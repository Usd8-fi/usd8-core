// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";

/// @dev A distinct call frame used as the newly authorized Treasury after rotation.
contract USD8TokenCaller {
    function callMint(USD8 token, address recipient, uint256 amount)
        external
        returns (bool success, bytes memory returndata)
    {
        return address(token).call(abi.encodeCall(USD8.mint, (recipient, amount)));
    }

    function callBurn(USD8 token, address holder, uint256 amount)
        external
        returns (bool success, bytes memory returndata)
    {
        return address(token).call(abi.encodeCall(USD8.burn, (holder, amount)));
    }
}

/// @notice Foundry/Kontrol properties for USD8's Registry-resolved mint/burn authority.
/// @dev Uses the production implementations behind real ERC1967 proxies. This
///      contract is both the timelock and initial Treasury. Kontrol v1.0.255
///      supports symbolic `vm.prank`, which quantifies unauthorized properties
///      over every caller except the current Treasury. Authorized state seeds and
///      amounts are uint128 so their sums cannot overflow uint256.
contract USD8TokenKontrolTest is Test {
    Registry internal registry;
    USD8 internal usd8;
    USD8TokenCaller internal otherCaller;

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        otherCaller = new USD8TokenCaller();

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

    function test_unauthorizedMintRevertsAtomically(address unauthorizedCaller, address recipient, uint256 amount)
        public
    {
        vm.assume(unauthorizedCaller != usd8.treasury());

        uint256 supplyBefore = usd8.totalSupply();
        uint256 balanceBefore = usd8.balanceOf(recipient);

        vm.prank(unauthorizedCaller);
        (bool success, bytes memory returndata) = address(usd8).call(abi.encodeCall(USD8.mint, (recipient, amount)));

        assert(!success);
        assert(_selector(returndata) == USD8.UnauthorizedTreasury.selector);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(recipient) == balanceBefore);
    }

    function test_unauthorizedBurnRevertsAtomically(
        address unauthorizedCaller,
        address holder,
        uint128 holderBalanceSeed,
        uint256 amount
    ) public {
        vm.assume(unauthorizedCaller != usd8.treasury());
        vm.assume(holder != address(0));
        vm.assume(holderBalanceSeed > 0);

        usd8.mint(holder, holderBalanceSeed);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 balanceBefore = usd8.balanceOf(holder);

        vm.prank(unauthorizedCaller);
        (bool success, bytes memory returndata) = address(usd8).call(abi.encodeCall(USD8.burn, (holder, amount)));

        assert(!success);
        assert(_selector(returndata) == USD8.UnauthorizedTreasury.selector);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(holder) == balanceBefore);
    }

    function test_authorizedMintExactDeltaFromExistingState(
        address recipient,
        address unrelatedHolder,
        uint128 recipientBalanceSeed,
        uint128 unrelatedSupplySeed,
        uint128 mintAmount
    ) public {
        vm.assume(recipient != address(0));
        vm.assume(unrelatedHolder != address(0));
        vm.assume(unrelatedHolder != recipient);
        vm.assume(recipientBalanceSeed > 0);
        vm.assume(unrelatedSupplySeed > 0);
        vm.assume(mintAmount > 0);

        usd8.mint(recipient, recipientBalanceSeed);
        usd8.mint(unrelatedHolder, unrelatedSupplySeed);

        uint256 supplyBefore = usd8.totalSupply();
        uint256 balanceBefore = usd8.balanceOf(recipient);

        usd8.mint(recipient, mintAmount);

        assert(usd8.totalSupply() == supplyBefore + mintAmount);
        assert(usd8.balanceOf(recipient) == balanceBefore + mintAmount);
        assert(usd8.balanceOf(unrelatedHolder) == unrelatedSupplySeed);
    }

    function test_authorizedBurnExactDeltaFromExistingState(
        address holder,
        address unrelatedHolder,
        uint128 holderBalanceSeed,
        uint128 unrelatedSupplySeed,
        uint128 burnAmount
    ) public {
        vm.assume(holder != address(0));
        vm.assume(unrelatedHolder != address(0));
        vm.assume(unrelatedHolder != holder);
        vm.assume(holderBalanceSeed > 0);
        vm.assume(unrelatedSupplySeed > 0);
        vm.assume(burnAmount > 0);
        vm.assume(holderBalanceSeed >= burnAmount);

        usd8.mint(holder, holderBalanceSeed);
        usd8.mint(unrelatedHolder, unrelatedSupplySeed);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 balanceBefore = usd8.balanceOf(holder);
        usd8.burn(holder, burnAmount);

        assert(usd8.totalSupply() == supplyBefore - burnAmount);
        assert(usd8.balanceOf(holder) == balanceBefore - burnAmount);
        assert(usd8.balanceOf(unrelatedHolder) == unrelatedSupplySeed);
    }

    function test_treasuryRotationMintRevokesOldAndGrantsNew(address recipient, uint128 mintAmount) public {
        vm.assume(recipient != address(0));
        vm.assume(mintAmount > 0);

        registry.setTreasury(address(otherCaller));
        assert(usd8.treasury() == address(otherCaller));

        uint256 supplyBefore = usd8.totalSupply();
        uint256 balanceBefore = usd8.balanceOf(recipient);

        (bool oldSuccess, bytes memory oldReturndata) =
            address(usd8).call(abi.encodeCall(USD8.mint, (recipient, mintAmount)));
        assert(!oldSuccess);
        assert(_selector(oldReturndata) == USD8.UnauthorizedTreasury.selector);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(recipient) == balanceBefore);

        (bool newSuccess,) = otherCaller.callMint(usd8, recipient, mintAmount);
        assert(newSuccess);
        assert(usd8.totalSupply() == supplyBefore + mintAmount);
        assert(usd8.balanceOf(recipient) == balanceBefore + mintAmount);
    }

    function test_treasuryRotationBurnRevokesOldAndGrantsNew(
        address holder,
        address unrelatedHolder,
        uint128 holderBalanceSeed,
        uint128 unrelatedSupplySeed,
        uint128 burnAmount
    ) public {
        vm.assume(holder != address(0));
        vm.assume(unrelatedHolder != address(0));
        vm.assume(unrelatedHolder != holder);
        vm.assume(holderBalanceSeed > 0);
        vm.assume(unrelatedSupplySeed > 0);
        vm.assume(burnAmount > 0);
        vm.assume(holderBalanceSeed >= burnAmount);

        usd8.mint(holder, holderBalanceSeed);
        usd8.mint(unrelatedHolder, unrelatedSupplySeed);

        registry.setTreasury(address(otherCaller));
        assert(usd8.treasury() == address(otherCaller));

        uint256 supplyBefore = usd8.totalSupply();
        uint256 balanceBefore = usd8.balanceOf(holder);

        (bool oldSuccess, bytes memory oldReturndata) =
            address(usd8).call(abi.encodeCall(USD8.burn, (holder, burnAmount)));
        assert(!oldSuccess);
        assert(_selector(oldReturndata) == USD8.UnauthorizedTreasury.selector);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(holder) == balanceBefore);
        assert(usd8.balanceOf(unrelatedHolder) == unrelatedSupplySeed);

        (bool newSuccess,) = otherCaller.callBurn(usd8, holder, burnAmount);
        assert(newSuccess);
        assert(usd8.totalSupply() == supplyBefore - burnAmount);
        assert(usd8.balanceOf(holder) == balanceBefore - burnAmount);
        assert(usd8.balanceOf(unrelatedHolder) == unrelatedSupplySeed);
    }

    function test_authorizedMintToZeroRevertsAtomically(uint256 amount) public {
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) = address(usd8).call(abi.encodeCall(USD8.mint, (address(0), amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InvalidReceiver.selector);
        assert(usd8.balanceOf(address(0)) == 0);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_authorizedMintOverflowRollsBackAtomically(address recipient) public {
        vm.assume(recipient != address(0));
        usd8.mint(recipient, type(uint256).max);

        (bool success, bytes memory returndata) = address(usd8).call(abi.encodeCall(USD8.mint, (recipient, 1)));

        assert(!success);
        assert(_selector(returndata) == bytes4(0x4e487b71));
        assert(usd8.balanceOf(recipient) == type(uint256).max);
        assert(usd8.totalSupply() == type(uint256).max);
    }

    function test_authorizedBurnFromZeroRevertsAtomically(uint256 amount) public {
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) = address(usd8).call(abi.encodeCall(USD8.burn, (address(0), amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InvalidSender.selector);
        assert(usd8.balanceOf(address(0)) == 0);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_authorizedBurnInsufficientBalanceRollsBackAtomically(
        address holder,
        address unrelatedHolder,
        uint128 holderSeed,
        uint128 unrelatedSeed,
        uint128 amount
    ) public {
        vm.assume(holder != address(0));
        vm.assume(unrelatedHolder != address(0));
        vm.assume(holder != unrelatedHolder);
        vm.assume(amount > holderSeed);

        usd8.mint(holder, holderSeed);
        usd8.mint(unrelatedHolder, unrelatedSeed);
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) = address(usd8).call(abi.encodeCall(USD8.burn, (holder, amount)));

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InsufficientBalance.selector);
        assert(usd8.balanceOf(holder) == holderSeed);
        assert(usd8.balanceOf(unrelatedHolder) == unrelatedSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_authorizedZeroMintPreservesNondegenerateState(
        address recipient,
        address unrelatedHolder,
        uint128 recipientSeed,
        uint128 unrelatedSeed
    ) public {
        vm.assume(recipient != address(0));
        vm.assume(unrelatedHolder != address(0));
        vm.assume(recipient != unrelatedHolder);

        usd8.mint(recipient, recipientSeed);
        usd8.mint(unrelatedHolder, unrelatedSeed);
        uint256 supplyBefore = usd8.totalSupply();

        usd8.mint(recipient, 0);

        assert(usd8.balanceOf(recipient) == recipientSeed);
        assert(usd8.balanceOf(unrelatedHolder) == unrelatedSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }

    function test_authorizedZeroBurnPreservesNondegenerateState(
        address holder,
        address unrelatedHolder,
        uint128 holderSeed,
        uint128 unrelatedSeed
    ) public {
        vm.assume(holder != address(0));
        vm.assume(unrelatedHolder != address(0));
        vm.assume(holder != unrelatedHolder);

        usd8.mint(holder, holderSeed);
        usd8.mint(unrelatedHolder, unrelatedSeed);
        uint256 supplyBefore = usd8.totalSupply();

        usd8.burn(holder, 0);

        assert(usd8.balanceOf(holder) == holderSeed);
        assert(usd8.balanceOf(unrelatedHolder) == unrelatedSeed);
        assert(usd8.totalSupply() == supplyBefore);
    }
}
