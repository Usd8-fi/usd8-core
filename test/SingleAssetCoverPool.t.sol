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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
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
        registry.setBoosterNFT(address(booster));
        registry.setDefiInsurance(address(defi));
        defi.addInsuredToken(IERC20(address(lp1)), 8000, MIN_CLAIM, FEED, address(0), "");
        defi.addInsuredToken(IERC20(address(lp2)), 8000, MIN_CLAIM * 2, FEED, address(0), "");
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

    /// @dev Admin opens an incident on the token if none is joinable, then the
    ///      user joins it. Keeps call sites simple.
    function _registerClaim(address user, MockERC20 insuredToken, uint128 amount) internal returns (uint256 claimId) {
        insuredToken.mint(user, amount);
        vm.prank(user);
        insuredToken.approve(address(defi), amount);

        if (!_hasJoinableIncident(address(insuredToken))) {
            vm.prank(admin);
            defi.openClaimIncident(IERC20(address(insuredToken)), uint64(block.number - 1));
        }
        vm.prank(user);
        claimId = defi.joinClaim(IERC20(address(insuredToken)), amount, 0, 0, 0, "");
    }

    /// @dev True if the in-flight incident covers token and its claim
    ///      window is still open (i.e. a claim can join without opening).
    function _hasJoinableIncident(address token) internal view returns (bool) {
        uint256 active = defi.activeIncidentId();
        if (active == 0) return false;
        (IERC20 tok, uint64 wEnd,,,,,,,,) = defi.incidents(active);
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
        return _leafSpent(incidentId, claimId, user, amounts, 0, 0, escrow);
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
        assertEq(defi.insuredTokenListLength(), 2);
        assertEq(defi.nextClaimId(), 1);
        assertEq(defi.nextIncidentId(), 1);
        assertEq(registry.boosterNFT(), address(booster));
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

    function test_ExitEpochUsesThreeDayBatches() public {
        assertEq(pool.EXIT_BATCH_INTERVAL(), 3 days);
        uint256 shares = _stake(alice, 100e6);
        uint256 requestedAt = block.timestamp;

        vm.prank(alice);
        pool.requestRedeem(shares);
        (, uint64 exitEpoch) = pool.exitRequests(alice);

        uint256 earliest = requestedAt + pool.UNSTAKE_COOLDOWN();
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
        defi.addInsuredToken(IERC20(address(usdc)), 8000, MIN_CLAIM, FEED, address(0), "");
    }

    function test_AddInsuredTokenAcceptsUSD8() public {
        vm.prank(admin);
        defi.addInsuredToken(IERC20(address(usd8)), 8000, MIN_CLAIM, FEED, address(0), "");
        assertEq(defi.getInsuredToken(IERC20(address(usd8))).maxCoverageBps, 8000);
    }

    /// @dev End-to-end USD8 self-cover: the TEE attests a backing loss off-chain
    ///      and signs the open; alice then claims. No on-chain trigger/adapter.
    function test_USD8BackingLossTriggersIncident() public {
        vm.startPrank(admin);
        defi.addInsuredToken(IERC20(address(usd8)), 8000, MIN_CLAIM, FEED, address(0), "");
        usd8.mint(alice, 100e18);
        vm.stopPrank();
        vm.prank(alice);
        usd8.approve(address(defi), 100e18);

        // Without a TEE attestation there is no live incident: a bare join (no open
        // sig) tries the open branch and reverts inside ECDSA on the empty signature.
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(0)));
        defi.joinClaim(IERC20(address(usd8)), 50e18, 0, 0, 0, "");

        // The TEE evaluates the backing loss off-chain and signs the open at a
        // pinned pre-incident reference block; anyone relays it.
        uint64 refBlock = uint64(block.number - 1);
        _openSigned(address(usd8), refBlock);
        uint256 id = defi.activeIncidentId();
        (,,,,, uint64 stored,,,,) = defi.incidents(id);
        assertEq(stored, refBlock);

        vm.prank(alice);
        defi.joinClaim(IERC20(address(usd8)), 50e18, 0, 0, 0, "");
        // Still listed: delisting is deferred to root submission, not open.
        assertEq(defi.getInsuredToken(IERC20(address(usd8))).maxCoverageBps, 8000);
    }

    function test_AddInsuredTokenDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(DefiInsurance.InsuredTokenAlreadyApproved.selector, IERC20(address(lp1)))
        );
        defi.addInsuredToken(IERC20(address(lp1)), 8000, MIN_CLAIM, FEED, address(0), "");
    }

    // ════════════════════ Settlement config ════════════════════

    function test_AddInsuredTokenStoresConfig() public view {
        DefiInsurance.InsuredToken memory it = defi.getInsuredToken(IERC20(address(lp1)));
        assertEq(it.maxCoverageBps, 8000);
        assertEq(it.minClaimAmount, MIN_CLAIM);
        assertEq(it.underlyingPriceOracle, FEED);
        assertEq(it.underlyingConversionAddress, address(0)); // identity
    }

    function test_MinClaimAmountIsPerInsuredToken() public view {
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).minClaimAmount, MIN_CLAIM);
        assertEq(defi.getInsuredToken(IERC20(address(lp2))).minClaimAmount, MIN_CLAIM * 2);
    }

    function test_AddInsuredTokenRejectsBadArgs() public {
        MockERC20 lp3 = new MockERC20("LP3", "LP3", 18);
        vm.startPrank(admin);
        vm.expectRevert(SharedBase.ZeroAddress.selector); // zero price oracle
        defi.addInsuredToken(IERC20(address(lp3)), 8000, MIN_CLAIM, address(0), address(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(DefiInsurance.InvalidMaxCoverageBps.selector, uint256(0), uint256(10_000))
        );
        defi.addInsuredToken(IERC20(address(lp3)), 0, MIN_CLAIM, FEED, address(0), "");
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InvalidMinClaimAmount.selector, uint256(0)));
        defi.addInsuredToken(IERC20(address(lp3)), 8000, 0, FEED, address(0), "");
        vm.stopPrank();
    }

    function test_ConversionRecipeValidationIsTrustedToTimelock() public {
        MockConversionRecipe converter = new MockConversionRecipe(0);
        bytes memory cd = abi.encodeCall(MockConversionRecipe.convertToAssets, (1e18));

        vm.prank(admin);
        defi.setUnderlyingConversion(IERC20(address(lp1)), address(converter), cd);

        DefiInsurance.InsuredToken memory it = defi.getInsuredToken(IERC20(address(lp1)));
        assertEq(it.underlyingConversionAddress, address(converter));
        assertEq(it.underlyingConversionCallData, cd);
    }

    function test_ConversionRecipeUpdatable() public {
        // Mutable via setter: repoint lp1's token→underlying recipe in place.
        MockConversionRecipe converter = new MockConversionRecipe(1e18);
        bytes memory cd = abi.encodeCall(MockConversionRecipe.convertToAssets, (1e18));
        vm.prank(admin);
        defi.setUnderlyingConversion(IERC20(address(lp1)), address(converter), cd);
        DefiInsurance.InsuredToken memory it = defi.getInsuredToken(IERC20(address(lp1)));
        assertEq(it.underlyingConversionAddress, address(converter));
        assertEq(it.underlyingConversionCallData, cd);

        // And re-listing sets a fresh recipe.
        vm.startPrank(admin);
        defi.removeInsuredToken(IERC20(address(lp1)));
        defi.addInsuredToken(IERC20(address(lp1)), 8000, MIN_CLAIM, FEED, address(converter), cd);
        vm.stopPrank();
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).underlyingConversionAddress, address(converter));
    }

    function test_MinClaimAmountUpdatable() public {
        uint128 updatedMinimum = 25e18;
        vm.prank(admin);
        defi.setMinClaimAmount(IERC20(address(lp1)), updatedMinimum);
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).minClaimAmount, updatedMinimum);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InvalidMinClaimAmount.selector, uint256(0)));
        defi.setMinClaimAmount(IERC20(address(lp1)), 0);
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
            DefiInsurance.SettlementParams({twapLookbackBlocks: 1, holdingMarginBlocks: 1, sampleStepBlocks: 1});
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
        vm.startPrank(admin);
        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        defi.setMaxCoverageBps(IERC20(address(lp1)), 5000);
        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        defi.setMinClaimAmount(IERC20(address(lp1)), 25e18);
        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        defi.setUnderlyingPriceOracle(IERC20(address(lp1)), FEED);
        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        defi.removeInsuredToken(IERC20(address(lp2)));
        vm.stopPrank();
    }

    function test_ZeroSampleStepReverts() public {
        DefiInsurance.SettlementParams memory p =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 50, holdingMarginBlocks: 20, sampleStepBlocks: 0});
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.InvalidSettlementParams.selector);
        defi.setSettlementParams(p);
    }

    function test_OpenBlockRecordedForOffchainConfigRecompute() public {
        DefiInsurance.SettlementParams memory p =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 50, holdingMarginBlocks: 20, sampleStepBlocks: 5});
        vm.prank(admin);
        defi.setSettlementParams(p);

        uint64 expectedOpen = uint64(block.number);
        _registerClaim(bob, lp1, 50e18); // opens incident 1

        // The incident records only its open block; off-chain reconstructs the
        // full config (recipe, params, scored-token set) from state as of it.
        (,,,,,, uint64 openBlock,,,) = defi.incidents(1);
        assertEq(openBlock, expectedOpen);

        // Config is frozen while the incident is live, so the openBlock read
        // can't be desynced by a mid-incident retune — setSettlementParams reverts.
        DefiInsurance.SettlementParams memory p2 =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 999, holdingMarginBlocks: 1, sampleStepBlocks: 1});
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        defi.setSettlementParams(p2);
    }

    function test_AdminCanRemoveInsuredToken() public {
        vm.prank(admin);
        defi.removeInsuredToken(IERC20(address(lp2)));
        assertEq(defi.insuredTokenListLength(), 1);
        uint256 cov = defi.getInsuredToken(IERC20(address(lp2))).maxCoverageBps;
        assertEq(cov, 0); // maxCoverageBps == 0 ⇒ delisted
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

        vm.warp(block.timestamp + pool.EXIT_BATCH_INTERVAL());
        vm.prank(bob);
        pool.requestRedeem(bobShares);
        (, uint64 bobExitEpoch) = pool.exitRequests(bob);
        assertGt(bobExitEpoch, aliceExitEpoch);

        vm.warp(bobExitEpoch);
        assertEq(pool.settleMaturedExitEpochs(1), 1);
        assertEq(pool.nextExitEpochIndex(), 1);
        (,,,, bool aliceSettled) = pool.exitEpochs(aliceExitEpoch);
        (,,,, bool bobSettled) = pool.exitEpochs(bobExitEpoch);
        assertTrue(aliceSettled);
        assertFalse(bobSettled);

        assertEq(pool.settleMaturedExitEpochs(1), 1);
        assertEq(pool.nextExitEpochIndex(), 2);
        (,,,, bobSettled) = pool.exitEpochs(bobExitEpoch);
        assertTrue(bobSettled);
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

        // Settle so the incident stays active through its dispute/finalize phases
        // (otherwise it would void at the submit deadline = 8d).
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

        // Resolve the incident with a 40-USDC loss first.
        vm.warp(incidentOpenedAt + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + defi.DISPUTE_PERIOD() + 1);
        _finalize(cid, amounts, 0);
        assertEq(defi.activeIncidentId(), 0);

        // Only now does settlement reserve Alice's post-loss pro-rata value.
        uint256 expectedAssets = pool.previewRedeem(exitingShares);
        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), expectedAssets);
        assertEq(expectedAssets, 80e6);
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
        vm.warp(block.timestamp + defi.DISPUTE_PERIOD() + 1);
        _finalize(cid, amounts, 0);
        assertLt(block.timestamp, exitEpoch, "incident resolves inside cooldown");

        vm.warp(exitEpoch);
        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 60e6, "cooldown exit absorbs resolved incident loss");
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
        (IERC20 tok, uint64 wEnd, bytes32 root, uint256 unresolved,,,,,,) = defi.incidents(1);
        assertEq(address(tok), address(lp1));
        assertEq(wEnd, uint64(block.timestamp) + defi.CLAIM_WINDOW());
        assertEq(root, bytes32(0));
        assertEq(unresolved, 1);
        assertEq(defi.activeIncidentId(), 1);
        // Still listed at open: delisting is deferred to root submission.
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
        (,,, uint256 unresolved,,,,,,) = defi.incidents(1);
        assertEq(unresolved, 2);
        assertEq(defi.nextIncidentId(), 2);
    }

    function test_JoinRejectsClaimBelowInsuredTokenMinimum() public {
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));

        uint128 amount = MIN_CLAIM - 1;
        lp1.mint(bob, amount);
        vm.startPrank(bob);
        lp1.approve(address(defi), amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                DefiInsurance.ClaimBelowMinimum.selector, IERC20(address(lp1)), uint256(amount), uint256(MIN_CLAIM)
            )
        );
        defi.joinClaim(IERC20(address(lp1)), amount, 0, 0, 0, "");
        vm.stopPrank();
    }

    function test_JoinMinimumUsesActualReceivedAmount() public {
        MockFeeToken feeToken = new MockFeeToken(100); // sends 99% of requested amount
        uint128 minimum = 100e18;
        vm.startPrank(admin);
        defi.addInsuredToken(IERC20(address(feeToken)), 8000, minimum, FEED, address(0), "");
        defi.openClaimIncident(IERC20(address(feeToken)), uint64(block.number - 1));
        vm.stopPrank();

        feeToken.mint(bob, minimum);
        vm.startPrank(bob);
        feeToken.approve(address(defi), minimum);
        vm.expectRevert(
            abi.encodeWithSelector(
                DefiInsurance.ClaimBelowMinimum.selector, IERC20(address(feeToken)), uint256(99e18), uint256(minimum)
            )
        );
        defi.joinClaim(IERC20(address(feeToken)), minimum, 0, 0, 0, "");
        vm.stopPrank();

        assertEq(feeToken.balanceOf(address(defi)), 0);
        assertEq(feeToken.balanceOf(bob), minimum);
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

    /// @dev I1: a referenceBlock older than MAX_REFERENCE_BLOCK_AGE is rejected, so
    ///      a stale (unrelayed) open attestation effectively expires.
    function test_OpenRejectsStaleReferenceBlock() public {
        vm.roll(1_000_000);
        uint64 maxAge = defi.MAX_REFERENCE_BLOCK_AGE();
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

    /// @dev I2: a booster amount above uint128 is rejected, so the stored value can
    ///      never diverge from the uint256 emitted in ClaimRegistered.
    function test_JoinRejectsBoosterAmountAboveUint128() public {
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.BoosterAmountTooLarge.selector, tooBig));
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, tooBig, 0, "");
        vm.stopPrank();
    }

    function test_JoinWithoutOpenIncidentReverts() public {
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        // No live claim: a bare join (referenceBlock 0, empty sig) falls into the open
        // branch and reverts inside ECDSA on the empty signature — you can't just join.
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(0)));
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, 0, 0, "");
        vm.stopPrank();
    }

    /// @dev The permissionless open path: with no live claim, the first joinClaim
    ///      carrying a valid TEE open attestation opens the incident and registers the
    ///      claim; a later claimant then joins with no attestation.
    function test_FirstJoinOpensWithTeeSig() public {
        uint64 refBlock = uint64(block.number - 1);
        bytes memory sig = _teeSignOpen(address(lp1), refBlock);

        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        uint256 cid = defi.joinClaim(IERC20(address(lp1)), 50e18, 0, 0, refBlock, sig);
        vm.stopPrank();

        uint256 id = defi.activeIncidentId();
        assertTrue(id != 0);
        (IERC20 tok,,,,, uint64 stored,,,,) = defi.incidents(id);
        assertEq(address(tok), address(lp1));
        assertEq(stored, refBlock);
        assertEq(defi.activeClaimId(id, bob), cid);

        // A second claimant joins the now-live claim with no attestation (0, "").
        lp1.mint(carol, 30e18);
        vm.startPrank(carol);
        lp1.approve(address(defi), 30e18);
        uint256 cid2 = defi.joinClaim(IERC20(address(lp1)), 30e18, 0, 0, 0, "");
        vm.stopPrank();
        assertEq(defi.activeClaimId(id, carol), cid2);
    }

    function test_OpenSignatureIsInvalidatedByPcrRotation() public {
        uint64 refBlock = uint64(block.number - 1);
        bytes memory staleSig = _teeSignOpen(address(lp1), refBlock);

        vm.prank(admin);
        registry.setTeePcrHash(bytes32(uint256(0xBEEF)));

        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        vm.expectRevert();
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, 0, refBlock, staleSig);
        vm.stopPrank();
    }

    /// @dev Once a claim is live, a join that still carries an open attestation
    ///      (non-zero referenceBlock or non-empty signature) is rejected.
    function test_JoinRejectsOpenAttestationWhenLive() public {
        _registerClaim(bob, lp1, 50e18); // opens incident 1

        lp1.mint(carol, 30e18);
        vm.startPrank(carol);
        lp1.approve(address(defi), 30e18);
        vm.expectRevert(DefiInsurance.UnexpectedOpenAttestation.selector);
        defi.joinClaim(IERC20(address(lp1)), 30e18, 0, 0, uint64(block.number - 1), "");
        vm.stopPrank();
    }

    /// @dev With no live claim, a first join whose open attestation is signed by a
    ///      non-TEE key reverts UnauthorizedOpenSigner(recovered).
    function test_FirstJoinRejectsBadOpenSig() public {
        uint64 refBlock = uint64(block.number - 1);
        bytes memory badSig = _signOpen(0xBAD, address(lp1), refBlock);

        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.UnauthorizedOpenSigner.selector, vm.addr(0xBAD)));
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, 0, refBlock, badSig);
        vm.stopPrank();
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

    function test_OneClaimPerAccountPerIncident() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18); // opens incident 1, bob joins

        // A second claim by bob in the same incident reverts.
        lp1.mint(bob, 20e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 20e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.DuplicateClaim.selector, uint256(1)));
        defi.joinClaim(IERC20(address(lp1)), 20e18, 0, 0, 0, "");
        vm.stopPrank();

        // After cancelling, bob may re-file within the window.
        vm.prank(bob);
        defi.cancelClaim();
        vm.startPrank(bob);
        lp1.approve(address(defi), 20e18);
        uint256 cid2 = defi.joinClaim(IERC20(address(lp1)), 20e18, 0, 0, 0, "");
        vm.stopPrank();
        assertGt(cid2, cid);
    }

    function test_ClaimAfterWindowReverts() public {
        _registerClaim(bob, lp1, 50e18);
        (, uint64 wEnd,,,,,,,,) = defi.incidents(1);
        vm.warp(wEnd + 1);

        lp1.mint(carol, 30e18);
        vm.startPrank(carol);
        lp1.approve(address(defi), 30e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, IERC20(address(lp1)), wEnd));
        defi.joinClaim(IERC20(address(lp1)), 30e18, 0, 0, 0, "");
        vm.stopPrank();
    }

    function test_RelistedTokenOpensFreshIncident() public {
        uint256 cid1 = _registerClaim(bob, lp1, 50e18);
        // Submit a root: this is what delists lp1 (a confirmed event).
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, cid1, bob, _amounts(0)));
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).maxCoverageBps, 0); // delisted at root
        // Let incident 1 fully resolve (dispute + finalize windows elapse).
        vm.warp(block.timestamp + 2 days + 4 days + 1);

        // Delisted by settlement: governance must re-list before a new incident.
        vm.prank(admin);
        defi.addInsuredToken(IERC20(address(lp1)), 8000, MIN_CLAIM, FEED, address(0), "");
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
        (,,, uint256 unresolved,,,,,,) = defi.incidents(1);
        assertEq(unresolved, 0); // join ++ then cancel -- back to zero
    }

    function test_CancelAfterWindowReverts() public {
        _registerClaim(bob, lp1, 50e18);
        (, uint64 wEnd,,,,,,,,) = defi.incidents(1);
        vm.warp(wEnd + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, IERC20(address(lp1)), wEnd));
        defi.cancelClaim();
    }

    function test_CancelByNonClaimantReverts() public {
        _registerClaim(bob, lp1, 50e18); // bob's claim; carol has none
        vm.prank(carol);
        vm.expectRevert(DefiInsurance.NoActiveClaim.selector);
        defi.cancelClaim();
    }

    function test_WithdrawClaimAfterVoidIncident() public {
        // No root ever submitted -> incident void at windowEnd + 3d.
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimNotWithdrawable.selector, cid));
        defi.withdrawNonFinalizedClaim(cid);

        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
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
        // Incident no longer active ⇒ no live claim derivable; escrow recovery is the path.
        vm.expectRevert(DefiInsurance.NoActiveClaim.selector);
        defi.finalizeClaim(_amounts(40e6), 0, 0, 50e18, new bytes32[](0));

        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
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

        (,, bytes32 storedRoot,,,,,,,) = defi.incidents(1);
        assertEq(storedRoot, root);
        // amounts[] align to the (incident-stable) pool asset list.
        (IERC20[] memory list,) = registry.coverPools();
        assertEq(list.length, 1);
        assertEq(address(list[0]), address(usdc));
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

    /// @dev Settlement is single-shot: once a root is set, any resubmit reverts
    ///      AlreadySettled — same root, different root, or after finalize opens. A bad
    ///      root is handled by dispute → correct, not by overwrite. This also makes
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

        // Nor after the dispute period elapses (finalize open) while the settle window
        // is still open — the overlap that would have reset the budget mid-payout.
        vm.warp(block.timestamp + 2 days + 1);
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

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(bob);
        vm.expectRevert(DefiInsurance.NoActiveClaim.selector);
        defi.finalizeClaim(amounts, 0, 0, 50e18, new bytes32[](0));

        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
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
        vm.warp(block.timestamp + 2 days + 1);
        uint256[] memory noPayouts = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentFinalizing.selector, uint256(1)));
        vm.prank(admin);
        defi.adminCorrectSettlement(bytes32(0), noPayouts);
    }

    /// @dev A late TEE root still receives its full dispute period and cannot be
    ///      overwritten through the signed settlement path.
    function test_LateSubmissionCannotBeOverwritten() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 3 days); // settle at the submit deadline
        _settle(1, _leaf(1, cid, bob, _amounts(0)));

        // Already settled: no resubmit/overwrite (the root check precedes the phase check).
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
        (, uint64 windowEnd,,,,,,,,) = defi.incidents(1);
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
        (,,, uint256 unresolved,,,,,, bytes32 claimSetHash) = defi.incidents(incidentId);
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
                    "Settlement(uint256 incidentId,bytes32 root,uint256 unresolved,uint256[] poolPayouts,bytes32 pools,bytes32 claimSet,bytes32 teePcrHash)"
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

    function _signSettlement(uint256 privateKey, uint256 incidentId, bytes32 root, uint256[] memory pp)
        internal
        view
        returns (bytes memory)
    {
        return _signSettlementWithPcr(privateKey, incidentId, root, pp, defi.incidentTeePcrHash(incidentId));
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
        vm.prank(user);
        defi.finalizeClaim(amounts, scoreSpent, scoreSpent, escrow, new bytes32[](0));
    }

    /// @dev EIP-712 IncidentOpen signature over token, referenceBlock,
    ///      nextIncidentId, and current PCR — mirrors joinClaim.
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
                    "IncidentOpen(address insuredToken,uint64 referenceBlock,uint256 incidentId,bytes32 teePcrHash)"
                ),
                token,
                referenceBlock,
                defi.nextIncidentId(),
                registry.teePcrHash()
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Open an incident claim-lessly on token (admin fallback). The permissionless
    ///      TEE-attested open now happens inside the first joinClaim; see
    ///      test_FirstJoinOpensWithTeeSig for that path.
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
        vm.warp(block.timestamp + 5 days + 3 days + 1); // past claim + submit window
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

        // The second authorized enclave opens the incident through the permissionless
        // first-claim path while the original signer remains authorized.
        uint64 refBlock = uint64(block.number - 1);
        bytes memory openSig = _signOpen(SECOND_TEE_PK, address(lp1), refBlock);
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        uint256 cid = defi.joinClaim(IERC20(address(lp1)), 50e18, 0, 0, refBlock, openSig);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root = _leaf(1, cid, bob, _amounts(0));
        uint256[] memory pp = _pp();

        // The same second enclave may also authorize settlement; the caller is only
        // a permissionless relay and need not itself be in the signer set.
        bytes memory settlementSig = _signSettlement(SECOND_TEE_PK, 1, root, pp);
        vm.prank(carol);
        defi.settleIncident(root, pp, settlementSig);
        (,, bytes32 stored,,,,,,,) = defi.incidents(1);
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
        (,, bytes32 stored,,,,,,,) = defi.incidents(1);
        assertEq(stored, root);
    }

    function test_SettleDerivesOpeningPcrFromStorageAfterEmergencyRegistryChange() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        assertEq(defi.incidentTeePcrHash(1), TEST_TEE_PCR_HASH);

        vm.startPrank(admin);
        registry.setDefiInsurance(address(0));
        registry.setTeePcrHash(UPDATED_TEE_PCR_HASH);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root = _leaf(1, cid, bob, _amounts(0));
        uint256[] memory pp = _pp();
        bytes memory sig = _signSettlementWithPcr(TEE_PK, 1, root, pp, TEST_TEE_PCR_HASH);
        defi.settleIncident(root, pp, sig);

        (,, bytes32 stored,,,,,,,) = defi.incidents(1);
        assertEq(stored, root);
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

    // ════════════════════ Finalize ════════════════════

    function test_FinalizeSingleClaim() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory amounts = _amounts(20e6);
        bytes32 root = _leaf(1, cid, bob, amounts);
        _settle(1, root);

        // Not open during the dispute period.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(amounts, 0, 0, 50e18, new bytes32[](0));

        vm.warp(block.timestamp + 4 days + 1);
        _finalize(cid, amounts, 0);

        assertEq(usdc.balanceOf(bob), 20e6);
        assertEq(pool.totalAssets(), 80e6);
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
        defi.finalizeClaim(amountsBob, 0, 0, 50e18, proofBob);

        bytes32[] memory proofCarol = new bytes32[](1);
        proofCarol[0] = leafBob;
        vm.prank(carol);
        defi.finalizeClaim(amountsCarol, 0, 0, 50e18, proofCarol);

        assertEq(usdc.balanceOf(bob), 40e6);
        assertEq(usdc.balanceOf(carol), 20e6);
        assertEq(pool.totalAssets(), 240e6);
    }

    /// @dev F1: on an honest root the committed budget == Σ leaf amounts, so the
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
        pp[0] = 80e6; // == 40 + 40, the exact leaf sum
        defi.settleIncident(root, pp, _teeSign(1, root, pp));
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory pB = new bytes32[](1);
        pB[0] = lC;
        vm.prank(bob);
        defi.finalizeClaim(aB, 0, 0, 50e18, pB);
        bytes32[] memory pC = new bytes32[](1);
        pC[0] = lB;
        vm.prank(carol);
        defi.finalizeClaim(aC, 0, 0, 50e18, pC);

        assertEq(usdc.balanceOf(bob), 40e6);
        assertEq(usdc.balanceOf(carol), 40e6);
    }

    /// @dev F1: a malformed root whose leaves over-allocate a pool (Σ 80e6 >
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
        defi.finalizeClaim(aB, 0, 0, 50e18, pB); // budget 50e6 -> 10e6

        bytes32[] memory pC = new bytes32[](1);
        pC[0] = lB;
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.PayoutCapExceeded.selector, 0, 40e6, 10e6));
        defi.finalizeClaim(aC, 0, 0, 50e18, pC); // 40e6 > 10e6 remaining

        assertEq(usdc.balanceOf(bob), 40e6); // early claim paid
        assertEq(usdc.balanceOf(carol), 0); // late claim capped out; recovers escrow later
        assertEq(pool.totalAssets(), 260e6); // pool lost only 40e6, never past the 50e6 budget
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
        bytes32 lB = _leafSpent(1, cb, bob, aB, 0, 0, 50e18); // eligible = E/2
        bytes32 lC = _leafSpent(1, cc, carol, aC, 0, 0, 100e18); // eligible > escrow
        _settle(1, _hashPair(lB, lC));
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory pB = new bytes32[](1);
        pB[0] = lC;
        vm.prank(bob);
        defi.finalizeClaim(aB, 0, 0, 50e18, pB);

        // Refund = escrow − eligible = 50e18; the full 100e18 left the escrow ledger.
        assertEq(lp1.balanceOf(bob), 50e18);
        assertEq(usdc.balanceOf(bob), 20e6); // payout still delivered
        assertEq(defi.escrowedInsuredTokens(IERC20(address(lp1))), 50e18); // only carol's escrow left

        // eligible above escrow is rejected (guards a malformed leaf).
        bytes32[] memory pC = new bytes32[](1);
        pC[0] = lB;
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.EligibleExceedsEscrow.selector, 100e18, 50e18));
        defi.finalizeClaim(aC, 0, 0, 100e18, pC);
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
        defi.finalizeClaim(_amounts(90e6), 0, 0, 50e18, new bytes32[](0));
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
        defi.finalizeClaim(aB, 0, 0, 50e18, proofB);

        // Second finalize by bob: his claim is resolved, but carol's keeps the incident
        // active so the claim is still derivable and the resolved guard fires.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimAlreadyResolved.selector, cb));
        defi.finalizeClaim(aB, 0, 0, 50e18, proofB);
    }

    function test_PayoutExceedingPoolBalanceReverts() public {
        // Root says pay 500 USDC but the pool only holds 100 (cap = 80). An honest
        // root never over-allocates, so this is a corrupt root: the per-incident
        // budget draw-down catches it first and fails the finalize loudly — bob
        // recovers his escrow via withdrawNonFinalizedClaim. (_settle commits
        // poolPayouts = maxPayoutPerIncident() = 80e6 via _pp.)
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(500e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);

        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.PayoutCapExceeded.selector, 0, 500e6, 80e6));
        vm.prank(bob);
        defi.finalizeClaim(amounts, 0, 0, 50e18, new bytes32[](0));

        // Escrow recoverable once the finalize window lapses.
        vm.warp(block.timestamp + 4 days + 4 days + 1);
        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
        assertEq(lp1.balanceOf(bob), 50e18);
        assertEq(pool.totalAssets(), 100e6); // pool untouched
    }

    function test_StakeBlockedDuringIncidentThenResumes() public {
        _stake(alice, 100e6);
        _registerClaim(bob, lp1, 50e18); // opens incident 1

        usdc.mint(carol, 100e6);
        vm.startPrank(carol);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(SingleAssetCoverPool.PoolFrozen.selector);
        pool.deposit(100e6, carol);
        vm.stopPrank();

        // Incident voids after the dispute period -> staking reopens.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(carol);
        pool.deposit(100e6, carol);
        assertGt(pool.balanceOf(carol), 0);
    }

    /// @dev Finalizing the last claim unlocks the pool immediately.
    function test_AllClaimsFinalizedUnlocksPoolEarly() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18); // incident 1, one claim
        vm.warp(block.timestamp + 5 days + 1); // claim window ends
        _settle(1, _leaf(1, cid, bob, _amounts(40e6)));

        vm.warp(block.timestamp + 2 days + 1); // into the finalize window
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
    ///      (withdrawNonFinalizedClaim) must stay open so a pause can't trap funds.
    function test_DefiPauseBlocksIntakeNotEscrowRecovery() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18); // opens incident 1, bob escrows
        vm.prank(admin);
        registry.setPaused(address(defi), true);

        // Intake blocked.
        lp1.mint(carol, 50e18);
        vm.startPrank(carol);
        lp1.approve(address(defi), 50e18);
        vm.expectRevert(Registry.Paused.selector);
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, 0, 0, "");
        vm.stopPrank();

        // Void the incident, then recover escrow despite the pause.
        vm.warp(block.timestamp + 5 days + 3 days + 1); // past SUBMIT_DEADLINE → VOID
        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
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
        (,, bytes32 stored,,,,,,,) = defi.incidents(1);
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

    // ════════════════════ Boosters & score ════════════════════

    /// @dev Admin opens an incident on token; user joins committing qty
    ///      units of the canonical booster (id 1).
    function _openWithBooster(address user, MockERC20 token, uint128 amount, uint256 qty)
        internal
        returns (uint256 claimId)
    {
        token.mint(user, amount);
        booster.mint(user, defi.BOOSTER_ID(), qty);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(token)), uint64(block.number - 1));
        vm.startPrank(user);
        token.approve(address(defi), amount);
        booster.setApprovalForAll(address(defi), true);
        claimId = defi.joinClaim(IERC20(address(token)), amount, 0, qty, 0, "");
        vm.stopPrank();
    }

    function test_BoosterEscrowedOnOpen() public {
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 3);
        assertEq(booster.balanceOf(bob, 1), 0);
        assertEq(booster.balanceOf(address(defi), 1), 3);
        assertEq(defi.getClaimBoosterAmount(cid), 3);
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
        assertEq(defi.getClaimBoosterAmount(cid), 3); // preserve committed-and-burned amount on-chain
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
        defi.finalizeClaim(amounts, 100, 102, 50e18, new bytes32[](0));
    }

    function test_JoinRevertsWithoutBoosterApproval() public {
        lp1.mint(bob, 50e18);
        booster.mint(bob, defi.BOOSTER_ID(), 3);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        vm.expectRevert();
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, 3, 0, "");
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
        booster.mint(bob, defi.BOOSTER_ID(), 3);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        booster.setApprovalForAll(address(defi), true);
        uint256 cid = defi.joinClaim(IERC20(address(lp1)), 50e18, 500, 3, 0, "");
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leafSpent(1, cid, bob, amounts, 500, 515, 50e18));
        vm.warp(block.timestamp + 4 days + 1);

        assertEq(registry.scoreSpent(bob), 0);
        vm.expectEmit(true, true, false, true, address(defi));
        emit DefiInsurance.ScoreSpent(bob, 500, 1);
        vm.prank(bob);
        defi.finalizeClaim(amounts, 500, 515, 50e18, new bytes32[](0));
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
        // Void: no root through the dispute period.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
        assertEq(booster.balanceOf(bob, 1), 3);
        assertEq(booster.balanceOf(address(defi), 1), 0);
    }

    function test_SetBoosterNFTBlockedDuringIncident() public {
        _registerClaim(bob, lp1, 50e18); // opens an incident -> system frozen
        vm.prank(admin);
        vm.expectRevert(Registry.Frozen.selector);
        registry.setBoosterNFT(address(0xBEEF));

        // Resolves after the dispute period -> setting reopens.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(admin);
        registry.setBoosterNFT(address(0xBEEF));
        assertEq(registry.boosterNFT(), address(0xBEEF));
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

    function test_BoosterCommitRequiresNftSet() public {
        vm.prank(admin);
        registry.setBoosterNFT(address(0));

        booster.mint(bob, 1, 1);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        booster.setApprovalForAll(address(defi), true);
        vm.expectRevert(DefiInsurance.BoosterNFTUnset.selector);
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, 1, 0, "");
        vm.stopPrank();
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

        // 200 -> 120 USDC backing the same shares; both stakers diluted equally.
        vm.warp(block.timestamp + 5 days + 1); // finalize window over, queue clears
        uint256 aliceOut = _completeUnstakeAfterCooldown(alice, pool.balanceOf(alice));
        assertEq(aliceOut, 60e6);
    }

    function test_UnstakeBlockedThroughPhasesThenUnblocks() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.prank(alice);
        pool.requestRedeem(50e6 * VS);
        (, uint64 exitEpoch) = pool.exitRequests(alice);

        // Before the exit epoch, cooldown is still the first gate.
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SingleAssetCoverPool.CooldownNotElapsed.selector, exitEpoch));
        pool.completeRedeem(alice);

        // Settle within the submit window.
        vm.warp(block.timestamp + 4 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(10e6)));

        // Once matured, the already-open incident holds settlement until resolution.
        vm.warp(exitEpoch);
        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.PoolFrozen.selector);
        pool.completeRedeem(alice);

        vm.warp(block.timestamp + 2 days + 1);
        _finalize(cid, _amounts(10e6), 0);

        vm.prank(alice);
        assertEq(pool.completeRedeem(alice), 45e6);
    }

    function test_UnstakeUnblocksAfterVoidIncident() public {
        _stake(alice, 100e6);
        _registerClaim(bob, lp1, 50e18);

        vm.prank(alice);
        pool.requestRedeem(50e6 * VS);
        (, uint64 exitEpoch) = pool.exitRequests(alice);

        // No root submitted: once the incident voids, the matured exit can settle.
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
        // No root submitted: incident 1 voids at windowEnd + dispute period.
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

        // Fast admin can run reward ops (the emission window) but not curate.
        vm.prank(fastAdmin);
        pool.setRewardsDuration(14 days);
        assertEq(pool.rewardsDuration(), 14 days);

        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, fastAdmin));
        vm.prank(fastAdmin);
        defi.setMaxCoverageBps(IERC20(address(lp1)), 7000);

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
        defi.addInsuredToken(IERC20(address(tok)), 8000, MIN_CLAIM, FEED, address(0), "");

        _stake(alice, 100e6); // pool capital to pay from

        uint128 escrow = 100e18;
        tok.mint(bob, escrow);
        vm.prank(bob);
        tok.approve(address(defi), escrow);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(tok)), uint64(block.number - 1));
        vm.prank(bob);
        uint256 claimId = defi.joinClaim(IERC20(address(tok)), escrow, 0, 0, 0, "");

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(20e6);
        uint256 eligible = 60e18; // < escrow → 40e18 refund fires the probe
        _settle(1, _leafSpent(1, claimId, bob, amounts, 0, 0, eligible));
        vm.warp(block.timestamp + defi.DISPUTE_PERIOD() + 1);

        vm.prank(bob);
        defi.finalizeClaim(amounts, 0, 0, eligible, new bytes32[](0));

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
    ///      dispute, no timelock); the corrected root runs its own fresh DISPUTE
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

        // Fresh DISPUTE window on the corrected root, then pay the corrected amount.
        vm.warp(block.timestamp + defi.DISPUTE_PERIOD() + 1);
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
        defi.finalizeClaim(amounts, 0, 0, 50e18, new bytes32[](0));

        // Window closes: join and cancel are now out of phase.
        (, uint64 wEnd,,,,,,,,) = defi.incidents(1);
        vm.warp(wEnd + 1);
        lp1.mint(carol, 10e18);
        vm.startPrank(carol);
        lp1.approve(address(defi), 10e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, lp1, wEnd));
        defi.joinClaim(IERC20(address(lp1)), 10e18, 0, 0, 0, "");
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, lp1, wEnd));
        defi.cancelClaim();

        // SETTLE phase: root lands; finalize still gated by the DISPUTE period.
        _settle(1, root);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(amounts, 0, 0, 50e18, new bytes32[](0));

        // A beta correction restarts a fresh dispute clock, so finalize is gated again.
        vm.prank(admin);
        defi.adminCorrectSettlement(root, pp);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(amounts, 0, 0, 50e18, new bytes32[](0));

        // Once the corrected root's dispute period passes, finalization retires it.
        vm.warp(block.timestamp + defi.DISPUTE_PERIOD() + 1);
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
                        DefiInsurance.joinClaim,
                        (REENTRY_TOKEN, reentryAmount, uint256(0), uint256(0), REFERENCE_BLOCK, reentrySignature)
                    )
                );
            reentrySucceeded = ok;
            reentryReturndata = returndata;
        }
        return 0;
    }
}
