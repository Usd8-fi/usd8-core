// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {DefiInsuranceKontrolBase, DefiInsuranceHarnessPool} from "./DefiInsuranceHarness.k.sol";
import {
    USD8SweepStandardToken,
    USD8SweepRevertingToken,
    USD8SweepFalseReturnToken,
    USD8SweepNoReturnToken,
    USD8SweepMalformedReturnToken,
    USD8SweepRejectingReceiver
} from "./USD8Sweep.k.sol";

contract DefiInsuranceUpgradeV2 is DefiInsurance {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract DefiInsuranceUpgradeNonUUPS {
    function version() external pure returns (uint256) {
        return 999;
    }
}

contract DefiInsuranceUpgradeWrongUUID {
    function proxiableUUID() external pure returns (bytes32) {
        return keccak256("wrong-defi-insurance-uuid");
    }
}

contract DefiInsuranceUpgradeFailingInitializer is DefiInsurance {
    error InitializationFailed();
    uint256 public candidateValue;

    function initializeV2ThenRevert(uint256 value) external reinitializer(2) {
        candidateValue = value;
        revert InitializationFailed();
    }
}

/// @notice SharedBase sweep and beta-only UUPS lifecycle properties for DefiInsurance.
contract DefiInsuranceAdminKontrolTest is DefiInsuranceKontrolBase {
    struct UpgradeSnapshot {
        bytes32 incidentTuple;
        bytes32 claimTuple;
        bytes32 pools;
        bytes32 budget;
        bytes32 config;
        uint256 insuredBalance;
        uint64 phaseWindow;
        uint64 nextIncident;
        uint64 nextClaim;
        bytes32 liveClaimTuple;
        uint256 liveEscrow;
        uint256 liveBondBalance;
        uint256 liveBoosterBalance;
    }

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address internal constant RECIPIENT = address(0xBEEFCAFE);
    address internal constant NO_CODE = address(0xDEAD);

    function _implementationWord() internal view returns (bytes32) {
        return vm.load(address(defi), IMPLEMENTATION_SLOT);
    }

    function _incidentTupleHash(uint256 incidentId) internal view returns (bytes32) {
        (
            IERC20 token,
            uint64 resolvedAt,
            uint64 referenceBlock,
            uint64 openBlock,
            uint64 phaseDeadline,
            bytes32 root,
            uint256 unresolved,
            bytes32 claimSetHash,
            bytes32 teePcrHash,
            uint16 protocolFeeShareBps
        ) = defi.incidents(incidentId);
        return keccak256(
            abi.encode(
                token,
                resolvedAt,
                referenceBlock,
                openBlock,
                phaseDeadline,
                root,
                unresolved,
                claimSetHash,
                teePcrHash,
                protocolFeeShareBps
            )
        );
    }

    function _claimTupleHash(uint256 claimId) internal view returns (bytes32) {
        (address user, uint64 incidentId, uint128 escrow, uint128 boosterAmount, uint128 bondAmount, bool resolved) =
            defi.claims(claimId);
        return keccak256(abi.encode(user, incidentId, escrow, boosterAmount, bondAmount, resolved));
    }

    function test_sweepOnlyTransfersSurplusAboveLiveEscrow(uint64 escrow, uint64 surplus) public {
        vm.assume(escrow > 0);
        vm.assume(surplus > 0);
        _openAndJoin(ALICE, escrow, 0, 0);
        insured.mint(address(defi), surplus);
        defi.sweepToken(IERC20(address(insured)), RECIPIENT);
        assert(insured.balanceOf(address(defi)) == escrow);
        assert(insured.balanceOf(RECIPIENT) == surplus);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == escrow);
    }

    function test_foreignStandardAndLegacyNoReturnTokensSweepExactly(uint64 amount) public {
        vm.assume(amount > 0);
        USD8SweepStandardToken standard = new USD8SweepStandardToken();
        standard.mint(address(defi), amount);
        defi.sweepToken(IERC20(address(standard)), RECIPIENT);
        assert(standard.balanceOf(address(defi)) == 0);
        assert(standard.balanceOf(RECIPIENT) == amount);

        USD8SweepNoReturnToken legacy = new USD8SweepNoReturnToken();
        legacy.mint(address(defi), amount);
        defi.sweepToken(IERC20(address(legacy)), RECIPIENT);
        assert(legacy.balanceOf(address(defi)) == 0);
        assert(legacy.balanceOf(RECIPIENT) == amount);
    }

    function test_falseRevertingAndMalformedTokenSweepsRollbackAtomically(uint64 amount) public {
        vm.assume(amount > 0);
        USD8SweepFalseReturnToken falseToken = new USD8SweepFalseReturnToken();
        USD8SweepRevertingToken revertingToken = new USD8SweepRevertingToken();
        USD8SweepMalformedReturnToken malformed = new USD8SweepMalformedReturnToken();
        falseToken.mint(address(defi), amount);
        revertingToken.mint(address(defi), amount);
        malformed.mint(address(defi), amount);

        (bool f, bytes memory fd) =
            address(defi).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(falseToken)), RECIPIENT)));
        (bool r,) =
            address(defi).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(revertingToken)), RECIPIENT)));
        (bool m,) = address(defi).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(malformed)), RECIPIENT)));
        assert(!f && !r && !m);
        assert(
            keccak256(fd)
                == keccak256(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(falseToken)))
        );
        assert(falseToken.balanceOf(address(defi)) == amount);
        assert(revertingToken.balanceOf(address(defi)) == amount);
        assert(malformed.balanceOf(address(defi)) == amount);
        assert(malformed.balanceOf(RECIPIENT) == 0);
    }

    function test_sweepAclRecipientAndNothingToSweepGuardsAreAtomic() public {
        USD8SweepStandardToken token = new USD8SweepStandardToken();
        token.mint(address(defi), 10);
        (bool unauthorized, bytes memory ud) =
            _callAs(OUTSIDER, abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), RECIPIENT)));
        assert(!unauthorized && _selector(ud) == Registry.UnauthorizedAdmin.selector);
        (bool zero, bytes memory zd) =
            address(defi).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), address(0))));
        assert(!zero && _selector(zd) == SharedBase.ZeroAddress.selector);
        (bool self, bytes memory sd) =
            address(defi).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(token)), address(defi))));
        assert(
            !self && _sameBytes(sd, abi.encodeWithSelector(SharedBase.InvalidSweepRecipient.selector, address(defi)))
        );
        assert(token.balanceOf(address(defi)) == 10);
        assert(token.balanceOf(RECIPIENT) == 0);

        _openAndJoin(ALICE, 10, 0, 0);
        uint256 recipientBefore = insured.balanceOf(RECIPIENT);
        (bool nothing, bytes memory nd) =
            address(defi).call(abi.encodeCall(SharedBase.sweepToken, (IERC20(address(insured)), RECIPIENT)));
        assert(!nothing && _sameBytes(nd, abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(insured))));
        assert(insured.balanceOf(address(defi)) == 10);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 10);
        assert(insured.balanceOf(RECIPIENT) == recipientBefore);
    }

    function test_ethSweepExactAndRejectingReceiverRollback(uint128 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(defi), amount);
        uint256 recipientBefore = RECIPIENT.balance;
        defi.sweepETH(payable(RECIPIENT));
        assert(address(defi).balance == 0);
        assert(RECIPIENT.balance == recipientBefore + amount);

        USD8SweepRejectingReceiver rejecting = new USD8SweepRejectingReceiver();
        vm.deal(address(defi), amount);
        (bool success, bytes memory data) =
            address(defi).call(abi.encodeCall(SharedBase.sweepETH, (payable(address(rejecting)))));
        assert(!success && _sameBytes(data, abi.encodeWithSelector(SharedBase.EthTransferFailed.selector)));
        assert(address(defi).balance == amount);
        assert(address(rejecting).balance == 0);
    }

    function test_validNamedV2UpgradePreservesHistoricalResolvedInsuranceState(uint64 surplus) public {
        vm.assume(surplus > 0);
        defi.setClaimBondAmount(77);
        DefiInsurance.SettlementParams memory params =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 11, minHoldingRequired: 22, sampleStepBlocks: 33});
        defi.setSettlementParams(params);
        DefiInsurance.InsuredToken memory config = defi.getInsuredToken(IERC20(address(insured)));
        defi.editInsuredToken(
            IERC20(address(insured)), 8000, config.underlyingPriceOracle, address(0xC0DE), hex"12345678aabbccdd"
        );

        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        uint256 claimId = _openAndJoin(ALICE, 10, 3, 2);
        uint256[] memory amounts = _oneAmount(25);
        bytes32 root = _leaf(1, claimId, ALICE, amounts, 3, 3, 10);
        _settle(1, root, _oneAmount(40));
        _warpToFinalization(1);
        vm.prank(ALICE);
        defi.finalizeClaim(claimId, true, amounts, 3, 3, 10, new bytes32[](0));
        assert(defi.activeIncidentId() == 0);
        assert(pool.totalPaid() == 25);
        defi.editInsuredToken(IERC20(address(insured)), 8000, address(feed), address(0xC0DE), hex"12345678aabbccdd");
        uint256 liveClaimId = _openAndJoin(BOB, 12, 5, 3);
        uint256 terminalDeadline = uint256(_incidentPhaseDeadline(2)) + defi.incidentPhaseWindow(2);
        vm.warp(terminalDeadline + 1);
        assert(defi.activeIncidentId() == 0);
        assert(_incidentUnresolved(2) == 1);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 12);
        insured.mint(address(defi), surplus);

        UpgradeSnapshot memory before_ = UpgradeSnapshot({
            incidentTuple: _incidentTupleHash(1),
            claimTuple: _claimTupleHash(claimId),
            pools: keccak256(abi.encode(defi.incidentPools(1))),
            budget: keccak256(abi.encode(defi.incidentPoolBudget(1))),
            config: keccak256(abi.encode(defi.getInsuredToken(IERC20(address(insured))))),
            insuredBalance: insured.balanceOf(address(defi)),
            phaseWindow: defi.incidentPhaseWindow(1),
            nextIncident: defi.nextIncidentId(),
            nextClaim: defi.nextClaimId(),
            liveClaimTuple: _claimTupleHash(liveClaimId),
            liveEscrow: defi.escrowedInsuredTokens(IERC20(address(insured))),
            liveBondBalance: bondToken.balanceOf(address(defi)),
            liveBoosterBalance: booster.balanceOf(address(defi), _boosterId())
        });

        DefiInsuranceUpgradeV2 candidate = new DefiInsuranceUpgradeV2();
        defi.upgradeToAndCall(address(candidate), "");
        DefiInsuranceUpgradeV2 upgraded = DefiInsuranceUpgradeV2(address(defi));

        assert(upgraded.version() == 2);
        assert(address(upgraded.registry()) == address(registry));
        assert(keccak256(abi.encode(upgraded.getInsuredToken(IERC20(address(insured))))) == before_.config);
        assert(upgraded.isTeeSigner(vm.addr(TEE_KEY)));
        assert(upgraded.claimBondAmount() == 77);
        (uint64 lookback, uint64 holding, uint64 stride) = upgraded.settlementParams();
        assert(lookback == 11 && holding == 22 && stride == 33);
        assert(upgraded.nextIncidentId() == before_.nextIncident);
        assert(upgraded.nextClaimId() == before_.nextClaim);
        assert(upgraded.incidentPhaseWindow(1) == before_.phaseWindow);
        assert(_incidentTupleHash(1) == before_.incidentTuple);
        assert(_claimTupleHash(claimId) == before_.claimTuple);
        assert(keccak256(abi.encode(upgraded.incidentPools(1))) == before_.pools);
        assert(keccak256(abi.encode(upgraded.incidentPoolBudget(1))) == before_.budget);
        assert(upgraded.claimIdByIncidentAndUser(1, ALICE) == claimId);
        assert(_claimTupleHash(liveClaimId) == before_.liveClaimTuple);
        assert(upgraded.escrowedInsuredTokens(IERC20(address(insured))) == before_.liveEscrow);
        assert(insured.balanceOf(address(upgraded)) == before_.insuredBalance);
        assert(bondToken.balanceOf(address(upgraded)) == before_.liveBondBalance);
        assert(booster.balanceOf(address(upgraded), _boosterId()) == before_.liveBoosterBalance);

        vm.prank(BOB);
        upgraded.finalizeClaim(liveClaimId, false, new uint256[](0), 0, 0, 0, new bytes32[](0));
        assert(upgraded.escrowedInsuredTokens(IERC20(address(insured))) == 0);
        assert(bondToken.balanceOf(address(upgraded)) == 0);
        assert(booster.balanceOf(address(upgraded), _boosterId()) == 0);
    }

    function test_unauthorizedActiveIncidentAndPostBetaUpgradesRollbackImplementation() public {
        DefiInsuranceUpgradeV2 candidate = new DefiInsuranceUpgradeV2();
        bytes32 before_ = _implementationWord();
        vm.prank(OUTSIDER);
        (bool unauthorized, bytes memory ud) =
            address(defi).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));
        assert(!unauthorized && _selector(ud) == Registry.UnauthorizedTimelock.selector);
        assert(_implementationWord() == before_);

        _open(IERC20(address(insured)));
        (bool active, bytes memory ad) =
            address(defi).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));
        assert(!active && _selector(ad) == DefiInsurance.IncidentsActive.selector);
        assert(_implementationWord() == before_);
    }

    function test_upgradeRejectedAfterBetaEnds() public {
        registry.endBetaMode();
        DefiInsuranceUpgradeV2 candidate = new DefiInsuranceUpgradeV2();
        bytes32 before_ = _implementationWord();
        (bool success, bytes memory data) =
            address(defi).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));
        assert(!success && _sameBytes(data, abi.encodeWithSelector(SharedBase.NotBetaMode.selector)));
        assert(_implementationWord() == before_);
    }

    function test_nonUupsCandidateReturnsExactInvalidImplementationAndNoCodePreemptsWithEmptyBytes() public {
        bytes32 before_ = _implementationWord();
        DefiInsuranceUpgradeNonUUPS nonUups = new DefiInsuranceUpgradeNonUUPS();

        (bool noCodeSuccess, bytes memory noCodeData) =
            address(defi).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (NO_CODE, bytes(""))));
        assert(!noCodeSuccess && noCodeData.length == 0);
        assert(_implementationWord() == before_);

        (bool success, bytes memory data) =
            address(defi).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(nonUups), bytes(""))));
        assert(!success);
        assert(
            keccak256(data)
                == keccak256(
                    abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(nonUups))
                )
        );
        assert(_implementationWord() == before_);
        assert(address(defi.registry()) == address(registry));
    }

    function test_wrongUuidCandidateReturnsExactUnsupportedUuidAndRollsBack() public {
        bytes32 before_ = _implementationWord();
        DefiInsuranceUpgradeWrongUUID wrong = new DefiInsuranceUpgradeWrongUUID();
        bytes32 wrongSlot = keccak256("wrong-defi-insurance-uuid");
        (bool success, bytes memory data) =
            address(defi).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(wrong), bytes(""))));
        assert(!success);
        assert(
            keccak256(data)
                == keccak256(abi.encodeWithSelector(UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, wrongSlot))
        );
        assert(_implementationWord() == before_);
        assert(address(defi.registry()) == address(registry));
    }

    function test_emptyCalldataUpgradeRejectsValueWithExactFourBytesAndRollback() public {
        DefiInsuranceUpgradeV2 candidate = new DefiInsuranceUpgradeV2();
        bytes32 before_ = _implementationWord();
        vm.deal(address(this), 1);
        (bool success, bytes memory data) = address(defi).call{value: 1}(
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes("")))
        );
        assert(!success);
        assert(data.length == 4 && _selector(data) == ERC1967Utils.ERC1967NonPayable.selector);
        assert(_implementationWord() == before_);
        assert(address(defi).balance == 0);
        assert(address(this).balance == 1);
    }

    function test_failedDelegateInitializerRollsBackImplementationAndWrites() public {
        DefiInsuranceUpgradeFailingInitializer candidate = new DefiInsuranceUpgradeFailingInitializer();
        bytes32 before_ = _implementationWord();
        bytes memory init = abi.encodeCall(DefiInsuranceUpgradeFailingInitializer.initializeV2ThenRevert, (77));
        (bool success,) =
            address(defi).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), init)));
        assert(!success);
        assert(_implementationWord() == before_);
        assert(address(defi.registry()) == address(registry));
        (bool valueSuccess,) = address(defi).staticcall(abi.encodeWithSignature("candidateValue()"));
        assert(!valueSuccess);
    }

    function test_proxyAndImplementationUupsContextsAreExact() public view {
        bytes32 implementationBefore = _implementationWord();
        address registryBefore = address(defi.registry());
        uint64 nextIncidentBefore = defi.nextIncidentId();
        uint64 nextClaimBefore = defi.nextClaimId();
        (bool proxySuccess, bytes memory proxyData) =
            address(defi).staticcall(abi.encodeCall(IERC1822Proxiable.proxiableUUID, ()));
        assert(
            !proxySuccess
                && _sameBytes(proxyData, abi.encodeWithSelector(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector))
        );
        assert(_implementationWord() == implementationBefore);
        assert(address(defi.registry()) == registryBefore);
        assert(defi.nextIncidentId() == nextIncidentBefore && defi.nextClaimId() == nextClaimBefore);
        assert(implementation.proxiableUUID() == IMPLEMENTATION_SLOT);
    }
}
