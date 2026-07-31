// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC1155} from "../mocks/MockERC1155.sol";

contract SettlementInvariantFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

abstract contract InsuranceSettlementBase is StdInvariant, Test {
    MockERC20 internal usdc;
    MockERC20 internal insuredToken;
    MockERC1155 internal booster;
    Registry internal registry;
    USD8 internal usd8;
    DefiInsurance internal defi;
    SingleAssetCoverPool internal pool;
    SettlementInvariantFeed internal feed;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant ALICE = address(0xBEEF);
    address internal constant BOB = address(0xB0B);
    address internal constant LP = address(0x1F00D);
    uint128 internal constant MIN_CLAIM = 10e18;
    uint64 internal constant BOOSTER_ID = 1;
    uint16 internal constant BOOSTER_BOOST_BPS = 100;
    uint256 internal constant TEE_PK = 0x7EE;
    bytes32 internal constant TEE_PCR_HASH = keccak256("settlement-invariant-pcr");

    function _setUpSettlementProtocol() internal {
        vm.roll(1_000);
        feed = new SettlementInvariantFeed();
        usdc = new MockERC20("USDC", "USDC", 6);
        insuredToken = new MockERC20("INSURED", "INS", 18);
        booster = new MockERC1155();

        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (ADMIN, ADMIN))))
        );
        vm.prank(ADMIN);
        registry.setTeePcrHash(TEE_PCR_HASH);

        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        vm.startPrank(ADMIN);
        registry.setUsd8(address(usd8));
        registry.setTreasury(ADMIN);
        vm.stopPrank();

        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new SingleAssetCoverPool()), ADMIN);
        pool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (registry, IERC20(address(usdc)), "Settlement Cover", "USD8-cp-USDC")
                    )
                )
            )
        );
        defi = DefiInsurance(
            address(
                new ERC1967Proxy(address(new DefiInsurance()), abi.encodeCall(DefiInsurance.initialize, (registry)))
            )
        );

        vm.startPrank(ADMIN);
        registry.setMaxCoverPoolPayoutBps(8_000);
        registry.addPool(address(pool), address(feed));
        registry.setBoosterConfig(address(booster), BOOSTER_ID, BOOSTER_BOOST_BPS);
        registry.setDefiInsurance(address(defi));
        defi.editInsuredToken(IERC20(address(insuredToken)), 8_000, address(feed), address(0), "");
        defi.setTeeSigner(vm.addr(TEE_PK), true);
        vm.stopPrank();
    }

    function _stake(address who, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        shares = pool.deposit(amount, who);
        vm.stopPrank();
    }

    function _fundBond(address user) internal {
        vm.prank(ADMIN);
        usd8.mint(user, 10e18);
        vm.prank(user);
        usd8.approve(address(defi), 10e18);
    }

    function _finalizeUnboosted(address user, uint256 claimId, uint256 payout, uint256 eligible) internal {
        vm.prank(user);
        defi.finalizeClaim(claimId, true, _amounts(payout), 1, 1, eligible, new bytes32[](0));
    }

    function _amounts(uint256 payout) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = payout;
    }

    function _grossPayout(uint256 incidentId, uint256 claimantPayout) internal view returns (uint256) {
        (,,,,,,,,, uint16 protocolFeeShareBps) = defi.incidents(incidentId);
        return Math.mulDiv(claimantPayout, 10_000, 10_000 - protocolFeeShareBps);
    }

    function _leaf(
        uint256 incidentId,
        uint256 claimId,
        address user,
        uint256 payout,
        uint256 scoreSpent,
        uint256 boostedScore,
        uint256 eligible
    ) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(incidentId, claimId, user, _amounts(payout), scoreSpent, boostedScore, eligible))
            )
        );
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("DefiInsurance")),
                keccak256(bytes("1")),
                block.chainid,
                address(defi)
            )
        );
    }

    function _settlementStructHash(uint256 incidentId, bytes32 root, uint256[] memory payouts)
        internal
        view
        returns (bytes32)
    {
        (,,,,,, uint256 unresolved, bytes32 claimSetHash, bytes32 pcrHash,) = defi.incidents(incidentId);
        (, address[] memory pools) = registry.coverPools();
        bytes32 settlementTypeHash = keccak256(
            "Settlement(uint256 incidentId,bytes32 root,uint256 unresolvedClaims,uint256[] poolPayouts,bytes32 pools,bytes32 claimSet,bytes32 teePcrHash)"
        );
        bytes32 payoutsHash = keccak256(abi.encodePacked(payouts));
        bytes32 poolsHash = keccak256(abi.encodePacked(pools));
        return keccak256(
            abi.encode(settlementTypeHash, incidentId, root, unresolved, payoutsHash, poolsHash, claimSetHash, pcrHash)
        );
    }

    function _settlementDigest(uint256 incidentId, bytes32 root, uint256[] memory payouts)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), _settlementStructHash(incidentId, root, payouts))
        );
    }

    function _signSettlement(uint256 incidentId, bytes32 root, uint256[] memory payouts)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEE_PK, _settlementDigest(incidentId, root, payouts));
        return abi.encodePacked(r, s, v);
    }

    function _openIncident() internal returns (uint256 incidentId) {
        if (!defi.isInsuredToken(IERC20(address(insuredToken)))) {
            vm.prank(ADMIN);
            defi.editInsuredToken(IERC20(address(insuredToken)), 8_000, address(feed), address(0), "");
        }
        vm.roll(block.number + 1);
        vm.prank(ADMIN);
        incidentId = defi.openClaimIncident(IERC20(address(insuredToken)), uint64(block.number - 1));
    }
}

