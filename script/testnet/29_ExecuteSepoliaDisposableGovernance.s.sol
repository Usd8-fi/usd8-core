// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Registry} from "../../src/Registry.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SepoliaDisposableGovernance} from "./SepoliaDisposableGovernance.sol";

/// @notice Executes one already-ready topology-bound U21/U25 disposable governance action.
contract ExecuteSepoliaDisposableGovernance is Script {
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
        require(
            timelock.hasRole(timelock.EXECUTOR_ROLE(), admin) || timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)),
            "executor missing"
        );

        if (action == SepoliaDisposableGovernance.Action.U21Deregister) {
            require(registry.defiInsurance() == address(insurance), "module not registered");
            require(insurance.activeIncidentId() != 0, "U21 incident missing");
        } else if (action == SepoliaDisposableGovernance.Action.U21Restore) {
            require(registry.defiInsurance() == address(0), "module not cleared");
            require(insurance.activeIncidentId() == 0, "U21 claims unresolved");
            require(registry.betaMode(), "beta already ended");
        } else {
            require(registry.defiInsurance() == address(insurance), "module not registered");
            require(insurance.activeIncidentId() == 0, "U25 incident active");
            require(registry.betaMode(), "beta already ended");
        }

        bytes memory payload = SepoliaDisposableGovernance.payload(action, address(insurance));
        bytes32 salt = SepoliaDisposableGovernance.salt(action, address(registry), address(insurance));
        bytes32 operation = timelock.hashOperation(address(registry), 0, payload, bytes32(0), salt);
        require(timelock.isOperationReady(operation), "operation not ready");

        vm.startBroadcast();
        timelock.execute(address(registry), 0, payload, bytes32(0), salt);
        vm.stopBroadcast();

        require(timelock.isOperationDone(operation), "operation incomplete");
        if (action == SepoliaDisposableGovernance.Action.U21Deregister) {
            require(registry.defiInsurance() == address(0), "module still registered");
            require(!registry.payoutIncidentActive(), "freeze still active");
        } else if (action == SepoliaDisposableGovernance.Action.U21Restore) {
            require(registry.defiInsurance() == address(insurance), "module not restored");
        } else {
            require(!registry.betaMode(), "beta still active");
        }

        console2.log("action", uint256(action));
        console2.logBytes32(operation);
    }
}
