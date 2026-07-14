// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Registry} from "../src/Registry.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {USD8SavingsAdapter} from "../src/adapters/USD8SavingsAdapter.sol";
import {VaultV2} from "vault-v2/src/VaultV2.sol";
import {VaultV2Factory} from "vault-v2/src/VaultV2Factory.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

// ════════════════════════════════════════════════════════════════════════
//  SingleAssetCoverPool stateful handler — bounded actors
// ════════════════════════════════════════════════════════════════════════
contract PoolHandler is Test {
    SingleAssetCoverPool public pool;
    USD8 public usd8;
    MockERC20 public asset;
    address public admin;

    address[2] public actors;

    // ghost accounting
    uint256 public ghostDistributed; // total USD8 ever streamed in
    uint256 public ghostWithdrawn; // total USD8 ever paid out as yield

    constructor(SingleAssetCoverPool _pool, USD8 _usd8, MockERC20 _asset, address _admin) {
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
        try pool.deposit(amount, who) {} catch {}
        vm.stopPrank();
    }

    function requestUnstake(uint256 actorSeed, uint256 shares) external {
        address who = _actor(actorSeed);
        uint256 bal = pool.balanceOf(who);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(who);
        try pool.requestRedeem(shares) {} catch {}
    }

    function cancelUnstake(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        try pool.cancelRedeemRequest() {} catch {}
    }

    function completeUnstake(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        // completeRedeem checkpoints but does not pay yield; capture any USD8
        // delta defensively (expected 0) so the reward-conservation ghost holds.
        uint256 before = usd8.balanceOf(who);
        vm.prank(who);
        try pool.completeRedeem() {
            ghostWithdrawn += usd8.balanceOf(who) - before;
        } catch {}
    }

    function withdrawYield(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        try pool.claimReward() returns (uint256 got) {
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
//  SingleAssetCoverPool invariants (properties 1 & 2)
// ════════════════════════════════════════════════════════════════════════
contract SingleAssetCoverPoolInvariantTest is StdInvariant, Test {
    SingleAssetCoverPool pool;
    USD8 usd8;
    MockERC20 asset;
    PoolHandler handler;
    address admin = address(0xA11CE);
    Registry registry;

    function setUp() public {
        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (admin, admin))))
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry, admin)))));
        asset = new MockERC20("AST", "AST", 18);

        SingleAssetCoverPool impl = new SingleAssetCoverPool();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), admin);
        pool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (registry, IERC20(address(asset)), IERC20(address(usd8)), "Cover", "cp")
                    )
                )
            )
        );
        vm.startPrank(admin);
        registry.addPool(address(pool));
        vm.stopPrank();

        handler = new PoolHandler(pool, usd8, asset, admin);

        // grant handler USD8 mint rights via admin prank inside handler (USD8 treasury == admin)
        // USD8 mint is gated to treasury; admin was set as treasury at init.
        bytes4[] memory sel = new bytes4[](7);
        sel[0] = PoolHandler.stake.selector;
        sel[1] = PoolHandler.requestUnstake.selector;
        sel[2] = PoolHandler.cancelUnstake.selector;
        sel[3] = PoolHandler.completeUnstake.selector;
        sel[4] = PoolHandler.withdrawYield.selector;
        sel[5] = PoolHandler.distribute.selector;
        sel[6] = PoolHandler.warp.selector;
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
        uint256 sumShares = pool.balanceOf(address(0xA11)) + pool.balanceOf(address(0xB0B));
        assertEq(sumShares, pool.totalSupply(), "share sum != totalShares");
        // totalAssets is backed by real token balance held by the pool.
        assertLe(pool.totalAssets(), asset.balanceOf(address(pool)), "totalAssets > balance");
    }
}

