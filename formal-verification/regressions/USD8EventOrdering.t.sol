// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";
import {USD8EventsSweepToken, USD8EventsV2} from "../properties/USD8Events.k.sol";

/// @notice Concrete Foundry regressions for multi-log order that Kontrol v1.0.255's
///         single-slot expectEmit model cannot express.
contract USD8EventOrderingForgeTest is Test {
    address internal constant RECIPIENT = address(0xB0B);

    event RegistryChanged(address indexed oldRegistry, address indexed newRegistry);
    event Initialized(uint64 version);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event TokenSwept(address indexed token, address indexed to, uint256 amount);
    event Upgraded(address indexed implementation);
    event UpgradeInitialized(uint256 value);

    Registry internal registry;
    USD8 internal usd8;

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(this));
    }

    function test_initializeEmitsRegistryChangedThenInitialized() public {
        USD8 fresh = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeWithSignature("name()"))));

        vm.expectEmit(true, true, false, true, address(fresh));
        emit RegistryChanged(address(0), address(registry));
        vm.expectEmit(false, false, false, true, address(fresh));
        emit Initialized(1);
        fresh.initialize(registry);
    }

    function test_sweepTokenEmitsTransferThenTokenSwept() public {
        uint256 amount = 17;
        USD8EventsSweepToken token = new USD8EventsSweepToken();
        token.mint(address(usd8), amount);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(usd8), RECIPIENT, amount);
        vm.expectEmit(true, true, false, true, address(usd8));
        emit TokenSwept(address(token), RECIPIENT, amount);
        usd8.sweepToken(IERC20(address(token)), RECIPIENT);
    }

    function test_upgradeEmitsUpgradedThenInitializerThenInitialized() public {
        uint256 value = 23;
        USD8EventsV2 candidate = new USD8EventsV2();

        vm.expectEmit(true, false, false, true, address(usd8));
        emit Upgraded(address(candidate));
        vm.expectEmit(false, false, false, true, address(usd8));
        emit UpgradeInitialized(value);
        vm.expectEmit(false, false, false, true, address(usd8));
        emit Initialized(2);
        usd8.upgradeToAndCall(address(candidate), abi.encodeCall(USD8EventsV2.initializeV2, (value)));
    }
}
