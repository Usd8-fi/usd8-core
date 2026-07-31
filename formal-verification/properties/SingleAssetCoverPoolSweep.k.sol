// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {Registry} from "../../src/Registry.sol";
import {CoverPoolHarnessToken, SingleAssetCoverPoolKontrolBase} from "./SingleAssetCoverPoolHarness.k.sol";

contract CoverPoolForceETH {
    constructor(address target) payable {
        selfdestruct(payable(target));
    }
}

contract CoverPoolRejectETH {
    receive() external payable {
        revert("reject");
    }
}

/// @notice Pool-specific surplus sweep accounting and SharedBase failure-atomicity properties.
contract SingleAssetCoverPoolSweepKontrolTest is SingleAssetCoverPoolKontrolBase {
    receive() external payable {}

    function test_assetSweepTransfersOnlyBalanceAbovePrincipalAccounting() public {
        _deposit(ALICE, 10);
        assetToken.mint(address(pool), 3);
        pool.sweepToken(assetToken, RECIPIENT);
        assert(assetToken.balanceOf(RECIPIENT) == 3);
        assert(assetToken.balanceOf(address(pool)) == 10);
        assert(pool.totalAssets() == 10);
    }

    function test_assetSweepAlsoProtectsSettledWithdrawalReserve() public {
        uint256 shares = _deposit(ALICE, 10);
        uint64 epoch = _request(ALICE, shares);
        vm.warp(epoch);
        pool.settleMaturedExitEpochs(1);
        assetToken.mint(address(pool), 3);
        pool.sweepToken(assetToken, RECIPIENT);
        assert(assetToken.balanceOf(RECIPIENT) == 3);
        assert(assetToken.balanceOf(address(pool)) == 10);
        assert(pool.withdrawalReserve() == 10);
        vm.prank(ALICE);
        assert(pool.completeRedeem(ALICE) == 10);
    }

    function test_rewardSweepTransfersOnlyDonationAboveCommittedReserve() public {
        _deposit(ALICE, 10);
        pool.setRewardsDuration(10);
        _notify(BOB, 100);
        rewardToken.mint(address(pool), 7);
        pool.sweepToken(rewardToken, RECIPIENT);
        assert(rewardToken.balanceOf(RECIPIENT) == 7);
        assert(rewardToken.balanceOf(address(pool)) == 100);
        assert(pool.rewardReserve() == 100);
    }

    function test_sameAssetAndRewardTokenProtectionIsAdditive() public {
        Registry localRegistry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        CoverPoolHarnessToken common = new CoverPoolHarnessToken("Common", "COMMON", 18);
        localRegistry.setUsd8(address(common));
        SingleAssetCoverPool localPool = SingleAssetCoverPool(
            address(
                new ERC1967Proxy(
                    address(new SingleAssetCoverPool()),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (localRegistry, IERC20(address(common)), "Common Pool", "cpCOMMON")
                    )
                )
            )
        );
        common.mint(ALICE, 10);
        vm.startPrank(ALICE);
        common.approve(address(localPool), 10);
        localPool.deposit(10, ALICE);
        vm.stopPrank();
        localPool.setRewardsDuration(10);
        common.mint(BOB, 100);
        vm.startPrank(BOB);
        common.approve(address(localPool), 100);
        localPool.receiveProfitDistribution(100);
        vm.stopPrank();
        common.mint(address(localPool), 3);

        localPool.sweepToken(common, RECIPIENT);
        assert(common.balanceOf(RECIPIENT) == 3);
        assert(common.balanceOf(address(localPool)) == 110);
        assert(localPool.totalAssets() == 10);
        assert(localPool.rewardReserve() == 100);
    }

    function test_sameTokenSweepProtectsSimultaneousActiveWithdrawalAndRewardReserves() public {
        Registry localRegistry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        CoverPoolHarnessToken common = new CoverPoolHarnessToken("Common", "COMMON", 18);
        localRegistry.setUsd8(address(common));
        SingleAssetCoverPool localPool = SingleAssetCoverPool(
            address(
                new ERC1967Proxy(
                    address(new SingleAssetCoverPool()),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (localRegistry, IERC20(address(common)), "Common Pool", "cpCOMMON")
                    )
                )
            )
        );
        common.mint(ALICE, 10);
        common.mint(BOB, 110);
        vm.startPrank(ALICE);
        common.approve(address(localPool), 10);
        uint256 aliceShares = localPool.deposit(10, ALICE);
        localPool.requestRedeem(aliceShares);
        vm.stopPrank();
        localPool.setRewardsDuration(10);
        vm.startPrank(BOB);
        common.approve(address(localPool), 110);
        localPool.deposit(10, BOB);
        localPool.receiveProfitDistribution(100);
        vm.stopPrank();
        (, uint64 epoch) = localPool.exitRequests(ALICE);
        vm.warp(epoch);
        localPool.settleMaturedExitEpochs(1);
        common.mint(address(localPool), 7);

        localPool.sweepToken(common, RECIPIENT);
        assert(common.balanceOf(RECIPIENT) == 7);
        assert(common.balanceOf(address(localPool)) == 120);
        assert(localPool.totalAssets() == 10);
        assert(localPool.withdrawalReserve() == 10);
        assert(localPool.rewardReserve() == 100);
    }

    function test_poolSharesAreNeverSweepableAndUnrelatedTokenSweepsFully() public {
        uint256 shares = _deposit(ALICE, 10);
        _request(ALICE, shares);
        (bool protected, bytes memory pd) =
            address(pool).call(abi.encodeCall(pool.sweepToken, (IERC20(address(pool)), RECIPIENT)));
        assert(!protected);
        assert(keccak256(pd) == keccak256(abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(pool))));
        assert(pool.balanceOf(address(pool)) == shares);

        CoverPoolHarnessToken stray = new CoverPoolHarnessToken("Stray", "STRAY", 18);
        stray.mint(address(pool), 9);
        pool.sweepToken(stray, RECIPIENT);
        assert(stray.balanceOf(RECIPIENT) == 9 && stray.balanceOf(address(pool)) == 0);
    }

    function test_tokenSweepAclRecipientAndNothingFailuresAreAtomic() public {
        assetToken.mint(address(pool), 3);
        (bool outsider, bytes memory od) =
            _callPoolAs(OUTSIDER, abi.encodeCall(pool.sweepToken, (IERC20(address(assetToken)), RECIPIENT)));
        assert(!outsider);
        assert(keccak256(od) == keccak256(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, OUTSIDER)));
        (bool zero, bytes memory zd) =
            address(pool).call(abi.encodeCall(pool.sweepToken, (IERC20(address(assetToken)), address(0))));
        _assertExactFourByteError(zero, zd, SharedBase.ZeroAddress.selector);
        (bool self, bytes memory sd) =
            address(pool).call(abi.encodeCall(pool.sweepToken, (IERC20(address(assetToken)), address(pool))));
        assert(!self);
        assert(
            keccak256(sd) == keccak256(abi.encodeWithSelector(SharedBase.InvalidSweepRecipient.selector, address(pool)))
        );
        assert(assetToken.balanceOf(address(pool)) == 3);
        pool.sweepToken(assetToken, RECIPIENT);
        (bool empty, bytes memory ed) =
            address(pool).call(abi.encodeCall(pool.sweepToken, (IERC20(address(assetToken)), RECIPIENT)));
        assert(!empty);
        assert(
            keccak256(ed) == keccak256(abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(assetToken)))
        );
    }

    function test_ethSweepSuccessAndAllFailureBranchesAreAtomic() public {
        vm.deal(address(this), 2 ether);
        new CoverPoolForceETH{value: 1 ether}(address(pool));
        uint256 recipientBefore = RECIPIENT.balance;
        pool.sweepETH(payable(RECIPIENT));
        assert(RECIPIENT.balance == recipientBefore + 1 ether && address(pool).balance == 0);

        (bool empty, bytes memory ed) = address(pool).call(abi.encodeCall(pool.sweepETH, (payable(RECIPIENT))));
        assert(!empty);
        assert(keccak256(ed) == keccak256(abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(0))));
        new CoverPoolForceETH{value: 1 ether}(address(pool));
        (bool outsider, bytes memory od) = _callPoolAs(OUTSIDER, abi.encodeCall(pool.sweepETH, (payable(RECIPIENT))));
        assert(!outsider);
        assert(keccak256(od) == keccak256(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, OUTSIDER)));
        (bool zero, bytes memory zd) = address(pool).call(abi.encodeCall(pool.sweepETH, (payable(address(0)))));
        _assertExactFourByteError(zero, zd, SharedBase.ZeroAddress.selector);
        (bool self, bytes memory sd) = address(pool).call(abi.encodeCall(pool.sweepETH, (payable(address(pool)))));
        assert(!self);
        assert(
            keccak256(sd) == keccak256(abi.encodeWithSelector(SharedBase.InvalidSweepRecipient.selector, address(pool)))
        );

        CoverPoolRejectETH reject = new CoverPoolRejectETH();
        (bool rejected, bytes memory rd) = address(pool).call(abi.encodeCall(pool.sweepETH, (payable(address(reject)))));
        _assertExactFourByteError(rejected, rd, SharedBase.EthTransferFailed.selector);
        assert(address(pool).balance == 1 ether);
    }
}
