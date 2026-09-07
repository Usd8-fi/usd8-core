// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SepoliaLossVault} from "./SepoliaLossFixture.sol";
import {SepoliaAllRoutesLoss} from "./SepoliaAllRoutesLoss.sol";

contract RealizeSepoliaAllRoutesLoss is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        DefiInsurance insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        SepoliaLossVault lossVault = SepoliaLossVault(vm.envAddress("SEPOLIA_LOSS_TOKEN"));
        string memory lane = vm.envString("USD8_LOSS_LANE");
        uint256 lossBps = vm.envOr("USD8_LOSS_BPS", uint256(2_200));
        IERC20 underlying = IERC20(lossVault.asset());

        require(msg.sender == admin, "unexpected broadcaster");
        require(insurance.activeIncidentId() == 0, "incident active");
        require(insurance.isInsuredToken(IERC20(address(lossVault))), "loss token not listed");
        require(lossVault.admin() == admin, "loss-vault admin mismatch");

        uint256 assetsBefore = lossVault.totalAssets();
        uint256 supplyBefore = lossVault.totalSupply();
        uint256 adminUnderlyingBefore = underlying.balanceOf(admin);
        uint256 nextClaimBefore = insurance.nextClaimId();
        uint256 escrowBefore = insurance.escrowedInsuredTokens(IERC20(address(lossVault)));
        require(assetsBefore != 0 && assetsBefore == supplyBefore, "fixture not healthy");
        uint256 loss = SepoliaAllRoutesLoss.amount(assetsBefore, lossBps);
        require(loss != 0, "zero loss");

        vm.startBroadcast();
        lossVault.realizeLoss(admin, loss);
        vm.stopBroadcast();

        require(lossVault.totalAssets() == assetsBefore - loss, "asset loss mismatch");
        require(lossVault.totalSupply() == supplyBefore, "share supply changed");
        require(underlying.balanceOf(admin) == adminUnderlyingBefore + loss, "recipient delta mismatch");
        require(insurance.activeIncidentId() == 0, "incident opened during fixture write");
        require(insurance.nextClaimId() == nextClaimBefore, "claim id changed");
        require(insurance.escrowedInsuredTokens(IERC20(address(lossVault))) == escrowBefore, "escrow changed");

        console2.log("lane", lane);
        console2.log("lossBps", lossBps);
        console2.log("lossAssets", loss);
        console2.log("preAssets", assetsBefore);
        console2.log("postAssets", lossVault.totalAssets());
        console2.log("supply", supplyBefore);
        console2.log("lossAnchorBlock", block.number);
    }
}
