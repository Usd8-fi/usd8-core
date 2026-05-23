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
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {USD8} from "../../src/USD8.sol";
import {SavingsUSD8} from "../../src/vaults/SavingsUSD8.sol";
import {VestedERC4626} from "../../src/vaults/VestedERC4626.sol";
import {IStrategy} from "../../src/IStrategy.sol";

/// @dev Minimal USD8-denominated mock strategy mirroring `test/mocks/MockStrategy.sol`
///      but for the USD8 token instead of USDC.
contract MockUSD8Strategy is IStrategy {
    USD8 public immutable usd8;
    uint256 public deployedAmount;
    uint256 public deployCallCount;
    uint256 public withdrawCallCount;

    constructor(USD8 _usd8) {
        usd8 = _usd8;
    }

    function deploy(uint256 amount) external override {
        deployedAmount += amount;
        deployCallCount += 1;
    }

    function withdraw(uint256 amount) external override {
        withdrawCallCount += 1;
        usd8.transfer(msg.sender, amount);
    }

    function totalAssets() external view override returns (uint256) {
        return usd8.balanceOf(address(this));
    }
}

contract SavingsUSD8Test is Test {
    USD8 usd8;
    SavingsUSD8 vault;

    address admin = address(0xA11CE);
    address usd8Owner = address(this); // deployer holds USD8 minting power until we delegate
    address alice = address(0xBEEF);
    address reporter = address(0xDA7A);

    uint64 constant UNLOCK = 7 days;

    function setUp() public {
        usd8 = new USD8(usd8Owner);
        vault = new SavingsUSD8(usd8, admin, UNLOCK);
    }

    function _mintUSD8To(address to, uint256 amount) internal {
        // Test contract is USD8's admin; can mint directly.
        usd8.mint(to, amount);
    }

    // -- Basics ------------------------------------------------------------

    function test_ConstructorWiring() public view {
        assertEq(address(vault.asset()), address(usd8));
        assertEq(vault.owner(), admin);
        assertEq(vault.profitMaxUnlockTime(), UNLOCK);
        assertEq(vault.name(), "Savings USD8");
        assertEq(vault.symbol(), "sUSD8");
        assertEq(vault.strategiesLength(), 0);
    }

    function test_DepositRedeemNormal() public {
        _mintUSD8To(alice, 100e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 100e18);
        uint256 shares = vault.deposit(100e18, alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();
        assertEq(usd8.balanceOf(alice), 100e18);
    }

    // -- Profit vesting ----------------------------------------------------

    function test_ProfitVestsLinearly() public {
        _mintUSD8To(alice, 100e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        _mintUSD8To(reporter, 50e18);
        vm.startPrank(reporter);
        usd8.approve(address(vault), 50e18);
        vault.reportProfit(50e18);
        vm.stopPrank();

        // No instant jump.
        assertEq(vault.totalAssets(), 100e18);

        // Halfway.
        vm.warp(block.timestamp + UNLOCK / 2);
        assertApproxEqAbs(vault.totalAssets(), 125e18, 1);

        // Fully vested.
        vm.warp(block.timestamp + UNLOCK);
        assertEq(vault.totalAssets(), 150e18);
    }

    // -- Strategy management -----------------------------------------------

    function _approve(MockUSD8Strategy s) internal {
        IStrategy[] memory arr = new IStrategy[](1);
        arr[0] = s;
        vm.prank(admin);
        vault.addStrategies(arr);
    }

    function test_AddStrategy() public {
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);
        assertEq(address(vault.strategies(0)), address(s));
        assertEq(vault.strategiesLength(), 1);
    }

    function test_AddStrategyZeroAddressReverts() public {
        IStrategy[] memory arr = new IStrategy[](1);
        arr[0] = IStrategy(address(0));
        vm.prank(admin);
        vm.expectRevert(SavingsUSD8.ZeroAddress.selector);
        vault.addStrategies(arr);
    }

    function test_AddStrategyDuplicateReverts() public {
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);
        IStrategy[] memory arr = new IStrategy[](1);
        arr[0] = s;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SavingsUSD8.StrategyAlreadyApproved.selector, s));
        vault.addStrategies(arr);
    }

    function test_NonAdminCannotAddStrategy() public {
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        IStrategy[] memory arr = new IStrategy[](1);
        arr[0] = s;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.addStrategies(arr);
    }

    function test_DepositToStrategyAndIncludeInRawAssets() public {
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);

        _mintUSD8To(alice, 100e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        // Admin pushes 60 USD8 into strategy.
        vm.prank(admin);
        vault.depositToStrategy(s, 60e18);

        assertEq(usd8.balanceOf(address(vault)), 40e18, "idle");
        assertEq(usd8.balanceOf(address(s)), 60e18, "strategy");
        // totalAssets counts both (no profit vesting yet).
        assertEq(vault.totalAssets(), 100e18);
    }

    function test_WithdrawPullsFromStrategyWhenIdleInsufficient() public {
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);

        _mintUSD8To(alice, 100e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 100e18);
        uint256 shares = vault.deposit(100e18, alice);
        vm.stopPrank();

        vm.prank(admin);
        vault.depositToStrategy(s, 100e18);
        assertEq(usd8.balanceOf(address(vault)), 0);

        // Alice fully withdraws; the vault must pull from strategy.
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(usd8.balanceOf(alice), 100e18);
        assertEq(s.withdrawCallCount(), 1);
        assertEq(usd8.balanceOf(address(s)), 0);
    }

    function test_RemoveStrategyRequiresDrained() public {
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);

        _mintUSD8To(alice, 50e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 50e18);
        vault.deposit(50e18, alice);
        vm.stopPrank();
        vm.prank(admin);
        vault.depositToStrategy(s, 50e18);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SavingsUSD8.StrategyHasFunds.selector, s, 50e18));
        vault.removeStrategy(s);

        vm.startPrank(admin);
        vault.withdrawFromStrategy(s, 50e18);
        vault.removeStrategy(s);
        vm.stopPrank();
        assertEq(vault.strategiesLength(), 0);
    }

    function test_ProfitVestingWithStrategyDeployed() public {
        // End-to-end: user deposits, admin moves to strategy, profit reported.
        // Vesting still works correctly.
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);

        _mintUSD8To(alice, 100e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        vm.stopPrank();
        vm.prank(admin);
        vault.depositToStrategy(s, 100e18);

        // Reporter brings 20 USD8 of profit (e.g., harvested from strategy).
        _mintUSD8To(reporter, 20e18);
        vm.startPrank(reporter);
        usd8.approve(address(vault), 20e18);
        vault.reportProfit(20e18);
        vm.stopPrank();

        // No instant jump: idle (20) + strategy (100) − unvested (20) = 100.
        assertEq(vault.totalAssets(), 100e18);

        vm.warp(block.timestamp + UNLOCK);
        assertEq(vault.totalAssets(), 120e18);
    }
}