/// @dev Stateless tracer retained as a fast, production-faithful signed-settlement fuzz test.
contract InsuranceSettlementLifecycleTracerTest is InsuranceSettlementBase {
    function setUp() public {
        _setUpSettlementProtocol();
    }

    function testFuzz_SignedSettlementFinalizationConservesValue(uint128 escrowSeed, uint256 payoutSeed) public {
        uint128 escrow = uint128(bound(escrowSeed, MIN_CLAIM, 1_000e18));
        _stake(ALICE, 1_000e6);
        uint256 incidentId = _openIncident();
        insuredToken.mint(BOB, escrow);
        _fundBond(BOB);
        vm.startPrank(BOB);
        insuredToken.approve(address(defi), escrow);
        uint256 claimId = defi.fileClaim(IERC20(address(insuredToken)), escrow, 1, 0, 0, "");
        vm.stopPrank();

        uint256 payout = bound(payoutSeed, 0, pool.maxPayoutPerIncident() * 8_000 / 10_000);
        uint256 eligible = uint256(escrow) / 2;
        bytes32 root = _leaf(incidentId, claimId, BOB, payout, 1, 1, eligible);
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(incidentId);
        vm.warp(claimDeadline + 1);
        uint256[] memory budget = _amounts(_grossPayout(incidentId, payout));
        defi.settleIncident(root, budget, _signSettlement(incidentId, root, budget));
        (,,,, uint64 phaseDeadline,,,,,) = defi.incidents(incidentId);
        vm.warp(phaseDeadline + 1);

        uint256 poolAssetsBefore = pool.totalAssets();
        uint256 bobUsdcBefore = usdc.balanceOf(BOB);
        vm.prank(BOB);
        defi.finalizeClaim(claimId, true, _amounts(payout), 1, 1, eligible, new bytes32[](0));

        assertEq(poolAssetsBefore - pool.totalAssets(), _grossPayout(incidentId, payout), "pool payout conservation");
        assertEq(usdc.balanceOf(BOB) - bobUsdcBefore, payout, "claimant payout");
        assertEq(insuredToken.balanceOf(BOB), uint256(escrow) - eligible, "escrow refund");
        assertEq(defi.escrowedInsuredTokens(IERC20(address(insuredToken))), 0, "escrow ledger");
        assertEq(defi.activeIncidentId(), 0, "incident not resolved");
    }

    function testFuzz_ExactSettlementBoundaries(uint128 escrowSeed, uint256 payoutSeed) public {
        uint128 escrow = uint128(bound(escrowSeed, MIN_CLAIM, 1_000e18));
        _stake(ALICE, 1_000e6);
        uint256 incidentId = _openIncident();
        insuredToken.mint(BOB, escrow);
        _fundBond(BOB);
        vm.startPrank(BOB);
        insuredToken.approve(address(defi), escrow);
        uint256 claimId = defi.fileClaim(IERC20(address(insuredToken)), escrow, 1, 0, 0, "");
        vm.stopPrank();

        uint256 payout = bound(payoutSeed, 0, pool.maxPayoutPerIncident() * 8_000 / 10_000);
        uint256[] memory budget = _amounts(_grossPayout(incidentId, payout));
        bytes32 root = _leaf(incidentId, claimId, BOB, payout, 1, 1, escrow);
        bytes memory signature = _signSettlement(incidentId, root, budget);
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(incidentId);

        vm.warp(claimDeadline);
        vm.expectRevert();
        defi.settleIncident(root, budget, signature);

        vm.warp(claimDeadline + registry.incidentTimingConfig().phaseWindow);
        defi.settleIncident(root, budget, signature);
        {
            (,,,, uint64 phaseDeadline,,,,,) = defi.incidents(incidentId);
            vm.warp(phaseDeadline);
            vm.prank(BOB);
            vm.expectRevert();
            defi.finalizeClaim(claimId, true, _amounts(payout), 1, 1, escrow, new bytes32[](0));
        }

        (,,,, uint64 phaseDeadline,,,,,) = defi.incidents(incidentId);
        vm.warp(uint256(phaseDeadline) + registry.incidentTimingConfig().phaseWindow);
        vm.prank(BOB);
        defi.finalizeClaim(claimId, true, _amounts(payout), 1, 1, escrow, new bytes32[](0));
        assertEq(defi.activeIncidentId(), 0, "boundary-finalized incident remained active");
    }

    function testFuzz_NonzeroCorrectionReplacesRootAndBudget(
        uint128 escrowSeed,
        uint256 oldPayoutSeed,
        uint256 newPayoutSeed
    ) public {
        uint128 escrow = uint128(bound(escrowSeed, MIN_CLAIM, 1_000e18));
        _stake(ALICE, 1_000e6);
        uint256 incidentId = _openIncident();
        insuredToken.mint(BOB, escrow);
        _fundBond(BOB);
        vm.startPrank(BOB);
        insuredToken.approve(address(defi), escrow);
        uint256 claimId = defi.fileClaim(IERC20(address(insuredToken)), escrow, 1, 0, 0, "");
        vm.stopPrank();

        uint256 oldPayout = bound(oldPayoutSeed, 0, pool.maxPayoutPerIncident() * 8_000 / 10_000);
        uint256 newPayout = bound(newPayoutSeed, 0, pool.maxPayoutPerIncident() * 8_000 / 10_000);
        uint256 oldEligible = uint256(escrow) / 2;
        uint256 newEligible = uint256(escrow) / 3;

        {
            bytes32 oldRoot = _leaf(incidentId, claimId, BOB, oldPayout, 1, 1, oldEligible);
            (,,,, uint64 claimDeadline,,,,,) = defi.incidents(incidentId);
            vm.warp(claimDeadline + 1);
            uint256[] memory oldBudget = _amounts(_grossPayout(incidentId, oldPayout));
            defi.settleIncident(oldRoot, oldBudget, _signSettlement(incidentId, oldRoot, oldBudget));
            (,,,, uint64 oldPhaseDeadline,,,,,) = defi.incidents(incidentId);
            vm.warp(oldPhaseDeadline - registry.incidentTimingConfig().phaseWindow + 1 days);

            bytes32 newRoot = _leaf(incidentId, claimId, BOB, newPayout, 1, 1, newEligible);
            uint256[] memory newBudget = _amounts(_grossPayout(incidentId, newPayout));
            vm.prank(ADMIN);
            defi.adminCorrectSettlement(newRoot, newBudget);
            (,,,, uint64 newPhaseDeadline, bytes32 committedRoot,,,,) = defi.incidents(incidentId);
            assertEq(committedRoot, newRoot, "corrected root not installed");
            assertGt(newPhaseDeadline, oldPhaseDeadline, "correction did not reset correction clock");
            vm.warp(newPhaseDeadline + 1);
        }

        uint256 poolBefore = pool.totalAssets();
        uint256 escrowBefore = defi.escrowedInsuredTokens(IERC20(address(insuredToken)));
        vm.expectRevert();
        _finalizeUnboosted(BOB, claimId, oldPayout, oldEligible);
        assertEq(pool.totalAssets(), poolBefore, "old proof changed pool assets");
        assertEq(defi.escrowedInsuredTokens(IERC20(address(insuredToken))), escrowBefore, "old proof changed escrow");

        _finalizeUnboosted(BOB, claimId, newPayout, newEligible);
        assertEq(
            poolBefore - pool.totalAssets(), _grossPayout(incidentId, newPayout), "corrected payout budget not used"
        );
    }

    function test_TwoClaimMerkleFinalizesInReverseOrder() public {
        _stake(LP, 1_000e6);
        uint256 incidentId = _openIncident();
        uint256 claimA = _joinTraceClaim(incidentId, ALICE, 100e18, 123e18, 2);
        uint256 claimB = _joinTraceClaim(incidentId, BOB, 80e18, 456e18, 1);
        uint256 boostedA = Math.mulDiv(123e18, 10_200, 10_000);
        uint256 boostedB = Math.mulDiv(456e18, 10_100, 10_000);
        bytes32 leafA = _leaf(incidentId, claimA, ALICE, 100e6, 123e18, boostedA, 40e18);
        bytes32 leafB = _leaf(incidentId, claimB, BOB, 200e6, 456e18, boostedB, 20e18);
        _settleTraceIncident(incidentId, _hashPair(leafA, leafB), 300e6);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafA;
        _finalizeTraceClaim(claimB, BOB, 200e6, 456e18, boostedB, 20e18, proof);
        proof[0] = leafB;
        _finalizeTraceClaim(claimA, ALICE, 100e6, 123e18, boostedA, 40e18, proof);

        assertEq(pool.totalAssets(), 625e6, "two-claim gross pool conservation");
        assertEq(registry.scoreSpent(ALICE), 123e18, "alice raw score");
        assertEq(registry.scoreSpent(BOB), 456e18, "bob raw score");
        assertEq(booster.totalSupply(BOOSTER_ID), 0, "boosters not burned");
        assertEq(defi.escrowedInsuredTokens(IERC20(address(insuredToken))), 0, "escrow not cleared");
        assertEq(insuredToken.balanceOf(address(defi)), 60e18, "eligible escrow conservation");
    }

    function _joinTraceClaim(uint256 incidentId, address user, uint128 escrow, uint256 score, uint128 boosterAmount)
        internal
        returns (uint256 claimId)
    {
        insuredToken.mint(user, escrow);
        _fundBond(user);
        booster.mint(user, BOOSTER_ID, boosterAmount);
        vm.startPrank(user);
        booster.setApprovalForAll(address(defi), true);
        insuredToken.approve(address(defi), escrow);
        claimId = defi.fileClaim(IERC20(address(insuredToken)), escrow, score, boosterAmount, 0, "");
        vm.stopPrank();
        assertEq(defi.claimIdByIncidentAndUser(incidentId, user), claimId, "incident/user claim index");
    }

    function _settleTraceIncident(uint256 incidentId, bytes32 root, uint256 payout) internal {
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(incidentId);
        vm.warp(claimDeadline + 1);
        uint256[] memory budget = _amounts(_grossPayout(incidentId, payout));
        defi.settleIncident(root, budget, _signSettlement(incidentId, root, budget));
        (,,,, uint64 phaseDeadline,,,,,) = defi.incidents(incidentId);
        vm.warp(phaseDeadline + 1);
    }

    function _finalizeTraceClaim(
        uint256 claimId,
        address user,
        uint256 payout,
        uint256 score,
        uint256 boostedScore,
        uint256 eligible,
        bytes32[] memory proof
    ) internal {
        vm.prank(user);
        defi.finalizeClaim(claimId, true, _amounts(payout), score, boostedScore, eligible, proof);
    }
}

