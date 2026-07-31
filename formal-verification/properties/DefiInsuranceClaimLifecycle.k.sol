// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {DefiInsuranceKontrolBase, DefiInsuranceHarnessPool} from "./DefiInsuranceHarness.k.sol";

contract DefiInsuranceFeeToken is ERC20 {
    uint256 internal immutable fee;

    constructor(uint256 fee_) ERC20("Fee Token", "FEE") {
        fee = fee_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && fee != 0) {
            require(value >= fee, "fee exceeds amount");
            super._update(from, to, value - fee);
            super._update(from, address(0), fee);
            return;
        }
        super._update(from, to, value);
    }
}

/// @dev ERC20 callback model that catches nested-call failure so the outer
///      production transition can complete and expose the exact transient guard.
contract DefiInsuranceCallbackToken is ERC20 {
    address internal callbackTarget;
    bytes internal callbackData;
    bool internal armed;
    uint256 public callbackAttempts;
    bool public callbackSuccess;
    bytes4 public callbackSelector;
    uint256 public callbackReturndataLength;

    constructor() ERC20("Callback Token", "CALL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from != address(0) && to != address(0)) {
            armed = false;
            callbackAttempts++;
            bytes memory returndata;
            (callbackSuccess, returndata) = callbackTarget.call(callbackData);
            callbackReturndataLength = returndata.length;
            if (returndata.length >= 4) {
                bytes4 selector;
                assembly {
                    selector := mload(add(returndata, 0x20))
                }
                callbackSelector = selector;
            }
            armed = true;
        }
    }
}

