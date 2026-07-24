// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {VaultV2} from "vault-v2/src/VaultV2.sol";
import {VaultV2Factory} from "vault-v2/src/VaultV2Factory.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {USD8SavingsAdapter} from "../../src/adapters/USD8SavingsAdapter.sol";

contract USD8SavingsHandler is Test {
    MockERC20 public immutable asset;
    VaultV2 public immutable vault;
    USD8SavingsAdapter public immutable adapter;
    address[2] internal actors;

    uint256 public ghostMinted;
    uint256 public successfulDeposits;
    uint256 public successfulRedemptions;
    uint256 public successfulProfitDistributions;
    uint256 public successfulWarps;
    uint256 public successfulShareTransfers;

    constructor(MockERC20 asset_, VaultV2 vault_, USD8SavingsAdapter adapter_, address actorA, address actorB) {
        asset = asset_;
        vault = vault_;
        adapter = adapter_;
        actors = [actorA, actorB];
    }

    function mintActor(uint256 actorSeed, uint256 amountSeed) external {
        address actor_ = actors[bound(actorSeed, 0, 1)];
        uint256 amount = bound(amountSeed, 0, 1e24);
        asset.mint(actor_, amount);
        ghostMinted += amount;
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        address actor_ = actors[bound(actorSeed, 0, 1)];
        uint256 balance = asset.balanceOf(actor_);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.startPrank(actor_);
        asset.approve(address(vault), amount);
        vault.deposit(amount, actor_);
        vm.stopPrank();
        successfulDeposits++;
    }

    function redeem(uint256 actorSeed, uint256 sharesSeed) external {
        address actor_ = actors[bound(actorSeed, 0, 1)];
        uint256 shares = vault.balanceOf(actor_);
        if (shares == 0) return;
        uint256 amount = bound(sharesSeed, 1, shares);
        vm.prank(actor_);
        vault.redeem(amount, actor_, actor_);
        successfulRedemptions++;
    }

    function distributeProfit(uint256 actorSeed, uint256 amountSeed) external {
        address actor_ = actors[bound(actorSeed, 0, 1)];
        uint256 balance = asset.balanceOf(actor_);
        if (balance == 0 || vault.totalSupply() == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.startPrank(actor_);
        asset.approve(address(adapter), amount);
        adapter.receiveProfitDistribution(amount);
        vm.stopPrank();
        successfulProfitDistributions++;
    }

    function warpForward(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 365 days));
        successfulWarps++;
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 sharesSeed) external {
        address from = actors[bound(fromSeed, 0, 1)];
        address to = actors[bound(toSeed, 0, 1)];
        if (from == to) return;
        uint256 balance = vault.balanceOf(from);
        if (balance == 0) return;
        uint256 shares = bound(sharesSeed, 1, balance);
        vm.prank(from);
        assertTrue(vault.transfer(to, shares), "savings share transfer failed");
        successfulShareTransfers++;
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }
}

contract USD8SavingsInvariantTest is StdInvariant, Test {
    MockERC20 asset;
    VaultV2 vault;
    USD8SavingsAdapter adapter;
    USD8SavingsHandler handler;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    function setUp() public {
        asset = new MockERC20("USD8", "USD8", 18);
        VaultV2Factory factory = new VaultV2Factory();
        vault = VaultV2(factory.createVaultV2(address(this), address(asset), bytes32("sUSD8")));
        adapter = new USD8SavingsAdapter(address(vault));
        _configureAdapter();

        handler = new USD8SavingsHandler(asset, vault, adapter, ALICE, BOB);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = USD8SavingsHandler.mintActor.selector;
        selectors[1] = USD8SavingsHandler.deposit.selector;
        selectors[2] = USD8SavingsHandler.redeem.selector;
        selectors[3] = USD8SavingsHandler.distributeProfit.selector;
        selectors[4] = USD8SavingsHandler.warpForward.selector;
        selectors[5] = USD8SavingsHandler.transferShares.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_ProductiveSavingsBranchesAreReachable() public {
        handler.mintActor(0, 1_000e18);
        handler.deposit(0, 800e18);
        handler.transferShares(0, 1, 100e18);
        handler.distributeProfit(0, 100e18);
        handler.warpForward(180 days);
        handler.redeem(0, 200e18);

        assertGt(handler.successfulDeposits(), 0);
        assertGt(handler.successfulProfitDistributions(), 0);
        assertGt(handler.successfulWarps(), 0);
        assertGt(handler.successfulRedemptions(), 0);
        assertGt(handler.successfulShareTransfers(), 0);
    }

    function invariant_underlyingSupplyIsFullyConserved() public view {
        uint256 accounted = asset.balanceOf(ALICE) + asset.balanceOf(BOB) + asset.balanceOf(address(vault))
            + asset.balanceOf(address(adapter));
        assertEq(asset.totalSupply(), handler.ghostMinted(), "mint ghost drift");
        assertEq(accounted, asset.totalSupply(), "underlying conservation");
    }

    function invariant_allSharesBelongToKnownActors() public view {
        assertEq(vault.totalSupply(), vault.balanceOf(ALICE) + vault.balanceOf(BOB), "share conservation");
    }

    function invariant_adapterAllocationNeverExceedsControlledAssets() public view {
        assertLe(vault.allocation(adapter.adapterId()), asset.balanceOf(address(adapter)), "allocation exceeds assets");
    }

    function invariant_realAssetsMatchesAdapterPolicy() public view {
        uint256 allocation = vault.allocation(adapter.adapterId());
        uint256 expected = allocation == 0 ? 0 : asset.balanceOf(address(adapter));
        assertEq(adapter.realAssets(), expected, "realAssets policy drift");
    }

    function invariant_reportedAssetsNeverExceedControlledAssets() public view {
        uint256 controlled = asset.balanceOf(address(vault)) + asset.balanceOf(address(adapter));
        assertLe(vault.totalAssets(), controlled, "vault reports unbacked assets");
    }

    function invariant_liquidityAdapterKeepsVaultIdleBalanceEmpty() public view {
        assertEq(asset.balanceOf(address(vault)), 0, "idle assets bypassed adapter");
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
