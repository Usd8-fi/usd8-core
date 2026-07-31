// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Cancels only the retired canonical-system mLOSS E2E operations.
/// @dev Testnet cleanup; this intentionally cannot cancel arbitrary operation IDs.
contract CancelRetiredSepoliaLossE2EScript is Script {
    bytes32 internal constant SETUP = 0x7d2e591ff212e35486e2a1e654b3850a96431ada0fa94d3d42e24e9f0f1d9c6c;
    bytes32 internal constant RESTORE = 0x68bd81e687ed84737e37cda8430b744281e55a9e0ba0938e533b02177fc46ed4;
    bytes32 internal constant GRANT = 0x158c1a2eff2924b6d452b2414b4f5579f854fa5a4d132afb47feefe8ffa3e633;
    bytes32 internal constant REVOKE = 0xe22c3e8b0459da36a2867782d07dbf963cc7b14f11f404e68b7ecccda270cda9;

    function run() external {
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        TimelockController timelock = TimelockController(payable(vm.envAddress("SEPOLIA_TIMELOCK")));
        require(msg.sender == admin, "broadcaster/admin mismatch");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), admin), "missing canceller role");
        require(
            timelock.isOperationPending(SETUP) && timelock.isOperationPending(RESTORE)
                && timelock.isOperationPending(GRANT) && timelock.isOperationPending(REVOKE),
            "retired operation not pending"
        );
        vm.startBroadcast();
        timelock.cancel(SETUP);
        timelock.cancel(RESTORE);
        timelock.cancel(GRANT);
        timelock.cancel(REVOKE);
        vm.stopBroadcast();
        console2.log("Cancelled exactly four retired Sepolia mLOSS E2E operations");
    }
}
