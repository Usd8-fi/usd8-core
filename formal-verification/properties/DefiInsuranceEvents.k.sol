// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {DefiInsuranceKontrolBase, DefiInsuranceHarnessToken} from "./DefiInsuranceHarness.k.sol";

contract DefiInsuranceEventsV2 is DefiInsurance {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Exact first-transaction-log properties supported by Kontrol v1.0.255.
/// @dev The compiled DefiInsurance ABI has 22 events. Ten are proved here, eleven
///      later-log obligations are proved by DefiInsuranceEventOrderingForgeTest,
///      and EIP712DomainChanged is structurally excluded because current
///      EIP712Upgradeable source declares but never emits it.
contract DefiInsuranceEventsKontrolTest is DefiInsuranceKontrolBase {
    address internal constant SWEEP_RECIPIENT = address(0xF00D);

    event RegistryChanged(address indexed oldRegistry, address indexed newRegistry);
    event InsuredTokenAdded(IERC20 indexed insuredToken);
    event MaxCoverageBpsSet(IERC20 indexed insuredToken, uint256 maxCoverageBps);
    event InsuredTokenRemoved(IERC20 indexed insuredToken);
    event SettlementParamsSet(DefiInsurance.SettlementParams params);
    event IncidentOpened(
        uint256 indexed incidentId, IERC20 indexed insuredToken, uint64 claimDeadline, uint16 protocolFeeShareBps
    );
    event IncidentCorrected(uint256 indexed incidentId, bytes32 root);
    event TeeSignerSet(address indexed signer, bool authorized);
    event ETHSwept(address indexed to, uint256 amount);
    event Upgraded(address indexed implementation);

    function _deployUninitialized() internal returns (DefiInsurance fresh) {
        // A successful view delegatecall satisfies the proxy's non-empty-data
        // deployment guard without initializing DefiInsurance or emitting logs.
        fresh = DefiInsurance(
            address(
                new ERC1967Proxy(
                    address(new DefiInsurance()), abi.encodeCall(DefiInsurance.getInsuredToken, (IERC20(address(0))))
                )
            )
        );
    }

    function test_initializeEmitsRegistryChanged() public {
        DefiInsurance fresh = _deployUninitialized();

        vm.expectEmit(true, true, false, true, address(fresh));
        emit RegistryChanged(address(0), address(registry));
        fresh.initialize(registry);
    }

    function test_newInsuredTokenEmitsAddedFirst() public {
        DefiInsuranceHarnessToken token = new DefiInsuranceHarnessToken("Event Token", "EVT");

        vm.expectEmit(true, false, false, true, address(defi));
        emit InsuredTokenAdded(IERC20(address(token)));
        defi.editInsuredToken(IERC20(address(token)), 4321, address(feed), address(0xC0DE), hex"12345678");
    }

    function test_existingInsuredTokenUpdateEmitsExactCoverageFirst(uint16 coverage) public {
        vm.assume(coverage > 0 && coverage <= 8_000);

        vm.expectEmit(true, false, false, true, address(defi));
        emit MaxCoverageBpsSet(IERC20(address(insured)), coverage);
        defi.editInsuredToken(IERC20(address(insured)), coverage, address(feed), address(0xC0DE), hex"1234");
    }

    function test_delistEmitsExactInsuredTokenRemoved() public {
        vm.expectEmit(true, false, false, true, address(defi));
        emit InsuredTokenRemoved(IERC20(address(insured)));
        defi.editInsuredToken(IERC20(address(insured)), 0, address(0), address(0), "");
    }

    function test_settlementParamsEmitsExactTuple() public {
        DefiInsurance.SettlementParams memory params =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 11, minHoldingRequired: 22, sampleStepBlocks: 33});

        vm.expectEmit(false, false, false, true, address(defi));
        emit SettlementParamsSet(params);
        defi.setSettlementParams(params);
    }

    function test_adminOpenEmitsExactIncidentTokenAndDeadline() public {
        Registry.IncidentTimingConfig memory timing = registry.incidentTimingConfig();
        uint64 expectedDeadline = uint64(block.timestamp) + timing.phaseWindow;
        uint16 expectedFeeShare = registry.protocolFeeConfig().claimProtocolFeeShareBps;

        vm.expectEmit(true, true, false, true, address(defi));
        emit IncidentOpened(1, IERC20(address(insured)), expectedDeadline, expectedFeeShare);
        defi.openClaimIncident(IERC20(address(insured)), uint64(block.number - 1));
    }

    function test_nonzeroCorrectionEmitsExactReplacementRoot() public {
        uint256 claimId = _openAndJoin(ALICE, 10, 0, 0);
        uint256[] memory none = _emptyAmounts();
        bytes32 original = _leaf(1, claimId, ALICE, none, 0, 0, 10);
        _settle(1, original, none);
        bytes32 replacement = keccak256("replacement event root");

        vm.expectEmit(true, false, false, true, address(defi));
        emit IncidentCorrected(1, replacement);
        defi.adminCorrectSettlement(replacement, none);
    }

    function test_teeSignerEmitsExactSignerAndAuthorization(bool authorized) public {
        address signer = address(0x5151);

        vm.expectEmit(true, false, false, true, address(defi));
        emit TeeSignerSet(signer, authorized);
        defi.setTeeSigner(signer, authorized);
    }

    function test_sweepETHEmitsExactRecipientAndAmount(uint128 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(defi), amount);

        vm.expectEmit(true, false, false, true, address(defi));
        emit ETHSwept(SWEEP_RECIPIENT, amount);
        defi.sweepETH(payable(SWEEP_RECIPIENT));
    }

    function test_compatibleUpgradeEmitsExactImplementation() public {
        DefiInsuranceEventsV2 candidate = new DefiInsuranceEventsV2();

        vm.expectEmit(true, false, false, true, address(defi));
        emit Upgraded(address(candidate));
        defi.upgradeToAndCall(address(candidate), "");
    }
}
