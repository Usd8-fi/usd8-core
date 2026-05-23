// SPDX-License-Identifier: MIT
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {USD8} from "../src/USD8.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract USD8Test is Test {
    USD8 usd8;
    address treasury = address(0xA11CE);
    address alice = address(0xBEEF);
    address newTreasury = address(0xB0B);

    function setUp() public {
        usd8 = new USD8(treasury);
    }

    function test_TreasuryMintBurn() public {
        vm.startPrank(treasury);
        usd8.mint(alice, 1_000e18);
        assertEq(usd8.balanceOf(alice), 1_000e18);
        usd8.burn(alice, 400e18);
        assertEq(usd8.balanceOf(alice), 600e18);
        assertEq(usd8.totalSupply(), 600e18);
        vm.stopPrank();
    }

    function test_NonTreasuryCannotMint() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        usd8.mint(alice, 1e18);
    }

    function test_NonTreasuryCannotBurn() public {
        vm.prank(treasury);
        usd8.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        usd8.burn(alice, 1e18);
    }

    function test_ConstructorRejectsZeroTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new USD8(address(0));
    }

    function test_MintToZeroReverts() public {
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        usd8.mint(address(0), 1e18);
    }

    function test_BurnFromZeroReverts() public {
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        usd8.burn(address(0), 1e18);
    }

    function test_RenounceOwnershipDisabled() public {
        vm.prank(treasury);
        vm.expectRevert(USD8.RenounceOwnershipDisabled.selector);
        usd8.renounceOwnership();
        assertEq(usd8.owner(), treasury);
    }

    function test_TreasuryHandoverIsTwoStep() public {
        vm.prank(treasury);
        usd8.transferOwnership(newTreasury);
        assertEq(usd8.owner(), treasury, "old treasury must remain until accept");
        assertEq(usd8.pendingOwner(), newTreasury);

        vm.prank(newTreasury);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newTreasury));
        usd8.mint(alice, 1e18);

        vm.prank(newTreasury);
        usd8.acceptOwnership();
        assertEq(usd8.owner(), newTreasury);

        vm.prank(newTreasury);
        usd8.mint(alice, 1e18);
        assertEq(usd8.balanceOf(alice), 1e18);

        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, treasury));
        usd8.mint(alice, 1e18);
    }
}
