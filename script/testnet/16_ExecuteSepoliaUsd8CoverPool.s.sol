// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";

contract ExecuteSepoliaUsd8CoverPoolScript is Script {
    address internal constant DEPLOYMENT_ADMIN = 0x724e8951d39E14CEBcB5fB02638f49A637C97838;
    address internal constant TIMELOCK = 0x158494e7b95c0e5F87e8dB4Ad1Be5c32de99F645;
    address internal constant REGISTRY = 0xB34D92cd05005DF36050370433819597a9BaC693;
    address internal constant DEFI_INSURANCE = 0x4E346CcD0a46D51ebaE6810d653791982968d502;
    address internal constant USD8 = 0xa5B32853235619B5e9AF364A40c0c6386Dbd6055;
    address internal constant USD8_PRICE_ORACLE = 0xf4AeDC595912cE5951c3a0AfDD8a61ebb07a8634;
    address internal constant USD8_COVER_POOL = 0x6388c3826902F7D7812E632D0B63ea44D9C1e5Cf;
    bytes32 internal constant SALT = keccak256("USD8 Sepolia USD8 cover pool 2026-09-14");
    bytes32 internal constant OPERATION_ID = 0xdf37838ff64586598500d32a956c9ccdb6b78309e55b5adf2eb7ae3c337d4cbf;

    function run() external {
        require(block.chainid == 11155111, "wrong chain");
        require(msg.sender == DEPLOYMENT_ADMIN, "wrong sender");

        TimelockController timelock = TimelockController(payable(TIMELOCK));
        Registry registry = Registry(REGISTRY);
        bytes memory data = abi.encodeCall(Registry.addPool, (USD8_COVER_POOL, USD8_PRICE_ORACLE));

        require(timelock.hashOperation(REGISTRY, 0, data, bytes32(0), SALT) == OPERATION_ID, "operation mismatch");
        require(timelock.isOperationReady(OPERATION_ID), "operation not ready");
        require(!timelock.isOperationDone(OPERATION_ID), "operation already done");
        require(DefiInsurance(DEFI_INSURANCE).activeIncidentId() == 0, "incident active");
        require(registry.coverPool(IERC20(USD8)) == address(0), "USD8 pool already registered");

        (, address[] memory beforePools) = registry.coverPools();
        require(beforePools.length == 1, "unexpected pool count");

        vm.startBroadcast();
        timelock.execute(REGISTRY, 0, data, bytes32(0), SALT);
        vm.stopBroadcast();

        require(timelock.isOperationDone(OPERATION_ID), "operation incomplete");
        require(registry.coverPool(IERC20(USD8)) == USD8_COVER_POOL, "asset mapping mismatch");
        (IERC20[] memory afterAssets, address[] memory afterPools) = registry.coverPools();
        require(afterPools.length == 2, "pool count mismatch");
        require(address(afterAssets[1]) == USD8 && afterPools[1] == USD8_COVER_POOL, "pool order mismatch");

        console2.log("Executed USD8 Cover Pool registration");
        console2.logBytes32(OPERATION_ID);
        console2.log("USD8 Cover Pool", USD8_COVER_POOL);
    }
}
