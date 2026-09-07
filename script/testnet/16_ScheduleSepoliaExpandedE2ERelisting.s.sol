// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {DefiInsurance} from "../../src/DefiInsurance.sol";

/// @notice Schedule the one-time msLOSS relisting used by the expanded Sepolia E2E.
contract ScheduleSepoliaExpandedE2ERelisting is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    bytes32 internal constant SALT = keccak256("USD8 Sepolia expanded E2E mLOSS relist 2026-08-30");

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        TimelockController timelock = TimelockController(payable(vm.envAddress("SEPOLIA_TIMELOCK")));
        DefiInsurance insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        IERC20 lossToken = IERC20(vm.envAddress("SEPOLIA_LOSS_TOKEN"));
        address usdcOracle = vm.envAddress("SEPOLIA_USDC_USD_ORACLE");

        require(msg.sender == admin, "unexpected broadcaster");
        require(insurance.activeIncidentId() == 0, "incident active");
        require(!insurance.isInsuredToken(lossToken), "loss token already listed");
        require(timelock.getMinDelay() == 30 minutes, "unexpected delay");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), admin), "proposer missing");

        bytes memory payload = abi.encodeCall(
            DefiInsurance.editInsuredToken,
            (lossToken, 8000, usdcOracle, address(lossToken), abi.encodeCall(IERC4626.convertToAssets, (1e18)))
        );
        bytes32 operation = timelock.hashOperation(address(insurance), 0, payload, bytes32(0), SALT);
        require(!timelock.isOperation(operation), "relisting operation exists");

        vm.startBroadcast();
        timelock.schedule(address(insurance), 0, payload, bytes32(0), SALT, timelock.getMinDelay());
        vm.stopBroadcast();

        require(timelock.isOperationPending(operation), "relisting not pending");
        console2.logBytes32(operation);
        console2.log("readyAt", timelock.getTimestamp(operation));
    }
}