/// @dev Two-pool tracer proves payout-array ordering, per-pool budget isolation,
/// and conservation across heterogeneous pool assets.
contract InsuranceSettlementMultiPoolTracerTest is InsuranceSettlementBase {
    MockERC20 internal secondAsset;
    SingleAssetCoverPool internal secondPool;

    function setUp() public {
        _setUpSettlementProtocol();
        secondAsset = new MockERC20("WETH", "WETH", 18);
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new SingleAssetCoverPool()), ADMIN);
        secondPool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (registry, IERC20(address(secondAsset)), "WETH Cover", "USD8-cp-WETH")
                    )
                )
            )
        );
        vm.prank(ADMIN);
        registry.addPool(address(secondPool), address(feed));
    }

    function testFuzz_TwoPoolPayoutsConserveEachAsset(
        uint128 escrowSeed,
        uint256 firstPayoutSeed,
        uint256 secondPayoutSeed
    ) public {
        uint128 escrow = uint128(bound(escrowSeed, MIN_CLAIM, 1_000e18));
        _stake(ALICE, 1_000e6);
        secondAsset.mint(ALICE, 1_000e18);
        vm.startPrank(ALICE);
        secondAsset.approve(address(secondPool), type(uint256).max);
        secondPool.deposit(1_000e18, ALICE);
        vm.stopPrank();

        uint256 incidentId = _openIncident();
        insuredToken.mint(BOB, escrow);
        _fundBond(BOB);
        vm.startPrank(BOB);
        insuredToken.approve(address(defi), escrow);
        uint256 claimId = defi.fileClaim(IERC20(address(insuredToken)), escrow, 1, 0, 0, "");
        vm.stopPrank();

        uint256 payoutA = bound(firstPayoutSeed, 0, pool.maxPayoutPerIncident() * 8_000 / 10_000);
        uint256 payoutB = bound(secondPayoutSeed, 0, secondPool.maxPayoutPerIncident() * 8_000 / 10_000);
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = payoutA;
        payouts[1] = payoutB;
        uint256 eligible = uint256(escrow) / 2;
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(incidentId, claimId, BOB, payouts, 1, 1, eligible))));

        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(incidentId);
        vm.warp(claimDeadline + 1);
        uint256[] memory grossPayouts = new uint256[](2);
        grossPayouts[0] = _grossPayout(incidentId, payoutA);
        grossPayouts[1] = _grossPayout(incidentId, payoutB);
        defi.settleIncident(root, grossPayouts, _signSettlement(incidentId, root, grossPayouts));
        (,,,, uint64 phaseDeadline,,,,,) = defi.incidents(incidentId);
        vm.warp(phaseDeadline + 1);

        uint256 firstBefore = pool.totalAssets();
        uint256 secondBefore = secondPool.totalAssets();
        vm.prank(BOB);
        defi.finalizeClaim(claimId, true, payouts, 1, 1, eligible, new bytes32[](0));

        assertEq(firstBefore - pool.totalAssets(), grossPayouts[0], "first pool conservation");
        assertEq(secondBefore - secondPool.totalAssets(), grossPayouts[1], "second pool conservation");
        assertEq(usdc.balanceOf(BOB), payoutA, "first asset recipient delta");
        assertEq(secondAsset.balanceOf(BOB), payoutB, "second asset recipient delta");
        assertEq(defi.activeIncidentId(), 0, "incident not resolved");
    }
}

