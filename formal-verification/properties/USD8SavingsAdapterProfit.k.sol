// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {USD8SavingsAdapter} from "../../src/adapters/USD8SavingsAdapter.sol";
import {
    USD8SavingsAdapterKontrolBase,
    USD8SavingsCallbackToken,
    USD8SavingsFalseReturnToken,
    USD8SavingsFeeToken,
    USD8SavingsMalformedToken,
    USD8SavingsNoReturnToken,
    USD8SavingsParent,
    USD8SavingsRevertingToken,
    USD8SavingsToken
} from "./USD8SavingsAdapterHarness.k.sol";

/// @notice Profit-distribution ordering, token-mode, rollback, and callback properties.
/// @dev [A:EXACT_ERC20] Exact received-asset and event claims require a transaction-stable,
/// non-fee, non-rebasing ERC20 that returns true or no data. SafeERC20 alone does not
/// enforce an exact receiver balance delta. [A:CALLBACK] Neither this adapter nor the
/// modeled IVaultV2 boundary supplies a reentrancy guard; callback schedules are therefore
/// characterized explicitly rather than assumed impossible.
contract USD8SavingsAdapterProfitKontrolTest is USD8SavingsAdapterKontrolBase {
    function test_profitCheckpointsBeforeExactTransferAndReturnsExactDeltas(uint128 seed, uint128 assets) public {
        vm.assume(uint256(seed) + assets <= type(uint128).max);
        token.mint(DISTRIBUTOR, uint256(seed) + assets);
        vm.prank(DISTRIBUTOR);
        token.approve(address(adapter), assets);
        uint256 distributorBefore = token.balanceOf(DISTRIBUTOR);
        uint256 adapterBefore = token.balanceOf(address(adapter));

        vm.prank(DISTRIBUTOR);
        adapter.receiveProfitDistribution(assets);

        assert(parent.accrueCalls() == 1 && parent.checkpointed());
        assert(token.observedCheckpoint());
        assert(token.transferFromCalls() == 1);
        assert(token.balanceOf(DISTRIBUTOR) == distributorBefore - assets);
        assert(token.balanceOf(address(adapter)) == adapterBefore + assets);
        assert(token.allowance(DISTRIBUTOR, address(adapter)) == 0);
    }

    function test_profitZeroStillCheckpointsAndCallsTokenExactlyOnce() public {
        vm.prank(DISTRIBUTOR);
        adapter.receiveProfitDistribution(0);
        assert(parent.accrueCalls() == 1 && parent.checkpointed());
        assert(token.observedCheckpoint());
        assert(token.transferFromCalls() == 1);
        assert(token.balanceOf(address(adapter)) == 0);
    }

    function test_profitIsPermissionlessAcrossRepresentativeCaller(uint128 assets) public {
        token.mint(OUTSIDER, assets);
        vm.prank(OUTSIDER);
        token.approve(address(adapter), assets);
        vm.prank(OUTSIDER);
        adapter.receiveProfitDistribution(assets);
        assert(parent.accrueCalls() == 1);
        assert(token.balanceOf(address(adapter)) == assets);
        assert(token.balanceOf(OUTSIDER) == 0);
    }

    function test_unsolicitedDonationDoesNotCheckpointButLaterProfitDoes(uint128 donation, uint128 profit) public {
        vm.assume(uint256(donation) + profit <= type(uint128).max);
        token.mint(DISTRIBUTOR, uint256(donation) + profit);
        vm.prank(DISTRIBUTOR);
        token.transfer(address(adapter), donation);
        assert(parent.accrueCalls() == 0);
        assert(adapter.realAssets() == 0);

        parent.setAllocation(adapter.adapterId(), 1);
        vm.prank(DISTRIBUTOR);
        token.approve(address(adapter), profit);
        vm.prank(DISTRIBUTOR);
        adapter.receiveProfitDistribution(profit);
        assert(parent.accrueCalls() == 1);
        assert(adapter.realAssets() == uint256(donation) + profit);
        assert(parent.allocation(adapter.adapterId()) == 1);
    }

    function test_parentAccrualRevertPreventsTransferAndRollsBackEverything(uint128 assets) public {
        token.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        token.approve(address(adapter), assets);
        parent.setRevertAccrue(true);
        vm.prank(DISTRIBUTOR);
        (bool success, bytes memory returndata) =
            address(adapter).call(abi.encodeCall(USD8SavingsAdapter.receiveProfitDistribution, (assets)));
        assert(!success);
        _assertExactRevert(returndata, abi.encodeWithSelector(USD8SavingsParent.AccrualRejected.selector));
        assert(parent.accrueCalls() == 0 && !parent.checkpointed());
        assert(token.transferFromCalls() == 0);
        assert(token.balanceOf(DISTRIBUTOR) == assets);
        assert(token.balanceOf(address(adapter)) == 0);
        assert(token.allowance(DISTRIBUTOR, address(adapter)) == assets);
    }

    function test_insufficientAllowanceRollsBackCheckpointAtomically(uint128 assets) public {
        vm.assume(assets > 0);
        token.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        (bool success, bytes memory returndata) =
            address(adapter).call(abi.encodeCall(USD8SavingsAdapter.receiveProfitDistribution, (assets)));
        assert(!success);
        _assertExactRevert(
            returndata,
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(adapter), uint256(0), uint256(assets)
            )
        );
        assert(parent.accrueCalls() == 0 && !parent.checkpointed());
        assert(token.transferFromCalls() == 0);
        assert(token.balanceOf(DISTRIBUTOR) == assets);
        assert(token.balanceOf(address(adapter)) == 0);
    }

    function test_revertingTokenRollsBackCheckpointAndBalances(uint128 assets) public {
        USD8SavingsRevertingToken bad = new USD8SavingsRevertingToken();
        (USD8SavingsParent badParent, USD8SavingsAdapter badAdapter) = _deployWith(address(bad));
        bad.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        bad.approve(address(badAdapter), assets);
        vm.prank(DISTRIBUTOR);
        (bool success, bytes memory returndata) =
            address(badAdapter).call(abi.encodeCall(USD8SavingsAdapter.receiveProfitDistribution, (assets)));
        assert(!success);
        _assertExactRevert(returndata, abi.encodeWithSelector(USD8SavingsRevertingToken.TransferFromRejected.selector));
        assert(badParent.accrueCalls() == 0 && !badParent.checkpointed());
        assert(bad.balanceOf(DISTRIBUTOR) == assets && bad.balanceOf(address(badAdapter)) == 0);
        assert(bad.allowance(DISTRIBUTOR, address(badAdapter)) == assets);
    }

    function test_falseReturnTokenRollsBackCheckpointWithExactSafeERC20Error(uint128 assets) public {
        USD8SavingsFalseReturnToken bad = new USD8SavingsFalseReturnToken();
        (USD8SavingsParent badParent, USD8SavingsAdapter badAdapter) = _deployWith(address(bad));
        bad.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        bad.approve(address(badAdapter), assets);
        vm.prank(DISTRIBUTOR);
        (bool success, bytes memory returndata) =
            address(badAdapter).call(abi.encodeCall(USD8SavingsAdapter.receiveProfitDistribution, (assets)));
        assert(!success);
        _assertExactRevert(
            returndata, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad))
        );
        assert(badParent.accrueCalls() == 0 && !badParent.checkpointed());
        assert(bad.balanceOf(DISTRIBUTOR) == assets && bad.balanceOf(address(badAdapter)) == 0);
    }

    function test_malformedReturnRollsBackTokenMutationAllowanceAndCheckpoint(uint128 assets) public {
        USD8SavingsMalformedToken bad = new USD8SavingsMalformedToken();
        (USD8SavingsParent badParent, USD8SavingsAdapter badAdapter) = _deployWith(address(bad));
        bad.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        bad.approve(address(badAdapter), assets);
        vm.prank(DISTRIBUTOR);
        (bool success, bytes memory returndata) =
            address(badAdapter).call(abi.encodeCall(USD8SavingsAdapter.receiveProfitDistribution, (assets)));
        assert(!success);
        _assertExactRevert(
            returndata, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad))
        );
        assert(badParent.accrueCalls() == 0 && !badParent.checkpointed());
        assert(bad.balanceOf(DISTRIBUTOR) == assets && bad.balanceOf(address(badAdapter)) == 0);
        assert(bad.allowance(DISTRIBUTOR, address(badAdapter)) == assets);
    }

    function test_noReturnLegacyTokenSucceedsWithExactDeltas(uint128 assets) public {
        USD8SavingsNoReturnToken legacy = new USD8SavingsNoReturnToken();
        (USD8SavingsParent legacyParent, USD8SavingsAdapter legacyAdapter) = _deployWith(address(legacy));
        legacy.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        legacy.approve(address(legacyAdapter), assets);
        vm.prank(DISTRIBUTOR);
        legacyAdapter.receiveProfitDistribution(assets);
        assert(legacyParent.accrueCalls() == 1 && legacyParent.checkpointed());
        assert(legacy.balanceOf(DISTRIBUTOR) == 0);
        assert(legacy.balanceOf(address(legacyAdapter)) == assets);
        assert(legacy.allowance(DISTRIBUTOR, address(legacyAdapter)) == 0);
    }

    function test_feeTokenSucceedsButReceivesOneLessThanNominal(uint128 assets) public {
        vm.assume(assets > 0);
        USD8SavingsFeeToken fee = new USD8SavingsFeeToken();
        (USD8SavingsParent feeParent, USD8SavingsAdapter feeAdapter) = _deployWith(address(fee));
        fee.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        fee.approve(address(feeAdapter), assets);
        vm.prank(DISTRIBUTOR);
        feeAdapter.receiveProfitDistribution(assets);
        assert(feeParent.accrueCalls() == 1 && feeParent.checkpointed());
        assert(fee.balanceOf(DISTRIBUTOR) == 0);
        assert(fee.balanceOf(address(feeAdapter)) == uint256(assets) - 1);
        assert(fee.balanceOf(address(0xFEE)) == 1);
    }

    function test_parentCanCallbackIntoAuthorizedHookBeforeTransfer(uint128 assets) public {
        token.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        token.approve(address(adapter), assets);
        parent.setAccrueCallback(
            address(adapter), abi.encodeCall(USD8SavingsAdapter.allocate, (bytes(""), 77, bytes4(0xAABBCCDD), OUTSIDER))
        );
        vm.prank(DISTRIBUTOR);
        adapter.receiveProfitDistribution(assets);
        bytes32[] memory expectedIds = new bytes32[](1);
        expectedIds[0] = adapter.adapterId();
        bytes memory expectedReturn = abi.encode(expectedIds, int256(0));
        assert(parent.callbackSuccess());
        assert(parent.callbackResultLength() == expectedReturn.length);
        assert(parent.callbackResultHash() == keccak256(expectedReturn));
        assert(parent.callbackResultSelector() == bytes4(0));
        assert(parent.accrueCalls() == 1);
        assert(token.transferFromCalls() == 1);
        assert(token.observedCheckpoint());
        assert(token.balanceOf(address(adapter)) == assets);
    }

    function test_parentCaughtNestedRevertStillAppliesOuterDeltasOnce(uint128 assets) public {
        token.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        token.approve(address(adapter), assets);
        parent.setAccrueCallback(
            address(adapter), abi.encodeCall(USD8SavingsAdapter.allocate, (hex"01", 0, bytes4(0), address(0)))
        );
        vm.prank(DISTRIBUTOR);
        adapter.receiveProfitDistribution(assets);
        bytes memory expectedRevert = abi.encodeWithSelector(USD8SavingsAdapter.InvalidData.selector);
        assert(!parent.callbackSuccess());
        assert(parent.callbackResultLength() == expectedRevert.length);
        assert(parent.callbackResultHash() == keccak256(expectedRevert));
        assert(parent.callbackResultSelector() == USD8SavingsAdapter.InvalidData.selector);
        assert(parent.accrueCalls() == 1);
        assert(token.transferFromCalls() == 1);
        assert(token.balanceOf(DISTRIBUTOR) == 0);
        assert(token.balanceOf(address(adapter)) == assets);
        assert(token.allowance(DISTRIBUTOR, address(adapter)) == 0);
    }

    function test_tokenCallbackCanReenterProfitHookBecauseNoGuardExists(uint128 assets) public {
        USD8SavingsCallbackToken callbackToken = new USD8SavingsCallbackToken();
        USD8SavingsParent callbackParent = new USD8SavingsParent(address(callbackToken));
        USD8SavingsAdapter callbackAdapter = new USD8SavingsAdapter(address(callbackParent));
        callbackToken.setObservedParent(callbackParent);
        callbackToken.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        callbackToken.approve(address(callbackAdapter), assets);
        callbackToken.configureCallback(
            address(callbackAdapter), abi.encodeCall(USD8SavingsAdapter.receiveProfitDistribution, (uint256(0)))
        );
        vm.prank(DISTRIBUTOR);
        callbackAdapter.receiveProfitDistribution(assets);
        assert(callbackToken.callbackSuccess());
        assert(callbackToken.callbackResultLength() == 0);
        assert(callbackToken.callbackResultHash() == keccak256(bytes("")));
        assert(callbackToken.callbackResultSelector() == bytes4(0));
        assert(callbackParent.accrueCalls() == 2);
        assert(callbackToken.transferFromCalls() == 2);
        assert(callbackToken.balanceOf(DISTRIBUTOR) == 0);
        assert(callbackToken.balanceOf(address(callbackAdapter)) == assets);
    }

    function test_tokenCaughtNonzeroNestedRevertAppliesOuterDeltasOnce(uint128 assets, uint128 nestedAssets) public {
        vm.assume(nestedAssets > 0);
        USD8SavingsCallbackToken callbackToken = new USD8SavingsCallbackToken();
        USD8SavingsParent callbackParent = new USD8SavingsParent(address(callbackToken));
        USD8SavingsAdapter callbackAdapter = new USD8SavingsAdapter(address(callbackParent));
        callbackToken.setObservedParent(callbackParent);
        callbackToken.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        callbackToken.approve(address(callbackAdapter), assets);
        callbackToken.configureCallback(
            address(callbackAdapter), abi.encodeCall(USD8SavingsAdapter.receiveProfitDistribution, (nestedAssets))
        );
        vm.prank(DISTRIBUTOR);
        callbackAdapter.receiveProfitDistribution(assets);

        bytes memory expectedRevert = abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientAllowance.selector,
            address(callbackAdapter),
            uint256(0),
            uint256(nestedAssets)
        );
        assert(!callbackToken.callbackSuccess());
        assert(callbackToken.callbackResultLength() == expectedRevert.length);
        assert(callbackToken.callbackResultHash() == keccak256(expectedRevert));
        assert(callbackToken.callbackResultSelector() == IERC20Errors.ERC20InsufficientAllowance.selector);
        assert(callbackParent.accrueCalls() == 1);
        assert(callbackToken.transferFromCalls() == 1);
        assert(callbackToken.balanceOf(DISTRIBUTOR) == 0);
        assert(callbackToken.balanceOf(address(callbackAdapter)) == assets);
        assert(callbackToken.allowance(DISTRIBUTOR, address(callbackAdapter)) == 0);
    }
}
