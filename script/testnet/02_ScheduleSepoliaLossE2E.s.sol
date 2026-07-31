// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Registry} from "../../src/Registry.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";

/// @notice Schedules the testnet-only mLOSS listing/shortened lifecycle and its restoration.
/// @dev Both operations remain subject to the canonical 24-hour governance delay.
contract ScheduleSepoliaLossE2EScript is Script {
    uint64 internal constant CANONICAL_PHASE_WINDOW = 3 days;
    uint64 internal constant TESTNET_PHASE_WINDOW = 30 minutes;
    uint64 internal constant MAX_REFERENCE_BLOCK_AGE = 43_200;
    uint256 internal constant COVERAGE_BPS = 8_000;
    bytes32 internal constant SETUP_SALT = keccak256("USD8 Sepolia mLOSS E2E setup 2026-07-30");
    bytes32 internal constant RESTORE_SALT = keccak256("USD8 Sepolia mLOSS E2E restore 2026-07-30");

    function run() external {
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        TimelockController timelock = TimelockController(payable(vm.envAddress("SEPOLIA_TIMELOCK")));
        Registry registry = Registry(vm.envAddress("SEPOLIA_REGISTRY"));
        DefiInsurance insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        address vault = vm.envAddress("SEPOLIA_LOSS_VAULT");
        address usdcOracle = vm.envAddress("SEPOLIA_USDC_USD_ORACLE");
        require(msg.sender == admin, "broadcaster/admin mismatch");
        require(timelock.getMinDelay() == 24 hours, "unexpected timelock delay");
        require(registry.incidentTimingConfig().phaseWindow == CANONICAL_PHASE_WINDOW, "unexpected canonical timing");
        require(!insurance.isInsuredToken(IERC20(vault)), "fixture already insured");

        bytes32 setupId = _scheduleSetup(timelock, registry, insurance, vault, usdcOracle);
        bytes32 restoreId = _scheduleRestore(timelock, registry);

        console2.log("=== Sepolia mLOSS E2E governance (TESTNET ONLY) ===");
        console2.logBytes32(setupId);
        console2.logBytes32(restoreId);
    }

    function _scheduleSetup(
        TimelockController timelock,
        Registry registry,
        DefiInsurance insurance,
        address vault,
        address usdcOracle
    ) private returns (bytes32) {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _setupBatch(registry, insurance, vault, usdcOracle);
        return _schedule(timelock, targets, values, payloads, SETUP_SALT);
    }

    function _scheduleRestore(TimelockController timelock, Registry registry) private returns (bytes32) {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _restoreBatch(registry);
        return _schedule(timelock, targets, values, payloads, RESTORE_SALT);
    }

    function _schedule(
        TimelockController timelock,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        bytes32 salt
    ) private returns (bytes32 operationId) {
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        require(!timelock.isOperation(operationId), "operation already exists");
        vm.startBroadcast();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, timelock.getMinDelay());
        vm.stopBroadcast();
    }

    function _setupBatch(Registry registry, DefiInsurance insurance, address vault, address usdcOracle)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);
        targets[0] = address(insurance);
        payloads[0] = abi.encodeCall(
            DefiInsurance.editInsuredToken,
            (IERC20(vault), COVERAGE_BPS, usdcOracle, vault, abi.encodeCall(IERC4626.convertToAssets, (1e18)))
        );
        targets[1] = address(registry);
        payloads[1] = abi.encodeCall(
            Registry.setIncidentTimingConfig,
            (Registry.IncidentTimingConfig({phaseWindow: TESTNET_PHASE_WINDOW, maxReferenceBlockAge: MAX_REFERENCE_BLOCK_AGE}))
        );
    }

    function _restoreBatch(Registry registry)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](1);
        values = new uint256[](1);
        payloads = new bytes[](1);
        targets[0] = address(registry);
        payloads[0] = abi.encodeCall(
            Registry.setIncidentTimingConfig,
            (Registry.IncidentTimingConfig({phaseWindow: CANONICAL_PHASE_WINDOW, maxReferenceBlockAge: MAX_REFERENCE_BLOCK_AGE}))
        );
    }
}
