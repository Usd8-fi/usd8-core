// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";

/// @notice Executes only the ready fast-system mLOSS listing operation; never the signer revoke.
contract ExecuteSepoliaFastE2EFixtureListingScript is Script {
    bytes32 internal constant LIST_SALT = keccak256("USD8 fast Sepolia mLOSS fixture listing 2026-07-30");

    function run() external {
        TimelockController timelock = TimelockController(payable(vm.envAddress("SEPOLIA_TIMELOCK")));
        DefiInsurance insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        address vault = vm.envAddress("SEPOLIA_LOSS_VAULT");
        address oracle = vm.envAddress("SEPOLIA_USDC_USD_ORACLE");
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        targets[0] = address(insurance);
        payloads[0] = abi.encodeCall(
            DefiInsurance.editInsuredToken,
            (IERC20(vault), 8000, oracle, vault, abi.encodeCall(IERC4626.convertToAssets, (1e18)))
        );
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), LIST_SALT);
        require(timelock.isOperationReady(id), "listing not ready");
        require(!insurance.isInsuredToken(IERC20(vault)), "fixture already listed");
        vm.startBroadcast();
        timelock.executeBatch(targets, values, payloads, bytes32(0), LIST_SALT);
        vm.stopBroadcast();
        require(insurance.isInsuredToken(IERC20(vault)), "listing failed");
        console2.log("Executed fast E2E fixture listing");
        console2.logBytes32(id);
    }
}
