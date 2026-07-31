// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DefiInsurance, ISingleAssetCoverPool} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {DefiInsuranceKontrolBase, DefiInsuranceHarnessToken} from "../properties/DefiInsuranceHarness.k.sol";

contract DefiInsuranceEventPool is ISingleAssetCoverPool {
    DefiInsuranceHarnessToken internal immutable payoutToken;
    uint256 internal immutable cap;

    event ClaimPaid(address indexed to, uint256 amount);

    constructor(DefiInsuranceHarnessToken token_, uint256 cap_) {
        payoutToken = token_;
        cap = cap_;
    }

    function settleMaturedExitEpochs(uint256) external pure returns (uint256) {
        return 0;
    }

    function asset() external view returns (address) {
        return address(payoutToken);
    }

    function totalAssets() external view returns (uint256) {
        return payoutToken.balanceOf(address(this));
    }

    function maxPayoutPerIncident() external view returns (uint256) {
        return cap;
    }

    function payClaim(address to, uint256 amount) external {
        payoutToken.transfer(to, amount);
        emit ClaimPaid(to, amount);
    }
}

/// @notice Foundry-only exact presence/order regressions for events that are not
/// the first transaction log. Kontrol v1.0.255 cannot advance expectEmit past
/// prior application, ERC20, ERC1155, or pool logs.
contract DefiInsuranceEventOrderingForgeTest is DefiInsuranceKontrolBase {
    address internal constant SWEEP_RECIPIENT = address(0xF00D);

    event RegistryChanged(address indexed oldRegistry, address indexed newRegistry);
    event Initialized(uint64 version);
    event InsuredTokenAdded(IERC20 indexed insuredToken);
    event MaxCoverageBpsSet(IERC20 indexed insuredToken, uint256 maxCoverageBps);
    event UnderlyingPriceOracleSet(IERC20 indexed insuredToken, address underlyingPriceOracle);
    event UnderlyingConversionSet(IERC20 indexed insuredToken, address conversionAddress, bytes conversionCallData);
    event InsuredTokenRemoved(IERC20 indexed insuredToken);
    event IncidentOpened(
        uint256 indexed incidentId, IERC20 indexed insuredToken, uint64 claimDeadline, uint16 protocolFeeShareBps
    );
    event IncidentSettled(uint256 indexed incidentId, bytes32 root, bytes32 teePcrHash);
    event ClaimRegistered(
        uint256 indexed claimId,
        uint256 indexed incidentId,
        address indexed user,
        uint128 insuredTokenAmount,
        uint256 scoreToSpend,
        uint256 boosterAmount
    );
    event ClaimFinalized(uint256 indexed claimId, address indexed user);
    event ProtocolFeePaid(uint256 indexed incidentId, address indexed pool, address indexed receiver, uint256 amount);
    event ClaimCancelled(uint256 indexed claimId, address indexed user);
    event ClaimDeclined(uint256 indexed claimId, address indexed user, bool eligible);
    event ScoreSpent(address indexed user, uint256 amount, uint256 indexed incidentId);
    event ScoreSpentRecorded(address indexed account, uint256 amount, uint256 newTotal);
    event TokenSwept(address indexed token, address indexed to, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event ClaimPaid(address indexed to, uint256 amount);

    function _deployUninitialized() internal returns (DefiInsurance fresh) {
        fresh = DefiInsurance(
            address(
                new ERC1967Proxy(
                    address(new DefiInsurance()), abi.encodeCall(DefiInsurance.getInsuredToken, (IERC20(address(0))))
                )
            )
        );
    }

    function test_initializeEmitsRegistryChangedThenInitialized() public {
        DefiInsurance fresh = _deployUninitialized();

        vm.expectEmit(true, true, false, true, address(fresh));
        emit RegistryChanged(address(0), address(registry));
        vm.expectEmit(false, false, false, true, address(fresh));
        emit Initialized(1);
        fresh.initialize(registry);
    }

    function test_newTokenConfigurationEmitsExactFourLogOrder() public {
        DefiInsuranceHarnessToken token = new DefiInsuranceHarnessToken("Ordered Token", "ORD");
        address conversion = address(0xC0DE);
        bytes memory conversionData = hex"12345678";

        vm.expectEmit(true, false, false, true, address(defi));
        emit InsuredTokenAdded(IERC20(address(token)));
        vm.expectEmit(true, false, false, true, address(defi));
        emit MaxCoverageBpsSet(IERC20(address(token)), 4321);
        vm.expectEmit(true, false, false, true, address(defi));
        emit UnderlyingPriceOracleSet(IERC20(address(token)), address(feed));
        vm.expectEmit(true, false, false, true, address(defi));
        emit UnderlyingConversionSet(IERC20(address(token)), conversion, conversionData);
        defi.editInsuredToken(IERC20(address(token)), 4321, address(feed), conversion, conversionData);
    }

    function test_firstFileClaimEmitsOpenTransfersThenExactRegistration() public {
        uint128 escrow = 17;
        uint256 score = 23;
        uint64 referenceBlock = uint64(block.number - 1);
        uint64 expectedDeadline = uint64(block.timestamp) + registry.incidentTimingConfig().phaseWindow;
        uint16 expectedFeeShare = registry.protocolFeeConfig().claimProtocolFeeShareBps;
        bytes memory signature = _openSignature(IERC20(address(insured)), referenceBlock);
        uint256 bond = defi.claimBondAmount();
        insured.mint(ALICE, escrow);
        bondToken.mint(ALICE, bond);
        vm.startPrank(ALICE);
        insured.approve(address(defi), escrow);
        bondToken.approve(address(defi), bond);

        vm.expectEmit(true, true, false, true, address(defi));
        emit IncidentOpened(1, IERC20(address(insured)), expectedDeadline, expectedFeeShare);
        vm.expectEmit(true, true, false, true, address(insured));
        emit Transfer(ALICE, address(defi), escrow);
        vm.expectEmit(true, true, false, true, address(bondToken));
        emit Transfer(ALICE, address(defi), bond);
        vm.expectEmit(true, true, true, true, address(defi));
        emit ClaimRegistered(1, 1, ALICE, escrow, score, 0);
        defi.fileClaim(IERC20(address(insured)), escrow, score, 0, referenceBlock, signature);
        vm.stopPrank();
    }

    function test_nonzeroBoosterTransferPrefixesExactClaimRegisteredPayload() public {
        _open(IERC20(address(insured)));
        uint128 escrow = 17;
        uint256 score = 23;
        uint256 boosterAmount = 4;
        uint256 bond = defi.claimBondAmount();
        insured.mint(ALICE, escrow);
        bondToken.mint(ALICE, bond);
        booster.mint(ALICE, _boosterId(), boosterAmount);

        vm.startPrank(ALICE);
        insured.approve(address(defi), escrow);
        bondToken.approve(address(defi), bond);
        booster.setApprovalForAll(address(defi), true);
        vm.expectEmit(true, true, false, true, address(insured));
        emit Transfer(ALICE, address(defi), escrow);
        vm.expectEmit(true, true, false, true, address(bondToken));
        emit Transfer(ALICE, address(defi), bond);
        vm.expectEmit(true, true, true, true, address(booster));
        emit TransferSingle(address(defi), ALICE, address(defi), _boosterId(), boosterAmount);
        vm.expectEmit(true, true, true, true, address(defi));
        emit ClaimRegistered(1, 1, ALICE, escrow, score, boosterAmount);
        defi.fileClaim(IERC20(address(insured)), escrow, score, boosterAmount, 0, "");
        vm.stopPrank();
    }

    function test_nonzeroBoosterBurnAndPayoutTokenPoolPrefixesAreExact() public {
        address feeReceiver = address(0xFEE);
        registry.setProtocolFeeConfig(
            Registry.ProtocolFeeConfig({receiver: feeReceiver, claimProtocolFeeShareBps: 2_000, reserveYieldFeeBps: 0})
        );
        DefiInsuranceEventPool pool = new DefiInsuranceEventPool(poolAsset, 500);
        poolAsset.mint(address(pool), 1000);
        registry.addPool(address(pool), address(feed));
        expectedRegistryPools.push(address(pool));
        uint256 claimId = _openAndJoin(ALICE, 10, 1, 2);
        uint256[] memory amounts = _oneAmount(25);
        bytes32 root = _leaf(1, claimId, ALICE, amounts, 1, 1, 10);
        _settle(1, root, _oneAmount(31));
        _warpToFinalization(1);
        uint256 bond = defi.claimBondAmount();

        vm.startPrank(ALICE);
        vm.expectEmit(true, true, true, true, address(booster));
        emit TransferSingle(address(defi), address(defi), address(0), _boosterId(), 2);
        vm.expectEmit(true, true, false, true, address(bondToken));
        emit Transfer(address(defi), ALICE, bond);
        vm.expectEmit(true, true, false, true, address(poolAsset));
        emit Transfer(address(pool), ALICE, 25);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ClaimPaid(ALICE, 25);
        vm.expectEmit(true, true, false, true, address(poolAsset));
        emit Transfer(address(pool), feeReceiver, 6);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ClaimPaid(feeReceiver, 6);
        vm.expectEmit(true, true, true, true, address(defi));
        emit ProtocolFeePaid(1, address(pool), feeReceiver, 6);
        vm.expectEmit(true, true, false, true, address(defi));
        emit ScoreSpent(ALICE, 1, 1);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ScoreSpentRecorded(ALICE, 1, 1);
        vm.expectEmit(true, true, false, true, address(defi));
        emit ClaimFinalized(claimId, ALICE);
        defi.finalizeClaim(claimId, true, amounts, 1, 1, 10, new bytes32[](0));
        vm.stopPrank();
    }

    function test_claimBondSetterEmitsNoLogsForZeroOrNonzero() public {
        vm.recordLogs();
        defi.setClaimBondAmount(0);
        defi.setClaimBondAmount(123);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 0);
        assertEq(defi.claimBondAmount(), 123);
    }

    function test_settlementEmitsDelistBeforeExactSettlement() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 0, 0, 10);
        uint64 claimEnd = _incidentPhaseDeadline(1);
        vm.warp(uint256(claimEnd) + 1);
        bytes memory signature = _fixtureSettlementSignature(1, root, none);

        vm.expectEmit(true, false, false, true, address(defi));
        emit InsuredTokenRemoved(IERC20(address(insured)));
        vm.expectEmit(true, false, false, true, address(defi));
        emit IncidentSettled(1, root, PCR_HASH);
        defi.settleIncident(root, none, signature);
    }

    function test_cancelEmitsBondAndInsuredTransfersBeforeCancellation() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256 bond = defi.claimBondAmount();

        vm.startPrank(ALICE);
        vm.expectEmit(true, true, false, true, address(bondToken));
        emit Transfer(address(defi), ALICE, bond);
        vm.expectEmit(true, true, false, true, address(insured));
        emit Transfer(address(defi), ALICE, 10);
        vm.expectEmit(true, true, false, true, address(defi));
        emit ClaimCancelled(claimId, ALICE);
        defi.cancelClaim();
        vm.stopPrank();
    }

    function test_acceptedFinalizationEmitsBondScoreRegistryThenFinalized() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 1, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 1, 1, 10);
        _settle(1, root, none);
        _warpToFinalization(1);
        uint256 bond = defi.claimBondAmount();

        vm.startPrank(ALICE);
        vm.expectEmit(true, true, false, true, address(bondToken));
        emit Transfer(address(defi), ALICE, bond);
        vm.expectEmit(true, true, false, true, address(defi));
        emit ScoreSpent(ALICE, 1, 1);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ScoreSpentRecorded(ALICE, 1, 1);
        vm.expectEmit(true, true, false, true, address(defi));
        emit ClaimFinalized(claimId, ALICE);
        defi.finalizeClaim(claimId, true, none, 1, 1, 10, new bytes32[](0));
        vm.stopPrank();
    }

    function test_eligibleDeclineEmitsRefundsThenExactEligibleFlag() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 1, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 1, 1, 10);
        _settle(1, root, none);
        _warpToFinalization(1);
        uint256 bond = defi.claimBondAmount();

        vm.startPrank(ALICE);
        vm.expectEmit(true, true, false, true, address(insured));
        emit Transfer(address(defi), ALICE, 10);
        vm.expectEmit(true, true, false, true, address(bondToken));
        emit Transfer(address(defi), ALICE, bond);
        vm.expectEmit(true, true, false, true, address(defi));
        emit ClaimDeclined(claimId, ALICE, true);
        defi.finalizeClaim(claimId, false, none, 1, 1, 10, new bytes32[](0));
        vm.stopPrank();
    }

    function test_ineligibleDeclineForfeitsBondThenEmitsFalseFlag() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 root = _leaf(1, claimId, ALICE, none, 0, 0, 10);
        _settle(1, root, none);
        _warpToFinalization(1);
        uint256 bond = defi.claimBondAmount();

        vm.startPrank(ALICE);
        vm.expectEmit(true, true, false, true, address(insured));
        emit Transfer(address(defi), ALICE, 10);
        vm.expectEmit(true, true, false, true, address(bondToken));
        emit Transfer(address(defi), CAROL, bond);
        vm.expectEmit(true, true, false, true, address(defi));
        emit ClaimDeclined(claimId, ALICE, false);
        defi.finalizeClaim(claimId, false, none, 0, 0, 10, new bytes32[](0));
        vm.stopPrank();
    }

    function test_sweepTokenEmitsTransferThenExactTokenSwept() public {
        DefiInsuranceHarnessToken stray = new DefiInsuranceHarnessToken("Stray", "STRAY");
        stray.mint(address(defi), 19);

        vm.expectEmit(true, true, false, true, address(stray));
        emit Transfer(address(defi), SWEEP_RECIPIENT, 19);
        vm.expectEmit(true, true, false, true, address(defi));
        emit TokenSwept(address(stray), SWEEP_RECIPIENT, 19);
        defi.sweepToken(IERC20(address(stray)), SWEEP_RECIPIENT);
    }
}
