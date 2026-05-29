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
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Minimal v2 implementation used to exercise the upgrade path.
contract USD8V2 is USD8 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract USD8Test is Test {
    USD8 impl;
    USD8 usd8; // proxy, accessed as USD8

    address admin = address(0xC0DE);
    address treasury = address(0xA11CE);
    address alice = address(0xBEEF);
    address newTreasury = address(0xB0B);
    address newAdmin = address(0xD00D);

    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);

    function _deployProxy(address _admin, address _treasury) internal returns (USD8) {
        bytes memory init = abi.encodeCall(USD8.initialize, (_admin, _treasury));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        return USD8(address(proxy));
    }

    function _unauthorizedAdmin(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(USD8.UnauthorizedAdmin.selector, account);
    }

    function setUp() public {
        impl = new USD8();
        usd8 = _deployProxy(admin, treasury);
    }

    function test_AuthorityWiring() public view {
        assertEq(usd8.admin(), admin);
        assertEq(usd8.treasury(), treasury);
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

    function test_InitializeRejectsZeroAdmin() public {
        vm.expectRevert(USD8.ZeroAddress.selector);
        _deployProxy(address(0), treasury);
    }

    function test_InitializeRejectsZeroTreasury() public {
        vm.expectRevert(USD8.ZeroAddress.selector);
        _deployProxy(admin, address(0));
    }

    function test_InitializeOnlyOnce() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        usd8.initialize(admin, treasury);
    }

    function test_ImplementationDisabled() public {
        // Direct calls to the implementation must not be initializable.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(admin, treasury);
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
        vm.expectRevert(abi.encodeWithSelector(USD8.UnauthorizedTreasury.selector, newTreasury));
        vm.prank(newTreasury);
        usd8.mint(alice, 1e18);

        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(usd8));
        emit TreasuryChanged(treasury, newTreasury);
        usd8.setTreasury(newTreasury);

        assertEq(usd8.treasury(), newTreasury);

        vm.prank(newTreasury);
        usd8.mint(alice, 1e18);
        assertEq(usd8.balanceOf(alice), 1e18);

        vm.expectRevert(abi.encodeWithSelector(USD8.UnauthorizedTreasury.selector, treasury));
        vm.prank(treasury);
        usd8.mint(alice, 1e18);
    }

    function test_SetTreasuryRejectsZero() public {
        vm.expectRevert(USD8.ZeroAddress.selector);
        vm.prank(admin);
        usd8.setTreasury(address(0));
    }

    function test_NonAdminCannotSetTreasury() public {
        vm.expectRevert(_unauthorizedAdmin(treasury));
        vm.prank(treasury);
        usd8.setTreasury(newTreasury);
    }

    function test_AdminCanBeTransferred() public {
        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(usd8));
        emit AdminChanged(admin, newAdmin);
        usd8.setAdmin(newAdmin);

        assertEq(usd8.admin(), newAdmin);

        vm.expectRevert(_unauthorizedAdmin(admin));
        vm.prank(admin);
        usd8.setTreasury(newTreasury);

        vm.prank(newAdmin);
        usd8.setTreasury(newTreasury);
        assertEq(usd8.treasury(), newTreasury);
    }

    function test_SetAdminRejectsZero() public {
        vm.expectRevert(USD8.ZeroAddress.selector);
        vm.prank(admin);
        usd8.setAdmin(address(0));
    }

    function test_NonAdminCannotSetAdmin() public {
        vm.expectRevert(_unauthorizedAdmin(treasury));
        vm.prank(treasury);
        usd8.setAdmin(newAdmin);
    }

    // ─────────────────── UUPS upgrade path ───────────────────

    function test_AdminCanUpgrade() public {
        USD8V2 v2 = new USD8V2();
        vm.prank(admin);
        usd8.upgradeToAndCall(address(v2), "");
        assertEq(USD8V2(address(usd8)).version(), 2);
        assertEq(usd8.treasury(), treasury);
    }

    function test_StatePreservedAcrossUpgrade() public {
        vm.prank(treasury);
        usd8.mint(alice, 500e18);

        USD8V2 v2 = new USD8V2();
        vm.prank(admin);
        usd8.upgradeToAndCall(address(v2), "");

        assertEq(usd8.balanceOf(alice), 500e18);
        assertEq(usd8.totalSupply(), 500e18);
        assertEq(usd8.treasury(), treasury);
    }

    function test_NonAdminCannotUpgrade() public {
        USD8V2 v2 = new USD8V2();
        vm.expectRevert(_unauthorizedAdmin(treasury));
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
