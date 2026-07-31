// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Registry} from "../src/Registry.sol";

contract ProtocolFeeTest is Test {
    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant ADMIN = address(0xAD);

    Registry internal registry;

    function setUp() public {
        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (TIMELOCK, ADMIN))))
        );
    }

    function test_ProtocolFeeConfigDefaultsToAdminAndTwentyPercentShares() public view {
        Registry.ProtocolFeeConfig memory config = registry.protocolFeeConfig();

        assertEq(config.receiver, ADMIN);
        assertEq(config.claimProtocolFeeShareBps, 2_000);
        assertEq(config.reserveYieldFeeBps, 2_000);
    }

    function test_AdminAtomicallyUpdatesProtocolFeeConfig() public {
        Registry.ProtocolFeeConfig memory next = Registry.ProtocolFeeConfig({
            receiver: address(0xFEE), claimProtocolFeeShareBps: 1_500, reserveYieldFeeBps: 1_000
        });

        vm.prank(ADMIN);
        registry.setProtocolFeeConfig(next);

        Registry.ProtocolFeeConfig memory saved = registry.protocolFeeConfig();
        assertEq(saved.receiver, next.receiver);
        assertEq(saved.claimProtocolFeeShareBps, next.claimProtocolFeeShareBps);
        assertEq(saved.reserveYieldFeeBps, next.reserveYieldFeeBps);
    }

    function test_ProtocolFeeConfigRejectsUnauthorizedCaller() public {
        Registry.ProtocolFeeConfig memory next = Registry.ProtocolFeeConfig({
            receiver: address(0xFEE), claimProtocolFeeShareBps: 1_500, reserveYieldFeeBps: 1_000
        });

        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, address(0xBAD)));
        vm.prank(address(0xBAD));
        registry.setProtocolFeeConfig(next);
    }

    function test_ProtocolFeeConfigRejectsZeroReceiver() public {
        Registry.ProtocolFeeConfig memory next = Registry.ProtocolFeeConfig({
            receiver: address(0), claimProtocolFeeShareBps: 1_500, reserveYieldFeeBps: 1_000
        });

        vm.expectRevert(Registry.ZeroAddress.selector);
        vm.prank(ADMIN);
        registry.setProtocolFeeConfig(next);
    }

    function test_ProtocolFeeConfigRejectsClaimFeeAboveTwentyPercent() public {
        Registry.ProtocolFeeConfig memory next = Registry.ProtocolFeeConfig({
            receiver: address(0xFEE), claimProtocolFeeShareBps: 2_001, reserveYieldFeeBps: 2_000
        });

        vm.expectRevert(abi.encodeWithSelector(Registry.InvalidProtocolFeeBps.selector, uint256(2_001)));
        vm.prank(ADMIN);
        registry.setProtocolFeeConfig(next);
    }

    function test_ProtocolFeeConfigRejectsReserveFeeAboveTwentyPercent() public {
        Registry.ProtocolFeeConfig memory next = Registry.ProtocolFeeConfig({
            receiver: address(0xFEE), claimProtocolFeeShareBps: 2_000, reserveYieldFeeBps: 2_001
        });

        vm.expectRevert(abi.encodeWithSelector(Registry.InvalidProtocolFeeBps.selector, uint256(2_001)));
        vm.prank(ADMIN);
        registry.setProtocolFeeConfig(next);
    }
}
