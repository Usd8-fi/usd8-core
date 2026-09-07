// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SepoliaTestToken} from "./SepoliaDependencies.sol";

/// @notice Restores the Sepolia loss fixture without altering claimant holdings.
contract ResetSepoliaFreshLifecycleLoss is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        DefiInsurance insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        IERC4626 lossVault = IERC4626(vm.envAddress("SEPOLIA_LOSS_TOKEN"));
        SepoliaTestToken underlying = SepoliaTestToken(address(lossVault.asset()));

        require(msg.sender == admin, "unexpected broadcaster");
        require(insurance.activeIncidentId() == 0, "incident active");
        require(lossVault.totalAssets() < lossVault.totalSupply(), "loss fixture is not impaired");
        uint256 restoration = lossVault.totalSupply() - lossVault.totalAssets();

        vm.startBroadcast();
        underlying.mint(admin, restoration);
        IERC20(address(underlying)).safeTransfer(address(lossVault), restoration);
        vm.stopBroadcast();

        require(lossVault.totalAssets() == lossVault.totalSupply(), "loss fixture restore failed");
        console2.log("restoration", restoration);
        console2.log("restoredAtBlock", block.number);
    }
}
