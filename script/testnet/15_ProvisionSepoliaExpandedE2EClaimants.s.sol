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

/// @notice One-time real-Sepolia provisioning for the expanded UI E2E.
/// @dev Claim actions remain browser-driven; this script only gives disposable accounts gas,
///      distinct mature-score balances, insured-token shares, and claimant 11's post-open mint input.
contract ProvisionSepoliaExpandedE2EClaimants is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 internal constant CLAIMANT_COUNT = 11;
    uint256 internal constant NATIVE_FUNDING = 0.01 ether;
    uint256 internal constant CLAIMANT_11_USDC = 10e6;

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
        require(lossVault.totalAssets() == lossVault.totalSupply(), "loss fixture not restored");
        require(address(treasury) == registry.treasury(), "treasury mismatch");

        uint256 totalUsd8;
        uint256 totalLossAssets;
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            require(claimants[i].balance == 0, "claimant already funded");
            require(usd8.balanceOf(claimants[i]) == 0, "claimant already has USD8");
            require(usdc.balanceOf(claimants[i]) == 0, "claimant already has USDC");
            require(lossVault.balanceOf(claimants[i]) == 0, "claimant already has loss shares");
            if (i < 10) totalUsd8 += _usd8Amount(i);
            totalLossAssets += _lossAmount(i);
            require(lossVault.previewDeposit(_lossAmount(i)) == _lossAmount(i), "non-unit loss ratio");
        }
        require(usdc.balanceOf(admin) >= totalUsd8 / 1e12 + CLAIMANT_11_USDC, "insufficient admin USDC");
        require(admin.balance >= CLAIMANT_COUNT * NATIVE_FUNDING, "insufficient admin ETH");

        vm.startBroadcast();

        usdc.forceApprove(address(treasury), totalUsd8 / 1e12);
        treasury.mintUSD8(totalUsd8 / 1e12);
        for (uint256 i = 0; i < 10; i++) {
            usd8.safeTransfer(claimants[i], _usd8Amount(i));
        }
        usdc.safeTransfer(claimants[10], CLAIMANT_11_USDC);

        underlying.mint(admin, totalLossAssets);
        IERC20(address(underlying)).forceApprove(address(lossVault), totalLossAssets);
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            lossVault.deposit(_lossAmount(i), claimants[i]);
        }
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            (bool sent,) = payable(claimants[i]).call{value: NATIVE_FUNDING}("");
            require(sent, "native funding failed");
        }

        vm.stopBroadcast();

        require(usd8.balanceOf(admin) == 0, "unexpected admin USD8 remainder");
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            require(claimants[i].balance == NATIVE_FUNDING, "native funding mismatch");
            require(usd8.balanceOf(claimants[i]) == (i < 10 ? _usd8Amount(i) : 0), "USD8 mismatch");
            require(usdc.balanceOf(claimants[i]) == (i == 10 ? CLAIMANT_11_USDC : 0), "USDC mismatch");
            require(lossVault.balanceOf(claimants[i]) == _lossAmount(i), "loss-share mismatch");
            console2.log("claimant", i + 1, claimants[i]);
        }
        console2.log("scoreMaturityAnchorBlock", block.number);
    }

    function _usd8Amount(uint256 index) internal pure returns (uint256) {
        return (index + 1) * 100e18;
    }

    function _lossAmount(uint256 index) internal pure returns (uint256) {
        return (index + 1) * 100e18;
    }

    function _claimants() internal pure returns (address[] memory claimants) {
        claimants = new address[](CLAIMANT_COUNT);
        claimants[0] = 0x8Fa49d582B9bB8e4613D4e05c642D3eB2C539Dcd;
        claimants[1] = 0xaf90430e677A926B6814095A5685cF8bF425B5e3;
        claimants[2] = 0x890b76bF56B65568e724bD8317d57F166C03f898;
        claimants[3] = 0x1d5A8126662308e96168F64ABaAf070Bb99aBD5a;
        claimants[4] = 0x49dC35C96966028064D789Eb57FAa7213f1aB5C2;
        claimants[5] = 0xcEACe0Be8f2cC8aC04330bc8F89f9cf5Ef53b744;
        claimants[6] = 0x3Ed161Ceef7900B7130B9ae97F3f400A71B741C6;
        claimants[7] = 0xF92E102e0f5FB4DbDDCe982B8bb2808b8a136f9c;
        claimants[8] = 0x77D25F099cac66c6eEd6D6de9bEcb4515Ae9Bb3d;
        claimants[9] = 0xeAD1462372ff1dC7A184dAA8a7c4D9542582f10e;
        claimants[10] = 0x398a5E98C88e64774B8Ff80A02C0FBF5a9E87c1e;
    }
}
