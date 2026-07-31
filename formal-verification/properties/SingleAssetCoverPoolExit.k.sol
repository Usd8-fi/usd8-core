// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {Registry} from "../../src/Registry.sol";
import {SingleAssetCoverPoolKontrolBase} from "./SingleAssetCoverPoolHarness.k.sol";

/// @notice Async redemption epoch, reserve, loss exposure, queue bound, and endpoint properties.
contract SingleAssetCoverPoolExitKontrolTest is SingleAssetCoverPoolKontrolBase {
    function test_exitEpochIsCooldownRoundedUpToBatchBoundary() public {
        uint256 shares = _deposit(ALICE, 10);
        Registry.ExitTimingConfig memory config = registry.exitTimingConfig();
        uint256 requestedAt = block.timestamp;
        uint64 epoch = _request(ALICE, shares);
        uint256 earliest = requestedAt + config.unstakeCooldown;
        uint64 expected = uint64(Math.ceilDiv(earliest, config.exitBatchInterval) * config.exitBatchInterval);
        (uint256 storedShares, uint64 storedEpoch) = pool.exitRequests(ALICE);
        assert(epoch == expected && storedEpoch == expected);
        assert(storedShares == shares);
        assert(epoch >= earliest);
        assert(uint256(epoch) - earliest < config.exitBatchInterval);
        assert(pool.balanceOf(ALICE) == 0);
        assert(pool.balanceOf(address(pool)) == shares);
        (uint256 totalShares,, uint256 remainingShares,) = pool.exitEpochs(epoch);
        assert(totalShares == shares && remainingShares == 0);
    }

    function test_timingConfigChangeUsesFutureConfigButClampsToOutstandingTail() public {
        uint256 aliceShares = _deposit(ALICE, 10);
        uint256 bobShares = _deposit(BOB, 10);
        uint64 aliceEpoch = _request(ALICE, aliceShares);
        registry.setExitTimingConfig(Registry.ExitTimingConfig({unstakeCooldown: 1 days, exitBatchInterval: 1 hours}));
        vm.warp(block.timestamp + 1);
        uint64 unclampedBobEpoch = uint64(Math.ceilDiv(block.timestamp + 1 days, 1 hours) * 1 hours);
        uint64 bobEpoch = _request(BOB, bobShares);
        (, uint64 storedAlice) = pool.exitRequests(ALICE);
        Registry.ExitTimingConfig memory config = registry.exitTimingConfig();
        assert(storedAlice == aliceEpoch);
        assert(unclampedBobEpoch < aliceEpoch);
        assert(bobEpoch == aliceEpoch);
        assert(config.unstakeCooldown == 1 days);
        assert(config.exitBatchInterval == 1 hours);
    }

    function test_settledQueueTailDoesNotOverrideFutureConfig() public {
        uint256 aliceShares = _deposit(ALICE, 10);
        uint256 bobShares = _deposit(BOB, 10);
        uint64 aliceEpoch = _request(ALICE, aliceShares);
        vm.warp(aliceEpoch);
        assert(pool.settleMaturedExitEpochs(1) == 1);
        assert(pool.nextExitEpochIndex() == 1);

        registry.setExitTimingConfig(Registry.ExitTimingConfig({unstakeCooldown: 1, exitBatchInterval: 1}));
        uint64 bobEpoch = _request(BOB, bobShares);
        (, uint64 storedBob) = pool.exitRequests(BOB);
        assert(bobEpoch == uint64(block.timestamp + 1));
        assert(storedBob == bobEpoch);
        assert(bobEpoch > aliceEpoch);
    }

    function test_requestRejectsZeroExcessDuplicateAndPausedAtomically() public {
        uint256 shares = _deposit(ALICE, 10);
        vm.prank(ALICE);
        (bool zero, bytes memory zd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.requestRedeem, (uint256(0))));
        _assertExactFourByteError(zero, zd, SingleAssetCoverPool.ZeroAmount.selector);
        vm.prank(ALICE);
        (bool excess, bytes memory ed) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.requestRedeem, (shares + 1)));
        assert(!excess);
        assert(
            keccak256(ed)
                == keccak256(
                    abi.encodeWithSelector(SingleAssetCoverPool.InsufficientShares.selector, shares + 1, shares)
                )
        );
        assert(pool.balanceOf(ALICE) == shares && pool.balanceOf(address(pool)) == 0);
        uint256 firstRequest = shares - 1;
        uint64 firstEpoch = _request(ALICE, firstRequest);
        vm.prank(ALICE);
        (bool duplicate, bytes memory dd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.requestRedeem, (uint256(1))));
        _assertExactFourByteError(duplicate, dd, SingleAssetCoverPool.UnstakeRequestExists.selector);
        (uint256 pendingAfter, uint64 epochAfter) = pool.exitRequests(ALICE);
        assert(pendingAfter == firstRequest && epochAfter == firstEpoch);
        assert(pool.balanceOf(ALICE) == 1);

        uint256 bobShares = _deposit(BOB, 10);
        registry.setPaused(address(pool), true);
        vm.prank(BOB);
        (bool paused, bytes memory pd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.requestRedeem, (bobShares)));
        _assertExactFourByteError(paused, pd, Registry.Paused.selector);
        assert(pool.balanceOf(BOB) == bobShares);
    }

    function test_requestDuringIncidentRemainsAvailableAndLossExposed() public {
        uint256 shares = _deposit(ALICE, 100);
        _freeze();
        uint64 epoch = _request(ALICE, shares);
        assert(pool.balanceOf(address(pool)) == shares);
        vm.warp(epoch);
        (bool frozen, bytes memory data) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.settleMaturedExitEpochs, (uint256(1))));
        _assertExactFourByteError(frozen, data, SingleAssetCoverPool.PoolFrozen.selector);

        insurance.pay(pool, RECIPIENT, 40);
        assert(pool.totalAssets() == 60);
        _unfreeze();
        assert(pool.settleMaturedExitEpochs(1) == 1);
        (uint256 totalShares, uint256 assets, uint256 remainingShares, uint256 remainingAssets) = pool.exitEpochs(epoch);
        assert(totalShares == shares && assets == 60);
        assert(remainingShares == shares && remainingAssets == assets);
        assert(pool.withdrawalReserve() == 60);
    }

    function test_sameEpochAggregatesSharesAndCreatesOneQueueEntry() public {
        uint256 aliceShares = _deposit(ALICE, 10);
        uint256 bobShares = _deposit(BOB, 20);
        uint64 aliceEpoch = _request(ALICE, aliceShares);
        uint64 bobEpoch = _request(BOB, bobShares);
        assert(aliceEpoch == bobEpoch);
        (uint256 totalShares,,,) = pool.exitEpochs(aliceEpoch);
        assert(totalShares == aliceShares + bobShares);
        vm.warp(aliceEpoch);
        assert(pool.settleMaturedExitEpochs(10) == 1);
        assert(pool.nextExitEpochIndex() == 1);
        assert(pool.settleMaturedExitEpochs(10) == 0);
        assert(pool.nextExitEpochIndex() == 1);
    }

    function test_settlementMaxEpochBoundZeroOneAndUnmaturedBreak() public {
        registry.setExitTimingConfig(Registry.ExitTimingConfig({unstakeCooldown: 10, exitBatchInterval: 10}));
        uint256 aliceShares = _deposit(ALICE, 10);
        uint64 first = _request(ALICE, aliceShares);
        _freeze(); // keep the first matured epoch queued while the second request is filed
        vm.warp(block.timestamp + 11);
        _unfreeze();
        uint256 bobShares = _deposit(BOB, 10);
        _freeze();
        uint64 second = _request(BOB, bobShares);
        _unfreeze();
        assert(second > first);

        vm.warp(first);
        assert(pool.settleMaturedExitEpochs(0) == 0);
        assert(pool.nextExitEpochIndex() == 0);
        assert(pool.settleMaturedExitEpochs(10) == 1);
        assert(pool.nextExitEpochIndex() == 1);
        (,, uint256 secondRemainingShares,) = pool.exitEpochs(second);
        assert(secondRemainingShares == 0);
        vm.warp(second);
        assert(pool.settleMaturedExitEpochs(1) == 1);
        assert(pool.nextExitEpochIndex() == 2);
    }

    function test_partialEpochSettlementUsesIndependentOZFormulaAndConservesAssets() public {
        uint256 aliceShares = _deposit(ALICE, 100);
        _deposit(BOB, 100);
        uint256 requested = aliceShares / 2;
        uint64 epoch = _request(ALICE, requested);
        uint256 accountedBefore = pool.totalAssets();
        uint256 supplyBefore = pool.totalSupply();
        uint256 expectedAssets = Math.mulDiv(requested, accountedBefore + 1, supplyBefore + 1000);
        vm.warp(epoch);
        assert(pool.settleMaturedExitEpochs(1) == 1);
        (uint256 totalShares, uint256 totalAssets, uint256 remainingShares, uint256 remainingAssets) =
            pool.exitEpochs(epoch);
        assert(totalShares == requested && remainingShares == requested);
        assert(totalAssets == expectedAssets && remainingAssets == expectedAssets);
        assert(pool.totalAssets() == accountedBefore - expectedAssets);
        assert(pool.withdrawalReserve() == expectedAssets);
        assert(pool.totalSupply() == supplyBefore - requested);
        assert(pool.balanceOf(address(pool)) == 0);
    }

    function test_boundedSymbolicSettlementAccountingUsesIndependentFormula(
        uint64 aliceAssets,
        uint64 bobAssets,
        uint64 requestSeed
    ) public {
        vm.assume(aliceAssets > 0 && bobAssets > 0);
        uint256 aliceShares = _deposit(ALICE, aliceAssets);
        _deposit(BOB, bobAssets);
        uint256 requested = uint256(requestSeed) % aliceShares + 1;
        uint64 epoch = _request(ALICE, requested);
        uint256 assetsBefore = pool.totalAssets();
        uint256 supplyBefore = pool.totalSupply();
        uint256 expected = Math.mulDiv(requested, assetsBefore + 1, supplyBefore + 1000);
        vm.warp(epoch);
        pool.settleMaturedExitEpochs(1);
        assert(pool.totalAssets() + pool.withdrawalReserve() == assetsBefore);
        assert(pool.withdrawalReserve() == expected);
        assert(pool.totalSupply() == supplyBefore - requested);
        (uint256 totalShares, uint256 totalAssets, uint256 remainingShares, uint256 remainingAssets) =
            pool.exitEpochs(epoch);
        assert(totalShares == requested && remainingShares == requested);
        assert(totalAssets == expected && remainingAssets == expected);
    }

    function test_finalShareEpochDrainsAllActiveAssetsWithoutVirtualDust() public {
        uint256 shares = _deposit(ALICE, 7);
        uint64 epoch = _request(ALICE, shares);
        assetToken.mint(address(pool), 3); // surplus is not active accounting
        vm.warp(epoch);
        pool.settleMaturedExitEpochs(1);
        (, uint256 reserved, uint256 remainingShares,) = pool.exitEpochs(epoch);
        assert(remainingShares == shares && reserved == 7);
        assert(pool.totalAssets() == 0);
        assert(pool.totalSupply() == 0);
        assert(pool.withdrawalReserve() == 7);
        assert(assetToken.balanceOf(address(pool)) == 10);
    }

    function test_completeBeforeCooldownAndInvalidRecipientAndNoRequestRevert() public {
        uint256 shares = _deposit(ALICE, 10);
        uint64 epoch = _request(ALICE, shares);
        vm.prank(BOB);
        (bool none, bytes memory nd) = address(pool).call(abi.encodeCall(SingleAssetCoverPool.completeRedeem, (BOB)));
        _assertExactFourByteError(none, nd, SingleAssetCoverPool.NoUnstakeRequest.selector);
        vm.prank(ALICE);
        (bool zero, bytes memory zd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.completeRedeem, (address(0))));
        _assertExactFourByteError(zero, zd, SingleAssetCoverPool.InvalidRecipient.selector);
        vm.prank(ALICE);
        (bool self, bytes memory sd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.completeRedeem, (address(pool))));
        _assertExactFourByteError(self, sd, SingleAssetCoverPool.InvalidRecipient.selector);
        vm.prank(ALICE);
        (bool early, bytes memory ed) = address(pool).call(abi.encodeCall(SingleAssetCoverPool.completeRedeem, (ALICE)));
        assert(!early);
        assert(
            keccak256(ed) == keccak256(abi.encodeWithSelector(SingleAssetCoverPool.CooldownNotElapsed.selector, epoch))
        );
        (, uint64 storedEpoch) = pool.exitRequests(ALICE);
        assert(storedEpoch == epoch);
        assert(pool.withdrawalReserve() == 0 && assetToken.balanceOf(ALICE) == 0);
    }

    function test_completeAutoSettlesMaturedEpochAndPaysChosenReceiver() public {
        uint256 shares = _deposit(ALICE, 10);
        uint64 epoch = _request(ALICE, shares);
        vm.warp(epoch);
        vm.prank(ALICE);
        uint256 assets = pool.completeRedeem(RECIPIENT);
        assert(assets == 10);
        assert(assetToken.balanceOf(RECIPIENT) == 10);
        assert(pool.withdrawalReserve() == 0);
        assert(pool.totalAssets() == 0 && pool.totalSupply() == 0);
        (uint256 pending,) = pool.exitRequests(ALICE);
        assert(pending == 0);
        (,, uint256 remainingShares, uint256 remainingAssets) = pool.exitEpochs(epoch);
        assert(remainingShares == 0 && remainingAssets == 0);
    }

    function test_twoClaimantsConserveEpochReserveAndLastClaimantDrainsRoundingDust() public {
        uint256 aliceShares = _deposit(ALICE, 1);
        uint256 bobShares = _deposit(BOB, 2);
        uint64 epoch = _request(ALICE, aliceShares);
        assert(_request(BOB, bobShares) == epoch);
        vm.warp(epoch);
        pool.settleMaturedExitEpochs(1);
        (uint256 totalShares, uint256 epochAssets, uint256 remainingSharesBefore, uint256 remainingAssetsBefore) =
            pool.exitEpochs(epoch);
        assert(remainingSharesBefore == totalShares && remainingAssetsBefore == epochAssets);

        vm.prank(ALICE);
        uint256 aliceAssets = pool.completeRedeem(ALICE);
        (, uint256 reserveAfterAlice,, uint256 remainingAfterAlice) = pool.exitEpochs(epoch);
        assert(reserveAfterAlice == epochAssets);
        assert(remainingAfterAlice == epochAssets - aliceAssets);
        vm.prank(BOB);
        uint256 bobAssets = pool.completeRedeem(BOB);
        assert(aliceAssets + bobAssets == epochAssets);
        assert(pool.withdrawalReserve() == 0);
        (,, uint256 remainingShares, uint256 remainingAssets) = pool.exitEpochs(epoch);
        assert(remainingShares == 0 && remainingAssets == 0);
    }

    function test_settledReserveRemainsClaimableDuringIncidentAndCannotFundClaim() public {
        uint256 shares = _deposit(ALICE, 10);
        uint64 epoch = _request(ALICE, shares);
        vm.warp(epoch);
        pool.settleMaturedExitEpochs(1);
        assert(pool.totalAssets() == 0 && pool.withdrawalReserve() == 10);
        _freeze();

        (bool payout, bytes memory data) =
            address(insurance).call(abi.encodeCall(insurance.pay, (pool, RECIPIENT, uint256(1))));
        assert(!payout);
        assert(
            keccak256(data)
                == keccak256(
                    abi.encodeWithSelector(
                        SingleAssetCoverPool.PayoutExceedsPoolAssets.selector, uint256(1), uint256(0)
                    )
                )
        );
        assert(pool.totalAssets() == 0 && pool.withdrawalReserve() == 10);
        assert(assetToken.balanceOf(address(pool)) == 10 && assetToken.balanceOf(RECIPIENT) == 0);
        vm.prank(ALICE);
        uint256 assets = pool.completeRedeem(ALICE);
        assert(assets == 10);
        assert(assetToken.balanceOf(ALICE) == 10);
        assert(pool.withdrawalReserve() == 0);
    }

    function test_pausedCompleteAndFrozenUnsettledCompleteRevertWithoutDeletingReceipt() public {
        uint256 shares = _deposit(ALICE, 10);
        uint64 epoch = _request(ALICE, shares);
        vm.warp(epoch);
        registry.setPaused(address(pool), true);
        vm.prank(ALICE);
        (bool paused, bytes memory pd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.completeRedeem, (ALICE)));
        _assertExactFourByteError(paused, pd, Registry.Paused.selector);
        registry.setPaused(address(pool), false);
        _freeze();
        vm.prank(ALICE);
        (bool frozen, bytes memory fd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.completeRedeem, (ALICE)));
        _assertExactFourByteError(frozen, fd, SingleAssetCoverPool.PoolFrozen.selector);
        (uint256 pending, uint64 storedEpoch) = pool.exitRequests(ALICE);
        assert(pending == shares && storedEpoch == epoch);
        assert(pool.withdrawalReserve() == 0);
    }
}