contract InsuranceSettlementLifecycleInvariantTest is InsuranceSettlementBase {
    struct SettlementRow {
        address user;
        uint256 payout;
        uint256 scoreSpent;
        uint256 boostedScore;
        uint256 eligible;
        bytes32 leaf;
        bool committed;
        bool finalized;
    }

    address[2] internal claimants;
    mapping(uint256 incidentId => uint256[] claimIds) internal incidentClaims;
    mapping(uint256 claimId => uint256 scoreToSpend) internal requestedScore;
    mapping(uint256 claimId => SettlementRow row) internal rows;
    mapping(uint256 incidentId => uint256 amount) internal ghostCommittedPayout;
    mapping(uint256 incidentId => uint256 amount) internal ghostPaidByIncident;
    mapping(uint256 incidentId => uint256 amount) internal ghostPoolAssetsAtSettlement;
    mapping(address user => uint256 amount) internal ghostScoreSpent;

    uint256 internal ghostPoolFunded;
    uint256 internal ghostPoolPaid;
    uint256 internal ghostOutstandingEscrow;
    uint256 internal ghostForfeitedEscrow;
    uint256 internal ghostOutstandingBoosters;
    uint256 internal ghostReturnedBoosters;
    uint256 internal ghostBurnedBoosters;
    uint256 internal ghostMintedBoosters;
    uint256 internal ghostIncidentsOpened;
    uint256 public successfulJoins;
    uint256 public successfulTwoClaimJoins;
    uint256 public successfulSettlements;
    uint256 public successfulFinalizations;
    uint256 public successfulVoids;
    uint256 public successfulWithdrawals;
    uint256 public successfulExpiryWithdrawals;

    function setUp() public {
        _setUpSettlementProtocol();
        claimants = [ALICE, BOB];
        ghostPoolFunded = 1_000_000e6;
        _stake(LP, ghostPoolFunded);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = this.fundPool.selector;
        selectors[1] = this.openAndJoin.selector;
        selectors[2] = this.joinSecond.selector;
        selectors[3] = this.advanceToSettlement.selector;
        selectors[4] = this.settle.selector;
        selectors[5] = this.advanceToFinalization.selector;
        selectors[6] = this.finalize.selector;
        selectors[7] = this.voidDuringDispute.selector;
        selectors[8] = this.withdrawNonFinalized.selector;
        selectors[9] = this.advancePastFinalizationExpiry.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    function fundPool(uint256 amount) external {
        if (defi.activeIncidentId() != 0) return;
        amount = bound(amount, 1, 1_000_000e6);
        _stake(LP, amount);
        ghostPoolFunded += amount;
    }

    function openAndJoin(uint256 actorSeed, uint128 escrowSeed, uint256 scoreSeed, uint128 boosterSeed) external {
        if (defi.activeIncidentId() != 0 || ghostIncidentsOpened == 3) return;
        uint256 incidentId = _openIncident();
        ghostIncidentsOpened += 1;
        _join(incidentId, claimants[actorSeed % claimants.length], escrowSeed, scoreSeed, boosterSeed);
    }

    function joinSecond(uint256 actorSeed, uint128 escrowSeed, uint256 scoreSeed, uint128 boosterSeed) external {
        uint256 incidentId = defi.activeIncidentId();
        if (incidentId == 0 || incidentClaims[incidentId].length != 1) return;
        (,,,, uint64 claimDeadline, bytes32 root,,,,) = defi.incidents(incidentId);
        if (root != bytes32(0) || block.timestamp > claimDeadline) return;

        address first = rows[incidentClaims[incidentId][0]].user;
        address candidate = claimants[actorSeed % claimants.length];
        if (candidate == first) candidate = candidate == ALICE ? BOB : ALICE;
        _join(incidentId, candidate, escrowSeed, scoreSeed, boosterSeed);
    }

    function _join(uint256 incidentId, address user, uint128 escrowSeed, uint256 scoreSeed, uint128 boosterSeed)
        internal
    {
        if (defi.claimIdByIncidentAndUser(incidentId, user) != 0) return;
        uint128 escrow = uint128(bound(escrowSeed, MIN_CLAIM, 1_000e18));
        uint256 scoreToSpend = bound(scoreSeed, 0, 1_000_000e18);
        uint128 boosterAmount = uint128(bound(boosterSeed, 0, 5));

        insuredToken.mint(user, escrow);
        _fundBond(user);
        if (boosterAmount != 0) {
            booster.mint(user, BOOSTER_ID, boosterAmount);
            vm.prank(user);
            booster.setApprovalForAll(address(defi), true);
            ghostOutstandingBoosters += boosterAmount;
            ghostMintedBoosters += boosterAmount;
        }

        vm.startPrank(user);
        insuredToken.approve(address(defi), escrow);
        uint256 claimId = defi.fileClaim(IERC20(address(insuredToken)), escrow, scoreToSpend, boosterAmount, 0, "");
        vm.stopPrank();

        incidentClaims[incidentId].push(claimId);
        successfulJoins += 1;
        if (incidentClaims[incidentId].length == 2) successfulTwoClaimJoins += 1;
        requestedScore[claimId] = scoreToSpend;
        rows[claimId].user = user;
        ghostOutstandingEscrow += escrow;
    }

    function advanceToSettlement() external {
        uint256 incidentId = defi.activeIncidentId();
        if (incidentId == 0) return;
        (,,,, uint64 claimDeadline, bytes32 root,,,,) = defi.incidents(incidentId);
        if (root == bytes32(0) && block.timestamp <= claimDeadline) vm.warp(claimDeadline + 1);
    }

    function settle(uint256 payoutSeed0, uint256 payoutSeed1, uint128 eligibleSeed0, uint128 eligibleSeed1) external {
        uint256 incidentId = defi.activeIncidentId();
        if (incidentId == 0) return;
        (,,,, uint64 claimDeadline, bytes32 standingRoot,,,,) = defi.incidents(incidentId);
        if (
            standingRoot != bytes32(0) || block.timestamp <= claimDeadline
                || block.timestamp > claimDeadline + registry.incidentTimingConfig().phaseWindow
        ) return;

        uint256[] storage claimsForIncident = incidentClaims[incidentId];
        uint256 count = claimsForIncident.length;
        if (count == 0 || count > 2) return;
        uint256 budgetCap = pool.maxPayoutPerIncident() * 8_000 / 10_000;
        uint256 payout0 = bound(payoutSeed0, 0, budgetCap);
        uint256 payout1 = count == 2 ? bound(payoutSeed1, 0, budgetCap - payout0) : 0;

        bytes32 firstLeaf = _commitRow(claimsForIncident[0], payout0, eligibleSeed0);
        bytes32 root = firstLeaf;
        if (count == 2) root = _hashPair(firstLeaf, _commitRow(claimsForIncident[1], payout1, eligibleSeed1));

        uint256 committed = rows[claimsForIncident[0]].payout;
        if (count == 2) committed += rows[claimsForIncident[1]].payout;
        _commitSettlement(incidentId, root, committed);
    }

    function _commitSettlement(uint256 incidentId, bytes32 root, uint256) internal {
        uint256 grossCommitted;
        uint256[] storage claimsForIncident = incidentClaims[incidentId];
        for (uint256 i; i < claimsForIncident.length; i++) {
            grossCommitted += _grossPayout(incidentId, rows[claimsForIncident[i]].payout);
        }
        uint256[] memory poolPayouts = _amounts(grossCommitted);
        bytes memory signature = _signSettlement(incidentId, root, poolPayouts);
        ghostPoolAssetsAtSettlement[incidentId] = pool.totalAssets();
        defi.settleIncident(root, poolPayouts, signature);
        successfulSettlements += 1;
        ghostCommittedPayout[incidentId] = grossCommitted;
    }

    function _commitRow(uint256 claimId, uint256 payout, uint128 eligibleSeed) internal returns (bytes32 leaf) {
        (address user, uint256 incidentId, uint128 escrow, uint128 boosterAmount,,) = defi.claims(claimId);
        uint256 scoreSpent = requestedScore[claimId];
        uint256 boostedScore = Math.mulDiv(scoreSpent, 10_000 + uint256(boosterAmount) * BOOSTER_BOOST_BPS, 10_000);
        uint256 eligible = bound(eligibleSeed, 0, escrow);
        if (scoreSpent == 0 || eligible == 0) payout = 0;
        leaf = _leaf(incidentId, claimId, user, payout, scoreSpent, boostedScore, eligible);
        rows[claimId] = SettlementRow({
            user: user,
            payout: payout,
            scoreSpent: scoreSpent,
            boostedScore: boostedScore,
            eligible: eligible,
            leaf: leaf,
            committed: true,
            finalized: false
        });
    }

    function advanceToFinalization() external {
        uint256 incidentId = defi.activeIncidentId();
        if (incidentId == 0) return;
        (,,,, uint64 phaseDeadline, bytes32 root,,,,) = defi.incidents(incidentId);
        if (root != bytes32(0) && block.timestamp <= phaseDeadline) {
            vm.warp(phaseDeadline + 1);
        }
    }

    function _canFinalize(uint256 incidentId) internal view returns (bool) {
        (,,,, uint64 phaseDeadline, bytes32 root,,,,) = defi.incidents(incidentId);
        uint256 finalizeDeadline = uint256(phaseDeadline) + registry.incidentTimingConfig().phaseWindow;
        return root != bytes32(0) && block.timestamp > phaseDeadline && block.timestamp <= finalizeDeadline;
    }

    function finalize(uint256 actorSeed) external {
        uint256 incidentId = defi.activeIncidentId();
        if (incidentId == 0 || !_canFinalize(incidentId)) return;

        uint256[] storage claimsForIncident = incidentClaims[incidentId];
        if (claimsForIncident.length == 0) return;
        uint256 claimId = claimsForIncident[actorSeed % claimsForIncident.length];
        SettlementRow storage row = rows[claimId];
        (,, uint128 escrow, uint128 boosterAmount,, bool resolved) = defi.claims(claimId);
        if (!row.committed || row.finalized || resolved) return;

        bytes32[] memory proof;
        if (claimsForIncident.length == 2) {
            proof = new bytes32[](1);
            uint256 other = claimsForIncident[0] == claimId ? claimsForIncident[1] : claimsForIncident[0];
            proof[0] = rows[other].leaf;
        } else {
            proof = new bytes32[](0);
        }

        uint256 poolBefore = pool.totalAssets();
        uint256 payoutBefore = usdc.balanceOf(row.user);
        uint256 insuredBefore = insuredToken.balanceOf(row.user);
        vm.prank(row.user);
        defi.finalizeClaim(claimId, true, _amounts(row.payout), row.scoreSpent, row.boostedScore, row.eligible, proof);

        row.finalized = true;
        successfulFinalizations += 1;
        bool claimEligible = row.scoreSpent != 0 && row.eligible != 0;
        ghostOutstandingEscrow -= escrow;
        ghostForfeitedEscrow += claimEligible ? row.eligible : 0;
        uint256 grossPayout = _grossPayout(incidentId, row.payout);
        ghostPoolPaid += grossPayout;
        ghostPaidByIncident[incidentId] += grossPayout;
        ghostScoreSpent[row.user] += claimEligible ? row.scoreSpent : 0;
        ghostOutstandingBoosters -= boosterAmount;
        if (claimEligible) ghostBurnedBoosters += boosterAmount;
        else ghostReturnedBoosters += boosterAmount;

        assertEq(poolBefore - pool.totalAssets(), grossPayout, "pool payout delta");
        assertEq(usdc.balanceOf(row.user) - payoutBefore, row.payout, "claimant payout delta");
        assertEq(
            insuredToken.balanceOf(row.user) - insuredBefore,
            uint256(escrow) - (claimEligible ? row.eligible : 0),
            "refund delta"
        );
        _assertFinalResolutionTimestamp(incidentId);
    }

    function _assertFinalResolutionTimestamp(uint256 incidentId) internal view {
        (, uint64 resolvedAt,,,,, uint256 unresolved,,,) = defi.incidents(incidentId);
        if (unresolved == 0) assertGt(resolvedAt, 0, "final claim missing timestamp");
    }

    function voidDuringDispute() external {
        uint256 incidentId = defi.activeIncidentId();
        if (incidentId == 0) return;
        (,,,, uint64 phaseDeadline, bytes32 root,,,,) = defi.incidents(incidentId);
        if (root == bytes32(0) || block.timestamp > phaseDeadline) return;
        vm.prank(ADMIN);
        defi.adminCorrectSettlement(bytes32(0), new uint256[](0));
        successfulVoids += 1;
    }

    function advancePastFinalizationExpiry() external {
        uint256 incidentId = defi.activeIncidentId();
        if (incidentId == 0) return;
        (,,,, uint64 phaseDeadline, bytes32 root,,,,) = defi.incidents(incidentId);
        uint256 finalizeDeadline = uint256(phaseDeadline) + registry.incidentTimingConfig().phaseWindow;
        if (root != bytes32(0)) {
            if (block.timestamp <= finalizeDeadline) vm.warp(finalizeDeadline + 1);
        }
    }

    function _declineClaim(uint256 claimId, uint256 incidentId, address user, bool hasRoot) internal returns (bool) {
        if (!hasRoot) {
            vm.prank(user);
            defi.finalizeClaim(claimId, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
            return true;
        }

        SettlementRow storage row = rows[claimId];
        if (!row.committed) return false;
        bytes32[] memory proof;
        uint256[] storage claimsForIncident = incidentClaims[incidentId];
        if (claimsForIncident.length == 2) {
            proof = new bytes32[](1);
            uint256 other = claimsForIncident[0] == claimId ? claimsForIncident[1] : claimsForIncident[0];
            proof[0] = rows[other].leaf;
        } else {
            proof = new bytes32[](0);
        }
        vm.prank(user);
        defi.finalizeClaim(claimId, false, _amounts(row.payout), row.scoreSpent, row.boostedScore, row.eligible, proof);
        return true;
    }

    function withdrawNonFinalized(uint256 claimSeed) external {
        uint256 next = defi.nextClaimId();
        if (next <= 1) return;
        uint256 claimId = bound(claimSeed, 1, next - 1);
        (address user, uint256 incidentId, uint128 escrow, uint128 boosterAmount,, bool resolved) = defi.claims(claimId);
        if (resolved) return;
        (,,,, uint64 phaseDeadline, bytes32 root,,,,) = defi.incidents(incidentId);
        Registry.IncidentTimingConfig memory timing = registry.incidentTimingConfig();
        uint256 terminalDeadline = uint256(phaseDeadline) + timing.phaseWindow;
        bool withdrawable = block.timestamp > terminalDeadline;
        if (!withdrawable) return;

        uint256 insuredBefore = insuredToken.balanceOf(user);
        uint256 boosterBefore = booster.balanceOf(user, BOOSTER_ID);
        if (!_declineClaim(claimId, incidentId, user, root != bytes32(0))) return;
        successfulWithdrawals += 1;
        if (root != bytes32(0)) successfulExpiryWithdrawals += 1;
        ghostOutstandingEscrow -= escrow;
        ghostOutstandingBoosters -= boosterAmount;
        ghostReturnedBoosters += boosterAmount;
        assertEq(insuredToken.balanceOf(user) - insuredBefore, escrow, "withdraw refund delta");
        assertEq(booster.balanceOf(user, BOOSTER_ID) - boosterBefore, boosterAmount, "booster return delta");
    }

    function test_ProductiveHandlerBranchesAreReachable() public {
        this.openAndJoin(0, MIN_CLAIM, 100e18, 2);
        this.joinSecond(0, MIN_CLAIM * 2, 200e18, 1);
        this.advanceToSettlement();
        this.settle(100e6, 200e6, MIN_CLAIM / 2, MIN_CLAIM);
        this.advanceToFinalization();
        this.finalize(0);
        this.finalize(1);
        assertEq(defi.activeIncidentId(), 0, "finalized incident remains active");

        this.openAndJoin(0, MIN_CLAIM, 300e18, 1);
        this.advanceToSettlement();
        this.settle(100e6, 0, MIN_CLAIM / 2, 0);
        this.voidDuringDispute();
        this.withdrawNonFinalized(defi.nextClaimId() - 1);

        this.openAndJoin(1, MIN_CLAIM, 400e18, 3);
        this.advanceToSettlement();
        this.settle(100e6, 0, MIN_CLAIM / 2, 0);
        this.advancePastFinalizationExpiry();
        this.withdrawNonFinalized(defi.nextClaimId() - 1);

        assertEq(ghostIncidentsOpened, 3, "multi-incident path not reached");
        assertEq(successfulJoins, 4, "join branches not reached");
        assertEq(successfulTwoClaimJoins, 1, "two-claim branch not reached");
        assertEq(successfulSettlements, 3, "signed settlements not reached");
        assertEq(successfulFinalizations, 2, "proof finalizations not reached");
        assertEq(successfulVoids, 1, "void branch not reached");
        assertEq(successfulWithdrawals, 2, "withdraw branches not reached");
        assertEq(successfulExpiryWithdrawals, 1, "expiry branch not reached");
    }

    function invariant_globalEscrowMatchesAllUnresolvedClaims() public view {
        uint256 unresolvedEscrow;
        for (uint256 claimId = 1; claimId < defi.nextClaimId(); claimId++) {
            (,, uint128 escrow,,, bool resolved) = defi.claims(claimId);
            if (!resolved) unresolvedEscrow += escrow;
        }
        assertEq(unresolvedEscrow, ghostOutstandingEscrow, "ghost escrow drift");
        assertEq(defi.escrowedInsuredTokens(IERC20(address(insuredToken))), unresolvedEscrow, "protocol escrow drift");
    }

    function invariant_eachIncidentUnresolvedCountIsExact() public view {
        for (uint256 incidentId = 1; incidentId < defi.nextIncidentId(); incidentId++) {
            (,,,,,, uint256 unresolved,,,) = defi.incidents(incidentId);
            uint256 counted;
            for (uint256 claimId = 1; claimId < defi.nextClaimId(); claimId++) {
                (, uint256 claimIncident,,,, bool resolved) = defi.claims(claimId);
                if (claimIncident == incidentId && !resolved) counted += 1;
            }
            assertEq(unresolved, counted, "incident unresolved drift");
        }
    }

    function invariant_insuredTokenBalanceConservesEscrowAndForfeitures() public view {
        assertEq(
            insuredToken.balanceOf(address(defi)),
            ghostOutstandingEscrow + ghostForfeitedEscrow,
            "insured-token conservation"
        );
    }

    function invariant_poolLossEqualsFinalizedPayouts() public view {
        assertEq(pool.totalAssets(), ghostPoolFunded - ghostPoolPaid, "pool payout conservation");
        assertEq(usdc.balanceOf(address(pool)), pool.totalAssets(), "pool token balance drift");
        assertEq(pool.withdrawalReserve(), 0, "unexpected withdrawal reserve");
        for (uint256 incidentId = 1; incidentId < defi.nextIncidentId(); incidentId++) {
            assertLe(ghostPaidByIncident[incidentId], ghostCommittedPayout[incidentId], "incident budget exceeded");
            assertLe(
                ghostCommittedPayout[incidentId],
                ghostPoolAssetsAtSettlement[incidentId] * registry.maxCoverPoolPayoutBps() / 10_000,
                "committed payout exceeded settlement cap"
            );
        }
    }

    function invariant_resolvedIncidentsHaveResolutionTimestamp() public view {
        for (uint256 incidentId = 1; incidentId < defi.nextIncidentId(); incidentId++) {
            (, uint64 resolvedAt,,, uint64 phaseDeadline, bytes32 root, uint256 unresolved,,,) =
                defi.incidents(incidentId);
            bool voided = root == bytes32(0) && phaseDeadline == 0;
            if (voided) assertGt(resolvedAt, 0, "voided incident missing timestamp");
            if (resolvedAt != 0) assertTrue(voided || unresolved == 0, "early resolution timestamp");
        }
    }

    function invariant_committedRowsMatchClaimsAndBudgets() public view {
        for (uint256 incidentId = 1; incidentId < defi.nextIncidentId(); incidentId++) {
            uint256 committedRowSum;
            uint256[] storage claimsForIncident = incidentClaims[incidentId];
            for (uint256 i; i < claimsForIncident.length; i++) {
                committedRowSum += _assertClaimAndRowConsistency(claimsForIncident[i]);
            }
            assertEq(committedRowSum, ghostCommittedPayout[incidentId], "committed gross row sum drift");
        }
    }

    function _assertClaimAndRowConsistency(uint256 claimId) internal view returns (uint256 payout) {
        (address user, uint256 incidentId, uint128 escrow, uint128 boosterAmount,, bool resolved) = defi.claims(claimId);
        if (!resolved) assertEq(defi.claimIdByIncidentAndUser(incidentId, user), claimId, "live claim pointer drift");

        SettlementRow storage row = rows[claimId];
        if (!row.committed) return 0;
        assertEq(row.user, user, "committed row user drift");
        assertEq(row.scoreSpent, requestedScore[claimId], "committed raw score drift");
        assertLe(row.eligible, escrow, "committed eligible amount exceeds escrow");
        uint256 expectedBoosted =
            Math.mulDiv(row.scoreSpent, 10_000 + uint256(boosterAmount) * BOOSTER_BOOST_BPS, 10_000);
        assertEq(row.boostedScore, expectedBoosted, "committed boosted score drift");
        assertEq(
            row.leaf,
            _leaf(incidentId, claimId, user, row.payout, row.scoreSpent, row.boostedScore, row.eligible),
            "committed leaf drift"
        );
        return _grossPayout(incidentId, row.payout);
    }

    function invariant_scoreLedgerUsesRawCommittedScore() public view {
        assertEq(registry.scoreSpent(ALICE), ghostScoreSpent[ALICE], "alice score drift");
        assertEq(registry.scoreSpent(BOB), ghostScoreSpent[BOB], "bob score drift");
    }

    function invariant_boosterEscrowBurnAndReturnConservation() public view {
        uint256 supply = booster.totalSupply(BOOSTER_ID);
        assertEq(supply, ghostOutstandingBoosters + ghostReturnedBoosters, "booster supply drift");
        assertEq(ghostMintedBoosters, supply + ghostBurnedBoosters, "booster burn drift");
        assertEq(booster.balanceOf(address(defi), BOOSTER_ID), ghostOutstandingBoosters, "booster escrow drift");
    }

    function invariant_claimAndIncidentIdsAreGapless() public view {
        uint256 successfulClaims;
        for (uint256 claimId = 1; claimId < defi.nextClaimId(); claimId++) {
            (address user,,,,,) = defi.claims(claimId);
            if (user != address(0)) successfulClaims += 1;
        }
        assertEq(defi.nextClaimId(), successfulClaims + 1, "claim id gap");
        assertEq(defi.nextIncidentId(), ghostIncidentsOpened + 1, "incident id gap");
    }

    function invariant_activeIncidentAndRegistryFreezeAgree() public view {
        uint256 active = defi.activeIncidentId();
        assertEq(registry.payoutIncidentActive(), active != 0, "registry freeze mismatch");
        if (active != 0) {
            (,,,, uint64 phaseDeadline, bytes32 root, uint256 unresolved,,,) = defi.incidents(active);
            assertGt(unresolved, 0, "active incident without claims");
            Registry.IncidentTimingConfig memory timing = registry.incidentTimingConfig();
            uint256 terminalDeadline = uint256(phaseDeadline) + timing.phaseWindow;
            assertLe(block.timestamp, terminalDeadline, "active incident expired");
        }
    }
}