/// @notice Incident opening, joining, escrow, booster, commitment, and cancellation properties.
contract DefiInsuranceClaimLifecycleKontrolTest is DefiInsuranceKontrolBase {
    function test_openSnapshotsRegistryTimingPcrAndPoolAfterSettlingMaturedEpochs() public {
        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        uint256 openedAt = block.timestamp;
        uint256 incidentId = _open(IERC20(address(insured)));
        Registry.IncidentTimingConfig memory timing = registry.incidentTimingConfig();
        (
            IERC20 token,
            uint64 resolvedAt,
            uint64 referenceBlock,
            uint64 openBlock,
            uint64 claimEnd,
            bytes32 root,
            uint256 unresolved,
            bytes32 claimSetHash,
            bytes32 teePcrHash,
            uint16 protocolFeeShareBps
        ) = defi.incidents(incidentId);
        assert(address(token) == address(insured));
        assert(claimEnd == openedAt + timing.phaseWindow);
        assert(root == bytes32(0));
        assert(unresolved == 0);
        assert(resolvedAt == 0);
        assert(referenceBlock == block.number - 1);
        assert(openBlock == block.number);
        assert(defi.incidentPhaseWindow(incidentId) == timing.phaseWindow);
        assert(claimSetHash == bytes32(0));
        assert(teePcrHash == PCR_HASH);
        assert(protocolFeeShareBps == registry.protocolFeeConfig().claimProtocolFeeShareBps);
        assert(pool.settleCalls() == 1);
        assert(defi.nextIncidentId() == 2);
        assert(defi.activeIncidentId() == incidentId);
    }

    function test_fullArrayGettersReturnExactEmptyAndOpenedPoolSnapshots() public {
        address[] memory emptyPools = new address[](0);
        uint256[] memory emptyBudget = new uint256[](0);

        // Full-array mapping getters do not index an array at the supplied id:
        // a never-opened incident succeeds with canonical ABI encoding of an empty array.
        (bool poolsSuccess, bytes memory poolsData) =
            address(defi).staticcall(abi.encodeCall(DefiInsurance.incidentPools, (type(uint256).max)));
        (bool budgetSuccess, bytes memory budgetData) =
            address(defi).staticcall(abi.encodeCall(DefiInsurance.incidentPoolBudget, (type(uint256).max)));
        assert(poolsSuccess && keccak256(poolsData) == keccak256(abi.encode(emptyPools)));
        assert(budgetSuccess && keccak256(budgetData) == keccak256(abi.encode(emptyBudget)));

        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        uint256 incidentId = _open(IERC20(address(insured)));
        address[] memory pools = defi.incidentPools(incidentId);
        uint256[] memory budget = defi.incidentPoolBudget(incidentId);
        assert(pools.length == 1 && pools[0] == address(pool));
        assert(budget.length == 0);
    }

    function test_openedIncidentDeadlinesIgnoreLaterLegalRegistryTimingChange() public {
        Registry.IncidentTimingConfig memory openingTiming = registry.incidentTimingConfig();
        uint256 openedAt = block.timestamp;
        uint256 oldIncident = _open(IERC20(address(insured)));
        uint256 expectedClaimDeadline = openedAt + openingTiming.phaseWindow;
        uint256 expectedTerminalDeadline = expectedClaimDeadline + openingTiming.phaseWindow;
        assert(_incidentPhaseDeadline(oldIncident) == expectedClaimDeadline);
        assert(defi.incidentPhaseWindow(oldIncident) == openingTiming.phaseWindow);

        vm.warp(expectedTerminalDeadline + 1);
        assert(defi.activeIncidentId() == 0);
        Registry.IncidentTimingConfig memory laterTiming = Registry.IncidentTimingConfig({
            phaseWindow: openingTiming.phaseWindow + 17, maxReferenceBlockAge: openingTiming.maxReferenceBlockAge
        });
        registry.setIncidentTimingConfig(laterTiming);

        assert(_incidentPhaseDeadline(oldIncident) == expectedClaimDeadline);
        assert(
            uint256(_incidentPhaseDeadline(oldIncident)) + defi.incidentPhaseWindow(oldIncident)
                == expectedTerminalDeadline
        );
        assert(defi.incidentPhaseWindow(oldIncident) == openingTiming.phaseWindow);

        uint256 newOpenedAt = block.timestamp;
        uint256 newIncident = _open(IERC20(address(secondInsured)));
        assert(_incidentPhaseDeadline(newIncident) == newOpenedAt + laterTiming.phaseWindow);
        assert(defi.incidentPhaseWindow(newIncident) == laterTiming.phaseWindow);
    }

    function test_openReferenceBlockExactAgeBoundarySucceeds() public {
        Registry.IncidentTimingConfig memory timing = registry.incidentTimingConfig();
        vm.roll(uint256(timing.maxReferenceBlockAge) + 100);
        uint64 referenceBlock = uint64(block.number - timing.maxReferenceBlockAge);
        uint256 incidentId = defi.openClaimIncident(IERC20(address(insured)), referenceBlock);
        uint64 stored = _incidentReferenceBlock(incidentId);
        assert(stored == referenceBlock);
    }

    function test_openRejectsZeroCurrentFutureAndTooOldReferenceBlocksAtomically() public {
        Registry.IncidentTimingConfig memory timing = registry.incidentTimingConfig();
        vm.roll(uint256(timing.maxReferenceBlockAge) + 100);
        uint64 tooOld = uint64(block.number - timing.maxReferenceBlockAge - 1);
        uint64[4] memory invalid = [uint64(0), uint64(block.number), uint64(block.number + 1), tooOld];
        for (uint256 i = 0; i < invalid.length; i++) {
            (bool success, bytes memory data) = address(defi)
                .call(abi.encodeCall(DefiInsurance.openClaimIncident, (IERC20(address(insured)), invalid[i])));
            assert(!success);
            assert(_sameBytes(data, abi.encodeWithSelector(DefiInsurance.InvalidReferenceBlock.selector, invalid[i])));
            assert(defi.nextIncidentId() == 1);
            assert(defi.activeIncidentId() == 0);
        }
    }

    function test_openAuthorizationPauseRegistrationAndSingleIncidentGuardsAreAtomic() public {
        (bool unauthorized, bytes memory ud) = _callAs(
            OUTSIDER,
            abi.encodeCall(DefiInsurance.openClaimIncident, (IERC20(address(insured)), uint64(block.number - 1)))
        );
        assert(!unauthorized && _selector(ud) == Registry.UnauthorizedAdmin.selector);

        registry.setPaused(address(defi), true);
        (bool paused, bytes memory pd) = address(defi)
            .call(abi.encodeCall(DefiInsurance.openClaimIncident, (IERC20(address(insured)), uint64(block.number - 1))));
        assert(!paused && _selector(pd) == Registry.Paused.selector);
        registry.setPaused(address(defi), false);

        registry.setDefiInsurance(address(0));
        (bool stale, bytes memory sd) = address(defi)
            .call(abi.encodeCall(DefiInsurance.openClaimIncident, (IERC20(address(insured)), uint64(block.number - 1))));
        assert(!stale && _selector(sd) == DefiInsurance.DefiInsuranceNotRegistered.selector);
        registry.setDefiInsurance(address(defi));

        _open(IERC20(address(insured)));
        uint64 nextIncidentBefore = defi.nextIncidentId();
        uint64 phaseDeadlineBefore = _incidentPhaseDeadline(1);
        bytes32 teePcrBefore = _incidentTeePcrHash(1);
        (bool second, bytes memory secondData) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.openClaimIncident, (IERC20(address(secondInsured)), uint64(block.number - 1))
                )
            );
        assert(!second && _sameBytes(secondData, abi.encodeWithSelector(DefiInsurance.IncidentsActive.selector)));
        assert(defi.nextIncidentId() == nextIncidentBefore);
        assert(defi.activeIncidentId() == 1);
        assert(_incidentPhaseDeadline(1) == phaseDeadlineBefore);
        assert(_incidentTeePcrHash(1) == teePcrBefore);
    }

    function test_openPoolFailureRollsBackEveryIncidentWrite() public {
        DefiInsuranceHarnessPool pool = _registerPool(1000, 500);
        pool.setModes(true, false, false);
        (bool success,) = address(defi)
            .call(abi.encodeCall(DefiInsurance.openClaimIncident, (IERC20(address(insured)), uint64(block.number - 1))));
        assert(!success);
        assert(defi.nextIncidentId() == 1);
        assert(defi.activeIncidentId() == 0);
        assert(_incidentTeePcrHash(1) == bytes32(0));
        assert(defi.incidentPhaseWindow(1) == 0);
        assert(pool.settleCalls() == 0);
    }

    function test_firstFileClaimUsesProductionDigestAndExactEscrow(uint128 amount, uint128 score) public {
        vm.assume(amount > 0);
        uint64 referenceBlock = uint64(block.number - 1);
        bytes memory signature = _openSignature(IERC20(address(insured)), referenceBlock);

        insured.mint(ALICE, amount);
        bondToken.mint(ALICE, defi.claimBondAmount());
        vm.startPrank(ALICE);
        insured.approve(address(defi), amount);
        bondToken.approve(address(defi), defi.claimBondAmount());
        uint256 claimId = defi.fileClaim(IERC20(address(insured)), amount, score, 0, referenceBlock, signature);
        vm.stopPrank();
        (address user, uint64 incidentId, uint128 escrow, uint128 boost, uint128 bond, bool resolved) =
            defi.claims(claimId);
        uint256 unresolved = _incidentUnresolved(incidentId);
        bytes32 claimSetHash = _claimSetHash(incidentId);
        assert(user == ALICE);
        assert(incidentId == 1);
        assert(escrow == amount);
        assert(boost == 0 && bond == defi.claimBondAmount() && !resolved);
        assert(unresolved == 1);
        assert(defi.claimIdByIncidentAndUser(incidentId, ALICE) == claimId);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == amount);
        assert(claimSetHash == keccak256(abi.encode(bytes32(0), claimId, ALICE, amount, score, uint256(0))));
    }

    function test_openSignatureBecomesInvalidWhenBoundPricePolicyChanges() public {
        insured.mint(ALICE, 10);
        vm.prank(ALICE);
        insured.approve(address(defi), 10);
        uint64 referenceBlock = uint64(block.number - 1);
        bytes memory staleSignature = _openSignature(IERC20(address(insured)), referenceBlock);

        registry.setIncidentOpenPriceConfig(
            Registry.IncidentOpenPriceConfig({twapBlocks: 1200, sampleStepBlocks: 300, minimumDropBps: 1234})
        );
        vm.prank(ALICE);
        (bool success, bytes memory data) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.fileClaim,
                    (IERC20(address(insured)), uint128(10), uint256(0), uint256(0), referenceBlock, staleSignature)
                )
            );
        assert(!success && _selector(data) == DefiInsurance.UnauthorizedOpenSigner.selector);
        assert(defi.nextIncidentId() == 1);
        assert(defi.nextClaimId() == 1);
        assert(defi.activeIncidentId() == 0);
        assert(insured.balanceOf(ALICE) == 10);
        assert(insured.balanceOf(address(defi)) == 0);
    }

    function test_firstJoinRejectsMalformedAndWrongSignerWithoutOpening() public {
        insured.mint(ALICE, 10);
        vm.prank(ALICE);
        insured.approve(address(defi), 10);
        uint64 referenceBlock = uint64(block.number - 1);

        vm.prank(ALICE);
        (bool malformed, bytes memory malformedData) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.fileClaim,
                    (IERC20(address(insured)), uint128(10), uint256(0), uint256(0), referenceBlock, bytes(""))
                )
            );
        assert(
            !malformed
                && _sameBytes(
                    malformedData, abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(0))
                )
        );
        assert(defi.nextIncidentId() == 1);

        uint256 wrongKey = 0xB0B;
        bytes32 structHash = keccak256(
            abi.encode(
                OPEN_TYPEHASH,
                address(insured),
                referenceBlock,
                uint256(1),
                PCR_HASH,
                _expectedIncidentOpenEligibilityHash(IERC20(address(insured)))
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("DefiInsurance"),
                keccak256("1"),
                block.chainid,
                address(defi)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        vm.prank(ALICE);
        (bool wrong, bytes memory wrongData) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.fileClaim,
                    (
                        IERC20(address(insured)),
                        uint128(10),
                        uint256(0),
                        uint256(0),
                        referenceBlock,
                        abi.encodePacked(r, s, v)
                    )
                )
            );
        assert(
            !wrong
                && _sameBytes(
                    wrongData, abi.encodeWithSelector(DefiInsurance.UnauthorizedOpenSigner.selector, vm.addr(wrongKey))
                )
        );
        assert(defi.nextIncidentId() == 1);
        assert(defi.nextClaimId() == 1);
        assert(defi.activeIncidentId() == 0);
        assert(insured.balanceOf(ALICE) == 10 && insured.balanceOf(address(defi)) == 0);
    }

    function test_laterJoinRejectsDuplicateWrongTokenAndClosedEndpoint() public {
        _openAndJoin(ALICE, 10, 0, 0);
        (bool duplicate, bytes memory dd) = _callAs(
            ALICE,
            abi.encodeCall(
                DefiInsurance.fileClaim,
                (IERC20(address(insured)), uint128(1), uint256(0), uint256(0), uint64(0), bytes(""))
            )
        );
        assert(!duplicate && _selector(dd) == DefiInsurance.DuplicateClaim.selector);
        (bool wrongToken, bytes memory wd) = _callAs(
            BOB,
            abi.encodeCall(
                DefiInsurance.fileClaim,
                (IERC20(address(secondInsured)), uint128(2), uint256(0), uint256(0), uint64(0), bytes(""))
            )
        );
        assert(!wrongToken && _selector(wd) == DefiInsurance.IncidentTokenMismatch.selector);

        uint64 claimEnd = _incidentPhaseDeadline(1);
        vm.warp(uint256(claimEnd) + 1);
        (bool late, bytes memory ld) = _callAs(
            BOB,
            abi.encodeCall(
                DefiInsurance.fileClaim,
                (IERC20(address(insured)), uint128(1), uint256(0), uint256(0), uint64(0), bytes(""))
            )
        );
        assert(!late);
        assert(
            keccak256(ld)
                == keccak256(
                    abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, IERC20(address(insured)), claimEnd)
                )
        );
        assert(defi.nextClaimId() == 2);
        assert(_incidentUnresolved(1) == 1);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 10);
    }

    function test_deregisteredModuleCannotAcceptClaimJoinOrEscrow() public {
        _openAndJoin(ALICE, 10, 0, 0);
        uint256 bond = defi.claimBondAmount();
        insured.mint(BOB, 2);
        bondToken.mint(BOB, bond);
        vm.startPrank(BOB);
        insured.approve(address(defi), 2);
        bondToken.approve(address(defi), bond);
        vm.stopPrank();

        uint256 nextClaimBefore = defi.nextClaimId();
        uint256 unresolvedBefore = _incidentUnresolved(1);
        bytes32 claimSetBefore = _claimSetHash(1);
        uint256 bobInsuredBefore = insured.balanceOf(BOB);
        uint256 bobBondBefore = bondToken.balanceOf(BOB);
        uint256 moduleInsuredBefore = insured.balanceOf(address(defi));
        uint256 moduleBondBefore = bondToken.balanceOf(address(defi));

        registry.setDefiInsurance(address(0));
        (bool success, bytes memory returndata) = _callAs(
            BOB,
            abi.encodeCall(
                DefiInsurance.fileClaim,
                (IERC20(address(insured)), uint128(2), uint256(0), uint256(0), uint64(0), bytes(""))
            )
        );

        assert(!success && _selector(returndata) == DefiInsurance.DefiInsuranceNotRegistered.selector);
        assert(defi.nextClaimId() == nextClaimBefore);
        assert(_incidentUnresolved(1) == unresolvedBefore);
        assert(_claimSetHash(1) == claimSetBefore);
        assert(insured.balanceOf(BOB) == bobInsuredBefore);
        assert(bondToken.balanceOf(BOB) == bobBondBefore);
        assert(insured.balanceOf(address(defi)) == moduleInsuredBefore);
        assert(bondToken.balanceOf(address(defi)) == moduleBondBefore);
    }

    function test_joinCreditsActualFeeOnTransferDelta() public {
        DefiInsuranceFeeToken feeToken = new DefiInsuranceFeeToken(1);
        defi.editInsuredToken(IERC20(address(feeToken)), 8000, address(feed), address(0), "");
        _open(IERC20(address(feeToken)));
        feeToken.mint(ALICE, 10);
        bondToken.mint(ALICE, defi.claimBondAmount());
        vm.startPrank(ALICE);
        feeToken.approve(address(defi), 10);
        bondToken.approve(address(defi), defi.claimBondAmount());
        uint256 claimId = defi.fileClaim(IERC20(address(feeToken)), 10, 0, 0, 0, "");
        vm.stopPrank();
        (,, uint128 escrow,,,) = defi.claims(claimId);
        assert(escrow == 9);
        assert(defi.escrowedInsuredTokens(IERC20(address(feeToken))) == 9);
        assert(feeToken.balanceOf(address(defi)) == 9);
    }

    function test_joinZeroTinyAndOversizedBoosterBoundaries() public {
        _open(IERC20(address(secondInsured)));
        (bool zero, bytes memory zd) = _callAs(
            ALICE,
            abi.encodeCall(
                DefiInsurance.fileClaim,
                (IERC20(address(secondInsured)), uint128(0), uint256(0), uint256(0), uint64(0), bytes(""))
            )
        );
        assert(!zero && _selector(zd) == DefiInsurance.ZeroAmount.selector);

        secondInsured.mint(ALICE, 1);
        bondToken.mint(ALICE, defi.claimBondAmount());
        vm.startPrank(ALICE);
        secondInsured.approve(address(defi), 1);
        bondToken.approve(address(defi), defi.claimBondAmount());
        uint256 tinyClaim = defi.fileClaim(IERC20(address(secondInsured)), 1, 0, 0, 0, "");
        vm.stopPrank();
        (,, uint128 tinyEscrow,,,) = defi.claims(tinyClaim);
        assert(tinyEscrow == 1);

        secondInsured.mint(BOB, 2);
        bondToken.mint(BOB, defi.claimBondAmount());
        vm.startPrank(BOB);
        secondInsured.approve(address(defi), 2);
        bondToken.approve(address(defi), defi.claimBondAmount());
        (bool huge, bytes memory hd) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.fileClaim,
                    (
                        IERC20(address(secondInsured)),
                        uint128(2),
                        uint256(0),
                        uint256(type(uint128).max) + 1,
                        uint64(0),
                        bytes("")
                    )
                )
            );
        vm.stopPrank();
        assert(!huge);
        assert(
            keccak256(hd)
                == keccak256(
                    abi.encodeWithSelector(
                        SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(128), uint256(type(uint128).max) + 1
                    )
                )
        );
        assert(defi.nextClaimId() == 2);
        assert(defi.escrowedInsuredTokens(IERC20(address(secondInsured))) == 1);
        assert(secondInsured.balanceOf(BOB) == 2);
        assert(bondToken.balanceOf(BOB) == defi.claimBondAmount());
    }

    function test_boosterEscrowIsSnapshottedExactly(uint8 boosterAmount) public {
        vm.assume(boosterAmount > 0);
        uint256 claimId = _openAndJoin(ALICE, 10, 7, boosterAmount);
        (,,, uint128 stored,,) = defi.claims(claimId);
        assert(stored == boosterAmount);
        assert(_boosterCollection() == address(booster));
        assert(booster.balanceOf(address(defi), _boosterId()) == boosterAmount);
        assert(booster.balanceOf(ALICE, _boosterId()) == 0);
        (,,, uint128 storedBooster,,) = defi.claims(claimId);
        assert(storedBooster == boosterAmount);
    }

    function test_cancelReturnsEscrowAndBoostersUpdatesCommitmentAndAllowsRefile(uint8 boosterAmount) public {
        vm.assume(boosterAmount > 0);
        uint256 claimId = _openAndJoin(ALICE, 10, 7, boosterAmount);
        bytes32 beforeHash = _claimSetHash(1);
        vm.prank(ALICE);
        defi.cancelClaim();

        (,,,,, bool resolved) = defi.claims(claimId);
        uint256 unresolved = _incidentUnresolved(1);
        bytes32 afterHash = _claimSetHash(1);
        assert(resolved);
        assert(unresolved == 0);
        assert(afterHash == keccak256(abi.encode(beforeHash, claimId)));
        assert(defi.claimIdByIncidentAndUser(1, ALICE) == 0);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 0);
        assert(insured.balanceOf(ALICE) == 10);
        assert(booster.balanceOf(ALICE, _boosterId()) == boosterAmount);

        uint256 replacement = _join(ALICE, IERC20(address(insured)), 11, 9, 0);
        assert(replacement == claimId + 1);
        assert(defi.claimIdByIncidentAndUser(1, ALICE) == replacement);
    }

    function test_cancelIsAvailableWhilePausedButNotAfterClaimWindow() public {
        _openAndJoin(ALICE, 10, 0, 0);
        registry.setPaused(address(defi), true);
        vm.prank(ALICE);
        defi.cancelClaim();
        assert(insured.balanceOf(ALICE) == 10);

        registry.setPaused(address(defi), false);
        _join(ALICE, IERC20(address(insured)), 10, 0, 0);
        uint64 claimEnd = _incidentPhaseDeadline(1);
        vm.warp(uint256(claimEnd) + 1);
        (bool late, bytes memory data) = _callAs(ALICE, abi.encodeCall(DefiInsurance.cancelClaim, ()));
        assert(!late && _selector(data) == DefiInsurance.ClaimWindowClosed.selector);
    }

    function test_cancelWithoutActiveClaimRevertsExactlyAndPreservesCounters() public {
        uint64 nextClaimBefore = defi.nextClaimId();
        uint64 nextIncidentBefore = defi.nextIncidentId();

        (bool success, bytes memory data) = _callAs(ALICE, abi.encodeCall(DefiInsurance.cancelClaim, ()));

        assert(!success && data.length == 4 && _selector(data) == DefiInsurance.NoActiveClaim.selector);
        assert(defi.nextClaimId() == nextClaimBefore);
        assert(defi.nextIncidentId() == nextIncidentBefore);
        assert(defi.activeIncidentId() == 0);
    }

    function test_laterJoinRejectsUnexpectedOpenAttestationExactlyAndAtomically() public {
        _openAndJoin(ALICE, 10, 0, 0);
        uint64 nextClaimBefore = defi.nextClaimId();
        uint256 unresolvedBefore = _incidentUnresolved(1);
        bytes32 claimSetBefore = _claimSetHash(1);

        (bool referenceSuccess, bytes memory referenceData) = _callAs(
            BOB,
            abi.encodeCall(
                DefiInsurance.fileClaim,
                (IERC20(address(insured)), uint128(1), uint256(0), uint256(0), uint64(1), bytes(""))
            )
        );
        (bool signatureSuccess, bytes memory signatureData) = _callAs(
            BOB,
            abi.encodeCall(
                DefiInsurance.fileClaim,
                (IERC20(address(insured)), uint128(1), uint256(0), uint256(0), uint64(0), hex"01")
            )
        );

        assert(
            !referenceSuccess && referenceData.length == 4
                && _selector(referenceData) == DefiInsurance.UnexpectedOpenAttestation.selector
        );
        assert(
            !signatureSuccess && signatureData.length == 4
                && _selector(signatureData) == DefiInsurance.UnexpectedOpenAttestation.selector
        );
        assert(defi.nextClaimId() == nextClaimBefore);
        assert(_incidentUnresolved(1) == unresolvedBefore);
        assert(_claimSetHash(1) == claimSetBefore);
        assert(insured.balanceOf(BOB) == 0 && bondToken.balanceOf(BOB) == 0);
    }

    function test_deregisteredModuleRejectsFirstClaimBeforeOpenAttestationPartition() public {
        uint64 nextIncidentBefore = defi.nextIncidentId();
        uint64 nextClaimBefore = defi.nextClaimId();
        registry.setDefiInsurance(address(0));

        (bool success, bytes memory data) = _callAs(
            ALICE,
            abi.encodeCall(
                DefiInsurance.fileClaim,
                (
                    IERC20(address(insured)),
                    uint128(1),
                    uint256(0),
                    uint256(0),
                    uint64(block.number - 1),
                    bytes("not-an-open-signature")
                )
            )
        );

        assert(!success && data.length == 4 && _selector(data) == DefiInsurance.DefiInsuranceNotRegistered.selector);
        assert(defi.nextIncidentId() == nextIncidentBefore);
        assert(defi.nextClaimId() == nextClaimBefore);
        assert(defi.activeIncidentId() == 0);
        assert(_incidentPhaseDeadline(1) == 0);
        assert(_incidentTeePcrHash(1) == bytes32(0));
    }

    function test_insuredTokenCallbackCannotReenterFileClaimAndOuterJoinIsExact() public {
        DefiInsuranceCallbackToken callbackToken = new DefiInsuranceCallbackToken();
        defi.editInsuredToken(IERC20(address(callbackToken)), 8000, address(feed), address(0), "");
        _open(IERC20(address(callbackToken)));
        uint256 bond = defi.claimBondAmount();
        callbackToken.mint(ALICE, 10);
        bondToken.mint(ALICE, bond);
        callbackToken.configureCallback(
            address(defi),
            abi.encodeCall(
                DefiInsurance.fileClaim,
                (IERC20(address(callbackToken)), uint128(1), uint256(0), uint256(0), uint64(0), bytes(""))
            )
        );

        vm.startPrank(ALICE);
        callbackToken.approve(address(defi), 10);
        bondToken.approve(address(defi), bond);
        uint256 claimId = defi.fileClaim(IERC20(address(callbackToken)), 10, 0, 0, 0, "");
        vm.stopPrank();

        assert(callbackToken.callbackAttempts() == 1);
        assert(!callbackToken.callbackSuccess());
        assert(callbackToken.callbackSelector() == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assert(callbackToken.callbackReturndataLength() == 4);
        assert(claimId == 1 && defi.nextClaimId() == 2);
        assert(_incidentUnresolved(1) == 1);
        assert(defi.escrowedInsuredTokens(IERC20(address(callbackToken))) == 10);
    }

    function test_cancelAfterDeregistrationIsExactAndReentrancySafe() public {
        DefiInsuranceCallbackToken callbackToken = new DefiInsuranceCallbackToken();
        defi.editInsuredToken(IERC20(address(callbackToken)), 8000, address(feed), address(0), "");
        _open(IERC20(address(callbackToken)));
        uint256 bond = defi.claimBondAmount();
        callbackToken.mint(ALICE, 10);
        bondToken.mint(ALICE, bond);
        vm.startPrank(ALICE);
        callbackToken.approve(address(defi), 10);
        bondToken.approve(address(defi), bond);
        uint256 claimId = defi.fileClaim(IERC20(address(callbackToken)), 10, 0, 0, 0, "");
        vm.stopPrank();
        callbackToken.configureCallback(address(defi), abi.encodeCall(DefiInsurance.cancelClaim, ()));
        registry.setDefiInsurance(address(0));

        vm.prank(ALICE);
        defi.cancelClaim();

        assert(callbackToken.callbackAttempts() == 1);
        assert(!callbackToken.callbackSuccess());
        assert(callbackToken.callbackReturndataLength() == 4);
        assert(callbackToken.callbackSelector() == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        (,,,,, bool resolved) = defi.claims(claimId);
        assert(resolved);
        assert(_incidentUnresolved(1) == 0);
        assert(defi.claimIdByIncidentAndUser(1, ALICE) == 0);
        assert(callbackToken.balanceOf(ALICE) == 10);
        assert(bondToken.balanceOf(ALICE) == bond);
        assert(defi.escrowedInsuredTokens(IERC20(address(callbackToken))) == 0);
    }

    function test_refundTokenCallbackCannotReenterCancelAndOuterCancelCompletes() public {
        DefiInsuranceCallbackToken callbackToken = new DefiInsuranceCallbackToken();
        defi.editInsuredToken(IERC20(address(callbackToken)), 8000, address(feed), address(0), "");
        _open(IERC20(address(callbackToken)));
        uint256 bond = defi.claimBondAmount();
        callbackToken.mint(ALICE, 10);
        bondToken.mint(ALICE, bond);
        vm.startPrank(ALICE);
        callbackToken.approve(address(defi), 10);
        bondToken.approve(address(defi), bond);
        uint256 claimId = defi.fileClaim(IERC20(address(callbackToken)), 10, 0, 0, 0, "");
        vm.stopPrank();
        callbackToken.configureCallback(address(defi), abi.encodeCall(DefiInsurance.cancelClaim, ()));

        vm.prank(ALICE);
        defi.cancelClaim();

        assert(callbackToken.callbackAttempts() == 1);
        assert(!callbackToken.callbackSuccess());
        assert(callbackToken.callbackSelector() == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assert(callbackToken.callbackReturndataLength() == 4);
        (,,,,, bool resolved) = defi.claims(claimId);
        assert(resolved && _incidentUnresolved(1) == 0);
        assert(callbackToken.balanceOf(ALICE) == 10);
        assert(defi.escrowedInsuredTokens(IERC20(address(callbackToken))) == 0);
    }
}
