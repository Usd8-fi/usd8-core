// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SepoliaLossToken, SepoliaLossVault} from "../script/testnet/SepoliaLossFixture.sol";

contract SepoliaLossFixtureTest is Test {
    address internal admin = makeAddr("sepolia fixture admin");
    address internal recipient = makeAddr("loss recipient");
    address internal depositor = makeAddr("depositor");

    SepoliaLossToken internal token;
    SepoliaLossVault internal vault;

    function setUp() public {
        token = new SepoliaLossToken(admin);
        vault = new SepoliaLossVault(IERC20(address(token)), admin);

        vm.startPrank(admin);
        token.mint(depositor, 100e18);
        vm.stopPrank();

        vm.startPrank(depositor);
        token.approve(address(vault), 100e18);
        vault.deposit(100e18, depositor);
        vm.stopPrank();
    }

    function test_AdminCanCreateSustainedDirectRedemptionLoss() public {
        assertEq(vault.convertToAssets(1e18), 1e18);

        vm.prank(admin);
        vault.realizeLoss(recipient, 30e18);

        assertEq(token.balanceOf(recipient), 30e18);
        assertLt(vault.convertToAssets(1e18), 80e16);
        assertGt(vault.convertToAssets(1e18), 69e16);
    }

    function test_NonAdminCannotMintOrRealizeLoss() public {
        vm.expectRevert(SepoliaLossToken.Unauthorized.selector);
        token.mint(address(this), 1);

        vm.expectRevert(SepoliaLossVault.Unauthorized.selector);
        vault.realizeLoss(address(this), 1);
    }

    function test_RejectsZeroAdminAndZeroLossRecipient() public {
        vm.expectRevert(SepoliaLossToken.ZeroAddress.selector);
        new SepoliaLossToken(address(0));

        vm.expectRevert(SepoliaLossVault.ZeroAddress.selector);
        new SepoliaLossVault(IERC20(address(token)), address(0));

        vm.prank(admin);
        vm.expectRevert(SepoliaLossVault.ZeroAddress.selector);
        vault.realizeLoss(address(0), 1);
    }
}
