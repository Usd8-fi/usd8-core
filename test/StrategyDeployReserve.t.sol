// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Registry} from "../src/Registry.sol";
import {Treasury} from "../src/Treasury.sol";
import {USD8} from "../src/USD8.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Plain OpenZeppelin ERC-4626 vault (no decimals offset): a one-unit seed
///      plus a large donation inflates share price through virtual-share rounding.
contract PublicVault is ERC20, ERC4626 {
    constructor(IERC20 asset_) ERC20("Public", "PUB") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }
}

/// @title L-03 regression: a strategy deployment may not impair the aggregate
///        reserve beyond the fixed rounding allowance.
contract StrategyDeployReserveTest is Test {
    address constant USDC_ADDR = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address timelock = address(0xA11CE);
    address admin = address(0xAD);
    address mallory = address(0xBAD);

    MockERC20 usdc;
    Registry registry;
    USD8 usd8;
    Treasury treasury;
    PublicVault vault;
    ERC4626Strategy strategy;

    function setUp() public {
        MockERC20 template = new MockERC20("USD Coin", "USDC", 6);
        vm.etch(USDC_ADDR, address(template).code);
        usdc = MockERC20(USDC_ADDR);
        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (timelock, admin))))
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        vm.prank(timelock);
        registry.setUsd8(address(usd8));
        treasury = Treasury(
            address(
                new ERC1967Proxy(
                    address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry, IERC20(USDC_ADDR)))
                )
            )
        );
        vm.prank(timelock);
        registry.setTreasury(address(treasury));

        vault = new PublicVault(IERC20(USDC_ADDR));
        strategy = new ERC4626Strategy(address(treasury), registry, vault);
        vm.prank(timelock);
        treasury.addStrategy(IStrategy(address(strategy)), type(uint256).max);

        usdc.mint(address(treasury), 1000e6);
    }

    /// @dev Auditor scenario: 1 base-unit seed + 500 USDC donation, then Treasury
    ///      deploys 500 USDC. The adapter's own tolerance accepts the ~166 USDC
    ///      shortfall; Treasury must reject it.
    function test_DonationInflatedVaultDeploymentReverts() public {
        _inflateVault(1, 500e6);
        uint256 before = treasury.getReserveBalance();
        assertEq(before, 1000e6);

        vm.prank(admin);
        vm.expectPartialRevert(Treasury.StrategyDeployReserveLoss.selector);
        treasury.depositToStrategy(IStrategy(address(strategy)), 500e6);

        assertEq(treasury.getReserveBalance(), before, "reserve unchanged after revert");
        assertEq(usdc.balanceOf(address(treasury)), 1000e6);
    }

    /// @dev Ordinary rounding (at most a couple of base units) still passes.
    function test_HealthyVaultDeploymentWithinTolerance() public {
        _inflateVault(100e6, 7); // tiny appreciation: share price ~1.00000007
        uint256 before = treasury.getReserveBalance();

        vm.prank(admin);
        treasury.depositToStrategy(IStrategy(address(strategy)), 500e6);

        uint256 afterBal = treasury.getReserveBalance();
        assertLe(before - afterBal, treasury.RESERVE_CHECK_TOLERANCE());
        assertGe(strategy.totalAssets(), 500e6 - 2);
    }

    function _inflateVault(uint256 seed, uint256 donation) internal {
        usdc.mint(mallory, seed + donation);
        vm.startPrank(mallory);
        usdc.approve(address(vault), seed);
        vault.deposit(seed, mallory);
        usdc.transfer(address(vault), donation);
        vm.stopPrank();
    }
}
