// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "../../src/Registry.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8} from "../../src/USD8.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";

contract TreasuryEventsV2 is Treasury {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Exact Treasury event surface exercised through real ERC1967 proxies.
contract TreasuryEventsTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant USER = address(0xBEEF);
    address internal constant RECEIVER_ONE = address(0xCAFE);
    address internal constant RECEIVER_TWO = address(0xD00D);
    address internal constant SWEEP_RECIPIENT = address(0xF00D);

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasury;
    MockERC20 internal usdc;

    event RegistryChanged(address indexed oldRegistry, address indexed newRegistry);
    event Initialized(uint64 version);
    event Minted(address indexed user, uint256 usdcAmount, uint256 usd8Amount);
    event Redeemed(address indexed user, uint256 usd8Amount, uint256 usdcAmount);
    event StrategyAdded(IStrategy indexed strategy);
    event StrategyRemoved(IStrategy indexed strategy);
    event DepositedToStrategy(IStrategy indexed strategy, uint256 amount);
    event WithdrawnFromStrategy(IStrategy indexed strategy, uint256 amount);
    event RevenueHarvested(uint256 amount);
    event RevenueDistributed(address indexed recipient, uint256 amount);
    event ProfitReceiverSet(address indexed receiver, uint256 weight, Treasury.RevenueDistributionMode mode);
    event ProfitReceiverRemoved(address indexed receiver);
    event ETHSwept(address indexed to, uint256 amount);
    event TokenSwept(address indexed token, address indexed to, uint256 amount);
    event Upgraded(address indexed implementation);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        treasury = Treasury(
            address(
                new ERC1967Proxy(
                    address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(usdc))))
                )
            )
        );
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(treasury));
    }

    function _mintForUser(uint256 usdcAmount) internal {
        usdc.mint(USER, usdcAmount);
        vm.startPrank(USER);
        usdc.approve(address(treasury), usdcAmount);
        treasury.mintUSD8(usdcAmount);
        vm.stopPrank();
    }

    function test_initializeEmitsRegistryChangedThenInitializedFromProxy() public {
        Treasury implementation = new Treasury();
        address candidate = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectEmit(true, true, false, true, candidate);
        emit RegistryChanged(address(0), address(registry));
        vm.expectEmit(false, false, false, true, candidate);
        emit Initialized(1);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(usdc))))
        );
        assertEq(address(proxy), candidate);
    }

    function test_mintAndRedeemEmitExactAmountsFromProxy() public {
        uint256 usdcAmount = 100e6;
        uint256 usd8Amount = 100e18;
        usdc.mint(USER, usdcAmount);
        vm.startPrank(USER);
        usdc.approve(address(treasury), usdcAmount);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Minted(USER, usdcAmount, usd8Amount);
        treasury.mintUSD8(usdcAmount);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Redeemed(USER, 40e18, 40e6);
        treasury.redeemUSD8(40e18, 40e6);
        vm.stopPrank();
    }

    function test_strategyCurationAndFlowsEmitExactStrategyAndAmounts() public {
        MockStrategy strategy = new MockStrategy(usdc);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit StrategyAdded(strategy);
        treasury.addStrategy(strategy, type(uint256).max);

        usdc.mint(address(treasury), 50e6);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit DepositedToStrategy(strategy, 50e6);
        treasury.depositToStrategy(strategy, 50e6);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit WithdrawnFromStrategy(strategy, 20e6);
        treasury.withdrawFromStrategy(strategy, 20e6);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit StrategyRemoved(strategy);
        treasury.removeStrategy(strategy);
    }

    function test_harvestEmitsHarvestThenOrderedExactDistributions() public {
        _mintForUser(100e6);
        usdc.mint(address(treasury), 20e6);
        treasury.setProfitReceiver(RECEIVER_ONE, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        treasury.setProfitReceiver(RECEIVER_TWO, 3, Treasury.RevenueDistributionMode.DirectTransfer);

        uint256 harvested = 19_900e15;
        uint256 firstShare = harvested / 4;
        uint256 secondShare = harvested - firstShare;
        vm.expectEmit(false, false, false, true, address(treasury));
        emit RevenueHarvested(harvested);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit RevenueDistributed(RECEIVER_ONE, firstShare);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit RevenueDistributed(RECEIVER_TWO, secondShare);
        treasury.harvestAndDistribute();
    }

    function test_profitReceiverSetAndRemovedEmitExactConfiguration() public {
        vm.expectEmit(true, false, false, true, address(treasury));
        emit ProfitReceiverSet(RECEIVER_ONE, 7, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        treasury.setProfitReceiver(RECEIVER_ONE, 7, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit ProfitReceiverRemoved(RECEIVER_ONE);
        treasury.removeProfitReceiver(RECEIVER_ONE);
    }

    function test_sweepsEmitExactTokenETHRecipientsAndAmounts() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(treasury), 7e18);
        vm.deal(address(treasury), 1 ether);

        vm.expectEmit(true, true, false, true, address(treasury));
        emit TokenSwept(address(stray), SWEEP_RECIPIENT, 7e18);
        treasury.sweepToken(IERC20(address(stray)), SWEEP_RECIPIENT);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit ETHSwept(SWEEP_RECIPIENT, 1 ether);
        treasury.sweepETH(payable(SWEEP_RECIPIENT));
    }

    function test_upgradeEmitsExactImplementationFromProxy() public {
        TreasuryEventsV2 implementation = new TreasuryEventsV2();

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Upgraded(address(implementation));
        treasury.upgradeToAndCall(address(implementation), "");
    }
}
