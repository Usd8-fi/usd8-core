// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {Registry} from "../src/Registry.sol";
import {SharedBase} from "../src/SharedBase.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {USD8} from "../src/USD8.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";

interface ICompleteRedeem {
    function completeRedeem(address receiver) external returns (uint256 assets);
}

/// @dev Insured token that records the pool-freeze state when DefiInsurance
///      sends an over-escrow refund during claim finalization.
contract RefundFreezeProbeToken is ERC20 {
    Registry public reg;
    address public defi;
    bool public probed;
    bool public frozenDuringRefund;

    constructor(Registry _reg) ERC20("Probe", "PRB") {
        reg = _reg;
    }

    function setDefi(address d) external {
        defi = d;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == defi && defi != address(0)) {
            frozenDuringRefund = reg.payoutIncidentActive();
            probed = true;
        }
        super._update(from, to, value);
    }
}

contract SingleAssetCoverPoolTest is Test {
    MockERC20 usdc;
    USD8 usd8; // real USD8: reward token
    MockERC20 lp1; // insured token 1
    MockERC20 lp2; // insured token 2
    MockERC1155 booster;
    SingleAssetCoverPool pool; // the single USDC stake pool
    UpgradeableBeacon beacon;
    DefiInsurance defi;
    Registry registry;

    address admin = address(0xA11CE);
    address alice = address(0xBEEF);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    uint64 constant DURATION = 7 days;
    address constant FEED = address(0xFEED); // dummy USD feed (off-chain only, unused on-chain)
    uint128 constant MIN_CLAIM = 10e18; // insured-token base units
    uint256 constant VS = 1_000; // virtual-share multiplier (10 ** _decimalsOffset(), offset = 3)
    uint64 constant BOOSTER_ID = 1;
    uint16 constant BOOSTER_BOOST_BPS = 100;
    bytes32 constant TEST_TEE_PCR_HASH = keccak256("PCR0-PCR1-PCR2");
    bytes32 constant UPDATED_TEE_PCR_HASH = keccak256("updated-PCR0-PCR1-PCR2");

    event TeePcrHashSet(bytes32 indexed oldHash, bytes32 indexed newHash);

    function setUp() public {
        vm.roll(1000); // so openClaimIncident's referenceBlock (block.number - 1) is a valid past block
        vm.etch(FEED, hex"00");
        vm.mockCall(FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(
            FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(1e8), uint256(1), uint256(1), uint80(1))
        );
        usdc = new MockERC20("USDC", "USDC", 6);
        // admin doubles as timelock + admin on the shared Registry in tests.
        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (admin, admin))))
        );
        vm.prank(admin);
        registry.setTeePcrHash(TEST_TEE_PCR_HASH);
        USD8 usd8Impl = new USD8();
        usd8 = USD8(address(new ERC1967Proxy(address(usd8Impl), abi.encodeCall(USD8.initialize, (registry)))));
        vm.startPrank(admin);
        registry.setUsd8(address(usd8));
        registry.setTreasury(admin);
        vm.stopPrank();
        lp1 = new MockERC20("LP1", "LP1", 18);
        lp2 = new MockERC20("LP2", "LP2", 18);
        booster = new MockERC1155();

        // SingleAssetCoverPool impl behind a shared UpgradeableBeacon (owner = admin),
        // matching prod. The launch pool is USDC, rewarded in USD8.
        SingleAssetCoverPool poolImpl = new SingleAssetCoverPool();
        beacon = new UpgradeableBeacon(address(poolImpl), admin);
        pool = _deployPool(IERC20(address(usdc)));

        defi = DefiInsurance(
            address(
                new ERC1967Proxy(address(new DefiInsurance()), abi.encodeCall(DefiInsurance.initialize, (registry)))
            )
        );
        vm.startPrank(admin);
        registry.setMaxCoverPoolPayoutBps(8000); // 80% for these tests (constructor default is 50%)
        registry.addPool(address(pool), FEED);
        registry.setBoosterConfig(address(booster), BOOSTER_ID, BOOSTER_BOOST_BPS);
        registry.setDefiInsurance(address(defi));
        defi.editInsuredToken(IERC20(address(lp1)), 8000, FEED, address(0), "");
        defi.editInsuredToken(IERC20(address(lp2)), 8000, FEED, address(0), "");
        defi.setTeeSigner(vm.addr(TEE_PK), true); // settlement is TEE-signature-gated
        vm.stopPrank();
    }

    // ────────────────────────── helpers ──────────────────────────

    /// @dev Deploy a pool proxy for `asset_` behind the shared beacon, rewarded in
    ///      USD8. Live on init — no seed step.
    function _deployPool(IERC20 asset_) internal returns (SingleAssetCoverPool) {
        return SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon), abi.encodeCall(SingleAssetCoverPool.initialize, (registry, asset_, "Cover", "cp"))
                )
            )
        );
    }

    function _stake(address who, uint256 amount) internal returns (uint256 sharesMinted) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        sharesMinted = pool.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Fund rewards: admin (acting as the Treasury donor) streams `amount` USD8.
    function _notify(uint256 amount) internal {
        vm.startPrank(admin);
        usd8.mint(admin, amount);
        usd8.approve(address(pool), amount);
        pool.receiveProfitDistribution(amount);
        vm.stopPrank();
    }

    function _fundClaimBond(address user) internal {
        vm.prank(admin);
        usd8.mint(user, 10e18);
        vm.prank(user);
        usd8.approve(address(defi), 10e18);
    }

    function _prepareClaimant(address user, MockERC20 insuredToken, uint128 amount) internal {
        insuredToken.mint(user, amount);
        _fundClaimBond(user);
        vm.prank(user);
        insuredToken.approve(address(defi), amount);
    }

    /// @dev Admin opens an incident on the token if none is joinable, then the
    ///      user joins it. Keeps call sites simple.
    function _registerClaim(address user, MockERC20 insuredToken, uint128 amount) internal returns (uint256 claimId) {
        insuredToken.mint(user, amount);
        _fundClaimBond(user);
        vm.prank(user);
        insuredToken.approve(address(defi), amount);

        if (!_hasJoinableIncident(address(insuredToken))) {
            vm.prank(admin);
            defi.openClaimIncident(IERC20(address(insuredToken)), uint64(block.number - 1));
        }
        vm.prank(user);
        claimId = defi.fileClaim(IERC20(address(insuredToken)), amount, 0, 0, 0, "");
    }

    /// @dev True if the in-flight incident covers token and its claim
    ///      window is still open (i.e. a claim can join without opening).
    function _hasJoinableIncident(address token) internal view returns (bool) {
        uint256 active = defi.activeIncidentId();
        if (active == 0) return false;
        (IERC20 tok,,,, uint64 wEnd,,,,,) = defi.incidents(active);
        return address(tok) == token && block.timestamp <= wEnd;
    }

    /// @dev OZ double-hashed leaf over (incidentId, claimId, user, amounts, rawScoreSpent,
    ///      boostedScore, eligible). eligible defaults to the claim's escrow,
    ///      which is what finalizeClaim forfeits, so refund is 0 and payouts are unchanged.
    function _leaf(uint256 incidentId, uint256 claimId, address user, uint256[] memory amounts)
        internal
        view
        returns (bytes32)
    {
        (,, uint128 escrow,,,) = defi.claims(claimId);
        return _leafSpent(incidentId, claimId, user, amounts, 1, 1, escrow);
    }

    function _leafSpent(
        uint256 incidentId,
        uint256 claimId,
        address user,
        uint256[] memory amounts,
        uint256 scoreSpent,
        uint256 boostedScore,
        uint256 eligible
    ) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(keccak256(abi.encode(incidentId, claimId, user, amounts, scoreSpent, boostedScore, eligible)))
        );
    }

    /// @dev OZ MerkleProof sorted-pair hash (for building 2-leaf test trees).
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Relay a TEE-signed settlement root for incidentId.
    function _settle(uint256 incidentId, bytes32 root) internal {
        uint256[] memory pp = _pp();
        defi.settleIncident(root, pp, _teeSign(incidentId, root, pp));
    }

    /// @dev Payout row for the single-pool [usdc] setup.
    function _amounts(uint256 usdcAmt) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = usdcAmt;
    }

    function _completeUnstakeAfterCooldown(address who, uint256 shares) internal returns (uint256 assetsOut) {
        vm.prank(who);
        pool.requestRedeem(shares);
        (, uint64 exitEpoch) = pool.exitRequests(who);
        vm.warp(exitEpoch);
        vm.prank(who);
        assetsOut = pool.completeRedeem(who);
    }

    // ════════════════════ Construction & basic config ════════════════════

    function test_ConstructorWiring() public view {
        assertEq(address(pool.usd8()), address(usd8));
        assertEq(address(pool.asset()), address(usdc));
        assertEq(registry.timelock(), admin);
        assertTrue(registry.isAdmin(admin));
        assertEq(pool.rewardsDuration(), DURATION);
        assertEq(registry.coverPoolsLength(), 1);
        assertTrue(defi.isInsuredToken(IERC20(address(lp1))));
        assertTrue(defi.isInsuredToken(IERC20(address(lp2))));
        assertEq(defi.nextClaimId(), 1);
        assertEq(defi.nextIncidentId(), 1);
        (address boosterCollection, uint64 boosterId, uint16 boosterBoostBps) = registry.boosterConfig();
        assertEq(boosterCollection, address(booster));
        assertEq(boosterId, BOOSTER_ID);
        assertEq(boosterBoostBps, BOOSTER_BOOST_BPS);
    }

    function test_BoosterConfigCanOnlyBeSetOnce() public {
        Registry fresh = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (admin, admin))))
        );

        vm.prank(admin);
        fresh.setBoosterConfig(address(booster), BOOSTER_ID, BOOSTER_BOOST_BPS);
        (address collection, uint64 tokenId, uint16 boostBps) = fresh.boosterConfig();
        assertEq(collection, address(booster));
        assertEq(tokenId, BOOSTER_ID);
        assertEq(boostBps, BOOSTER_BOOST_BPS);

        vm.prank(admin);
        vm.expectRevert(Registry.BoosterConfigAlreadySet.selector);
        fresh.setBoosterConfig(address(0xB0057), 2, 200);
    }

    function test_TimelockSetsTeePcrHash() public {
        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(registry));
        emit TeePcrHashSet(TEST_TEE_PCR_HASH, UPDATED_TEE_PCR_HASH);
        registry.setTeePcrHash(UPDATED_TEE_PCR_HASH);

        assertEq(registry.teePcrHash(), UPDATED_TEE_PCR_HASH);
    }

    function test_TeePcrHashRejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(Registry.InvalidTeePcrHash.selector);
        registry.setTeePcrHash(bytes32(0));
    }

    function test_InitializeUsesRegistryUsd8AsRewardToken() public {
        SingleAssetCoverPool candidate = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(SingleAssetCoverPool.initialize, (registry, IERC20(address(usdc)), "Cover", "cp"))
                )
            )
        );

        assertEq(address(candidate.usd8()), address(usd8));
    }

    function test_InitializeRejectsUnsetRegistryUsd8() public {
        Registry emptyRegistry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (admin, admin))))
        );
        vm.expectRevert(SharedBase.ZeroAddress.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(SingleAssetCoverPool.initialize, (emptyRegistry, IERC20(address(usdc)), "Cover", "cp"))
        );
    }

    function test_ImplementationCannotBeInitialized() public {
        SingleAssetCoverPool impl = new SingleAssetCoverPool();
        vm.expectRevert(); // InvalidInitialization (impl initializers disabled)
        impl.initialize(registry, IERC20(address(usdc)), "Cover", "cp");
    }

    /// @dev Beacon upgrade re-points the proxy at new code while storage is
    ///      preserved; only the beacon owner (timelock) may upgrade.
    function test_BeaconUpgradePreservesStorage() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares / 2);
        (, uint64 exitEpochBefore) = pool.exitRequests(alice);

        SingleAssetCoverPoolV2 v2 = new SingleAssetCoverPoolV2();

        // Non-owner cannot upgrade the beacon.
        vm.prank(alice);
        vm.expectRevert();
        beacon.upgradeTo(address(v2));

        // Owner (admin) upgrades: every pool sees the new code.
        vm.prank(admin);
        beacon.upgradeTo(address(v2));

        assertEq(SingleAssetCoverPoolV2(address(pool)).version(), 2); // new code
        assertEq(pool.totalSupply(), shares);
        assertEq(pool.balanceOf(alice), shares / 2);
        assertEq(pool.balanceOf(address(pool)), shares / 2);
        assertEq(pool.totalAssets(), 100e6);
        (uint256 requestedAfter, uint64 exitEpochAfter) = pool.exitRequests(alice);
        assertEq(requestedAfter, shares / 2);
        assertEq(exitEpochAfter, exitEpochBefore);
    }

    function test_DefiInsuranceUpgradeAllowedDuringBeta() public {
        DefiInsuranceV2 v2 = new DefiInsuranceV2();

        vm.prank(admin); // admin == timelock in this harness
        defi.upgradeToAndCall(address(v2), "");
    }

    function test_DefiInsuranceUpgradeBlockedDuringActiveIncident() public {
        _registerClaim(bob, lp1, 50e18);
        DefiInsuranceV2 v2 = new DefiInsuranceV2();

        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        vm.prank(admin); // admin == timelock in this harness
        defi.upgradeToAndCall(address(v2), "");
    }

    function test_DefiInsuranceUpgradePermanentlyDisabledAfterBetaEnds() public {
        vm.prank(admin);
        registry.endBetaMode();

        DefiInsuranceV2 v2 = new DefiInsuranceV2();
        vm.expectRevert(SharedBase.NotBetaMode.selector);
        vm.prank(admin);
        defi.upgradeToAndCall(address(v2), "");
    }

    function test_DefiInsuranceImplementationCannotBeInitialized() public {
        DefiInsurance implementation = new DefiInsurance();
        vm.expectRevert();
        implementation.initialize(registry);
    }

    // ════════════════════ Pool topology (Registry) ════════════════════

    function test_AddPoolRejectsInvalidFeedContract() public {
        MockERC20 asset = new MockERC20("Bad feed", "BAD", 18);
        SingleAssetCoverPool newPool = _deployPool(IERC20(address(asset)));

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Registry.InvalidAssetUsdFeed.selector, address(0xdead)));
        registry.addPool(address(newPool), address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(Registry.InvalidAssetUsdFeed.selector, address(asset)));
        registry.addPool(address(newPool), address(asset));
        vm.stopPrank();
    }

    function test_AddPoolRejectsMissingFeed() public {
        MockERC20 asset = new MockERC20("No feed", "NONE", 18);
        SingleAssetCoverPool newPool = _deployPool(IERC20(address(asset)));
        vm.prank(admin);
        vm.expectRevert(Registry.ZeroAddress.selector);
        registry.addPool(address(newPool), address(0));
    }

    function test_AddPoolDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Registry.PoolExists.selector, IERC20(address(usdc))));
        registry.addPool(address(pool), FEED);
    }

    function test_AddPoolRejectsInsuredToken() public {
        SingleAssetCoverPool conflictingPool = _deployPool(IERC20(address(lp1)));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Registry.TokenConflict.selector, IERC20(address(lp1))));
        registry.addPool(address(conflictingPool), FEED);
    }

    function test_RemovePool() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        SingleAssetCoverPool daiPool = _deployPool(IERC20(address(dai)));
        vm.startPrank(admin);
        registry.addPool(address(daiPool), FEED);
        assertEq(registry.coverPoolsLength(), 2);
        assertEq(registry.assetUsdFeed(IERC20(address(dai))), FEED);
        registry.removePool(address(daiPool));
        assertEq(registry.coverPoolsLength(), 1);
        assertEq(registry.coverPool(IERC20(address(dai))), address(0));
        assertEq(registry.assetUsdFeed(IERC20(address(dai))), address(0));

        // Removing an unregistered asset reverts.
        vm.expectRevert(abi.encodeWithSelector(Registry.PoolNotFound.selector, IERC20(address(dai))));
        registry.removePool(address(daiPool));
        vm.stopPrank();
    }

    /// @dev Fee-on-transfer assets are unsupported (ERC-4626 limitation): a deposit
    ///      that delivers less than the nominal amount reverts loudly rather than
    ///      corrupting accounting (totalAssets would exceed the real balance).
    function test_FeeOnTransferDepositReverts() public {
        MockFeeToken fee = new MockFeeToken(100); // 1% fee on transfer
        SingleAssetCoverPool feePool = _deployPool(IERC20(address(fee)));
        vm.prank(admin);
        registry.addPool(address(feePool), FEED);

        fee.mint(alice, 100e18);
        vm.startPrank(alice);
        fee.approve(address(feePool), 100e18);
        vm.expectRevert(SingleAssetCoverPool.FeeOnTransferUnsupported.selector);
        feePool.deposit(100e18, alice);
        vm.stopPrank();

        assertEq(feePool.totalAssets(), 0, "no accounting on a rejected deposit");
    }

    /// @dev Shares are transferable ERC-20; rewards must checkpoint on transfer so the
    ///      sender keeps what they earned and the receiver earns going forward — no
    ///      double-count, no leak (reward-on-transfer path in {_update}).
    function test_ShareTransferConservesRewards() public {
        _stake(alice, 100e6); // alice: all shares
        _notify(70e18); // stream 70 USD8 over rewardsDuration
        vm.warp(block.timestamp + 3 days + 12 hours); // half the 7-day window elapses

        uint256 aliceEarnedBefore = pool.earned(alice);
        assertGt(aliceEarnedBefore, 0);
        assertEq(pool.earned(bob), 0);

        // Alice transfers half her shares to bob mid-stream.
        uint256 half = pool.balanceOf(alice) / 2;
        vm.prank(alice);
        pool.transfer(bob, half);

        // Transfer credits alice's accrued rewards up to now; bob starts from 0 accrued.
        assertApproxEqAbs(pool.earned(alice), aliceEarnedBefore, 2, "alice keeps her accrued");
        assertEq(pool.earned(bob), 0, "bob accrued nothing yet");

        // Let the rest stream; both now earn on their post-transfer balances (equal split).
        vm.warp(block.timestamp + 4 days);
        uint256 aliceTotal = pool.earned(alice);
        uint256 bobTotal = pool.earned(bob);

        // Conservation: total claimable never exceeds what was distributed.
        assertLe(aliceTotal + bobTotal, 70e18, "no reward inflation across the transfer");
        // Bob (0 before) earned only on the second half at half the shares.
        assertGt(bobTotal, 0);
        assertGt(aliceTotal, bobTotal, "alice earned the first half solo plus her share of the rest");
    }

    function test_RequestRedeemEscrowsSharesAndStopsFutureRewards() public {
        uint256 shares = _stake(alice, 100e6);
        _notify(70e18);
        vm.warp(block.timestamp + 1 days);
        uint256 accruedBeforeRequest = pool.earned(alice);

        vm.prank(alice);
        pool.requestRedeem(shares);

        assertEq(pool.balanceOf(alice), 0, "requested shares leave user balance");
        assertEq(pool.balanceOf(address(pool)), shares, "pool escrows requested shares");

        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(pool.earned(alice), accruedBeforeRequest, 2, "request stops future rewards");
    }

    function test_ProtocolSeedRemainsRewardEligibleAfterExternalExit() public {
        address seedSink = address(0xdead);
        uint256 seedShares = _stake(seedSink, 10_000);
        uint256 aliceShares = _stake(alice, 100e6);
        _completeUnstakeAfterCooldown(alice, aliceShares);

        _notify(70e18);
        vm.warp(block.timestamp + 1 days);

        assertEq(pool.balanceOf(seedSink), seedShares);
        assertGt(pool.earned(seedSink), 0);
    }

    function test_ExitTimingConfigDefaultsAndAdminUpdateAtomically() public {
        Registry.ExitTimingConfig memory defaults = registry.exitTimingConfig();
        assertEq(defaults.unstakeCooldown, 7 days);
        assertEq(defaults.exitBatchInterval, 3 days);

        Registry.ExitTimingConfig memory updated =
            Registry.ExitTimingConfig({unstakeCooldown: 1 hours, exitBatchInterval: 15 minutes});
        vm.prank(admin);
        registry.setExitTimingConfig(updated);
        Registry.ExitTimingConfig memory stored = registry.exitTimingConfig();
        assertEq(stored.unstakeCooldown, updated.unstakeCooldown);
        assertEq(stored.exitBatchInterval, updated.exitBatchInterval);

        uint256 shares = _stake(alice, 100e6);
        uint256 requestedAt = block.timestamp;
        vm.prank(alice);
        pool.requestRedeem(shares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);
        uint256 earliest = requestedAt + updated.unstakeCooldown;
        assertGe(exitEpoch, earliest);
        assertLt(exitEpoch, earliest + updated.exitBatchInterval);
        assertEq(exitEpoch % updated.exitBatchInterval, 0);
    }

    function test_ShorterTimingCannotInsertBeforeOutstandingExitEpoch() public {
        uint256 aliceShares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(aliceShares);
        (, uint64 outstandingTail) = pool.exitRequests(alice);

        Registry.ExitTimingConfig memory shorter =
            Registry.ExitTimingConfig({unstakeCooldown: 1 days, exitBatchInterval: 1 days});
        vm.prank(admin);
        registry.setExitTimingConfig(shorter);

        uint256 bobShares = _stake(bob, 100e6);
        vm.prank(bob);
        pool.requestRedeem(bobShares);
        (, uint64 bobEpoch) = pool.exitRequests(bob);

        assertEq(bobEpoch, outstandingTail);
    }

    function test_LegacyExitTimingSelectorsAreNotExposed() public view {
        (bool cooldownSuccess, bytes memory cooldownData) =
            address(pool).staticcall(abi.encodeWithSignature("UNSTAKE_COOLDOWN()"));
        assertFalse(cooldownSuccess);
        assertEq(cooldownData.length, 0);

        (bool intervalSuccess, bytes memory intervalData) =
            address(pool).staticcall(abi.encodeWithSignature("EXIT_BATCH_INTERVAL()"));
        assertFalse(intervalSuccess);
        assertEq(intervalData.length, 0);
    }

    function test_ExitTimingConfigRejectsUnauthorizedInvalidAndActiveIncidentUpdates() public {
        Registry.ExitTimingConfig memory valid =
            Registry.ExitTimingConfig({unstakeCooldown: 1 hours, exitBatchInterval: 15 minutes});

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, alice));
        registry.setExitTimingConfig(valid);

        Registry.ExitTimingConfig memory invalid =
            Registry.ExitTimingConfig({unstakeCooldown: 0, exitBatchInterval: 15 minutes});
        vm.prank(admin);
        vm.expectRevert(Registry.InvalidExitTimingConfig.selector);
        registry.setExitTimingConfig(invalid);

        _registerClaim(bob, lp1, 50e18);
        vm.prank(admin);
        vm.expectRevert(Registry.Frozen.selector);
        registry.setExitTimingConfig(valid);
    }

    function test_ExitEpochUsesThreeDayBatches() public {
        Registry.ExitTimingConfig memory config = registry.exitTimingConfig();
        assertEq(config.exitBatchInterval, 3 days);
        uint256 shares = _stake(alice, 100e6);
        uint256 requestedAt = block.timestamp;

        vm.prank(alice);
        pool.requestRedeem(shares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);

        uint256 earliest = requestedAt + config.unstakeCooldown;
        assertGe(exitEpoch, earliest);
        assertLt(exitEpoch, earliest + 3 days);
        assertEq(exitEpoch % 3 days, 0);
    }

    function test_IncidentOpeningSettlesMaturedExitBeforeComputingCapacity() public {
        uint256 exitingShares = _stake(alice, 100e6);
        uint256 activeShares = _stake(bob, 100e6);

        vm.prank(alice);
        pool.requestRedeem(exitingShares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);
        vm.warp(exitEpoch);

        _registerClaim(carol, lp1, 50e18);

        assertEq(pool.totalAssets(), 100e6, "matured capital excluded before freeze");
        assertEq(pool.totalSupply(), activeShares, "matured shares burned before freeze");
        assertEq(pool.balanceOf(address(pool)), 0, "escrow consumed at exit epoch");
        assertEq(pool.maxPayoutPerIncident(), 80e6, "capacity uses active capital only");
    }

    function test_MaturedExitCanBeClaimedWithoutAWindow() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares);

        vm.warp(block.timestamp + 30 days);
        pool.settleMaturedExitEpochs(type(uint256).max);
        assertEq(pool.withdrawalReserve(), 100e6);

        vm.prank(alice);
        uint256 assets = ICompleteRedeem(address(pool)).completeRedeem(alice);

        assertEq(assets, 100e6);
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(pool.withdrawalReserve(), 0);
    }

    function test_StandardRedeemRemainsDisabledAfterExitMatures() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);

        vm.warp(exitEpoch);
        assertEq(pool.maxRedeem(alice), 0, "exit receipts are claimed through completeRedeem");
    }

    function test_CancelRedeemRequestSelectorRemoved() public {
        (bool ok, bytes memory returndata) = address(pool).call(abi.encodeWithSignature("cancelRedeemRequest()"));
        assertFalse(ok);
        assertEq(returndata.length, 0);
    }

    function test_PoolCurationBlockedDuringIncident() public {
        _stake(alice, 100e6);
        _registerClaim(bob, lp1, 50e18); // opens incident -> system frozen

        MockERC20 newAsset = new MockERC20("NEW", "NEW", 18);
        SingleAssetCoverPool newPool = _deployPool(IERC20(address(newAsset)));
        vm.prank(admin);
        vm.expectRevert(Registry.Frozen.selector);
        registry.addPool(address(newPool), FEED);

        // Removal is also blocked while an incident is active.
        vm.prank(admin);
        vm.expectRevert(Registry.Frozen.selector);
        registry.removePool(address(pool));
    }

    // ════════════════════ Insured token management ════════════════════

    function test_AddInsuredTokenRejectsStakeAsset() public {
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.TokenConflict.selector);
        defi.editInsuredToken(IERC20(address(usdc)), 8000, FEED, address(0), "");
    }

    function test_AddInsuredTokenAcceptsUSD8() public {
        vm.prank(admin);
        defi.editInsuredToken(IERC20(address(usd8)), 8000, FEED, address(0), "");
        assertEq(defi.getInsuredToken(IERC20(address(usd8))).maxCoverageBps, 8000);
    }

    /// @dev End-to-end USD8 self-cover: the TEE attests a backing loss off-chain
    ///      and signs the open; alice then claims. No on-chain trigger/adapter.
    function test_USD8BackingLossTriggersIncident() public {
        vm.startPrank(admin);
        defi.editInsuredToken(IERC20(address(usd8)), 8000, FEED, address(0), "");
        usd8.mint(alice, 100e18);
        vm.stopPrank();
        vm.prank(alice);
        usd8.approve(address(defi), 100e18);

        // Without a TEE signature the first filing fails closed.
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(0)));
        defi.fileClaim(IERC20(address(usd8)), 50e18, 0, 0, 0, "");

        // The first claimant atomically opens and files with the TEE authorization.
        uint64 refBlock = uint64(block.number - 1);
        bytes memory sig = _teeSignOpen(address(usd8), refBlock);
        vm.prank(alice);
        defi.fileClaim(IERC20(address(usd8)), 50e18, 0, 0, refBlock, sig);
        uint256 id = defi.activeIncidentId();
        (,, uint64 stored,,,,,,,) = defi.incidents(id);
        assertEq(stored, refBlock);
        // Still listed: delisting is deferred to root settlement, not open.
        assertEq(defi.getInsuredToken(IERC20(address(usd8))).maxCoverageBps, 8000);
    }

    function test_EditInsuredTokenUpdatesConfig() public {
        vm.prank(admin);
        defi.editInsuredToken(IERC20(address(lp1)), 7000, FEED, address(0), "");
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).maxCoverageBps, 7000);
    }

    // ════════════════════ Settlement config ════════════════════

    function test_AddInsuredTokenStoresConfig() public view {
        DefiInsurance.InsuredToken memory it = defi.getInsuredToken(IERC20(address(lp1)));
        assertEq(it.maxCoverageBps, 8000);
        assertEq(it.underlyingPriceOracle, FEED);
        assertEq(it.underlyingConversionAddress, address(0)); // identity
    }

    function test_AddInsuredTokenRejectsBadArgs() public {
        MockERC20 lp3 = new MockERC20("LP3", "LP3", 18);
        vm.startPrank(admin);
        vm.expectRevert(SharedBase.ZeroAddress.selector); // zero price oracle
        defi.editInsuredToken(IERC20(address(lp3)), 8000, address(0), address(0), "");
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InsuredTokenNotApproved.selector, IERC20(address(lp3))));
        defi.editInsuredToken(IERC20(address(lp3)), 0, address(0), address(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(DefiInsurance.InvalidMaxCoverageBps.selector, uint256(8_001), uint256(8_000))
        );
        defi.editInsuredToken(IERC20(address(lp3)), 8_001, FEED, address(0), "");
        defi.editInsuredToken(IERC20(address(lp3)), 8000, FEED, address(0), "");
        vm.stopPrank();
    }

    function test_ConversionRecipeValidationIsTrustedToTimelock() public {
        MockConversionRecipe converter = new MockConversionRecipe(0);
        bytes memory cd = abi.encodeCall(MockConversionRecipe.convertToAssets, (1e18));
        DefiInsurance.InsuredToken memory config = defi.getInsuredToken(IERC20(address(lp1)));
        config.underlyingConversionAddress = address(converter);
        config.underlyingConversionCallData = cd;

        vm.prank(admin);
        defi.editInsuredToken(
            IERC20(address(lp1)),
            config.maxCoverageBps,
            config.underlyingPriceOracle,
            config.underlyingConversionAddress,
            config.underlyingConversionCallData
        );

        DefiInsurance.InsuredToken memory it = defi.getInsuredToken(IERC20(address(lp1)));
        assertEq(it.underlyingConversionAddress, address(converter));
        assertEq(it.underlyingConversionCallData, cd);
    }

    function test_ConversionRecipeUpdatable() public {
        // Mutable via setter: repoint lp1's token→underlying recipe in place.
        bytes32 eligibilityBefore = defi.incidentOpenEligibilityHash(IERC20(address(lp1)));
        MockConversionRecipe converter = new MockConversionRecipe(1e18);
        bytes memory cd = abi.encodeCall(MockConversionRecipe.convertToAssets, (1e18));
        DefiInsurance.InsuredToken memory config = defi.getInsuredToken(IERC20(address(lp1)));
        config.underlyingConversionAddress = address(converter);
        config.underlyingConversionCallData = cd;
        vm.prank(admin);
        defi.editInsuredToken(
            IERC20(address(lp1)),
            config.maxCoverageBps,
            config.underlyingPriceOracle,
            config.underlyingConversionAddress,
            config.underlyingConversionCallData
        );
        DefiInsurance.InsuredToken memory it = defi.getInsuredToken(IERC20(address(lp1)));
        assertEq(it.underlyingConversionAddress, address(converter));
        assertEq(it.underlyingConversionCallData, cd);
        assertNotEq(defi.incidentOpenEligibilityHash(IERC20(address(lp1))), eligibilityBefore);

        // And re-listing sets a fresh recipe.
        vm.startPrank(admin);
        defi.editInsuredToken(IERC20(address(lp1)), 0, address(0), address(0), "");
        defi.editInsuredToken(IERC20(address(lp1)), 8000, FEED, address(converter), cd);
        vm.stopPrank();
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).underlyingConversionAddress, address(converter));
    }

    function test_InsuredTokenConfigUpdatesAtomically() public {
        MockConversionRecipe converter = new MockConversionRecipe(2e18);
        bytes memory conversionData = abi.encodeCall(MockConversionRecipe.convertToAssets, (2e18));
        DefiInsurance.InsuredToken memory updated = DefiInsurance.InsuredToken({
            maxCoverageBps: 7500,
            underlyingPriceOracle: address(0xBEEF),
            underlyingConversionAddress: address(converter),
            underlyingConversionCallData: conversionData
        });

        vm.prank(admin);
        (bool ok,) = address(defi)
            .call(
                abi.encodeWithSignature(
                    "editInsuredToken(address,uint256,address,address,bytes)",
                    address(lp1),
                    updated.maxCoverageBps,
                    updated.underlyingPriceOracle,
                    updated.underlyingConversionAddress,
                    updated.underlyingConversionCallData
                )
            );
        assertTrue(ok);

        DefiInsurance.InsuredToken memory stored = defi.getInsuredToken(IERC20(address(lp1)));
        assertEq(stored.maxCoverageBps, updated.maxCoverageBps);
        assertEq(stored.underlyingPriceOracle, updated.underlyingPriceOracle);
        assertEq(stored.underlyingConversionAddress, updated.underlyingConversionAddress);
        assertEq(stored.underlyingConversionCallData, updated.underlyingConversionCallData);
    }

    function test_ScoredTokenRateTimeline() public {
        vm.startPrank(admin);
        vm.roll(100);
        registry.setScoredToken(IERC20(address(usd8)), 5);
        assertEq(registry.scoredTokensLength(), 1);
        IERC20[] memory list = registry.getScoredTokens();
        assertEq(address(list[0]), address(usd8));
        Registry.RatePoint[] memory h = registry.getScoredRateHistory(IERC20(address(usd8)));
        assertEq(h.length, 1);
        assertEq(h[0].fromBlock, 100);
        assertEq(h[0].rate, 5);

        // A rate change APPENDS a segment effective at block.number — never rewrites
        // the past, never duplicates the token in the enumerable set.
        vm.roll(200);
        registry.setScoredToken(IERC20(address(usd8)), 7);
        assertEq(registry.scoredTokensLength(), 1); // still one token
        h = registry.getScoredRateHistory(IERC20(address(usd8)));
        assertEq(h.length, 2);
        assertEq(h[0].rate, 5); // old segment preserved
        assertEq(h[1].fromBlock, 200);
        assertEq(h[1].rate, 7);

        // rate 0 is the off switch — appends {now, 0}, token stays enumerable.
        vm.roll(300);
        registry.setScoredToken(IERC20(address(usd8)), 0);
        assertEq(registry.scoredTokensLength(), 1);
        h = registry.getScoredRateHistory(IERC20(address(usd8)));
        assertEq(h.length, 3);
        assertEq(h[2].rate, 0);
        vm.stopPrank();
    }

    function test_RegistryStoresSettlementOraclePolicy() public {
        assertEq(registry.maxOracleStaleness(), 36 hours);

        vm.startPrank(admin);
        registry.setAssetUsdFeed(IERC20(address(lp1)), FEED);
        registry.setMaxOracleStaleness(48 hours);
        vm.stopPrank();

        assertEq(registry.assetUsdFeed(IERC20(address(lp1))), FEED);
        assertEq(registry.maxOracleStaleness(), 48 hours);
    }

    function test_RegistryRejectsInvalidSettlementOraclePolicy() public {
        vm.startPrank(admin);
        vm.expectRevert(Registry.ZeroAddress.selector);
        registry.setAssetUsdFeed(IERC20(address(0)), FEED);
        vm.expectRevert(Registry.ZeroAddress.selector);
        registry.setAssetUsdFeed(IERC20(address(lp1)), address(0));
        vm.expectRevert(Registry.InvalidOracleStaleness.selector);
        registry.setMaxOracleStaleness(0);
        vm.stopPrank();
    }

    function test_RegistryRejectsAssetFeedAbove18Decimals() public {
        vm.mockCall(FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(19)));

        vm.expectRevert(abi.encodeWithSelector(Registry.InvalidAssetUsdFeed.selector, FEED));
        vm.prank(admin);
        registry.setAssetUsdFeed(IERC20(address(lp1)), FEED);
    }

    function test_SettlementOraclePolicyFrozenDuringIncident() public {
        _registerClaim(alice, lp1, 10e18);

        vm.startPrank(admin);
        vm.expectRevert(Registry.Frozen.selector);
        registry.setAssetUsdFeed(IERC20(address(lp1)), FEED);
        vm.expectRevert(Registry.Frozen.selector);
        registry.setMaxOracleStaleness(48 hours);
        vm.stopPrank();
    }

    function test_ScoredTokenRateTimelineRejectsNonIncreasingBlock() public {
        vm.startPrank(admin);
        vm.roll(100);
        registry.setScoredToken(IERC20(address(usd8)), 5);

        vm.expectRevert(
            abi.encodeWithSelector(
                Registry.NonIncreasingScoredRateBlock.selector, IERC20(address(usd8)), uint64(100), uint64(100)
            )
        );
        registry.setScoredToken(IERC20(address(usd8)), 7);
        vm.stopPrank();
    }

    function test_ScoredTokenRateTimelineAllowsDifferentTokensInSameBlock() public {
        vm.startPrank(admin);
        vm.roll(100);
        registry.setScoredToken(IERC20(address(usd8)), 5);
        registry.setScoredToken(IERC20(address(lp1)), 7);
        vm.stopPrank();

        Registry.RatePoint[] memory usd8History = registry.getScoredRateHistory(IERC20(address(usd8)));
        Registry.RatePoint[] memory lp1History = registry.getScoredRateHistory(IERC20(address(lp1)));
        assertEq(usd8History[0].fromBlock, 100);
        assertEq(lp1History[0].fromBlock, 100);
    }

    function test_SettlementConfigFrozenDuringIncident() public {
        _registerClaim(bob, lp1, 50e18); // opens incident

        // Settlement-critical config is frozen for the incident's whole life,
        // so the off-chain openBlock config read can't be desynced by a mid-incident
        // mutation. setSettlementParams now reverts IncidentsActive.
        DefiInsurance.SettlementParams memory p =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 1, minHoldingRequired: 1, sampleStepBlocks: 1});
        vm.startPrank(admin);
        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        defi.setSettlementParams(p);

        // Scored-token curation stays frozen too (Registry-side).
        vm.expectRevert(Registry.Frozen.selector);
        registry.setScoredToken(IERC20(address(usd8)), 1);
        vm.stopPrank();
    }

    /// @dev Insured-token config setters are also frozen during an incident.
    function test_InsuredConfigFrozenDuringIncident() public {
        _registerClaim(bob, lp1, 50e18); // opens incident on lp1
        DefiInsurance.InsuredToken memory config = defi.getInsuredToken(IERC20(address(lp1)));
        config.maxCoverageBps = 5000;
        vm.startPrank(admin);
        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        defi.editInsuredToken(
            IERC20(address(lp1)),
            config.maxCoverageBps,
            config.underlyingPriceOracle,
            config.underlyingConversionAddress,
            config.underlyingConversionCallData
        );
        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        defi.editInsuredToken(IERC20(address(lp2)), 0, address(0), address(0), "");
        vm.stopPrank();
    }

    function test_IncidentOpenPriceConfigDefaultsAndAdminUpdateAtomically() public {
        Registry.IncidentOpenPriceConfig memory defaults = registry.incidentOpenPriceConfig();
        assertEq(defaults.twapBlocks, 7_200);
        assertEq(defaults.sampleStepBlocks, 300);
        assertEq(defaults.minimumDropBps, 2_000);

        Registry.IncidentOpenPriceConfig memory updated =
            Registry.IncidentOpenPriceConfig({twapBlocks: 600, sampleStepBlocks: 60, minimumDropBps: 2_500});
        vm.prank(admin);
        registry.setIncidentOpenPriceConfig(updated);

        Registry.IncidentOpenPriceConfig memory stored = registry.incidentOpenPriceConfig();
        assertEq(stored.twapBlocks, updated.twapBlocks);
        assertEq(stored.sampleStepBlocks, updated.sampleStepBlocks);
        assertEq(stored.minimumDropBps, updated.minimumDropBps);
    }

    function test_IncidentOpenPriceConfigRejectsUnauthorizedInvalidAndActiveIncidentUpdates() public {
        Registry.IncidentOpenPriceConfig memory valid =
            Registry.IncidentOpenPriceConfig({twapBlocks: 600, sampleStepBlocks: 60, minimumDropBps: 2_000});

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, alice));
        registry.setIncidentOpenPriceConfig(valid);

        valid.sampleStepBlocks = 70;
        vm.prank(admin);
        vm.expectRevert(Registry.InvalidIncidentOpenPriceConfig.selector);
        registry.setIncidentOpenPriceConfig(valid);

        valid = Registry.IncidentOpenPriceConfig({twapBlocks: 600, sampleStepBlocks: 600, minimumDropBps: 2_000});
        vm.prank(admin);
        vm.expectRevert(Registry.InvalidIncidentOpenPriceConfig.selector);
        registry.setIncidentOpenPriceConfig(valid);

        valid = Registry.IncidentOpenPriceConfig({
            twapBlocks: registry.incidentTimingConfig().maxReferenceBlockAge,
            sampleStepBlocks: 300,
            minimumDropBps: 2_000
        });
        vm.prank(admin);
        vm.expectRevert(Registry.InvalidIncidentOpenPriceConfig.selector);
        registry.setIncidentOpenPriceConfig(valid);

        _registerClaim(bob, lp1, 50e18);
        valid = Registry.IncidentOpenPriceConfig({twapBlocks: 600, sampleStepBlocks: 60, minimumDropBps: 2_000});
        vm.prank(admin);
        vm.expectRevert(Registry.Frozen.selector);
        registry.setIncidentOpenPriceConfig(valid);
    }

    function test_AllTimingSettersRequireTimelockNotAdmin() public {
        address fastAdmin = address(0xFA57);
        vm.prank(admin);
        registry.setAdmin(fastAdmin, true);

        Registry.IncidentTimingConfig memory incidentTiming = registry.incidentTimingConfig();
        Registry.ExitTimingConfig memory exitTiming = registry.exitTimingConfig();
        Registry.IncidentOpenPriceConfig memory openPrice = registry.incidentOpenPriceConfig();

        vm.startPrank(fastAdmin);
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, fastAdmin));
        registry.setIncidentTimingConfig(incidentTiming);
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, fastAdmin));
        registry.setExitTimingConfig(exitTiming);
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, fastAdmin));
        registry.setIncidentOpenPriceConfig(openPrice);
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, fastAdmin));
        pool.setRewardsDuration(14 days);
        vm.stopPrank();
    }

    function test_IncidentTimingConfigRejectsReferenceAgeNotGreaterThanTwapWindow() public {
        Registry.IncidentTimingConfig memory timing = registry.incidentTimingConfig();
        timing.maxReferenceBlockAge = registry.incidentOpenPriceConfig().twapBlocks;

        vm.prank(admin);
        vm.expectRevert(Registry.InvalidIncidentTimingConfig.selector);
        registry.setIncidentTimingConfig(timing);
    }

    function test_IncidentTimingConfigDefaultsAndTimelockUpdateAtomically() public {
        Registry.IncidentTimingConfig memory defaults = registry.incidentTimingConfig();
        assertEq(defaults.phaseWindow, 3 days);
        assertEq(defaults.maxReferenceBlockAge, 43_200);

        Registry.IncidentTimingConfig memory updated =
            Registry.IncidentTimingConfig({phaseWindow: 60 minutes, maxReferenceBlockAge: 10_000});
        vm.prank(admin);
        registry.setIncidentTimingConfig(updated);

        assertEq(registry.incidentTimingConfig().phaseWindow, updated.phaseWindow);
        assertEq(registry.incidentTimingConfig().maxReferenceBlockAge, updated.maxReferenceBlockAge);
    }

    function test_IncidentTimingConfigAllowsValuesAboveFormerCaps() public {
        Registry.IncidentTimingConfig memory updated =
            Registry.IncidentTimingConfig({phaseWindow: 31 days, maxReferenceBlockAge: 1_000_001});

        vm.prank(admin);
        registry.setIncidentTimingConfig(updated);

        Registry.IncidentTimingConfig memory stored = registry.incidentTimingConfig();
        assertEq(stored.phaseWindow, updated.phaseWindow);
        assertEq(stored.maxReferenceBlockAge, updated.maxReferenceBlockAge);
    }

    function test_ExitTimingConfigAllowsValuesAboveFormerCap() public {
        Registry.ExitTimingConfig memory updated =
            Registry.ExitTimingConfig({unstakeCooldown: 31 days, exitBatchInterval: 32 days});

        vm.prank(admin);
        registry.setExitTimingConfig(updated);

        Registry.ExitTimingConfig memory stored = registry.exitTimingConfig();
        assertEq(stored.unstakeCooldown, updated.unstakeCooldown);
        assertEq(stored.exitBatchInterval, updated.exitBatchInterval);
    }

    function test_IncidentOpenPriceConfigAllowsMoreThanFormerSampleCap() public {
        Registry.IncidentOpenPriceConfig memory updated =
            Registry.IncidentOpenPriceConfig({twapBlocks: 600, sampleStepBlocks: 1, minimumDropBps: 2_000});

        vm.prank(admin);
        registry.setIncidentOpenPriceConfig(updated);

        Registry.IncidentOpenPriceConfig memory stored = registry.incidentOpenPriceConfig();
        assertEq(stored.twapBlocks, updated.twapBlocks);
        assertEq(stored.sampleStepBlocks, updated.sampleStepBlocks);
        assertEq(stored.minimumDropBps, updated.minimumDropBps);
    }

    function test_PhaseDeadlineStartsAtClaimEnd() public {
        uint256 openedAt = block.timestamp;
        _registerClaim(bob, lp1, 50e18);

        (,,,, uint64 phaseDeadline,,,,,) = defi.incidents(1);
        assertEq(phaseDeadline, openedAt + registry.incidentTimingConfig().phaseWindow);
    }

    function test_IncidentTimingIsFrozenForActiveIncident() public {
        Registry.IncidentTimingConfig memory configured =
            Registry.IncidentTimingConfig({phaseWindow: 60 minutes, maxReferenceBlockAge: 10_000});
        vm.prank(admin);
        registry.setIncidentTimingConfig(configured);

        uint256 openedAt = block.timestamp;
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        (,,,, uint64 phaseDeadline,,,,,) = defi.incidents(1);
        assertEq(phaseDeadline, openedAt + configured.phaseWindow);
        uint256 settlementDeadline = uint256(phaseDeadline) + configured.phaseWindow;

        vm.prank(admin);
        vm.expectRevert(Registry.Frozen.selector);
        registry.setIncidentTimingConfig(configured);

        vm.warp(settlementDeadline + 1);
        vm.prank(bob);
        defi.finalizeClaim(claimId, false, new uint256[](0), 0, 0, 0, new bytes32[](0));

        Registry.IncidentTimingConfig memory later = Registry.IncidentTimingConfig({
            phaseWindow: 30 minutes, maxReferenceBlockAge: configured.maxReferenceBlockAge
        });
        vm.prank(admin);
        registry.setIncidentTimingConfig(later);
        (,,,, uint64 unchangedPhaseDeadline,,,,,) = defi.incidents(1);
        assertEq(unchangedPhaseDeadline, phaseDeadline);
    }

    function test_ExpiredIncidentCannotBeResurrectedByLaterTimingUpdate() public {
        Registry.IncidentTimingConfig memory configured =
            Registry.IncidentTimingConfig({phaseWindow: 60 minutes, maxReferenceBlockAge: 10_000});
        vm.prank(admin);
        registry.setIncidentTimingConfig(configured);

        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        (,,,, uint64 phaseDeadline,,,,,) = defi.incidents(1);
        vm.warp(uint256(phaseDeadline) + configured.phaseWindow + 1);

        configured.phaseWindow = 2 hours;
        vm.prank(admin);
        registry.setIncidentTimingConfig(configured);

        vm.prank(bob);
        defi.finalizeClaim(claimId, false, new uint256[](0), 0, 0, 0, new bytes32[](0));

        (,,,,, bool resolved) = defi.claims(claimId);
        assertTrue(resolved);
    }

    function test_IncidentTimingConfigRejectsUnauthorizedAndInvalidUpdates() public {
        Registry.IncidentTimingConfig memory valid =
            Registry.IncidentTimingConfig({phaseWindow: 60 minutes, maxReferenceBlockAge: 10_000});
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, alice));
        registry.setIncidentTimingConfig(valid);

        valid.phaseWindow = 0;
        vm.prank(admin);
        vm.expectRevert(Registry.InvalidIncidentTimingConfig.selector);
        registry.setIncidentTimingConfig(valid);
    }

    function test_ZeroSampleStepReverts() public {
        DefiInsurance.SettlementParams memory p =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 50, minHoldingRequired: 20, sampleStepBlocks: 0});
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.InvalidSettlementParams.selector);
        defi.setSettlementParams(p);
    }

    function test_OpenBlockRecordedForOffchainConfigRecompute() public {
        DefiInsurance.SettlementParams memory p =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 50, minHoldingRequired: 20, sampleStepBlocks: 5});
        vm.prank(admin);
        defi.setSettlementParams(p);

        uint64 expectedOpen = uint64(block.number);
        _registerClaim(bob, lp1, 50e18); // opens incident 1

        // The incident records only its open block; off-chain reconstructs the
        // full config (recipe, params, scored-token set) from state as of it.
        (,,, uint64 openBlock,,,,,,) = defi.incidents(1);
        assertEq(openBlock, expectedOpen);

        // Config is frozen while the incident is live, so the openBlock read
        // can't be desynced by a mid-incident retune — setSettlementParams reverts.
        DefiInsurance.SettlementParams memory p2 =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 999, minHoldingRequired: 1, sampleStepBlocks: 1});
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        defi.setSettlementParams(p2);
    }

    function test_EditInsuredTokenZeroCoverageDelists() public {
        vm.prank(admin);
        defi.editInsuredToken(IERC20(address(lp2)), 0, address(0), address(0), "");
        uint256 cov = defi.getInsuredToken(IERC20(address(lp2))).maxCoverageBps;
        assertEq(cov, 0); // maxCoverageBps == 0 ⇒ delisted
        assertFalse(defi.isInsuredToken(IERC20(address(lp2))));
    }

    // ════════════════════ Share-based stake/unstake ════════════════════

    function test_FirstStakeIsOneToOne() public {
        uint256 shares = _stake(alice, 100e6);
        assertEq(shares, 100e6 * VS);
        assertEq(pool.totalSupply(), 100e6 * VS);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(pool.balanceOf(alice), 100e6 * VS);
    }

    function test_StakeSecondIsProportional() public {
        _stake(alice, 100e6);
        uint256 sharesB = _stake(bob, 50e6);
        assertEq(sharesB, 50e6 * VS);
        assertEq(pool.totalSupply(), 150e6 * VS);
    }

    function test_DepositCapEnforcedSoftAndUncappable() public {
        // Uncapped by default.
        assertEq(pool.maxDeposit(alice), type(uint256).max);
        assertEq(pool.maxMint(alice), type(uint256).max);

        vm.prank(admin);
        pool.setDepositCap(100e6);
        assertEq(pool.maxDeposit(alice), 100e6);
        assertEq(pool.maxMint(alice), 100e6 * VS);

        // Partial fill → remaining capacity shrinks.
        _stake(alice, 60e6);
        assertEq(pool.maxDeposit(alice), 40e6);

        // Over-cap deposit reverts; exactly the remaining capacity is fine.
        usdc.mint(bob, 50e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 50e6);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit
        pool.deposit(50e6, bob);
        pool.deposit(40e6, bob);
        vm.stopPrank();
        assertEq(pool.totalAssets(), 100e6);
        assertEq(pool.maxDeposit(alice), 0);

        // Soft: lowering below current size stops new deposits but never unwinds.
        vm.prank(admin);
        pool.setDepositCap(50e6);
        assertEq(pool.maxDeposit(alice), 0);
        assertEq(pool.totalAssets(), 100e6);

        // Uncap again.
        vm.prank(admin);
        pool.setDepositCap(0);
        assertEq(pool.maxDeposit(alice), type(uint256).max);
    }

    function test_DepositCapSetterAuth() public {
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, bob));
        vm.prank(bob);
        pool.setDepositCap(1e6);
    }

    function test_LegacyCompleteRedeemWithoutReceiverSelectorRemoved() public {
        (bool ok, bytes memory returndata) = address(pool).call(abi.encodeWithSignature("completeRedeem()"));
        assertFalse(ok);
        assertEq(returndata.length, 0);
    }

    function test_ClaimExitSelectorRemoved() public {
        (bool ok, bytes memory returndata) = address(pool).call(abi.encodeWithSignature("claimExit(address)", alice));
        assertFalse(ok);
        assertEq(returndata.length, 0);
    }

    function test_UnstakeRequestStartsCooldown() public {
        _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(100e6 * VS);
        (uint256 sh, uint64 exitEpoch) = pool.exitRequests(alice);
        assertEq(sh, 100e6 * VS);
        assertGe(exitEpoch, block.timestamp + 7 days);
        assertLt(exitEpoch, block.timestamp + 10 days);
    }

    function test_UnstakeRequestDuplicateReverts() public {
        _stake(alice, 100e6);
        vm.startPrank(alice);
        pool.requestRedeem(50e6 * VS);
        vm.expectRevert(SingleAssetCoverPool.UnstakeRequestExists.selector);
        pool.requestRedeem(50e6 * VS);
        vm.stopPrank();
    }

    function test_CompleteRedeemBeforeCooldownReverts() public {
        _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(100e6 * VS);
        (, uint64 exitEpoch) = pool.exitRequests(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SingleAssetCoverPool.CooldownNotElapsed.selector, exitEpoch));
        pool.completeRedeem(alice);
    }

    function test_CompleteUnstakeAfterCooldownReturnsTokens() public {
        _stake(alice, 100e6);
        uint256 out = _completeUnstakeAfterCooldown(alice, pool.balanceOf(alice));
        assertEq(out, 100e6);
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(pool.totalSupply(), 0);
    }

    function test_FullExitSettlementResetsActiveAccountingBeforeNewMint() public {
        uint256 aliceShares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(aliceShares);
        (, uint64 aliceExitEpoch) = pool.exitRequests(alice);

        vm.warp(aliceExitEpoch);
        pool.settleMaturedExitEpochs(type(uint256).max);

        assertEq(pool.totalSupply(), 0);
        assertEq(pool.totalAssets(), 0);
        assertEq(pool.balanceOf(address(pool)), 0);
        assertEq(pool.withdrawalReserve(), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 100e6);

        uint256 bobShares = 50e6 * VS;
        usdc.mint(bob, 50e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 50e6);
        assertEq(pool.mint(bobShares, bob), 50e6);
        vm.stopPrank();

        assertEq(pool.totalSupply(), bobShares);
        assertEq(pool.totalAssets(), 50e6);
        assertEq(pool.withdrawalReserve(), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 150e6);

        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 100e6);
        assertEq(pool.totalAssets(), 50e6);
        assertEq(pool.withdrawalReserve(), 0);
        assertEq(usdc.balanceOf(address(pool)), 50e6);
        assertEq(pool.previewRedeem(pool.totalSupply()), 50e6);

        vm.prank(bob);
        pool.requestRedeem(bobShares);
        (, uint64 bobExitEpoch) = pool.exitRequests(bob);
        vm.warp(bobExitEpoch);
        vm.prank(bob);
        assertEq(pool.completeRedeem(bob), 50e6);

        assertEq(pool.totalSupply(), 0);
        assertEq(pool.totalAssets(), 0);
        assertEq(pool.withdrawalReserve(), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
    }

    function test_SettleMaturedExitEpochsRespectsCallerBatchSize() public {
        uint256 aliceShares = _stake(alice, 100e6);
        uint256 bobShares = _stake(bob, 100e6);

        vm.prank(alice);
        pool.requestRedeem(aliceShares);
        (, uint64 aliceExitEpoch) = pool.exitRequests(alice);

        vm.warp(block.timestamp + registry.exitTimingConfig().exitBatchInterval);
        vm.prank(bob);
        pool.requestRedeem(bobShares);
        (, uint64 bobExitEpoch) = pool.exitRequests(bob);
        assertGt(bobExitEpoch, aliceExitEpoch);

        vm.warp(bobExitEpoch);
        assertEq(pool.settleMaturedExitEpochs(1), 1);
        assertEq(pool.nextExitEpochIndex(), 1);
        (,, uint256 aliceRemainingShares,) = pool.exitEpochs(aliceExitEpoch);
        (,, uint256 bobRemainingShares,) = pool.exitEpochs(bobExitEpoch);
        assertGt(aliceRemainingShares, 0);
        assertEq(bobRemainingShares, 0);

        assertEq(pool.settleMaturedExitEpochs(1), 1);
        assertEq(pool.nextExitEpochIndex(), 2);
        (,, bobRemainingShares,) = pool.exitEpochs(bobExitEpoch);
        assertGt(bobRemainingShares, 0);
    }

    function test_ZeroAssetExitEpochUsesRemainingSharesAsSettlementSentinel() public {
        uint256 aliceShares = _stake(alice, 50e6);
        uint256 bobShares = _stake(bob, 50e6);
        vm.prank(alice);
        pool.requestRedeem(aliceShares);
        vm.prank(bob);
        pool.requestRedeem(bobShares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);
        (, uint64 bobExitEpoch) = pool.exitRequests(bob);
        assertEq(exitEpoch, bobExitEpoch);

        vm.prank(address(defi));
        pool.payClaim(carol, 100e6);
        vm.warp(exitEpoch);
        assertEq(pool.settleMaturedExitEpochs(1), 1);

        (uint256 totalShares, uint256 totalAssets, uint256 remainingShares, uint256 remainingAssets) =
            pool.exitEpochs(exitEpoch);
        assertEq(totalAssets, 0);
        assertEq(remainingShares, totalShares);
        assertEq(remainingAssets, 0);

        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 0);
        (,, remainingShares,) = pool.exitEpochs(exitEpoch);
        assertEq(remainingShares, bobShares);

        vm.prank(bob);
        assertEq(pool.completeRedeem(bob), 0);
        (,, remainingShares,) = pool.exitEpochs(exitEpoch);
        assertEq(remainingShares, 0);
        assertEq(pool.settleMaturedExitEpochs(1), 0);

        vm.prank(bob);
        vm.expectRevert(SingleAssetCoverPool.NoUnstakeRequest.selector);
        pool.completeRedeem(bob);
    }

    function test_CompleteRedeemAtExitEpochSucceeds() public {
        _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(100e6 * VS);
        (, uint64 exitEpoch) = pool.exitRequests(alice);
        vm.warp(exitEpoch);
        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 100e6);
    }

    function test_MaturedExitNeverExpiresAndCanRequestAgainAfterClaim() public {
        _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(100e6 * VS);

        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 100e6);

        uint256 shares = _stake(alice, 50e6);
        vm.prank(alice);
        pool.requestRedeem(shares);
        (uint256 requested,) = pool.exitRequests(alice);
        assertEq(requested, shares);
    }

    function test_SameEpochClaimsExactlyConsumeReserve() public {
        uint256 aliceShares = _stake(alice, 100e6);
        uint256 bobShares = _stake(bob, 50e6);

        vm.prank(alice);
        pool.requestRedeem(aliceShares);
        vm.prank(bob);
        pool.requestRedeem(bobShares);

        (, uint64 aliceExitEpoch) = pool.exitRequests(alice);
        (, uint64 bobExitEpoch) = pool.exitRequests(bob);
        assertEq(aliceExitEpoch, bobExitEpoch);

        // Fractional loss exercises per-user rounding; the last claimant receives
        // any residual so the epoch reserve is consumed exactly.
        vm.prank(address(defi));
        pool.payClaim(carol, 1e6 + 1);
        vm.warp(aliceExitEpoch);
        pool.settleMaturedExitEpochs(type(uint256).max);
        uint256 reserved = pool.withdrawalReserve();

        vm.prank(alice);
        uint256 aliceOut = pool.completeRedeem(alice);
        vm.prank(bob);
        uint256 bobOut = pool.completeRedeem(bob);

        assertEq(aliceOut + bobOut, reserved);
        assertEq(pool.withdrawalReserve(), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
    }

    function test_CompleteRedeemRejectsPoolAsReceiver() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);
        vm.warp(exitEpoch);

        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.InvalidRecipient.selector);
        pool.completeRedeem(address(pool));

        (uint256 pendingShares,) = pool.exitRequests(alice);
        assertEq(pendingShares, shares);
        assertEq(pool.withdrawalReserve(), 0, "failed claim did not settle persistently");
    }

    function test_CompleteUnstakeBlockedByActiveIncident() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.prank(alice);
        pool.requestRedeem(100e6 * VS);

        // Settle so the incident stays active through its correction/finalize phases
        // (otherwise it would void at the settlement deadline = 8d).
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(0)));

        (, uint64 exitEpoch) = pool.exitRequests(alice);
        vm.warp(exitEpoch);
        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.PoolFrozen.selector);
        pool.completeRedeem(alice);
    }

    function test_IncidentOpenedDuringCooldownHoldsExitUntilResolution() public {
        uint256 exitingShares = _stake(alice, 100e6);
        _stake(carol, 100e6);

        vm.prank(alice);
        pool.requestRedeem(exitingShares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);

        // Incident opens while Alice is still inside the cooldown.
        vm.warp(block.timestamp + 3 days);
        uint256 incidentOpenedAt = block.timestamp;
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        // Cooldown expiry cannot crystallize or release the exit while that
        // pre-expiry incident remains active.
        vm.warp(exitEpoch);
        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.PoolFrozen.selector);
        pool.completeRedeem(alice);
        assertEq(pool.withdrawalReserve(), 0);
        assertEq(pool.totalAssets(), 200e6);

        // Resolve with 40 USDC to the claimant plus the 10-USDC protocol fee.
        vm.warp(incidentOpenedAt + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + registry.incidentTimingConfig().phaseWindow + 1);
        _finalize(cid, amounts, 0);
        assertEq(defi.activeIncidentId(), 0);

        // Only now does settlement reserve Alice's post-loss pro-rata value.
        uint256 expectedAssets = pool.previewRedeem(exitingShares);
        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), expectedAssets);
        assertEq(expectedAssets, 75e6);
    }

    function test_IncidentResolvedBeforeExitEpochStillHaircutsExit() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);

        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + registry.incidentTimingConfig().phaseWindow + 1);
        _finalize(cid, amounts, 0);
        assertLt(block.timestamp, exitEpoch, "incident resolves inside cooldown");

        vm.warp(exitEpoch);
        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 50e6, "cooldown exit absorbs gross resolved incident loss");
    }

    function test_IncidentOpenedAtExitEpochReservesExitBeforeFreeze() public {
        uint256 shares = _stake(alice, 100e6);
        _stake(carol, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);

        vm.warp(exitEpoch);
        _registerClaim(bob, lp1, 50e18);

        assertEq(pool.totalAssets(), 100e6);
        assertEq(pool.withdrawalReserve(), 100e6);
        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 100e6, "pre-freeze reserve remains claimable");
    }

    // ════════════════════ Rewards (preserved behavior) ════════════════════

    function test_ProfitDistributionRevertsWithNoStakers() public {
        vm.startPrank(admin);
        usd8.mint(admin, 100e18);
        usd8.approve(address(pool), 100e18);
        vm.expectRevert(SingleAssetCoverPool.NoEligibleStakers.selector);
        pool.receiveProfitDistribution(100e18);
        vm.stopPrank();
    }

    function test_RewardAccruesProRata() public {
        _stake(alice, 100e6);
        _stake(bob, 100e6);
        _notify(70e18); // over 7d -> 10 USD8/day across 200 shares
        vm.warp(block.timestamp + DURATION);
        uint256 ea = pool.earned(alice);
        uint256 eb = pool.earned(bob);
        assertApproxEqAbs(ea, 35e18, 1e10);
        assertApproxEqAbs(eb, 35e18, 1e10);
    }

    function test_JITLatecomerOnlyGetsForwardSlice() public {
        _stake(alice, 100e6);
        _notify(70e18);
        vm.warp(block.timestamp + DURATION / 2);
        _stake(bob, 100e6); // joins halfway
        vm.warp(block.timestamp + DURATION / 2);

        uint256 ea = pool.earned(alice);
        uint256 eb = pool.earned(bob);
        // Alice: half stream solo + 1/2 of remaining half.
        // Bob:   only 1/2 of remaining half.
        assertApproxEqAbs(ea, 70e18 / 2 + 70e18 / 4, 1e10);
        assertApproxEqAbs(eb, 70e18 / 4, 1e10);
    }

    function test_PendingUnstakeStopsEarningImmediately() public {
        _stake(alice, 100e6);
        _stake(bob, 100e6);
        _notify(70e18);

        vm.warp(block.timestamp + 1 days);
        uint256 aliceAtRequest = pool.earned(alice);
        uint256 bobAtRequest = pool.earned(bob);

        vm.prank(alice);
        pool.requestRedeem(100e6 * VS);

        vm.warp(block.timestamp + 2 days);
        assertApproxEqAbs(pool.earned(alice), aliceAtRequest, 1e10, "exiting shares stop earning");
        assertApproxEqAbs(
            pool.earned(bob), bobAtRequest + (70e18 * 2 days / DURATION), 1e10, "active shares receive stream"
        );
    }

    function test_DustDonationDoesNotStretchRewardSchedule() public {
        _stake(alice, 100e6);
        _notify(70e18); // rate set, periodFinish = now + 7 days
        uint128 rate0 = pool.rewardRate();
        uint64 pf0 = pool.periodFinish();

        vm.warp(block.timestamp + 1 days);
        _notify(1); // 1-wei donation mid-stream

        uint128 rate1 = pool.rewardRate();
        uint64 pf1 = pool.periodFinish();
        // Dust must NOT reset periodFinish to a fresh full window.
        assertApproxEqAbs(uint256(pf1), uint256(pf0), 1 hours);
        // Rate barely moves — the funded stream isn't diluted.
        assertApproxEqRel(uint256(rate1), uint256(rate0), 1e15); // within 0.1%
    }

    // ════════════════════ Claim registration ════════════════════

    function test_RegisterClaimOpensIncident() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        assertEq(cid, 1);
        (IERC20 tok,,,, uint64 wEnd, bytes32 root, uint256 unresolved,,,) = defi.incidents(1);
        assertEq(address(tok), address(lp1));
        assertEq(wEnd, uint64(block.timestamp) + registry.incidentTimingConfig().phaseWindow);
        assertEq(root, bytes32(0));
        assertEq(unresolved, 1);
        assertEq(defi.activeIncidentId(), 1);
        // Still listed at open: delisting is deferred to root settlement.
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).maxCoverageBps, 8000);
        assertEq(lp1.balanceOf(address(defi)), 50e18);
    }

    function test_FirstClaimIdIsOne() public {
        assertEq(defi.nextClaimId(), 1); // starts at 1
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        assertEq(cid, 1); // first claim id is 1, NOT 2
        (address user,,,,,) = defi.claims(1);
        assertEq(user, bob); // record stored at claims[1]
        (address u2,,,,,) = defi.claims(2);
        assertEq(u2, address(0)); // claims[2] is empty
        assertEq(defi.nextClaimId(), 2); // now points at 2 for the next claim
    }

    function test_SecondClaimSameTokenJoinsIncident() public {
        _registerClaim(bob, lp1, 50e18);
        _registerClaim(carol, lp1, 30e18);
        (,,,,,, uint256 unresolved,,,) = defi.incidents(1);
        assertEq(unresolved, 2);
        assertEq(defi.nextIncidentId(), 2);
    }

    function test_ClaimBelowLegacyMinimumUsesBondInstead() public {
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));

        uint128 amount = 1;
        lp1.mint(bob, amount);
        vm.prank(admin);
        usd8.mint(bob, 10e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), amount);
        usd8.approve(address(defi), 10e18);
        uint256 claimId = defi.fileClaim(IERC20(address(lp1)), amount, 0, 0, 0, "");
        vm.stopPrank();

        (,, uint128 escrow,, uint128 bondAmount,) = defi.claims(claimId);
        assertEq(escrow, amount);
        assertEq(bondAmount, 10e18);
    }

    function test_FeeTokenClaimRecordsActualReceivedAmount() public {
        MockFeeToken feeToken = new MockFeeToken(100); // sends 99% of requested amount
        uint128 requested = 100e18;
        vm.startPrank(admin);
        defi.editInsuredToken(IERC20(address(feeToken)), 8000, FEED, address(0), "");
        defi.openClaimIncident(IERC20(address(feeToken)), uint64(block.number - 1));
        usd8.mint(bob, 10e18);
        vm.stopPrank();

        feeToken.mint(bob, requested);
        vm.startPrank(bob);
        feeToken.approve(address(defi), requested);
        usd8.approve(address(defi), 10e18);
        uint256 claimId = defi.fileClaim(IERC20(address(feeToken)), requested, 0, 0, 0, "");
        vm.stopPrank();

        (,, uint128 escrow,,,) = defi.claims(claimId);
        assertEq(escrow, 99e18);
        assertEq(feeToken.balanceOf(address(defi)), 99e18);
    }

    function test_OpenIncidentUnapprovedTokenReverts() public {
        MockERC20 lp3 = new MockERC20("LP3", "LP3", 18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InsuredTokenNotApproved.selector, IERC20(address(lp3))));
        defi.openClaimIncident(IERC20(address(lp3)), uint64(block.number - 1));
    }

    /// @dev An incident can't open unless this module is the registered
    ///      defiInsurance — else Registry.payoutIncidentActive() wouldn't freeze the pools.
    function test_OpenRevertsIfNotRegisteredDefiInsurance() public {
        vm.prank(admin);
        registry.setDefiInsurance(address(0)); // de-register (also the emergency brake)
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.DefiInsuranceNotRegistered.selector);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
    }

    /// @dev I1: a referenceBlock older than the configured maximum age is rejected, so
    ///      a stale (unrelayed) open attestation effectively expires.
    function test_OpenRejectsStaleReferenceBlock() public {
        vm.roll(1_000_000);
        uint64 maxAge = registry.incidentTimingConfig().maxReferenceBlockAge;
        assertEq(maxAge, 43_200); // ~6 days at 12-second blocks

        uint64 tooOld = uint64(block.number) - maxAge - 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InvalidReferenceBlock.selector, tooOld));
        defi.openClaimIncident(IERC20(address(lp1)), tooOld);

        // Exactly at the boundary is still fresh enough.
        uint64 justOld = uint64(block.number) - maxAge;
        vm.prank(admin);
        assertGt(defi.openClaimIncident(IERC20(address(lp1)), justOld), 0);
    }

    function test_FirstFileClaimRequiresTeeAuthorization() public {
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(0)));
        defi.fileClaim(IERC20(address(lp1)), 50e18, 0, 0, 0, "");
        vm.stopPrank();
    }

    /// @dev The first claimant atomically opens and files with TEE data; later claimants
    ///      use the same entrypoint with zero/empty open data.
    function test_FileClaimAtomicallyOpensThenLaterClaimantJoins() public {
        uint64 refBlock = uint64(block.number - 1);
        bytes memory sig = _teeSignOpen(address(lp1), refBlock);

        lp1.mint(bob, 50e18);
        _fundClaimBond(bob);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        uint256 cid = defi.fileClaim(IERC20(address(lp1)), 50e18, 0, 0, refBlock, sig);
        vm.stopPrank();

        uint256 id = defi.activeIncidentId();
        (IERC20 tok,, uint64 stored,,,,,,,) = defi.incidents(id);
        assertEq(address(tok), address(lp1));
        assertEq(stored, refBlock);
        assertEq(defi.claimIdByIncidentAndUser(id, bob), cid);

        lp1.mint(carol, 30e18);
        _fundClaimBond(carol);
        vm.startPrank(carol);
        lp1.approve(address(defi), 30e18);
        vm.expectRevert(DefiInsurance.UnexpectedOpenAttestation.selector);
        defi.fileClaim(IERC20(address(lp1)), 30e18, 0, 0, refBlock, sig);
        uint256 cid2 = defi.fileClaim(IERC20(address(lp1)), 30e18, 0, 0, 0, "");
        vm.stopPrank();
        assertEq(defi.claimIdByIncidentAndUser(id, carol), cid2);
    }

    function test_OpenSignatureIsInvalidatedByPricePolicyChange() public {
        uint64 refBlock = uint64(block.number - 1);
        bytes memory staleSig = _teeSignOpen(address(lp1), refBlock);

        vm.prank(admin);
        registry.setIncidentOpenPriceConfig(
            Registry.IncidentOpenPriceConfig({twapBlocks: 600, sampleStepBlocks: 60, minimumDropBps: 2_500})
        );

        vm.expectRevert();
        defi.fileClaim(IERC20(address(lp1)), 1, 0, 0, refBlock, staleSig);
    }

    function test_OpenSignatureIsInvalidatedByPcrRotation() public {
        uint64 refBlock = uint64(block.number - 1);
        bytes memory staleSig = _teeSignOpen(address(lp1), refBlock);

        vm.prank(admin);
        registry.setTeePcrHash(bytes32(uint256(0xBEEF)));

        vm.expectRevert();
        defi.fileClaim(IERC20(address(lp1)), 1, 0, 0, refBlock, staleSig);
    }

    /// @dev A TEE-open authorization signed by a non-TEE key reverts.
    function test_TeeOpenRejectsBadSig() public {
        uint64 refBlock = uint64(block.number - 1);
        bytes memory badSig = _signOpen(0xBAD, address(lp1), refBlock);

        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.UnauthorizedOpenSigner.selector, vm.addr(0xBAD)));
        defi.fileClaim(IERC20(address(lp1)), 1, 0, 0, refBlock, badSig);
    }

    function test_OpenIncidentOnlyAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, bob));
        vm.prank(bob);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
    }

    function test_OpenIncidentRejectsRegisteredPoolReentry() public {
        uint64 referenceBlock = uint64(block.number - 1);
        MockERC20 reentrantAsset = new MockERC20("REENTRANT", "REENTRANT", 18);
        ReentrantIncidentPool reentrantPool =
            new ReentrantIncidentPool(defi, IERC20(address(reentrantAsset)), IERC20(address(lp2)), referenceBlock);
        lp2.mint(address(reentrantPool), 50e18);
        reentrantPool.arm(50e18, _teeSignOpen(address(lp2), referenceBlock));

        vm.prank(admin);
        registry.addPool(address(reentrantPool), FEED);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), referenceBlock);

        assertTrue(reentrantPool.attempted());
        assertFalse(reentrantPool.reentrySucceeded());
        assertEq(
            reentrantPool.reentryReturndata(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(defi.nextIncidentId(), 2, "only one incident opened");
        assertEq(defi.activeIncidentId(), 1);
        (IERC20 insuredToken,,,,,,,,,) = defi.incidents(1);
        assertEq(address(insuredToken), address(lp1));
    }

    function test_JoiningActiveIncidentWithDifferentTokenRevertsWithMismatch() public {
        _registerClaim(bob, lp1, 50e18);

        lp2.mint(carol, 30e18);
        _fundClaimBond(carol);
        vm.startPrank(carol);
        lp2.approve(address(defi), 30e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                DefiInsurance.IncidentTokenMismatch.selector, uint256(1), IERC20(address(lp1)), IERC20(address(lp2))
            )
        );
        defi.fileClaim(IERC20(address(lp2)), 30e18, 0, 0, 0, "");
        vm.stopPrank();
    }

    function test_OneClaimPerAccountPerIncident() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18); // opens incident 1, bob joins

        // A second claim by bob in the same incident reverts.
        lp1.mint(bob, 20e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 20e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.DuplicateClaim.selector, uint256(1)));
        defi.fileClaim(IERC20(address(lp1)), 20e18, 0, 0, 0, "");
        vm.stopPrank();

        // After cancelling, bob may re-file within the window.
        vm.prank(bob);
        defi.cancelClaim();
        vm.startPrank(bob);
        lp1.approve(address(defi), 20e18);
        usd8.approve(address(defi), 10e18);
        uint256 cid2 = defi.fileClaim(IERC20(address(lp1)), 20e18, 0, 0, 0, "");
        vm.stopPrank();
        assertGt(cid2, cid);
    }

    function test_ClaimAfterWindowReverts() public {
        _registerClaim(bob, lp1, 50e18);
        (,,,, uint64 wEnd,,,,,) = defi.incidents(1);
        vm.warp(wEnd + 1);

        lp1.mint(carol, 30e18);
        vm.startPrank(carol);
        lp1.approve(address(defi), 30e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, IERC20(address(lp1)), wEnd));
        defi.fileClaim(IERC20(address(lp1)), 30e18, 0, 0, 0, "");
        vm.stopPrank();
    }

    function test_ClaimAfterRootCommittedRevertsDuringCorrectionWindow() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(1);
        vm.warp(claimDeadline + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(0)));

        lp1.mint(carol, 30e18);
        _fundClaimBond(carol);
        vm.startPrank(carol);
        lp1.approve(address(defi), 30e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentFinalizing.selector, uint256(1)));
        defi.fileClaim(IERC20(address(lp1)), 30e18, 0, 0, 0, "");
        vm.stopPrank();
    }

    function test_RelistedTokenOpensFreshIncident() public {
        uint256 cid1 = _registerClaim(bob, lp1, 50e18);
        // Settle a root: this is what delists lp1 (a confirmed event).
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, cid1, bob, _amounts(0)));
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).maxCoverageBps, 0); // delisted at root
        // Let incident 1 fully resolve (dispute + finalize windows elapse).
        vm.warp(block.timestamp + 2 days + 4 days + 1);

        // Delisted by settlement: governance must re-list before a new incident.
        vm.prank(admin);
        defi.editInsuredToken(IERC20(address(lp1)), 8000, FEED, address(0), "");
        uint256 cid = _registerClaim(carol, lp1, 30e18);
        (, uint256 incidentId,,,,) = defi.claims(cid);
        assertEq(incidentId, 2);
        assertEq(defi.activeIncidentId(), 2);
    }

    // ════════════════════ Cancel & withdraw ════════════════════

    function test_CancelClaimDuringWindowRefunds() public {
        _registerClaim(bob, lp1, 50e18);
        vm.prank(bob);
        defi.cancelClaim();
        assertEq(lp1.balanceOf(bob), 50e18);
        (,,,,,, uint256 unresolved,,,) = defi.incidents(1);
        assertEq(unresolved, 0); // join ++ then cancel -- back to zero
    }

    function test_CancelAfterWindowReverts() public {
        _registerClaim(bob, lp1, 50e18);
        (,,,, uint64 wEnd,,,,,) = defi.incidents(1);
        vm.warp(wEnd + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, IERC20(address(lp1)), wEnd));
        defi.cancelClaim();
    }

    function test_CancelAfterRootCommittedRevertsDuringCorrectionWindow() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(1);
        vm.warp(claimDeadline + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(0)));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentFinalizing.selector, uint256(1)));
        defi.cancelClaim();
    }

    function test_CancelByNonClaimantReverts() public {
        _registerClaim(bob, lp1, 50e18); // bob's claim; carol has none
        vm.prank(carol);
        vm.expectRevert(DefiInsurance.NoActiveClaim.selector);
        defi.cancelClaim();
    }

    function test_WithdrawClaimAfterVoidIncident() public {
        // No settlement root -> incident void at windowEnd + 3d.
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(cid, false, new uint256[](0), 0, 0, 0, new bytes32[](0));

        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
        assertEq(lp1.balanceOf(bob), 50e18);
    }

    function test_WithdrawClaimAfterFinalizeWindowExpires() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root = _leaf(1, cid, bob, _amounts(40e6));
        _settle(1, root);

        // Bob sleeps through the finalize window.
        vm.warp(block.timestamp + 3 days + 5 days + 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, false, _amounts(40e6), 1, 1, 50e18, new bytes32[](0));
        assertEq(lp1.balanceOf(bob), 50e18);
        // Payout portion stayed in the pool.
        assertEq(pool.totalAssets(), 100e6);
    }

    // ════════════════════ Settlement (root) ════════════════════

    function test_SettleIncidentAcceptsAdminRoot() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        bytes32 root = _leaf(1, cid, bob, _amounts(40e6));
        _settle(1, root);

        (,,,,, bytes32 storedRoot,,,,) = defi.incidents(1);
        assertEq(storedRoot, root);
        // amounts[] align to the (incident-stable) pool asset list.
        (IERC20[] memory list,) = registry.coverPools();
        assertEq(list.length, 1);
        assertEq(address(list[0]), address(usdc));
        uint256[] memory budget = defi.incidentPoolBudget(1);
        assertEq(budget.length, 1);
        assertEq(budget[0], pool.maxPayoutPerIncident());
    }

    function test_FinalizeClaimPaysSnapshottedProtocolShareFromGrossPoolBudget() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        (,,,,,,,,, uint16 feeShareBps) = defi.incidents(1);
        assertEq(feeShareBps, 2_000);

        vm.warp(block.timestamp + 5 days + 1);
        uint256 claimantAmount = 40e6;
        uint256 protocolFee = 10e6;
        uint256[] memory grossBudget = _amounts(claimantAmount + protocolFee);
        bytes32 root = _leaf(1, cid, bob, _amounts(claimantAmount));
        defi.settleIncident(root, grossBudget, _teeSign(1, root, grossBudget));

        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, true, _amounts(claimantAmount), 1, 1, 50e18, new bytes32[](0));

        assertEq(usdc.balanceOf(bob), claimantAmount);
        assertEq(usdc.balanceOf(admin), protocolFee);
        assertEq(pool.totalAssets(), 50e6);
        assertEq(defi.incidentPoolBudget(1)[0], 0);
    }

    function test_ClaimProtocolFeeRoundsDownAtOneBaseUnit() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory grossBudget = _amounts(1);
        bytes32 root = _leaf(1, cid, bob, _amounts(1));
        defi.settleIncident(root, grossBudget, _teeSign(1, root, grossBudget));

        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, true, _amounts(1), 1, 1, 50e18, new bytes32[](0));

        assertEq(usdc.balanceOf(bob), 1);
        assertEq(usdc.balanceOf(admin), 0);
        assertEq(pool.totalAssets(), 100e6 - 1);
    }

    function test_IncidentClaimFeeShareIsUnaffectedByLaterRegistryUpdate() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.prank(admin);
        registry.setProtocolFeeConfig(
            Registry.ProtocolFeeConfig({receiver: admin, claimProtocolFeeShareBps: 1_000, reserveYieldFeeBps: 2_000})
        );

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory grossBudget = _amounts(50e6);
        bytes32 root = _leaf(1, cid, bob, _amounts(40e6));
        defi.settleIncident(root, grossBudget, _teeSign(1, root, grossBudget));

        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, true, _amounts(40e6), 1, 1, 50e18, new bytes32[](0));

        assertEq(usdc.balanceOf(bob), 40e6);
        assertEq(usdc.balanceOf(admin), 10e6);
        assertEq(pool.totalAssets(), 50e6);
    }

    function test_ClaimProtocolFeeUsesLiveReceiver() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.prank(admin);
        registry.setProtocolFeeConfig(
            Registry.ProtocolFeeConfig({receiver: carol, claimProtocolFeeShareBps: 2_000, reserveYieldFeeBps: 2_000})
        );

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory grossBudget = _amounts(50e6);
        bytes32 root = _leaf(1, cid, bob, _amounts(40e6));
        defi.settleIncident(root, grossBudget, _teeSign(1, root, grossBudget));

        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, true, _amounts(40e6), 1, 1, 50e18, new bytes32[](0));

        assertEq(usdc.balanceOf(admin), 0);
        assertEq(usdc.balanceOf(carol), 10e6);
    }

    function test_SettleBeforeWindowEndReverts() public {
        _registerClaim(bob, lp1, 50e18);
        bytes32 root = bytes32(uint256(1));
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root, pp); // precompute: expectRevert binds to the next call
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.settleIncident(root, pp, sig);
    }

    function test_SettleAfterCutoffReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 3 days + 1); // past the settle cutoff → incident inactive/voided
        bytes32 root = bytes32(uint256(1));
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root, pp);
        // Past the cutoff the incident is no longer active, so it's rejected as
        // NotActiveIncident(0) (before the settle-phase check) — settling too EARLY still
        // reverts OutsideSettlementPhase.
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NotActiveIncident.selector, uint256(0)));
        defi.settleIncident(root, pp, sig);
    }

    /// @dev Settlement is single-shot: once a root is set, any repeat settlement reverts
    ///      AlreadySettled — same root, different root, or after finalize opens. A bad
    ///      root is handled by admin correction, not by overwrite. This also makes
    ///      settle/finalize trivially exclusive (no re-settle can collide with a payout).
    function test_SettleIsSingleShot() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1); // early in the settle window
        _settle(1, bytes32(uint256(1)));

        // A different root can't overwrite, still within the settle window.
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, bytes32(uint256(2)), pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.AlreadySettled.selector, uint256(1)));
        defi.settleIncident(bytes32(uint256(2)), pp, sig);

        // Nor after the correction window elapses (finalize open) while the settle window
        // is still open — the overlap that would have reset the budget mid-payout.
        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);
        sig = _teeSign(1, bytes32(uint256(2)), pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.AlreadySettled.selector, uint256(1)));
        defi.settleIncident(bytes32(uint256(2)), pp, sig);
    }

    function test_SettleZeroRootReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, bytes32(0), pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NoStandingRoot.selector, uint256(1)));
        defi.settleIncident(bytes32(0), pp, sig);
    }

    /// @dev During beta, an authorized correction to root zero voids a standing root,
    ///      unfreezes pools, blocks its proofs, and makes escrow immediately recoverable.
    function test_AdminCorrectionZeroRootVoidsStandingSettlement() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(50e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        uint256[] memory noPayouts = new uint256[](0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, alice));
        defi.adminCorrectSettlement(bytes32(0), noPayouts);
        vm.prank(admin);
        defi.adminCorrectSettlement(bytes32(0), noPayouts);
        assertEq(defi.activeIncidentId(), 0);

        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
        assertEq(lp1.balanceOf(bob), 50e18);
        assertEq(pool.totalAssets(), 100e6);
    }

    function test_AdminCorrectionRequiresStandingRoot() public {
        _registerClaim(bob, lp1, 50e18);
        uint256[] memory noPayouts = new uint256[](0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NoStandingRoot.selector, uint256(1)));
        defi.adminCorrectSettlement(bytes32(0), noPayouts);
    }

    function test_AdminCorrectionZeroRootRequiresEmptyPayouts() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(0)));

        uint256[] memory payouts = _pp();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.SettlementPoolMismatch.selector, uint256(1), uint256(0)));
        defi.adminCorrectSettlement(bytes32(0), payouts);
    }

    function test_AdminCorrectionBlockedOnceFinalizeWindowOpens() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(0)));
        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);
        uint256[] memory noPayouts = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentFinalizing.selector, uint256(1)));
        vm.prank(admin);
        defi.adminCorrectSettlement(bytes32(0), noPayouts);
    }

    /// @dev A late TEE root still receives its full correction window and cannot be
    ///      overwritten through the signed settlement path.
    function test_LateSubmissionCannotBeOverwritten() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(1);
        vm.warp(uint256(claimDeadline) + defi.incidentPhaseWindow(1)); // settle at the settlement deadline
        _settle(1, _leaf(1, cid, bob, _amounts(0)));

        // Already settled: no repeat settlement/overwrite (the root check precedes the phase check).
        vm.warp(block.timestamp + 1 days);
        bytes32 root9 = bytes32(uint256(9));
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root9, pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.AlreadySettled.selector, uint256(1)));
        defi.settleIncident(root9, pp, sig);
    }

    function test_CancelLastClaimAutoEndsAfterClaimWindow() public {
        _registerClaim(bob, lp1, 50e18); // opened via admin, bob joins
        vm.prank(bob);
        defi.cancelClaim();
        (,,,, uint64 windowEnd,,,,,) = defi.incidents(1);
        assertEq(defi.activeIncidentId(), 1);
        vm.warp(windowEnd + 1);
        assertEq(defi.activeIncidentId(), 0);
    }

    // ════════════════════ TEE-signed settlement ════════════════════

    uint256 constant TEE_PK = 0x7EE;
    uint256 constant SECOND_TEE_PK = 0x7EF;

    /// @dev Per-pool payout caps aligned to the current pool set — the max each pool
    ///      may commit, which always satisfies settleIncident's per-pool cap check.
    function _pp() internal view returns (uint256[] memory pp) {
        (, address[] memory poolAddrs) = registry.coverPools();
        pp = new uint256[](poolAddrs.length);
        for (uint256 i = 0; i < poolAddrs.length; i++) {
            pp[i] = SingleAssetCoverPool(poolAddrs[i]).maxPayoutPerIncident();
        }
    }

    /// @dev EIP-712 digest for Settlement over the incident's CURRENT on-chain
    ///      unresolved count and committed per-pool payouts — mirrors settleIncident.
    function _settlementDigest(uint256 incidentId, bytes32 root, uint256[] memory pp, bytes32 teePcrHash)
        internal
        view
        returns (bytes32)
    {
        (,,,,,, uint256 unresolved, bytes32 claimSetHash,,) = defi.incidents(incidentId);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("DefiInsurance")),
                keccak256(bytes("1")),
                block.chainid,
                address(defi)
            )
        );
        (, address[] memory poolAddrs) = registry.coverPools();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Settlement(uint256 incidentId,bytes32 root,uint256 unresolvedClaims,uint256[] poolPayouts,bytes32 pools,bytes32 claimSet,bytes32 teePcrHash)"
                ),
                incidentId,
                root,
                unresolved,
                keccak256(abi.encodePacked(pp)),
                keccak256(abi.encodePacked(poolAddrs)),
                claimSetHash,
                teePcrHash
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _teeSign(uint256 incidentId, bytes32 root, uint256[] memory pp) internal view returns (bytes memory) {
        return _signSettlement(TEE_PK, incidentId, root, pp);
    }

    function _incidentTeePcrHash(uint256 incidentId) internal view returns (bytes32 teePcrHash) {
        (,,,,,,,, teePcrHash,) = defi.incidents(incidentId);
    }

    function _signSettlement(uint256 privateKey, uint256 incidentId, bytes32 root, uint256[] memory pp)
        internal
        view
        returns (bytes memory)
    {
        return _signSettlementWithPcr(privateKey, incidentId, root, pp, _incidentTeePcrHash(incidentId));
    }

    function _signSettlementWithPcr(
        uint256 privateKey,
        uint256 incidentId,
        bytes32 root,
        uint256[] memory pp,
        bytes32 teePcrHash
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, _settlementDigest(incidentId, root, pp, teePcrHash));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Finalize a single-claim incident as its owner. The incident's root was
    ///      settled as that claim's leaf, so a single leaf's merkle root == the leaf
    ///      and the proof is empty.
    function _finalize(uint256 claimId, uint256[] memory amounts, uint256 scoreSpent) internal {
        (address user,, uint128 escrow,,,) = defi.claims(claimId);
        if (scoreSpent == 0) scoreSpent = 1;
        vm.prank(user);
        defi.finalizeClaim(claimId, true, amounts, scoreSpent, scoreSpent, escrow, new bytes32[](0));
    }

    /// @dev EIP-712 IncidentOpen signature over token, referenceBlock,
    ///      nextIncidentId, and current PCR — mirrors first-claim fileClaim verification.
    function _teeSignOpen(address token, uint64 referenceBlock) internal view returns (bytes memory) {
        return _signOpen(TEE_PK, token, referenceBlock);
    }

    /// @dev Same open digest signed with an arbitrary key (for the bad-signer path).
    function _signOpen(uint256 pk, address token, uint64 referenceBlock) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("DefiInsurance")),
                keccak256(bytes("1")),
                block.chainid,
                address(defi)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "IncidentOpen(address insuredToken,uint64 referenceBlock,uint256 incidentId,bytes32 teePcrHash,bytes32 eligibilityHash)"
                ),
                token,
                referenceBlock,
                defi.nextIncidentId(),
                registry.teePcrHash(),
                defi.incidentOpenEligibilityHash(IERC20(token))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Open an incident claim-lessly on token through the trusted admin fallback.
    ///      Permissionless opening occurs atomically in first-claim `fileClaim`.
    function _openSigned(address token, uint64 referenceBlock) internal returns (uint256) {
        vm.prank(admin);
        return defi.openClaimIncident(IERC20(token), referenceBlock);
    }

    function test_SetTeeSignerManagesIndependentAuthorizations() public {
        address first = vm.addr(TEE_PK);
        address second = vm.addr(SECOND_TEE_PK);

        assertTrue(defi.isTeeSigner(first));
        assertFalse(defi.isTeeSigner(second));

        vm.prank(admin);
        defi.setTeeSigner(second, true);
        assertTrue(defi.isTeeSigner(first));
        assertTrue(defi.isTeeSigner(second));

        vm.prank(admin);
        defi.setTeeSigner(first, false);
        assertFalse(defi.isTeeSigner(first));
        assertTrue(defi.isTeeSigner(second));

        vm.prank(admin);
        vm.expectRevert(SharedBase.ZeroAddress.selector);
        defi.setTeeSigner(address(0), true);
    }

    /// @dev L5: the signer set can't be changed while an incident is live, so the
    ///      exact 1-of-N authorization set present at open remains through settlement.
    function test_SetTeeSignerBlockedDuringIncident() public {
        _registerClaim(bob, lp1, 50e18); // opens incident 1

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentsActive.selector));
        defi.setTeeSigner(vm.addr(SECOND_TEE_PK), true);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentsActive.selector));
        defi.setTeeSigner(vm.addr(TEE_PK), false);

        assertTrue(defi.isTeeSigner(vm.addr(TEE_PK)));
        assertFalse(defi.isTeeSigner(vm.addr(SECOND_TEE_PK)));

        // Once the incident voids, additions and revocations are allowed again.
        vm.warp(block.timestamp + 5 days + 3 days + 1); // past claim + settlement window
        vm.prank(admin);
        defi.setTeeSigner(vm.addr(SECOND_TEE_PK), true);
        vm.prank(admin);
        defi.setTeeSigner(vm.addr(TEE_PK), false);
        assertTrue(defi.isTeeSigner(vm.addr(SECOND_TEE_PK)));
        assertFalse(defi.isTeeSigner(vm.addr(TEE_PK)));
    }

    function test_MultipleTeeSignersAreOneOfNForOpenAndSettlement() public {
        address second = vm.addr(SECOND_TEE_PK);
        vm.prank(admin);
        defi.setTeeSigner(second, true);

        assertTrue(defi.isTeeSigner(vm.addr(TEE_PK)));
        assertTrue(defi.isTeeSigner(second));

        // The second authorized enclave authorizes the first filing while the original remains authorized.
        uint64 refBlock = uint64(block.number - 1);
        bytes memory openSig = _signOpen(SECOND_TEE_PK, address(lp1), refBlock);

        lp1.mint(bob, 50e18);
        _fundClaimBond(bob);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        uint256 cid = defi.fileClaim(IERC20(address(lp1)), 50e18, 0, 0, refBlock, openSig);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root = _leaf(1, cid, bob, _amounts(0));
        uint256[] memory pp = _pp();

        // The same second enclave may also authorize settlement; the caller is only
        // a permissionless relay and need not itself be in the signer set.
        bytes memory settlementSig = _signSettlement(SECOND_TEE_PK, 1, root, pp);
        vm.prank(carol);
        defi.settleIncident(root, pp, settlementSig);
        (,,,,, bytes32 stored,,,,) = defi.incidents(1);
        assertEq(stored, root);
    }

    function test_SettleIncidentSignedByAnyone() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        bytes32 root = _leaf(1, cid, bob, _amounts(0));
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root, pp);
        vm.prank(carol); // permissionless relay
        defi.settleIncident(root, pp, sig);
        (,,,,, bytes32 stored,,,,) = defi.incidents(1);
        assertEq(stored, root);
    }

    function test_DeregisteredModuleCannotSettleAfterEmergencyRegistryChange() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        assertEq(_incidentTeePcrHash(1), TEST_TEE_PCR_HASH);

        vm.startPrank(admin);
        registry.setDefiInsurance(address(0));
        registry.setTeePcrHash(UPDATED_TEE_PCR_HASH);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root = _leaf(1, cid, bob, _amounts(0));
        uint256[] memory pp = _pp();
        bytes memory sig = _signSettlementWithPcr(TEE_PK, 1, root, pp, TEST_TEE_PCR_HASH);
        vm.expectRevert(DefiInsurance.DefiInsuranceNotRegistered.selector);
        defi.settleIncident(root, pp, sig);

        (,,,,, bytes32 stored,,,,) = defi.incidents(1);
        assertEq(stored, bytes32(0));

        vm.prank(bob);
        defi.finalizeClaim(cid, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
        assertEq(lp1.balanceOf(bob), 50e18);
    }

    function test_DeregisteredModuleCannotAcceptClaimJoins() public {
        _registerClaim(bob, lp1, 50e18);
        _prepareClaimant(carol, lp1, 10e18);

        uint256 nextClaimBefore = defi.nextClaimId();
        uint256 moduleLpBefore = lp1.balanceOf(address(defi));
        uint256 moduleBondBefore = usd8.balanceOf(address(defi));
        (,,,,,, uint256 unresolvedBefore, bytes32 claimSetBefore,,) = defi.incidents(1);

        vm.prank(admin);
        registry.setDefiInsurance(address(0));

        vm.expectRevert(DefiInsurance.DefiInsuranceNotRegistered.selector);
        vm.prank(carol);
        defi.fileClaim(IERC20(address(lp1)), 10e18, 0, 0, 0, "");

        assertEq(defi.nextClaimId(), nextClaimBefore);
        assertEq(defi.claimIdByIncidentAndUser(1, carol), 0);
        assertEq(lp1.balanceOf(carol), 10e18);
        assertEq(lp1.balanceOf(address(defi)), moduleLpBefore);
        assertEq(usd8.balanceOf(address(defi)), moduleBondBefore);
        (,,,,,, uint256 unresolvedAfter, bytes32 claimSetAfter,,) = defi.incidents(1);
        assertEq(unresolvedAfter, unresolvedBefore);
        assertEq(claimSetAfter, claimSetBefore);
    }

    function test_DeregisteredModuleCannotCorrectSettlement() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        bytes32 originalRoot = _leaf(1, cid, bob, _amounts(0));
        uint256[] memory pp = _pp();
        defi.settleIncident(originalRoot, pp, _teeSign(1, originalRoot, pp));

        vm.prank(admin);
        registry.setDefiInsurance(address(0));

        bytes32 correctedRoot = keccak256("stale-module-correction");
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.DefiInsuranceNotRegistered.selector);
        defi.adminCorrectSettlement(correctedRoot, pp);

        (,,,,, bytes32 storedRoot,,,,) = defi.incidents(1);
        assertEq(storedRoot, originalRoot);
    }

    function test_WithdrawnClaimCannotAlsoBeCancelled() public {
        uint256 bobClaim = _registerClaim(bob, lp1, 50e18);
        _registerClaim(carol, lp1, 50e18);

        vm.prank(admin);
        registry.setDefiInsurance(address(0));

        vm.prank(bob);
        defi.finalizeClaim(bobClaim, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
        assertEq(
            defi.claimIdByIncidentAndUser(1, bob), bobClaim, "withdrawn claim remains discoverable by incident and user"
        );

        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimAlreadyResolved.selector, bobClaim));
        vm.prank(bob);
        defi.cancelClaim();

        assertEq(lp1.balanceOf(address(defi)), 50e18, "other claimant escrow remains protected");
    }

    function test_SettlementSignatureBindsTeePcrHash() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        bytes32 root = _leaf(1, cid, bob, _amounts(0));
        uint256[] memory pp = _pp();
        bytes memory sig = _signSettlementWithPcr(TEE_PK, 1, root, pp, UPDATED_TEE_PCR_HASH);

        vm.expectPartialRevert(DefiInsurance.UnauthorizedSettlementSigner.selector);
        defi.settleIncident(root, pp, sig);
    }

    function test_SettleSignedWrongSignerReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root = bytes32(uint256(1));
        uint256[] memory pp = _pp();
        bytes memory sig = _signSettlement(0xBAD, 1, root, pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.UnauthorizedSettlementSigner.selector, vm.addr(0xBAD)));
        defi.settleIncident(root, pp, sig);
    }

    function test_SettleSignedDisabledWhenSignerUnset() public {
        vm.prank(admin);
        defi.setTeeSigner(vm.addr(TEE_PK), false); // empty set disables the signed path
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root = bytes32(uint256(1));
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root, pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.UnauthorizedSettlementSigner.selector, vm.addr(TEE_PK)));
        defi.settleIncident(root, pp, sig);
    }

    /// @dev The signature binds the exact claim set: a root signed before a
    ///      later join (different unresolved count) can never land.
    function test_SettleSignedBindsClaimSet() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        bytes32 root = _leaf(1, cid, bob, _amounts(0));
        uint256[] memory pp = _pp();
        bytes memory staleSig = _teeSign(1, root, pp); // signed over unresolved == 1

        _registerClaim(carol, lp1, 10e18); // claim set grows
        vm.warp(block.timestamp + 5 days + 1);
        vm.expectPartialRevert(DefiInsurance.UnauthorizedSettlementSigner.selector);
        defi.settleIncident(root, pp, staleSig);
    }

    function test_ClaimBondAmountIsConfigurableAndSnapshottedInClaim() public {
        assertEq(defi.claimBondAmount(), 10e18);
        vm.prank(bob);
        vm.expectRevert();
        defi.setClaimBondAmount(25e18);
        vm.prank(admin);
        defi.setClaimBondAmount(25e18);

        _openSigned(address(lp1), uint64(block.number - 1));
        (IERC20 insuredToken,,,, uint64 claimDeadline,,,, bytes32 teePcrHash,) = defi.incidents(1);
        assertEq(address(insuredToken), address(lp1));
        assertGt(claimDeadline, block.timestamp);
        assertEq(teePcrHash, TEST_TEE_PCR_HASH);
        address[] memory incidentPools = defi.incidentPools(1);
        assertEq(incidentPools.length, 1);
        assertEq(incidentPools[0], address(pool));
        uint256[] memory incidentPoolBudget = defi.incidentPoolBudget(1);
        assertEq(incidentPoolBudget.length, 0);

        lp1.mint(bob, 1);
        vm.prank(admin);
        usd8.mint(bob, 25e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 1);
        usd8.approve(address(defi), 25e18);
        uint256 claimId = defi.fileClaim(IERC20(address(lp1)), 1, 0, 0, 0, "");
        vm.stopPrank();

        (,,,, uint128 storedBondAmount,) = defi.claims(claimId);
        assertEq(storedBondAmount, 25e18);
    }

    // ════════════════════ Finalize ════════════════════

    function test_ThirdPartyResolvesZeroScoreClaimAndForfeitsBond() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory amounts = _amounts(0);
        _settle(1, _leafSpent(1, cid, bob, amounts, 0, 0, 50e18));
        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);

        vm.prank(carol);
        defi.finalizeClaim(cid, false, amounts, 0, 0, 50e18, new bytes32[](0));

        assertEq(lp1.balanceOf(bob), 50e18);
        assertEq(usd8.balanceOf(bob), 0);
        assertEq(usd8.balanceOf(carol), 0);
        assertEq(usd8.balanceOf(registry.treasury()), 10e18);
        (,,,,, bool resolved) = defi.claims(cid);
        assertTrue(resolved);
    }

    function test_ThirdPartyResolvesZeroEligibleAmountClaimAndForfeitsBond() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory amounts = _amounts(0);
        _settle(1, _leafSpent(1, cid, bob, amounts, 1, 1, 0));
        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);

        vm.prank(carol);
        defi.finalizeClaim(cid, false, amounts, 1, 1, 0, new bytes32[](0));

        assertEq(lp1.balanceOf(bob), 50e18);
        assertEq(usd8.balanceOf(bob), 0);
        assertEq(usd8.balanceOf(carol), 0);
        assertEq(usd8.balanceOf(registry.treasury()), 10e18);
        (,,,,, bool resolved) = defi.claims(cid);
        assertTrue(resolved);
    }

    function test_ThirdPartyCannotResolveBondEligibleClaim() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory amounts = _amounts(0);
        _settle(1, _leafSpent(1, cid, bob, amounts, 1, 1, 50e18));
        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.UnauthorizedClaim.selector, cid));
        defi.finalizeClaim(cid, false, amounts, 1, 1, 50e18, new bytes32[](0));
    }

    function test_FinalizeDeclineRefundsEligibleBondWithoutAcceptingPayout() public {
        _stake(alice, 100e6);
        lp1.mint(bob, 1);
        vm.prank(admin);
        usd8.mint(bob, 10e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 1);
        usd8.approve(address(defi), 10e18);
        uint256 cid = defi.fileClaim(
            IERC20(address(lp1)),
            1,
            1,
            0,
            uint64(block.number - 1),
            _teeSignOpen(address(lp1), uint64(block.number - 1))
        );
        vm.stopPrank();

        assertEq(usd8.balanceOf(address(defi)), 10e18);
        (,,,, uint128 storedBondAmount,) = defi.claims(cid);
        assertEq(storedBondAmount, 10e18);

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leafSpent(1, cid, bob, amounts, 1, 1, 1));
        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);

        vm.prank(bob);
        defi.finalizeClaim(cid, false, amounts, 1, 1, 1, new bytes32[](0));

        assertEq(lp1.balanceOf(bob), 1);
        assertEq(usd8.balanceOf(bob), 10e18);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(registry.scoreSpent(bob), 0);
        (,,,,, bool resolved) = defi.claims(cid);
        assertTrue(resolved);
    }

    function test_FinalizeIneligibleClaimSendsForfeitedBondToTreasury() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory amounts = _amounts(0);
        _settle(1, _leafSpent(1, cid, bob, amounts, 0, 0, 0));
        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);

        vm.prank(bob);
        defi.finalizeClaim(cid, false, amounts, 0, 0, 0, new bytes32[](0));

        assertEq(lp1.balanceOf(bob), 50e18);
        assertEq(usd8.balanceOf(bob), 0);
        assertEq(usd8.balanceOf(address(defi)), 0);
        assertEq(usd8.balanceOf(registry.treasury()), 10e18);
    }

    function test_FinalizeSingleClaim() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory amounts = _amounts(20e6);
        bytes32 root = _leaf(1, cid, bob, amounts);
        _settle(1, root);

        // Not open during the correction window.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(cid, true, amounts, 1, 1, 50e18, new bytes32[](0));

        vm.warp(block.timestamp + 4 days + 1);
        _finalize(cid, amounts, 0);

        assertEq(usdc.balanceOf(bob), 20e6);
        assertEq(usd8.balanceOf(bob), 10e18); // eligible bond refunded on acceptance
        assertEq(pool.totalAssets(), 75e6);
        // Forfeited insured tokens stay in the contract as unaccounted revenue.
        assertEq(lp1.balanceOf(address(defi)), 50e18);
    }

    function test_FinalizeTwoClaimantsMerkle() public {
        _stake(alice, 300e6);
        uint256 cb = _registerClaim(bob, lp1, 50e18);
        uint256 cc = _registerClaim(carol, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory amountsBob = _amounts(40e6);
        uint256[] memory amountsCarol = _amounts(20e6);
        // Two-leaf merkle tree; each claimant finalizes with the sibling as proof.
        bytes32 leafBob = _leaf(1, cb, bob, amountsBob);
        bytes32 leafCarol = _leaf(1, cc, carol, amountsCarol);
        _settle(1, _hashPair(leafBob, leafCarol));
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory proofBob = new bytes32[](1);
        proofBob[0] = leafCarol;
        vm.prank(bob);
        defi.finalizeClaim(cb, true, amountsBob, 1, 1, 50e18, proofBob);

        bytes32[] memory proofCarol = new bytes32[](1);
        proofCarol[0] = leafBob;
        vm.prank(carol);
        defi.finalizeClaim(cc, true, amountsCarol, 1, 1, 50e18, proofCarol);

        assertEq(usdc.balanceOf(bob), 40e6);
        assertEq(usdc.balanceOf(carol), 20e6);
        assertEq(pool.totalAssets(), 225e6);
    }

    /// @dev F1: on an honest root the committed budget == the grossed Σ leaf amounts, so the
    ///      per-incident draw-down lands exactly at 0 and BOTH claims finalize — no
    ///      last-finalizer stranding.
    function test_FinalizeBudgetExactSumAllFinalize() public {
        _stake(alice, 300e6); // cap = 240e6
        uint256 cb = _registerClaim(bob, lp1, 50e18);
        uint256 cc = _registerClaim(carol, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory aB = _amounts(40e6);
        uint256[] memory aC = _amounts(40e6);
        bytes32 lB = _leaf(1, cb, bob, aB);
        bytes32 lC = _leaf(1, cc, carol, aC);
        bytes32 root = _hashPair(lB, lC);
        uint256[] memory pp = new uint256[](1);
        pp[0] = 100e6; // == gross(40) + gross(40)
        defi.settleIncident(root, pp, _teeSign(1, root, pp));
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory pB = new bytes32[](1);
        pB[0] = lC;
        vm.prank(bob);
        defi.finalizeClaim(cb, true, aB, 1, 1, 50e18, pB);
        bytes32[] memory pC = new bytes32[](1);
        pC[0] = lB;
        vm.prank(carol);
        defi.finalizeClaim(cc, true, aC, 1, 1, 50e18, pC);

        assertEq(usdc.balanceOf(bob), 40e6);
        assertEq(usdc.balanceOf(carol), 40e6);
    }

    /// @dev F1: a malformed root whose leaves over-allocate a pool (gross Σ 100e6 >
    ///      committed 50e6) can't drain past the committed budget — the early claim
    ///      pays, the draw-down hard-caps the pool's total loss at 50e6, and the
    ///      claim that would cross it reverts (recovers escrow, doesn't get paid).
    function test_FinalizeBudgetCapsCumulativePayout() public {
        _stake(alice, 300e6); // cap = 240e6, so 50e6 committed passes settle
        uint256 cb = _registerClaim(bob, lp1, 50e18);
        uint256 cc = _registerClaim(carol, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory aB = _amounts(40e6);
        uint256[] memory aC = _amounts(40e6);
        bytes32 lB = _leaf(1, cb, bob, aB);
        bytes32 lC = _leaf(1, cc, carol, aC);
        bytes32 root = _hashPair(lB, lC);
        uint256[] memory pp = new uint256[](1);
        pp[0] = 50e6; // committed BELOW the 80e6 leaf sum — a bad root
        defi.settleIncident(root, pp, _teeSign(1, root, pp));
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory pB = new bytes32[](1);
        pB[0] = lC;
        vm.prank(bob);
        defi.finalizeClaim(cb, true, aB, 1, 1, 50e18, pB); // gross budget 50e6 -> 0

        bytes32[] memory pC = new bytes32[](1);
        pC[0] = lB;
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.PayoutCapExceeded.selector, 0, 50e6, 0));
        defi.finalizeClaim(cc, true, aC, 1, 1, 50e18, pC); // gross 50e6 > 0 remaining

        assertEq(usdc.balanceOf(bob), 40e6); // early claim paid
        assertEq(usdc.balanceOf(carol), 0); // late claim capped out; recovers escrow later
        assertEq(pool.totalAssets(), 250e6); // pool lost exactly the 50e6 gross budget
    }

    /// @dev A claim that over-escrows (escrow > signed eligible) is refunded the
    ///      excess on finalize: only `eligible` is forfeited, the full escrow leaves
    ///      the escrow ledger, and the remainder is returned to the claimant. A leaf
    ///      whose eligible exceeds the escrow reverts EligibleExceedsEscrow.
    function test_FinalizeRefundsOverEscrow() public {
        _stake(alice, 300e6);
        // bob escrows E = 100e18 but is only eligible for E/2; carol's leaf is
        // malformed (eligible 100e18 > her 50e18 escrow) to prove the guard.
        uint256 cb = _registerClaim(bob, lp1, 100e18);
        uint256 cc = _registerClaim(carol, lp1, 50e18);
        assertEq(defi.escrowedInsuredTokens(IERC20(address(lp1))), 150e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory aB = _amounts(20e6);
        uint256[] memory aC = _amounts(10e6);
        bytes32 lB = _leafSpent(1, cb, bob, aB, 1, 1, 50e18); // eligible = E/2
        bytes32 lC = _leafSpent(1, cc, carol, aC, 1, 1, 100e18); // eligible > escrow
        _settle(1, _hashPair(lB, lC));
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory pB = new bytes32[](1);
        pB[0] = lC;
        vm.prank(bob);
        defi.finalizeClaim(cb, true, aB, 1, 1, 50e18, pB);

        // Refund = escrow − eligible = 50e18; the full 100e18 left the escrow ledger.
        assertEq(lp1.balanceOf(bob), 50e18);
        assertEq(usdc.balanceOf(bob), 20e6); // payout still delivered
        assertEq(defi.escrowedInsuredTokens(IERC20(address(lp1))), 50e18); // only carol's escrow left

        // eligible above escrow is rejected (guards a malformed leaf).
        bytes32[] memory pC = new bytes32[](1);
        pC[0] = lB;
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.EligibleExceedsEscrow.selector, 100e18, 50e18));
        defi.finalizeClaim(cc, true, aC, 1, 1, 100e18, pC);
    }

    function test_FinalizeWrongAmountsReverts() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(40e6)));
        vm.warp(block.timestamp + 4 days + 1);

        // Root commits to 40e6 (single leaf); finalizing 90e6 fails the merkle check.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InvalidProof.selector, cid));
        defi.finalizeClaim(cid, true, _amounts(90e6), 1, 1, 50e18, new bytes32[](0));
    }

    function test_FinalizeTwiceReverts() public {
        _stake(alice, 200e6);
        uint256 cb = _registerClaim(bob, lp1, 50e18);
        uint256 cc = _registerClaim(carol, lp1, 50e18); // keeps the incident active after bob finalizes
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory aB = _amounts(40e6);
        bytes32 leafB = _leaf(1, cb, bob, aB);
        bytes32 leafC = _leaf(1, cc, carol, _amounts(20e6));
        _settle(1, _hashPair(leafB, leafC));
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = leafC;
        vm.prank(bob);
        defi.finalizeClaim(cb, true, aB, 1, 1, 50e18, proofB);

        // Second finalize by bob: his claim is resolved, but carol's keeps the incident
        // active so the claim is still derivable and the resolved guard fires.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimAlreadyResolved.selector, cb));
        defi.finalizeClaim(cb, true, aB, 1, 1, 50e18, proofB);
    }

    function test_PayoutExceedingPoolBalanceReverts() public {
        // Root says pay 500 USDC but the pool only holds 100 (cap = 80). An honest
        // root never over-allocates, so this is a corrupt root: the per-incident
        // budget draw-down catches it first and fails the finalize loudly — bob
        // recovers his escrow by declining via finalizeClaim. (_settle commits
        // poolPayouts = maxPayoutPerIncident() = 80e6 via _pp.)
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(500e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);

        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.PayoutCapExceeded.selector, 0, 625e6, 80e6));
        vm.prank(bob);
        defi.finalizeClaim(cid, true, amounts, 1, 1, 50e18, new bytes32[](0));

        // Escrow recoverable once the finalize window lapses.
        vm.warp(block.timestamp + 4 days + 4 days + 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, false, amounts, 1, 1, 50e18, new bytes32[](0));
        assertEq(lp1.balanceOf(bob), 50e18);
        assertEq(pool.totalAssets(), 100e6); // pool untouched
    }

    function test_StakeBlockedDuringIncidentThenResumes() public {
        _stake(alice, 100e6);
        _registerClaim(bob, lp1, 50e18); // opens incident 1

        usdc.mint(carol, 100e6);
        vm.startPrank(carol);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, carol, 100e6, 0));
        pool.deposit(100e6, carol);
        vm.stopPrank();

        // Incident voids after the correction window -> staking reopens.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(carol);
        pool.deposit(100e6, carol);
        assertGt(pool.balanceOf(carol), 0);
    }

    function test_MintBlockedDuringIncidentUsesMaxMint() public {
        _stake(alice, 100e6);
        _registerClaim(bob, lp1, 50e18);

        uint256 shares = 1e18;
        usdc.mint(carol, 1e6);
        vm.startPrank(carol);
        usdc.approve(address(pool), 1e6);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, carol, shares, 0));
        pool.mint(shares, carol);
        vm.stopPrank();
    }

    /// @dev Finalizing the last claim unlocks the pool immediately.
    function test_AllClaimsFinalizedUnlocksPoolEarly() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18); // incident 1, one claim
        vm.warp(block.timestamp + 5 days + 1); // claim window ends
        _settle(1, _leaf(1, cid, bob, _amounts(40e6)));

        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1); // into the finalize window
        _finalize(cid, _amounts(40e6), 0);

        // Last claim finalized: incident inactive well before FINALIZE_WINDOW ends.
        assertEq(defi.activeIncidentId(), 0);
        usdc.mint(carol, 100e6);
        vm.startPrank(carol);
        usdc.approve(address(pool), 100e6);
        pool.deposit(100e6, carol); // no PoolFrozen revert
        vm.stopPrank();
        assertGt(pool.balanceOf(carol), 0);
    }

    // This test contract acts as a payout module in a few tests; it must answer
    // activeIncidentId() (0 = pool not frozen, so staking stays open).
    function activeIncidentId() external pure returns (uint256) {
        return 0;
    }

    function test_PayClaimOnlyByModule() public {
        _stake(alice, 100e6);
        // bob is not the registered payout module.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SingleAssetCoverPool.NotDefiInsurance.selector, bob));
        pool.payClaim(address(0xdead), 10e6);
    }

    /// @dev L-d: payClaim to the pool itself is rejected (would silently convert
    ///      staker principal into sweepable surplus).
    function test_PayClaimRejectsPoolAsRecipient() public {
        _stake(alice, 100e6);
        vm.prank(admin);
        registry.setDefiInsurance(address(this));
        vm.expectRevert(SingleAssetCoverPool.InvalidRecipient.selector);
        pool.payClaim(address(pool), 10e6);
    }

    /// @dev L-a: pausing DefiInsurance blocks claim intake, but escrow recovery
    ///      (declining via finalizeClaim) must stay open so a pause can't trap funds.
    function test_DefiPauseBlocksIntakeNotEscrowRecovery() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18); // opens incident 1, bob escrows
        vm.prank(admin);
        registry.setPaused(address(defi), true);

        // Intake blocked.
        lp1.mint(carol, 50e18);
        vm.startPrank(carol);
        lp1.approve(address(defi), 50e18);
        vm.expectRevert(Registry.Paused.selector);
        defi.fileClaim(IERC20(address(lp1)), 50e18, 0, 0, 0, "");
        vm.stopPrank();

        // Void the incident, then recover escrow despite the pause.
        vm.warp(block.timestamp + 5 days + 3 days + 1); // past settlement deadline → void
        vm.prank(bob);
        defi.finalizeClaim(cid, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
        assertEq(lp1.balanceOf(bob), 50e18);
    }

    function test_FullyDrainedAssetStaysStakeable() public {
        _stake(alice, 100e6); // 100e6 * VS shares

        // Drain usdc to exactly zero via a payout, leaving alice's shares outstanding.
        // This contract becomes the single payout module (activeIncidentId()==0,
        // so the pool isn't frozen and staking stays open).
        vm.prank(admin);
        registry.setDefiInsurance(address(this));
        pool.payClaim(address(0xdead), 100e6);
        assertEq(pool.totalAssets(), 0);
        assertGt(pool.totalSupply(), 0);

        // Recapitalization must not revert (would div-by-zero pre-fix). With totalAssets
        // drained to 0, the ERC-4626 conversion mints received * (totalSupply + VS), so
        // fresh capital recovers its full stake; the pre-drain shares stay worthless
        // (fully haircut by the payout).
        uint256 minted = _stake(carol, 50e6);
        assertEq(minted, 50e6 * (100e6 * VS + VS));

        vm.startPrank(carol);
        pool.requestRedeem(minted);
        (, uint64 exitEpoch) = pool.exitRequests(carol);
        vm.warp(exitEpoch);
        uint256 out = pool.completeRedeem(carol);
        vm.stopPrank();
        assertEq(out, 50e6);
    }

    /// @dev payClaim can't pay more than the pool holds; the per-incident cap is
    ///      enforced up front at settle (see test_SettleRejectsPayoutAboveCap), not here.
    function test_PayClaimCannotExceedBalance() public {
        _stake(alice, 100e6);
        vm.prank(admin);
        registry.setDefiInsurance(address(this));

        vm.expectRevert(abi.encodeWithSelector(SingleAssetCoverPool.PayoutExceedsPoolAssets.selector, 101e6, 100e6));
        pool.payClaim(address(0xdead), 101e6);

        pool.payClaim(address(0xdead), 100e6);
        assertEq(pool.totalAssets(), 0);
    }

    /// @dev maxPayoutPerIncident = balance × Registry.maxPayoutBps / 10_000, and it
    ///      tracks a live bps update.
    function test_MaxPayoutPerIncidentView() public {
        _stake(alice, 100e6); // setUp bps = 8000
        assertEq(pool.maxPayoutPerIncident(), 80e6);
        vm.prank(admin);
        registry.setMaxCoverPoolPayoutBps(5000);
        assertEq(pool.maxPayoutPerIncident(), 50e6);
    }

    /// @dev settleIncident rejects a per-pool committed total above the pool's cap,
    ///      bounding LP loss per incident; at the cap it settles.
    function test_SettleRejectsPayoutAboveCap() public {
        _stake(alice, 100e6); // cap = 80e6 at bps 8000
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root = _leaf(1, cid, bob, _amounts(80e6));

        uint256[] memory pp = new uint256[](1);
        pp[0] = 80e6 + 1;
        bytes memory sig = _teeSign(1, root, pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.PayoutCapExceeded.selector, 0, 80e6 + 1, 80e6));
        defi.settleIncident(root, pp, sig);

        pp[0] = 80e6;
        sig = _teeSign(1, root, pp);
        defi.settleIncident(root, pp, sig);
        (,,,,, bytes32 stored,,,,) = defi.incidents(1);
        assertEq(stored, root);
    }

    /// @dev No permanent seed: a distribution into a pool with no stakers reverts
    ///      {NoEligibleStakers} (caller keeps funds); once a stake lands it streams (L3).
    function test_DistributionRequiresStakersThenStreams() public {
        SingleAssetCoverPool p = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(SingleAssetCoverPool.initialize, (registry, IERC20(address(usdc)), "Cover", "cp"))
                )
            )
        );

        // No stakers yet → distribution reverts, funds stay with the caller.
        vm.startPrank(admin);
        usd8.mint(admin, 5e18);
        usd8.approve(address(p), 5e18);
        vm.expectRevert(SingleAssetCoverPool.NoEligibleStakers.selector);
        p.receiveProfitDistribution(5e18);
        vm.stopPrank();

        // A real stake makes the pool eligible (1:1 into an empty pool); it then streams.
        usdc.mint(address(this), 10e6);
        usdc.approve(address(p), 10e6);
        p.deposit(10e6, address(this));
        assertEq(p.totalSupply(), 10e6 * VS);
        assertEq(p.totalAssets(), 10e6);

        vm.prank(admin);
        p.receiveProfitDistribution(5e18);
        assertEq(usd8.balanceOf(address(p)), 5e18);
    }

    /// @dev When the stake asset IS the reward token, {_sweepable} must protect
    ///      staked principal AND committed rewards (their sum), not just one.
    function test_SweepProtectsPrincipalWhenAssetIsRewardToken() public {
        SingleAssetCoverPool p = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(SingleAssetCoverPool.initialize, (registry, IERC20(address(usd8)), "Cover", "cp"))
                )
            )
        );

        // 100 principal + 5 committed rewards = 105 accounted; nothing sweepable.
        vm.prank(admin);
        usd8.mint(alice, 100e18);
        vm.startPrank(alice);
        usd8.approve(address(p), 100e18);
        p.deposit(100e18, alice);
        vm.stopPrank();

        vm.startPrank(admin);
        usd8.mint(admin, 5e18);
        usd8.approve(address(p), 5e18);
        p.receiveProfitDistribution(5e18);
        vm.expectRevert(abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(usd8)));
        p.sweepToken(IERC20(address(usd8)), carol);

        // Only a stray surplus above the 105 accounted is sweepable.
        usd8.mint(address(p), 7e18);
        p.sweepToken(IERC20(address(usd8)), carol);
        vm.stopPrank();
        assertEq(usd8.balanceOf(carol), 7e18);
        assertEq(usd8.balanceOf(address(p)), 105e18);
    }

    function test_AdminSweepsForfeitedInsuredTokens() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);
        _finalize(cid, amounts, 0);

        // Forfeited insured tokens are now unaccounted protocol revenue, sweepable.
        vm.prank(admin);
        defi.sweepToken(IERC20(address(lp1)), carol);
        assertEq(lp1.balanceOf(carol), 50e18);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(lp1)));
        defi.sweepToken(IERC20(address(lp1)), carol);
    }

    function test_SweepStrayStakeAssetExcessOnly() public {
        _stake(alice, 100e6);
        // Someone blindly transfers 50 USDC to the pool (not staked).
        usdc.mint(address(this), 50e6);
        usdc.transfer(address(pool), 50e6);

        // Staked principal (100) is untouchable; only the 50 stray is swept.
        vm.prank(admin);
        pool.sweepToken(IERC20(address(usdc)), carol);
        assertEq(usdc.balanceOf(carol), 50e6);
        assertEq(pool.totalAssets(), 100e6); // principal intact
    }

    function test_SweepProtectsMaturedWithdrawalReserve() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);
        vm.warp(exitEpoch);
        pool.settleMaturedExitEpochs(type(uint256).max);

        usdc.mint(address(pool), 50e6); // unrelated stray transfer
        vm.prank(admin);
        pool.sweepToken(IERC20(address(usdc)), carol);

        assertEq(usdc.balanceOf(carol), 50e6);
        assertEq(pool.withdrawalReserve(), 100e6);
        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 100e6);
    }

    function test_SweepCannotTakeEscrowedExitShares() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(pool)));
        pool.sweepToken(IERC20(address(pool)), carol);

        assertEq(pool.balanceOf(address(pool)), shares);
        assertEq(pool.balanceOf(carol), 0);
    }

    function test_SweepRewardTokenStrayRecoverable() public {
        // No rewards committed -> blindly-sent USD8 is fully recoverable.
        vm.prank(admin);
        usd8.mint(address(this), 10e18);
        usd8.transfer(address(pool), 10e18);
        vm.prank(admin);
        pool.sweepToken(IERC20(address(usd8)), carol);
        assertEq(usd8.balanceOf(carol), 10e18);
    }

    function test_SweepRewardTokenProtectsCommittedReserve() public {
        _stake(alice, 100e6);
        _notify(50e18); // 50 USD8 committed to rewards
        vm.prank(admin);
        usd8.mint(address(this), 10e18);
        usd8.transfer(address(pool), 10e18); // 10 stray on top

        // Only the 10 stray is swept; the 50 reserve is protected.
        vm.prank(admin);
        pool.sweepToken(IERC20(address(usd8)), carol);
        assertEq(usd8.balanceOf(carol), 10e18);
        // Nothing stray left: the committed reserve is not sweepable.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(usd8)));
        pool.sweepToken(IERC20(address(usd8)), carol);
    }

    /// @dev The insured token's surplus (strays / forfeited) is sweepable even DURING a
    ///      live incident — the escrow is protected by the accounting cap, not a blanket
    ///      block — and bob's escrow stays fully recoverable.
    function test_SweepStrayDuringIncidentEscrowProtected() public {
        _registerClaim(bob, lp1, 50e18); // 50 lp1 escrowed, opens incident
        lp1.mint(address(this), 30e18);
        lp1.transfer(address(defi), 30e18); // 30 lp1 stray

        // Mid-incident, only the 30 stray (surplus above the 50 escrow) is swept.
        vm.prank(admin);
        defi.sweepToken(IERC20(address(lp1)), carol);
        assertEq(lp1.balanceOf(carol), 30e18, "stray swept during incident");
        assertEq(lp1.balanceOf(address(defi)), 50e18, "escrow untouched");

        // Bob's escrow is still fully recoverable.
        vm.prank(bob);
        defi.cancelClaim();
        assertEq(lp1.balanceOf(bob), 50e18);

        // Nothing left: escrow returned, stray already taken.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(lp1)));
        defi.sweepToken(IERC20(address(lp1)), carol);
    }

    function test_SweepProtectsClaimBondAndOnlyReleasesSurplusUSD8() public {
        _registerClaim(bob, lp1, 50e18);
        uint256 bond = defi.claimBondAmount();
        vm.prank(admin);
        usd8.mint(address(defi), 3e18);

        vm.prank(admin);
        defi.sweepToken(IERC20(address(usd8)), carol);
        assertEq(usd8.balanceOf(carol), 3e18);
        assertEq(usd8.balanceOf(address(defi)), bond);

        vm.prank(bob);
        defi.cancelClaim();
        assertEq(usd8.balanceOf(bob), bond);
    }

    // ════════════════════ Boosters & score ════════════════════

    /// @dev Admin opens an incident on token; user joins committing qty
    ///      units of the canonical booster (id 1).
    function _openWithBooster(address user, MockERC20 token, uint128 amount, uint256 qty)
        internal
        returns (uint256 claimId)
    {
        token.mint(user, amount);
        _fundClaimBond(user);
        booster.mint(user, BOOSTER_ID, qty);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(token)), uint64(block.number - 1));
        vm.startPrank(user);
        token.approve(address(defi), amount);
        booster.setApprovalForAll(address(defi), true);
        claimId = defi.fileClaim(IERC20(address(token)), amount, 0, qty, 0, "");
        vm.stopPrank();
    }

    function test_BoosterEscrowedOnOpen() public {
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 3);
        assertEq(booster.balanceOf(bob, 1), 0);
        assertEq(booster.balanceOf(address(defi), 1), 3);
        (,,, uint128 storedBooster,,) = defi.claims(cid);
        assertEq(storedBooster, 3);
    }

    function test_BoosterAmountAboveUint128RevertsWithoutTruncation() public {
        uint256 oversizedAmount = uint256(type(uint128).max) + 1;
        lp1.mint(bob, 50e18);
        _fundClaimBond(bob);
        booster.mint(bob, BOOSTER_ID, oversizedAmount);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));

        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        booster.setApprovalForAll(address(defi), true);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, oversizedAmount));
        defi.fileClaim(IERC20(address(lp1)), 50e18, 0, oversizedAmount, 0, "");
        vm.stopPrank();

        assertEq(defi.nextClaimId(), 1);
        assertEq(lp1.balanceOf(bob), 50e18);
        assertEq(booster.balanceOf(bob, BOOSTER_ID), oversizedAmount);
    }

    function test_BoosterBurnedOnFinalize() public {
        _stake(alice, 100e6);
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 3);
        assertEq(booster.totalSupply(1), 3);

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);
        _finalize(cid, amounts, 0);

        assertEq(booster.balanceOf(bob, 1), 0); // claimant receives no refund
        assertEq(booster.balanceOf(address(defi), 1), 0); // burned from escrow
        assertEq(booster.totalSupply(1), 0); // real burn reduced supply
        (,,, uint128 storedBooster,,) = defi.claims(cid);
        assertEq(storedBooster, 3); // preserve committed-and-burned amount on-chain
    }

    function test_FinalizeRejectsBoostedScoreInconsistentWithEscrowedBoosters() public {
        _stake(alice, 100e6);
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 3);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leafSpent(1, cid, bob, amounts, 100, 102, 50e18));
        vm.warp(block.timestamp + 4 days + 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InvalidBoostedScore.selector, 102, 103));
        defi.finalizeClaim(cid, true, amounts, 100, 102, 50e18, new bytes32[](0));
    }

    function test_JoinRevertsWithoutBoosterApproval() public {
        lp1.mint(bob, 50e18);
        _fundClaimBond(bob);
        booster.mint(bob, BOOSTER_ID, 3);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        vm.expectRevert();
        defi.fileClaim(IERC20(address(lp1)), 50e18, 0, 3, 0, "");
        vm.stopPrank();

        assertEq(booster.balanceOf(bob, 1), 3);
        assertEq(booster.balanceOf(address(defi), 1), 0);
    }

    /// @dev Finalization commits both raw and boosted scores in the leaf, but emits and records
    ///      only the raw score spent. A larger boosted allocation score cannot inflate the ledger.
    function test_ScoreSpentEmittedOnFinalize() public {
        _stake(alice, 100e6);
        // Bob requests 500 raw score and commits three boosters. The leaf proves
        // the resulting 515 payout score while Registry accounting advances by only 500.
        lp1.mint(bob, 50e18);
        _fundClaimBond(bob);
        booster.mint(bob, BOOSTER_ID, 3);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        booster.setApprovalForAll(address(defi), true);
        uint256 cid = defi.fileClaim(IERC20(address(lp1)), 50e18, 500, 3, 0, "");
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leafSpent(1, cid, bob, amounts, 500, 515, 50e18));
        vm.warp(block.timestamp + 4 days + 1);

        assertEq(registry.scoreSpent(bob), 0);
        vm.expectEmit(true, true, false, true, address(defi));
        emit DefiInsurance.ScoreSpent(bob, 500, 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, true, amounts, 500, 515, 50e18, new bytes32[](0));
        assertEq(registry.scoreSpent(bob), 500);
    }

    /// @dev Only the registered payout module may write the score ledger.
    function test_RecordScoreSpentOnlyModule() public {
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedModule.selector, address(this)));
        registry.recordScoreSpent(bob, 100);
    }

    function test_BoosterReturnedOnCancel() public {
        _openWithBooster(bob, lp1, 50e18, 3);
        vm.prank(bob);
        defi.cancelClaim();
        assertEq(booster.balanceOf(bob, 1), 3);
        assertEq(booster.balanceOf(address(defi), 1), 0);
    }

    function test_BoosterReturnedOnWithdraw() public {
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 3);
        // Void: no root through the correction window.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
        assertEq(booster.balanceOf(bob, 1), 3);
        assertEq(booster.balanceOf(address(defi), 1), 0);
    }

    function test_SetTeePcrHashBlockedDuringIncident() public {
        _registerClaim(bob, lp1, 50e18);
        vm.prank(admin);
        vm.expectRevert(Registry.Frozen.selector);
        registry.setTeePcrHash(UPDATED_TEE_PCR_HASH);

        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(admin);
        registry.setTeePcrHash(UPDATED_TEE_PCR_HASH);
        assertEq(registry.teePcrHash(), UPDATED_TEE_PCR_HASH);
    }

    // ════════════════════ Loss socialization & staker lock ════════════════════

    function test_LossSocializedAcrossStakers() public {
        _stake(alice, 100e6);
        _stake(carol, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 100e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(80e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);
        _finalize(cid, amounts, 0);

        // 200 -> 100 USDC after the 80/20 gross settlement; both stakers dilute equally.
        vm.warp(block.timestamp + 5 days + 1); // finalize window over, queue clears
        uint256 aliceOut = _completeUnstakeAfterCooldown(alice, pool.balanceOf(alice));
        assertEq(aliceOut, 50e6);
    }

    function test_UnstakeBlockedThroughPhasesThenUnblocks() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(1);

        vm.prank(alice);
        pool.requestRedeem(50e6 * VS);
        (, uint64 exitEpoch) = pool.exitRequests(alice);

        // Before the exit epoch, cooldown is still the first gate.
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SingleAssetCoverPool.CooldownNotElapsed.selector, exitEpoch));
        pool.completeRedeem(alice);

        // Settle within the settlement window.
        vm.warp(uint256(claimDeadline) + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(10e6)));
        (,,,, uint64 correctionDeadline,,,,,) = defi.incidents(1);

        // Once matured, the already-open incident holds settlement until resolution.
        uint256 finalizeAt = uint256(correctionDeadline) + 1;
        if (exitEpoch > finalizeAt) finalizeAt = exitEpoch;
        vm.warp(finalizeAt);
        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.PoolFrozen.selector);
        pool.completeRedeem(alice);

        _finalize(cid, _amounts(10e6), 0);

        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 43.75e6);
    }

    function test_UnstakeUnblocksAfterVoidIncident() public {
        _stake(alice, 100e6);
        _registerClaim(bob, lp1, 50e18);

        vm.prank(alice);
        pool.requestRedeem(50e6 * VS);
        (, uint64 exitEpoch) = pool.exitRequests(alice);

        // No settlement root: once the incident voids, the matured exit can settle.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        assertGe(block.timestamp, exitEpoch);
        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 50e6);
    }

    function test_UnstakeUnblocksAfterSoleClaimCancelled() public {
        _stake(alice, 100e6);
        _registerClaim(bob, lp1, 50e18);

        vm.prank(alice);
        pool.requestRedeem(50e6 * VS);
        (, uint64 exitEpoch) = pool.exitRequests(alice);

        vm.prank(bob);
        defi.cancelClaim();

        // Once both claim window and cooldown epoch end, the inactive incident
        // no longer holds exit settlement.
        vm.warp(exitEpoch);
        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 50e6);
    }

    // ════════════════════ One incident at a time ════════════════════

    function test_SecondIncidentBlockedWhileFirstActive() public {
        _registerClaim(bob, lp1, 50e18);
        assertEq(defi.activeIncidentId(), 1);

        // Opening a second incident is rejected while the first is in flight,
        // even by the admin on a different insured token.
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        defi.openClaimIncident(IERC20(address(lp2)), uint64(block.number - 1));
    }

    function test_NewIncidentOpensAfterPriorResolves() public {
        _stake(alice, 200e6);
        uint256 c1 = _registerClaim(bob, lp1, 50e18);

        // Settle + finalize incident 1 fully.
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory a1 = _amounts(40e6);
        _settle(1, _leaf(1, c1, bob, a1));
        vm.warp(block.timestamp + 4 days + 1);
        _finalize(c1, a1, 0);

        // Incident 1 inactive -> a fresh incident can open on lp2 and runs
        // its full settlement window off its own clock.
        uint256 c2 = _registerClaim(carol, lp2, 30e18);
        assertEq(defi.activeIncidentId(), 2);

        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root2 = _leaf(2, c2, carol, _amounts(10e6));
        _settle(2, root2);
        vm.warp(block.timestamp + 4 days + 1);
        _finalize(c2, _amounts(10e6), 0);
        assertEq(usdc.balanceOf(carol), 10e6);
    }

    function test_NewIncidentOpensAfterPriorVoids() public {
        _registerClaim(bob, lp1, 50e18);
        // No settlement root: incident 1 voids at windowEnd + correction window.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        // Now a new incident may open.
        uint256 c2 = _registerClaim(carol, lp2, 30e18);
        assertEq(defi.activeIncidentId(), 2);
        assertEq(c2, 2);
    }

    // ════════════════════ Roles ════════════════════

    function test_RoleTransfersAndGating() public {
        // Distinct fast admin; timelock keeps config + role assignment.
        address fastAdmin = address(0xFA57);
        vm.prank(admin);
        registry.setAdmin(fastAdmin, true);
        assertTrue(registry.isAdmin(fastAdmin));

        // Fast admin cannot alter economic or timing configuration.
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, fastAdmin));
        vm.prank(fastAdmin);
        pool.setRewardsDuration(14 days);
        assertEq(pool.rewardsDuration(), 7 days);

        DefiInsurance.InsuredToken memory config = defi.getInsuredToken(IERC20(address(lp1)));
        config.maxCoverageBps = 7000;
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, fastAdmin));
        vm.prank(fastAdmin);
        defi.editInsuredToken(
            IERC20(address(lp1)),
            config.maxCoverageBps,
            config.underlyingPriceOracle,
            config.underlyingConversionAddress,
            config.underlyingConversionCallData
        );

        // Timelock handover; old timelock loses config access.
        address newTimelock = address(0x71E);
        vm.prank(admin);
        registry.setTimelock(newTimelock);
        assertEq(registry.timelock(), newTimelock);

        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, admin));
        vm.prank(admin);
        registry.setScoredToken(IERC20(address(usd8)), 1);
    }

    function test_CompleteRedeemLeavesYieldClaimable() public {
        // requestRedeem checkpoints yield and completeRedeem does NOT pay it: claiming is a
        // separate action, and a full exit must not strand the accrued USD8.
        _stake(alice, 100e6);
        _notify(70e18);
        vm.warp(block.timestamp + 7 days + 1); // full window earned

        uint256 aliceShares = pool.balanceOf(alice);
        vm.startPrank(alice);
        pool.requestRedeem(aliceShares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);
        vm.warp(exitEpoch);
        pool.completeRedeem(alice);
        assertEq(usd8.balanceOf(alice), 0); // principal only, no auto-claim

        uint256 got = pool.claimReward();
        vm.stopPrank();
        assertApproxEqAbs(got, 70e18, 1e7); // still fully claimable after exit
    }

    function test_DeferredEmissionSurvivesEmptyBase() public {
        // Carry-forward regression: if every staker fully exits mid-stream, the
        // undripped emission must defer and re-stream to the next staker rather
        // than strand in rewardReserve.
        vm.prank(admin);
        pool.setRewardsDuration(30 days);
        _stake(alice, 100e6);
        _notify(70e18); // 70 over 30 days

        // Alice requests immediately, so the earning base empties and the whole
        // undripped emission is deferred for the next active staker.
        uint256 aliceShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestRedeem(aliceShares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);
        vm.warp(exitEpoch);
        vm.prank(alice);
        pool.completeRedeem(alice);

        // Long gap with a zero base, then a new staker arrives (its checkpoint
        // defers the gap), then run past the extended finish.
        vm.warp(block.timestamp + 60 days);
        _stake(carol, 50e6);
        vm.warp(block.timestamp + 60 days);

        vm.prank(alice);
        uint256 aliceGot = pool.claimReward();
        vm.prank(carol);
        uint256 carolGot = pool.claimReward();
        // Nothing stranded: the full 70 is paid across the two earning intervals.
        assertApproxEqAbs(aliceGot + carolGot, 70e18, 1e13);
    }

    // ════════════════════ Emergency pause ════════════════════

    function test_PauseGatesValueMovingEntrypoints() public {
        _stake(alice, 100e6);
        _notify(70e18);
        vm.warp(block.timestamp + 1 days);
        uint256 aliceShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestRedeem(aliceShares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);
        vm.warp(exitEpoch);

        // Pause: admin or timelock may toggle; a non-role caller cannot.
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, bob));
        vm.prank(bob);
        registry.setPaused(address(pool), true);
        vm.prank(admin);
        registry.setPaused(address(pool), true);
        assertTrue(registry.paused(address(pool)));

        // All value-moving entrypoints revert while paused.
        usdc.mint(carol, 10e6);
        vm.startPrank(carol);
        usdc.approve(address(pool), 10e6);
        vm.expectRevert(Registry.Paused.selector);
        pool.deposit(10e6, carol);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(Registry.Paused.selector);
        pool.completeRedeem(alice);
        vm.expectRevert(Registry.Paused.selector);
        pool.claimReward();
        vm.stopPrank();

        vm.startPrank(admin);
        usd8.mint(admin, 1e18);
        usd8.approve(address(pool), 1e18);
        vm.expectRevert(Registry.Paused.selector);
        pool.receiveProfitDistribution(1e18);
        vm.stopPrank();
        // payClaim is covered separately in test_PayClaimPausedReverts.
    }

    function test_PayClaimPausedReverts() public {
        _stake(alice, 100e6);
        vm.prank(admin);
        registry.setDefiInsurance(address(this));
        vm.prank(admin);
        registry.setPaused(address(pool), true);
        vm.expectRevert(Registry.Paused.selector);
        pool.payClaim(address(0xdead), 10e6);
    }

    function test_UnpauseRestoresFlow() public {
        _stake(alice, 100e6);
        vm.prank(admin);
        registry.setPaused(address(pool), true);
        vm.prank(admin);
        registry.setPaused(address(pool), false);
        assertFalse(registry.paused(address(pool)));
        _stake(bob, 50e6); // works again
        assertGt(pool.balanceOf(bob), 0);
    }

    function test_SetDefiInsuranceRejectsAlreadyActiveCandidate() public {
        StuckModule m = new StuckModule();
        m.setActiveIncidentId(1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Registry.CandidateIncidentActive.selector, address(m), 1));
        registry.setDefiInsurance(address(m));
    }

    function test_DeregisterNeutralizesStuckModule() public {
        StuckModule m = new StuckModule();
        vm.prank(admin);
        registry.setDefiInsurance(address(m));
        m.setActiveIncidentId(1); // module later becomes stuck active
        assertTrue(registry.payoutIncidentActive());

        // Worst case: the module starts reverting in activeIncidentId() — every
        // freeze-gated function would brick while it stays the module.
        m.setRevertMode(true);
        vm.expectRevert(bytes("dead"));
        registry.payoutIncidentActive();

        // Clearing the module to zero is the emergency brake: setDefiInsurance(0)
        // skips the payoutIncidentActive() guard, so the stuck module is fully neutralized.
        vm.prank(admin);
        registry.setDefiInsurance(address(0));
        assertFalse(registry.payoutIncidentActive());
        _stake(alice, 100e6); // pool usable again
    }

    function test_LastClaimStaysFrozenThroughRefund() public {
        // finalizing the FINAL unresolved claim must keep the incident active
        // (pool frozen) through the over-escrow refund, so a callback in the insured
        // token can't re-enter redeem and exit at the pre-loss share price.
        RefundFreezeProbeToken tok = new RefundFreezeProbeToken(registry);
        tok.setDefi(address(defi));
        vm.prank(admin);
        defi.editInsuredToken(IERC20(address(tok)), 8000, FEED, address(0), "");

        _stake(alice, 100e6); // pool capital to pay from

        uint128 escrow = 100e18;
        tok.mint(bob, escrow);
        _fundClaimBond(bob);
        vm.prank(bob);
        tok.approve(address(defi), escrow);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(tok)), uint64(block.number - 1));
        vm.prank(bob);
        uint256 claimId = defi.fileClaim(IERC20(address(tok)), escrow, 0, 0, 0, "");

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(20e6);
        uint256 eligible = 60e18; // < escrow → 40e18 refund fires the probe
        _settle(1, _leafSpent(1, claimId, bob, amounts, 1, 1, eligible));
        vm.warp(block.timestamp + registry.incidentTimingConfig().phaseWindow + 1);

        vm.prank(bob);
        defi.finalizeClaim(claimId, true, amounts, 1, 1, eligible, new bytes32[](0));

        assertTrue(tok.probed(), "refund fired the probe");
        assertTrue(tok.frozenDuringRefund(), "incident still frozen during the last claim's refund");
        assertEq(defi.activeIncidentId(), 0, "incident retired only after finalize completes");
    }

    function test_SubDurationRewardRejectedInsteadOfStranding() public {
        _stake(alice, 100e6);

        // a distribution too small to stream (total/duration floors to zero)
        // is rejected outright — nothing enters rewardReserve to strand forever.
        vm.startPrank(admin);
        usd8.mint(admin, 1);
        usd8.approve(address(pool), 1);
        vm.expectRevert(abi.encodeWithSelector(SingleAssetCoverPool.RewardRateZero.selector, 1, pool.rewardsDuration()));
        pool.receiveProfitDistribution(1);
        vm.stopPrank();
        assertEq(pool.rewardReserve(), 0, "nothing reserved");
    }

    /// @dev Beta mode: admin corrects a bad TEE root in ONE call (no separate
    ///      dispute, no timelock); the corrected root runs its own fresh CORRECTION
    ///      window, then finalizes and pays the corrected amount.
    function test_AdminCorrectSettlementInBeta() public {
        assertTrue(registry.betaMode(), "launches in beta");
        _stake(alice, 100e6); // underwrite so payouts have capital
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, claimId, bob, _amounts(50e6))); // bad root (overpays)

        // Admin fixes it directly, in beta — one call. Precompute leaf/pp (their
        // external reads would otherwise consume the prank).
        uint256[] memory good = _amounts(20e6);
        bytes32 corrRoot = _leaf(1, claimId, bob, good);
        uint256[] memory pp = _pp();
        vm.prank(admin);
        defi.adminCorrectSettlement(corrRoot, pp);

        // Fresh CORRECTION window on the corrected root, then pay the corrected amount.
        vm.warp(block.timestamp + registry.incidentTimingConfig().phaseWindow + 1);
        _finalize(claimId, good, 0);
        assertEq(usdc.balanceOf(bob), 20e6, "paid the admin-corrected amount");
    }

    /// @dev Once the timelock ends beta, the admin shortcut is gone — one-way.
    function test_AdminCorrectSettlementRejectedAfterBeta() public {
        vm.prank(admin); // admin == timelock in this harness
        registry.endBetaMode();
        assertFalse(registry.betaMode());

        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, claimId, bob, _amounts(0)));

        bytes32 corrRoot = _leaf(1, claimId, bob, _amounts(0));
        uint256[] memory pp = _pp();
        vm.prank(admin);
        vm.expectRevert(SharedBase.NotBetaMode.selector);
        defi.adminCorrectSettlement(corrRoot, pp);
    }

    function test_EndBetaModeRejectedDuringActiveIncident() public {
        _registerClaim(bob, lp1, 50e18);

        vm.expectRevert(Registry.Frozen.selector);
        vm.prank(admin); // admin == timelock in this harness
        registry.endBetaMode();
    }

    /// @dev Explicit permission matrix for the claim-open phase.
    function test_PhaseMatrix_ClaimOpen_AllowsOnlyFileAndCancel() public {
        uint256 bobClaim = _registerClaim(bob, lp1, 50e18);
        _prepareClaimant(carol, lp1, 10e18);

        // Filing and cancellation are the only lifecycle mutations open to claimants.
        vm.prank(carol);
        uint256 carolClaim = defi.fileClaim(IERC20(address(lp1)), 10e18, 0, 0, 0, "");
        assertGt(carolClaim, bobClaim);

        uint256[] memory amounts = _amounts(0);
        bytes32 root = _hashPair(_leaf(1, bobClaim, bob, amounts), _leaf(1, carolClaim, carol, amounts));
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root, pp);

        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.settleIncident(root, pp, sig);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(bobClaim, false, amounts, 1, 1, 50e18, new bytes32[](0));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NoStandingRoot.selector, uint256(1)));
        defi.adminCorrectSettlement(root, pp);

        vm.prank(carol);
        defi.cancelClaim();
        (,,,,, bool resolved) = defi.claims(carolClaim);
        assertTrue(resolved);
    }

    /// @dev Explicit permission matrix after claims close but before a root lands.
    function test_PhaseMatrix_Settlement_AllowsOnlySettlement() public {
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        _prepareClaimant(carol, lp1, 10e18);
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(1);
        vm.warp(claimDeadline + 1);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, lp1, claimDeadline));
        defi.fileClaim(IERC20(address(lp1)), 10e18, 0, 0, 0, "");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, lp1, claimDeadline));
        defi.cancelClaim();

        uint256[] memory amounts = _amounts(0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(claimId, false, amounts, 1, 1, 50e18, new bytes32[](0));

        uint256[] memory pp = _pp();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NoStandingRoot.selector, uint256(1)));
        defi.adminCorrectSettlement(bytes32(uint256(1)), pp);

        bytes32 root = _leaf(1, claimId, bob, amounts);
        _settle(1, root);
        (,,,,, bytes32 storedRoot,,,,) = defi.incidents(1);
        assertEq(storedRoot, root);
    }

    /// @dev Explicit permission matrix while a standing root is still correctable.
    function test_PhaseMatrix_Correction_AllowsOnlyAdminCorrection() public {
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(1);
        vm.warp(claimDeadline + 1);
        uint256[] memory amounts = _amounts(0);
        bytes32 root = _leaf(1, claimId, bob, amounts);
        _settle(1, root);

        _prepareClaimant(carol, lp1, 10e18);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentFinalizing.selector, uint256(1)));
        defi.fileClaim(IERC20(address(lp1)), 10e18, 0, 0, 0, "");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentFinalizing.selector, uint256(1)));
        defi.cancelClaim();

        uint256[] memory pp = _pp();
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.AlreadySettled.selector, uint256(1)));
        defi.settleIncident(bytes32(uint256(2)), pp, "");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(claimId, true, amounts, 1, 1, 50e18, new bytes32[](0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(claimId, false, amounts, 1, 1, 50e18, new bytes32[](0));

        (,,,, uint64 oldCorrectionDeadline,,,,,) = defi.incidents(1);
        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, alice));
        defi.adminCorrectSettlement(root, pp);

        vm.prank(admin);
        defi.adminCorrectSettlement(root, pp);
        (,,,, uint64 newCorrectionDeadline,,,,,) = defi.incidents(1);
        assertGt(newCorrectionDeadline, oldCorrectionDeadline);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentFinalizing.selector, uint256(1)));
        defi.fileClaim(IERC20(address(lp1)), 10e18, 0, 0, 0, "");
    }

    /// @dev Explicit permission matrix once proofs may be exercised.
    function test_PhaseMatrix_Finalization_AllowsOnlyAcceptOrDecline() public {
        uint256 bobClaim = _registerClaim(bob, lp1, 50e18);
        uint256 carolClaim = _registerClaim(carol, lp1, 50e18);
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(1);
        vm.warp(claimDeadline + 1);

        uint256[] memory amounts = _amounts(0);
        bytes32 bobLeaf = _leaf(1, bobClaim, bob, amounts);
        bytes32 carolLeaf = _leaf(1, carolClaim, carol, amounts);
        bytes32 root = _hashPair(bobLeaf, carolLeaf);
        _settle(1, root);
        (,,,, uint64 correctionDeadline,,,,,) = defi.incidents(1);
        vm.warp(correctionDeadline + 1);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentFinalizing.selector, uint256(1)));
        defi.fileClaim(IERC20(address(lp1)), 1, 0, 0, 0, "");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentFinalizing.selector, uint256(1)));
        defi.cancelClaim();

        uint256[] memory pp = _pp();
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.AlreadySettled.selector, uint256(1)));
        defi.settleIncident(bytes32(uint256(2)), pp, "");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentFinalizing.selector, uint256(1)));
        defi.adminCorrectSettlement(root, pp);

        bytes32[] memory bobProof = new bytes32[](1);
        bobProof[0] = carolLeaf;
        vm.prank(bob);
        defi.finalizeClaim(bobClaim, true, amounts, 1, 1, 50e18, bobProof);

        bytes32[] memory carolProof = new bytes32[](1);
        carolProof[0] = bobLeaf;
        vm.prank(carol);
        defi.finalizeClaim(carolClaim, false, amounts, 1, 1, 50e18, carolProof);
        assertEq(defi.activeIncidentId(), 0);
    }

    /// @dev Once payout acceptance expires, only proof-backed decline remains available.
    function test_PhaseMatrix_PayoutExpired_AllowsOnlyProofBackedDecline() public {
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(1);
        vm.warp(claimDeadline + 1);
        uint256[] memory amounts = _amounts(0);
        bytes32 root = _leaf(1, claimId, bob, amounts);
        _settle(1, root);
        (,,,, uint64 correctionDeadline,,,,,) = defi.incidents(1);
        vm.warp(uint256(correctionDeadline) + defi.incidentPhaseWindow(1) + 1);

        _prepareClaimant(carol, lp1, 10e18);
        uint64 referenceBlock = uint64(block.number - 1);
        bytes memory openSignature = _teeSignOpen(address(lp1), referenceBlock);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InsuredTokenNotApproved.selector, IERC20(address(lp1))));
        defi.fileClaim(IERC20(address(lp1)), 10e18, 0, 0, referenceBlock, openSignature);

        vm.prank(bob);
        vm.expectRevert(DefiInsurance.NoActiveClaim.selector);
        defi.cancelClaim();

        uint256[] memory pp = _pp();
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NotActiveIncident.selector, uint256(0)));
        defi.settleIncident(bytes32(uint256(2)), pp, "");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NotActiveIncident.selector, uint256(0)));
        defi.adminCorrectSettlement(root, pp);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(claimId, true, amounts, 1, 1, 50e18, new bytes32[](0));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InvalidProof.selector, claimId));
        defi.finalizeClaim(claimId, false, amounts, 1, 1, 49e18, new bytes32[](0));

        vm.prank(bob);
        defi.finalizeClaim(claimId, false, amounts, 1, 1, 50e18, new bytes32[](0));
        (,,,,, bool resolved) = defi.claims(claimId);
        assertTrue(resolved);
    }

    /// @dev If no root arrives, the expired incident permits only proofless recovery.
    function test_PhaseMatrix_NoRootExpired_AllowsOnlyProoflessRecovery() public {
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        uint64 claimDeadline;
        bytes32 oldIncidentState;
        {
            bytes32 oldRoot;
            uint256 oldUnresolved;
            bytes32 oldClaimSet;
            (,,,, claimDeadline, oldRoot, oldUnresolved, oldClaimSet,,) = defi.incidents(1);
            oldIncidentState = keccak256(abi.encode(claimDeadline, oldRoot, oldUnresolved, oldClaimSet));
        }
        vm.warp(uint256(claimDeadline) + defi.incidentPhaseWindow(1) + 1);

        vm.prank(bob);
        vm.expectRevert(DefiInsurance.NoActiveClaim.selector);
        defi.cancelClaim();

        uint256[] memory pp = _pp();
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NotActiveIncident.selector, uint256(0)));
        defi.settleIncident(bytes32(uint256(1)), pp, "");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NotActiveIncident.selector, uint256(0)));
        defi.adminCorrectSettlement(bytes32(uint256(1)), pp);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(claimId, true, new uint256[](0), 0, 0, 0, new bytes32[](0));

        // Terminal expiry permits a fresh incident without mutating the old one.
        _prepareClaimant(carol, lp2, 10e18);
        uint64 referenceBlock = uint64(block.number - 1);
        bytes memory openSignature = _teeSignOpen(address(lp2), referenceBlock);
        vm.prank(carol);
        uint256 freshClaim = defi.fileClaim(IERC20(address(lp2)), 10e18, 0, 0, referenceBlock, openSignature);
        assertEq(freshClaim, 2);
        assertEq(defi.activeIncidentId(), 2);

        {
            uint64 oldDeadlineAfter;
            bytes32 oldRootAfter;
            uint256 oldUnresolvedAfter;
            bytes32 oldClaimSetAfter;
            (,,,, oldDeadlineAfter, oldRootAfter, oldUnresolvedAfter, oldClaimSetAfter,,) = defi.incidents(1);
            assertEq(
                keccak256(abi.encode(oldDeadlineAfter, oldRootAfter, oldUnresolvedAfter, oldClaimSetAfter)),
                oldIncidentState
            );
        }
        {
            (address oldUser, uint64 oldIncidentId,,,, bool oldResolved) = defi.claims(claimId);
            assertEq(oldUser, bob);
            assertEq(oldIncidentId, 1);
            assertFalse(oldResolved);
        }

        // Historical recovery remains keyed by claim id even while incident 2 is active.
        vm.prank(bob);
        defi.finalizeClaim(claimId, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
        (,,,,, bool resolved) = defi.claims(claimId);
        assertTrue(resolved);
        assertEq(lp1.balanceOf(bob), 50e18);
    }

    /// @dev Exact timestamps belong to the ending phase; the next phase opens at +1.
    function test_PhaseMatrix_ExactDeadlineOwnership() public {
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        _prepareClaimant(carol, lp1, 10e18);
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(1);
        vm.warp(claimDeadline);

        // At the exact claim deadline, filing and cancellation remain open.
        vm.prank(carol);
        defi.fileClaim(IERC20(address(lp1)), 10e18, 0, 0, 0, "");
        vm.prank(carol);
        defi.cancelClaim();

        uint256[] memory amounts = _amounts(0);
        bytes32 root = _leaf(1, claimId, bob, amounts);
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root, pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.settleIncident(root, pp, sig);

        // The exact settlement deadline still accepts the sole signed root.
        vm.warp(uint256(claimDeadline) + defi.incidentPhaseWindow(1));
        _settle(1, root);
        (,,,, uint64 correctionDeadline,,,,,) = defi.incidents(1);

        // The exact correction deadline still belongs to correction, not finalization.
        vm.warp(correctionDeadline);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(claimId, true, amounts, 1, 1, 50e18, new bytes32[](0));
        vm.prank(admin);
        defi.adminCorrectSettlement(root, pp);

        // Payout acceptance remains open through the exact finalization deadline.
        (,,,, uint64 correctedDeadline,,,,,) = defi.incidents(1);
        vm.warp(uint256(correctedDeadline) + defi.incidentPhaseWindow(1));
        _finalize(claimId, amounts, 1);
        assertEq(defi.activeIncidentId(), 0);
    }

    /// @dev Without a root, proofless recovery opens only after the settlement deadline.
    function test_PhaseMatrix_NoRootRecoveryOpensOnlyAfterExactExpiry() public {
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(1);
        uint256 settlementDeadline = uint256(claimDeadline) + defi.incidentPhaseWindow(1);

        vm.warp(settlementDeadline);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(claimId, false, new uint256[](0), 0, 0, 0, new bytes32[](0));

        vm.warp(settlementDeadline + 1);
        vm.prank(bob);
        defi.finalizeClaim(claimId, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
        (,,,,, bool resolved) = defi.claims(claimId);
        assertTrue(resolved);
    }

    /// @dev Full claim/settle/beta-correct/finalize state machine in phase order.
    function test_PhaseOrderStateMachine() public {
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        uint256[] memory amounts = _amounts(0);
        bytes32 root = _leaf(1, claimId, bob, amounts);
        uint256[] memory pp = _pp();

        // CLAIM phase: settle and finalize are both out of phase.
        bytes memory sig = _teeSign(1, root, pp); // before expectRevert: helper reads incidents
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.settleIncident(root, pp, sig);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(claimId, true, amounts, 1, 1, 50e18, new bytes32[](0));

        // Window closes: join and cancel are now out of phase.
        (,,,, uint64 wEnd,,,,,) = defi.incidents(1);
        vm.warp(wEnd + 1);
        lp1.mint(carol, 10e18);
        vm.startPrank(carol);
        lp1.approve(address(defi), 10e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, lp1, wEnd));
        defi.fileClaim(IERC20(address(lp1)), 10e18, 0, 0, 0, "");
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, lp1, wEnd));
        defi.cancelClaim();

        // SETTLE phase: root lands; finalize still gated by the CORRECTION period.
        _settle(1, root);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(claimId, true, amounts, 1, 1, 50e18, new bytes32[](0));

        // A beta correction restarts a fresh correction clock, so finalize is gated again.
        vm.prank(admin);
        defi.adminCorrectSettlement(root, pp);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(claimId, true, amounts, 1, 1, 50e18, new bytes32[](0));

        // Once the corrected root's correction window passes, finalization retires it.
        vm.warp(block.timestamp + registry.incidentTimingConfig().phaseWindow + 1);
        _finalize(claimId, amounts, 0);
        assertEq(defi.activeIncidentId(), 0);
    }

    /// @dev Requested shares are escrowed, remain loss-exposed until their exit epoch, then
    ///      become a fixed claim while both standard ERC-4626 exit doors stay disabled.
    function test_ExitClaimHandlesLossWhileStandardDoorsStayDisabled() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares / 2);

        assertEq(pool.maxWithdraw(alice), 0);
        assertEq(pool.maxRedeem(alice), 0);
        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.WithdrawNotSupported.selector);
        pool.withdraw(1e6, alice, alice);
        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.RedeemNotSupported.selector);
        pool.redeem(1, alice, alice);

        // Only the non-requested half remains in Alice's wallet and transferable.
        vm.prank(alice);
        pool.transfer(bob, shares - shares / 2);
        vm.prank(address(defi));
        pool.payClaim(carol, 30e6);

        uint256 expectedAssets = pool.previewRedeem(shares / 2);
        (, uint64 exitEpoch) = pool.exitRequests(alice);
        vm.warp(exitEpoch);
        pool.settleMaturedExitEpochs(type(uint256).max);
        vm.prank(alice);
        uint256 got = pool.completeRedeem(alice);
        assertEq(got, expectedAssets);
        assertEq(usdc.balanceOf(alice), expectedAssets);
    }

    function test_RewardsDurationBounded() public {
        // 0 and anything past the 1-year cap are rejected; the cap itself is ok.
        uint64 maxDur = pool.MAX_REWARDS_DURATION(); // read before prank/expectRevert
        vm.startPrank(admin);
        vm.expectRevert(SingleAssetCoverPool.InvalidRewardsDuration.selector);
        pool.setRewardsDuration(0);
        vm.expectRevert(SingleAssetCoverPool.InvalidRewardsDuration.selector);
        pool.setRewardsDuration(maxDur + 1);
        pool.setRewardsDuration(maxDur); // exactly the cap is fine
        vm.stopPrank();
        assertEq(pool.rewardsDuration(), maxDur);
    }

    function test_RequestedSharesAreEscrowedDuringCooldown() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares / 2);

        assertEq(pool.balanceOf(address(pool)), shares / 2);
        assertEq(pool.balanceOf(alice), shares / 2);
        vm.prank(alice);
        pool.transfer(bob, shares / 2);
        assertEq(pool.balanceOf(alice), 0);
    }

    function test_MaturedExitReceiptNeverExpires() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares);
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 100e6);
    }

    function test_FirstStakerAfterLongEmptyGapEarnsDeferredRewardsOverRemainingDuration() public {
        vm.prank(admin);
        pool.setRewardsDuration(30 days);
        _stake(alice, 100e6);
        _notify(70e18);

        uint256 shares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestRedeem(shares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);
        vm.warp(exitEpoch);
        vm.prank(alice);
        pool.completeRedeem(alice);
        assertEq(pool.totalSupply(), 0);

        vm.warp(block.timestamp + 60 days);
        _stake(carol, 1); // first new stake after stale finish
        vm.prank(carol);
        assertEq(pool.claimReward(), 0, "nothing to harvest instantly");

        // Requesting stopped the only earning balance immediately, so the complete
        // 30-day stream resumes for the next active staker.
        vm.warp(block.timestamp + 30 days);
        vm.prank(carol);
        uint256 streamed = pool.claimReward();
        assertApproxEqAbs(streamed, 70e18, 1e6, "deferred rewards stream over full duration");
    }
}

