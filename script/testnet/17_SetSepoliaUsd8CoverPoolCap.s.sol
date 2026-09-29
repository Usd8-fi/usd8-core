// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../../src/Registry.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";

/// @notice Sets the Sepolia USD8 Cover Pool capacity to 10,000 USD8.
contract SetSepoliaUsd8CoverPoolCapScript is Script {
    uint256 internal constant CHAIN_ID = 11_155_111;
    uint256 internal constant CAP = 10_000 ether;
    uint256 internal constant EXPECTED_NONCE = 901;

    address internal constant ADMIN = 0x724e8951d39E14CEBcB5fB02638f49A637C97838;
    Registry internal constant REGISTRY = Registry(0xB34D92cd05005DF36050370433819597a9BaC693);
    SingleAssetCoverPool internal constant POOL = SingleAssetCoverPool(0x6388c3826902F7D7812E632D0B63ea44D9C1e5Cf);

    function run() external {
        require(block.chainid == CHAIN_ID, "Sepolia only");
        require(msg.sender == ADMIN, "broadcaster/admin mismatch");
        require(REGISTRY.isAdmin(ADMIN), "sender is not Registry admin");
        require(REGISTRY.coverPool(IERC20(POOL.asset())) == address(POOL), "pool not registered");
        require(POOL.depositCap() == 0, "unexpected current cap");
        require(POOL.totalAssets() <= CAP, "current assets exceed cap");
        require(vm.getNonce(ADMIN) == EXPECTED_NONCE, "unexpected nonce");

        vm.startBroadcast();
        POOL.setDepositCap(CAP);
        vm.stopBroadcast();

        require(POOL.depositCap() == CAP, "cap update failed");
        require(POOL.maxDeposit(ADMIN) == CAP - POOL.totalAssets(), "remaining capacity mismatch");
        console2.log("USD8 Cover Pool deposit cap", POOL.depositCap());
    }
}
