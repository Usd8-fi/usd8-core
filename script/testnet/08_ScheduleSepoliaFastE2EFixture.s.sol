// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SepoliaLossVault} from "./SepoliaLossFixture.sol";

/// @notice Schedules fixture listing and its mandatory post-E2E signer revoke on the fast test system.
contract ScheduleSepoliaFastE2EFixtureScript is Script {
    bytes32 internal constant LIST_SALT = keccak256("USD8 fast Sepolia mLOSS fixture listing 2026-07-30");
    bytes32 internal constant REVOKE_SALT = keccak256("USD8 fast Sepolia mLOSS signer revoke 2026-07-30");

    function run() external {
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        TimelockController timelock = TimelockController(payable(vm.envAddress("SEPOLIA_TIMELOCK")));
        DefiInsurance insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        address vault = vm.envAddress("SEPOLIA_LOSS_VAULT");
        address usdcOracle = vm.envAddress("SEPOLIA_USDC_USD_ORACLE");
        require(msg.sender == admin, "broadcaster/admin mismatch");
        require(timelock.getMinDelay() == 30 minutes, "wrong fast timelock delay");
        require(!insurance.isInsuredToken(IERC20(vault)), "fixture already listed");
        require(insurance.isTeeSigner(admin), "agent signer missing");

        bytes32 listId = _scheduleListing(timelock, insurance, vault, usdcOracle);
        bytes32 revokeId = _scheduleRevoke(timelock, insurance, admin);
        console2.log("fast fixture listing operation");
        console2.logBytes32(listId);
        console2.log("fast signer revoke operation");
        console2.logBytes32(revokeId);
    }

    function _scheduleListing(TimelockController t, DefiInsurance i, address vault, address oracle)
        private
        returns (bytes32 id)
    {
        address[] memory targets = new address[](1); uint256[] memory values = new uint256[](1); bytes[] memory payloads = new bytes[](1);
        targets[0] = address(i);
        payloads[0] = abi.encodeCall(DefiInsurance.editInsuredToken, (IERC20(vault), 8000, oracle, vault, abi.encodeCall(IERC4626.convertToAssets, (1e18))));
        id = t.hashOperationBatch(targets, values, payloads, bytes32(0), LIST_SALT);
        require(!t.isOperation(id), "listing exists");
        vm.startBroadcast(); t.scheduleBatch(targets, values, payloads, bytes32(0), LIST_SALT, t.getMinDelay()); vm.stopBroadcast();
    }

    function _scheduleRevoke(TimelockController t, DefiInsurance i, address admin) private returns (bytes32 id) {
        address[] memory targets = new address[](1); uint256[] memory values = new uint256[](1); bytes[] memory payloads = new bytes[](1);
        targets[0] = address(i); payloads[0] = abi.encodeCall(DefiInsurance.setTeeSigner, (admin, false));
        id = t.hashOperationBatch(targets, values, payloads, bytes32(0), REVOKE_SALT);
        require(!t.isOperation(id), "revoke exists");
        vm.startBroadcast(); t.scheduleBatch(targets, values, payloads, bytes32(0), REVOKE_SALT, t.getMinDelay()); vm.stopBroadcast();
    }
}
