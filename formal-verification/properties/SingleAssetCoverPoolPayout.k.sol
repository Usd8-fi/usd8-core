// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {Registry} from "../../src/Registry.sol";
import {SingleAssetCoverPoolKontrolBase} from "./SingleAssetCoverPoolHarness.k.sol";

/// @notice Insurance payout authorization, cap, accounting, and failure-atomicity properties.
contract SingleAssetCoverPoolPayoutKontrolTest is SingleAssetCoverPoolKontrolBase {
    function test_maxPayoutTracksActiveAssetsAndRegistryBpsExactly(uint128 assets, uint16 bps) public {
        vm.assume(assets > 0);
        vm.assume(bps > 0 && bps < 10_000);
        _deposit(ALICE, assets);
        registry.setMaxCoverPoolPayoutBps(bps);
        assert(pool.maxPayoutPerIncident() == uint256(assets) * bps / 10_000);
    }

    function test_authorizedZeroPayoutIsNoOpButPoolRecipientAlwaysRejects() public {
        _deposit(ALICE, 10);
        uint256 accountedBefore = pool.totalAssets();
        uint256 recipientBefore = assetToken.balanceOf(RECIPIENT);
        insurance.pay(pool, RECIPIENT, 0);
        assert(pool.totalAssets() == accountedBefore);
        assert(assetToken.balanceOf(RECIPIENT) == recipientBefore);

        (bool self, bytes memory sd) =
            address(insurance).call(abi.encodeCall(insurance.pay, (pool, address(pool), uint256(0))));
        _assertExactFourByteError(self, sd, SingleAssetCoverPool.InvalidRecipient.selector);
        assert(pool.totalAssets() == accountedBefore);
    }

    function test_unauthorizedAndPausedPayoutsRevertBeforeStateChanges() public {
        _deposit(ALICE, 10);
        (bool unauthorized, bytes memory ud) =
            _callPoolAs(OUTSIDER, abi.encodeCall(SingleAssetCoverPool.payClaim, (RECIPIENT, uint256(1))));
        assert(!unauthorized);
        assert(
            keccak256(ud) == keccak256(abi.encodeWithSelector(SingleAssetCoverPool.NotDefiInsurance.selector, OUTSIDER))
        );
        registry.setPaused(address(pool), true);
        (bool paused, bytes memory pd) =
            address(insurance).call(abi.encodeCall(insurance.pay, (pool, RECIPIENT, uint256(1))));
        _assertExactFourByteError(paused, pd, Registry.Paused.selector);
        assert(pool.totalAssets() == 10);
        assert(assetToken.balanceOf(RECIPIENT) == 0);
    }

    function test_partialAndFullPayoutsReduceOnlyActiveAccountingExactly() public {
        _deposit(ALICE, 10);
        insurance.pay(pool, RECIPIENT, 4);
        assert(pool.totalAssets() == 6);
        assert(assetToken.balanceOf(address(pool)) == 6);
        assert(assetToken.balanceOf(RECIPIENT) == 4);
        insurance.pay(pool, RECIPIENT, 6);
        assert(pool.totalAssets() == 0);
        assert(assetToken.balanceOf(address(pool)) == 0);
        assert(assetToken.balanceOf(RECIPIENT) == 10);
        assert(pool.totalSupply() > 0);
    }

    function test_excessPayoutRevertsAndPreservesAccountingAndBalances() public {
        _deposit(ALICE, 10);
        (bool success, bytes memory data) =
            address(insurance).call(abi.encodeCall(insurance.pay, (pool, RECIPIENT, uint256(11))));
        assert(!success);
        assert(
            keccak256(data)
                == keccak256(
                    abi.encodeWithSelector(
                        SingleAssetCoverPool.PayoutExceedsPoolAssets.selector, uint256(11), uint256(10)
                    )
                )
        );
        assert(pool.totalAssets() == 10);
        assert(assetToken.balanceOf(address(pool)) == 10);
        assert(assetToken.balanceOf(RECIPIENT) == 0);
    }
}
