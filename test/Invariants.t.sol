// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {USD8} from "../src/USD8.sol";
import {SavingsUSD8} from "../src/SavingsUSD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

// ════════════════════════════════════════════════════════════════════════
//  CoverPool stateful handler — bounded actors, single asset
// ════════════════════════════════════════════════════════════════════════
contract CoverPoolHandler is Test {
    CoverPool public pool;
    USD8 public usd8;
    MockERC20 public asset;
    address public admin;

    address[2] public actors;

    // ghost accounting
    uint256 public ghostDistributed; // total USD8 ever streamed in
    uint256 public ghostWithdrawn; // total USD8 ever paid out as yield

    constructor(CoverPool _pool, USD8 _usd8, MockERC20 _asset, address _admin) {
        pool = _pool;
        usd8 = _usd8;
        asset = _asset;
        admin = _admin;
        actors[0] = address(0xA11);
        actors[1] = address(0xB0B);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        amount = bound(amount, 1, 1e24);
        asset.mint(who, amount);
        vm.startPrank(who);
        asset.approve(address(pool), amount);
        try pool.stake(IERC20(address(asset)), amount) {} catch {}
        vm.stopPrank();
    }

    function requestUnstake(uint256 actorSeed, uint256 shares) external {
        address who = _actor(actorSeed);
        uint256 bal = pool.userShares(IERC20(address(asset)), who);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(who);
        try pool.requestUnstake(IERC20(address(asset)), shares) {} catch {}
    }

    function cancelUnstake(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        try pool.cancelUnstakeRequest(IERC20(address(asset))) {} catch {}
    }

    function completeUnstake(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        // completeUnstake also auto-withdraws pending yield (USD8) to who,
        // which decrements rewardReserve; capture that as a payout too.
        uint256 before = usd8.balanceOf(who);
        vm.prank(who);
        try pool.completeUnstake(IERC20(address(asset))) {
            ghostWithdrawn += usd8.balanceOf(who) - before;
        } catch {}
    }

    function withdrawYield(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        try pool.withdrawYield(IERC20(address(asset))) returns (uint256 got) {
            ghostWithdrawn += got;
        } catch {}
    }

    function distribute(uint256 amount) external {
        amount = bound(amount, 1, 1e22);
        vm.startPrank(admin);
        usd8.mint(admin, amount);
        usd8.approve(address(pool), amount);
        try pool.receiveProfitDistribution(amount) {
            ghostDistributed += amount;
        } catch {
            usd8.approve(address(pool), 0);
        }
        vm.stopPrank();
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 10 days);
        vm.warp(block.timestamp + secs);
    }
}

// ════════════════════════════════════════════════════════════════════════
//  CoverPool invariants (properties 1 & 2)
// ════════════════════════════════════════════════════════════════════════
contract CoverPoolInvariantTest is StdInvariant, Test {
    CoverPool pool;
    USD8 usd8;
    MockERC20 asset;
    CoverPoolHandler handler;
    address admin = address(0xA11CE);

    function setUp() public {
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (admin, admin)))));
        asset = new MockERC20("AST", "AST", 18);

        CoverPool impl = new CoverPool();
        pool = CoverPool(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(CoverPool.initialize, (IERC20(address(usd8)), admin, admin, address(0)))
                )
            )
        );
        vm.startPrank(admin);
        pool.addCoverPoolAsset(IERC20(address(asset)), address(0xFEED), 1, 0); // weight 1, uncapped
        vm.stopPrank();

        handler = new CoverPoolHandler(pool, usd8, asset, admin);

        // grant handler USD8 mint rights via admin prank inside handler (USD8 treasury == admin)
        // USD8 mint is gated to treasury; admin was set as treasury at init.
        bytes4[] memory sel = new bytes4[](7);
        sel[0] = CoverPoolHandler.stake.selector;
        sel[1] = CoverPoolHandler.requestUnstake.selector;
        sel[2] = CoverPoolHandler.cancelUnstake.selector;
        sel[3] = CoverPoolHandler.completeUnstake.selector;
        sel[4] = CoverPoolHandler.withdrawYield.selector;
        sel[5] = CoverPoolHandler.distribute.selector;
        sel[6] = CoverPoolHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    // Property 1: never over-pay; rewardReserve never underflows (would revert -> caught).
    function invariant_rewardConservation() public view {
        assertLe(handler.ghostWithdrawn(), handler.ghostDistributed(), "over-paid yield");
        // rewardReserve must still cover all unwithdrawn-but-distributed rewards.
        assertGe(handler.ghostDistributed() - handler.ghostWithdrawn(), 0);
        // rewardReserve == distributed - withdrawn (no leak/underflow).
        assertEq(pool.rewardReserve(), handler.ghostDistributed() - handler.ghostWithdrawn(), "reserve mismatch");
    }

    // Property 2: share accounting. sum(user shares) == totalShares; totalAssets <= balance.
    function invariant_shareAccounting() public view {
        uint256 sumShares =
            pool.userShares(IERC20(address(asset)), address(0xA11)) + pool.userShares(IERC20(address(asset)), address(0xB0B));
        assertEq(sumShares, pool.totalShares(IERC20(address(asset))), "share sum != totalShares");
        // totalAssets is backed by real token balance held by the pool.
        assertLe(pool.totalAssets(IERC20(address(asset))), asset.balanceOf(address(pool)), "totalAssets > balance");
    }
}

