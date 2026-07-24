// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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

contract InvariantFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

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
    uint256 public ghostDonatedAssets; // underlying sent directly, outside ERC-4626 accounting
    uint256 public ghostDonatedRewards; // direct USD8 surplus above committed rewards
    uint256 public ghostDepositedAssets; // underlying accepted through ERC-4626 deposits
    uint256 public ghostExitPayouts; // underlying paid from settled exit reserves
    uint256 public ghostClaimPayouts; // underlying paid through the insurance hook
    uint256 public ghostRemainingIncidentBudget;
    uint256 public activeIncidentId;
    uint256 public ghostIncidentCount;
    uint64[] internal ghostKnownEpochs;
    mapping(uint64 epoch => bool known) public ghostEpochKnown;
    mapping(uint64 epoch => bool settled) public ghostEpochSettled;
    mapping(uint64 epoch => uint256 shares) public ghostEpochTotalShares;
    mapping(uint64 epoch => uint256 assets) public ghostEpochTotalAssets;
    mapping(uint64 epoch => uint256 shares) public ghostEpochRemainingShares;
    mapping(uint64 epoch => uint256 assets) public ghostEpochRemainingAssets;

    uint256 public successfulExitRequests;
    uint256 public successfulSameEpochRequests;
    uint256 public successfulEpochSettlements;
    uint256 public successfulExitCompletions;
    uint256 public successfulFinalEpochClaimants;
    uint256 public successfulRequestsDuringIncident;

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
        if (activeIncidentId != 0) return;
        address who = _actor(actorSeed);
        amount = bound(amount, 1, 1e24);
        asset.mint(who, amount);
        vm.startPrank(who);
        asset.approve(address(pool), amount);
        pool.deposit(amount, who);
        vm.stopPrank();
        ghostDepositedAssets += amount;
    }

    function requestUnstake(uint256 actorSeed, uint256 shares) external {
        if (ghostKnownEpochs.length >= 16) return;
        address who = _actor(actorSeed);
        (uint256 existingShares,) = pool.exitRequests(who);
        if (existingShares != 0) return;
        uint256 bal = pool.balanceOf(who);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(who);
        pool.requestRedeem(shares);
        (, uint64 exitEpoch) = pool.exitRequests(who);
        if (!ghostEpochKnown[exitEpoch]) {
            ghostEpochKnown[exitEpoch] = true;
            ghostKnownEpochs.push(exitEpoch);
        } else if (ghostEpochTotalShares[exitEpoch] != 0) {
            successfulSameEpochRequests++;
        }
        ghostEpochTotalShares[exitEpoch] += shares;
        successfulExitRequests++;
        if (activeIncidentId != 0) successfulRequestsDuringIncident++;
        _syncSettledEpochs();
    }

    function completeUnstake(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        (uint256 shares, uint64 exitEpoch) = pool.exitRequests(who);
        if (shares == 0 || block.timestamp < exitEpoch) return;
        (,,,, bool settled) = pool.exitEpochs(exitEpoch);
        if (!settled && activeIncidentId != 0) return;
        if (!settled) {
            pool.settleMaturedExitEpochs(16);
            _syncSettledEpochs();
        }
        uint256 expectedAssets;
        uint256 remainingShares = ghostEpochRemainingShares[exitEpoch];
        if (shares == remainingShares) {
            expectedAssets = ghostEpochRemainingAssets[exitEpoch];
        } else {
            expectedAssets = Math.mulDiv(ghostEpochTotalAssets[exitEpoch], shares, ghostEpochTotalShares[exitEpoch]);
        }
        // completeRedeem does not pay yield; capture any USD8 delta
        // defensively (expected 0) so the reward-conservation ghost holds.
        uint256 rewardBefore = usd8.balanceOf(who);
        uint256 assetBefore = asset.balanceOf(who);
        vm.prank(who);
        pool.completeRedeem(who);
        ghostWithdrawn += usd8.balanceOf(who) - rewardBefore;
        uint256 received = asset.balanceOf(who) - assetBefore;
        assertEq(received, expectedAssets, "exit receipt rounding drift");
        ghostExitPayouts += received;
        ghostEpochRemainingShares[exitEpoch] = remainingShares - shares;
        ghostEpochRemainingAssets[exitEpoch] -= received;
        successfulExitCompletions++;
        if (ghostEpochRemainingShares[exitEpoch] == 0) successfulFinalEpochClaimants++;
    }

    function withdrawYield(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        uint256 got = pool.claimReward();
        ghostWithdrawn += got;
    }

    function distribute(uint256 amount) external {
        if (pool.totalSupply() == pool.balanceOf(address(pool))) return;
        amount = bound(amount, pool.rewardsDuration(), 1e22);
        vm.startPrank(admin);
        usd8.mint(admin, amount);
        usd8.approve(address(pool), amount);
        pool.receiveProfitDistribution(amount);
        ghostDistributed += amount;
        vm.stopPrank();
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 shares) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = pool.balanceOf(from);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);
        vm.prank(from);
        assertTrue(pool.transfer(to, shares), "share transfer failed");
    }

    function donateRewards(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        vm.prank(admin);
        usd8.mint(address(this), amount);
        assertTrue(usd8.transfer(address(pool), amount), "reward donation transfer failed");
        ghostDonatedRewards += amount;
    }

    function sweepDonatedRewards() external {
        if (ghostDonatedRewards == 0) return;
        uint256 receiverBefore = usd8.balanceOf(actors[0]);
        uint256 reserveBefore = pool.rewardReserve();
        uint256 swept = ghostDonatedRewards;
        vm.prank(admin);
        pool.sweepToken(IERC20(address(usd8)), actors[0]);
        ghostDonatedRewards = 0;
        assertEq(usd8.balanceOf(actors[0]), receiverBefore + swept, "wrong reward surplus swept");
        assertEq(pool.rewardReserve(), reserveBefore, "sweep touched reward reserve");
    }

    function donateAssets(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        asset.mint(address(pool), amount);
        ghostDonatedAssets += amount;
    }

    function settleMatured(uint256 maxEpochs) external {
        if (activeIncidentId != 0) return;
        maxEpochs = bound(maxEpochs, 1, 8);
        pool.settleMaturedExitEpochs(maxEpochs);
        _syncSettledEpochs();
    }

    function setIncidentActive(bool active) external {
        if (active) {
            if (activeIncidentId != 0 || ghostIncidentCount == 3) return;
            ghostIncidentCount += 1;
            activeIncidentId = ghostIncidentCount;
            ghostRemainingIncidentBudget = pool.maxPayoutPerIncident();
        } else {
            activeIncidentId = 0;
        }
    }

    function frozenOperationsRemainAtomic(uint256 actorSeed, uint256 amount) external {
        if (activeIncidentId == 0) return;
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1e24);
        uint256 assetsBefore = pool.totalAssets();
        uint256 supplyBefore = pool.totalSupply();
        uint256 reserveBefore = pool.withdrawalReserve();

        asset.mint(actor, amount);
        vm.startPrank(actor);
        asset.approve(address(pool), amount);
        vm.expectRevert(SingleAssetCoverPool.PoolFrozen.selector);
        pool.deposit(amount, actor);
        vm.stopPrank();

        vm.expectRevert(SingleAssetCoverPool.PoolFrozen.selector);
        pool.settleMaturedExitEpochs(1);

        assertEq(pool.totalAssets(), assetsBefore, "frozen operation changed assets");
        assertEq(pool.totalSupply(), supplyBefore, "frozen operation changed supply");
        assertEq(pool.withdrawalReserve(), reserveBefore, "frozen operation changed reserve");
    }

    function payClaim(uint256 actorSeed, uint256 amount) external {
        if (activeIncidentId == 0) return;
        uint256 available = pool.totalAssets();
        if (available == 0) return;
        uint256 budget = ghostRemainingIncidentBudget;
        if (budget == 0) return;
        uint256 limit = available < budget ? available : budget;
        amount = bound(amount, 1, limit);
        address recipient = _actor(actorSeed);
        uint256 balanceBefore = asset.balanceOf(recipient);
        pool.payClaim(recipient, amount);
        ghostClaimPayouts += amount;
        ghostRemainingIncidentBudget = budget - amount;
        assertEq(asset.balanceOf(recipient), balanceBefore + amount, "claim payout delta");
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 10 days);
        vm.warp(block.timestamp + secs);
    }

    function knownEpochsLength() external view returns (uint256) {
        return ghostKnownEpochs.length;
    }

    function knownEpoch(uint256 i) external view returns (uint64) {
        return ghostKnownEpochs[i];
    }

    function _syncSettledEpochs() internal {
        for (uint256 i = 0; i < ghostKnownEpochs.length; i++) {
            uint64 epochId = ghostKnownEpochs[i];
            if (ghostEpochSettled[epochId]) continue;
            (uint256 totalShares, uint256 totalAssets, uint256 remainingShares, uint256 remainingAssets, bool settled) =
                pool.exitEpochs(epochId);
            if (!settled) continue;
            assertEq(totalShares, ghostEpochTotalShares[epochId], "settled epoch share debt drift");
            assertEq(remainingShares, totalShares, "fresh epoch remaining shares");
            assertEq(remainingAssets, totalAssets, "fresh epoch remaining assets");
            ghostEpochSettled[epochId] = true;
            ghostEpochTotalAssets[epochId] = totalAssets;
            ghostEpochRemainingShares[epochId] = remainingShares;
            ghostEpochRemainingAssets[epochId] = remainingAssets;
            successfulEpochSettlements++;
        }
    }
}

