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
///      This contract is both Registry timelock and Treasury. Successful state seeds
///      are uint128, while rejected transfer values remain full-width where safe.
contract USD8ERC20KontrolTest is Test {
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

    function test_initializationAndStaticIdentity(address account, address spender) public view {
        assert(address(usd8.registry()) == address(registry));
        assert(keccak256(bytes(usd8.name())) == keccak256(bytes("USD8")));
        assert(keccak256(bytes(usd8.symbol())) == keccak256(bytes("USD8")));
        assert(usd8.decimals() == 18);
        assert(usd8.totalSupply() == 0);
        assert(usd8.balanceOf(account) == 0);
        assert(usd8.allowance(account, spender) == 0);
        assert(usd8.nonces(account) == 0);
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
        address sender,
        address recipient,
        address unrelated,
        uint128 senderSeed,
        uint128 recipientSeed,
        uint128 unrelatedSeed,
        uint128 amount
    ) public {
        vm.assume(sender != address(0));
        vm.assume(recipient != address(0));
        vm.assume(unrelated != address(0));
        vm.assume(sender != recipient);
        vm.assume(sender != unrelated);
        vm.assume(recipient != unrelated);
        vm.assume(amount <= senderSeed);

        usd8.mint(sender, senderSeed);
        usd8.mint(recipient, recipientSeed);
        usd8.mint(unrelated, unrelatedSeed);
        uint256 supplyBefore = usd8.totalSupply();

        vm.prank(sender);
        bool transferred = usd8.transfer(recipient, amount);

        assert(transferred);
        assert(usd8.balanceOf(sender) == uint256(senderSeed) - amount);
        assert(usd8.balanceOf(recipient) == uint256(recipientSeed) + amount);
        assert(usd8.balanceOf(unrelated) == unrelatedSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_selfTransferPreservesBalanceAndSupply(address holder, uint128 balanceSeed, uint128 amount) public {
        vm.assume(holder != address(0));
        vm.assume(amount > 0);
        vm.assume(amount <= balanceSeed);
        usd8.mint(holder, balanceSeed);
        uint256 supplyBefore = usd8.totalSupply();

        vm.prank(holder);
        bool transferred = usd8.transfer(holder, amount);

        assert(transferred);
        assert(usd8.balanceOf(holder) == balanceSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_zeroTransferPreservesNondegenerateState(
        address sender,
        address recipient,
        address unrelated,
        address spender,
        uint128 senderSeed,
        uint128 recipientSeed,
        uint128 unrelatedSeed,
        uint128 allowanceSeed
    ) public {
        vm.assume(sender != address(0));
        vm.assume(recipient != address(0));
        vm.assume(unrelated != address(0));
        vm.assume(spender != address(0));
        vm.assume(sender != recipient);
        vm.assume(sender != unrelated);
        vm.assume(recipient != unrelated);

        usd8.mint(sender, senderSeed);
        usd8.mint(recipient, recipientSeed);
        usd8.mint(unrelated, unrelatedSeed);
        vm.prank(sender);
        usd8.approve(spender, allowanceSeed);
        uint256 supplyBefore = usd8.totalSupply();

        vm.prank(sender);
        bool transferred = usd8.transfer(recipient, 0);

        assert(transferred);
        assert(usd8.balanceOf(sender) == senderSeed);
        assert(usd8.balanceOf(recipient) == recipientSeed);
        assert(usd8.balanceOf(unrelated) == unrelatedSeed);
        assert(usd8.allowance(sender, spender) == allowanceSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_transferToZeroRevertsAtomically(address sender, uint128 balanceSeed, uint256 amount) public {
        vm.assume(sender != address(0));
        usd8.mint(sender, balanceSeed);
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) = _callAs(sender, abi.encodeCall(IERC20.transfer, (address(0), amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InvalidReceiver.selector);
        assert(usd8.balanceOf(sender) == balanceSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_transferInsufficientBalanceRevertsAtomically(
        address sender,
        address recipient,
        uint128 senderSeed,
        uint128 recipientSeed,
        uint256 amount
    ) public {
        vm.assume(sender != address(0));
        vm.assume(recipient != address(0));
        vm.assume(sender != recipient);
        vm.assume(amount > senderSeed);
        usd8.mint(sender, senderSeed);
        usd8.mint(recipient, recipientSeed);
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) = _callAs(sender, abi.encodeCall(IERC20.transfer, (recipient, amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InsufficientBalance.selector);
        assert(usd8.balanceOf(sender) == senderSeed);
        assert(usd8.balanceOf(recipient) == recipientSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_approveOverwritesAndPreservesUnrelatedAllowance(
        address owner,
        address spender,
        address unrelatedSpender,
        uint128 initialApproval,
        uint128 replacement,
        uint128 unrelatedApproval
    ) public {
        vm.assume(owner != address(0));
        vm.assume(spender != address(0));
        vm.assume(unrelatedSpender != address(0));
        vm.assume(spender != unrelatedSpender);

        vm.startPrank(owner);
        assert(usd8.approve(spender, initialApproval));
        assert(usd8.approve(unrelatedSpender, unrelatedApproval));
        assert(usd8.approve(spender, replacement));
        vm.stopPrank();

        assert(usd8.allowance(owner, spender) == replacement);
        assert(usd8.allowance(owner, unrelatedSpender) == unrelatedApproval);
    }

    function test_approveZeroSpenderRevertsAtomically(address owner, uint256 amount) public {
        vm.assume(owner != address(0));

        (bool success, bytes memory returndata) = _callAs(owner, abi.encodeCall(IERC20.approve, (address(0), amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InvalidSpender.selector);
        assert(usd8.allowance(owner, address(0)) == 0);
    }

    function test_transferFromFiniteAllowanceConsumesExactAmount(
        address owner,
        address recipient,
        address spender,
        uint128 ownerSeed,
        uint128 recipientSeed,
        uint128 amount,
        uint128 allowanceRemainder
    ) public {
        vm.assume(owner != address(0));
        vm.assume(recipient != address(0));
        vm.assume(spender != address(0));
        vm.assume(owner != recipient);
        vm.assume(spender != owner);
        vm.assume(amount <= ownerSeed);

        usd8.mint(owner, ownerSeed);
        usd8.mint(recipient, recipientSeed);
        uint256 approved = uint256(amount) + allowanceRemainder;
        vm.prank(owner);
        usd8.approve(spender, approved);
        uint256 supplyBefore = usd8.totalSupply();

        vm.prank(spender);
        bool transferred = usd8.transferFrom(owner, recipient, amount);

        assert(transferred);
        assert(usd8.balanceOf(owner) == uint256(ownerSeed) - amount);
        assert(usd8.balanceOf(recipient) == uint256(recipientSeed) + amount);
        assert(usd8.allowance(owner, spender) == allowanceRemainder);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_transferFromMaxAllowanceIsRetained(
        address owner,
        address recipient,
        address spender,
        uint128 ownerSeed,
        uint128 amount
    ) public {
        vm.assume(owner != address(0));
        vm.assume(recipient != address(0));
        vm.assume(spender != address(0));
        vm.assume(owner != recipient);
        vm.assume(spender != owner);
        vm.assume(amount <= ownerSeed);

        usd8.mint(owner, ownerSeed);
        vm.prank(owner);
        usd8.approve(spender, type(uint256).max);

        vm.prank(spender);
        bool transferred = usd8.transferFrom(owner, recipient, amount);

        assert(transferred);
        assert(usd8.balanceOf(owner) == uint256(ownerSeed) - amount);
        assert(usd8.balanceOf(recipient) == amount);
        assert(usd8.allowance(owner, spender) == type(uint256).max);
        assert(usd8.totalSupply() == ownerSeed);
    }

    function test_transferFromInsufficientAllowanceRollsBackAtomically(
        address owner,
        address recipient,
        address spender,
        uint128 ownerSeed,
        uint128 recipientSeed,
        uint128 allowanceSeed,
        uint256 amount
    ) public {
        vm.assume(owner != address(0));
        vm.assume(recipient != address(0));
        vm.assume(spender != address(0));
        vm.assume(owner != recipient);
        vm.assume(spender != owner);
        vm.assume(amount > allowanceSeed);
        vm.assume(amount <= ownerSeed);

        usd8.mint(owner, ownerSeed);
        usd8.mint(recipient, recipientSeed);
        vm.prank(owner);
        usd8.approve(spender, allowanceSeed);
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) =
            _callAs(spender, abi.encodeCall(IERC20.transferFrom, (owner, recipient, amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InsufficientAllowance.selector);
        assert(usd8.balanceOf(owner) == ownerSeed);
        assert(usd8.balanceOf(recipient) == recipientSeed);
        assert(usd8.allowance(owner, spender) == allowanceSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_transferFromInsufficientBalanceRollsBackAllowanceAtomically(
        address owner,
        address recipient,
        address spender,
        uint128 ownerSeed,
        uint128 recipientSeed,
        uint128 amount
    ) public {
        vm.assume(owner != address(0));
        vm.assume(recipient != address(0));
        vm.assume(spender != address(0));
        vm.assume(owner != recipient);
        vm.assume(spender != owner);
        vm.assume(amount > ownerSeed);

        usd8.mint(owner, ownerSeed);
        usd8.mint(recipient, recipientSeed);
        vm.prank(owner);
        usd8.approve(spender, amount);
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) =
            _callAs(spender, abi.encodeCall(IERC20.transferFrom, (owner, recipient, amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InsufficientBalance.selector);
        assert(usd8.balanceOf(owner) == ownerSeed);
        assert(usd8.balanceOf(recipient) == recipientSeed);
        // A finite allowance write occurs before `_transfer`; the balance failure
        // must roll that write back with the rest of the transaction.
        assert(usd8.allowance(owner, spender) == amount);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_selfTransferFromFiniteAllowanceConsumesAllowanceOnly(
        address owner,
        address spender,
        uint128 balanceSeed,
        uint128 amount,
        uint128 allowanceRemainder
    ) public {
        vm.assume(owner != address(0));
        vm.assume(spender != address(0));
        vm.assume(spender != owner);
        vm.assume(amount > 0);
        vm.assume(amount <= balanceSeed);

        usd8.mint(owner, balanceSeed);
        vm.prank(owner);
        usd8.approve(spender, uint256(amount) + allowanceRemainder);
        uint256 supplyBefore = usd8.totalSupply();

        vm.prank(spender);
        bool transferred = usd8.transferFrom(owner, owner, amount);

        assert(transferred);
        assert(usd8.balanceOf(owner) == balanceSeed);
        assert(usd8.allowance(owner, spender) == allowanceRemainder);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_transferFromToZeroRollsFiniteAllowanceBack(
        address owner,
        address spender,
        uint128 ownerSeed,
        uint128 amount,
        uint128 allowanceRemainder
    ) public {
        vm.assume(owner != address(0));
        vm.assume(spender != address(0));
        vm.assume(spender != owner);
        vm.assume(amount > 0);
        vm.assume(amount <= ownerSeed);

        usd8.mint(owner, ownerSeed);
        uint256 approved = uint256(amount) + allowanceRemainder;
        vm.prank(owner);
        usd8.approve(spender, approved);
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) =
            _callAs(spender, abi.encodeCall(IERC20.transferFrom, (owner, address(0), amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InvalidReceiver.selector);
        assert(usd8.balanceOf(owner) == ownerSeed);
        assert(usd8.allowance(owner, spender) == approved);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_transferFromZeroPositiveAmountFailsAtAllowance(address recipient, address spender, uint128 amount)
        public
    {
        vm.assume(recipient != address(0));
        vm.assume(spender != address(0));
        vm.assume(amount > 0);

        (bool success, bytes memory returndata) =
            _callAs(spender, abi.encodeCall(IERC20.transferFrom, (address(0), recipient, amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InsufficientAllowance.selector);
        assert(usd8.balanceOf(recipient) == 0);
        assert(usd8.allowance(address(0), spender) == 0);
        assert(usd8.totalSupply() == 0);
    }

    function test_transferFromZeroZeroAmountFailsAtApprover(address recipient, address spender) public {
        vm.assume(recipient != address(0));
        vm.assume(spender != address(0));

        (bool success, bytes memory returndata) =
            _callAs(spender, abi.encodeCall(IERC20.transferFrom, (address(0), recipient, 0)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InvalidApprover.selector);
        assert(usd8.balanceOf(recipient) == 0);
        assert(usd8.allowance(address(0), spender) == 0);
        assert(usd8.totalSupply() == 0);
    }

    function test_transferFromOwnerAsSpenderConsumesSelfAllowance(
        address owner,
        address recipient,
        uint128 ownerSeed,
        uint128 recipientSeed,
        uint128 amount,
        uint128 allowanceRemainder
    ) public {
        vm.assume(owner != address(0));
        vm.assume(recipient != address(0));
        vm.assume(owner != recipient);
        vm.assume(amount <= ownerSeed);

        usd8.mint(owner, ownerSeed);
        usd8.mint(recipient, recipientSeed);
        vm.prank(owner);
        usd8.approve(owner, uint256(amount) + allowanceRemainder);

        vm.prank(owner);
        bool transferred = usd8.transferFrom(owner, recipient, amount);

        assert(transferred);
        assert(usd8.balanceOf(owner) == uint256(ownerSeed) - amount);
        assert(usd8.balanceOf(recipient) == uint256(recipientSeed) + amount);
        assert(usd8.allowance(owner, owner) == allowanceRemainder);
        assert(usd8.totalSupply() == uint256(ownerSeed) + recipientSeed);
    }

    function test_transferFromAllEqualConsumesSelfAllowanceOnly(
        address owner,
        uint128 balanceSeed,
        uint128 amount,
        uint128 allowanceRemainder
    ) public {
        vm.assume(owner != address(0));
        vm.assume(amount <= balanceSeed);

        usd8.mint(owner, balanceSeed);
        vm.prank(owner);
        usd8.approve(owner, uint256(amount) + allowanceRemainder);

        vm.prank(owner);
        bool transferred = usd8.transferFrom(owner, owner, amount);

        assert(transferred);
        assert(usd8.balanceOf(owner) == balanceSeed);
        assert(usd8.allowance(owner, owner) == allowanceRemainder);
        assert(usd8.totalSupply() == balanceSeed);
    }
}
