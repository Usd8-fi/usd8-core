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
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {Registry} from "../src/Registry.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Minimal v2 implementation used to exercise the upgrade path.
contract USD8V2 is USD8 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract USD8Test is Test {
    Registry registry;
    USD8 impl;
    USD8 usd8; // proxy, accessed as USD8

    address timelock = address(0xC0DE);
    address treasury = address(0xA11CE);
    address alice = address(0xBEEF);
    address newTreasury = address(0xB0B);
    address newTimelock = address(0xD00D);

    event TimelockChanged(address indexed oldTimelock, address indexed newTimelock);
    event TreasurySet(address indexed oldTreasury, address indexed newTreasury);

    function _deployProxy() internal returns (USD8) {
        bytes memory init = abi.encodeCall(USD8.initialize, (registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        return USD8(address(proxy));
    }

    function _deployBoundTreasury() internal returns (Treasury) {
        return
            Treasury(
                address(new ERC1967Proxy(address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry))))
            );
    }

    function _unauthorizedTimelock(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, account);
    }

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (timelock, timelock)))
            )
        ); // USD8 uses only the timelock role
        impl = new USD8();
        usd8 = _deployProxy();
        vm.startPrank(timelock);
        registry.setUsd8(address(usd8));
        registry.setTreasury(treasury);
        vm.stopPrank();
    }

    function test_RegistryWiring() public view {
        assertEq(registry.timelock(), timelock);
        assertEq(usd8.treasury(), treasury);
    }

    function test_TimelockCanSetCanonicalTopology() public {
        address savings = makeAddr("sUSD8");
        address oracle = makeAddr("USD8 price oracle");

        vm.startPrank(timelock);
        registry.setUsd8(address(usd8));
        registry.setTreasury(newTreasury);
        registry.setSavingsVault(savings);
        registry.setUsd8PriceOracle(oracle);
        vm.stopPrank();

        assertEq(registry.usd8(), address(usd8));
        assertEq(registry.treasury(), newTreasury);
        assertEq(registry.savingsVault(), savings);
        assertEq(registry.usd8PriceOracle(), oracle);
    }

    function test_AdminCannotSetCanonicalTopology() public {
        vm.prank(timelock);
        registry.setAdmin(alice, true);

        vm.startPrank(alice);
        vm.expectRevert(_unauthorizedTimelock(alice));
        registry.setUsd8(alice);
        vm.expectRevert(_unauthorizedTimelock(alice));
        registry.setTreasury(alice);
        vm.expectRevert(_unauthorizedTimelock(alice));
        registry.setSavingsVault(alice);
        vm.expectRevert(_unauthorizedTimelock(alice));
        registry.setUsd8PriceOracle(alice);
        vm.stopPrank();
    }

    function test_TreasuryCanMintBurn() public {
        vm.startPrank(treasury);
        usd8.mint(alice, 1_000e18);
        assertEq(usd8.balanceOf(alice), 1_000e18);
        usd8.burn(alice, 400e18);
        assertEq(usd8.balanceOf(alice), 600e18);
        assertEq(usd8.totalSupply(), 600e18);
        vm.stopPrank();
    }

    function test_NonTreasuryCannotMint() public {
        vm.expectRevert(abi.encodeWithSelector(USD8.UnauthorizedTreasury.selector, alice));
        vm.prank(alice);
        usd8.mint(alice, 1e18);
    }

    function test_NonTreasuryCannotBurn() public {
        vm.prank(treasury);
        usd8.mint(alice, 1e18);
        vm.expectRevert(abi.encodeWithSelector(USD8.UnauthorizedTreasury.selector, alice));
        vm.prank(alice);
        usd8.burn(alice, 1e18);
    }

    function test_InitializeRejectsZeroRegistry() public {
        vm.expectRevert(Registry.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(USD8.initialize, (Registry(address(0)))));
    }

    function test_InitializeOnlyOnce() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        usd8.initialize(registry);
    }

    function test_ImplementationDisabled() public {
        // Direct calls to the implementation must not be initializable.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(registry);
    }

    function test_MintToZeroReverts() public {
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        usd8.mint(address(0), 1e18);
    }

    function test_BurnFromZeroReverts() public {
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        usd8.burn(address(0), 1e18);
    }

    function test_AdminCanSetTreasury() public {
        Treasury candidate = _deployBoundTreasury();

        vm.expectRevert(abi.encodeWithSelector(USD8.UnauthorizedTreasury.selector, address(candidate)));
        vm.prank(address(candidate));
        usd8.mint(alice, 1e18);

        vm.prank(timelock);
        vm.expectEmit(true, true, false, true, address(registry));
        emit TreasurySet(treasury, address(candidate));
        registry.setTreasury(address(candidate));

        assertEq(usd8.treasury(), address(candidate));

        vm.prank(address(candidate));
        usd8.mint(alice, 1e18);
        assertEq(usd8.balanceOf(alice), 1e18);

        vm.expectRevert(abi.encodeWithSelector(USD8.UnauthorizedTreasury.selector, treasury));
        vm.prank(treasury);
        usd8.mint(alice, 1e18);
    }

    function test_SetTreasuryAllowsTimelockToCorrectAddressBeforeIssuance() public {
        vm.prank(timelock);
        registry.setTreasury(newTreasury);

        assertEq(usd8.treasury(), newTreasury);
    }

    function test_TimelockCanRotateTreasuryWithLiveSupply() public {
        vm.prank(treasury);
        usd8.mint(alice, 1e18);
        assertEq(usd8.totalSupply(), 1e18);

        vm.prank(timelock);
        registry.setTreasury(newTreasury);
        assertEq(usd8.treasury(), newTreasury);

        vm.expectRevert(abi.encodeWithSelector(USD8.UnauthorizedTreasury.selector, treasury));
        vm.prank(treasury);
        usd8.mint(alice, 1e18);

        vm.prank(newTreasury);
        usd8.mint(alice, 1e18);
        assertEq(usd8.totalSupply(), 2e18);
    }

    function test_SetTreasuryRejectsZero() public {
        vm.expectRevert(Registry.ZeroAddress.selector);
        vm.prank(timelock);
        registry.setTreasury(address(0));
    }

    function test_NonAdminCannotSetTreasury() public {
        vm.expectRevert(_unauthorizedTimelock(treasury));
        vm.prank(treasury);
        registry.setTreasury(newTreasury);
    }

    function test_TimelockCanBeTransferred() public {
        Treasury candidate = _deployBoundTreasury();
        vm.prank(timelock);
        vm.expectEmit(true, true, false, true, address(registry));
        emit TimelockChanged(timelock, newTimelock);
        registry.setTimelock(newTimelock);

        assertEq(registry.timelock(), newTimelock);

        // Old timelock can no longer act.
        vm.expectRevert(_unauthorizedTimelock(timelock));
        vm.prank(timelock);
        registry.setTreasury(address(candidate));

        vm.prank(newTimelock);
        registry.setTreasury(address(candidate));
        assertEq(usd8.treasury(), address(candidate));
    }

    function test_SetTimelockRejectsZero() public {
        vm.expectRevert(Registry.ZeroAddress.selector);
        vm.prank(timelock);
        registry.setTimelock(address(0));
    }

    function test_NonTimelockCannotSetTimelock() public {
        vm.expectRevert(_unauthorizedTimelock(treasury));
        vm.prank(treasury);
        registry.setTimelock(newTimelock);
    }

    function test_SweepStrayToken() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(usd8), 5e18); // foreign token mis-sent to the USD8 contract
        vm.prank(timelock);
        usd8.sweepToken(IERC20(address(stray)), alice);
        assertEq(stray.balanceOf(alice), 5e18);
        assertEq(stray.balanceOf(address(usd8)), 0);
    }

    // ─────────────────── UUPS upgrade path ───────────────────

    function test_AdminCanUpgrade() public {
        USD8V2 v2 = new USD8V2();
        vm.prank(timelock);
        usd8.upgradeToAndCall(address(v2), "");
        assertEq(USD8V2(address(usd8)).version(), 2);
        assertEq(usd8.treasury(), treasury);
    }

    function test_StatePreservedAcrossUpgrade() public {
        vm.prank(treasury);
        usd8.mint(alice, 500e18);

        USD8V2 v2 = new USD8V2();
        vm.prank(timelock);
        usd8.upgradeToAndCall(address(v2), "");

        assertEq(usd8.balanceOf(alice), 500e18);
        assertEq(usd8.totalSupply(), 500e18);
        assertEq(usd8.treasury(), treasury);
    }

    function test_NonAdminCannotUpgrade() public {
        USD8V2 v2 = new USD8V2();
        vm.expectRevert(_unauthorizedTimelock(treasury));
        vm.prank(treasury);
        usd8.upgradeToAndCall(address(v2), "");
    }

    // -- ERC20Permit (EIP-2612) -------------------------------------------

    function test_PermitSetsAllowance() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("permitOwner");
        address spender = address(0xCAFE);
        uint256 value = 123e18;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(treasury);
        usd8.mint(owner, value);

        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, value, usd8.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usd8.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        usd8.permit(owner, spender, value, deadline, v, r, s);
        assertEq(usd8.allowance(owner, spender), value);
        assertEq(usd8.nonces(owner), 1);
    }

    function test_PermitRejectsExpiredDeadline() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("permitOwner");
        address spender = address(0xCAFE);
        uint256 deadline = block.timestamp - 1;

        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(permitTypehash, owner, spender, uint256(1), usd8.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usd8.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        vm.expectRevert();
        usd8.permit(owner, spender, 1, deadline, v, r, s);
    }
}