// ════════════════════════════════════════════════════════════════════════
//  SingleAssetCoverPool stateful invariants
// ════════════════════════════════════════════════════════════════════════
contract SingleAssetCoverPoolInvariantTest is StdInvariant, Test {
    SingleAssetCoverPool pool;
    USD8 usd8;
    MockERC20 asset;
    PoolHandler handler;
    address admin = address(0xA11CE);
    Registry registry;

    function setUp() public {
        address feed = address(new InvariantFeed());
        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (admin, admin))))
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        vm.startPrank(admin);
        registry.setUsd8(address(usd8));
        registry.setTreasury(admin);
        vm.stopPrank();
        asset = new MockERC20("AST", "AST", 18);

        SingleAssetCoverPool impl = new SingleAssetCoverPool();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), admin);
        pool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(SingleAssetCoverPool.initialize, (registry, IERC20(address(asset)), "Cover", "cp"))
                )
            )
        );
        vm.startPrank(admin);
        registry.addPool(address(pool), feed);
        vm.stopPrank();

        handler = new PoolHandler(pool, usd8, asset, admin);
        vm.prank(admin);
        registry.setDefiInsurance(address(handler));

        // grant handler USD8 mint rights via admin prank inside handler (USD8 treasury == admin)
        // USD8 mint is gated to treasury; admin was set as treasury at init.
        bytes4[] memory sel = new bytes4[](14);
        sel[0] = PoolHandler.stake.selector;
        sel[1] = PoolHandler.requestUnstake.selector;
        sel[2] = PoolHandler.completeUnstake.selector;
        sel[3] = PoolHandler.withdrawYield.selector;
        sel[4] = PoolHandler.distribute.selector;
        sel[5] = PoolHandler.warp.selector;
        sel[6] = PoolHandler.transferShares.selector;
        sel[7] = PoolHandler.donateAssets.selector;
        sel[8] = PoolHandler.settleMatured.selector;
        sel[9] = PoolHandler.payClaim.selector;
        sel[10] = PoolHandler.setIncidentActive.selector;
        sel[11] = PoolHandler.frozenOperationsRemainAtomic.selector;
        sel[12] = PoolHandler.donateRewards.selector;
        sel[13] = PoolHandler.sweepDonatedRewards.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    function test_ProductiveAsyncExitBranchesAreReachable() public {
        handler.stake(0, 100e18);
        handler.stake(1, 101e18);
        handler.requestUnstake(0, type(uint256).max);
        handler.requestUnstake(1, type(uint256).max);
        handler.setIncidentActive(true);
        handler.payClaim(0, 1e18);
        handler.warp(10 days);
        handler.setIncidentActive(false);
        handler.settleMatured(8);
        handler.completeUnstake(0);
        handler.completeUnstake(1);

        assertGt(handler.successfulExitRequests(), 1);
        assertGt(handler.successfulSameEpochRequests(), 0);
        assertGt(handler.successfulEpochSettlements(), 0);
        assertGt(handler.successfulExitCompletions(), 1);
        assertGt(handler.successfulFinalEpochClaimants(), 0);
    }

    // Never over-pay; rewardReserve equals unclaimed distribution.
    function invariant_rewardConservation() public view {
        assertLe(handler.ghostWithdrawn(), handler.ghostDistributed(), "over-paid yield");
        assertEq(pool.rewardReserve(), handler.ghostDistributed() - handler.ghostWithdrawn(), "reserve mismatch");
    }

    // Donations remain outside internal ERC-4626 principal accounting.
    function invariant_assetAccountingIsExact() public view {
        assertEq(
            asset.balanceOf(address(pool)),
            pool.totalAssets() + pool.withdrawalReserve() + handler.ghostDonatedAssets(),
            "asset accounting mismatch"
        );
    }

    function invariant_activeAndReservedAssetsMatchLifecycleGhosts() public view {
        assertEq(
            pool.totalAssets() + pool.withdrawalReserve(),
            handler.ghostDepositedAssets() - handler.ghostExitPayouts() - handler.ghostClaimPayouts(),
            "lifecycle asset accounting mismatch"
        );
    }

    function invariant_registryFreezeMatchesHandlerIncident() public view {
        assertEq(registry.payoutIncidentActive(), handler.activeIncidentId() != 0, "freeze state mismatch");
    }

    function invariant_rewardReserveIsFullyBacked() public view {
        assertEq(
            usd8.balanceOf(address(pool)),
            pool.rewardReserve() + handler.ghostDonatedRewards(),
            "reward balance mismatch"
        );
    }

    function invariant_knownUserRewardsFitReserve() public view {
        assertLe(
            pool.earned(address(0xA11)) + pool.earned(address(0xB0B)), pool.rewardReserve(), "earned exceeds reserve"
        );
    }

    function invariant_rewardLiabilitiesAndRemainingStreamFitReserve() public view {
        uint256 remainingStream;
        if (block.timestamp < pool.periodFinish()) {
            remainingStream = pool.rewardRate() * (pool.periodFinish() - block.timestamp);
        }
        assertLe(
            pool.earned(address(0xA11)) + pool.earned(address(0xB0B)) + remainingStream,
            pool.rewardReserve(),
            "reward liabilities exceed reserve"
        );
    }

    function invariant_exitEpochDebtMatchesWithdrawalReserve() public view {
        uint256 remainingAssetDebt;
        for (uint256 i = 0; i < handler.knownEpochsLength(); i++) {
            uint64 epochId = handler.knownEpoch(i);
            (uint256 totalShares, uint256 totalAssets, uint256 remainingShares, uint256 remainingAssets, bool settled) =
                pool.exitEpochs(epochId);
            assertEq(totalShares, handler.ghostEpochTotalShares(epochId), "epoch total-share drift");
            assertEq(settled, handler.ghostEpochSettled(epochId), "epoch settlement drift");
            if (settled) {
                assertEq(totalAssets, handler.ghostEpochTotalAssets(epochId), "epoch total-asset drift");
                assertEq(remainingShares, handler.ghostEpochRemainingShares(epochId), "epoch remaining-share drift");
                assertEq(remainingAssets, handler.ghostEpochRemainingAssets(epochId), "epoch remaining-asset drift");
                assertLe(remainingShares, totalShares, "epoch share debt exceeds total");
                assertLe(remainingAssets, totalAssets, "epoch asset debt exceeds total");
                if (remainingShares == 0) assertEq(remainingAssets, 0, "asset dust after final claimant");
                remainingAssetDebt += remainingAssets;
            } else {
                assertEq(totalAssets, 0, "unsettled epoch has assets");
                assertEq(remainingShares, 0, "unsettled epoch has remaining shares");
                assertEq(remainingAssets, 0, "unsettled epoch has remaining assets");
            }
        }
        assertEq(pool.withdrawalReserve(), remainingAssetDebt, "withdrawal reserve debt drift");
    }

    function invariant_shareAccounting() public view {
        uint256 sumShares =
            pool.balanceOf(address(0xA11)) + pool.balanceOf(address(0xB0B)) + pool.balanceOf(address(pool));
        assertEq(sumShares, pool.totalSupply(), "share sum != totalShares");
        assertEq(
            pool.balanceOf(address(pool)),
            _unsettledRequestShares(address(0xA11)) + _unsettledRequestShares(address(0xB0B)),
            "exit escrow != unsettled requests"
        );
        if (pool.totalSupply() == 0) assertEq(pool.totalAssets(), 0, "assets remain without shares");
        // Active assets plus matured exit debt are backed by the pool's real balance.
        assertLe(
            pool.totalAssets() + pool.withdrawalReserve(), asset.balanceOf(address(pool)), "accounted assets > balance"
        );
    }

    function _unsettledRequestShares(address user) internal view returns (uint256 shares) {
        uint64 exitEpoch;
        (shares, exitEpoch) = pool.exitRequests(user);
        if (shares == 0) return 0;
        (,,,, bool settled) = pool.exitEpochs(exitEpoch);
        return settled ? 0 : shares;
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
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        vm.startPrank(admin);
        registry.setUsd8(address(usd8));
        registry.setTreasury(admin);
        vm.stopPrank();
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
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        registry.setUsd8(address(usd8));
        treasury = Treasury(
            address(
                new ERC1967Proxy(
                    address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry, IERC20(USDC_ADDR)))
                )
            )
        );
        registry.setTreasury(address(treasury));
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
