// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {USD8} from "../../src/USD8.sol";
import {SavingsUSD8} from "../../src/SavingsUSD8.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/// @dev Minimal USD8-denominated mock strategy mirroring test/mocks/MockStrategy.sol
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

    function underlying() external view override returns (address) {
        return address(usd8);
    }
}

contract LossyUSD8Strategy is IStrategy {
    USD8 public immutable usd8;
    uint256 public deployCallCount;
    uint256 public withdrawCallCount;
    uint256 public lossOnNextWithdraw;

    constructor(USD8 _usd8) {
        usd8 = _usd8;
    }

    function setLossOnNextWithdraw(uint256 amount) external {
        lossOnNextWithdraw = amount;
    }

    function deploy(uint256) external override {
        deployCallCount += 1;
    }

    function withdraw(uint256 amount) external override {
        withdrawCallCount += 1;

        uint256 loss = lossOnNextWithdraw;
        if (loss != 0) {
            lossOnNextWithdraw = 0;
            usd8.transfer(address(0xD15CADED), loss);
        }

        usd8.transfer(msg.sender, amount);
    }

    function totalAssets() external view override returns (uint256) {
        return usd8.balanceOf(address(this));
    }

    function underlying() external view override returns (address) {
        return address(usd8);
    }
}

contract SavingsUSD8Test is Test {
    USD8 usd8;
    SavingsUSD8 vault;

    address timelock = address(0xA11CE);
    address admin = address(0x57A7);
    address usd8Treasury = address(this); // test contract mints directly.
    address alice = address(0xBEEF);
    address reporter = address(0xDA7A);

    uint64 constant UNLOCK = 7 days;

    function _unauthorizedTimelock(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SavingsUSD8.UnauthorizedTimelock.selector, account);
    }

    function _unauthorizedAdmin(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SavingsUSD8.UnauthorizedAdmin.selector, account);
    }

    function setUp() public {
        USD8 implUSD8 = new USD8();
        bytes memory init = abi.encodeCall(USD8.initialize, (address(this), usd8Treasury));
        usd8 = USD8(address(new ERC1967Proxy(address(implUSD8), init)));
        vault = new SavingsUSD8(usd8, timelock, admin);
    }

    function _mintUSD8To(address to, uint256 amount) internal {
        // Test contract is USD8's configured treasury; can mint directly.
        usd8.mint(to, amount);
    }

    // -- Basics ------------------------------------------------------------

    function test_ConstructorWiring() public view {
        assertEq(address(vault.asset()), address(usd8));
        assertEq(vault.timelock(), timelock);
        assertEq(vault.admin(), admin);
        assertEq(vault.profitMaxUnlockTime(), UNLOCK);
        assertEq(vault.name(), "Savings USD8");
        assertEq(vault.symbol(), "sUSD8");
        assertEq(vault.strategiesLength(), 0);
    }

    function test_SetProfitMaxUnlockTime() public {
        vm.prank(timelock);
        vault.setProfitMaxUnlockTime(8 hours);
        assertEq(vault.profitMaxUnlockTime(), 8 hours);

        // Timelock only — fast admin shrinking the window would enable
        // JIT-sniping the next distribution.
        vm.expectRevert(_unauthorizedTimelock(admin));
        vm.prank(admin);
        vault.setProfitMaxUnlockTime(1 hours);

        // Bounds: (0, MAX_PROFIT_MAX_UNLOCK_TIME].
        vm.expectRevert(SavingsUSD8.InvalidProfitMaxUnlockTime.selector);
        vm.prank(timelock);
        vault.setProfitMaxUnlockTime(0);

        vm.expectRevert(SavingsUSD8.InvalidProfitMaxUnlockTime.selector);
        vm.prank(timelock);
        vault.setProfitMaxUnlockTime(30 days + 1);
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

    function test_PermitSetsShareAllowance() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("permitOwner");
        address spender = address(0xCAFE);
        uint256 value = 25e18;
        uint256 deadline = block.timestamp + 1 hours;

        _mintUSD8To(owner, 100e18);
        vm.startPrank(owner);
        usd8.approve(address(vault), 100e18);
        vault.deposit(100e18, owner);
        vm.stopPrank();

        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, value, vault.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        vault.permit(owner, spender, value, deadline, v, r, s);

        assertEq(vault.allowance(owner, spender), value);
        assertEq(vault.nonces(owner), 1);
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
        vault.receiveProfitDistribution(50e18);
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
        vm.prank(timelock);
        vault.addStrategy(s, type(uint256).max);
    }

    function test_AddStrategy() public {
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);
        assertEq(address(vault.strategies(0)), address(s));
        assertEq(vault.strategiesLength(), 1);
    }

    function test_AddStrategyZeroAddressReverts() public {
        vm.prank(timelock);
        vm.expectRevert(SavingsUSD8.ZeroAddress.selector);
        vault.addStrategy(IStrategy(address(0)), type(uint256).max);
    }

    function test_AddStrategyDuplicateReverts() public {
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(SavingsUSD8.StrategyAlreadyApproved.selector, s));
        vault.addStrategy(s, type(uint256).max);
    }

    function test_NonAdminCannotAddStrategy() public {
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        vm.expectRevert(_unauthorizedTimelock(alice));
        vm.prank(alice);
        vault.addStrategy(s, type(uint256).max);
    }

    function test_AdminCanMoveFundsButNotCurateStrategies() public {
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);

        _mintUSD8To(alice, 25e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 25e18);
        vault.deposit(25e18, alice);
        vm.stopPrank();

        // Fast ops: fund moves are admin-allowed.
        vm.startPrank(admin);
        vault.depositToStrategy(s, 25e18);
        vault.withdrawFromStrategy(s, 25e18);
        vm.stopPrank();

        // Curation is timelock-only: admin can neither add nor remove a strategy
        // (removal can orphan funded assets -> unbacked shares, so it's gated).
        vm.expectRevert(_unauthorizedTimelock(admin));
        vm.prank(admin);
        vault.removeStrategy(s);

        MockUSD8Strategy s2 = new MockUSD8Strategy(usd8);
        vm.expectRevert(_unauthorizedTimelock(admin));
        vm.prank(admin);
        vault.addStrategy(s2, type(uint256).max);

        // Timelock can remove.
        vm.prank(timelock);
        vault.removeStrategy(s);
        assertEq(vault.strategiesLength(), 0);
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
        vm.prank(timelock);
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

        vm.prank(timelock);
        vault.depositToStrategy(s, 100e18);
        assertEq(usd8.balanceOf(address(vault)), 0);

        // Alice fully withdraws; the vault must pull from strategy.
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(usd8.balanceOf(alice), 100e18);
        assertEq(s.withdrawCallCount(), 1);
        assertEq(usd8.balanceOf(address(s)), 0);
    }

    function test_WithdrawRevertsIfSharePriceWouldDecrease() public {
        LossyUSD8Strategy s = new LossyUSD8Strategy(usd8);
        vm.prank(timelock);
        vault.addStrategy(s, type(uint256).max);

        _mintUSD8To(alice, 100e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        vm.prank(timelock);
        vault.depositToStrategy(s, 100e18);

        s.setLossOnNextWithdraw(10e18);

        vm.prank(alice);
        vm.expectPartialRevert(SavingsUSD8.SharePriceDecreased.selector);
        vault.withdraw(20e18, alice, alice);

        assertEq(vault.totalAssets(), 100e18);
        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(usd8.balanceOf(address(s)), 100e18);
    }

    function test_RemoveStrategyForcesRemovalIgnoringFunds() public {
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);

        _mintUSD8To(alice, 50e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 50e18);
        vault.deposit(50e18, alice);
        vm.stopPrank();
        vm.prank(timelock);
        vault.depositToStrategy(s, 50e18);

        vm.prank(timelock);
        vault.removeStrategy(s);
        assertEq(vault.strategiesLength(), 0);
        assertEq(usd8.balanceOf(address(s)), 50e18, "funds orphaned in strategy");
    }

    function test_AddStrategyAtIndexAndReorder() public {
        MockUSD8Strategy a = new MockUSD8Strategy(usd8);
        MockUSD8Strategy b = new MockUSD8Strategy(usd8);
        MockUSD8Strategy c = new MockUSD8Strategy(usd8);
        vm.startPrank(timelock);
        vault.addStrategy(a, type(uint256).max); // [a]
        vault.addStrategy(b, 0); // [b, a] — insert at front
        vault.addStrategy(c, 1); // [b, c, a] — insert mid

        // Reposition existing: remove + re-add at the target index.
        // Mid-queue removal must not disturb the order of the others.
        vault.removeStrategy(c); // [b, a]
        vault.addStrategy(c, 2); // [b, a, c]
        vault.removeStrategy(b); // [a, c]
        vault.addStrategy(b, 1); // [a, b, c]
        vm.stopPrank();

        assertEq(address(vault.strategies(0)), address(a));
        assertEq(address(vault.strategies(1)), address(b));
        assertEq(address(vault.strategies(2)), address(c));
    }

    function test_ProfitVestingWithStrategyDeployed() public {
        // End-to-end: user deposits, timelock moves to strategy, profit reported.
        // Vesting still works correctly.
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);

        _mintUSD8To(alice, 100e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        vm.stopPrank();
        vm.prank(timelock);
        vault.depositToStrategy(s, 100e18);

        // Reporter brings 20 USD8 of profit (e.g., harvested from strategy).
        _mintUSD8To(reporter, 20e18);
        vm.startPrank(reporter);
        usd8.approve(address(vault), 20e18);
        vault.receiveProfitDistribution(20e18);
        vm.stopPrank();

        // No instant jump: idle (20) + strategy (100) − unvested (20) = 100.
        assertEq(vault.totalAssets(), 100e18);

        vm.warp(block.timestamp + UNLOCK);
        assertEq(vault.totalAssets(), 120e18);
    }

    function test_WithdrawKeepsUnvestedProfitIdleAfterStrategyLoss() public {
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);

        _mintUSD8To(alice, 100e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 100e18);
        vault.deposit(100e18, alice);
        vm.stopPrank();

        vm.prank(timelock);
        vault.depositToStrategy(s, 100e18);

        _mintUSD8To(reporter, 20e18);
        vm.startPrank(reporter);
        usd8.approve(address(vault), 20e18);
        vault.receiveProfitDistribution(20e18);
        vm.stopPrank();

        vm.prank(alice);
        vault.redeem(50e18, alice, alice);

        assertEq(usd8.balanceOf(address(vault)), vault.unvestedProfit(), "unvested buffer remains idle");

        uint256 strategyBalance = usd8.balanceOf(address(s));
        vm.prank(address(s));
        usd8.transfer(address(0xD), strategyBalance);

        assertEq(vault.totalAssets(), 0, "strategy loss cannot underflow totalAssets");
    }

    // -- Pause -------------------------------------------------------------

    function _depositForAlice(uint256 amount) internal {
        _mintUSD8To(alice, amount);
        vm.startPrank(alice);
        usd8.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    function test_DepositPausedBlocksDepositAllowsRedeem() public {
        _depositForAlice(100e18);
        vm.prank(timelock);
        vault.setPauseState(SavingsUSD8.PauseState.DepositPaused);

        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxWithdraw(alice), 100e18);
        assertEq(vault.maxRedeem(alice), 100e18);

        _mintUSD8To(alice, 50e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 50e18);
        vm.expectRevert(abi.encodeWithSelector(SavingsUSD8.Paused.selector, SavingsUSD8.PauseState.DepositPaused));
        vault.deposit(50e18, alice);

        // Redeem still works.
        vault.redeem(100e18, alice, alice);
        vm.stopPrank();
        assertEq(usd8.balanceOf(alice), 150e18);
    }

    function test_WithdrawPausedBlocksRedeemAllowsDeposit() public {
        _depositForAlice(100e18);
        vm.prank(timelock);
        vault.setPauseState(SavingsUSD8.PauseState.WithdrawPaused);

        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SavingsUSD8.Paused.selector, SavingsUSD8.PauseState.WithdrawPaused));
        vault.redeem(100e18, alice, alice);

        // Deposit still works.
        _mintUSD8To(alice, 50e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 50e18);
        vault.deposit(50e18, alice);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), 150e18);
    }

    function test_SystemPausedBlocksAllUserActions() public {
        _depositForAlice(100e18);
        vm.prank(timelock);
        vault.setPauseState(SavingsUSD8.PauseState.SystemPaused);

        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);

        bytes memory err = abi.encodeWithSelector(SavingsUSD8.Paused.selector, SavingsUSD8.PauseState.SystemPaused);

        _mintUSD8To(alice, 50e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 50e18);
        vm.expectRevert(err);
        vault.deposit(50e18, alice);
        vm.expectRevert(err);
        vault.redeem(100e18, alice, alice);
        vm.stopPrank();

        // receiveProfitDistribution blocked.
        _mintUSD8To(reporter, 10e18);
        vm.startPrank(reporter);
        usd8.approve(address(vault), 10e18);
        vm.expectRevert(err);
        vault.receiveProfitDistribution(10e18);
        vm.stopPrank();
    }

    function test_SetPauseStateOnlyRoles() public {
        vm.expectRevert(_unauthorizedAdmin(alice));
        vm.prank(alice);
        vault.setPauseState(SavingsUSD8.PauseState.SystemPaused);
    }

    function test_TimelockCanTransferTimelock() public {
        address newTimelock = address(0xC0FFEE);

        vm.prank(timelock);
        vault.setTimelock(newTimelock);

        assertEq(vault.timelock(), newTimelock);

        // Old timelock loses role-gated access (it is not admin either).
        vm.expectRevert(_unauthorizedAdmin(timelock));
        vm.prank(timelock);
        vault.setPauseState(SavingsUSD8.PauseState.SystemPaused);

        vm.prank(newTimelock);
        vault.setPauseState(SavingsUSD8.PauseState.SystemPaused);
        assertEq(uint256(vault.pauseState()), uint256(SavingsUSD8.PauseState.SystemPaused));
    }

    function test_NonTimelockCannotTransferTimelock() public {
        vm.expectRevert(_unauthorizedTimelock(alice));
        vm.prank(alice);
        vault.setTimelock(alice);
    }

    function test_SetTimelockRejectsZero() public {
        vm.expectRevert(SavingsUSD8.ZeroAddress.selector);
        vm.prank(timelock);
        vault.setTimelock(address(0));
    }

    function test_TimelockCanSetAdmin() public {
        address newAdmin = address(0xC0FFEE);
        MockUSD8Strategy s = new MockUSD8Strategy(usd8);
        _approve(s);

        _mintUSD8To(alice, 10e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 10e18);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        vm.prank(timelock);
        vault.setAdmin(newAdmin);

        assertEq(vault.admin(), newAdmin);

        // New admin holds the fast role; the old admin no longer does.
        vm.prank(newAdmin);
        vault.depositToStrategy(s, 10e18);

        vm.expectRevert(_unauthorizedAdmin(admin));
        vm.prank(admin);
        vault.withdrawFromStrategy(s, 10e18);
    }

    function test_NonTimelockCannotSetAdmin() public {
        vm.expectRevert(_unauthorizedTimelock(alice));
        vm.prank(alice);
        vault.setAdmin(alice);
    }

    function test_SetAdminRejectsZero() public {
        vm.expectRevert(SavingsUSD8.ZeroAddress.selector);
        vm.prank(timelock);
        vault.setAdmin(address(0));
    }

    function test_PauseCanBeCleared() public {
        vm.startPrank(timelock);
        vault.setPauseState(SavingsUSD8.PauseState.SystemPaused);
        // The unpause path must always be reachable, even during SystemPaused.
        vault.setPauseState(SavingsUSD8.PauseState.None);
        vm.stopPrank();
        assertEq(uint256(vault.pauseState()), uint256(SavingsUSD8.PauseState.None));
    }

    // -- NoDepositors guard ------------------------------------------------

    function test_ReceiveProfitDistributionRevertsWhenNoDepositors() public {
        _mintUSD8To(reporter, 10e18);
        vm.startPrank(reporter);
        usd8.approve(address(vault), 10e18);
        vm.expectRevert(SavingsUSD8.NoDepositors.selector);
        vault.receiveProfitDistribution(10e18);
        vm.stopPrank();
    }

    function test_ReceiveProfitDistributionWorksAfterFirstDeposit() public {
        _depositForAlice(100e18);
        _mintUSD8To(reporter, 10e18);
        vm.startPrank(reporter);
        usd8.approve(address(vault), 10e18);
        vault.receiveProfitDistribution(10e18);
        vm.stopPrank();
        assertEq(uint256(vault.pendingProfit()), 10e18);
    }

    // -- Strategy asset mismatch -------------------------------------------

    function test_AddStrategyRejectsWrongUnderlying() public {
        // MockUSD8Strategy reports USD8 as underlying; vault expects USD8 — should work.
        MockUSD8Strategy good = new MockUSD8Strategy(usd8);
        vm.prank(timelock);
        vault.addStrategy(good, type(uint256).max);
        assertEq(vault.strategiesLength(), 1);

        // Wrong-underlying strategy (returns address(0xDEAD)).
        WrongUnderlyingStrategy bad = new WrongUnderlyingStrategy();
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                SavingsUSD8.StrategyAssetMismatch.selector, IStrategy(address(bad)), address(usd8), address(0xDEAD)
            )
        );
        vault.addStrategy(IStrategy(address(bad)), type(uint256).max);
    }
}

/// @dev Strategy whose underlying() returns a non-USD8 / non-USDC address,
///      used to exercise StrategyAssetMismatch in both vaults.
contract WrongUnderlyingStrategy is IStrategy {
    function underlying() external pure override returns (address) {
        return address(0xDEAD);
    }

    function deploy(uint256) external override {}
    function withdraw(uint256) external override {}

    function totalAssets() external pure override returns (uint256) {
        return 0;
    }
}
