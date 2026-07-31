// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {
    DefiInsuranceKontrolBase,
    DefiInsuranceHarnessPool,
    DefiInsuranceHarnessToken
} from "./DefiInsuranceHarness.k.sol";

/// @notice TEE settlement commitment, timing, cap, correction, and rollback properties.
contract DefiInsuranceSettlementKontrolTest is DefiInsuranceKontrolBase {
    bytes32 internal constant SECP256K1_HALF_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a1;

    function test_settlementCommitsRootDeadlinesBudgetAndDelistsToken() public {
        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        uint256 claimId = _openAndJoin(ALICE, 10, 7, 0);
        uint256[] memory amounts = _oneAmount(100);
        bytes32 root = _leaf(1, claimId, ALICE, amounts, 7, 7, 10);
        uint256[] memory budget = _oneAmount(400);
        _settle(1, root, budget);

        (IERC20 token,,,,,,,,,) = defi.incidents(1);
        bytes32 storedRoot = _incidentRoot(1);
        uint64 correctionDeadline = _incidentPhaseDeadline(1);
        uint64 phaseWindow = defi.incidentPhaseWindow(1);
        assert(address(token) == address(insured));
        assert(storedRoot == root);
        assert(correctionDeadline == block.timestamp + phaseWindow);
        assert(uint256(correctionDeadline) + phaseWindow > correctionDeadline);
        address[] memory storedPools = defi.incidentPools(1);
        uint256[] memory storedBudget = defi.incidentPoolBudget(1);
        assert(storedPools.length == 1 && storedPools[0] == address(pool));
        assert(storedBudget.length == 1 && storedBudget[0] == budget[0]);
        assert(storedPools.length == storedBudget.length);
        assert(!defi.isInsuredToken(IERC20(address(insured))));
        assert(defi.isInsuredToken(IERC20(address(secondInsured))));
    }

    function test_independentSettlementFixtureMatchesStoredSnapshotAndSucceeds() public {
        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        uint256 claimId = _openAndJoin(ALICE, 10, 3, 0);
        uint256[] memory payouts = _oneAmount(123);
        bytes32 root = _leaf(1, claimId, ALICE, _oneAmount(0), 3, 3, 10);

        address[] memory expectedPools = new address[](1);
        expectedPools[0] = address(pool);
        bytes32 expectedClaimSetHash =
            keccak256(abi.encode(bytes32(0), claimId, ALICE, uint128(10), uint256(3), uint256(0)));
        bytes memory signature =
            _settlementSignature(1, root, payouts, expectedPools, 1, expectedClaimSetHash, PCR_HASH);

        address[] memory storedPools = defi.incidentPools(1);
        assert(keccak256(abi.encode(storedPools)) == keccak256(abi.encode(expectedPools)));
        assert(_incidentUnresolved(1) == 1);
        assert(_claimSetHash(1) == expectedClaimSetHash);
        assert(_incidentTeePcrHash(1) == PCR_HASH);

        uint64 claimEnd = _incidentPhaseDeadline(1);
        vm.warp(uint256(claimEnd) + 1);
        defi.settleIncident(root, payouts, signature);
        assert(_incidentRoot(1) == root);
        uint256[] memory storedBudget = defi.incidentPoolBudget(1);
        assert(storedBudget.length == 1 && storedBudget[0] == payouts[0]);
    }

    function test_settlementAtExactSettlementDeadlineSucceeds() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint64 claimEnd = _incidentPhaseDeadline(1);
        uint256 settlementDeadline = uint256(claimEnd) + defi.incidentPhaseWindow(1);
        assert(settlementDeadline > claimEnd);
        uint256[] memory amounts = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, amounts, 0, 0, 10);
        vm.warp(settlementDeadline);
        defi.settleIncident(root, amounts, _fixtureSettlementSignature(1, root, amounts));
        bytes32 stored = _incidentRoot(1);
        assert(stored == root);
    }

    function test_settlementRejectedAtClaimEndAndAfterSettlementDeadline() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint64 claimEnd = _incidentPhaseDeadline(1);
        uint256 settlementDeadline = uint256(claimEnd) + defi.incidentPhaseWindow(1);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 0, 0, 10);
        bytes memory signature = _fixtureSettlementSignature(1, root, none);
        uint256 unresolvedBefore = _incidentUnresolved(1);
        uint256 escrowBefore = defi.escrowedInsuredTokens(IERC20(address(insured)));
        bytes32 claimSetBefore = _claimSetHash(1);

        vm.warp(claimEnd);
        (bool early, bytes memory ed) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (root, none, signature)));
        assert(
            !early && _sameBytes(ed, abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)))
        );
        assert(_incidentRoot(1) == bytes32(0));
        assert(_incidentUnresolved(1) == unresolvedBefore);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == escrowBefore);
        assert(_claimSetHash(1) == claimSetBefore);
        vm.warp(uint256(settlementDeadline) + 1);
        (bool late, bytes memory ld) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (root, none, signature)));
        assert(!late && _sameBytes(ld, abi.encodeWithSelector(DefiInsurance.NotActiveIncident.selector, uint256(0))));
        bytes32 stored = _incidentRoot(1);
        assert(stored == bytes32(0));
        assert(_incidentUnresolved(1) == unresolvedBefore);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == escrowBefore);
        assert(_claimSetHash(1) == claimSetBefore);
    }

    function test_zeroRootAndSecondSettlementRevertWithoutReplacingStandingRoot() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint64 claimEnd = _incidentPhaseDeadline(1);
        vm.warp(uint256(claimEnd) + 1);
        uint256[] memory none = _emptyAmounts();
        (bool zero, bytes memory zd) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (bytes32(0), none, bytes("bad"))));
        assert(!zero);
        assert(keccak256(zd) == keccak256(abi.encodeWithSelector(DefiInsurance.NoStandingRoot.selector, uint256(1))));

        bytes32 root = _leaf(1, claimId, ALICE, none, 0, 0, 10);
        defi.settleIncident(root, none, _fixtureSettlementSignature(1, root, none));
        bytes32 replacement = keccak256("replacement");
        (bool again, bytes memory ad) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (replacement, none, bytes("bad"))));
        assert(!again);
        assert(keccak256(ad) == keccak256(abi.encodeWithSelector(DefiInsurance.AlreadySettled.selector, uint256(1))));
        bytes32 stored = _incidentRoot(1);
        assert(stored == root);
        assert(keccak256(abi.encode(defi.incidentPoolBudget(1))) == keccak256(abi.encode(none)));
    }

    function test_poolArrayMismatchAndCapExcessRevertAtomically() public {
        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint64 claimEnd = _incidentPhaseDeadline(1);
        vm.warp(uint256(claimEnd) + 1);
        bytes32 root = _leaf(1, claimId, ALICE, _oneAmount(1), 0, 0, 10);

        uint256[] memory empty = _emptyAmounts();
        (bool mismatch, bytes memory md) = address(defi)
            .call(
                abi.encodeCall(DefiInsurance.settleIncident, (root, empty, _fixtureSettlementSignature(1, root, empty)))
            );
        assert(!mismatch);
        assert(
            keccak256(md)
                == keccak256(
                    abi.encodeWithSelector(DefiInsurance.SettlementPoolMismatch.selector, uint256(0), uint256(1))
                )
        );

        uint256[] memory excessive = _oneAmount(501);
        (bool cap, bytes memory cd) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.settleIncident, (root, excessive, _fixtureSettlementSignature(1, root, excessive))
                )
            );
        assert(!cap);
        assert(
            keccak256(cd)
                == keccak256(
                    abi.encodeWithSelector(
                        DefiInsurance.PayoutCapExceeded.selector, uint256(0), uint256(501), uint256(500)
                    )
                )
        );
        bytes32 stored = _incidentRoot(1);
        assert(stored == bytes32(0));
        assert(pool.payCalls() == 0);
        assert(defi.isInsuredToken(IERC20(address(insured))));
    }

    function test_exactPoolCapIsAccepted(uint128 cap) public {
        _registerPool(type(uint128).max, cap);
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory amounts = _oneAmount(0);
        bytes32 root = _leaf(1, claimId, ALICE, amounts, 0, 0, 10);
        uint256[] memory budget = _oneAmount(cap);
        _settle(1, root, budget);
        bytes32 stored = _incidentRoot(1);
        assert(stored == root);
    }

    function test_revertingPoolCapRollsBackRootDeadlinesAndDelisting() public {
        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        pool.setModes(false, true, false);
        uint256[] memory amount = _oneAmount(1);
        bytes32 root = _leaf(1, claimId, ALICE, amount, 0, 0, 10);
        uint64 claimEnd = _incidentPhaseDeadline(1);
        vm.warp(uint256(claimEnd) + 1);
        (bool success,) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.settleIncident, (root, amount, _fixtureSettlementSignature(1, root, amount))
                )
            );
        assert(!success);
        bytes32 stored = _incidentRoot(1);
        uint64 phaseDeadline = _incidentPhaseDeadline(1);
        assert(stored == bytes32(0));
        assert(_incidentResolvedAt(1) == 0);
        assert(phaseDeadline == claimEnd);
        assert(defi.isInsuredToken(IERC20(address(insured))));
    }

    function test_signatureBindsRootBudgetClaimSetAndUnresolvedCount() public {
        _registerPool(1000, 500);
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory originalBudget = _oneAmount(100);
        uint256[] memory amounts = _oneAmount(0);
        bytes32 root = _leaf(1, claimId, ALICE, amounts, 0, 0, 10);
        bytes memory signature = _fixtureSettlementSignature(1, root, originalBudget);

        _join(BOB, IERC20(address(insured)), 11, 9, 0);
        uint64 claimEnd = _incidentPhaseDeadline(1);
        vm.warp(uint256(claimEnd) + 1);
        (bool changedClaimSet, bytes memory csd) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (root, originalBudget, signature)));
        assert(!changedClaimSet && _selector(csd) == DefiInsurance.UnauthorizedSettlementSigner.selector);

        uint256[] memory changedBudget = _oneAmount(101);
        bytes memory currentSignature = _fixtureSettlementSignature(1, root, originalBudget);
        (bool budget, bytes memory bd) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (root, changedBudget, currentSignature)));
        assert(!budget && _selector(bd) == DefiInsurance.UnauthorizedSettlementSigner.selector);

        bytes32 changedRoot = keccak256("changed root");
        (bool rootChanged, bytes memory rd) = address(defi)
            .call(abi.encodeCall(DefiInsurance.settleIncident, (changedRoot, originalBudget, currentSignature)));
        assert(!rootChanged && _selector(rd) == DefiInsurance.UnauthorizedSettlementSigner.selector);
        bytes32 stored = _incidentRoot(1);
        assert(stored == bytes32(0));
    }

    function test_settlementRejectsWrongUnresolvedOnly() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory payouts = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, payouts, 0, 0, 10);
        address[] memory pools = new address[](0);
        bytes32 claimSet = keccak256(abi.encode(bytes32(0), claimId, ALICE, uint128(10), uint256(0), uint256(0)));
        vm.warp(uint256(_incidentPhaseDeadline(1)) + 1);
        bytes memory signature = _settlementSignature(1, root, payouts, pools, 2, claimSet, PCR_HASH);
        address recovered =
            ECDSA.recover(_independentSettlementDigest(1, root, payouts, pools, 1, claimSet, PCR_HASH), signature);
        (bool success, bytes memory data) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (root, payouts, signature)));
        assert(!success);
        assert(
            keccak256(data)
                == keccak256(abi.encodeWithSelector(DefiInsurance.UnauthorizedSettlementSigner.selector, recovered))
        );
        assert(_incidentRoot(1) == bytes32(0));
    }

    function test_settlementRejectsWrongPoolSnapshotOrderOnly() public {
        DefiInsuranceHarnessPool first = _registerPool(1000, 500);
        DefiInsuranceHarnessToken secondAsset = new DefiInsuranceHarnessToken("Second Pool Asset", "POOL2");
        DefiInsuranceHarnessPool second = new DefiInsuranceHarnessPool(secondAsset, 2000, 600);
        registry.addPool(address(second), address(feed));
        expectedRegistryPools.push(address(second));
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 100;
        payouts[1] = 200;
        bytes32 root = _leaf(1, claimId, ALICE, payouts, 0, 0, 10);
        address[] memory correct = new address[](2);
        correct[0] = address(first);
        correct[1] = address(second);
        address[] memory reversed = new address[](2);
        reversed[0] = address(second);
        reversed[1] = address(first);
        bytes32 claimSet = keccak256(abi.encode(bytes32(0), claimId, ALICE, uint128(10), uint256(0), uint256(0)));
        vm.warp(uint256(_incidentPhaseDeadline(1)) + 1);
        bytes memory signature = _settlementSignature(1, root, payouts, reversed, 1, claimSet, PCR_HASH);
        address recovered =
            ECDSA.recover(_independentSettlementDigest(1, root, payouts, correct, 1, claimSet, PCR_HASH), signature);
        (bool success, bytes memory data) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (root, payouts, signature)));
        assert(!success);
        assert(
            keccak256(data)
                == keccak256(abi.encodeWithSelector(DefiInsurance.UnauthorizedSettlementSigner.selector, recovered))
        );
        assert(_incidentRoot(1) == bytes32(0));
        assert(first.payCalls() == 0 && second.payCalls() == 0);
    }

    function test_settlementRejectsWrongPcrOnly() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory payouts = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, payouts, 0, 0, 10);
        address[] memory pools = new address[](0);
        bytes32 claimSet = keccak256(abi.encode(bytes32(0), claimId, ALICE, uint128(10), uint256(0), uint256(0)));
        vm.warp(uint256(_incidentPhaseDeadline(1)) + 1);
        bytes memory signature = _settlementSignature(1, root, payouts, pools, 1, claimSet, keccak256("wrong-pcr-only"));
        address recovered =
            ECDSA.recover(_independentSettlementDigest(1, root, payouts, pools, 1, claimSet, PCR_HASH), signature);
        (bool success, bytes memory data) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (root, payouts, signature)));
        assert(!success);
        assert(
            keccak256(data)
                == keccak256(abi.encodeWithSelector(DefiInsurance.UnauthorizedSettlementSigner.selector, recovered))
        );
        assert(_incidentRoot(1) == bytes32(0));
        assert(defi.isInsuredToken(IERC20(address(insured))));
    }

    function test_pauseAndDeregistrationBlockSettlementBeforeStateChanges() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint64 claimEnd = _incidentPhaseDeadline(1);
        vm.warp(uint256(claimEnd) + 1);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 0, 0, 10);
        bytes memory signature = _fixtureSettlementSignature(1, root, none);

        registry.setPaused(address(defi), true);
        (bool paused, bytes memory pd) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (root, none, signature)));
        assert(!paused && _selector(pd) == Registry.Paused.selector);
        registry.setPaused(address(defi), false);
        registry.setDefiInsurance(address(0));
        (bool stale, bytes memory sd) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (root, none, signature)));
        assert(!stale && _selector(sd) == DefiInsurance.DefiInsuranceNotRegistered.selector);
        bytes32 stored = _incidentRoot(1);
        assert(stored == bytes32(0));
    }

    function test_nonzeroCorrectionReplacesRootBudgetAndRestartsDeadlines() public {
        _registerPool(1000, 500);
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory oldBudget = _oneAmount(100);
        bytes32 oldRoot = _leaf(1, claimId, ALICE, _oneAmount(1), 0, 0, 10);
        _settle(1, oldRoot, oldBudget);
        vm.warp(block.timestamp + 10);

        uint256[] memory newBudget = _oneAmount(200);
        bytes32 newRoot = _leaf(1, claimId, ALICE, _oneAmount(2), 0, 0, 10);
        defi.adminCorrectSettlement(newRoot, newBudget);
        bytes32 stored = _incidentRoot(1);
        uint64 correctionDeadline = _incidentPhaseDeadline(1);
        uint64 phaseWindow = defi.incidentPhaseWindow(1);
        assert(stored == newRoot);
        assert(correctionDeadline == block.timestamp + phaseWindow);
        assert(uint256(correctionDeadline) + phaseWindow > correctionDeadline);
    }

    function test_deregisteredModuleCannotCorrectStandingSettlementAndStateIsAtomic() public {
        _registerPool(1000, 500);
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory oldBudget = _oneAmount(100);
        bytes32 oldRoot = _leaf(1, claimId, ALICE, _oneAmount(1), 0, 0, 10);
        _settle(1, oldRoot, oldBudget);
        bytes32 rootBefore = _incidentRoot(1);
        uint64 phaseDeadlineBefore = _incidentPhaseDeadline(1);
        uint64 resolvedBefore = _incidentResolvedAt(1);

        registry.setDefiInsurance(address(0));
        bytes32 replacementRoot = keccak256("replacement");
        (bool success, bytes memory data) =
            address(defi).call(abi.encodeCall(DefiInsurance.adminCorrectSettlement, (replacementRoot, _oneAmount(200))));
        assert(!success && _selector(data) == DefiInsurance.DefiInsuranceNotRegistered.selector);
        bytes32 rootAfter = _incidentRoot(1);
        assert(rootAfter == rootBefore);
        assert(_incidentPhaseDeadline(1) == phaseDeadlineBefore);
        assert(_incidentResolvedAt(1) == resolvedBefore);
    }

    function test_zeroCorrectionClosesIncidentAndMakesClaimRecoverable() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 0, 0, 10);
        _settle(1, root, none);
        defi.adminCorrectSettlement(bytes32(0), none);
        bytes32 stored = _incidentRoot(1);
        assert(_incidentReferenceBlock(1) == block.number - 1);
        assert(stored == bytes32(0));
        assert(_incidentResolvedAt(1) == block.timestamp);
        assert(defi.activeIncidentId() == 0);
        assert(_incidentResolvedAt(1) == block.timestamp);

        vm.prank(ALICE);
        defi.finalizeClaim(claimId, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
        assert(insured.balanceOf(ALICE) == 10);
    }

    function test_correctionAuthBetaStandingRootAndDisputeEndpointBoundaries() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory none = _emptyAmounts();
        (bool noRoot, bytes memory nd) =
            address(defi).call(abi.encodeCall(DefiInsurance.adminCorrectSettlement, (bytes32(0), none)));
        assert(!noRoot && _selector(nd) == DefiInsurance.NoStandingRoot.selector);

        bytes32 root = _leaf(1, claimId, ALICE, none, 0, 0, 10);
        _settle(1, root, none);
        (bool unauthorized, bytes memory ud) =
            _callAs(OUTSIDER, abi.encodeCall(DefiInsurance.adminCorrectSettlement, (bytes32(0), none)));
        assert(!unauthorized && _selector(ud) == Registry.UnauthorizedAdmin.selector);

        uint64 correctionDeadline = _incidentPhaseDeadline(1);
        vm.warp(correctionDeadline);
        defi.adminCorrectSettlement(keccak256("at endpoint"), none);
        uint64 restartedEnd = _incidentPhaseDeadline(1);
        bytes32 rootBefore = _incidentRoot(1);
        uint256 unresolvedBefore = _incidentUnresolved(1);
        bytes32 budgetBefore = keccak256(abi.encode(defi.incidentPoolBudget(1)));
        vm.warp(uint256(restartedEnd) + 1);
        (bool late, bytes memory ld) =
            address(defi).call(abi.encodeCall(DefiInsurance.adminCorrectSettlement, (bytes32(0), none)));
        assert(!late && _sameBytes(ld, abi.encodeWithSelector(DefiInsurance.IncidentFinalizing.selector, uint256(1))));
        assert(_incidentRoot(1) == rootBefore);
        assert(_incidentPhaseDeadline(1) == restartedEnd);
        assert(_incidentUnresolved(1) == unresolvedBefore);
        assert(keccak256(abi.encode(defi.incidentPoolBudget(1))) == budgetBefore);
    }

    function test_settlementEcdsaInvalidLengthInvalidSAndInvalidVAreExactAndAtomic() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 0, 0, 10);
        vm.warp(uint256(_incidentPhaseDeadline(1)) + 1);

        bytes[3] memory signatures;
        signatures[0] = hex"01";
        signatures[1] = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(SECP256K1_HALF_ORDER) + 1), uint8(27));
        signatures[2] = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(1)), uint8(0));
        bytes[3] memory expected;
        expected[0] = abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(1));
        expected[1] =
            abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, bytes32(uint256(SECP256K1_HALF_ORDER) + 1));
        expected[2] = abi.encodeWithSelector(ECDSA.ECDSAInvalidSignature.selector);

        for (uint256 i = 0; i < signatures.length; i++) {
            (bool success, bytes memory data) =
                address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (root, none, signatures[i])));
            assert(!success);
            assert(keccak256(data) == keccak256(expected[i]));
            if (i == 2) assert(data.length == 4);
            assert(_incidentRoot(1) == bytes32(0));
            assert(defi.incidentPoolBudget(1).length == 0);
            assert(defi.isInsuredToken(IERC20(address(insured))));
        }
    }

    function test_settlementSignatureSeparatelyBindsRootAndBudgetWithFullRecoveredBytes() public {
        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory budget = _oneAmount(100);
        bytes32 root = _leaf(1, claimId, ALICE, _oneAmount(0), 0, 0, 10);
        bytes memory signature = _fixtureSettlementSignature(1, root, budget);
        address[] memory pools = defi.incidentPools(1);
        uint256 unresolved = _incidentUnresolved(1);
        bytes32 claimSet = _claimSetHash(1);
        vm.warp(uint256(_incidentPhaseDeadline(1)) + 1);

        bytes32 changedRoot = keccak256("root-only");
        address recoveredRoot = ECDSA.recover(
            _independentSettlementDigest(1, changedRoot, budget, pools, unresolved, claimSet, PCR_HASH), signature
        );
        (bool rootSuccess, bytes memory rootData) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (changedRoot, budget, signature)));
        assert(!rootSuccess);
        assert(
            keccak256(rootData)
                == keccak256(abi.encodeWithSelector(DefiInsurance.UnauthorizedSettlementSigner.selector, recoveredRoot))
        );

        uint256[] memory changedBudget = _oneAmount(101);
        address recoveredBudget = ECDSA.recover(
            _independentSettlementDigest(1, root, changedBudget, pools, unresolved, claimSet, PCR_HASH), signature
        );
        (bool budgetSuccess, bytes memory budgetData) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (root, changedBudget, signature)));
        assert(!budgetSuccess);
        assert(
            keccak256(budgetData)
                == keccak256(
                    abi.encodeWithSelector(DefiInsurance.UnauthorizedSettlementSigner.selector, recoveredBudget)
                )
        );
        assert(_incidentRoot(1) == bytes32(0));
        assert(defi.incidentPoolBudget(1).length == 0);
        assert(pool.payCalls() == 0);
    }

    function test_settlementRejectsClaimSetOnlyMutationWithFullRecoveredBytes() public {
        uint256 originalClaim = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, originalClaim, ALICE, none, 0, 0, 10);
        bytes memory staleSignature = _fixtureSettlementSignature(1, root, none);
        address[] memory pools = defi.incidentPools(1);
        uint256 unresolvedBefore = _incidentUnresolved(1);
        bytes32 claimSetBefore = _claimSetHash(1);

        vm.prank(ALICE);
        defi.cancelClaim();
        _join(ALICE, IERC20(address(insured)), 10, 0, 0);
        assert(_incidentUnresolved(1) == unresolvedBefore);
        assert(_claimSetHash(1) != claimSetBefore);
        assert(keccak256(abi.encode(defi.incidentPools(1))) == keccak256(abi.encode(pools)));
        assert(_incidentTeePcrHash(1) == PCR_HASH);

        vm.warp(uint256(_incidentPhaseDeadline(1)) + 1);
        address recovered = ECDSA.recover(
            _independentSettlementDigest(1, root, none, pools, unresolvedBefore, _claimSetHash(1), PCR_HASH),
            staleSignature
        );
        (bool success, bytes memory data) =
            address(defi).call(abi.encodeCall(DefiInsurance.settleIncident, (root, none, staleSignature)));
        assert(!success);
        assert(
            keccak256(data)
                == keccak256(abi.encodeWithSelector(DefiInsurance.UnauthorizedSettlementSigner.selector, recovered))
        );
        assert(_incidentRoot(1) == bytes32(0));
        assert(_incidentUnresolved(1) == unresolvedBefore);
        assert(defi.incidentPoolBudget(1).length == 0);
    }
}