// ════════════════════════════════════════════════════════════════════════
//  Stateless fuzz: vesting (property 4), peg (property 5)
// ════════════════════════════════════════════════════════════════════════
contract StatelessFuzzTest is Test {
    address constant USDC_ADDR = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address admin = address(0xA11CE);

    // ── property 4: Morpho sUSD8 totalAssets never reverts; no JIT free yield ──
    function _deploySavings() internal returns (USD8 usd8, VaultV2 vault, USD8SavingsAdapter adapter) {
        Registry registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (admin, admin))))
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry, admin)))));
        vault = VaultV2(new VaultV2Factory().createVaultV2(address(this), address(usd8), keccak256("sUSD8")));
        adapter = new USD8SavingsAdapter(address(vault));
        vault.setCurator(address(this));
        _executeMorpho(vault, abi.encodeCall(IVaultV2.setIsAllocator, (address(this), true)));
        _executeMorpho(vault, abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        bytes memory idData = abi.encode("this", address(adapter));
        _executeMorpho(vault, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        _executeMorpho(vault, abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.setMaxRate(20e16 / uint256(365 days));
        vault.setLiquidityAdapterAndData(address(adapter), "");
    }

    function _executeMorpho(VaultV2 vault, bytes memory data) internal {
        vault.submit(data);
        (bool success, bytes memory returnData) = address(vault).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    function _mintUsd8(USD8 usd8, address to, uint256 amt) internal {
        vm.prank(admin);
        usd8.mint(to, amt);
    }

    /// forge-config: default.isolate = true
    function testFuzz_MorphoTotalAssetsNoRevert(uint256 seedDeposit, uint256 profit, uint256 t1, uint256 t2) public {
        (USD8 usd8, VaultV2 vault, USD8SavingsAdapter adapter) = _deploySavings();
        seedDeposit = bound(seedDeposit, 1e6, 1e24);
        profit = bound(profit, 1, 1e24);
        t1 = bound(t1, 0, 14 days);
        t2 = bound(t2, 0, 14 days);

        address dep = address(0xD00D);
        _mintUsd8(usd8, dep, seedDeposit);
        vm.startPrank(dep);
        usd8.approve(address(vault), seedDeposit);
        vault.deposit(seedDeposit, dep);
        vm.stopPrank();

        _mintUsd8(usd8, admin, profit);
        vm.startPrank(admin);
        usd8.approve(address(adapter), profit);
        adapter.receiveProfitDistribution(profit);
        vm.stopPrank();

        vm.warp(block.timestamp + t1);
        uint256 ta1 = vault.totalAssets();
        vm.warp(block.timestamp + t2);
        uint256 ta2 = vault.totalAssets();

        assertGe(ta2 + 1, ta1, "totalAssets decreased over pure time warp");
        assertLe(ta2, usd8.balanceOf(address(adapter)), "reported assets exceed controlled assets");
    }

    /// forge-config: default.isolate = true
    function testFuzz_MorphoNoJITFreeYield(uint256 seedDeposit, uint256 profit, uint256 jitDeposit) public {
        (USD8 usd8, VaultV2 vault, USD8SavingsAdapter adapter) = _deploySavings();
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
        usd8.approve(address(adapter), profit);
        adapter.receiveProfitDistribution(profit);
        vm.stopPrank();

        address atk = address(0xBAD);
        _mintUsd8(usd8, atk, jitDeposit);
        vm.startPrank(atk);
        usd8.approve(address(vault), jitDeposit);
        uint256 sharesOut = vault.deposit(jitDeposit, atk);
        uint256 assetsBack = vault.redeem(sharesOut, atk, atk);
        vm.stopPrank();

        assertLe(assetsBack, jitDeposit, "JIT attacker extracted free yield");
    }

    // ── property 5: Treasury peg — no unbacked mint; round-trip never profits ──
    function _deployTreasury() internal returns (USD8 usd8, Treasury treasury, MockERC20 usdc) {
        MockERC20 template = new MockERC20("USD Coin", "USDC", 6);
        vm.etch(USDC_ADDR, address(template).code);
        usdc = MockERC20(USDC_ADDR);

        // address(this) is the timelock (so it can setTreasury here); admin is
        // added to the admin set for the fuzz's admin-gated harvest path.
        Registry registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), admin)))
            )
        );
        usd8 = USD8(
            address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry, address(this)))))
        );
        treasury = Treasury(
            address(new ERC1967Proxy(address(new Treasury()), abi.encodeCall(Treasury.initialize, (usd8, registry))))
        );
        usd8.setTreasury(address(treasury));
    }

    function testFuzz_PegNoUnbackedMint(uint256 mintAmt, uint256 redeemAmt, bool harvest) public {
        (USD8 usd8, Treasury treasury, MockERC20 usdc) = _deployTreasury();
        mintAmt = bound(mintAmt, 1, 1e18); // USDC units (6dp)
        usdc.mint(address(this), mintAmt);
        usdc.approve(address(treasury), mintAmt);
        treasury.mintUSD8(mintAmt);

        if (harvest) {
            // 1:1 mint leaves no surplus above the buffer, so this no-ops
            // (harvested 0, nothing to distribute — no receiver required).
            vm.prank(admin);
            treasury.harvestAndDistribute();
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
            try treasury.redeemUSD8(redeemAmt, 0) {}
            catch {
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
