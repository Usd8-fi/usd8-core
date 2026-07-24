// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";
import {Treasury} from "../../src/Treasury.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";

contract TreasuryHandler is Test {
    uint256 internal constant SCALE = 1e12;
    address internal constant LOSS_SINK = address(0xDEAD);

    Registry public registry;
    USD8 public usd8;
    Treasury public treasury;
    MockERC20 public usdc;
    MockStrategy public strategy;
    MockStrategy public strategy2;
    MockStrategy public strategy3;
    address public timelock;
    address public admin;
    address public yieldReceiver;

    address[5] public actors;
    uint256 public ghostUserMinted;
    uint256 public ghostHarvested;
    uint256 public ghostPendingRevenue;
    uint256 public ghostDistributedRevenue;
    uint256 public ghostBurned;
    uint256 public ghostReserve;

    constructor(
        Registry registry_,
        USD8 usd8_,
        Treasury treasury_,
        MockERC20 usdc_,
        MockStrategy strategy_,
        MockStrategy strategy2_,
        MockStrategy strategy3_,
        address timelock_,
        address admin_,
        address yieldReceiver_
    ) {
        registry = registry_;
        usd8 = usd8_;
        treasury = treasury_;
        usdc = usdc_;
        strategy = strategy_;
        strategy2 = strategy2_;
        strategy3 = strategy3_;
        timelock = timelock_;
        admin = admin_;
        yieldReceiver = yieldReceiver_;
        actors = [address(0xA11), address(0xB0B), address(0xCA1), address(0xD00D), address(0xE11)];
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function mint(uint256 actorSeed, uint256 amount) external {
        if (registry.paused(address(treasury))) return;
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1e15);

        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 supplyBefore = usd8.totalSupply();
        uint256 actorBalanceBefore = usd8.balanceOf(actor);

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(treasury), amount);
        treasury.mintUSD8(amount);
        vm.stopPrank();

        uint256 minted = amount * SCALE;
        ghostUserMinted += minted;
        ghostReserve += amount;
        assertEq(treasury.getReserveBalance(), reserveBefore + amount, "mint reserve delta");
        assertEq(usd8.totalSupply(), supplyBefore + minted, "mint supply delta");
        assertEq(usd8.balanceOf(actor), actorBalanceBefore + minted, "mint receiver delta");
    }

    function redeem(uint256 actorSeed, uint256 amount) external {
        if (registry.paused(address(treasury))) return;
        address actor = _actor(actorSeed);
        uint256 actorUsd8 = usd8.balanceOf(actor);
        if (actorUsd8 == 0) return;
        amount = bound(amount, 1, actorUsd8);

        uint256 supplyBefore = usd8.totalSupply();
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 reserveInUsd8 = reserveBefore * SCALE;
        uint256 effectiveCollateral = reserveInUsd8 < supplyBefore ? reserveInUsd8 : supplyBefore;
        uint256 expectedUsdc = Math.mulDiv(amount, effectiveCollateral, supplyBefore) / SCALE;
        uint256 accessible = usdc.balanceOf(address(treasury));
        if (!strategy.withdrawReverts()) accessible += usdc.balanceOf(address(strategy));
        if (!strategy2.withdrawReverts()) accessible += usdc.balanceOf(address(strategy2));
        if (!strategy3.withdrawReverts()) accessible += usdc.balanceOf(address(strategy3));
        if (expectedUsdc > accessible) return;
        uint256 actorUsdcBefore = usdc.balanceOf(actor);

        vm.prank(actor);
        treasury.redeemUSD8(amount, expectedUsdc);

        ghostBurned += amount;
        ghostReserve -= expectedUsdc;
        assertEq(usd8.totalSupply(), supplyBefore - amount, "redeem supply delta");
        assertEq(usdc.balanceOf(actor), actorUsdcBefore + expectedUsdc, "redeem payout");
        assertEq(treasury.getReserveBalance(), reserveBefore - expectedUsdc, "redeem reserve delta");
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = usd8.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(from);
        assertTrue(usd8.transfer(to, amount), "transfer failed");
    }

    function donateReserve(uint256 amount) external {
        amount = bound(amount, 1, 1e15);
        usdc.mint(address(treasury), amount);
        ghostReserve += amount;
    }

    function allocateToStrategy(uint256 strategySeed, uint256 amount) external {
        if (registry.paused(address(treasury))) return;
        uint256 idle = usdc.balanceOf(address(treasury));
        if (idle == 0) return;
        amount = bound(amount, 1, idle);
        vm.prank(admin);
        treasury.depositToStrategy(_strategy(strategySeed), amount);
    }

    function withdrawFromStrategy(uint256 strategySeed, uint256 amount) external {
        if (registry.paused(address(treasury))) return;
        MockStrategy selected = _strategy(strategySeed);
        if (selected.withdrawReverts()) return;
        uint256 available = usdc.balanceOf(address(selected));
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(admin);
        treasury.withdrawFromStrategy(selected, amount);
    }

    function donateUsd8Revenue(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 balance = usd8.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(actor);
        assertTrue(usd8.transfer(address(treasury), amount), "revenue donation transfer failed");
        ghostPendingRevenue += amount;
    }

    function addStrategyYield(uint256 strategySeed, uint256 amount) external {
        amount = bound(amount, 1, 1e15);
        usdc.mint(address(_strategy(strategySeed)), amount);
        ghostReserve += amount;
    }

    function realizeStrategyLoss(uint256 strategySeed, uint256 amount) external {
        MockStrategy selected = _strategy(strategySeed);
        uint256 available = usdc.balanceOf(address(selected));
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(address(selected));
        assertTrue(usdc.transfer(LOSS_SINK, amount), "loss transfer failed");
        ghostReserve -= amount;
    }

    function setStrategyWithdrawFailure(uint256 strategySeed, bool reverts_) external {
        _strategy(strategySeed).setWithdrawReverts(reverts_);
    }

    function harvest() external {
        if (registry.paused(address(treasury))) return;
        uint256 supplyBefore = usd8.totalSupply();
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 treasuryRevenueBefore = usd8.balanceOf(address(treasury));
        uint256 receiverBefore = usd8.balanceOf(yieldReceiver);
        uint256 retain = supplyBefore + supplyBefore / treasury.HARVEST_BUFFER_DIVISOR();
        uint256 reserveInUsd8 = reserveBefore * SCALE;
        uint256 expectedHarvest = reserveInUsd8 > retain ? reserveInUsd8 - retain : 0;
        uint256 expectedDistribution = treasuryRevenueBefore + expectedHarvest;

        vm.prank(admin);
        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();
        ghostHarvested += expectedHarvest;
        ghostDistributedRevenue += expectedDistribution;
        ghostPendingRevenue = 0;

        assertEq(harvested, expectedHarvest, "harvest formula");
        assertEq(distributed, expectedDistribution, "distribution formula");
        assertEq(usd8.totalSupply(), supplyBefore + expectedHarvest, "harvest supply delta");
        assertEq(treasury.getReserveBalance(), reserveBefore, "harvest moved reserve");
        assertEq(usd8.balanceOf(yieldReceiver), receiverBefore + expectedDistribution, "receiver delta");
        assertEq(usd8.balanceOf(address(treasury)), 0, "revenue stranded");
    }

    function setPaused(bool paused) external {
        vm.prank(timelock);
        registry.setPaused(address(treasury), paused);
    }

    function redeemWithTooHighMinOut(uint256 actorSeed, uint256 amount) external {
        if (registry.paused(address(treasury))) return;
        address actor = _actor(actorSeed);
        uint256 actorUsd8 = usd8.balanceOf(actor);
        if (actorUsd8 == 0) return;
        amount = bound(amount, 1, actorUsd8);

        uint256 supply = usd8.totalSupply();
        uint256 reserve = treasury.getReserveBalance();
        uint256 effectiveCollateral = reserve * SCALE < supply ? reserve * SCALE : supply;
        uint256 expectedUsdc = Math.mulDiv(amount, effectiveCollateral, supply) / SCALE;

        uint256 actorUsdcBefore = usdc.balanceOf(actor);
        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(Treasury.InsufficientUsdcOut.selector, expectedUsdc, expectedUsdc + 1));
        treasury.redeemUSD8(amount, expectedUsdc + 1);

        assertEq(usd8.totalSupply(), supply, "failed redeem changed supply");
        assertEq(treasury.getReserveBalance(), reserve, "failed redeem changed reserve");
        assertEq(usdc.balanceOf(actor), actorUsdcBefore, "failed redeem paid USDC");
    }

    function pausedOperationsRemainAtomic(uint256 actorSeed, uint256 amount) external {
        if (!registry.paused(address(treasury))) return;
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1e15);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 reserveBefore = treasury.getReserveBalance();

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(treasury), amount);
        vm.expectRevert(Registry.Paused.selector);
        treasury.mintUSD8(amount);
        vm.stopPrank();

        uint256 actorUsd8 = usd8.balanceOf(actor);
        if (actorUsd8 != 0) {
            vm.prank(actor);
            vm.expectRevert(Registry.Paused.selector);
            treasury.redeemUSD8(bound(amount, 1, actorUsd8), 0);
        }

        vm.prank(admin);
        vm.expectRevert(Registry.Paused.selector);
        treasury.harvestAndDistribute();

        uint256 idle = usdc.balanceOf(address(treasury));
        if (idle != 0) {
            vm.prank(admin);
            vm.expectRevert(Registry.Paused.selector);
            treasury.depositToStrategy(strategy, 1);
        }

        assertEq(usd8.totalSupply(), supplyBefore, "paused operation changed supply");
        assertEq(treasury.getReserveBalance(), reserveBefore, "paused operation changed reserve");
    }

    function illiquidRedemptionIsAtomic(uint256 actorSeed, uint256 amount) external {
        if (registry.paused(address(treasury))) return;
        address actor = _actor(actorSeed);
        uint256 actorUsd8 = usd8.balanceOf(actor);
        if (actorUsd8 < SCALE) return;
        amount = bound(amount, SCALE, actorUsd8);

        uint256 idle = usdc.balanceOf(address(treasury));
        if (idle != 0) {
            vm.prank(admin);
            treasury.depositToStrategy(strategy, idle);
        }

        uint256 supply = usd8.totalSupply();
        uint256 reserve = treasury.getReserveBalance();
        uint256 effectiveCollateral = reserve * SCALE < supply ? reserve * SCALE : supply;
        uint256 expectedUsdc = Math.mulDiv(amount, effectiveCollateral, supply) / SCALE;
        if (expectedUsdc == 0) return;

        bool old1 = strategy.withdrawReverts();
        bool old2 = strategy2.withdrawReverts();
        bool old3 = strategy3.withdrawReverts();
        strategy.setWithdrawReverts(true);
        strategy2.setWithdrawReverts(true);
        strategy3.setWithdrawReverts(true);
        uint256 actorUsdcBefore = usdc.balanceOf(actor);
        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(Treasury.InsufficientLiquidity.selector, expectedUsdc, 0));
        treasury.redeemUSD8(amount, 0);
        strategy.setWithdrawReverts(old1);
        strategy2.setWithdrawReverts(old2);
        strategy3.setWithdrawReverts(old3);

        assertEq(usd8.totalSupply(), supply, "illiquid redeem changed supply");
        assertEq(treasury.getReserveBalance(), reserve, "illiquid redeem changed reserve");
        assertEq(usdc.balanceOf(actor), actorUsdcBefore, "illiquid redeem paid USDC");
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _strategy(uint256 seed) internal view returns (MockStrategy) {
        uint256 i = seed % 3;
        return i == 0 ? strategy : (i == 1 ? strategy2 : strategy3);
    }
}

