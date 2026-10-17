// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Registry} from "../src/Registry.sol";
import {DeploymentConfig} from "./config/DeploymentConfig.sol";
import {TimelockHandOff} from "./lib/TimelockHandOff.sol";

/// @title 02 — Deploy Timelock and Hand Off Governance
/// @notice Second deployment step. Run it once the system deployed by
///         `01_DeployUSD8System.s.sol` has finished its initial admin setup (extra insured
///         tokens, pools, ...) under interim deployer authority.
///
///         1. Locates the step-01 Registry and pool beacon from the broadcaster's CREATE3
///            addresses and requires the broadcaster to still be the Registry timelock and
///            the beacon owner (so this cannot run twice or against a foreign deployment).
///         2. Deploys the self-administered TimelockController (24h delay; configured admin
///            as sole proposer/canceller; open execution; no external admin) — or reuses it
///            if it is already at its CREATE3 address — and validates it.
///         3. Transfers pool-beacon ownership to the timelock, grants the configured admin,
///            drops the deployer as admin if it is not the configured admin, and finally calls
///            the IRREVERSIBLE Registry.setTimelock.
///
/// @dev    MUST be broadcast by the same deployer as step 01 (it holds interim authority and
///         owns the CREATE3 salts). Run with --slow. After this step every Registry topology
///         change (insured tokens, pools, scored tokens, sUSD8...) needs a 24h timelock proposal.
contract DeployTimelockAndHandOffScript is DeploymentConfig, TimelockHandOff {
    function run() external returns (TimelockController timelock) {
        Addresses memory config = _deploymentConfig(block.chainid);
        _requireCreateX();

        address deployer = msg.sender;
        Registry registry = Registry(_predictCreate3(deployer, LABEL_REGISTRY));
        address beacon = _predictCreate3(deployer, LABEL_POOL_BEACON);
        _validateInterimAuthority(registry, beacon, deployer);

        address predictedTimelock = _predictCreate3(deployer, LABEL_TIMELOCK);

        vm.startBroadcast();
        timelock = predictedTimelock.code.length == 0
            ? _deployTimelock(deployer, config.admin)
            : TimelockController(payable(predictedTimelock));
        _validateTimelock(address(timelock), config.admin);
        _handOffToTimelock(registry, beacon, timelock, deployer, config.admin);
        vm.stopBroadcast();

        console2.log("=== 02 TimelockController ===");
        console2.log("Address:             ", address(timelock));
        console2.log("minDelay:            ", TIMELOCK_MIN_DELAY);
        console2.log("Proposer/canceller:  ", config.admin);
        console2.log("Executor:             open (anyone after delay)");
        console2.log("External admin:       none (self-administered)");
        console2.log("");
        console2.log("=== Governance hand-off ===");
        console2.log("Registry:            ", address(registry));
        console2.log("Registry timelock:   ", registry.timelock());
        console2.log("Pool beacon:         ", beacon);
        console2.log("Beacon owner:        ", address(timelock));
        console2.log("Registry admin:      ", config.admin);
    }

    /// @notice Cross-chain address of a CREATE3-deployed USD8 contract (any label).
    function predictedAddress(address deployer, string calldata label) external view returns (address) {
        return _predictCreate3(deployer, label);
    }
}
