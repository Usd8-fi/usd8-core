// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";

/// @notice Schedules a temporary agent signer only for the Sepolia mLOSS E2E and its revocation.
/// @dev Testnet only. The revoke operation is scheduled before any signer grant can execute.
contract ScheduleSepoliaLossE2ESignerScript is Script {
    bytes32 internal constant GRANT_SALT = keccak256("USD8 Sepolia mLOSS E2E signer grant 2026-07-30");
    bytes32 internal constant REVOKE_SALT = keccak256("USD8 Sepolia mLOSS E2E signer revoke 2026-07-30");

    function run() external {
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        TimelockController timelock = TimelockController(payable(vm.envAddress("SEPOLIA_TIMELOCK")));
        DefiInsurance insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        require(msg.sender == admin, "broadcaster/admin mismatch");
        require(timelock.getMinDelay() == 24 hours, "unexpected timelock delay");
        require(!insurance.isTeeSigner(admin), "agent signer already authorized");

        bytes32 grantId = _schedule(timelock, insurance, admin, true, GRANT_SALT);
        bytes32 revokeId = _schedule(timelock, insurance, admin, false, REVOKE_SALT);
        console2.log("=== Sepolia mLOSS E2E signer (TESTNET ONLY) ===");
        console2.logBytes32(grantId);
        console2.logBytes32(revokeId);
    }

    function _schedule(TimelockController timelock, DefiInsurance insurance, address signer, bool allowed, bytes32 salt)
        private
        returns (bytes32 operationId)
    {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        targets[0] = address(insurance);
        payloads[0] = abi.encodeCall(DefiInsurance.setTeeSigner, (signer, allowed));
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        require(!timelock.isOperation(operationId), "operation already exists");
        vm.startBroadcast();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, timelock.getMinDelay());
        vm.stopBroadcast();
    }
}
