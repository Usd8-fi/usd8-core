// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Registry} from "../../src/Registry.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SepoliaDisposableGovernance} from "./SepoliaDisposableGovernance.sol";

/// @notice Schedules one topology-bound U21/U25 action on a fresh disposable Sepolia Registry.
/// @dev Schedule U21Deregister and U21Restore before executing deregistration. Restoration can
///      then execute only after every emergency claim recovery has made activeIncidentId zero.
contract ScheduleSepoliaDisposableGovernance is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        Registry registry = Registry(vm.envAddress("USD8_DISPOSABLE_REGISTRY"));
        DefiInsurance insurance = DefiInsurance(vm.envAddress("USD8_DISPOSABLE_DEFI_INSURANCE"));
        TimelockController timelock = TimelockController(payable(vm.envAddress("USD8_DISPOSABLE_TIMELOCK")));
        SepoliaDisposableGovernance.Action action =
            SepoliaDisposableGovernance.Action(vm.envUint("USD8_DISPOSABLE_ACTION"));

        SepoliaDisposableGovernance.requireDisposable(address(registry), address(insurance));
        require(msg.sender == admin, "unexpected broadcaster");
        require(address(registry).code.length != 0, "missing registry");
        require(address(insurance).code.length != 0, "missing insurance");
        require(address(timelock).code.length != 0, "missing timelock");
        require(registry.timelock() == address(timelock), "timelock mismatch");
        require(registry.defiInsurance() == address(insurance), "module not registered");
        require(registry.betaMode(), "beta already ended");
        require(timelock.getMinDelay() == 30 minutes, "unexpected delay");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), admin), "proposer missing");

        uint256 activeIncidentId = insurance.activeIncidentId();
        if (
            action == SepoliaDisposableGovernance.Action.U21Deregister
                || action == SepoliaDisposableGovernance.Action.U21Restore
        ) {
            require(activeIncidentId != 0, "U21 incident missing");
        } else {
            require(activeIncidentId == 0, "U25 incident active");
        }

        bytes memory payload = SepoliaDisposableGovernance.payload(action, address(insurance));
        bytes32 salt = SepoliaDisposableGovernance.salt(action, address(registry), address(insurance));
        bytes32 operation = timelock.hashOperation(address(registry), 0, payload, bytes32(0), salt);
        require(!timelock.isOperation(operation), "operation exists");

        vm.startBroadcast();
        timelock.schedule(address(registry), 0, payload, bytes32(0), salt, timelock.getMinDelay());
        vm.stopBroadcast();

        require(timelock.isOperationPending(operation), "operation not pending");
        console2.log("action", uint256(action));
        console2.log("registry", address(registry));
        console2.log("insurance", address(insurance));
        console2.logBytes32(operation);
        console2.log("readyAt", timelock.getTimestamp(operation));
    }
}
