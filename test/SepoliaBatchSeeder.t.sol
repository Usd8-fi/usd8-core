// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {SepoliaBatchSeeder} from "../script/testnet/SepoliaBatchSeeder.sol";

contract SepoliaBatchSeederTest is Test {
    SepoliaBatchSeeder internal seeder;
    MockERC20 internal token;
    address[] internal recipients;

    function setUp() public {
        seeder = new SepoliaBatchSeeder();
        token = new MockERC20("Fixture", "FIX", 18);
        recipients.push(makeAddr("one"));
        recipients.push(makeAddr("two"));
        vm.deal(address(this), 3 ether);
        token.mint(address(this), 6e18);
        token.approve(address(seeder), 6e18);
    }

    function test_DistributesExactEtherAndTokenAmounts() public {
        seeder.distributeEther{value: 2 ether}(recipients, 1 ether);
        seeder.distributeToken(token, recipients, 3e18);

        assertEq(recipients[0].balance, 1 ether);
        assertEq(recipients[1].balance, 1 ether);
        assertEq(token.balanceOf(recipients[0]), 3e18);
        assertEq(token.balanceOf(recipients[1]), 3e18);
    }

    function test_RejectsWrongEtherValueEmptyRecipientsAndZeroAmount() public {
        vm.expectRevert(SepoliaBatchSeeder.ValueMismatch.selector);
        seeder.distributeEther{value: 1 ether}(recipients, 1 ether);

        address[] memory empty;
        vm.expectRevert(SepoliaBatchSeeder.InvalidDistribution.selector);
        seeder.distributeEther(empty, 1 ether);

        vm.expectRevert(SepoliaBatchSeeder.InvalidDistribution.selector);
        seeder.distributeToken(token, recipients, 0);
    }
}
