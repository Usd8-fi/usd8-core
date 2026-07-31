// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {DefiInsuranceKontrolBase, DefiInsuranceHarnessPool} from "./DefiInsuranceHarness.k.sol";

/// @notice Merkle finalization, budget conservation, score/booster, rollback, and recovery properties.
contract DefiInsuranceFinalizationKontrolTest is DefiInsuranceKontrolBase {
    function test_symbolicEligibleEscrowRefundAndForfeitureAreExact(uint64 escrowSeed, uint64 eligibleSeed) public {
        vm.assume(escrowSeed > 0);
        vm.assume(eligibleSeed <= escrowSeed);
        uint256 claimId = _openAndJoin(ALICE, escrowSeed, 0, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 1, 1, eligibleSeed);
        _settle(1, root, none);
        _warpToFinalization(1);

        vm.prank(ALICE);
        defi.finalizeClaim(claimId, true, none, 1, 1, eligibleSeed, new bytes32[](0));

        (,,,,, bool resolved) = defi.claims(claimId);
        uint256 unresolved = _incidentUnresolved(1);
        assert(resolved);
        assert(unresolved == 0);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 0);
        assert(insured.balanceOf(ALICE) == uint256(escrowSeed) - eligibleSeed);
        assert(insured.balanceOf(address(defi)) == eligibleSeed);
        assert(_incidentResolvedAt(1) == block.timestamp);
        assert(defi.activeIncidentId() == 0);
        assert(defi.claimIdByIncidentAndUser(1, ALICE) == claimId);
    }

    function test_boostFormulaScoreMirrorAndBurnAreExact(uint64 scoreSpent, uint8 boosterAmount) public {
        vm.assume(boosterAmount > 0);
        vm.assume(scoreSpent > 0);
        uint256 claimId = _openAndJoin(ALICE, 10, scoreSpent, boosterAmount);
        uint256 expectedBoost =
            Math.mulDiv(uint256(scoreSpent), 10_000 + uint256(boosterAmount) * _boosterBoostBps(), 10_000);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, scoreSpent, expectedBoost, 10);
        _settle(1, root, none);
        _warpToFinalization(1);

        uint256 supplyBefore = booster.totalSupply(_boosterId());
        vm.prank(ALICE);
        defi.finalizeClaim(claimId, true, none, scoreSpent, expectedBoost, 10, new bytes32[](0));
        assert(registry.scoreSpent(ALICE) == scoreSpent);
        assert(booster.balanceOf(address(defi), _boosterId()) == 0);
        assert(booster.totalSupply(_boosterId()) == supplyBefore - boosterAmount);
        (,,, uint128 storedBooster,,) = defi.claims(claimId);
        assert(storedBooster == boosterAmount);
    }

    function test_singlePoolPayoutUsesExactCommittedBudgetAndLoss(uint64 payout, uint64 budget) public {
        vm.assume(payout <= budget);
        DefiInsuranceHarnessPool pool = _registerPool(type(uint128).max, type(uint128).max);
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory amounts = _oneAmount(payout);
        bytes32 root = _leaf(1, claimId, ALICE, amounts, 1, 1, 10);
        _settle(1, root, _oneAmount(budget));
        _warpToFinalization(1);
        uint256 assetsBefore = pool.assets();

        vm.prank(ALICE);
        defi.finalizeClaim(claimId, true, amounts, 1, 1, 10, new bytes32[](0));
        assert(pool.payCalls() == (payout == 0 ? 0 : 1));
        assert(pool.totalPaid() == payout);
        assert(pool.assets() == assetsBefore - payout);
        uint256[] memory remainingBudget = defi.incidentPoolBudget(1);
        assert(remainingBudget.length == 1 && remainingBudget[0] == uint256(budget) - payout);
        if (payout != 0) assert(pool.lastRecipient() == ALICE);
    }

    function test_twoClaimReverseOrderExactlyConsumesBudget() public {
        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        uint256 aliceClaim = _openAndJoin(ALICE, 10, 0, 0);
        uint256 bobClaim = _join(BOB, IERC20(address(insured)), 11, 0, 0);
        uint256[] memory aliceAmounts = _oneAmount(40);
        uint256[] memory bobAmounts = _oneAmount(60);
        bytes32 aliceLeaf = _leaf(1, aliceClaim, ALICE, aliceAmounts, 1, 1, 10);
        bytes32 bobLeaf = _leaf(1, bobClaim, BOB, bobAmounts, 1, 1, 11);
        bytes32 root = _hashPair(aliceLeaf, bobLeaf);
        _settle(1, root, _oneAmount(100));
        _warpToFinalization(1);

        bytes32[] memory bobProof = new bytes32[](1);
        bobProof[0] = aliceLeaf;
        vm.prank(BOB);
        defi.finalizeClaim(bobClaim, true, bobAmounts, 1, 1, 11, bobProof);
        assert(pool.totalPaid() == 60);
        assert(defi.activeIncidentId() == 1);
        assert(_incidentResolvedAt(1) == 0);

        bytes32[] memory aliceProof = new bytes32[](1);
        aliceProof[0] = bobLeaf;
        vm.prank(ALICE);
        defi.finalizeClaim(aliceClaim, true, aliceAmounts, 1, 1, 10, aliceProof);
        uint256 unresolved = _incidentUnresolved(1);
        assert(pool.totalPaid() == 100);
        uint256[] memory remainingBudget = defi.incidentPoolBudget(1);
        assert(remainingBudget.length == 1 && remainingBudget[0] == 0);
        assert(unresolved == 0);
        assert(defi.activeIncidentId() == 0);
        assert(_incidentResolvedAt(1) == block.timestamp);
    }

    function test_cumulativeBudgetExcessRollsBackSecondClaimOnly() public {
        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        uint256 aliceClaim = _openAndJoin(ALICE, 10, 0, 0);
        uint256 bobClaim = _join(BOB, IERC20(address(insured)), 11, 0, 0);
        uint256[] memory aliceAmounts = _oneAmount(70);
        uint256[] memory bobAmounts = _oneAmount(40);
        bytes32 aliceLeaf = _leaf(1, aliceClaim, ALICE, aliceAmounts, 1, 1, 10);
        bytes32 bobLeaf = _leaf(1, bobClaim, BOB, bobAmounts, 1, 1, 11);
        _settle(1, _hashPair(aliceLeaf, bobLeaf), _oneAmount(100));
        _warpToFinalization(1);

        bytes32[] memory aliceProof = new bytes32[](1);
        aliceProof[0] = bobLeaf;
        vm.prank(ALICE);
        defi.finalizeClaim(aliceClaim, true, aliceAmounts, 1, 1, 10, aliceProof);

        bytes32[] memory bobProof = new bytes32[](1);
        bobProof[0] = aliceLeaf;
        vm.prank(BOB);
        (bool success, bytes memory data) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (bobClaim, true, bobAmounts, uint256(1), uint256(1), uint256(11), bobProof)
                )
            );
        assert(!success && _selector(data) == DefiInsurance.PayoutCapExceeded.selector);
        (,,,,, bool bobResolved) = defi.claims(bobClaim);
        uint256 unresolved = _incidentUnresolved(1);
        assert(!bobResolved);
        assert(unresolved == 1);
        assert(pool.totalPaid() == 70);
        assert(insured.balanceOf(address(defi)) == 21);
    }

    function test_invalidLengthProofAndLeafFieldsRevertAtomically() public {
        _registerPool(1000, 500);
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory amount = _oneAmount(1);
        bytes32 root = _leaf(1, claimId, ALICE, amount, 1, 1, 10);
        _settle(1, root, _oneAmount(1));
        _warpToFinalization(1);

        uint256[] memory empty = _emptyAmounts();
        vm.prank(ALICE);
        (bool length, bytes memory ld) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, true, empty, uint256(1), uint256(1), uint256(10), new bytes32[](0))
                )
            );
        assert(!length && _sameBytes(ld, abi.encodeWithSelector(DefiInsurance.InvalidProof.selector, claimId)));
        vm.prank(ALICE);
        (bool field, bytes memory fd) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, true, amount, uint256(0), uint256(0), uint256(9), new bytes32[](0))
                )
            );
        assert(!field && _sameBytes(fd, abi.encodeWithSelector(DefiInsurance.InvalidProof.selector, claimId)));
        (,,,,, bool resolved) = defi.claims(claimId);
        assert(!resolved);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 10);
    }

    function test_invalidBoostRevertsAtomically(uint64 scoreSpent, uint8 boosterAmount) public {
        vm.assume(boosterAmount > 0);
        uint256 claimId = _openAndJoin(ALICE, 10, scoreSpent, boosterAmount);
        uint256 expected =
            Math.mulDiv(uint256(scoreSpent), 10_000 + uint256(boosterAmount) * _boosterBoostBps(), 10_000);
        uint256[] memory none = _emptyAmounts();
        bytes32 boostRoot = _leaf(1, claimId, ALICE, none, scoreSpent, expected + 1, 10);
        _settle(1, boostRoot, none);
        _warpToFinalization(1);

        vm.prank(ALICE);
        (bool boost, bytes memory bd) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, true, none, uint256(scoreSpent), expected + 1, uint256(10), new bytes32[](0))
                )
            );
        assert(!boost);
        assert(
            keccak256(bd)
                == keccak256(abi.encodeWithSelector(DefiInsurance.InvalidBoostedScore.selector, expected + 1, expected))
        );
        (,,,,, bool resolved) = defi.claims(claimId);
        assert(!resolved);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 10);
        assert(booster.balanceOf(address(defi), _boosterId()) == boosterAmount);
    }

    function test_eligibleExcessRevertsAtomicallyWithoutBackwardWarp() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 eligibleRoot = _leaf(1, claimId, ALICE, none, 0, 0, 11);
        _settle(1, eligibleRoot, none);
        _warpToFinalization(1);

        vm.prank(ALICE);
        (bool eligible, bytes memory ed) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, true, none, uint256(0), uint256(0), uint256(11), new bytes32[](0))
                )
            );
        assert(!eligible);
        assert(
            keccak256(ed)
                == keccak256(
                    abi.encodeWithSelector(DefiInsurance.EligibleExceedsEscrow.selector, uint256(11), uint256(10))
                )
        );
        (,,,,, bool resolved) = defi.claims(claimId);
        assert(!resolved);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 10);
    }

    function test_revertingPoolPaymentRollsBackEscrowBoosterScoreAndClaimThenRetrySucceeds() public {
        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        uint256 claimId = _openAndJoin(ALICE, 10, 7, 2);
        uint256 boosted = Math.mulDiv(7, 10_200, 10_000);
        uint256[] memory amount = _oneAmount(100);
        bytes32 root = _leaf(1, claimId, ALICE, amount, 7, boosted, 10);
        _settle(1, root, _oneAmount(100));
        _warpToFinalization(1);
        pool.setModes(false, false, true);

        vm.prank(ALICE);
        (bool success,) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, true, amount, uint256(7), boosted, uint256(10), new bytes32[](0))
                )
            );
        assert(!success);
        (,,,,, bool resolved) = defi.claims(claimId);
        uint256 unresolved = _incidentUnresolved(1);
        assert(!resolved && unresolved == 1);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 10);
        assert(booster.balanceOf(address(defi), _boosterId()) == 2);
        assert(registry.scoreSpent(ALICE) == 0);
        assert(pool.totalPaid() == 0);

        pool.setModes(false, false, false);
        vm.prank(ALICE);
        defi.finalizeClaim(claimId, true, amount, 7, boosted, 10, new bytes32[](0));
        assert(pool.totalPaid() == 100);
        assert(registry.scoreSpent(ALICE) == 7);
    }

    function test_scoreLedgerOverflowRollsBackWholeFinalization() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 1, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 1, 1, 10);
        _settle(1, root, none);
        _warpToFinalization(1);
        vm.prank(address(defi));
        registry.recordScoreSpent(ALICE, type(uint256).max);

        vm.prank(ALICE);
        (bool success,) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, true, none, uint256(1), uint256(1), uint256(10), new bytes32[](0))
                )
            );
        assert(!success);
        (,,,,, bool resolved) = defi.claims(claimId);
        assert(!resolved);
        assert(registry.scoreSpent(ALICE) == type(uint256).max);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 10);
        assert(insured.balanceOf(address(defi)) == 10);
    }

    function test_finalizationPhaseEndpointsAndPauseAreExact() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 1, 1, 10);
        _settle(1, root, none);
        uint64 correctionDeadline = _incidentPhaseDeadline(1);
        vm.warp(correctionDeadline);
        vm.prank(ALICE);
        (bool early, bytes memory ed) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, true, none, uint256(1), uint256(1), uint256(10), new bytes32[](0))
                )
            );
        assert(!early && _sameBytes(ed, abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, claimId)));

        vm.warp(uint256(correctionDeadline) + 1);
        registry.setPaused(address(defi), true);
        vm.prank(ALICE);
        (bool paused, bytes memory pd) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, true, none, uint256(1), uint256(1), uint256(10), new bytes32[](0))
                )
            );
        assert(!paused && _selector(pd) == Registry.Paused.selector);
        registry.setPaused(address(defi), false);
        vm.prank(ALICE);
        defi.finalizeClaim(claimId, true, none, 1, 1, 10, new bytes32[](0));
    }

    function test_doubleFinalizationCannotPayOrConsumeTwice() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 1, 1, 10);
        _settle(1, root, none);
        _warpToFinalization(1);
        vm.prank(ALICE);
        defi.finalizeClaim(claimId, true, none, 1, 1, 10, new bytes32[](0));
        uint256 balance = insured.balanceOf(address(defi));
        uint256 aliceBalance = insured.balanceOf(ALICE);
        uint256 unresolved = _incidentUnresolved(1);
        uint64 resolvedAt = _incidentResolvedAt(1);
        uint256 escrowed = defi.escrowedInsuredTokens(IERC20(address(insured)));

        vm.prank(ALICE);
        (bool again, bytes memory data) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, true, none, uint256(1), uint256(1), uint256(10), new bytes32[](0))
                )
            );
        assert(!again && _sameBytes(data, abi.encodeWithSelector(DefiInsurance.ClaimAlreadyResolved.selector, claimId)));
        assert(insured.balanceOf(address(defi)) == balance);
        assert(insured.balanceOf(ALICE) == aliceBalance);
        assert(_incidentUnresolved(1) == unresolved);
        assert(_incidentResolvedAt(1) == resolvedAt);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == escrowed);
        (,,,,, bool resolved) = defi.claims(claimId);
        assert(resolved);
    }

    function test_missingRootResolutionBoundaryIsStrictAndWorksWhilePaused() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 2);
        uint256 settlementDeadline = uint256(_incidentPhaseDeadline(1)) + defi.incidentPhaseWindow(1);
        vm.warp(settlementDeadline);
        vm.prank(ALICE);
        (bool early, bytes memory ed) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, false, new uint256[](0), uint256(0), uint256(0), uint256(0), new bytes32[](0))
                )
            );
        assert(!early && _selector(ed) == DefiInsurance.FinalizeNotOpen.selector);

        vm.warp(uint256(settlementDeadline) + 1);
        registry.setPaused(address(defi), true);
        vm.prank(ALICE);
        defi.finalizeClaim(claimId, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
        assert(insured.balanceOf(ALICE) == 10);
        assert(booster.balanceOf(ALICE, _boosterId()) == 2);
        assert(_incidentResolvedAt(1) == block.timestamp);
    }

    function test_thirdPartyMayResolveProvenZeroScoreClaim() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 0, 0, 10);
        _settle(1, root, none);
        _warpToFinalization(1);

        vm.prank(BOB);
        defi.finalizeClaim(claimId, false, none, 0, 0, 10, new bytes32[](0));

        (,,,,, bool resolved) = defi.claims(claimId);
        assert(resolved);
        assert(insured.balanceOf(ALICE) == 10);
        assert(registry.scoreSpent(ALICE) == 0);
    }

    function test_declineIsAvailableAfterDisputeAndChecksUnauthorizedResolved() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 1, 1, 10);
        _settle(1, root, none);
        _warpToFinalization(1);

        vm.prank(BOB);
        (bool unauthorized, bytes memory ud) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, false, none, uint256(1), uint256(1), uint256(10), new bytes32[](0))
                )
            );
        assert(
            !unauthorized && _sameBytes(ud, abi.encodeWithSelector(DefiInsurance.UnauthorizedClaim.selector, claimId))
        );
        (,,,,, bool resolvedBefore) = defi.claims(claimId);
        assert(!resolvedBefore && _incidentUnresolved(1) == 1);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 10);

        vm.prank(ALICE);
        defi.finalizeClaim(claimId, false, none, 1, 1, 10, new bytes32[](0));
        vm.prank(ALICE);
        (bool twice, bytes memory td) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, false, none, uint256(1), uint256(1), uint256(10), new bytes32[](0))
                )
            );
        assert(!twice && _selector(td) == DefiInsurance.ClaimAlreadyResolved.selector);
    }

    function test_deregisteredModuleCannotFinalizeAndImmediatelyEnablesRecovery() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 2);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 1, 1, 10);
        _settle(1, root, none);
        _warpToFinalization(1);
        registry.setDefiInsurance(address(0));

        vm.prank(ALICE);
        (bool finalizeSuccess, bytes memory finalizeData) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.finalizeClaim,
                    (claimId, true, none, uint256(1), uint256(1), uint256(10), new bytes32[](0))
                )
            );
        assert(!finalizeSuccess && _selector(finalizeData) == DefiInsurance.FinalizeNotOpen.selector);
        (,,,,, bool resolvedBefore) = defi.claims(claimId);
        uint256 unresolvedBefore = _incidentUnresolved(1);
        assert(!resolvedBefore && unresolvedBefore == 1);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 10);

        vm.prank(ALICE);
        defi.finalizeClaim(claimId, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
        (,,,,, bool resolvedAfter) = defi.claims(claimId);
        uint256 unresolvedAfter = _incidentUnresolved(1);
        assert(resolvedAfter && unresolvedAfter == 0);
        assert(_incidentResolvedAt(1) == block.timestamp);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 0);
        assert(insured.balanceOf(ALICE) == 10);
        assert(booster.balanceOf(ALICE, _boosterId()) == 2);
    }

    function test_poolPaymentCallbackCannotReenterFinalizationAndOuterPayoutCompletes() public {
        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        uint256 claimId = _openAndJoin(ALICE, 10, 1, 0);
        uint256[] memory amount = _oneAmount(25);
        bytes32 root = _leaf(1, claimId, ALICE, amount, 1, 1, 10);
        _settle(1, root, _oneAmount(25));
        _warpToFinalization(1);
        pool.configureCallback(
            address(defi),
            abi.encodeCall(
                DefiInsurance.finalizeClaim,
                (claimId, true, amount, uint256(1), uint256(1), uint256(10), new bytes32[](0))
            )
        );

        vm.prank(ALICE);
        defi.finalizeClaim(claimId, true, amount, 1, 1, 10, new bytes32[](0));

        assert(pool.callbackAttempts() == 1);
        assert(!pool.callbackSuccess());
        assert(pool.callbackSelector() == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assert(pool.callbackReturndataLength() == 4);
        assert(pool.totalPaid() == 25 && pool.assets() == 975);
        uint256[] memory remaining = defi.incidentPoolBudget(1);
        assert(remaining.length == 1 && remaining[0] == 0);
        (,,,,, bool resolved) = defi.claims(claimId);
        assert(resolved && _incidentUnresolved(1) == 0);
    }
}
