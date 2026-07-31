// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {SingleAssetCoverPoolKontrolBase} from "./SingleAssetCoverPoolHarness.k.sol";

/// @notice Kontrol-supported first-log obligations for the pool's compiled ABI.
/// @dev Later application logs that follow reserve/reward/share ERC20 Transfer logs
///      are isolated in SingleAssetCoverPoolEventOrdering.t.sol because Kontrol
///      v1.0.255 cannot advance expectEmit past an earlier unmatched log.
contract SingleAssetCoverPoolEventsKontrolTest is SingleAssetCoverPoolKontrolBase {
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event DepositCapSet(uint256 newCap);
    event ETHSwept(address indexed to, uint256 amount);
    event RegistryChanged(address indexed oldRegistry, address indexed newRegistry);
    event RewardsDurationSet(uint64 oldDuration, uint64 newDuration);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function _deployUninitializedPool() internal returns (SingleAssetCoverPool fresh) {
        // A successful non-mutating delegatecall avoids initializer logs during
        // construction while retaining the production ERC1967 proxy boundary.
        fresh = SingleAssetCoverPool(
            address(new ERC1967Proxy(address(new SingleAssetCoverPool()), abi.encodeWithSignature("totalAssets()")))
        );
    }

    function test_initializeEmitsRegistryChangedFirst() public {
        SingleAssetCoverPool fresh = _deployUninitializedPool();
        vm.expectEmit(true, true, false, true, address(fresh));
        emit RegistryChanged(address(0), address(registry));
        fresh.initialize(registry, IERC20(address(assetToken)), "Fresh Cover", "cpFRESH");
    }

    function test_approveEmitsExactApproval(uint256 value) public {
        vm.expectEmit(true, true, false, true, address(pool));
        emit Approval(ALICE, BOB, value);
        vm.prank(ALICE);
        pool.approve(BOB, value);
    }

    function test_transferEmitsExactTransfer(uint96 assets, uint96 value) public {
        vm.assume(assets > 0);
        uint256 shares = _deposit(ALICE, assets);
        vm.assume(value <= shares);

        vm.expectEmit(true, true, false, true, address(pool));
        emit Transfer(ALICE, BOB, value);
        vm.prank(ALICE);
        pool.transfer(BOB, value);
    }

    function test_setDepositCapEmitsExactCap(uint128 cap) public {
        vm.expectEmit(false, false, false, true, address(pool));
        emit DepositCapSet(cap);
        pool.setDepositCap(cap);
    }

    function test_setRewardsDurationEmitsOldThenNewDuration(uint64 duration) public {
        vm.assume(duration > 0 && duration <= pool.MAX_REWARDS_DURATION());
        uint64 oldDuration = pool.rewardsDuration();
        vm.expectEmit(false, false, false, true, address(pool));
        emit RewardsDurationSet(oldDuration, duration);
        pool.setRewardsDuration(duration);
    }

    function test_sweepETHEmitsExactRecipientAndAmount(uint128 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(pool), amount);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ETHSwept(RECIPIENT, amount);
        pool.sweepETH(payable(RECIPIENT));
    }
}
