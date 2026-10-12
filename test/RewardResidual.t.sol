// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Registry} from "../src/Registry.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {USD8} from "../src/USD8.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title L-01 regression: funded rewards must not be stranded by per-checkpoint
///        flooring once earning shares outgrow the hourly scaled emission.
contract RewardResidualTest is Test {
    MockERC20 usdc;
    USD8 usd8;
    Registry registry;
    SingleAssetCoverPool pool;

    address admin = address(0xA11CE);
    address alice = address(0xBEEF);
    address bob = address(0xB0B);
    address griefer = address(0x6121);
    address constant FEED = address(0xFEED);

    /// @dev The pool mints shares at a 1e3 decimals offset, so this stake yields
    ///      1e34 earning shares: one hour at rate 1 wei/s (3600 * 1e30 scaled
    ///      units = 3.6e33) divides to zero, while the full 7-day stream does not.
    uint256 constant BIG_STAKE = 1e31;
    uint256 constant BIG_SHARES = 1e34;

    function setUp() public {
        vm.etch(FEED, hex"00");
        vm.mockCall(FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(
            FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(1e8), uint256(1), uint256(1), uint80(1))
        );
        usdc = new MockERC20("USDC", "USDC", 6);
        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (admin, admin))))
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        vm.startPrank(admin);
        registry.setUsd8(address(usd8));
        registry.setTreasury(admin);
        vm.stopPrank();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new SingleAssetCoverPool()), admin);
        pool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(SingleAssetCoverPool.initialize, (registry, IERC20(address(usdc)), "Cover", "cp"))
                )
            )
        );
        vm.prank(admin);
        registry.addPool(address(pool), FEED);
    }

    /// @dev Auditor scenario: a 7-day stream checkpointed hourly by a shareless
    ///      account's zero-value self-transfers. Every hourly slice floors to zero
    ///      without a residual carry; with it, the staker still earns the stream.
    function test_HourlyCheckpointsDoNotStrandRewards() public {
        _stake(alice, BIG_STAKE);
        uint256 stream = 7 days; // rate = 1 wei/s
        _notify(stream);

        for (uint256 i = 0; i < 168; i++) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(griefer);
            pool.transfer(griefer, 0);
        }

        uint256 earned = pool.earned(alice);
        assertGt(earned, 0, "rewards stranded by per-checkpoint flooring");
        // Loss is bounded by one scaled share unit: < BIG_SHARES / 1e30 wei.
        assertApproxEqAbs(earned, stream, BIG_SHARES / 1e30 + 1, "staker should earn ~the whole stream");

        vm.prank(alice);
        uint256 paid = pool.claimReward();
        assertEq(paid, earned);
        assertEq(usd8.balanceOf(alice), paid);
    }

    /// @dev Fragmented checkpoints must credit the same total as one checkpoint.
    function test_FragmentedCheckpointsConserveRewards() public {
        _stake(alice, BIG_STAKE);
        _notify(7 days);
        uint256 snap = vm.snapshotState();

        vm.warp(block.timestamp + 7 days);
        vm.prank(griefer);
        pool.transfer(griefer, 0);
        uint256 single = pool.earned(alice);

        vm.revertToState(snap);
        for (uint256 i = 0; i < 168; i++) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(griefer);
            pool.transfer(griefer, 0);
        }
        uint256 fragmented = pool.earned(alice);

        assertEq(fragmented, single, "checkpoint fragmentation changed credited rewards");
        assertLt(pool.rewardResidual(), pool.totalSupply(), "residual bounded by earning shares");
    }

    /// @dev Residual accumulated under one share count is spent at the next, so no
    ///      scaled units are lost when earning shares change mid-stream.
    function test_ResidualCarriesAcrossShareChanges() public {
        _stake(alice, BIG_STAKE);
        _notify(7 days);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(griefer);
        pool.transfer(griefer, 0);
        uint256 residualBefore = pool.rewardResidual();
        assertGt(residualBefore, 0);

        _stake(bob, BIG_STAKE); // checkpoints, then doubles earning shares
        vm.warp(block.timestamp + 7 days);
        vm.prank(griefer);
        pool.transfer(griefer, 0);

        uint256 total = pool.earned(alice) + pool.earned(bob);
        // Everything streamed is credited up to dust well below 1 wei per share unit.
        assertApproxEqAbs(total, 7 days, 2 * BIG_SHARES / 1e30 + 2, "stream not conserved across share change");
        // Accepted trade-off: the first hour floored to residual under Alice's
        // share count alone and is credited under the doubled count, so it is
        // shared with Bob rather than discarded.
        assertEq(pool.earned(alice), pool.earned(bob), "carried residual is credited at the new share count");
    }

    function _stake(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        pool.deposit(amount, who);
        vm.stopPrank();
    }

    function _notify(uint256 amount) internal {
        vm.startPrank(admin);
        usd8.mint(admin, amount);
        usd8.approve(address(pool), amount);
        pool.receiveProfitDistribution(amount);
        vm.stopPrank();
    }
}
