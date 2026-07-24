// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8} from "../../src/USD8.sol";

contract TreasuryReceiverSetToken is ERC20 {
    constructor() ERC20("Receiver Set USDC", "rsUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice Bounded receiver-list properties over production Registry, USD8, and
///         Treasury implementations behind real ERC1967 proxies.
/// @dev The production receiver array is intentionally uncapped. List-shape
///      properties here explicitly use N <= 3; this is a proof bound, not a
///      production cap or gas guarantee. Revenue callbacks are out of scope.
contract TreasuryReceiverSetKontrolTest is Test {
    uint256 internal constant MAX_PROVED_RECEIVERS = 3;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant NEW_ADMIN = address(0xB0B);
    address internal constant RECEIVER_A = address(0xA001);
    address internal constant RECEIVER_B = address(0xB002);
    address internal constant RECEIVER_C = address(0xC003);
    address internal constant MISSING = address(0xD004);

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasury;
    TreasuryReceiverSetToken internal usdc;

    function setUp() public {
        usdc = new TreasuryReceiverSetToken();
        registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        treasury = Treasury(
            address(
                new ERC1967Proxy(
                    address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(usdc))))
                )
            )
        );
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(treasury));
    }

    function _mode(bool hookMode) internal pure returns (Treasury.RevenueDistributionMode) {
        return hookMode
            ? Treasury.RevenueDistributionMode.ReceiveProfitDistribution
            : Treasury.RevenueDistributionMode.DirectTransfer;
    }

    function _set(address receiver, uint256 weight, Treasury.RevenueDistributionMode mode) internal {
        treasury.setProfitReceiver(receiver, weight, mode);
        assert(treasury.profitReceiversLength() <= MAX_PROVED_RECEIVERS);
    }

    function _receiver(uint256 index)
        internal
        view
        returns (address receiver, uint256 weight, Treasury.RevenueDistributionMode mode)
    {
        return treasury.profitReceivers(index);
    }

    function _assertReceiver(
        uint256 index,
        address expectedReceiver,
        uint256 expectedWeight,
        Treasury.RevenueDistributionMode expectedMode
    ) internal view {
        (address receiver, uint256 weight, Treasury.RevenueDistributionMode mode) = _receiver(index);
        assert(receiver == expectedReceiver);
        assert(weight == expectedWeight);
        assert(mode == expectedMode);
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
        return address(treasury).call(data);
    }

    function _seedThree() internal {
        _set(RECEIVER_A, 11, Treasury.RevenueDistributionMode.DirectTransfer);
        _set(RECEIVER_B, 22, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        _set(RECEIVER_C, 33, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function test_zeroAddressReceiverIsRejectedAtomically(uint64 weight, bool hookMode) public {
        (bool success, bytes memory returndata) = address(treasury)
            .call(abi.encodeCall(Treasury.setProfitReceiver, (address(0), uint256(weight), _mode(hookMode))));

        assert(!success);
        assert(_selector(returndata) == SharedBase.ZeroAddress.selector);
        assert(treasury.profitReceiversLength() == 0);
    }

    function test_treasurySelfReceiverIsRejectedAtomically(uint64 weight, bool hookMode) public {
        (bool success, bytes memory returndata) = address(treasury)
            .call(abi.encodeCall(Treasury.setProfitReceiver, (address(treasury), uint256(weight), _mode(hookMode))));

        assert(!success);
        assert(
            keccak256(returndata)
                == keccak256(abi.encodeWithSelector(Treasury.InvalidProfitReceiver.selector, address(treasury)))
        );
        assert(treasury.profitReceiversLength() == 0);
    }

    function test_newReceiverAppendsExactAddressWeightAndMode(uint64 weight, bool hookMode) public {
        _set(RECEIVER_A, 7, Treasury.RevenueDistributionMode.DirectTransfer);
        Treasury.RevenueDistributionMode mode = _mode(hookMode);

        _set(RECEIVER_B, weight, mode);

        assert(treasury.profitReceiversLength() == 2);
        _assertReceiver(0, RECEIVER_A, 7, Treasury.RevenueDistributionMode.DirectTransfer);
        _assertReceiver(1, RECEIVER_B, weight, mode);
    }

    function test_existingReceiverUpdateChangesOnlyWeightAndModeWithoutDuplicateOrReorder(
        uint64 newWeight,
        bool hookMode
    ) public {
        _seedThree();
        Treasury.RevenueDistributionMode newMode = _mode(hookMode);

        _set(RECEIVER_B, newWeight, newMode);

        assert(treasury.profitReceiversLength() == 3);
        _assertReceiver(0, RECEIVER_A, 11, Treasury.RevenueDistributionMode.DirectTransfer);
        _assertReceiver(1, RECEIVER_B, newWeight, newMode);
        _assertReceiver(2, RECEIVER_C, 33, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function test_zeroWeightRemainsRegisteredAndCanBeReweighted(uint64 newWeight, bool hookMode) public {
        vm.assume(newWeight > 0);
        _set(RECEIVER_A, 0, Treasury.RevenueDistributionMode.DirectTransfer);
        _assertReceiver(0, RECEIVER_A, 0, Treasury.RevenueDistributionMode.DirectTransfer);

        Treasury.RevenueDistributionMode newMode = _mode(hookMode);
        _set(RECEIVER_A, newWeight, newMode);

        assert(treasury.profitReceiversLength() == 1);
        _assertReceiver(0, RECEIVER_A, newWeight, newMode);
    }

    function test_firstMiddleAndLastRemovalUseExactSwapAndPopSemantics(uint8 removedIndex) public {
        vm.assume(removedIndex < MAX_PROVED_RECEIVERS);
        _seedThree();
        address removed = removedIndex == 0 ? RECEIVER_A : removedIndex == 1 ? RECEIVER_B : RECEIVER_C;

        treasury.removeProfitReceiver(removed);

        assert(treasury.profitReceiversLength() == 2);
        if (removedIndex == 0) {
            _assertReceiver(0, RECEIVER_C, 33, Treasury.RevenueDistributionMode.DirectTransfer);
            _assertReceiver(1, RECEIVER_B, 22, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        } else if (removedIndex == 1) {
            _assertReceiver(0, RECEIVER_A, 11, Treasury.RevenueDistributionMode.DirectTransfer);
            _assertReceiver(1, RECEIVER_C, 33, Treasury.RevenueDistributionMode.DirectTransfer);
        } else {
            _assertReceiver(0, RECEIVER_A, 11, Treasury.RevenueDistributionMode.DirectTransfer);
            _assertReceiver(1, RECEIVER_B, 22, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        }
    }

    function test_missingRemovalRevertsAtomically() public {
        _seedThree();

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(Treasury.removeProfitReceiver, (MISSING)));

        assert(!success);
        assert(_selector(returndata) == Treasury.ProfitReceiverNotFound.selector);
        assert(treasury.profitReceiversLength() == 3);
        _assertReceiver(0, RECEIVER_A, 11, Treasury.RevenueDistributionMode.DirectTransfer);
        _assertReceiver(1, RECEIVER_B, 22, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        _assertReceiver(2, RECEIVER_C, 33, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function test_symbolicUnauthorizedSetAndRemoveAreAtomic(address caller, uint64 weight, bool hookMode) public {
        vm.assume(caller != registry.timelock());
        vm.assume(!registry.isAdmin(caller));
        _seedThree();

        (bool setSuccess, bytes memory setData) =
            _callAs(caller, abi.encodeCall(Treasury.setProfitReceiver, (MISSING, uint256(weight), _mode(hookMode))));
        assert(!setSuccess);
        assert(_selector(setData) == Registry.UnauthorizedAdmin.selector);

        (bool removeSuccess, bytes memory removeData) =
            _callAs(caller, abi.encodeCall(Treasury.removeProfitReceiver, (RECEIVER_B)));
        assert(!removeSuccess);
        assert(_selector(removeData) == Registry.UnauthorizedAdmin.selector);

        assert(treasury.profitReceiversLength() == 3);
        _assertReceiver(0, RECEIVER_A, 11, Treasury.RevenueDistributionMode.DirectTransfer);
        _assertReceiver(1, RECEIVER_B, 22, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        _assertReceiver(2, RECEIVER_C, 33, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function test_adminAndTimelockCanBothCurateReceivers(uint64 adminWeight, uint64 timelockWeight) public {
        vm.prank(ADMIN);
        treasury.setProfitReceiver(RECEIVER_A, adminWeight, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        _set(RECEIVER_B, timelockWeight, Treasury.RevenueDistributionMode.DirectTransfer);

        assert(treasury.profitReceiversLength() == 2);
        _assertReceiver(0, RECEIVER_A, adminWeight, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        _assertReceiver(1, RECEIVER_B, timelockWeight, Treasury.RevenueDistributionMode.DirectTransfer);

        vm.prank(ADMIN);
        treasury.removeProfitReceiver(RECEIVER_A);
        treasury.removeProfitReceiver(RECEIVER_B);
        assert(treasury.profitReceiversLength() == 0);
    }

    function test_adminRotationImmediatelyRevokesOldAndGrantsNew(uint64 weight) public {
        _set(RECEIVER_A, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        registry.setAdmin(NEW_ADMIN, true);
        registry.setAdmin(ADMIN, false);

        (bool oldSuccess, bytes memory oldData) = _callAs(
            ADMIN,
            abi.encodeCall(
                Treasury.setProfitReceiver,
                (RECEIVER_B, uint256(weight), Treasury.RevenueDistributionMode.ReceiveProfitDistribution)
            )
        );
        assert(!oldSuccess);
        assert(_selector(oldData) == Registry.UnauthorizedAdmin.selector);
        assert(treasury.profitReceiversLength() == 1);

        vm.prank(NEW_ADMIN);
        treasury.setProfitReceiver(RECEIVER_B, weight, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        assert(treasury.profitReceiversLength() == 2);
        _assertReceiver(0, RECEIVER_A, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        _assertReceiver(1, RECEIVER_B, weight, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
    }

    function test_lengthAndIndexGettersAreExactAndOutOfBoundsReverts() public {
        _seedThree();

        assert(treasury.profitReceiversLength() == 3);
        _assertReceiver(0, RECEIVER_A, 11, Treasury.RevenueDistributionMode.DirectTransfer);
        _assertReceiver(1, RECEIVER_B, 22, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        _assertReceiver(2, RECEIVER_C, 33, Treasury.RevenueDistributionMode.DirectTransfer);

        (bool success, bytes memory returndata) =
            address(treasury).staticcall(abi.encodeWithSignature("profitReceivers(uint256)", uint256(3)));
        assert(!success);
        // Solidity's generated getter for a storage array reverts with empty data
        // when the requested index is outside the live array length.
        assert(returndata.length == 0);
    }
}
