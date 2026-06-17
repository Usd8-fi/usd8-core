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
import {SavingsUSD8} from "../src/SavingsUSD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {LossyWithdrawStrategy} from "./mocks/LossyWithdrawStrategy.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";

contract TreasuryTest is Test {
    USD8 usd8;
    Treasury treasury;
    MockERC20 usdc;

    address constant USDC_ADDR = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address timelock = address(0xA11CE);
    address admin = address(0x57A7);
    address alice = address(0xBEEF);

    function _unauthorizedTimelock(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Treasury.UnauthorizedTimelock.selector, account);
    }

    function _unauthorizedAdmin(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Treasury.UnauthorizedAdmin.selector, account);
    }

    event Minted(address indexed user, uint256 usdcAmount, uint256 usd8Amount);
    event Redeemed(address indexed user, uint256 usd8Amount, uint256 usdcAmount);
    event PauseStateChanged(Treasury.PauseState oldState, Treasury.PauseState newState);
    event TimelockChanged(address indexed oldAdmin, address indexed newTimelock);
    event AdminChanged(address indexed oldStrategyManager, address indexed newStrategyManager);
    event StrategyAdded(IStrategy indexed strategy);
    event StrategyRemoved(IStrategy indexed strategy);
    event DepositedToStrategy(IStrategy indexed strategy, uint256 amount);
    event WithdrawnFromStrategy(IStrategy indexed strategy, uint256 amount);
    event RevenueDistributed(address indexed recipient, uint256 amount);
    event RevenueHarvested(uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);

    function setUp() public {
        // Etch a controllable mock at the hardcoded USDC mainnet address so
        // the constant in Treasury resolves to a token we can mint with.
        MockERC20 template = new MockERC20("USD Coin", "USDC", 6);
        vm.etch(USDC_ADDR, address(template).code);
        usdc = MockERC20(USDC_ADDR);

        USD8 impl = new USD8();
        bytes memory init = abi.encodeCall(USD8.initialize, (address(this), address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        usd8 = USD8(address(proxy));
        treasury = new Treasury(usd8, timelock, admin);
        usd8.setTreasury(address(treasury));

        assertEq(usd8.treasury(), address(treasury));
        assertEq(treasury.timelock(), timelock);
        assertEq(treasury.admin(), admin);
    }

    function test_ConstantsMatchSpec() public view {
        assertEq(address(treasury.USDC()), USDC_ADDR);
        assertEq(treasury.USDC_TO_USD8_SCALE(), 1e12);
        assertEq(address(treasury.usd8()), address(usd8));
    }

    // -- Pause system -----------------------------------------------------

    function test_PauseStateDefaultsToNone() public view {
        assertEq(uint256(treasury.pauseState()), uint256(Treasury.PauseState.None));
    }

    function test_AdminCanSetPauseState() public {
        vm.prank(timelock);
        vm.expectEmit(false, false, false, true, address(treasury));
        emit PauseStateChanged(Treasury.PauseState.None, Treasury.PauseState.MintPaused);
        treasury.setPauseState(Treasury.PauseState.MintPaused);
        assertEq(uint256(treasury.pauseState()), uint256(Treasury.PauseState.MintPaused));
    }

    function test_NonAdminCannotSetPauseState() public {
        vm.expectRevert(_unauthorizedAdmin(alice));
        vm.prank(alice);
        treasury.setPauseState(Treasury.PauseState.MintPaused);
    }

    function test_SetPauseStateOutOfRangeReverts() public {
        // Solc rejects out-of-range enum values with Panic(0x21).
        vm.prank(timelock);
        (bool ok,) = address(treasury).call(abi.encodeWithSignature("setPauseState(uint8)", uint8(4)));
        assertFalse(ok);
    }

    function test_MintPausedAllowsRedeem() public {
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        treasury.mintUSD8(1e6);
        vm.stopPrank();

        vm.prank(timelock);
        treasury.setPauseState(Treasury.PauseState.MintPaused);

        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Paused.selector, Treasury.PauseState.MintPaused));
        treasury.mintUSD8(1e6);
        treasury.redeemUSD8(1e18, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 1e6 + 1e6);
    }

    function test_RedeemPausedAllowsMint() public {
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        treasury.mintUSD8(1e6);
        vm.stopPrank();

        vm.prank(timelock);
        treasury.setPauseState(Treasury.PauseState.RedeemPaused);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Paused.selector, Treasury.PauseState.RedeemPaused));
        treasury.redeemUSD8(1e18, 0);

        usdc.mint(alice, 5e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 5e6);
        treasury.mintUSD8(5e6);
        vm.stopPrank();
        assertEq(usd8.balanceOf(alice), 6e18);
    }

    function test_SystemPauseBlocksBoth() public {
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        treasury.mintUSD8(1e6);
        vm.stopPrank();

        vm.prank(timelock);
        treasury.setPauseState(Treasury.PauseState.SystemPaused);

        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Paused.selector, Treasury.PauseState.SystemPaused));
        treasury.mintUSD8(1e6);

        vm.expectRevert(abi.encodeWithSelector(Treasury.Paused.selector, Treasury.PauseState.SystemPaused));
        treasury.redeemUSD8(1e18, 0);
        vm.stopPrank();
    }

    function test_PauseCanBeCleared() public {
        vm.startPrank(timelock);
        treasury.setPauseState(Treasury.PauseState.MintPaused);
        treasury.setPauseState(Treasury.PauseState.None);
        vm.stopPrank();

        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        treasury.mintUSD8(1e6);
        vm.stopPrank();

        assertEq(usd8.balanceOf(alice), 1e18);
    }

    function test_TimelockCanTransferTimelock() public {
        address newTimelock = address(0xC0FFEE);

        vm.prank(timelock);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit TimelockChanged(timelock, newTimelock);
        treasury.setTimelock(newTimelock);

        assertEq(treasury.timelock(), newTimelock);

        // Old timelock loses all role-gated access (it is not admin either).
        vm.expectRevert(_unauthorizedAdmin(timelock));
        vm.prank(timelock);
        treasury.setPauseState(Treasury.PauseState.MintPaused);

        vm.prank(newTimelock);
        treasury.setPauseState(Treasury.PauseState.SystemPaused);
        assertEq(uint256(treasury.pauseState()), uint256(Treasury.PauseState.SystemPaused));
    }

    function test_NonTimelockCannotTransferTimelock() public {
        vm.expectRevert(_unauthorizedTimelock(alice));
        vm.prank(alice);
        treasury.setTimelock(alice);
    }

    function test_SetTimelockRejectsZero() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        vm.prank(timelock);
        treasury.setTimelock(address(0));
    }

    function test_TimelockCanSetAdmin() public {
        address newAdmin = address(0xC0FFEE);
        MockStrategy strat = new MockStrategy(usdc);

        vm.prank(timelock);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit AdminChanged(admin, newAdmin);
        treasury.setAdmin(newAdmin);

        assertEq(treasury.admin(), newAdmin);

        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);

        assertEq(treasury.strategiesLength(), 1);
    }

    function test_NonTimelockCannotSetAdmin() public {
        vm.expectRevert(_unauthorizedTimelock(alice));
        vm.prank(alice);
        treasury.setAdmin(alice);
    }

    function test_SetAdminRejectsZero() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        vm.prank(timelock);
        treasury.setAdmin(address(0));
    }

    function test_AdminCanRunStrategyFundFlows() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);

        usdc.mint(address(treasury), 25e6);

        vm.startPrank(admin);
        treasury.depositToStrategy(strat, 25e6);
        treasury.withdrawFromStrategy(strat, 25e6);
        vm.stopPrank();

        vm.prank(timelock);
        treasury.removeStrategy(strat);

        assertEq(treasury.strategiesLength(), 0);
    }

    function test_Usd8TreasuryMigratesToNewTreasury() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();
        assertEq(usd8.balanceOf(alice), 100e18);
        assertEq(usd8.treasury(), address(treasury));

        address timelockB = address(0xB055);
        Treasury treasuryB = new Treasury(usd8, timelockB, timelockB);

        usd8.setTreasury(address(treasuryB));

        address bob = address(0xB0B);
        usdc.mint(bob, 10e6);
        vm.startPrank(bob);
        usdc.approve(address(treasury), 10e6);
        vm.expectRevert(abi.encodeWithSelector(USD8.UnauthorizedTreasury.selector, address(treasury)));
        treasury.mintUSD8(10e6);
        vm.stopPrank();

        usdc.mint(bob, 10e6);
        vm.startPrank(bob);
        usdc.approve(address(treasuryB), 10e6);
        treasuryB.mintUSD8(10e6);
        vm.stopPrank();
        assertEq(usd8.balanceOf(bob), 10e18);

        assertEq(usd8.balanceOf(alice), 100e18);
    }

    // -- Revenue harvesting & routing -------------------------------------

    address constant recipient = address(0xDEED);

    function test_DistributeRevenueForwardsUsd8ToRecipient() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();
        usdc.mint(address(treasury), 20e6);
        vm.prank(timelock);
        treasury.harvestRevenue();
        // 20e18 surplus minus the 10 bps buffer (100e18 / 1000 = 0.1e18).
        assertEq(usd8.balanceOf(address(treasury)), 19.9e18);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit RevenueDistributed(recipient, 12e18);
        vm.prank(timelock);
        treasury.distributeRevenue(recipient, 12e18, Treasury.RevenueDistributionMode.DirectTransfer);

        assertEq(usd8.balanceOf(recipient), 12e18);
        assertEq(usd8.balanceOf(address(treasury)), 7.9e18);
    }

    function test_DistributeRevenueToSavingsUsesProfitVesting() public {
        SavingsUSD8 savings = new SavingsUSD8(usd8, timelock, timelock);

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        usd8.approve(address(savings), 100e18);
        savings.deposit(100e18, alice);
        vm.stopPrank();

        usdc.mint(address(treasury), 20e6);
        vm.prank(timelock);
        treasury.harvestRevenue();
        // 20e18 surplus minus the 10 bps buffer (100e18 / 1000 = 0.1e18).
        assertEq(usd8.balanceOf(address(treasury)), 19.9e18);

        vm.prank(timelock);
        treasury.distributeRevenue(address(savings), 19.9e18, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        assertEq(usd8.balanceOf(address(treasury)), 0);
        assertEq(savings.pendingProfit(), 19.9e18);
        assertEq(savings.unvestedProfit(), 19.9e18);
        assertEq(savings.totalAssets(), 100e18, "no instant share-price jump");

        vm.warp(block.timestamp + 7 days);
        assertEq(savings.totalAssets(), 119.9e18);
    }

    function test_DistributeRevenueToZeroAddressReverts() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.distributeRevenue(address(0), 1e18, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function test_DistributeRevenueZeroAmountReverts() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.distributeRevenue(recipient, 0, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function test_NonAdminCannotDistributeRevenue() public {
        vm.expectRevert(_unauthorizedAdmin(alice));
        vm.prank(alice);
        treasury.distributeRevenue(recipient, 1e18, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function test_HarvestRevenueNoOpWhenNoSurplus() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        vm.prank(timelock);
        uint256 harvested = treasury.harvestRevenue();
        assertEq(harvested, 0);
        assertEq(usd8.balanceOf(address(treasury)), 0);
    }

    function test_HarvestRevenueRetainsSubBufferSurplus() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        // Sub-USDC dust redemption leaves a tiny (5e11) surplus that sits far
        // below the 10 bps buffer (~1e17), so harvest retains all of it.
        vm.prank(alice);
        treasury.redeemUSD8(5e11, 0);

        vm.prank(timelock);
        uint256 harvested = treasury.harvestRevenue();
        assertEq(harvested, 0);
        assertEq(usd8.balanceOf(address(treasury)), 0);
    }

    function test_HarvestRevenueMintsUsd8FromIdleSurplus() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();
        usdc.mint(address(treasury), 20e6);

        uint256 supplyBefore = usd8.totalSupply();
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 buffer = supplyBefore / treasury.HARVEST_BUFFER_DIVISOR();

        vm.expectEmit(false, false, false, true, address(treasury));
        emit RevenueHarvested(20e18 - buffer);
        vm.prank(timelock);
        uint256 harvested = treasury.harvestRevenue();

        assertEq(harvested, 20e18 - buffer, "minted USD8 equals surplus minus retained buffer");
        assertEq(usd8.balanceOf(address(treasury)), 20e18 - buffer);
        assertEq(treasury.getReserveBalance(), reserveBefore);
        assertEq(usd8.totalSupply(), supplyBefore + 20e18 - buffer);
        // Peg sits at supply + buffer after harvest, not exact equality.
        assertEq(treasury.getReserveBalance() * 1e12, usd8.totalSupply() + buffer);
    }

    function test_HarvestRevenueDoesNotTouchStrategies() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        MockStrategy strat = new MockStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        treasury.depositToStrategy(strat, 100e6);
        vm.stopPrank();

        usdc.mint(address(strat), 15e6);
        assertEq(treasury.getReserveBalance(), 115e6);

        vm.prank(timelock);
        uint256 harvested = treasury.harvestRevenue();
        // 15e18 surplus minus the 10 bps buffer (100e18 / 1000 = 0.1e18).
        assertEq(harvested, 14.9e18);
        assertEq(usd8.balanceOf(address(treasury)), 14.9e18);
        assertEq(strat.withdrawCallCount(), 0, "strategy not touched");
        assertEq(usdc.balanceOf(address(strat)), 115e6);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_SystemPauseBlocksGatedAdminFunctions() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);

        vm.prank(timelock);
        treasury.setPauseState(Treasury.PauseState.SystemPaused);

        bytes memory pauseErr = abi.encodeWithSelector(Treasury.Paused.selector, Treasury.PauseState.SystemPaused);

        vm.prank(timelock);
        vm.expectRevert(pauseErr);
        treasury.distributeRevenue(recipient, 1e18, Treasury.RevenueDistributionMode.DirectTransfer);

        vm.prank(timelock);
        vm.expectRevert(pauseErr);
        treasury.harvestRevenue();

        usdc.mint(address(treasury), 10e6);
        vm.prank(timelock);
        vm.expectRevert(pauseErr);
        treasury.depositToStrategy(strat, 10e6);

        vm.prank(timelock);
        vm.expectRevert(pauseErr);
        treasury.withdrawFromStrategy(strat, 1);
    }

    function test_SystemPauseDoesNotBlockUnpausing() public {
        vm.startPrank(timelock);
        treasury.setPauseState(Treasury.PauseState.SystemPaused);
        treasury.setPauseState(Treasury.PauseState.None);
        vm.stopPrank();
        assertEq(uint256(treasury.pauseState()), uint256(Treasury.PauseState.None));
    }

    function test_SystemPauseDoesNotBlockAddRemoveStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        treasury.setPauseState(Treasury.PauseState.SystemPaused);

        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        assertEq(treasury.strategiesLength(), 1);

        vm.prank(timelock);
        treasury.removeStrategy(strat);
        assertEq(treasury.strategiesLength(), 0);
    }

    function test_HarvestRevenueOnlyAdmin() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();
        usdc.mint(address(treasury), 5e6);

        vm.expectRevert(_unauthorizedAdmin(alice));
        vm.prank(alice);
        treasury.harvestRevenue();

        vm.prank(timelock);
        treasury.harvestRevenue();
        // 5e18 surplus minus the 10 bps buffer (100e18 / 1000 = 0.1e18).
        assertEq(usd8.balanceOf(address(treasury)), 4.9e18);
    }

    // -- Strategy ---------------------------------------------------------

    function _approveAndFundStrategy(MockStrategy strat, uint256 amount) internal {
        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        usdc.mint(address(treasury), amount);
        vm.prank(timelock);
        treasury.depositToStrategy(strat, amount);
    }

    function test_StrategiesEmptyByDefault() public view {
        assertEq(treasury.strategiesLength(), 0);
    }

    function test_AdminCanAddStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit StrategyAdded(strat);
        treasury.addStrategy(strat, type(uint256).max);

        assertEq(treasury.strategiesLength(), 1);
        assertEq(address(treasury.strategies(0)), address(strat));
    }

    function test_AddStrategyRejectsZeroAddress() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.addStrategy(IStrategy(address(0)), type(uint256).max);
    }

    function test_AddStrategyRejectsDuplicate() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StrategyAlreadyApproved.selector, strat));
        treasury.addStrategy(strat, type(uint256).max);
        vm.stopPrank();
    }

    function test_NonAdminCannotAddStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.expectRevert(_unauthorizedTimelock(alice));
        vm.prank(alice);
        treasury.addStrategy(strat, type(uint256).max);
    }

    function test_AddStrategyRejectsWrongUnderlying() public {
        WrongUsdcStrategy bad = new WrongUsdcStrategy();
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                Treasury.StrategyAssetMismatch.selector, IStrategy(address(bad)), USDC_ADDR, address(0xDEAD)
            )
        );
        treasury.addStrategy(IStrategy(address(bad)), type(uint256).max);
    }

    function test_RemoveStrategyForcesRemovalIgnoringFunds() public {
        MockStrategy strat = new MockStrategy(usdc);
        _approveAndFundStrategy(strat, 50e6);

        vm.prank(timelock);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit StrategyRemoved(strat);
        treasury.removeStrategy(strat);

        assertEq(treasury.strategiesLength(), 0);
        assertEq(usdc.balanceOf(address(strat)), 50e6, "funds orphaned in strategy");
    }

    function test_RemoveStrategyAfterDrain() public {
        MockStrategy strat = new MockStrategy(usdc);
        _approveAndFundStrategy(strat, 50e6);

        vm.startPrank(timelock);
        treasury.withdrawFromStrategy(strat, 50e6);
        treasury.removeStrategy(strat);
        vm.stopPrank();

        assertEq(treasury.strategiesLength(), 0);
    }

    function test_RemoveStrategyNotApprovedReverts() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StrategyNotApproved.selector, strat));
        treasury.removeStrategy(strat);
    }

    function test_AddStrategyAtIndexAndReorder() public {
        MockStrategy a = new MockStrategy(usdc);
        MockStrategy b = new MockStrategy(usdc);
        MockStrategy c = new MockStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(a, type(uint256).max); // [a]
        treasury.addStrategy(b, 0); // [b, a] — insert at front
        treasury.addStrategy(c, 1); // [b, c, a] — insert mid

        // Reposition existing: remove + re-add at the target index.
        // Mid-queue removal must not disturb the order of the others.
        treasury.removeStrategy(c); // [b, a]
        treasury.addStrategy(c, 2); // [b, a, c]
        treasury.removeStrategy(b); // [a, c]
        treasury.addStrategy(b, 1); // [a, b, c]
        vm.stopPrank();

        assertEq(address(treasury.strategies(0)), address(a));
        assertEq(address(treasury.strategies(1)), address(b));
        assertEq(address(treasury.strategies(2)), address(c));
    }

    function test_DepositToStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        usdc.mint(address(treasury), 100e6);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit DepositedToStrategy(strat, 100e6);
        treasury.depositToStrategy(strat, 100e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(treasury)), 0);
        assertEq(usdc.balanceOf(address(strat)), 100e6);
        assertEq(strat.deployCallCount(), 1);
    }

    function test_DepositToUnapprovedStrategyReverts() public {
        MockStrategy strat = new MockStrategy(usdc);
        usdc.mint(address(treasury), 100e6);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StrategyNotApproved.selector, strat));
        treasury.depositToStrategy(strat, 100e6);
    }

    function test_DepositZeroReverts() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.depositToStrategy(strat, 0);
        vm.stopPrank();
    }

    function test_WithdrawFromStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        _approveAndFundStrategy(strat, 100e6);

        vm.prank(timelock);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit WithdrawnFromStrategy(strat, 40e6);
        treasury.withdrawFromStrategy(strat, 40e6);

        assertEq(usdc.balanceOf(address(treasury)), 40e6);
        assertEq(usdc.balanceOf(address(strat)), 60e6);
        assertEq(strat.withdrawCallCount(), 1);
    }

    function test_NonAdminCannotDepositOrWithdraw() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);

        vm.expectRevert(_unauthorizedAdmin(alice));
        vm.prank(alice);
        treasury.depositToStrategy(strat, 1);

        vm.expectRevert(_unauthorizedAdmin(alice));
        vm.prank(alice);
        treasury.withdrawFromStrategy(strat, 1);
    }

    function test_MintLeavesUsdcIdle() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(treasury)), 100e6, "mint does not auto-deploy");
        assertEq(usdc.balanceOf(address(strat)), 0);
    }

    function test_ReserveBalanceSumsAcrossStrategies() public {
        MockStrategy a = new MockStrategy(usdc);
        MockStrategy b = new MockStrategy(usdc);
        _approveAndFundStrategy(a, 60e6);
        _approveAndFundStrategy(b, 30e6);
        usdc.mint(address(treasury), 10e6);

        assertEq(treasury.getReserveBalance(), 100e6, "idle + A + B");

        usdc.mint(address(a), 5e6);
        assertEq(treasury.getReserveBalance(), 105e6);
    }

    function test_RedeemPullsAcrossMultipleStrategies() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        MockStrategy a = new MockStrategy(usdc);
        MockStrategy b = new MockStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(a, type(uint256).max);
        treasury.addStrategy(b, type(uint256).max);
        treasury.depositToStrategy(a, 60e6);
        treasury.depositToStrategy(b, 40e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(treasury)), 0);
        assertEq(treasury.getReserveBalance(), 100e6);

        vm.prank(alice);
        treasury.redeemUSD8(80e18, 0);

        assertEq(usdc.balanceOf(alice), 80e6);
        assertEq(a.withdrawCallCount(), 1);
        assertEq(b.withdrawCallCount(), 1);
        assertEq(usdc.balanceOf(address(a)), 0, "A drained");
        assertEq(usdc.balanceOf(address(b)), 20e6, "B has remainder");
    }

    function test_RedeemDetectsSurplusHiddenStrategyLoss() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        LossyWithdrawStrategy strat = new LossyWithdrawStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        treasury.depositToStrategy(strat, 100e6);
        vm.stopPrank();

        usdc.mint(address(strat), 20e6);
        strat.setLossOnNextWithdraw(5e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.ReserveSupplyStatusWorsened.selector, 120e6, 100e18, 105e6, 90e18)
        );
        treasury.redeemUSD8(10e18, 0);
    }

    function test_RedeemSkipsEmptyStrategies() public {
        MockStrategy a = new MockStrategy(usdc);
        MockStrategy b = new MockStrategy(usdc);
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        vm.startPrank(timelock);
        treasury.addStrategy(a, type(uint256).max);
        treasury.addStrategy(b, type(uint256).max);
        treasury.depositToStrategy(b, 100e6);
        vm.stopPrank();

        vm.prank(alice);
        treasury.redeemUSD8(50e18, 0);

        assertEq(a.withdrawCallCount(), 0, "empty strategy not called");
        assertEq(b.withdrawCallCount(), 1);
        assertEq(usdc.balanceOf(alice), 50e6);
    }

    function test_RedeemRevertsIfShortfallExceedsAllStrategies() public {
        MockStrategy strat = new MockStrategy(usdc);
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        treasury.depositToStrategy(strat, 100e6);
        vm.stopPrank();

        vm.prank(address(strat));
        usdc.transfer(address(0xD), 100e6);

        vm.prank(alice);
        treasury.redeemUSD8(10e18, 0);
        assertEq(usdc.balanceOf(alice), 0, "total haircut, no USDC paid");
    }

    function test_MintUSD8() public {
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Minted(alice, 100e6, 100e18);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(address(treasury)), 100e6);
        assertEq(usd8.balanceOf(alice), 100e18);
        assertEq(usd8.totalSupply(), 100e18);
    }

    function test_Redeem() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Redeemed(alice, 40e18, 40e6);
        treasury.redeemUSD8(40e18, 0);
        vm.stopPrank();

        assertEq(usd8.balanceOf(alice), 60e18);
        assertEq(usdc.balanceOf(alice), 40e6);
        assertEq(usdc.balanceOf(address(treasury)), 60e6);
    }

    function test_MintZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.mintUSD8(0);
    }

    function test_RedeemZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.redeemUSD8(0, 0);
    }

    function test_RedeemWhenSupplyZeroRevertsCleanly() public {
        vm.prank(alice);
        vm.expectRevert(Treasury.NoUsd8Supply.selector);
        treasury.redeemUSD8(1e18, 0);
    }

    function test_RedeemRoundsDownInFavorOfProtocol() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);

        uint256 amount = 1e18 + 5e11;
        vm.expectEmit(true, false, false, true, address(treasury));
        emit Redeemed(alice, amount, 1e6);
        treasury.redeemUSD8(amount, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 1e6);
        assertEq(usdc.balanceOf(address(treasury)), 99e6);
        assertEq(usd8.balanceOf(alice), 100e18 - amount);
    }

    function test_RedeemSubUsdcUnitYieldsZeroUsdc() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);

        treasury.redeemUSD8(5e11, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(address(treasury)), 100e6);
        assertEq(usd8.balanceOf(alice), 100e18 - 5e11);
    }

    function test_RedeemRequiresUsd8Balance() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.redeemUSD8(1e18, 0);
    }

    function test_GetReserveBalanceMirrorsUsdcBalance() public {
        assertEq(treasury.getReserveBalance(), 0);
        usdc.mint(address(treasury), 250e6);
        assertEq(treasury.getReserveBalance(), 250e6);
    }

    // -- Pro-rata redemption ----------------------------------------------

    function _setupDistressed(address holder, uint256 lossUsdc)
        internal
        returns (uint256 supplyBefore, uint256 reserveBefore)
    {
        usdc.mint(holder, 100e6);
        vm.startPrank(holder);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        vm.prank(address(treasury));
        usdc.transfer(address(0xDEAD), lossUsdc);

        supplyBefore = usd8.totalSupply();
        reserveBefore = treasury.getReserveBalance();
    }

    function test_RedeemHaircutInDistress() public {
        (uint256 supplyBefore, uint256 reserveBefore) = _setupDistressed(alice, 10e6);
        assertEq(supplyBefore, 100e18);
        assertEq(reserveBefore, 90e6);

        vm.prank(alice);
        treasury.redeemUSD8(50e18, 0);

        assertEq(usdc.balanceOf(alice), 45e6, "alice gets pro-rata haircut");
        assertEq(usdc.balanceOf(address(treasury)), 45e6, "treasury holds the other half");
        assertEq(usd8.balanceOf(alice), 50e18);

        assertEq(treasury.getReserveBalance() * 1e18, usd8.totalSupply() * 90e6 / 100);
    }

    function test_RedeemSlippageReverts() public {
        (uint256 supplyBefore, uint256 reserveBefore) = _setupDistressed(alice, 10e6);
        assertEq(supplyBefore, 100e18);
        assertEq(reserveBefore, 90e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Treasury.InsufficientUsdcOut.selector, 45e6, 50e6));
        treasury.redeemUSD8(50e18, 50e6);

        vm.prank(alice);
        treasury.redeemUSD8(50e18, 45e6);
        assertEq(usdc.balanceOf(alice), 45e6);
    }

    function test_RedeemRatioPreservedAcrossPartialRedemptions() public {
        _setupDistressed(alice, 10e6);

        uint256 ratioBeforeNumer = treasury.getReserveBalance();
        uint256 ratioBeforeDenom = usd8.totalSupply();

        vm.startPrank(alice);
        treasury.redeemUSD8(20e18, 0);
        treasury.redeemUSD8(30e18, 0);
        vm.stopPrank();

        assertEq(treasury.getReserveBalance() * ratioBeforeDenom, usd8.totalSupply() * ratioBeforeNumer);
    }

    function test_MintDuringDistressIsDonation() public {
        _setupDistressed(alice, 10e6);

        address bob = address(0xB0B);
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        treasury.redeemUSD8(100e18, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), 95e6, "bob loses 5 USDC by minting into distress");
        assertEq(treasury.getReserveBalance(), 95e6);
        assertEq(usd8.totalSupply(), 100e18);
    }

    function test_RedeemSurplusCapsAtPeg() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        usdc.mint(address(treasury), 50e6);
        assertEq(treasury.getReserveBalance(), 150e6);

        vm.prank(alice);
        treasury.redeemUSD8(100e18, 0);

        assertEq(usdc.balanceOf(alice), 100e6, "redeem capped at 1:1");
        assertEq(usdc.balanceOf(address(treasury)), 50e6, "surplus retained");
        assertEq(usd8.totalSupply(), 0);
    }

    function test_NoArbitrageInHealthyState() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        treasury.redeemUSD8(100e18, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(usd8.balanceOf(alice), 0);
    }

    function test_NoArbitrageWithFlashMintRedeemInDistress() public {
        _setupDistressed(alice, 10e6);
        address bob = address(0xB0B);
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(treasury), 1_000e6);
        uint256 startUsdc = usdc.balanceOf(bob);
        treasury.mintUSD8(1_000e6);
        treasury.redeemUSD8(1_000e18, 0);
        uint256 endUsdc = usdc.balanceOf(bob);
        vm.stopPrank();

        assertLt(endUsdc, startUsdc, "attacker strictly loses USDC on the round-trip");
    }

    // -- Rescue -----------------------------------------------------------

    function test_RescueTokenSendsToRecipient() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(treasury), 7e18);

        vm.prank(timelock);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit TokenRescued(address(stray), recipient, 7e18);
        treasury.rescueToken(IERC20(address(stray)), recipient, 7e18);

        assertEq(stray.balanceOf(recipient), 7e18);
        assertEq(stray.balanceOf(address(treasury)), 0);
    }

    function test_RescueTokenRejectsUSDC() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Treasury.RescueProtected.selector, address(usdc)));
        treasury.rescueToken(IERC20(address(usdc)), recipient, 1);
    }

    function test_RescueTokenRejectsUSD8() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Treasury.RescueProtected.selector, address(usd8)));
        treasury.rescueToken(IERC20(address(usd8)), recipient, 1);
    }

    function test_RescueTokenRejectsZeroAddress() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        vm.prank(timelock);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.rescueToken(IERC20(address(stray)), address(0), 1);
    }

    function test_RescueETHSendsToRecipient() public {
        vm.deal(address(treasury), 1 ether);

        vm.prank(timelock);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit ETHRescued(recipient, 1 ether);
        treasury.rescueETH(payable(recipient), 1 ether);

        assertEq(recipient.balance, 1 ether);
    }
}

/// @dev Strategy whose `underlying()` returns a non-USDC address, used to
///      exercise StrategyAssetMismatch in Treasury.
contract WrongUsdcStrategy is IStrategy {
    function underlying() external pure override returns (address) {
        return address(0xDEAD);
    }

    function deploy(uint256) external override {}
    function withdraw(uint256) external override {}

    function totalAssets() external pure override returns (uint256) {
        return 0;
    }
}
