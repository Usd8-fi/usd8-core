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
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {USD8} from "../../src/USD8.sol";
import {SavingsUSD8} from "../../src/SavingsUSD8.sol";
import {Registry} from "../../src/Registry.sol";
import {Managed} from "../../src/Managed.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Minimal v2 implementation used to exercise the UUPS upgrade path.
contract SavingsUSD8V2 is SavingsUSD8 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract SavingsUSD8Test is Test {
    Registry authority;
    USD8 usd8;
    SavingsUSD8 impl;
    SavingsUSD8 vault; // proxy

    address timelock = address(0xA11CE);
    address admin = address(0x57A7);
    address usd8Treasury = address(this); // test contract mints directly.
    address alice = address(0xBEEF);
    address reporter = address(0xDA7A);

    uint64 constant UNLOCK = 7 days;

    function _unauthorizedTimelock(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, account);
    }

    function _unauthorizedAdmin(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, account);
    }

    function setUp() public {
        authority = new Registry(timelock, admin, 8000);
        USD8 implUSD8 = new USD8();
        bytes memory usd8Init = abi.encodeCall(USD8.initialize, (authority, usd8Treasury));
        usd8 = USD8(address(new ERC1967Proxy(address(implUSD8), usd8Init)));

        impl = new SavingsUSD8();
        bytes memory init = abi.encodeCall(SavingsUSD8.initialize, (authority, usd8));
        vault = SavingsUSD8(address(new ERC1967Proxy(address(impl), init)));
    }

    function _mintUSD8To(address to, uint256 amount) internal {
        // Test contract is USD8's configured treasury; can mint directly.
        usd8.mint(to, amount);
    }

    function _depositForAlice(uint256 amount) internal {
        _mintUSD8To(alice, amount);
        vm.startPrank(alice);
        usd8.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    // -- Basics ------------------------------------------------------------

    function test_InitializeWiring() public view {
        assertEq(address(vault.asset()), address(usd8));
        assertEq(authority.timelock(), timelock);
        assertTrue(authority.isAdmin(admin));
        assertEq(vault.profitMaxUnlockTime(), UNLOCK);
        assertEq(vault.name(), "Savings USD8");
        assertEq(vault.symbol(), "sUSD8");
    }

    function test_InitializeRejectsZeroAsset() public {
        bytes memory init = abi.encodeCall(SavingsUSD8.initialize, (authority, USD8(address(0))));
        vm.expectRevert(Managed.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_InitializeOnlyOnce() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(authority, usd8);
    }

    function test_ImplementationDisabled() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(authority, usd8);
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
        _depositForAlice(100e18);

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

    /// @dev Unvested profit is excluded from totalAssets, so a redeem can never
    ///      spend below it — the buffer stays idle without any strategy claw-back.
    function test_WithdrawKeepsUnvestedProfitIdle() public {
        _depositForAlice(100e18);

        _mintUSD8To(reporter, 20e18);
        vm.startPrank(reporter);
        usd8.approve(address(vault), 20e18);
        vault.receiveProfitDistribution(20e18);
        vm.stopPrank();

        // Immediately redeem half the shares. totalAssets == 100 (profit unvested),
        // so alice's 100 shares are worth 100 USD8; 50 shares → 50 USD8.
        vm.prank(alice);
        vault.redeem(50e18, alice, alice);

        assertEq(usd8.balanceOf(alice), 50e18);
        assertEq(usd8.balanceOf(address(vault)), vault.unvestedProfit() + 50e18, "unvested buffer remains idle");
    }

    // -- Pause -------------------------------------------------------------

    function test_PausedBlocksAllUserActions() public {
        _depositForAlice(100e18);
        vm.prank(timelock);
        authority.setPaused(address(vault), true);

        // All four max* views report 0 while paused.
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);

        _mintUSD8To(alice, 50e18);
        vm.startPrank(alice);
        usd8.approve(address(vault), 50e18);
        vm.expectRevert(Registry.Paused.selector);
        vault.deposit(50e18, alice);
        vm.expectRevert(Registry.Paused.selector);
        vault.redeem(100e18, alice, alice);
        vm.stopPrank();

        // receiveProfitDistribution blocked too.
        _mintUSD8To(reporter, 10e18);
        vm.startPrank(reporter);
        usd8.approve(address(vault), 10e18);
        vm.expectRevert(Registry.Paused.selector);
        vault.receiveProfitDistribution(10e18);
        vm.stopPrank();

        // Unpause restores deposit/redeem.
        vm.prank(timelock);
        authority.setPaused(address(vault), false);
        vm.prank(alice);
        vault.redeem(100e18, alice, alice);
        assertEq(usd8.balanceOf(alice), 150e18);
    }

    function test_SetPausedOnlyRoles() public {
        vm.expectRevert(_unauthorizedAdmin(alice));
        vm.prank(alice);
        authority.setPaused(address(vault), true);
    }

    function test_TimelockCanTransferTimelock() public {
        address newTimelock = address(0xC0FFEE);

        vm.prank(timelock);
        authority.setTimelock(newTimelock);

        assertEq(authority.timelock(), newTimelock);

        // Old timelock loses role-gated access (it is not admin either).
        vm.expectRevert(_unauthorizedAdmin(timelock));
        vm.prank(timelock);
        authority.setPaused(address(vault), true);

        vm.prank(newTimelock);
        authority.setPaused(address(vault), true);
        assertTrue(authority.paused(address(vault)));
    }

    function test_NonTimelockCannotTransferTimelock() public {
        vm.expectRevert(_unauthorizedTimelock(alice));
        vm.prank(alice);
        authority.setTimelock(alice);
    }

    function test_SetTimelockRejectsZero() public {
        vm.expectRevert(Registry.ZeroAddress.selector);
        vm.prank(timelock);
        authority.setTimelock(address(0));
    }

    function test_TimelockCanSetAdmin() public {
        address newAdmin = address(0xC0FFEE);

        vm.prank(timelock);
        authority.setAdmin(newAdmin, true);
        assertTrue(authority.isAdmin(newAdmin));

        // New admin holds the fast role (setPaused is admin-or-timelock).
        vm.prank(newAdmin);
        authority.setPaused(address(vault), true);

        // Timelock can remove an admin; the removed one loses access.
        vm.prank(timelock);
        authority.setAdmin(admin, false);
        vm.expectRevert(_unauthorizedAdmin(admin));
        vm.prank(admin);
        authority.setPaused(address(vault), false);
    }

    function test_NonTimelockCannotSetAdmin() public {
        vm.expectRevert(_unauthorizedTimelock(alice));
        vm.prank(alice);
        authority.setAdmin(alice, true);
    }

    function test_SetAdminRejectsZero() public {
        vm.expectRevert(Registry.ZeroAddress.selector);
        vm.prank(timelock);
        authority.setAdmin(address(0), true);
    }

    function test_PauseCanBeCleared() public {
        vm.startPrank(timelock);
        authority.setPaused(address(vault), true);
        // The unpause path must always be reachable, even while paused.
        authority.setPaused(address(vault), false);
        vm.stopPrank();
        assertFalse(authority.paused(address(vault)));
    }

    // -- Sweep -------------------------------------------------------------

    function test_SweepStrayTokenButNotAsset() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(vault), 5e18);
        vm.prank(admin);
        vault.sweepToken(IERC20(address(stray)), alice);
        assertEq(stray.balanceOf(alice), 5e18);

        // The underlying asset is protected (cap 0).
        _depositForAlice(100e18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Managed.NothingToSweep.selector, address(usd8)));
        vault.sweepToken(IERC20(address(usd8)), alice);
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

    // -- UUPS upgrade path -------------------------------------------------

    function test_TimelockCanUpgrade() public {
        _depositForAlice(100e18);

        SavingsUSD8V2 v2 = new SavingsUSD8V2();
        vm.prank(timelock);
        vault.upgradeToAndCall(address(v2), "");

        assertEq(SavingsUSD8V2(address(vault)).version(), 2);
        // State survives.
        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(address(vault.asset()), address(usd8));
    }

    function test_NonTimelockCannotUpgrade() public {
        SavingsUSD8V2 v2 = new SavingsUSD8V2();
        vm.expectRevert(_unauthorizedTimelock(admin));
        vm.prank(admin);
        vault.upgradeToAndCall(address(v2), "");
    }
}
