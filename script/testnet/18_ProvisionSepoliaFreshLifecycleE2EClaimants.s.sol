// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {Treasury} from "../../src/Treasury.sol";
import {SepoliaTestToken} from "./SepoliaDependencies.sol";

/// @notice Restores and provisions ten fresh disposable claimants for one complete UI lifecycle E2E.
/// @dev Claim, settlement and finalization writes remain browser-driven. This testnet-only setup
///      restores the mutable loss fixture, creates mature-score holdings, insured shares, and gas.
contract ProvisionSepoliaFreshLifecycleE2EClaimants is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 internal constant CLAIMANT_COUNT = 10;
    uint256 internal constant NATIVE_TARGET = 0.01 ether;

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");

        address admin = vm.envAddress("SEPOLIA_ADMIN");
        Registry registry = Registry(vm.envAddress("SEPOLIA_REGISTRY"));
        DefiInsurance insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        Treasury treasury = Treasury(payable(vm.envAddress("SEPOLIA_TREASURY")));
        IERC20 usd8 = IERC20(vm.envAddress("SEPOLIA_USD8"));
        IERC20 usdc = IERC20(vm.envAddress("SEPOLIA_USDC"));
        IERC4626 lossVault = IERC4626(vm.envAddress("SEPOLIA_LOSS_TOKEN"));
        SepoliaTestToken underlying = SepoliaTestToken(address(lossVault.asset()));
        address[] memory claimants = _claimants();

        require(msg.sender == admin, "unexpected broadcaster");
        require(registry.isAdmin(admin), "admin mismatch");
        require(registry.defiInsurance() == address(insurance), "insurance mismatch");
        require(insurance.activeIncidentId() == 0, "incident active");
        require(insurance.isInsuredToken(IERC20(address(lossVault))), "loss token not listed");
        require(address(treasury) == registry.treasury(), "treasury mismatch");
        require(lossVault.totalAssets() < lossVault.totalSupply(), "loss fixture is not impaired");

        uint256 restoration = lossVault.totalSupply() - lossVault.totalAssets();
        uint256 totalUsd8;
        uint256 totalLossAssets;
        uint256 totalNative;
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            require(usd8.balanceOf(claimants[i]) == 0, "claimant already has USD8");
            require(lossVault.balanceOf(claimants[i]) == 0, "claimant already has loss shares");
            totalUsd8 += _usd8Amount(i);
            totalLossAssets += _lossAmount(i);
            if (claimants[i].balance < NATIVE_TARGET) totalNative += NATIVE_TARGET - claimants[i].balance;
        }
        require(usdc.balanceOf(admin) >= totalUsd8 / 1e12, "insufficient admin USDC");
        require(admin.balance >= totalNative, "insufficient admin ETH");

        vm.startBroadcast();

        underlying.mint(admin, restoration + totalLossAssets);
        IERC20(address(underlying)).safeTransfer(address(lossVault), restoration);
        require(lossVault.totalAssets() == lossVault.totalSupply(), "loss fixture restore failed");

        usdc.forceApprove(address(treasury), totalUsd8 / 1e12);
        treasury.mintUSD8(totalUsd8 / 1e12);
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            usd8.safeTransfer(claimants[i], _usd8Amount(i));
        }

        IERC20(address(underlying)).forceApprove(address(lossVault), totalLossAssets);
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            require(lossVault.previewDeposit(_lossAmount(i)) == _lossAmount(i), "non-unit loss ratio");
            lossVault.deposit(_lossAmount(i), claimants[i]);
        }
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            if (claimants[i].balance < NATIVE_TARGET) {
                (bool sent,) = payable(claimants[i]).call{value: NATIVE_TARGET - claimants[i].balance}("");
                require(sent, "native funding failed");
            }
        }

        vm.stopBroadcast();

        require(lossVault.totalAssets() == lossVault.totalSupply(), "post-provision ratio mismatch");
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            require(claimants[i].balance == NATIVE_TARGET, "native funding mismatch");
            require(usd8.balanceOf(claimants[i]) == _usd8Amount(i), "USD8 mismatch");
            require(lossVault.balanceOf(claimants[i]) == _lossAmount(i), "loss-share mismatch");
            console2.log("claimant", i + 1, claimants[i]);
        }
        console2.log("scoreMaturityAnchorBlock", block.number);
    }

    function _usd8Amount(uint256 index) internal pure returns (uint256) {
        uint256[10] memory amounts = [uint256(100), 150, 220, 320, 450, 650, 900, 1_250, 1_800, 2_600];
        return amounts[index] * 1e18;
    }

    function _lossAmount(uint256 index) internal pure returns (uint256) {
        uint256[10] memory amounts =
            [uint256(25_000), 40_000, 60_000, 90_000, 130_000, 180_000, 250_000, 350_000, 500_000, 700_000];
        return amounts[index] * 1e18;
    }

    function _claimants() internal pure returns (address[] memory claimants) {
        claimants = new address[](CLAIMANT_COUNT);
        claimants[0] = 0xeb5eAd9c9b0E8BFa3f8959D602A32FC0c548c267;
        claimants[1] = 0x9c5d50400df8Bd397E7D7aed23bc55B5c4d0eb66;
        claimants[2] = 0x247fdb90237758B931db2e7f32A801117aCB8bA2;
        claimants[3] = 0x58cE869611C6BDe45AB627a98EaD449b89D09CA4;
        claimants[4] = 0x5F30FA9a5b2161DaA10519B7Ac16D4086a0c83d1;
        claimants[5] = 0x454265761D465CaCdEa56fE63446c6cE1486c568;
        claimants[6] = 0x8Dde6E408B844f7fB533c7a50c594ac3AAd36a84;
        claimants[7] = 0x096b098c0fC8F4b7b300467E3EFAC5efa8bd3166;
        claimants[8] = 0xFE63ab790b6D76BB7B3f4827F4F98EE44e436ccE;
        claimants[9] = 0x7f47Dbd58566B66edAc22bB4fB63DA650dDcfd7B;
    }
}
