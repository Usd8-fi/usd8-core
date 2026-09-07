// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SepoliaAllRoutesRelisting} from "./SepoliaAllRoutesRelisting.sol";

contract ExecuteSepoliaAllRoutesRelisting is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        TimelockController timelock = TimelockController(payable(vm.envAddress("SEPOLIA_TIMELOCK")));
        DefiInsurance insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        IERC20 lossToken = IERC20(vm.envAddress("SEPOLIA_LOSS_TOKEN"));
        address usdcOracle = vm.envAddress("SEPOLIA_USDC_USD_ORACLE");
        string memory lane = vm.envString("USD8_RELIST_LANE");

        require(msg.sender == admin, "unexpected broadcaster");
        require(insurance.activeIncidentId() == 0, "incident active");
        require(!insurance.isInsuredToken(lossToken), "loss token already listed");
        require(
            timelock.hasRole(timelock.EXECUTOR_ROLE(), admin) || timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)),
            "executor missing"
        );

        bytes memory payload = SepoliaAllRoutesRelisting.payload(lossToken, usdcOracle);
        bytes32 salt = SepoliaAllRoutesRelisting.salt(lane);
        bytes32 operation = timelock.hashOperation(address(insurance), 0, payload, bytes32(0), salt);
        require(timelock.isOperationReady(operation), "relisting not ready");

        vm.startBroadcast();
        timelock.execute(address(insurance), 0, payload, bytes32(0), salt);
        vm.stopBroadcast();

        DefiInsurance.InsuredToken memory config = insurance.getInsuredToken(lossToken);
        bytes memory recipe = abi.encodeCall(IERC4626.convertToAssets, (1e18));
        require(insurance.isInsuredToken(lossToken), "loss token not listed");
        require(config.maxCoverageBps == 8000, "coverage mismatch");
        require(config.underlyingPriceOracle == usdcOracle, "oracle mismatch");
        require(config.underlyingConversionAddress == address(lossToken), "conversion address mismatch");
        require(keccak256(config.underlyingConversionCallData) == keccak256(recipe), "conversion calldata mismatch");
        require(timelock.isOperationDone(operation), "relisting operation incomplete");
        console2.log("lane", lane);
        console2.logBytes32(operation);
    }
}
