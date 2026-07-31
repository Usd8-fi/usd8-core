// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {Registry} from "../../src/Registry.sol";
import {SingleAssetCoverPoolKontrolBase} from "./SingleAssetCoverPoolHarness.k.sol";

/// @notice Reward-stream accounting, checkpoint, failure-atomicity, and conservation properties.
contract SingleAssetCoverPoolRewardsKontrolTest is SingleAssetCoverPoolKontrolBase {
    function test_rewardGettersAreExactInZeroState() public view {
        assert(pool.rewardPerShare() == 0);
        assert(pool.rewardPerShareStored() == 0);
        (uint256 paid, uint256 accrued) = pool.rewardState(ALICE);
        assert(paid == 0);
        assert(accrued == 0);
    }

    function test_rewardGettersAreExactBeforeCheckpoint() public {
        uint256 shares = _deposit(ALICE, 100);
        pool.setRewardsDuration(10);
        _notify(BOB, 100);
        vm.warp(block.timestamp + 5);

        uint256 expectedLive = (5 * 10 * 1e30) / shares;
        assert(pool.rewardPerShare() == expectedLive);
        assert(pool.rewardPerShareStored() == 0);
        (uint256 paid, uint256 accrued) = pool.rewardState(ALICE);
        assert(paid == 0);
        assert(accrued == 0);
    }

    function test_rewardGettersAreExactAfterGlobalAndUserCheckpoint() public {
        uint256 shares = _deposit(ALICE, 100);
        pool.setRewardsDuration(10);
        _notify(CAROL, 100);
        vm.warp(block.timestamp + 5);
        uint256 expectedCheckpoint = (5 * 10 * 1e30) / shares;

        vm.prank(ALICE);
        pool.transfer(BOB, 1);

        assert(pool.rewardPerShare() == expectedCheckpoint);
        assert(pool.rewardPerShareStored() == expectedCheckpoint);
        (uint256 alicePaid, uint256 aliceAccrued) = pool.rewardState(ALICE);
        (uint256 bobPaid, uint256 bobAccrued) = pool.rewardState(BOB);
        assert(alicePaid == expectedCheckpoint);
        assert(aliceAccrued == 50);
        assert(bobPaid == expectedCheckpoint);
        assert(bobAccrued == 0);
    }

    function test_notificationRejectsZeroNoStakersAndPauseWithoutTakingRewards() public {
        rewardToken.mint(ALICE, 100);
        vm.prank(ALICE);
        rewardToken.approve(address(pool), 100);
        vm.prank(ALICE);
        (bool noStakers, bytes memory nsd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.receiveProfitDistribution, (uint256(100))));
        _assertExactFourByteError(noStakers, nsd, SingleAssetCoverPool.NoEligibleStakers.selector);
        assert(rewardToken.balanceOf(ALICE) == 100 && pool.rewardReserve() == 0);

        _deposit(ALICE, 10);
        vm.prank(ALICE);
        (bool zero, bytes memory zd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.receiveProfitDistribution, (uint256(0))));
        _assertExactFourByteError(zero, zd, SingleAssetCoverPool.ZeroAmount.selector);
        registry.setPaused(address(pool), true);
        vm.prank(ALICE);
        (bool paused, bytes memory pd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.receiveProfitDistribution, (uint256(100))));
        _assertExactFourByteError(paused, pd, Registry.Paused.selector);
        assert(rewardToken.balanceOf(ALICE) == 100 && pool.rewardReserve() == 0);
    }

    function test_exactScheduleAndSingleStakerClaimConserveRewardReserve() public {
        _deposit(ALICE, 100);
        pool.setRewardsDuration(10);
        uint64 finish = uint64(block.timestamp + 10);
        _notify(BOB, 100);
        assert(pool.rewardRate() == 10);
        assert(pool.lastUpdateTime() == block.timestamp);
        assert(pool.periodFinish() == finish);
        assert(pool.rewardReserve() == 100);

        vm.warp(finish);
        assert(pool.earned(ALICE) == 100);
        vm.prank(ALICE);
        assert(pool.claimReward() == 100);
        assert(rewardToken.balanceOf(ALICE) == 100);
        assert(pool.rewardReserve() == 0);
        assert(pool.earned(ALICE) == 0);
    }

    function test_twoEqualStakersSplitCompletedScheduleExactly() public {
        _deposit(ALICE, 100);
        _deposit(BOB, 100);
        pool.setRewardsDuration(10);
        _notify(CAROL, 100);
        vm.warp(block.timestamp + 10);
        assert(pool.earned(ALICE) == 50 && pool.earned(BOB) == 50);
        vm.prank(ALICE);
        assert(pool.claimReward() == 50);
        vm.prank(BOB);
        assert(pool.claimReward() == 50);
        assert(pool.rewardReserve() == 0);
        assert(rewardToken.balanceOf(ALICE) == 50 && rewardToken.balanceOf(BOB) == 50);
    }

    function test_transferCheckpointsSenderAndReceiverAcrossTwoIntervals() public {
        _deposit(ALICE, 100);
        pool.setRewardsDuration(10);
        _notify(CAROL, 100);
        vm.warp(block.timestamp + 5);
        uint256 half = pool.balanceOf(ALICE) / 2;
        vm.prank(ALICE);
        pool.transfer(BOB, half);
        vm.warp(block.timestamp + 5);
        assert(pool.earned(ALICE) == 75);
        assert(pool.earned(BOB) == 25);
        vm.prank(ALICE);
        pool.claimReward();
        vm.prank(BOB);
        pool.claimReward();
        assert(pool.rewardReserve() == 0);
    }

    function test_requestedExitSharesStopEarningButPriorAccrualRemainsClaimable() public {
        uint256 shares = _deposit(ALICE, 100);
        pool.setRewardsDuration(10);
        _notify(BOB, 100);
        vm.warp(block.timestamp + 5);
        _request(ALICE, shares);
        vm.warp(block.timestamp + 5);
        assert(pool.earned(ALICE) == 50);
        vm.prank(ALICE);
        assert(pool.claimReward() == 50);
        assert(pool.rewardReserve() == 50);
        assert(pool.balanceOf(address(pool)) == shares);
    }

    function test_zeroEarnerActiveStreamDefersWindowUntilLaterDepositorAndConservesReserve() public {
        uint256 shares = _deposit(ALICE, 10);
        pool.setRewardsDuration(10);
        _notify(CAROL, 100);
        uint64 originalFinish = pool.periodFinish();

        vm.warp(block.timestamp + 2);
        _request(ALICE, shares);
        assert(pool.earned(ALICE) == 20);
        assert(pool.rewardReserve() == 100);

        vm.warp(block.timestamp + 3);
        _deposit(BOB, 10);
        assert(pool.periodFinish() == originalFinish + 3);
        assert(pool.rewardReserve() == 100);

        vm.warp(pool.periodFinish());
        assert(pool.earned(ALICE) == 20);
        assert(pool.earned(BOB) == 80);
        vm.prank(ALICE);
        assert(pool.claimReward() == 20);
        vm.prank(BOB);
        assert(pool.claimReward() == 80);
        assert(pool.rewardReserve() == 0);
        assert(rewardToken.balanceOf(ALICE) + rewardToken.balanceOf(BOB) == 100);
    }

    function test_overlappingDistributionUsesExactWeightedSchedule() public {
        _deposit(ALICE, 100);
        pool.setRewardsDuration(10);
        _notify(BOB, 100);
        vm.warp(block.timestamp + 5);
        _notify(BOB, 50);
        // Remaining reward is 50 over 5 seconds. Weighted duration is
        // (50*5 + 50*10) / 100 = 7, so the accepted flooring rate is 14.
        assert(pool.rewardRate() == 14);
        assert(pool.periodFinish() == block.timestamp + 7);
        assert(pool.rewardReserve() == 150);
        vm.warp(block.timestamp + 7);
        assert(pool.earned(ALICE) == 148);
        vm.prank(ALICE);
        assert(pool.claimReward() == 148);
        assert(pool.rewardReserve() == 2);
    }

    function test_rateZeroAndTooHighFailuresRollbackTransferAndSchedule() public {
        _deposit(ALICE, 1);
        pool.setRewardsDuration(10);
        rewardToken.mint(BOB, 1);
        vm.prank(BOB);
        rewardToken.approve(address(pool), 1);
        vm.prank(BOB);
        (bool rateZero, bytes memory rzd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.receiveProfitDistribution, (uint256(1))));
        assert(!rateZero);
        assert(
            keccak256(rzd)
                == keccak256(
                    abi.encodeWithSelector(SingleAssetCoverPool.RewardRateZero.selector, uint256(1), uint256(10))
                )
        );
        assert(rewardToken.balanceOf(BOB) == 1 && pool.rewardReserve() == 0 && pool.rewardRate() == 0);

        pool.setRewardsDuration(1);
        uint256 huge = uint256(type(uint128).max) + 1;
        rewardToken.mint(BOB, huge);
        vm.prank(BOB);
        rewardToken.approve(address(pool), huge);
        vm.prank(BOB);
        (bool tooHigh, bytes memory thd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.receiveProfitDistribution, (huge)));
        _assertExactFourByteError(tooHigh, thd, SingleAssetCoverPool.RewardRateTooHigh.selector);
        assert(rewardToken.balanceOf(BOB) == huge + 1);
        assert(pool.rewardReserve() == 0 && pool.rewardRate() == 0 && pool.periodFinish() == 0);
    }

    function test_zeroClaimAndPausedClaimDoNotMutateAccrual() public {
        _deposit(ALICE, 10);
        vm.prank(ALICE);
        assert(pool.claimReward() == 0);
        pool.setRewardsDuration(10);
        _notify(BOB, 100);
        vm.warp(block.timestamp + 5);
        uint256 earnedBefore = pool.earned(ALICE);
        registry.setPaused(address(pool), true);
        vm.prank(ALICE);
        (bool paused, bytes memory pd) = address(pool).call(abi.encodeCall(SingleAssetCoverPool.claimReward, ()));
        _assertExactFourByteError(paused, pd, Registry.Paused.selector);
        assert(pool.earned(ALICE) == earnedBefore);
        assert(pool.rewardReserve() == 100);
        assert(rewardToken.balanceOf(ALICE) == 0);
    }
}