contract TreasuryInvariantTest is StdInvariant, Test {
    address internal constant USDC_ADDR = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant TIMELOCK = address(0xA11CE);
    address internal constant ADMIN = address(0x57A7);
    address internal constant YIELD_RECEIVER = address(0xFEE);

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasury;
    MockERC20 internal usdc;
    MockStrategy internal strategy;
    MockStrategy internal strategy2;
    MockStrategy internal strategy3;
    TreasuryHandler internal handler;

    function setUp() public {
        MockERC20 template = new MockERC20("USD Coin", "USDC", 6);
        vm.etch(USDC_ADDR, address(template).code);
        usdc = MockERC20(USDC_ADDR);

        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (TIMELOCK, ADMIN))))
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        treasury = Treasury(
            address(
                new ERC1967Proxy(
                    address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry, IERC20(USDC_ADDR)))
                )
            )
        );
        strategy = new MockStrategy(usdc);
        strategy2 = new MockStrategy(usdc);
        strategy3 = new MockStrategy(usdc);

        vm.startPrank(TIMELOCK);
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(treasury));
        treasury.addStrategy(strategy, 0);
        treasury.addStrategy(strategy2, 1);
        treasury.addStrategy(strategy3, 2);
        treasury.setProfitReceiver(YIELD_RECEIVER, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        vm.stopPrank();

        handler = new TreasuryHandler(
            registry, usd8, treasury, usdc, strategy, strategy2, strategy3, TIMELOCK, ADMIN, YIELD_RECEIVER
        );

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = TreasuryHandler.mint.selector;
        selectors[1] = TreasuryHandler.redeem.selector;
        selectors[2] = TreasuryHandler.transfer.selector;
        selectors[3] = TreasuryHandler.donateReserve.selector;
        selectors[4] = TreasuryHandler.allocateToStrategy.selector;
        selectors[5] = TreasuryHandler.withdrawFromStrategy.selector;
        selectors[6] = TreasuryHandler.addStrategyYield.selector;
        selectors[7] = TreasuryHandler.realizeStrategyLoss.selector;
        selectors[8] = TreasuryHandler.harvest.selector;
        selectors[9] = TreasuryHandler.setPaused.selector;
        selectors[10] = TreasuryHandler.redeemWithTooHighMinOut.selector;
        selectors[11] = TreasuryHandler.illiquidRedemptionIsAtomic.selector;
        selectors[12] = TreasuryHandler.pausedOperationsRemainAtomic.selector;
        selectors[13] = TreasuryHandler.donateUsd8Revenue.selector;
        selectors[14] = TreasuryHandler.setStrategyWithdrawFailure.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_ProductiveMultiStrategyQueueSkipsFailureAndContinues() public {
        handler.mint(0, 300e6);
        handler.allocateToStrategy(0, 100e6);
        handler.allocateToStrategy(1, 100e6);
        handler.allocateToStrategy(2, 100e6);
        handler.setStrategyWithdrawFailure(0, true);

        handler.redeem(0, 150e18);

        assertEq(usdc.balanceOf(address(strategy)), 100e6, "reverting first strategy changed");
        assertEq(usdc.balanceOf(address(strategy2)), 0, "second strategy not drained first");
        assertEq(usdc.balanceOf(address(strategy3)), 50e6, "third strategy remainder wrong");
    }

    function invariant_supplyEqualsAuthorizedMintsMinusBurns() public view {
        assertEq(
            usd8.totalSupply(),
            handler.ghostUserMinted() + handler.ghostHarvested() - handler.ghostBurned(),
            "supply conservation"
        );
    }

    function invariant_reserveEqualsIdlePlusStrategyAssets() public view {
        assertEq(
            treasury.getReserveBalance(),
            usdc.balanceOf(address(treasury)) + usdc.balanceOf(address(strategy)) + usdc.balanceOf(address(strategy2))
                + usdc.balanceOf(address(strategy3)),
            "reserve composition"
        );
    }

    function invariant_reserveMatchesIndependentGhostAccounting() public view {
        assertEq(treasury.getReserveBalance(), handler.ghostReserve(), "tracked reserve mismatch");
    }

    function invariant_harvestedRevenueReachedReceiver() public view {
        assertEq(usd8.balanceOf(YIELD_RECEIVER), handler.ghostDistributedRevenue(), "receiver distribution mismatch");
    }

    function invariant_noRevenueIsStrandedInTreasury() public view {
        assertEq(usd8.balanceOf(address(treasury)), handler.ghostPendingRevenue(), "pending revenue mismatch");
    }

    function invariant_allUsd8IsAccountedFor() public view {
        uint256 accounted = usd8.balanceOf(YIELD_RECEIVER) + usd8.balanceOf(address(treasury));
        for (uint256 i = 0; i < 5; i++) {
            accounted += usd8.balanceOf(handler.actorAt(i));
        }
        assertEq(accounted, usd8.totalSupply(), "USD8 holder accounting");
    }

    function invariant_registryKeepsCanonicalTreasury() public view {
        assertEq(usd8.treasury(), address(treasury), "canonical Treasury");
    }
}