/// @dev A v2 implementation with a version() bump, to prove a beacon upgrade
///      re-points the proxy at new code while preserving storage.
contract SingleAssetCoverPoolV2 is SingleAssetCoverPool {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract DefiInsuranceV2 is DefiInsurance {}

/// @dev Configurable token-to-underlying recipe used by curation tests.
contract MockConversionRecipe {
    uint256 public ratio;

    constructor(uint256 ratio_) {
        ratio = ratio_;
    }

    function convertToAssets(uint256) external view returns (uint256) {
        return ratio;
    }
}

/// @dev A payout module gone wrong: reports an incident forever, and can be
///      switched to reverting outright.
contract StuckModule {
    bool revertMode;
    uint256 incidentId;

    function setActiveIncidentId(uint256 id) external {
        incidentId = id;
    }

    function setRevertMode(bool r) external {
        revertMode = r;
    }

    function activeIncidentId() external view returns (uint256) {
        if (revertMode) revert("dead");
        return incidentId;
    }
}

/// @dev Registered-pool probe that attempts to open another incident while the
///      payout module is settling matured exits for the outer incident.
contract ReentrantIncidentPool {
    DefiInsurance private immutable DEFI;
    IERC20 private immutable ASSET;
    IERC20 private immutable REENTRY_TOKEN;
    uint64 private immutable REFERENCE_BLOCK;
    bool public attempted;
    bool public reentrySucceeded;
    bytes public reentryReturndata;
    uint128 private reentryAmount;
    bytes private reentrySignature;

    constructor(DefiInsurance defi_, IERC20 asset_, IERC20 reentryToken_, uint64 referenceBlock_) {
        DEFI = defi_;
        ASSET = asset_;
        REENTRY_TOKEN = reentryToken_;
        REFERENCE_BLOCK = referenceBlock_;
    }

    function asset() external view returns (IERC20) {
        return ASSET;
    }

    function arm(uint128 amount, bytes calldata signature) external {
        reentryAmount = amount;
        reentrySignature = signature;
        require(REENTRY_TOKEN.approve(address(DEFI), amount));
    }

    function settleMaturedExitEpochs(uint256) external returns (uint256) {
        if (!attempted) {
            attempted = true;
            (bool ok, bytes memory returndata) = address(DEFI)
                .call(
                    abi.encodeCall(
                        DefiInsurance.fileClaim,
                        (REENTRY_TOKEN, reentryAmount, uint256(0), uint256(0), REFERENCE_BLOCK, reentrySignature)
                    )
                );
            reentrySucceeded = ok;
            reentryReturndata = returndata;
        }
        return 0;
    }
}