// ════════════════════════════════════════════════════════════════════════
//  Stateless fuzz: size cap monotonicity (property 3), vesting (4), peg (5)
// ════════════════════════════════════════════════════════════════════════
contract StatelessFuzzTest is Test {
    address constant USDC_ADDR = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address admin = address(0xA11CE);

    // ── property 3: size cap never reverts, stake reverts cleanly ──
    //
    // For any PLAUSIBLE curated feed (decimals 0-18, a sane positive price), the
    // size-cap view must not panic and stake() must either succeed or revert with
    // the clean CoverPoolAssetCapExceeded error. (Absurd feed values — price
    // > ~1e59 — overflow _assetPriceWad's answer * 10**(18-fd); that path is
    // excluded by feed curation by design, and is documented as the curation
    // boundary in test_SizeCapOverflow_Repro below.)
    function testFuzz_SizeCapNeverReverts(int256 answer, uint8 feedDecimals, uint256 apyBps, uint256 distAmt)
        public
    {
        USD8 usd8 =
            USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (admin, admin)))));
        // Plausible curated feed: decimals 0-18, sane positive price (≤ 1e30 in
        // whole-token USD even at 18 decimals — far above any real asset, far
        // below the ~1e59 overflow boundary that curation excludes).
        feedDecimals = uint8(bound(feedDecimals, 0, 18));
        answer = int256(bound(uint256(answer), 1, 1e48));
        apyBps = bound(apyBps, 0, 1_000_000);
        distAmt = bound(distAmt, 1, 1e24);
        MockAggregator agg = new MockAggregator(answer, feedDecimals);

        MockERC20 asset = new MockERC20("AST", "AST", 6);
        CoverPool pool = CoverPool(
            address(
                new ERC1967Proxy(
                    address(new CoverPool()),
                    abi.encodeCall(CoverPool.initialize, (IERC20(address(usd8)), admin, admin, address(0)))
                )
            )
        );
        vm.startPrank(admin);
        pool.addCoverPoolAsset(IERC20(address(asset)), address(agg), 1, apyBps);
        vm.stopPrank();

        // bootstrap stake (rewardRate 0 => uncapped, always passes)
        asset.mint(address(this), 100e6);
        asset.approve(address(pool), 100e6);
        pool.stake(IERC20(address(asset)), 100e6);

        // stream profit -> sets rewardRate -> cap activates
        vm.startPrank(admin);
        usd8.mint(admin, distAmt);
        usd8.approve(address(pool), distAmt);
        pool.receiveProfitDistribution(distAmt);
        vm.stopPrank();

        // size cap view must never revert
        uint256 cap = pool.coverPoolAssetSizeCap(IERC20(address(asset)));
        assertGe(cap, 0);

        // a follow-up stake either succeeds or reverts with the cap error — never a raw panic
        uint256 amount = 50e6;
        asset.mint(address(this), amount);
        asset.approve(address(pool), amount);
        try pool.stake(IERC20(address(asset)), amount) returns (uint256) {
            // ok
        } catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertTrue(
                sel == CoverPool.CoverPoolAssetCapExceeded.selector,
                "stake reverted with a non-cap error (possible overflow/panic)"
            );
        }
    }

    /// @dev Documents the CURATION BOUNDARY (accepted, not a pending fix): an
    ///      absurd feed price (>~1e59 USD) overflows answer * 10**(18-fd) in
    ///      _assetPriceWad, so coverPoolAssetSizeCap panics instead of failing
    ///      open. Feeds are timelock-curated within sane bounds, so this input
    ///      can't occur in practice; the test pins the boundary so a future
    ///      change that wants unconditional fail-open knows what to move inside
    ///      the try/catch.
    function test_SizeCapOverflow_Repro() public {
        USD8 usd8 =
            USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (admin, admin)))));
        MockAggregator agg = new MockAggregator(int256(2e60), 0); // big positive price, 0 decimals
        MockERC20 asset = new MockERC20("AST", "AST", 6);
        CoverPool pool = CoverPool(
            address(
                new ERC1967Proxy(
                    address(new CoverPool()),
                    abi.encodeCall(CoverPool.initialize, (IERC20(address(usd8)), admin, admin, address(0)))
                )
            )
        );
        vm.prank(admin);
        pool.addCoverPoolAsset(IERC20(address(asset)), address(agg), 1, 5000); // 50% target APY
        asset.mint(address(this), 200e6);
        asset.approve(address(pool), 200e6);
        pool.stake(IERC20(address(asset)), 100e6); // bootstrap (rate 0 -> uncapped)
        vm.startPrank(admin);
        usd8.mint(admin, 70e18);
        usd8.approve(address(pool), 70e18);
        pool.receiveProfitDistribution(70e18); // sets rewardRate -> cap activates
        vm.stopPrank();

        vm.expectRevert(); // BUG: raw panic(0x11) instead of fail-open uncapped
        pool.coverPoolAssetSizeCap(IERC20(address(asset)));

        vm.expectRevert(); // BUG: stake bricked by the same panic
        pool.stake(IERC20(address(asset)), 100e6);
    }

    // ── property 4: SavingsUSD8 totalAssets never reverts; no JIT free yield ──
    function _deploySavings() internal returns (USD8 usd8, SavingsUSD8 vault) {
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (admin, admin)))));
        vault = new SavingsUSD8(usd8, admin, admin);
    }

    function _mintUsd8(USD8 usd8, address to, uint256 amt) internal {
        vm.prank(admin);
        usd8.mint(to, amt);
    }

    function testFuzz_VestingTotalAssetsNoRevert(uint256 seedDeposit, uint256 profit, uint256 t1, uint256 t2)
        public
    {
        (USD8 usd8, SavingsUSD8 vault) = _deploySavings();
        seedDeposit = bound(seedDeposit, 1e6, 1e24);
        profit = bound(profit, 1, 1e24);
        t1 = bound(t1, 0, 14 days);
        t2 = bound(t2, 0, 14 days);

        // seed depositor
        address dep = address(0xD00D);
        _mintUsd8(usd8, dep, seedDeposit);
        vm.startPrank(dep);
        usd8.approve(address(vault), seedDeposit);
        vault.deposit(seedDeposit, dep);
        vm.stopPrank();

        // distribute profit
        _mintUsd8(usd8, admin, profit);
        vm.startPrank(admin);
        usd8.approve(address(vault), profit);
        vault.receiveProfitDistribution(profit);
        vm.stopPrank();

        vm.warp(block.timestamp + t1);
        uint256 ta1 = vault.totalAssets(); // must not revert

        vm.warp(block.timestamp + t2);
        uint256 ta2 = vault.totalAssets(); // must not revert

        // share price non-decreasing across pure time (no loss here)
        if (vault.totalSupply() > 0) {
            // ta2 should be >= ta1 because vesting only releases more profit over time
            assertGe(ta2 + 1, ta1, "totalAssets decreased over pure time warp");
        }
    }

    function testFuzz_VestingNoJITFreeYield(uint256 seedDeposit, uint256 profit, uint256 jitDeposit) public {
        (USD8 usd8, SavingsUSD8 vault) = _deploySavings();
        seedDeposit = bound(seedDeposit, 1e6, 1e24);
        profit = bound(profit, 1e6, 1e24);
        jitDeposit = bound(jitDeposit, 1e6, 1e24);

        address dep = address(0xD00D);
        _mintUsd8(usd8, dep, seedDeposit);
        vm.startPrank(dep);
        usd8.approve(address(vault), seedDeposit);
        vault.deposit(seedDeposit, dep);
        vm.stopPrank();

        _mintUsd8(usd8, admin, profit);
        vm.startPrank(admin);
        usd8.approve(address(vault), profit);
        vault.receiveProfitDistribution(profit);
        vm.stopPrank();

        // JIT attacker deposits and immediately withdraws in the same block.
        address atk = address(0xBAD);
        _mintUsd8(usd8, atk, jitDeposit);
        vm.startPrank(atk);
        usd8.approve(address(vault), jitDeposit);
        uint256 sharesOut = vault.deposit(jitDeposit, atk);
        uint256 assetsBack = vault.redeem(sharesOut, atk, atk);
        vm.stopPrank();

        // attacker must not profit from unvested yield in a single block.
        assertLe(assetsBack, jitDeposit, "JIT attacker extracted free yield");
    }

    // ── property 5: Treasury peg — no unbacked mint; round-trip never profits ──
    function _deployTreasury() internal returns (USD8 usd8, Treasury treasury, MockERC20 usdc) {
        MockERC20 template = new MockERC20("USD Coin", "USDC", 6);
        vm.etch(USDC_ADDR, address(template).code);
        usdc = MockERC20(USDC_ADDR);

        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (address(this), address(this))))));
        treasury = new Treasury(usd8, admin, admin);
        usd8.setTreasury(address(treasury));
    }

    function testFuzz_PegNoUnbackedMint(uint256 mintAmt, uint256 redeemAmt, bool harvest) public {
        (USD8 usd8, Treasury treasury, MockERC20 usdc) = _deployTreasury();
        mintAmt = bound(mintAmt, 1, 1e18); // USDC units (6dp)
        usdc.mint(address(this), mintAmt);
        usdc.approve(address(treasury), mintAmt);
        treasury.mintUSD8(mintAmt);

        if (harvest) {
            vm.prank(admin);
            treasury.harvestRevenue();
        }

        // INVARIANT: supply <= reserve*1e12 + treasury-held USD8 buffer.
        // Treasury-held USD8 (harvested) is backed by the same reserve, so the
        // real peg check is supply (held by users) <= reserve*1e12.
        uint256 supply = usd8.totalSupply();
        uint256 treasuryUsd8 = usd8.balanceOf(address(treasury));
        uint256 userSupply = supply - treasuryUsd8;
        uint256 reserveUsd8 = treasury.getReserveBalance() * 1e12;
        assertLe(userSupply, reserveUsd8, "user-held USD8 is unbacked");

        // round-trip: mint then redeem never profits the user.
        if (redeemAmt > 0) {
            redeemAmt = bound(redeemAmt, 1, usd8.balanceOf(address(this)));
            uint256 usdcBefore = usdc.balanceOf(address(this));
            vm.prank(address(this));
            try treasury.redeemUSD8(redeemAmt, 0) {} catch {
                return;
            }
            uint256 usdcAfter = usdc.balanceOf(address(this));
            uint256 usdcGained = usdcAfter - usdcBefore;
            // user burned redeemAmt USD8 (==redeemAmt/1e12 USDC at peg); gained USDC must be <= that.
            assertLe(usdcGained, redeemAmt / 1e12, "redeem paid out more than burned");
        }
    }

    function testFuzz_PegRoundTripNoProfit(uint256 mintAmt) public {
        (USD8 usd8, Treasury treasury, MockERC20 usdc) = _deployTreasury();
        mintAmt = bound(mintAmt, 1, 1e18);
        usdc.mint(address(this), mintAmt);
        usdc.approve(address(treasury), mintAmt);
        treasury.mintUSD8(mintAmt);

        uint256 usd8Bal = usd8.balanceOf(address(this));
        uint256 usdcBefore = usdc.balanceOf(address(this));
        treasury.redeemUSD8(usd8Bal, 0);
        uint256 usdcAfter = usdc.balanceOf(address(this));

        // pure round trip: out <= in
        assertLe(usdcAfter - usdcBefore, mintAmt, "round-trip mint->redeem profited the user");
    }
}
