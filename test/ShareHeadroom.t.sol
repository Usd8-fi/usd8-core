// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Registry} from "../src/Registry.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {USD8} from "../src/USD8.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title L-02 regression: share supply must stop short of the ERC-4626 virtual-share
///        limit so conversions, and therefore exits, never overflow.
contract ShareHeadroomTest is Test {
    MockERC20 usdc;
    USD8 usd8;
    Registry registry;
    SingleAssetCoverPool pool;

    address admin = address(0xA11CE);
    address alice = address(0xBEEF);
    address bob = address(0xB0B);
    address constant FEED = address(0xFEED);

    uint256 constant VS = 1e3; // 10 ** _decimalsOffset()
    uint256 constant LIMIT = type(uint256).max - VS;

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

    /// @dev Push supply to the exact safe limit, then prove the next share is refused
    ///      through both ERC-4626 entry points while the limits report zero.
    function test_MintingStopsAtVirtualShareHeadroom() public {
        _fillToLimit(alice);
        assertEq(pool.totalSupply(), LIMIT);
        assertEq(pool.maxMint(bob), 0);
        assertEq(pool.maxDeposit(bob), 0);

        usdc.mint(bob, 10);
        vm.startPrank(bob);
        usdc.approve(address(pool), 10);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, bob, 1, 0));
        pool.mint(1, bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, bob, 1, 0));
        pool.deposit(1, bob);
        vm.stopPrank();

        // Conversions remain well-defined at the limit.
        pool.convertToAssets(1);
        pool.convertToShares(1);
    }

    /// @dev Auditor's bricking path: one holder keeps a single share while the rest
    ///      queue for exit, so settlement uses the partial-supply conversion. At the
    ///      safe limit it settles and pays.
    function test_PartialSupplyExitSettlesAtLimit() public {
        _fillToLimit(alice);
        vm.prank(alice);
        pool.transfer(bob, 1);

        uint256 aliceShares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestRedeem(aliceShares);

        vm.warp(block.timestamp + 10 days);
        pool.settleMaturedExitEpochs(1);
        vm.prank(alice);
        uint256 paid = pool.completeRedeem(alice);
        assertGt(paid, 0, "exit must pay out");
        assertEq(pool.totalSupply(), 1, "only Bob's share remains");
        assertEq(pool.maxMint(bob), LIMIT - 1, "headroom reopened after burn");
    }

    /// @dev The cap and the headroom compose: whichever is smaller binds.
    function test_HeadroomComposesWithDepositCap() public {
        assertEq(pool.maxMint(alice), LIMIT, "uncapped pool reports headroom");
        assertEq(pool.maxDeposit(alice), LIMIT / VS, "uncapped empty pool reports headroom in assets");

        vm.prank(admin);
        pool.setDepositCap(100e6);
        assertEq(pool.maxDeposit(alice), 100e6);
        assertEq(pool.maxMint(alice), 100e6 * VS);
    }

    /// @dev Reach `totalSupply == LIMIT` exactly: a first deposit at the 1:VS initial
    ///      rate, then mint the remainder.
    function _fillToLimit(address who) internal {
        uint256 assets = LIMIT / VS;
        usdc.mint(who, type(uint256).max / 2);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(assets, who);
        uint256 rest = LIMIT - pool.totalSupply();
        if (rest != 0) pool.mint(rest, who);
        vm.stopPrank();
    }
}
