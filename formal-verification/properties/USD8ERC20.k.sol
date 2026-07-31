// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";

/// @dev Makes constructor-call rollback observable without predicting a CREATE address.
contract USD8ZeroRegistryDeploymentProbe {
    uint256 public marker;

    function deploy(address implementation) external returns (address proxy) {
        marker = 1;
        proxy = address(new ERC1967Proxy(implementation, abi.encodeCall(USD8.initialize, (Registry(address(0))))));
        marker = 2;
    }
}

/// @notice Foundry/Kontrol initialization and ERC20 integration properties for USD8.
/// @dev Uses production USD8/Registry implementations behind real ERC1967 proxies.
///      This contract is both Registry timelock and Treasury. Successful scalar domains
///      are uint128; rejected-before-arithmetic attempts may remain full-width.
contract USD8ERC20KontrolTest is Test {
    // [C:ADDRESS_REPRESENTATIVE] EVM address-renaming symmetry lets fixed nonzero actors represent each
    // alias class; separate properties below cover distinct, zero, pairwise-alias, and all-equal partitions.
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5EED);
    address internal constant OTHER = address(0x0DDBA11);

    Registry internal registry;
    USD8 internal implementation;
    USD8 internal usd8;

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        implementation = new USD8();
        usd8 = USD8(address(new ERC1967Proxy(address(implementation), abi.encodeCall(USD8.initialize, (registry)))));
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(this));
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _callAs(address caller, bytes memory data) internal returns (bool success, bytes memory returndata) {
        vm.prank(caller);
        return address(usd8).call(data);
    }

    function test_initializationAndStaticIdentity() public view {
        assert(address(usd8.registry()) == address(registry));
        assert(keccak256(bytes(usd8.name())) == keccak256(bytes("USD8")));
        assert(keccak256(bytes(usd8.symbol())) == keccak256(bytes("USD8")));
        assert(usd8.decimals() == 18);
        assert(usd8.totalSupply() == 0);
        assert(usd8.balanceOf(ALICE) == 0);
        assert(usd8.allowance(ALICE, SPENDER) == 0);
        assert(usd8.nonces(ALICE) == 0);
    }

    function test_zeroRegistryConstructorFailureIsAtomic() public {
        USD8 freshImplementation = new USD8();
        USD8ZeroRegistryDeploymentProbe probe = new USD8ZeroRegistryDeploymentProbe();

        (bool success, bytes memory returndata) =
            address(probe).call(abi.encodeCall(USD8ZeroRegistryDeploymentProbe.deploy, (address(freshImplementation))));

        assert(!success);
        assert(_selector(returndata) == Registry.ZeroAddress.selector);
        assert(probe.marker() == 0);
        assert(address(freshImplementation).code.length > 0);
    }

    function test_reinitializeRevertsWithoutChangingState() public {
        (bool success, bytes memory returndata) = address(usd8).call(abi.encodeCall(USD8.initialize, (registry)));

        assert(!success);
        assert(_selector(returndata) == Initializable.InvalidInitialization.selector);
        assert(address(usd8.registry()) == address(registry));
        assert(usd8.totalSupply() == 0);
    }

    function test_directImplementationInitializationIsLocked() public {
        (bool success, bytes memory returndata) =
            address(implementation).call(abi.encodeCall(USD8.initialize, (registry)));

        assert(!success);
        assert(_selector(returndata) == Initializable.InvalidInitialization.selector);
    }

    function test_transferDistinctExactDeltasAndSupplyConservation(
        uint128 senderSeed,
        uint128 recipientSeed,
        uint128 unrelatedSeed,
        uint128 amount
    ) public {
        vm.assume(amount <= senderSeed);

        usd8.mint(ALICE, senderSeed);
        usd8.mint(BOB, recipientSeed);
        usd8.mint(OTHER, unrelatedSeed);
        uint256 supplyBefore = usd8.totalSupply();

        vm.prank(ALICE);
        bool transferred = usd8.transfer(BOB, amount);

        assert(transferred);
        assert(usd8.balanceOf(ALICE) == uint256(senderSeed) - amount);
        assert(usd8.balanceOf(BOB) == uint256(recipientSeed) + amount);
        assert(usd8.balanceOf(OTHER) == unrelatedSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_selfTransferPreservesBalanceAndSupply(uint128 balanceSeed, uint128 amount) public {
        vm.assume(amount > 0);
        vm.assume(amount <= balanceSeed);
        usd8.mint(ALICE, balanceSeed);
        uint256 supplyBefore = usd8.totalSupply();

        vm.prank(ALICE);
        bool transferred = usd8.transfer(ALICE, amount);

        assert(transferred);
        assert(usd8.balanceOf(ALICE) == balanceSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_zeroTransferPreservesNondegenerateState(
        uint128 senderSeed,
        uint128 recipientSeed,
        uint128 unrelatedSeed,
        uint128 allowanceSeed
    ) public {
        usd8.mint(ALICE, senderSeed);
        usd8.mint(BOB, recipientSeed);
        usd8.mint(OTHER, unrelatedSeed);
        vm.prank(ALICE);
        usd8.approve(SPENDER, allowanceSeed);
        uint256 supplyBefore = usd8.totalSupply();

        vm.prank(ALICE);
        bool transferred = usd8.transfer(BOB, 0);

        assert(transferred);
        assert(usd8.balanceOf(ALICE) == senderSeed);
        assert(usd8.balanceOf(BOB) == recipientSeed);
        assert(usd8.balanceOf(OTHER) == unrelatedSeed);
        assert(usd8.allowance(ALICE, SPENDER) == allowanceSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_transferToZeroRevertsAtomically(uint128 balanceSeed, uint256 amount) public {
        usd8.mint(ALICE, balanceSeed);
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) = _callAs(ALICE, abi.encodeCall(IERC20.transfer, (address(0), amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InvalidReceiver.selector);
        assert(usd8.balanceOf(ALICE) == balanceSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_transferInsufficientBalanceRevertsAtomically(
        uint128 senderSeed,
        uint128 recipientSeed,
        uint256 amount
    ) public {
        vm.assume(amount > senderSeed);
        usd8.mint(ALICE, senderSeed);
        usd8.mint(BOB, recipientSeed);
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) = _callAs(ALICE, abi.encodeCall(IERC20.transfer, (BOB, amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InsufficientBalance.selector);
        assert(usd8.balanceOf(ALICE) == senderSeed);
        assert(usd8.balanceOf(BOB) == recipientSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_approveOverwritesAndPreservesUnrelatedAllowance(
        uint128 initialApproval,
        uint128 replacement,
        uint128 unrelatedApproval
    ) public {
        vm.startPrank(ALICE);
        assert(usd8.approve(SPENDER, initialApproval));
        assert(usd8.approve(OTHER, unrelatedApproval));
        assert(usd8.approve(SPENDER, replacement));
        vm.stopPrank();

        assert(usd8.allowance(ALICE, SPENDER) == replacement);
        assert(usd8.allowance(ALICE, OTHER) == unrelatedApproval);
    }

    function test_approveZeroSpenderRevertsAtomically(uint256 amount) public {
        (bool success, bytes memory returndata) = _callAs(ALICE, abi.encodeCall(IERC20.approve, (address(0), amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InvalidSpender.selector);
        assert(usd8.allowance(ALICE, address(0)) == 0);
    }

    function test_transferFromFiniteAllowanceConsumesExactAmount(
        uint128 ownerSeed,
        uint128 recipientSeed,
        uint128 amount,
        uint128 allowanceRemainder
    ) public {
        vm.assume(amount <= ownerSeed);

        usd8.mint(ALICE, ownerSeed);
        usd8.mint(BOB, recipientSeed);
        uint256 approved = uint256(amount) + allowanceRemainder;
        vm.prank(ALICE);
        usd8.approve(SPENDER, approved);
        uint256 supplyBefore = usd8.totalSupply();

        vm.prank(SPENDER);
        bool transferred = usd8.transferFrom(ALICE, BOB, amount);

        assert(transferred);
        assert(usd8.balanceOf(ALICE) == uint256(ownerSeed) - amount);
        assert(usd8.balanceOf(BOB) == uint256(recipientSeed) + amount);
        assert(usd8.allowance(ALICE, SPENDER) == allowanceRemainder);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_transferFromRecipientAsSpenderConsumesAllowanceAndCreditsCaller(
        uint128 ownerSeed,
        uint128 recipientSeed,
        uint128 amount,
        uint128 allowanceRemainder
    ) public {
        vm.assume(amount <= ownerSeed);

        usd8.mint(ALICE, ownerSeed);
        usd8.mint(SPENDER, recipientSeed);
        vm.prank(ALICE);
        usd8.approve(SPENDER, uint256(amount) + allowanceRemainder);

        vm.prank(SPENDER);
        bool transferred = usd8.transferFrom(ALICE, SPENDER, amount);

        assert(transferred);
        assert(usd8.balanceOf(ALICE) == uint256(ownerSeed) - amount);
        assert(usd8.balanceOf(SPENDER) == uint256(recipientSeed) + amount);
        assert(usd8.allowance(ALICE, SPENDER) == allowanceRemainder);
        assert(usd8.totalSupply() == uint256(ownerSeed) + recipientSeed);
    }

    function test_transferFromMaxAllowanceIsRetained(uint128 ownerSeed, uint128 amount) public {
        vm.assume(amount <= ownerSeed);

        usd8.mint(ALICE, ownerSeed);
        vm.prank(ALICE);
        usd8.approve(SPENDER, type(uint256).max);

        vm.prank(SPENDER);
        bool transferred = usd8.transferFrom(ALICE, BOB, amount);

        assert(transferred);
        assert(usd8.balanceOf(ALICE) == uint256(ownerSeed) - amount);
        assert(usd8.balanceOf(BOB) == amount);
        assert(usd8.allowance(ALICE, SPENDER) == type(uint256).max);
        assert(usd8.totalSupply() == ownerSeed);
    }

    function test_transferFromInsufficientAllowanceRollsBackAtomically(
        uint128 ownerSeed,
        uint128 recipientSeed,
        uint128 allowanceSeed,
        uint256 amount
    ) public {
        vm.assume(amount > allowanceSeed);
        vm.assume(amount <= ownerSeed);

        usd8.mint(ALICE, ownerSeed);
        usd8.mint(BOB, recipientSeed);
        vm.prank(ALICE);
        usd8.approve(SPENDER, allowanceSeed);
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) =
            _callAs(SPENDER, abi.encodeCall(IERC20.transferFrom, (ALICE, BOB, amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InsufficientAllowance.selector);
        assert(usd8.balanceOf(ALICE) == ownerSeed);
        assert(usd8.balanceOf(BOB) == recipientSeed);
        assert(usd8.allowance(ALICE, SPENDER) == allowanceSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_transferFromInsufficientBalanceRollsBackAllowanceAtomically(
        uint128 ownerSeed,
        uint128 recipientSeed,
        uint128 amount
    ) public {
        vm.assume(amount > ownerSeed);

        usd8.mint(ALICE, ownerSeed);
        usd8.mint(BOB, recipientSeed);
        vm.prank(ALICE);
        usd8.approve(SPENDER, amount);
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) =
            _callAs(SPENDER, abi.encodeCall(IERC20.transferFrom, (ALICE, BOB, amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InsufficientBalance.selector);
        assert(usd8.balanceOf(ALICE) == ownerSeed);
        assert(usd8.balanceOf(BOB) == recipientSeed);
        // A finite allowance write occurs before `_transfer`; the balance failure
        // must roll that write back with the rest of the transaction.
        assert(usd8.allowance(ALICE, SPENDER) == amount);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_selfTransferFromFiniteAllowanceConsumesAllowanceOnly(
        uint128 balanceSeed,
        uint128 amount,
        uint128 allowanceRemainder
    ) public {
        vm.assume(amount > 0);
        vm.assume(amount <= balanceSeed);

        usd8.mint(ALICE, balanceSeed);
        vm.prank(ALICE);
        usd8.approve(SPENDER, uint256(amount) + allowanceRemainder);
        uint256 supplyBefore = usd8.totalSupply();

        vm.prank(SPENDER);
        bool transferred = usd8.transferFrom(ALICE, ALICE, amount);

        assert(transferred);
        assert(usd8.balanceOf(ALICE) == balanceSeed);
        assert(usd8.allowance(ALICE, SPENDER) == allowanceRemainder);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_transferFromToZeroRollsFiniteAllowanceBack(
        uint128 ownerSeed,
        uint128 amount,
        uint128 allowanceRemainder
    ) public {
        vm.assume(amount > 0);
        vm.assume(amount <= ownerSeed);

        usd8.mint(ALICE, ownerSeed);
        uint256 approved = uint256(amount) + allowanceRemainder;
        vm.prank(ALICE);
        usd8.approve(SPENDER, approved);
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) =
            _callAs(SPENDER, abi.encodeCall(IERC20.transferFrom, (ALICE, address(0), amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InvalidReceiver.selector);
        assert(usd8.balanceOf(ALICE) == ownerSeed);
        assert(usd8.allowance(ALICE, SPENDER) == approved);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_transferFromZeroPositiveAmountFailsAtAllowance(uint128 amount) public {
        vm.assume(amount > 0);

        (bool success, bytes memory returndata) =
            _callAs(SPENDER, abi.encodeCall(IERC20.transferFrom, (address(0), BOB, amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InsufficientAllowance.selector);
        assert(usd8.balanceOf(BOB) == 0);
        assert(usd8.allowance(address(0), SPENDER) == 0);
        assert(usd8.totalSupply() == 0);
    }

    function test_transferFromZeroZeroAmountFailsAtApprover() public {
        (bool success, bytes memory returndata) =
            _callAs(SPENDER, abi.encodeCall(IERC20.transferFrom, (address(0), BOB, 0)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InvalidApprover.selector);
        assert(usd8.balanceOf(BOB) == 0);
        assert(usd8.allowance(address(0), SPENDER) == 0);
        assert(usd8.totalSupply() == 0);
    }

    function test_transferFromOwnerAsSpenderConsumesSelfAllowance(
        uint128 ownerSeed,
        uint128 recipientSeed,
        uint128 amount,
        uint128 allowanceRemainder
    ) public {
        vm.assume(amount <= ownerSeed);

        usd8.mint(ALICE, ownerSeed);
        usd8.mint(BOB, recipientSeed);
        vm.prank(ALICE);
        usd8.approve(ALICE, uint256(amount) + allowanceRemainder);

        vm.prank(ALICE);
        bool transferred = usd8.transferFrom(ALICE, BOB, amount);

        assert(transferred);
        assert(usd8.balanceOf(ALICE) == uint256(ownerSeed) - amount);
        assert(usd8.balanceOf(BOB) == uint256(recipientSeed) + amount);
        assert(usd8.allowance(ALICE, ALICE) == allowanceRemainder);
        assert(usd8.totalSupply() == uint256(ownerSeed) + recipientSeed);
    }

    function test_transferFromAllEqualConsumesSelfAllowanceOnly(
        uint128 balanceSeed,
        uint128 amount,
        uint128 allowanceRemainder
    ) public {
        vm.assume(amount <= balanceSeed);

        usd8.mint(ALICE, balanceSeed);
        vm.prank(ALICE);
        usd8.approve(ALICE, uint256(amount) + allowanceRemainder);

        vm.prank(ALICE);
        bool transferred = usd8.transferFrom(ALICE, ALICE, amount);

        assert(transferred);
        assert(usd8.balanceOf(ALICE) == balanceSeed);
        assert(usd8.allowance(ALICE, ALICE) == allowanceRemainder);
        assert(usd8.totalSupply() == balanceSeed);
    }
}
