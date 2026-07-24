// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeploymentConfig} from "./config/DeploymentConfig.sol";

/// @title 01 — Deploy Timelock
/// @notice First deployment step. Creates the self-administered USD8 governance
///         timelock with one proposer/canceller and open execution after the delay.
/// @dev    Deploy this before {DeployUSD8SystemScript}, then pass the resulting
///         address to step 02 through the TIMELOCK_ADDRESS environment variable.
contract DeployTimelockScript is DeploymentConfig {
    uint256 public constant TIMELOCK_MIN_DELAY = 24 hours;

    function run() external returns (TimelockController timelock) {
        address admin = _governanceAdmin(block.chainid);

        vm.startBroadcast();
        timelock = _deployTimelock(admin);
        vm.stopBroadcast();

        console2.log("=== 01 TimelockController ===");
        console2.log("Address:             ", address(timelock));
        console2.log("minDelay:            ", TIMELOCK_MIN_DELAY);
        console2.log("Proposer/canceller:  ", admin);
        console2.log("Executor:             open (anyone after delay)");
        console2.log("External admin:       none (self-administered)");
        console2.log("");
        console2.log("Set TIMELOCK_ADDRESS to:", address(timelock));
    }

    function _deployTimelock(address proposer) internal returns (TimelockController timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        address[] memory executors = new address[](1);
        executors[0] = address(0);

        timelock = new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, address(0));
    }
}
