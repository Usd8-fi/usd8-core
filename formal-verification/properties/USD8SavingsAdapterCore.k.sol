// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {USD8SavingsAdapter} from "../../src/adapters/USD8SavingsAdapter.sol";
import {
    USD8SavingsAdapterFactory,
    USD8SavingsAdapterKontrolBase,
    USD8SavingsFalseApprovalToken,
    USD8SavingsForceApproveFallbackToken,
    USD8SavingsMalformedApprovalToken,
    USD8SavingsMalformedParent,
    USD8SavingsNoReturnToken,
    USD8SavingsParent,
    USD8SavingsRevertingApprovalToken,
    USD8SavingsRevertingParent,
    USD8SavingsToken
} from "./USD8SavingsAdapterHarness.k.sol";

/// @notice Constructor, immutable, view, accounting-hook, boundary, and
/// authority properties for the current USD8SavingsAdapter bytecode.
/// @dev [V:IVaultV2_MODEL] The vendor IVaultV2 implementation is not proved
/// here. asset(), allocation(id), and accrueInterest() are modeled independently;
/// adapter properties prove composition with those exact observable responses.
contract USD8SavingsAdapterCoreKontrolTest is USD8SavingsAdapterKontrolBase {
    /// @dev [C:NO_CODE_REPRESENTATIVE] 0xBEEF is an ordinary, non-precompile
    /// no-code address used as one representative. These constructor tests do
    /// not claim identical behavior for every code-length-zero address, notably
    /// the EVM precompile range.
    address internal constant REPRESENTATIVE_NO_CODE = address(0xBEEF);

    function test_constructorBindsIndependentExpectedValuesAndExactMaxAllowance() public view {
        bytes32 expectedId = keccak256(abi.encode("this", address(adapter)));
        assert(adapter.deployer() == address(this));
        assert(adapter.parentVault() == address(parent));
        assert(adapter.asset() == address(token));
        assert(adapter.adapterId() == expectedId);
        assert(token.allowance(address(adapter), address(parent)) == type(uint256).max);
    }

    function test_constructorDeployerIsImmediateFactoryCaller() public {
        USD8SavingsAdapterFactory factory = new USD8SavingsAdapterFactory();
        USD8SavingsAdapter deployed = factory.deploy(address(parent));
        assert(deployed.deployer() == address(factory));
        assert(deployed.parentVault() == address(parent));
        assert(deployed.asset() == address(token));
        assert(deployed.adapterId() == keccak256(abi.encode("this", address(deployed))));
        assert(token.allowance(address(deployed), address(parent)) == type(uint256).max);
    }

    function test_constructorAcceptsNoReturnApprovalAndSetsExactMaxAllowance() public {
        USD8SavingsNoReturnToken legacy = new USD8SavingsNoReturnToken();
        (USD8SavingsParent legacyParent, USD8SavingsAdapter legacyAdapter) = _deployWith(address(legacy));
        assert(legacyAdapter.asset() == address(legacy));
        assert(legacy.allowance(address(legacyAdapter), address(legacyParent)) == type(uint256).max);
    }

    function test_constructorFalseApprovalRevertsWithExactSafeERC20Error() public {
        USD8SavingsFalseApprovalToken badToken = new USD8SavingsFalseApprovalToken();
        USD8SavingsParent badParent = new USD8SavingsParent(address(badToken));
        USD8SavingsAdapterFactory factory = new USD8SavingsAdapterFactory();
        (bool success, bytes memory returndata) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(badParent))));
        assert(!success);
        _assertExactRevert(
            returndata, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(badToken))
        );
    }

    function test_constructorForceApproveFallbackSucceedsOnlyAfterZeroThenMax() public {
        USD8SavingsForceApproveFallbackToken fallbackToken = new USD8SavingsForceApproveFallbackToken(false, false);
        (USD8SavingsParent fallbackParent, USD8SavingsAdapter fallbackAdapter) = _deployWith(address(fallbackToken));
        assert(fallbackToken.approveCalls() == 3);
        assert(fallbackToken.zeroCalls() == 1);
        assert(fallbackToken.maxCalls() == 2);
        assert(fallbackToken.allowance(address(fallbackAdapter), address(fallbackParent)) == type(uint256).max);
    }

    function test_constructorForceApproveFallbackZeroFailureHasExactSafeERC20Error() public {
        USD8SavingsForceApproveFallbackToken bad = new USD8SavingsForceApproveFallbackToken(true, false);
        USD8SavingsParent badParent = new USD8SavingsParent(address(bad));
        USD8SavingsAdapterFactory factory = new USD8SavingsAdapterFactory();
        (bool success, bytes memory returndata) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(badParent))));
        assert(!success);
        _assertExactRevert(
            returndata, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad))
        );
        assert(bad.approveCalls() == 0); // failed constructor transaction is atomic
    }

    function test_constructorForceApproveFallbackFinalFailureHasExactSafeERC20Error() public {
        USD8SavingsForceApproveFallbackToken bad = new USD8SavingsForceApproveFallbackToken(false, true);
        USD8SavingsParent badParent = new USD8SavingsParent(address(bad));
        USD8SavingsAdapterFactory factory = new USD8SavingsAdapterFactory();
        (bool success, bytes memory returndata) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(badParent))));
        assert(!success);
        _assertExactRevert(
            returndata, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad))
        );
        assert(bad.approveCalls() == 0);
    }

    function test_constructorRevertingApprovalBubblesExactZeroFallbackError() public {
        USD8SavingsRevertingApprovalToken bad = new USD8SavingsRevertingApprovalToken();
        USD8SavingsParent badParent = new USD8SavingsParent(address(bad));
        USD8SavingsAdapterFactory factory = new USD8SavingsAdapterFactory();
        (bool success, bytes memory returndata) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(badParent))));
        assert(!success);
        _assertExactRevert(
            returndata,
            abi.encodeWithSelector(USD8SavingsRevertingApprovalToken.ApprovalRejected.selector, address(badParent), 0)
        );
    }

    function test_constructorMalformedApprovalHasExactSafeERC20Error() public {
        USD8SavingsMalformedApprovalToken bad = new USD8SavingsMalformedApprovalToken();
        USD8SavingsParent badParent = new USD8SavingsParent(address(bad));
        USD8SavingsAdapterFactory factory = new USD8SavingsAdapterFactory();
        (bool success, bytes memory returndata) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(badParent))));
        assert(!success);
        _assertExactRevert(
            returndata, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad))
        );
    }

    function test_constructorZeroAndNoCodeAssetsHaveExactSafeERC20Errors() public {
        USD8SavingsAdapterFactory factory = new USD8SavingsAdapterFactory();
        USD8SavingsParent zeroParent = new USD8SavingsParent(address(0));
        (bool zeroSuccess, bytes memory zeroData) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(zeroParent))));
        assert(!zeroSuccess);
        _assertExactRevert(zeroData, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(0)));

        address noCodeAsset = REPRESENTATIVE_NO_CODE;
        USD8SavingsParent noCodeParent = new USD8SavingsParent(noCodeAsset);
        (bool noCodeSuccess, bytes memory noCodeData) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(noCodeParent))));
        assert(!noCodeSuccess);
        _assertExactRevert(noCodeData, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, noCodeAsset));
    }

    function test_constructorParentReadFailuresAreAtomicAndPreserveExactRevertShapes() public {
        USD8SavingsAdapterFactory factory = new USD8SavingsAdapterFactory();
        USD8SavingsRevertingParent revertingParent = new USD8SavingsRevertingParent();
        (bool reverted, bytes memory revertData) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(revertingParent))));
        assert(!reverted);
        _assertExactRevert(revertData, abi.encodeWithSelector(USD8SavingsRevertingParent.AssetReadRejected.selector));

        USD8SavingsMalformedParent malformedParent = new USD8SavingsMalformedParent();
        (bool malformed, bytes memory malformedData) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(malformedParent))));
        assert(!malformed && malformedData.length == 0);

        (bool noCode, bytes memory noCodeData) =
            address(factory).call(abi.encodeCall(factory.deploy, (REPRESENTATIVE_NO_CODE)));
        assert(!noCode && noCodeData.length == 0);
    }

    function test_idsIsExactlyOneIndependentAdapterIdAndHasNoSideEffects() public view {
        uint256 allowanceBefore = token.allowance(address(adapter), address(parent));
        bytes32[] memory result = adapter.ids();
        assert(result.length == 1);
        assert(result[0] == keccak256(abi.encode("this", address(adapter))));
        assert(token.balanceOf(address(adapter)) == 0);
        assert(token.allowance(address(adapter), address(parent)) == allowanceBefore);
    }

    function test_allocationReturnsExactlyTheModeledParentRecord(uint128 recorded) public {
        parent.setAllocation(adapter.adapterId(), recorded);
        assert(adapter.allocation() == uint256(recorded));
    }

    function test_realAssetsZeroActiveGateIgnoresArbitraryUnsolicitedDonation(uint128 donation) public {
        token.mint(address(adapter), donation);
        parent.setAllocation(adapter.adapterId(), 0);
        assert(adapter.realAssets() == 0);
        assert(token.balanceOf(address(adapter)) == donation);
    }

    function test_realAssetsActiveReturnsEntireBalanceIncludingUnsolicitedDonation(uint128 recorded, uint128 donation)
        public
    {
        vm.assume(recorded > 0);
        token.mint(address(adapter), donation);
        parent.setAllocation(adapter.adapterId(), recorded);
        assert(adapter.realAssets() == donation);
    }

    /// @dev [A:HEALTHY_VAULT_UINT128] VaultV2 stores total assets/allocation in
    /// uint128; these symbolic seeds model healthy production-reachable state.
    /// Separate adversarial tests below inject oversized parent records directly.
    function test_allocateReturnsIndependentSignedDeltaBothDirections(uint128 recorded, uint128 currentBalance) public {
        parent.setAllocation(adapter.adapterId(), recorded);
        token.mint(address(adapter), currentBalance);
        (bytes32[] memory resultIds, int256 change) =
            parent.callAllocate(adapter, "", 991, bytes4(0x12345678), OUTSIDER);
        int256 expected = int256(uint256(currentBalance)) - int256(uint256(recorded));
        assert(resultIds.length == 1 && resultIds[0] == adapter.adapterId());
        assert(change == expected);
        assert(token.balanceOf(address(adapter)) == currentBalance);
        assert(parent.allocation(adapter.adapterId()) == recorded);
        assert(token.allowance(address(adapter), address(parent)) == type(uint256).max);
    }

    function test_deallocateReturnsProjectedSignedDeltaBothDirections(
        uint128 recorded,
        uint128 currentBalance,
        uint128 assets
    ) public {
        vm.assume(assets <= currentBalance);
        parent.setAllocation(adapter.adapterId(), recorded);
        token.mint(address(adapter), currentBalance);
        (bytes32[] memory resultIds, int256 change) =
            parent.callDeallocate(adapter, "", assets, bytes4(0x87654321), OUTSIDER);
        uint256 projected = uint256(currentBalance) - assets;
        int256 expected = int256(projected) - int256(uint256(recorded));
        assert(resultIds.length == 1 && resultIds[0] == adapter.adapterId());
        assert(change == expected);
        assert(token.balanceOf(address(adapter)) == currentBalance);
        assert(parent.allocation(adapter.adapterId()) == recorded);
        assert(token.allowance(address(adapter), address(parent)) == type(uint256).max);
    }

    // [C:ADDRESS_REPRESENTATIVE] Authorization depends only on equality with
    // parentVault, so OUTSIDER represents every unauthorized caller. All ignored
    // parameters remain arbitrary and cannot confer authority.
    function test_unauthorizedAllocateAndDeallocateRejectBeforePoisonedDataOrAccounting(
        bytes memory data,
        uint256 assets,
        bytes4 selector,
        address sender
    ) public {
        parent.setAllocationReadMode(true, false);
        token.setBalanceReadMode(true, false);
        vm.prank(OUTSIDER);
        (bool allocateSuccess, bytes memory allocateData) =
            address(adapter).call(abi.encodeCall(USD8SavingsAdapter.allocate, (data, assets, selector, sender)));
        vm.prank(OUTSIDER);
        (bool deallocateSuccess, bytes memory deallocateData) =
            address(adapter).call(abi.encodeCall(USD8SavingsAdapter.deallocate, (data, assets, selector, sender)));
        assert(!allocateSuccess);
        assert(!deallocateSuccess);
        _assertExactRevert(allocateData, abi.encodeWithSelector(USD8SavingsAdapter.NotAuthorized.selector));
        _assertExactRevert(deallocateData, abi.encodeWithSelector(USD8SavingsAdapter.NotAuthorized.selector));
        parent.setAllocationReadMode(false, false);
        token.setBalanceReadMode(false, false);
        assert(token.balanceOf(address(adapter)) == 0);
        assert(parent.allocation(adapter.adapterId()) == 0);
    }

    function test_parentRejectsEveryNonemptyDataBeforeRevertingAccounting(bytes memory data) public {
        vm.assume(data.length > 0);
        parent.setAllocationReadMode(true, false);
        token.setBalanceReadMode(true, false);
        (bool allocateSuccess, bytes memory allocateData) =
            address(parent).call(abi.encodeCall(parent.callAllocate, (adapter, data, 0, bytes4(0), address(0))));
        (bool deallocateSuccess, bytes memory deallocateData) =
            address(parent).call(abi.encodeCall(parent.callDeallocate, (adapter, data, 0, bytes4(0), address(0))));
        assert(!allocateSuccess);
        assert(!deallocateSuccess);
        _assertExactRevert(allocateData, abi.encodeWithSelector(USD8SavingsAdapter.InvalidData.selector));
        _assertExactRevert(deallocateData, abi.encodeWithSelector(USD8SavingsAdapter.InvalidData.selector));
    }

    function test_parentRejectsEveryNonemptyDataBeforeMalformedAccounting(bytes memory data) public {
        vm.assume(data.length > 0);
        parent.setAllocationReadMode(false, true);
        token.setBalanceReadMode(false, true);
        (bool allocateSuccess, bytes memory allocateData) =
            address(parent).call(abi.encodeCall(parent.callAllocate, (adapter, data, 0, bytes4(0), address(0))));
        (bool deallocateSuccess, bytes memory deallocateData) =
            address(parent).call(abi.encodeCall(parent.callDeallocate, (adapter, data, 0, bytes4(0), address(0))));
        assert(!allocateSuccess);
        assert(!deallocateSuccess);
        _assertExactRevert(allocateData, abi.encodeWithSelector(USD8SavingsAdapter.InvalidData.selector));
        _assertExactRevert(deallocateData, abi.encodeWithSelector(USD8SavingsAdapter.InvalidData.selector));
    }

    function test_accountingBubblesExactParentErrorBeforeTokenBalanceRead() public {
        bytes32 id = adapter.adapterId();
        parent.setAllocationReadMode(true, false);
        token.setBalanceReadMode(true, false);
        (bool success, bytes memory returndata) =
            address(parent).call(abi.encodeCall(parent.callAllocate, (adapter, bytes(""), 0, bytes4(0), address(0))));
        assert(!success);
        _assertExactRevert(returndata, abi.encodeWithSelector(USD8SavingsParent.AllocationReadRejected.selector, id));
    }

    function test_deallocateBubblesExactParentErrorBeforeTokenBalanceRead() public {
        bytes32 id = adapter.adapterId();
        parent.setAllocationReadMode(true, false);
        token.setBalanceReadMode(true, false);
        (bool success, bytes memory returndata) =
            address(parent).call(abi.encodeCall(parent.callDeallocate, (adapter, bytes(""), 0, bytes4(0), address(0))));
        assert(!success);
        _assertExactRevert(returndata, abi.encodeWithSelector(USD8SavingsParent.AllocationReadRejected.selector, id));
        parent.setAllocationReadMode(false, false);
        token.setBalanceReadMode(false, false);
        assert(parent.allocation(id) == 0);
        assert(token.balanceOf(address(adapter)) == 0);
    }

    function test_realAssetsBubblesExactParentErrorBeforeTokenBalanceRead() public {
        bytes32 id = adapter.adapterId();
        parent.setAllocationReadMode(true, false);
        token.setBalanceReadMode(true, false);
        (bool success, bytes memory returndata) =
            address(adapter).call(abi.encodeCall(USD8SavingsAdapter.realAssets, ()));
        assert(!success);
        _assertExactRevert(returndata, abi.encodeWithSelector(USD8SavingsParent.AllocationReadRejected.selector, id));
    }

    function test_activeRealAssetsBubblesExactTokenBalanceError() public {
        parent.setAllocation(adapter.adapterId(), 1);
        token.setBalanceReadMode(true, false);
        (bool success, bytes memory returndata) =
            address(adapter).call(abi.encodeCall(USD8SavingsAdapter.realAssets, ()));
        assert(!success);
        _assertExactRevert(
            returndata, abi.encodeWithSelector(USD8SavingsToken.BalanceReadRejected.selector, address(adapter))
        );
    }

    function test_malformedAllocationAndBalanceReadsHaveExactEmptyReverts() public {
        parent.setAllocationReadMode(false, true);
        (bool allocationSuccess, bytes memory allocationData) =
            address(adapter).call(abi.encodeCall(USD8SavingsAdapter.allocation, ()));
        assert(!allocationSuccess && allocationData.length == 0);

        parent.setAllocationReadMode(false, false);
        parent.setAllocation(adapter.adapterId(), 1);
        token.setBalanceReadMode(false, true);
        (bool balanceSuccess, bytes memory balanceData) =
            address(adapter).call(abi.encodeCall(USD8SavingsAdapter.realAssets, ()));
        assert(!balanceSuccess && balanceData.length == 0);
    }

    function test_allocateCurrentBalanceAtInt256MaxSucceeds() public {
        uint256 endpoint = uint256(type(int256).max);
        token.mint(address(adapter), endpoint);
        (bytes32[] memory resultIds, int256 change) = parent.callAllocate(adapter, "", 0, bytes4(0), address(0));
        assert(resultIds.length == 1 && resultIds[0] == adapter.adapterId());
        assert(change == type(int256).max);
    }

    function test_allocateRecordedAllocationAtInt256MaxSucceeds() public {
        uint256 endpoint = uint256(type(int256).max);
        parent.setAllocation(adapter.adapterId(), endpoint);
        (bytes32[] memory resultIds, int256 change) = parent.callAllocate(adapter, "", 0, bytes4(0), address(0));
        assert(resultIds.length == 1 && resultIds[0] == adapter.adapterId());
        assert(change == -type(int256).max);
    }

    function test_deallocateProjectedBalanceAtInt256MaxSucceeds() public {
        uint256 endpoint = uint256(type(int256).max);
        token.mint(address(adapter), endpoint);
        (bytes32[] memory resultIds, int256 change) = parent.callDeallocate(adapter, "", 0, bytes4(0), address(0));
        assert(resultIds.length == 1 && resultIds[0] == adapter.adapterId());
        assert(change == type(int256).max);
    }

    function test_deallocateRecordedAllocationAtInt256MaxSucceedsIndependently() public {
        uint256 endpoint = uint256(type(int256).max);
        bytes32 id = adapter.adapterId();
        parent.setAllocation(id, endpoint);
        token.mint(address(adapter), 1);
        uint256 allowanceBefore = token.allowance(address(adapter), address(parent));
        // A one-unit balance and withdrawal make the projected balance exactly zero,
        // isolating the recorded-allocation cast from the projected-balance boundary.
        (bytes32[] memory resultIds, int256 change) = parent.callDeallocate(adapter, "", 1, bytes4(0), address(0));
        assert(resultIds.length == 1 && resultIds[0] == id);
        assert(change == -type(int256).max);
        assert(parent.allocation(id) == endpoint);
        assert(token.balanceOf(address(adapter)) == 1);
        assert(token.allowance(address(adapter), address(parent)) == allowanceBefore);
        assert(token.transferFromCalls() == 0);
    }

    function test_allocateRejectsCurrentBalanceAboveSignedRangeWithExactPayload() public {
        uint256 oversized = uint256(type(int256).max) + 1;
        token.mint(address(adapter), oversized);
        (bool success, bytes memory returndata) =
            address(parent).call(abi.encodeCall(parent.callAllocate, (adapter, bytes(""), 0, bytes4(0), address(0))));
        assert(!success);
        _assertExactRevert(returndata, abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintToInt.selector, oversized));
        assert(token.balanceOf(address(adapter)) == oversized);
    }

    function test_allocateRejectsRecordedAllocationAboveSignedRangeWithExactPayload() public {
        uint256 oversized = uint256(type(int256).max) + 1;
        parent.setAllocation(adapter.adapterId(), oversized);
        (bool success, bytes memory returndata) =
            address(parent).call(abi.encodeCall(parent.callAllocate, (adapter, bytes(""), 0, bytes4(0), address(0))));
        assert(!success);
        _assertExactRevert(returndata, abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintToInt.selector, oversized));
        assert(parent.allocation(adapter.adapterId()) == oversized);
    }

    function test_deallocateRejectsRecordedAllocationAboveSignedRangeWithExactPayloadAndRollback() public {
        uint256 oversized = uint256(type(int256).max) + 1;
        bytes32 id = adapter.adapterId();
        parent.setAllocation(id, oversized);
        token.mint(address(adapter), 1);
        uint256 allowanceBefore = token.allowance(address(adapter), address(parent));
        // Keep the projected balance at zero so only the recorded-allocation cast
        // reaches its max+1 boundary; this is independent of projected-balance tests.
        (bool success, bytes memory returndata) =
            address(parent).call(abi.encodeCall(parent.callDeallocate, (adapter, bytes(""), 1, bytes4(0), address(0))));
        assert(!success);
        _assertExactRevert(returndata, abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintToInt.selector, oversized));
        assert(parent.allocation(id) == oversized);
        assert(token.balanceOf(address(adapter)) == 1);
        assert(token.allowance(address(adapter), address(parent)) == allowanceBefore);
        assert(token.transferFromCalls() == 0);
    }

    function test_deallocateUnderflowPanicsAndRollsBackWithoutTransfer(uint128 balance, uint128 excess) public {
        vm.assume(excess > 0 && uint256(balance) + excess <= type(uint128).max);
        token.mint(address(adapter), balance);
        uint256 assets = uint256(balance) + excess;
        (bool success, bytes memory returndata) = address(parent)
            .call(abi.encodeCall(parent.callDeallocate, (adapter, bytes(""), assets, bytes4(0), address(0))));
        assert(!success);
        _assertExactRevert(returndata, abi.encodeWithSelector(bytes4(0x4e487b71), uint256(0x11)));
        assert(token.balanceOf(address(adapter)) == balance);
    }

    function test_deallocateRejectsProjectedBalanceAboveSignedRange() public {
        uint256 oversized = uint256(type(int256).max) + 1;
        token.mint(address(adapter), oversized);
        (bool success, bytes memory returndata) =
            address(parent).call(abi.encodeCall(parent.callDeallocate, (adapter, bytes(""), 0, bytes4(0), address(0))));
        assert(!success);
        _assertExactRevert(returndata, abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintToInt.selector, oversized));
    }

    function test_hooksNeverTransferTokensOrConsumePermanentAllowance(uint128 balance, uint128 recorded) public {
        token.mint(address(adapter), balance);
        parent.setAllocation(adapter.adapterId(), recorded);
        uint256 adapterBefore = token.balanceOf(address(adapter));
        uint256 parentBefore = token.balanceOf(address(parent));
        uint256 allowanceBefore = token.allowance(address(adapter), address(parent));
        parent.callAllocate(adapter, "", type(uint256).max, bytes4(type(uint32).max), address(adapter));
        parent.callDeallocate(adapter, "", 0, bytes4(type(uint32).max), address(adapter));
        assert(token.balanceOf(address(adapter)) == adapterBefore);
        assert(token.balanceOf(address(parent)) == parentBefore);
        assert(token.allowance(address(adapter), address(parent)) == allowanceBefore);
        assert(token.transferFromCalls() == 0);
    }
}
