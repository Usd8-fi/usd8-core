// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultV2} from "vault-v2/src/VaultV2.sol";
import {VaultV2Factory} from "vault-v2/src/VaultV2Factory.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {USD8SavingsAdapter} from "../../src/adapters/USD8SavingsAdapter.sol";
import {USD8SavingsAdapterFactory} from "../../src/adapters/USD8SavingsAdapterFactory.sol";

contract USD8SavingsAdapterTest is Test {
    MockERC20 asset;
    VaultV2 vault;
    USD8SavingsAdapterFactory adapterFactory;
    USD8SavingsAdapter adapter;

    function setUp() public {
        asset = new MockERC20("USD8", "USD8", 18);
        VaultV2Factory vaultFactory = new VaultV2Factory();
        vault = VaultV2(vaultFactory.createVaultV2(address(this), address(asset), bytes32("sUSD8")));
        adapterFactory = new USD8SavingsAdapterFactory();
        adapter = USD8SavingsAdapter(adapterFactory.createUSD8SavingsAdapter(address(vault)));
    }

    function test_FactoryCreatesCorrectlyBoundAdapter() public {
        assertEq(adapter.factory(), address(adapterFactory));
        assertEq(adapter.parentVault(), address(vault));
        assertEq(adapter.asset(), address(asset));
        assertEq(adapter.adapterId(), keccak256(abi.encode("this", address(adapter))));
        assertEq(adapterFactory.usd8SavingsAdapter(address(vault)), address(adapter));
        assertTrue(adapterFactory.isUSD8SavingsAdapter(address(adapter)));
    }

    function test_DepositRoutesAssetsToAdapterAndReportsActualBalance() public {
        _configureAdapter();
        asset.mint(address(this), 100e18);
        asset.approve(address(vault), 100e18);

        uint256 shares = vault.deposit(100e18, address(this));

        assertEq(shares, 100e18);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(adapter)), 100e18);
        assertEq(adapter.realAssets(), 100e18);
        assertEq(vault.totalAssets(), 100e18);
    }

    /// forge-config: default.isolate = true
    function test_ProfitDistributionIsHeldAndReleasedThroughMorphoMaxRate() public {
        _configureAdapter();
        asset.mint(address(this), 120e18);
        asset.approve(address(vault), 100e18);
        vault.deposit(100e18, address(this));

        asset.approve(address(adapter), 20e18);
        adapter.receiveProfitDistribution(20e18);

        assertEq(asset.balanceOf(address(adapter)), 120e18);
        assertEq(vault.totalAssets(), 100e18, "profit must not jump share price in donation block");

        vm.warp(block.timestamp + 365 days);
        assertApproxEqAbs(vault.totalAssets(), 120e18, 1e10);
        assertApproxEqAbs(vault.convertToAssets(100e18), 120e18, 1e10);
    }

    /// forge-config: default.isolate = true
    function test_ProfitHookCheckpointsBeforeDonationAfterLongIdlePeriod() public {
        _configureAdapter();
        asset.mint(address(this), 120e18);
        asset.approve(address(vault), 100e18);
        vault.deposit(100e18, address(this));

        vm.warp(block.timestamp + 180 days);
        asset.approve(address(adapter), 20e18);
        adapter.receiveProfitDistribution(20e18);

        assertEq(vault.totalAssets(), 100e18, "pre-donation idle time must not release new profit");
        vm.warp(block.timestamp + 180 days);
        assertGt(vault.totalAssets(), 109e18);
    }

    /// forge-config: default.isolate = true
    function test_ProfitablePartialAndFullRedemptionsKeepAllocationSynchronized() public {
        _configureAdapter();
        asset.mint(address(this), 120e18);
        asset.approve(address(vault), 100e18);
        vault.deposit(100e18, address(this));
        asset.transfer(address(adapter), 20e18);
        vm.warp(block.timestamp + 365 days);

        uint256 firstAssets = vault.redeem(50e18, address(this), address(this));

        assertGt(firstAssets, 50e18);
        assertEq(vault.allocation(adapter.adapterId()), asset.balanceOf(address(adapter)));

        vm.warp(block.timestamp + 1 days);
        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        assertEq(vault.allocation(adapter.adapterId()), asset.balanceOf(address(adapter)));
        assertLe(asset.balanceOf(address(adapter)), 1);
    }

    /// forge-config: default.isolate = true
    function test_SameBlockJITDepositCannotCaptureBufferedProfit() public {
        _configureAdapter();
        asset.mint(address(this), 120e18);
        asset.approve(address(vault), 100e18);
        vault.deposit(100e18, address(this));
        asset.transfer(address(adapter), 20e18);

        address attacker = makeAddr("attacker");
        asset.mint(attacker, 100e18);
        vm.startPrank(attacker);
        asset.approve(address(vault), 100e18);
        uint256 shares = vault.deposit(100e18, attacker);
        uint256 returnedAssets = vault.redeem(shares, attacker, attacker);
        vm.stopPrank();

        assertLe(returnedAssets, 100e18);
    }

    function test_OnlyVaultMayCallAdapterHooks() public {
        vm.expectRevert(USD8SavingsAdapter.NotAuthorized.selector);
        adapter.allocate("", 0, bytes4(0), address(this));

        vm.expectRevert(USD8SavingsAdapter.NotAuthorized.selector);
        adapter.deallocate("", 0, bytes4(0), address(this));
    }

    function test_AdapterRejectsNonEmptyLiquidityData() public {
        _configureAdapter();
        vm.expectRevert(USD8SavingsAdapter.InvalidData.selector);
        vault.allocate(address(adapter), hex"01", 0);
    }

    function test_AdapterRejectsAllocationAboveSignedRange() public {
        asset.mint(address(adapter), uint256(type(int256).max) + 1);
        vm.prank(address(vault));
        vm.expectRevert(USD8SavingsAdapter.AllocationTooLarge.selector);
        adapter.allocate("", 0, bytes4(0), address(this));
    }

    function _configureAdapter() internal {
        vault.setCurator(address(this));
        _execute(abi.encodeCall(IVaultV2.setIsAllocator, (address(this), true)));
        _execute(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));

        bytes memory idData = abi.encode("this", address(adapter));
        _execute(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        _execute(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));

        vault.setMaxRate(20e16 / uint256(365 days));
        vault.setLiquidityAdapterAndData(address(adapter), "");
    }

    function _execute(bytes memory data) internal {
        vault.submit(data);
        (bool success, bytes memory returnData) = address(vault).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
