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
    address internal constant OWNER = address(0xA11CE55);
    address internal constant SENDER = address(0xA11CE);
    address internal constant RECIPIENT = address(0xB0B);
    address internal constant SPENDER = address(0xCAFE);
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
    }

    function _deployUninitializedUsd8() internal returns (USD8 fresh) {
        // A harmless production delegatecall satisfies ERC1967Proxy's non-empty-data
        // deployment guard while deliberately leaving the proxy uninitialized.
        fresh = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeWithSignature("name()"))));
    }

    /// @dev Kontrol v1.0.255 stores one expectEmit and cannot advance past a prior
    ///      log. Later-log presence and ordering are checked by the dedicated
    ///      Foundry regression in `formal-verification/regressions`.
    function test_initializeEmitsRegistryChanged() public {
        USD8 fresh = _deployUninitializedUsd8();
        vm.expectEmit(true, true, false, true, address(fresh));
        emit RegistryChanged(address(0), address(registry));
        fresh.initialize(registry);
    }

    // [C:ADDRESS_REPRESENTATIVE] Event topics depend only on actor equality;
    // zero/self/distinct transition semantics are proved in USD8ERC20.k.sol.
    function test_mintEmitsTransferFromZero(uint128 amount) public {
        vm.expectEmit(true, true, false, true, address(usd8));
        emit Transfer(address(0), RECIPIENT, amount);
        usd8.mint(RECIPIENT, amount);
    }

    function test_burnEmitsTransferToZero(uint128 amount) public {
        usd8.mint(RECIPIENT, amount);

        vm.expectEmit(true, true, false, true, address(usd8));
        emit Transfer(RECIPIENT, address(0), amount);
        usd8.burn(RECIPIENT, amount);
    }

    function test_transferEmitsTransfer(uint128 balance, uint128 amount) public {
        vm.assume(amount <= balance);
        usd8.mint(SENDER, balance);

        vm.expectEmit(true, true, false, true, address(usd8));
        emit Transfer(SENDER, RECIPIENT, amount);
        vm.prank(SENDER);
        usd8.transfer(RECIPIENT, amount);
    }

    function test_approveEmitsApproval(uint256 amount) public {
        vm.expectEmit(true, true, false, true, address(usd8));
        emit Approval(OWNER, SPENDER, amount);
        vm.prank(OWNER);
        usd8.approve(SPENDER, amount);
    }

    function test_permitEmitsApproval(uint256 value, uint256 deadline) public {
        vm.assume(deadline >= block.timestamp);
        // [C:ECDSA_CORRECT] Signature validity is discharged by USD8Permit.k.sol;
        // this event obligation models ecrecover as returning OWNER.
        vm.mockCall(address(1), bytes(""), abi.encode(OWNER));

        vm.expectEmit(true, true, false, true, address(usd8));
        emit Approval(OWNER, SPENDER, value);
        usd8.permit(OWNER, SPENDER, value, deadline, 27, bytes32(uint256(1)), bytes32(uint256(1)));
    }

    function test_sweepETHEmitsETHSwept(uint128 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(usd8), amount);

        vm.expectEmit(true, false, false, true, address(usd8));
        emit ETHSwept(ETH_RECIPIENT, amount);
        usd8.sweepETH(payable(ETH_RECIPIENT));
    }

    function test_sweepTokenEmitsTransfer(uint128 amount) public {
        vm.assume(amount > 0);
        USD8EventsSweepToken token = new USD8EventsSweepToken();
        token.mint(address(usd8), amount);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(usd8), RECIPIENT, amount);
        usd8.sweepToken(IERC20(address(token)), RECIPIENT);
    }

    function test_compatibleUpgradeEmitsUpgraded(uint128 value) public {
        USD8EventsV2 candidate = new USD8EventsV2();

        vm.expectEmit(true, false, false, true, address(usd8));
        emit Upgraded(address(candidate));
        usd8.upgradeToAndCall(address(candidate), abi.encodeCall(USD8EventsV2.initializeV2, (value)));
    }
}
