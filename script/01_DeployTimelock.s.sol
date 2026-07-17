// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title 01 — Deploy Timelock
/// @notice First deployment step. Creates the self-administered USD8 governance
///         timelock with one proposer/canceller and open execution after the delay.
/// @dev    Deploy this before {DeployUSD8SystemScript}, then pass the resulting
///         address to step 02 through the TIMELOCK_ADDRESS environment variable.
contract DeployTimelockScript is Script {
    error WrongChainId(uint256 actual, uint256 expected);

    uint256 public constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    uint256 public constant TIMELOCK_MIN_DELAY = 24 hours;

    /// @notice Initial proposer/canceller. Replace with a Safe before deployment
    ///         when multisig governance is ready.
    address public constant DEFAULT_PROPOSER = 0xB2E999D531D45a9115dA7706adFc651999f3c1F1;

    function run() external returns (TimelockController timelock) {
        if (block.chainid != ETHEREUM_MAINNET_CHAIN_ID) {
            revert WrongChainId(block.chainid, ETHEREUM_MAINNET_CHAIN_ID);
        }

        vm.startBroadcast();
        timelock = _deployTimelock(DEFAULT_PROPOSER);
        vm.stopBroadcast();

        console2.log("=== 01 TimelockController ===");
        console2.log("Address:             ", address(timelock));
        console2.log("minDelay:            ", TIMELOCK_MIN_DELAY);
        console2.log("Proposer/canceller:  ", DEFAULT_PROPOSER);
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
