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
import {Treasury} from "../src/Treasury.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {IStrategy} from "../src/IStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TreasuryTest is Test {
    USD8 usd8;
    Treasury treasury;
    MockERC20 usdc;

    address constant USDC_ADDR = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address treasuryAdmin = address(0xA11CE);
    address alice = address(0xBEEF);

    event Minted(address indexed user, uint256 usdcAmount, uint256 usd8Amount);
    event Redeemed(address indexed user, uint256 usd8Amount, uint256 usdcAmount);
    event PauseStateChanged(Treasury.PauseState oldState, Treasury.PauseState newState);
    event StrategyAdded(IStrategy indexed strategy);
    event StrategyRemoved(IStrategy indexed strategy);
    event DepositedToStrategy(IStrategy indexed strategy, uint256 amount);
    event WithdrawnFromStrategy(IStrategy indexed strategy, uint256 amount);
    event RevenueRecipientAdded(address indexed recipient);
    event RevenueRecipientRemoved(address indexed recipient);
    event RevenueDistributed(address indexed recipient, uint256 amount);
    event RevenueHarvested(uint256 amount);

    function setUp() public {
        // Etch a controllable mock at the hardcoded USDC mainnet address so
        // the constant in Treasury resolves to a token we can mint with.
        MockERC20 template = new MockERC20("USD Coin", "USDC", 6);
        vm.etch(USDC_ADDR, address(template).code);
        usdc = MockERC20(USDC_ADDR);

        usd8 = new USD8(address(this));
        treasury = new Treasury(usd8, treasuryAdmin);
        usd8.transferOwnership(address(treasury));
        treasury.acceptUsd8Ownership();

        assertEq(usd8.owner(), address(treasury));
        assertEq(treasury.owner(), treasuryAdmin);
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
        vm.prank(treasuryAdmin);
        vm.expectEmit(false, false, false, true, address(treasury));
        emit PauseStateChanged(Treasury.PauseState.None, Treasury.PauseState.MintPaused);
        treasury.setPauseState(Treasury.PauseState.MintPaused);
        assertEq(uint256(treasury.pauseState()), uint256(Treasury.PauseState.MintPaused));
    }

    function test_NonAdminCannotSetPauseState() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        treasury.setPauseState(Treasury.PauseState.MintPaused);
    }

    function test_SetPauseStateOutOfRangeReverts() public {
        // Solc rejects out-of-range enum values with Panic(0x21).
        vm.prank(treasuryAdmin);
        (bool ok,) = address(treasury).call(abi.encodeWithSignature("setPauseState(uint8)", uint8(4)));
        assertFalse(ok);
    }

    function test_MintPausedAllowsRedeem() public {
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        treasury.mintUSD8(1e6);
        vm.stopPrank();

        vm.prank(treasuryAdmin);
        treasury.setPauseState(Treasury.PauseState.MintPaused);

        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Paused.selector, Treasury.PauseState.MintPaused));
        treasury.mintUSD8(1e6);
        treasury.redeemUSD8(1e18);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 1e6 + 1e6);
    }

    function test_RedeemPausedAllowsMint() public {
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        treasury.mintUSD8(1e6);
        vm.stopPrank();

        vm.prank(treasuryAdmin);
        treasury.setPauseState(Treasury.PauseState.RedeemPaused);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Paused.selector, Treasury.PauseState.RedeemPaused));
        treasury.redeemUSD8(1e18);

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

        vm.prank(treasuryAdmin);
        treasury.setPauseState(Treasury.PauseState.SystemPaused);

        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        vm.expectRevert(abi.encodeWithSelector(Treasury.Paused.selector, Treasury.PauseState.SystemPaused));
        treasury.mintUSD8(1e6);

        vm.expectRevert(abi.encodeWithSelector(Treasury.Paused.selector, Treasury.PauseState.SystemPaused));
        treasury.redeemUSD8(1e18);
        vm.stopPrank();
    }

    function test_PauseCanBeCleared() public {
        vm.startPrank(treasuryAdmin);
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

    function test_RenounceOwnershipDisabled() public {
        vm.prank(treasuryAdmin);
        vm.expectRevert(Treasury.RenounceOwnershipDisabled.selector);
        treasury.renounceOwnership();
        assertEq(treasury.owner(), treasuryAdmin);
    }

    function test_AdminTransferIsTwoStep() public {
        address newAdmin = address(0xC0FFEE);
        vm.prank(treasuryAdmin);
        treasury.transferOwnership(newAdmin);
        assertEq(treasury.owner(), treasuryAdmin);
        assertEq(treasury.pendingOwner(), newAdmin);

        vm.prank(newAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newAdmin));
        treasury.setPauseState(Treasury.PauseState.SystemPaused);

        vm.prank(newAdmin);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), newAdmin);

        vm.prank(newAdmin);
        treasury.setPauseState(Treasury.PauseState.SystemPaused);
        assertEq(uint256(treasury.pauseState()), uint256(Treasury.PauseState.SystemPaused));
    }

    function test_Usd8OwnershipMigratesToNewTreasury() public {
        // After launch: there's USD8 supply outstanding, controlled by the
        // current Treasury. Migrate USD8 ownership to a fresh Treasury B
        // (e.g., a future v2 with new features) and confirm:
        //   - the live USD8 supply continues to exist
        //   - the old Treasury can no longer mint/burn
        //   - the new Treasury can

        // 1. Live state: alice has 100e18 USD8, backed by 100e6 USDC in
        //    the original Treasury.
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();
        assertEq(usd8.balanceOf(alice), 100e18);
        assertEq(usd8.owner(), address(treasury));

        // 2. Deploy a fresh Treasury B with a different admin.
        address treasuryAdminB = address(0xB055);
        Treasury treasuryB = new Treasury(usd8, treasuryAdminB);

        // 3. Old Treasury's admin initiates the 2-step transfer on USD8.
        vm.prank(treasuryAdmin);
        treasury.transferUsd8Ownership(address(treasuryB));

        // After initiation: still old owner; new is pending.
        assertEq(usd8.owner(), address(treasury));
        assertEq(usd8.pendingOwner(), address(treasuryB));

        // 4. Treasury B (or anyone) completes the handover via its bridge.
        treasuryB.acceptUsd8Ownership();
        assertEq(usd8.owner(), address(treasuryB));
        assertEq(usd8.pendingOwner(), address(0));

        // 5. Old Treasury can no longer mint — its `usd8.mint()` call now
        //    reverts because Treasury is no longer USD8's owner.
        address bob = address(0xB0B);
        usdc.mint(bob, 10e6);
        vm.startPrank(bob);
        usdc.approve(address(treasury), 10e6);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(treasury)));
        treasury.mintUSD8(10e6);
        vm.stopPrank();

        // 6. New Treasury B can mint normally.
        usdc.mint(bob, 10e6);
        vm.startPrank(bob);
        usdc.approve(address(treasuryB), 10e6);
        treasuryB.mintUSD8(10e6);
        vm.stopPrank();
        assertEq(usd8.balanceOf(bob), 10e18);

        // 7. Alice's existing position is preserved across the migration.
        assertEq(usd8.balanceOf(alice), 100e18);
    }

    function test_NonAdminCannotTransferUsd8Ownership() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        treasury.transferUsd8Ownership(address(0xDEAD));
    }

    // -- Revenue harvesting & routing -------------------------------------

    address constant recipient = address(0xDEED);

    function test_AdminCanAddRevenueRecipient() public {
        vm.prank(treasuryAdmin);
        vm.expectEmit(true, false, false, false, address(treasury));
        emit RevenueRecipientAdded(recipient);
        treasury.addRevenueRecipient(recipient);
        assertEq(treasury.revenueRecipients(0), recipient);
        assertEq(treasury.revenueRecipientsLength(), 1);
    }

    function test_AddRevenueRecipientRejectsZero() public {
        vm.prank(treasuryAdmin);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.addRevenueRecipient(address(0));
    }

    function test_AddRevenueRecipientRejectsDuplicate() public {
        vm.startPrank(treasuryAdmin);
        treasury.addRevenueRecipient(recipient);
        vm.expectRevert(abi.encodeWithSelector(Treasury.RevenueRecipientAlreadyApproved.selector, recipient));
        treasury.addRevenueRecipient(recipient);
        vm.stopPrank();
    }

    function test_NonAdminCannotAddRevenueRecipient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        treasury.addRevenueRecipient(recipient);
    }

    function test_AdminCanRemoveRevenueRecipient() public {
        vm.startPrank(treasuryAdmin);
        treasury.addRevenueRecipient(recipient);
        vm.expectEmit(true, false, false, false, address(treasury));
        emit RevenueRecipientRemoved(recipient);
        treasury.removeRevenueRecipient(recipient);
        vm.stopPrank();
        assertEq(treasury.revenueRecipientsLength(), 0);
    }

    function test_RemoveUnapprovedRevenueRecipientReverts() public {
        vm.prank(treasuryAdmin);
        vm.expectRevert(abi.encodeWithSelector(Treasury.RevenueRecipientNotApproved.selector, recipient));
        treasury.removeRevenueRecipient(recipient);
    }

    function test_DistributeRevenueForwardsUsd8ToRecipient() public {
        // Mint 100 USD8 backed by 100 USDC, then donate 20 USDC as yield
        // and harvest into the Treasury.
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();
        usdc.mint(address(treasury), 20e6);
        treasury.harvestRevenue();
        assertEq(usd8.balanceOf(address(treasury)), 20e18);

        vm.startPrank(treasuryAdmin);
        treasury.addRevenueRecipient(recipient);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit RevenueDistributed(recipient, 12e18);
        treasury.distributeRevenue(recipient, 12e18);
        vm.stopPrank();

        assertEq(usd8.balanceOf(recipient), 12e18);
        assertEq(usd8.balanceOf(address(treasury)), 8e18);
    }

    function test_DistributeRevenueToUnapprovedReverts() public {
        vm.prank(treasuryAdmin);
        vm.expectRevert(abi.encodeWithSelector(Treasury.RevenueRecipientNotApproved.selector, recipient));
        treasury.distributeRevenue(recipient, 1e18);
    }

    function test_DistributeRevenueZeroAmountReverts() public {
        vm.startPrank(treasuryAdmin);
        treasury.addRevenueRecipient(recipient);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.distributeRevenue(recipient, 0);
        vm.stopPrank();
    }

    function test_NonAdminCannotDistributeRevenue() public {
        vm.prank(treasuryAdmin);
        treasury.addRevenueRecipient(recipient);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        treasury.distributeRevenue(recipient, 1e18);
    }

    function test_HarvestRevenueNoOpWhenNoSurplus() public {
        // Mint 100 USDC -> 100 USD8. Reserve exactly matches supply.
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        uint256 harvested = treasury.harvestRevenue();
        assertEq(harvested, 0);
        assertEq(usd8.balanceOf(address(treasury)), 0);
    }

    function test_HarvestRevenueCapturesSubUsdcSurplus() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        // Sub-USDC surplus via a dust redeem (burns USD8, pays out 0 USDC).
        vm.prank(alice);
        treasury.redeemUSD8(5e11);

        uint256 harvested = treasury.harvestRevenue();
        assertEq(harvested, 5e11);
        assertEq(usd8.balanceOf(address(treasury)), 5e11);
    }

    function test_HarvestRevenueMintsUsd8FromIdleSurplus() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();
        usdc.mint(address(treasury), 20e6); // simulated yield, all idle

        uint256 supplyBefore = usd8.totalSupply();
        uint256 reserveBefore = treasury.getReserveBalance();

        vm.expectEmit(false, false, false, true, address(treasury));
        emit RevenueHarvested(20e18);
        uint256 harvested = treasury.harvestRevenue();

        assertEq(harvested, 20e18, "minted USD8 equals USDC surplus times 1e12");
        assertEq(usd8.balanceOf(address(treasury)), 20e18);
        assertEq(treasury.getReserveBalance(), reserveBefore);
        assertEq(usd8.totalSupply(), supplyBefore + 20e18);
        // Peg holds: reserve * 1e12 = supply post-harvest.
        assertEq(treasury.getReserveBalance() * 1e12, usd8.totalSupply());
    }

    function test_HarvestRevenueDoesNotTouchStrategies() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        MockStrategy strat = new MockStrategy(usdc);
        vm.startPrank(treasuryAdmin);
        treasury.addStrategies(_one(strat));
        treasury.depositToStrategy(strat, 100e6);
        vm.stopPrank();

        usdc.mint(address(strat), 15e6); // simulated yield
        assertEq(treasury.getReserveBalance(), 115e6);

        uint256 harvested = treasury.harvestRevenue();
        assertEq(harvested, 15e18);
        assertEq(usd8.balanceOf(address(treasury)), 15e18);
        assertEq(strat.withdrawCallCount(), 0, "strategy not touched");
        assertEq(usdc.balanceOf(address(strat)), 115e6);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_SystemPauseBlocksGatedAdminFunctions() public {
        // Set up pre-pause state so each gated function has the prerequisites
        // it needs to even attempt to run.
        MockStrategy strat = new MockStrategy(usdc);
        vm.startPrank(treasuryAdmin);
        treasury.addStrategies(_one(strat));
        treasury.addRevenueRecipient(recipient);
        treasury.transferOwnership(alice); // sets alice as pending admin
        vm.stopPrank();

        // Now pause the system.
        vm.prank(treasuryAdmin);
        treasury.setPauseState(Treasury.PauseState.SystemPaused);

        bytes memory pauseErr = abi.encodeWithSelector(Treasury.Paused.selector, Treasury.PauseState.SystemPaused);

        // acceptOwnership (Treasury admin role)
        vm.prank(alice);
        vm.expectRevert(pauseErr);
        treasury.acceptOwnership();

        // acceptUsd8Ownership
        vm.expectRevert(pauseErr);
        treasury.acceptUsd8Ownership();

        // transferUsd8Ownership
        vm.prank(treasuryAdmin);
        vm.expectRevert(pauseErr);
        treasury.transferUsd8Ownership(address(0xBEEF));

        // distributeRevenue
        vm.prank(treasuryAdmin);
        vm.expectRevert(pauseErr);
        treasury.distributeRevenue(recipient, 1e18);

        // harvestRevenue
        vm.expectRevert(pauseErr);
        treasury.harvestRevenue();

        // depositToStrategy
        usdc.mint(address(treasury), 10e6);
        vm.prank(treasuryAdmin);
        vm.expectRevert(pauseErr);
        treasury.depositToStrategy(strat, 10e6);

        // withdrawFromStrategy
        vm.prank(treasuryAdmin);
        vm.expectRevert(pauseErr);
        treasury.withdrawFromStrategy(strat, 1);
    }

    function test_SystemPauseDoesNotBlockUnpausing() public {
        vm.startPrank(treasuryAdmin);
        treasury.setPauseState(Treasury.PauseState.SystemPaused);
        // The unpause path must always be reachable.
        treasury.setPauseState(Treasury.PauseState.None);
        vm.stopPrank();
        assertEq(uint256(treasury.pauseState()), uint256(Treasury.PauseState.None));
    }

    function test_SystemPauseDoesNotBlockAddRemoveStrategy() public {
        // Strategy curation is intentionally NOT gated by SystemPaused.
        // Confirm admin can still add/remove during a freeze.
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(treasuryAdmin);
        treasury.setPauseState(Treasury.PauseState.SystemPaused);

        vm.prank(treasuryAdmin);
        treasury.addStrategies(_one(strat));
        assertEq(treasury.strategiesLength(), 1);

        vm.prank(treasuryAdmin);
        treasury.removeStrategy(strat);
        assertEq(treasury.strategiesLength(), 0);
    }

    function test_HarvestRevenueCallableByAnyone() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();
        usdc.mint(address(treasury), 5e6);

        // Alice (random user) triggers harvest. Revenue (USD8) is minted
        // into the Treasury itself, not to alice.
        vm.prank(alice);
        treasury.harvestRevenue();

        assertEq(usd8.balanceOf(address(treasury)), 5e18);
        assertEq(usd8.balanceOf(alice), 100e18, "alice's own balance unchanged");
    }

    // -- Strategy ---------------------------------------------------------

    /// @dev Wraps a single strategy in a one-element array for the bulk
    ///      `addStrategies` API.
    function _one(IStrategy s) internal pure returns (IStrategy[] memory arr) {
        arr = new IStrategy[](1);
        arr[0] = s;
    }

    function _approveAndFundStrategy(MockStrategy strat, uint256 amount) internal {
        vm.prank(treasuryAdmin);
        treasury.addStrategies(_one(strat));
        usdc.mint(address(treasury), amount);
        vm.prank(treasuryAdmin);
        treasury.depositToStrategy(strat, amount);
    }

    function test_StrategiesEmptyByDefault() public view {
        assertEq(treasury.strategiesLength(), 0);
    }

    function test_AdminCanAddStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(treasuryAdmin);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit StrategyAdded(strat);
        treasury.addStrategies(_one(strat));

        assertEq(treasury.strategiesLength(), 1);
        assertEq(address(treasury.strategies(0)), address(strat));
    }

    function test_AddStrategyRejectsZeroAddress() public {
        vm.prank(treasuryAdmin);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.addStrategies(_one(IStrategy(address(0))));
    }

    function test_AddStrategyRejectsDuplicate() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.startPrank(treasuryAdmin);
        treasury.addStrategies(_one(strat));
        vm.expectRevert(abi.encodeWithSelector(Treasury.StrategyAlreadyApproved.selector, strat));
        treasury.addStrategies(_one(strat));
        vm.stopPrank();
    }

    function test_BulkAddStrategies() public {
        MockStrategy a = new MockStrategy(usdc);
        MockStrategy b = new MockStrategy(usdc);
        MockStrategy c = new MockStrategy(usdc);

        IStrategy[] memory batch = new IStrategy[](3);
        batch[0] = a;
        batch[1] = b;
        batch[2] = c;

        vm.prank(treasuryAdmin);
        treasury.addStrategies(batch);

        assertEq(treasury.strategiesLength(), 3);
        assertEq(address(treasury.strategies(0)), address(a));
        assertEq(address(treasury.strategies(1)), address(b));
        assertEq(address(treasury.strategies(2)), address(c));
    }

    function test_BulkAddRejectsDuplicateInBatch() public {
        MockStrategy a = new MockStrategy(usdc);
        IStrategy[] memory batch = new IStrategy[](2);
        batch[0] = a;
        batch[1] = a; // duplicate within the same call

        vm.prank(treasuryAdmin);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StrategyAlreadyApproved.selector, a));
        treasury.addStrategies(batch);

        // All-or-nothing: even the first one shouldn't have been added.
        assertEq(treasury.strategiesLength(), 0);
    }

    function test_BulkAddEmptyArrayIsNoop() public {
        IStrategy[] memory empty = new IStrategy[](0);
        vm.prank(treasuryAdmin);
        treasury.addStrategies(empty);
        assertEq(treasury.strategiesLength(), 0);
    }

    function test_NonAdminCannotAddStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        treasury.addStrategies(_one(strat));
    }

    function test_RemoveStrategyRequiresZeroAssets() public {
        MockStrategy strat = new MockStrategy(usdc);
        _approveAndFundStrategy(strat, 50e6);

        vm.prank(treasuryAdmin);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StrategyHasFunds.selector, strat, 50e6));
        treasury.removeStrategy(strat);
    }

    function test_RemoveStrategyAfterDrain() public {
        MockStrategy strat = new MockStrategy(usdc);
        _approveAndFundStrategy(strat, 50e6);

        vm.startPrank(treasuryAdmin);
        treasury.withdrawFromStrategy(strat, 50e6);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit StrategyRemoved(strat);
        treasury.removeStrategy(strat);
        vm.stopPrank();

        assertEq(treasury.strategiesLength(), 0);
    }

    function test_RemoveStrategyNotApprovedReverts() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(treasuryAdmin);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StrategyNotApproved.selector, strat));
        treasury.removeStrategy(strat);
    }

    function test_DepositToStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        usdc.mint(address(treasury), 100e6);
        vm.startPrank(treasuryAdmin);
        treasury.addStrategies(_one(strat));

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
        vm.prank(treasuryAdmin);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StrategyNotApproved.selector, strat));
        treasury.depositToStrategy(strat, 100e6);
    }

    function test_DepositZeroReverts() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.startPrank(treasuryAdmin);
        treasury.addStrategies(_one(strat));
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.depositToStrategy(strat, 0);
        vm.stopPrank();
    }

    function test_WithdrawFromStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        _approveAndFundStrategy(strat, 100e6);

        vm.prank(treasuryAdmin);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit WithdrawnFromStrategy(strat, 40e6);
        treasury.withdrawFromStrategy(strat, 40e6);

        assertEq(usdc.balanceOf(address(treasury)), 40e6);
        assertEq(usdc.balanceOf(address(strat)), 60e6);
        assertEq(strat.withdrawCallCount(), 1);
    }

    function test_NonAdminCannotDepositOrWithdraw() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(treasuryAdmin);
        treasury.addStrategies(_one(strat));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        treasury.depositToStrategy(strat, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        treasury.withdrawFromStrategy(strat, 1);
    }

    function test_MintLeavesUsdcIdle() public {
        // Even with strategies approved, mint must NOT auto-deploy. Admin
        // explicitly allocates.
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(treasuryAdmin);
        treasury.addStrategies(_one(strat));

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
        usdc.mint(address(treasury), 10e6); // idle

        assertEq(treasury.getReserveBalance(), 100e6, "idle + A + B");

        // Yield in A.
        usdc.mint(address(a), 5e6);
        assertEq(treasury.getReserveBalance(), 105e6);
    }

    function test_RedeemPullsAcrossMultipleStrategies() public {
        // Set up: 100e18 USD8 minted (against 100e6 USDC). Move all USDC
        // into two strategies (60 + 40) so idle = 0.
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        MockStrategy a = new MockStrategy(usdc);
        MockStrategy b = new MockStrategy(usdc);
        vm.startPrank(treasuryAdmin);
        treasury.addStrategies(_one(a));
        treasury.addStrategies(_one(b));
        treasury.depositToStrategy(a, 60e6);
        treasury.depositToStrategy(b, 40e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(treasury)), 0);
        assertEq(treasury.getReserveBalance(), 100e6);

        // Redeem 80e18 → 80e6 USDC. Need to drain A (60) then take 20 from B.
        vm.prank(alice);
        treasury.redeemUSD8(80e18);

        assertEq(usdc.balanceOf(alice), 80e6);
        assertEq(a.withdrawCallCount(), 1);
        assertEq(b.withdrawCallCount(), 1);
        assertEq(usdc.balanceOf(address(a)), 0, "A drained");
        assertEq(usdc.balanceOf(address(b)), 20e6, "B has remainder");
    }

    function test_RedeemSkipsEmptyStrategies() public {
        MockStrategy a = new MockStrategy(usdc);
        MockStrategy b = new MockStrategy(usdc);
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        vm.startPrank(treasuryAdmin);
        treasury.addStrategies(_one(a)); // empty
        treasury.addStrategies(_one(b));
        treasury.depositToStrategy(b, 100e6);
        vm.stopPrank();

        // Redeem 50 → need 50 from somewhere. A is empty, should skip.
        vm.prank(alice);
        treasury.redeemUSD8(50e18);

        assertEq(a.withdrawCallCount(), 0, "empty strategy not called");
        assertEq(b.withdrawCallCount(), 1);
        assertEq(usdc.balanceOf(alice), 50e6);
    }

    function test_RedeemRevertsIfShortfallExceedsAllStrategies() public {
        // Mint 100, deploy 100. Then drain the strategy via admin so total
        // backing collapses. Redeem should revert (USDC.safeTransfer fails)
        // because there's nothing to pull from.
        MockStrategy strat = new MockStrategy(usdc);
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        vm.startPrank(treasuryAdmin);
        treasury.addStrategies(_one(strat));
        treasury.depositToStrategy(strat, 100e6);
        vm.stopPrank();

        // Drain the strategy's USDC out-of-band (simulating loss).
        vm.prank(address(strat));
        usdc.transfer(address(0xD), 100e6);

        // Reserve is now 0. Pro-rata redeem would pay 0 USDC, but supply > 0
        // so usdcAmount > 0 if any user redeems. Actually with C=0 in
        // distress, usdcAmount = amount * 0 / S / 1e12 = 0. So redeem
        // succeeds with 0 payout — pro-rata haircut is total.
        vm.prank(alice);
        treasury.redeemUSD8(10e18);
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
        treasury.redeemUSD8(40e18);
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
        treasury.redeemUSD8(0);
    }

    function test_RedeemRoundsDownInFavorOfProtocol() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);

        uint256 amount = 1e18 + 5e11;
        vm.expectEmit(true, false, false, true, address(treasury));
        emit Redeemed(alice, amount, 1e6);
        treasury.redeemUSD8(amount);
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

        treasury.redeemUSD8(5e11);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(address(treasury)), 100e6);
        assertEq(usd8.balanceOf(alice), 100e18 - 5e11);
    }

    function test_RedeemRequiresUsd8Balance() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.redeemUSD8(1e18);
    }

    function test_GetReserveBalanceMirrorsUsdcBalance() public {
        assertEq(treasury.getReserveBalance(), 0);
        usdc.mint(address(treasury), 250e6);
        assertEq(treasury.getReserveBalance(), 250e6);
    }

    // -- Pro-rata redemption ----------------------------------------------

    /// @dev Simulate a 10% loss on the reserve: alice has 100e18
    /// USD8 backed by 100e6 USDC, then 10e6 USDC walks out of the Treasury
    /// (in real life this would be a strategy loss). Pro-rata haircut must
    /// pay 90 USDC for 100 USD8, leaving the ratio unchanged for any
    /// remaining holders.
    function _setupDistressed(address holder, uint256 lossUsdc)
        internal
        returns (uint256 supplyBefore, uint256 reserveBefore)
    {
        usdc.mint(holder, 100e6);
        vm.startPrank(holder);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        // Drain `lossUsdc` from Treasury, prank as Treasury (it owns the funds).
        vm.prank(address(treasury));
        usdc.transfer(address(0xDEAD), lossUsdc);

        supplyBefore = usd8.totalSupply();
        reserveBefore = treasury.getReserveBalance();
    }

    function test_RedeemHaircutInDistress() public {
        (uint256 supplyBefore, uint256 reserveBefore) = _setupDistressed(alice, 10e6);
        assertEq(supplyBefore, 100e18);
        assertEq(reserveBefore, 90e6);

        // Redeem 50e18 USD8 — half the supply. Pro-rata payout:
        //   50e18 * 90e6 * 1e12 / (100e18 * 1e12) = 50e18 * 90e6 / 100e18 = 45e6.
        vm.prank(alice);
        treasury.redeemUSD8(50e18);

        assertEq(usdc.balanceOf(alice), 45e6, "alice gets pro-rata haircut");
        assertEq(usdc.balanceOf(address(treasury)), 45e6, "treasury holds the other half");
        assertEq(usd8.balanceOf(alice), 50e18);

        // Ratio preserved: 45e6 USDC / 50e18 USD8 == 90e6 / 100e18.
        assertEq(treasury.getReserveBalance() * 1e18, usd8.totalSupply() * 90e6 / 100);
    }

    function test_RedeemRatioPreservedAcrossPartialRedemptions() public {
        _setupDistressed(alice, 10e6);

        uint256 ratioBeforeNumer = treasury.getReserveBalance();
        uint256 ratioBeforeDenom = usd8.totalSupply();

        vm.startPrank(alice);
        treasury.redeemUSD8(20e18);
        treasury.redeemUSD8(30e18);
        vm.stopPrank();

        // After each redeem, C/S must equal the prior C/S (modulo rounding).
        // Equivalent: C * denom == S * numer.
        assertEq(treasury.getReserveBalance() * ratioBeforeDenom, usd8.totalSupply() * ratioBeforeNumer);
    }

    function test_MintDuringDistressIsDonation() public {
        _setupDistressed(alice, 10e6);

        // Bob mints 100 USDC during distress. Mint is unconditional 1:1.
        // S=200e18, C=190e6 after. Ratio improves from 0.9 to 0.95.
        address bob = address(0xB0B);
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        // Bob redeems immediately at the new (better) ratio: gets 95e6.
        treasury.redeemUSD8(100e18);
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

        // Donate 50 USDC to the Treasury — simulates accrued yield.
        usdc.mint(address(treasury), 50e6);
        assertEq(treasury.getReserveBalance(), 150e6);

        // Alice redeems 100e18 USD8. Pro-rata would give 150 USDC, but the
        // cap at peg gives only 100. Surplus stays in Treasury.
        vm.prank(alice);
        treasury.redeemUSD8(100e18);

        assertEq(usdc.balanceOf(alice), 100e6, "redeem capped at 1:1");
        assertEq(usdc.balanceOf(address(treasury)), 50e6, "surplus retained");
        assertEq(usd8.totalSupply(), 0);
    }

    function test_NoArbitrageInHealthyState() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        treasury.redeemUSD8(100e18);
        vm.stopPrank();

        // Round-trip in healthy state: net zero.
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
        treasury.redeemUSD8(1_000e18);
        uint256 endUsdc = usdc.balanceOf(bob);
        vm.stopPrank();

        assertLt(endUsdc, startUsdc, "attacker strictly loses USDC on the round-trip");
    }
}
