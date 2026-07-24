// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";

contract USD8EventsSweepToken is ERC20 {
    constructor() ERC20("Event Sweep Token", "EST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Compatible production-derived candidate used to prove the complete
///      upgradeToAndCall log order, including its reinitializer's logs.
contract USD8EventsV2 is USD8 {
    event UpgradeInitialized(uint256 value);

    uint256 public upgradeValue;

    function initializeV2(uint256 value) external reinitializer(2) {
        upgradeValue = value;
        emit UpgradeInitialized(value);
    }
}

/// @notice Exact production-log properties for USD8 behind real ERC1967 proxies.
/// @dev Every expectation pins the emitting contract, indexed topics, and data.
///      Symbolic successful amounts are uint128 to keep arithmetic tractable.
contract USD8EventsKontrolTest is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 internal constant OWNER_KEY = 0xA11CE;
    address internal constant ETH_RECIPIENT = address(0xBEEF);

    event RegistryChanged(address indexed oldRegistry, address indexed newRegistry);
    event Initialized(uint64 version);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event ETHSwept(address indexed to, uint256 amount);
    event TokenSwept(address indexed token, address indexed to, uint256 amount);
    event Upgraded(address indexed implementation);
    event UpgradeInitialized(uint256 value);

    Registry internal registry;
    USD8 internal usd8;
    address internal owner;

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
        owner = vm.addr(OWNER_KEY);
    }

    function _permitDigest(address spender, uint256 value, uint256 deadline) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, usd8.nonces(owner), deadline));
        return keccak256(abi.encodePacked("\x19\x01", usd8.DOMAIN_SEPARATOR(), structHash));
    }

    function test_initializeEmitsRegistryChangedThenInitialized() public {
        // A harmless production delegatecall satisfies ERC1967Proxy's non-empty-data
        // deployment guard while deliberately leaving the proxy uninitialized.
        USD8 fresh = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeWithSignature("name()"))));

        vm.expectEmit(true, true, false, true, address(fresh));
        emit RegistryChanged(address(0), address(registry));
        vm.expectEmit(false, false, false, true, address(fresh));
        emit Initialized(1);
        fresh.initialize(registry);
    }

    function test_mintEmitsTransferFromZero(address recipient, uint128 amount) public {
        vm.assume(recipient != address(0));

        vm.expectEmit(true, true, false, true, address(usd8));
        emit Transfer(address(0), recipient, amount);
        usd8.mint(recipient, amount);
    }

    function test_burnEmitsTransferToZero(address holder, uint128 amount) public {
        vm.assume(holder != address(0));
        usd8.mint(holder, amount);

        vm.expectEmit(true, true, false, true, address(usd8));
        emit Transfer(holder, address(0), amount);
        usd8.burn(holder, amount);
    }

    function test_transferEmitsTransfer(address sender, address recipient, uint128 balance, uint128 amount) public {
        vm.assume(sender != address(0));
        vm.assume(recipient != address(0));
        vm.assume(sender != recipient);
        vm.assume(amount <= balance);
        usd8.mint(sender, balance);

        vm.expectEmit(true, true, false, true, address(usd8));
        emit Transfer(sender, recipient, amount);
        vm.prank(sender);
        usd8.transfer(recipient, amount);
    }

    function test_approveEmitsApproval(address tokenOwner, address spender, uint256 amount) public {
        vm.assume(tokenOwner != address(0));
        vm.assume(spender != address(0));

        vm.expectEmit(true, true, false, true, address(usd8));
        emit Approval(tokenOwner, spender, amount);
        vm.prank(tokenOwner);
        usd8.approve(spender, amount);
    }

    function test_permitEmitsApproval(address spender, uint256 value, uint256 deadline) public {
        vm.assume(spender != address(0));
        vm.assume(deadline >= block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, _permitDigest(spender, value, deadline));

        vm.expectEmit(true, true, false, true, address(usd8));
        emit Approval(owner, spender, value);
        usd8.permit(owner, spender, value, deadline, v, r, s);
    }

    function test_sweepETHEmitsETHSwept(uint128 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(usd8), amount);

        vm.expectEmit(true, false, false, true, address(usd8));
        emit ETHSwept(ETH_RECIPIENT, amount);
        usd8.sweepETH(payable(ETH_RECIPIENT));
    }

    function test_sweepTokenEmitsTransferThenTokenSwept(address recipient, uint128 amount) public {
        vm.assume(recipient != address(0));
        vm.assume(recipient != address(usd8));
        vm.assume(amount > 0);
        USD8EventsSweepToken token = new USD8EventsSweepToken();
        token.mint(address(usd8), amount);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(usd8), recipient, amount);
        vm.expectEmit(true, true, false, true, address(usd8));
        emit TokenSwept(address(token), recipient, amount);
        usd8.sweepToken(IERC20(address(token)), recipient);
    }

    function test_compatibleUpgradeEmitsUpgradedThenInitializerLogs(uint128 value) public {
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
