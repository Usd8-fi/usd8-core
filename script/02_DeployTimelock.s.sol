// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeploymentConfig} from "./config/DeploymentConfig.sol";
import {TimelockHandOff} from "./lib/TimelockHandOff.sol";

/// @title 02 — Deploy Timelock
/// @notice Second deployment step. Deploys the self-administered governance TimelockController
///         at its CREATE3 address (24h delay; configured admin as sole proposer/canceller; open
///         execution; no external admin) and validates that exact layout. If the timelock is
///         already at its CREATE3 address it is only validated; nothing is broadcast.
///
///         This step does NOT hand off governance: the Registry timelock, Registry admins and
///         pool-beacon owner stay with the deployer, so timelock-only settings can still be made
///         immediately. Moving governance to this timelock is a separate, later step.
///
/// @dev    MUST be broadcast by the same deployer as step 01 (it owns the CREATE3 salts), so the
///         timelock lands at the same address on every chain. Run with --slow.
contract DeployTimelockScript is DeploymentConfig, TimelockHandOff {
    function run() external returns (TimelockController timelock) {
        Addresses memory config = _deploymentConfig(block.chainid);
        _requireCreateX();

        address deployer = msg.sender;
        address predicted = _predictCreate3(deployer, LABEL_TIMELOCK);

        if (predicted.code.length == 0) {
            vm.startBroadcast();
            timelock = _deployTimelock(deployer, config.admin);
            vm.stopBroadcast();
        } else {
            timelock = TimelockController(payable(predicted));
        }
        if (address(timelock) != predicted) revert HandOffIncomplete();
        _validateTimelock(address(timelock), config.admin);

        console2.log("=== 02 TimelockController ===");
        console2.log("Address:             ", address(timelock));
        console2.log("minDelay:            ", TIMELOCK_MIN_DELAY);
        console2.log("Proposer/canceller:  ", config.admin);
        console2.log("Executor:             open (anyone after delay)");
        console2.log("External admin:       none (self-administered)");
        console2.log("Governance hand-off:  not performed (deployer keeps interim authority)");
    }

    /// @notice Cross-chain address of a CREATE3-deployed USD8 contract (any label).
    function predictedAddress(address deployer, string calldata label) external view returns (address) {
        return _predictCreate3(deployer, label);
    }
}
