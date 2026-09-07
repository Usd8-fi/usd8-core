// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SepoliaTestToken} from "./SepoliaDependencies.sol";

/// @notice Restores only the synthetic Sepolia loss vault to a healthy 1:1 ratio.
/// @dev Testnet cleanup for the completed twenty-claim lifecycle; it provisions no actors.
contract RestoreSepoliaTwentyClaimLossFixture is Script {
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
        require(underlying.admin() == admin, "underlying admin mismatch");

        uint256 assetsBefore = lossVault.totalAssets();
        uint256 sharesBefore = lossVault.totalSupply();
        require(assetsBefore < sharesBefore, "fixture is not impaired");
        uint256 restoration = sharesBefore - assetsBefore;
        uint256 underlyingSupplyBefore = underlying.totalSupply();
        uint256 adminUnderlyingBefore = underlying.balanceOf(admin);
        uint256 nextClaimIdBefore = insurance.nextClaimId();
        uint256 escrowBefore = insurance.escrowedInsuredTokens(IERC20(address(lossVault)));

        vm.startBroadcast();
        underlying.mint(admin, restoration);
        IERC20(address(underlying)).safeTransfer(address(lossVault), restoration);
        vm.stopBroadcast();

        require(lossVault.totalAssets() == sharesBefore, "post total assets mismatch");
        require(lossVault.totalSupply() == sharesBefore, "vault supply changed");
        require(underlying.totalSupply() == underlyingSupplyBefore + restoration, "underlying supply mismatch");
        require(underlying.balanceOf(admin) == adminUnderlyingBefore, "admin underlying residue");
        require(insurance.activeIncidentId() == 0, "incident reactivated");
        require(insurance.nextClaimId() == nextClaimIdBefore, "next claim changed");
        require(insurance.escrowedInsuredTokens(IERC20(address(lossVault))) == escrowBefore, "escrow changed");

        console2.log("restoration", restoration);
        console2.log("healthyBaselineAnchorBlock", block.number);
    }
}
