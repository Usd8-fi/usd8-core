// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {Registry} from "../src/Registry.sol";
import {RegistryManaged} from "../src/RegistryManaged.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {LossyWithdrawStrategy} from "./mocks/LossyWithdrawStrategy.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IProfitDistributionReceiver} from "../src/interfaces/IProfitDistributionReceiver.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {VaultV2} from "vault-v2/src/VaultV2.sol";
import {VaultV2Factory} from "vault-v2/src/VaultV2Factory.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {USD8SavingsAdapter} from "../src/adapters/USD8SavingsAdapter.sol";
import {USD8SavingsAdapterFactory} from "../src/adapters/USD8SavingsAdapterFactory.sol";

contract NonPullingProfitReceiver is IProfitDistributionReceiver {
    function receiveProfitDistribution(uint256) external pure {}
}

contract TreasuryTest is Test {
    Registry registry;
    USD8 usd8;
    Treasury treasuryImpl;
    Treasury treasury;
    MockERC20 usdc;

    address constant USDC_ADDR = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address timelock = address(0xA11CE);
    address admin = address(0x57A7);
    address alice = address(0xBEEF);

    function _unauthorizedTimelock(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, account);
    }

    function _unauthorizedAdmin(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, account);
    }

    event Minted(address indexed user, uint256 usdcAmount, uint256 usd8Amount);
    event Redeemed(address indexed user, uint256 usd8Amount, uint256 usdcAmount);
    event PausedSet(address indexed target, bool paused);
    event TimelockChanged(address indexed oldAdmin, address indexed newTimelock);
    event AdminSet(address indexed account, bool allowed);
    event StrategyAdded(IStrategy indexed strategy);
    event StrategyRemoved(IStrategy indexed strategy);
    event DepositedToStrategy(IStrategy indexed strategy, uint256 amount);
    event WithdrawnFromStrategy(IStrategy indexed strategy, uint256 amount);
    event RevenueDistributed(address indexed recipient, uint256 amount);
    event RevenueHarvested(uint256 amount);
    event TokenSwept(address indexed token, address indexed to, uint256 amount);
    event ETHSwept(address indexed to, uint256 amount);

    function setUp() public {
        // Etch a controllable mock at the hardcoded USDC mainnet address so
        // the constant in Treasury resolves to a token we can mint with.
        MockERC20 template = new MockERC20("USD Coin", "USDC", 6);
        vm.etch(USDC_ADDR, address(template).code);
        usdc = MockERC20(USDC_ADDR);

        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (timelock, admin))))
        );
        USD8 impl = new USD8();
        bytes memory init = abi.encodeCall(USD8.initialize, (registry, address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        usd8 = USD8(address(proxy));
        treasuryImpl = new Treasury();
        treasury = Treasury(
            address(new ERC1967Proxy(address(treasuryImpl), abi.encodeCall(Treasury.initialize, (usd8, registry))))
        );
        vm.prank(timelock);
        usd8.setTreasury(address(treasury));

        assertEq(usd8.treasury(), address(treasury));
        assertEq(registry.timelock(), timelock);
        assertTrue(registry.isAdmin(admin));
    }

    function _deployMorphoSavings() internal returns (VaultV2 vault, USD8SavingsAdapter adapter) {
        VaultV2Factory factory = new VaultV2Factory();
        vault = VaultV2(factory.createVaultV2(address(this), address(usd8), keccak256("sUSD8")));
        adapter = USD8SavingsAdapter(new USD8SavingsAdapterFactory().createUSD8SavingsAdapter(address(vault)));
        vault.setCurator(address(this));
        _executeMorpho(vault, abi.encodeCall(IVaultV2.setIsAllocator, (address(this), true)));
        _executeMorpho(vault, abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        bytes memory idData = abi.encode("this", address(adapter));
        _executeMorpho(vault, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        _executeMorpho(vault, abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.setMaxRate(20e16 / uint256(365 days));
        vault.setLiquidityAdapterAndData(address(adapter), "");
    }

    function _executeMorpho(VaultV2 vault, bytes memory data) internal {
        vault.submit(data);
        (bool success, bytes memory returnData) = address(vault).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    function test_ConstantsMatchSpec() public view {
        assertEq(address(treasury.USDC()), USDC_ADDR);
        assertEq(treasury.USDC_TO_USD8_SCALE(), 1e12);
        assertEq(address(treasury.usd8()), address(usd8));
    }

    function test_ImplementationDisabled() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        treasuryImpl.initialize(usd8, registry);
    }

    function test_InitializeOnlyOnce() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        treasury.initialize(usd8, registry);
    }

    function test_InitializeRejectsNonContractUsd8() public {
        vm.expectRevert(abi.encodeWithSelector(Treasury.InvalidContract.selector, alice));
        new ERC1967Proxy(address(treasuryImpl), abi.encodeCall(Treasury.initialize, (USD8(alice), registry)));
    }

    function test_InitializeRejectsMismatchedRegistry() public {
        Registry otherRegistry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (timelock, admin))))
        );

        vm.expectRevert(
            abi.encodeWithSelector(Treasury.RegistryMismatch.selector, address(otherRegistry), address(registry))
        );
        new ERC1967Proxy(address(treasuryImpl), abi.encodeCall(Treasury.initialize, (usd8, otherRegistry)));
    }

    // -- Pause system (single strict pause) -------------------------------

    function test_PauseDefaultsToFalse() public view {
        assertFalse(registry.paused(address(treasury)));
    }

    function test_AdminCanSetPaused() public {
        vm.prank(timelock);
        vm.expectEmit(true, false, false, true, address(registry));
        emit PausedSet(address(treasury), true);
        registry.setPaused(address(treasury), true);
        assertTrue(registry.paused(address(treasury)));
    }

    function test_NonAdminCannotSetPaused() public {
        vm.expectRevert(_unauthorizedAdmin(alice));
        vm.prank(alice);
        registry.setPaused(address(treasury), true);
    }

    function test_PausedBlocksMintAndRedeem() public {
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        treasury.mintUSD8(1e6);
        vm.stopPrank();

        vm.prank(timelock);
        registry.setPaused(address(treasury), true);

        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        vm.expectRevert(Registry.Paused.selector);
        treasury.mintUSD8(1e6);
        vm.expectRevert(Registry.Paused.selector);
        treasury.redeemUSD8(1e18, 0);
        vm.stopPrank();
    }

    function test_PauseCanBeCleared() public {
        vm.startPrank(timelock);
        registry.setPaused(address(treasury), true);
        registry.setPaused(address(treasury), false);
        vm.stopPrank();

        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 1e6);
        treasury.mintUSD8(1e6);
        vm.stopPrank();

        assertEq(usd8.balanceOf(alice), 1e18);
    }

    function test_TimelockCanTransferTimelock() public {
        address newTimelock = address(0xC0FFEE);

        vm.prank(timelock);
        vm.expectEmit(true, true, false, true, address(registry));
        emit TimelockChanged(timelock, newTimelock);
        registry.setTimelock(newTimelock);

        assertEq(registry.timelock(), newTimelock);

        // Old timelock loses all role-gated access (it is not admin either).
        vm.expectRevert(_unauthorizedAdmin(timelock));
        vm.prank(timelock);
        registry.setPaused(address(treasury), true);

        vm.prank(newTimelock);
        registry.setPaused(address(treasury), true);
        assertTrue(registry.paused(address(treasury)));
    }

    function test_NonTimelockCannotTransferTimelock() public {
        vm.expectRevert(_unauthorizedTimelock(alice));
        vm.prank(alice);
        registry.setTimelock(alice);
    }

    function test_SetTimelockRejectsZero() public {
        vm.expectRevert(Registry.ZeroAddress.selector);
        vm.prank(timelock);
        registry.setTimelock(address(0));
    }

    function test_TimelockCanSetAdmin() public {
        address newAdmin = address(0xC0FFEE);
        MockStrategy strat = new MockStrategy(usdc);

        vm.prank(timelock);
        vm.expectEmit(true, false, false, true, address(registry));
        emit AdminSet(newAdmin, true);
        registry.setAdmin(newAdmin, true);

        assertTrue(registry.isAdmin(newAdmin));

        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);

        assertEq(treasury.strategiesLength(), 1);
    }

    function test_NonTimelockCannotSetAdmin() public {
        vm.expectRevert(_unauthorizedTimelock(alice));
        vm.prank(alice);
        registry.setAdmin(alice, true);
    }

    function test_SetAdminRejectsZero() public {
        vm.expectRevert(Registry.ZeroAddress.selector);
        vm.prank(timelock);
        registry.setAdmin(address(0), true);
    }

    function test_AdminCanRunStrategyFundFlows() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);

        usdc.mint(address(treasury), 25e6);

        vm.startPrank(admin);
        treasury.depositToStrategy(strat, 25e6);
        treasury.withdrawFromStrategy(strat, 25e6);
        vm.stopPrank();

        vm.prank(timelock);
        treasury.removeStrategy(strat);

        assertEq(treasury.strategiesLength(), 0);
    }

    function _newTreasury() internal returns (Treasury) {
        return Treasury(
            address(new ERC1967Proxy(address(new Treasury()), abi.encodeCall(Treasury.initialize, (usd8, registry))))
        );
    }

    /// @dev M-06: the Treasury may be re-pointed only before first issuance
    ///      (initial wiring). Once USD8 is live, setTreasury stays LOCKED even
    ///      after supply returns to zero, so the reserve anchor cannot move.
    function test_SetTreasuryLockedOnceSupplyExists() public {
        // Supply is still 0 here (setUp minted nothing) — a re-point is allowed.
        Treasury treasuryB = _newTreasury();
        vm.prank(timelock);
        usd8.setTreasury(address(treasuryB));
        assertEq(usd8.treasury(), address(treasuryB));

        // Mint so supply > 0.
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasuryB), 100e6);
        treasuryB.mintUSD8(100e6);
        vm.stopPrank();
        assertEq(usd8.totalSupply(), 100e18);

        // Now rotation is barred — no fragmenting backing from liabilities.
        Treasury treasuryC = _newTreasury();
        vm.prank(timelock);
        vm.expectRevert(USD8.TreasuryLocked.selector);
        usd8.setTreasury(address(treasuryC));
        assertEq(usd8.treasury(), address(treasuryB)); // unchanged

        // The lock is historical, not merely `totalSupply != 0`: even after all
        // liabilities are redeemed, residual reserve/strategy value cannot be
        // abandoned by rotating away from the stable Treasury proxy.
        usdc.mint(address(treasuryB), 50e6);
        vm.prank(alice);
        treasuryB.redeemUSD8(100e18, 0);
        assertEq(usd8.totalSupply(), 0);
        assertEq(treasuryB.getReserveBalance(), 50e6);

        vm.prank(timelock);
        vm.expectRevert(USD8.TreasuryLocked.selector);
        usd8.setTreasury(address(treasuryC));
        assertEq(usd8.treasury(), address(treasuryB));
    }

    /// @dev M-06: evolve the Treasury by UUPS-upgrading its proxy IN PLACE —
    ///      same address, reserve/strategies/authority all preserved, timelock-gated.
    function test_TreasuryUpgradeInPlacePreservesStateAndAuthority() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, 0);
        treasury.setProfitReceiver(recipient, 7, Treasury.RevenueDistributionMode.DirectTransfer);
        vm.stopPrank();
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();
        vm.prank(admin);
        treasury.depositToStrategy(strat, 40e6);

        assertEq(usdc.balanceOf(address(treasury)), 60e6);
        assertEq(strat.totalAssets(), 40e6);
        assertEq(treasury.getReserveBalance(), 100e6);

        address v2 = address(new TreasuryV2());

        // Only the timelock can upgrade.
        vm.expectRevert(_unauthorizedTimelock(alice));
        vm.prank(alice);
        UUPSUpgradeable(address(treasury)).upgradeToAndCall(v2, "");

        // In-place upgrade: same proxy address, state + authority intact.
        vm.prank(timelock);
        UUPSUpgradeable(address(treasury)).upgradeToAndCall(v2, "");
        assertEq(TreasuryV2(address(treasury)).version(), 2);
        assertEq(address(treasury.usd8()), address(usd8));
        assertEq(address(treasury.registry()), address(registry));
        assertEq(treasury.strategiesLength(), 1);
        assertEq(address(treasury.strategies(0)), address(strat));
        assertEq(usdc.balanceOf(address(treasury)), 60e6);
        assertEq(strat.totalAssets(), 40e6);
        assertEq(treasury.getReserveBalance(), 100e6);
        assertEq(treasury.profitReceiversLength(), 1);
        (address savedReceiver, uint256 savedWeight, Treasury.RevenueDistributionMode savedMode) =
            treasury.profitReceivers(0);
        assertEq(savedReceiver, recipient);
        assertEq(savedWeight, 7);
        assertEq(uint256(savedMode), uint256(Treasury.RevenueDistributionMode.DirectTransfer));
        assertEq(usd8.totalSupply(), 100e18);
        assertEq(usd8.treasury(), address(treasury)); // never re-pointed

        // The upgraded proxy still owns mint/burn authority and the reserve.
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 10e6);
        treasury.mintUSD8(10e6);
        treasury.redeemUSD8(10e18, 10e6);
        vm.stopPrank();
        assertEq(usd8.totalSupply(), 100e18);
        assertEq(treasury.getReserveBalance(), 100e6);
    }

    // -- Revenue harvesting & routing -------------------------------------

    address constant recipient = address(0xDEED);

    function test_DistributeRevenueForwardsUsd8ToRecipient() public {
        _seedTreasuryUsd8(19.9e18);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit RevenueDistributed(recipient, 12e18);
        vm.prank(timelock);
        treasury.distributeRevenue(recipient, 12e18, Treasury.RevenueDistributionMode.DirectTransfer);

        assertEq(usd8.balanceOf(recipient), 12e18);
        assertEq(usd8.balanceOf(address(treasury)), 7.9e18);
    }

    /// forge-config: default.isolate = true
    function test_DistributeRevenueToMorphoSavingsUsesMaxRateBuffer() public {
        (VaultV2 savings, USD8SavingsAdapter adapter) = _deployMorphoSavings();

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        usd8.approve(address(savings), 100e18);
        savings.deposit(100e18, alice);
        vm.stopPrank();

        _seedTreasuryUsd8(19.9e18);

        vm.prank(timelock);
        treasury.distributeRevenue(
            address(adapter), 19.9e18, Treasury.RevenueDistributionMode.ReceiveProfitDistribution
        );

        assertEq(usd8.balanceOf(address(treasury)), 0);
        assertEq(usd8.balanceOf(address(adapter)), 119.9e18);
        assertEq(savings.totalAssets(), 100e18, "no instant share-price jump");

        vm.warp(block.timestamp + 365 days);
        assertApproxEqAbs(savings.totalAssets(), 119.9e18, 1e10);
    }

    function test_DistributeRevenueRevertsWhenReceiverPullsNothing() public {
        NonPullingProfitReceiver nonPulling = new NonPullingProfitReceiver();
        _seedTreasuryUsd8(10e18);

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Treasury.RevenueDeliveryMismatch.selector, 10e18, 0));
        treasury.distributeRevenue(
            address(nonPulling), 10e18, Treasury.RevenueDistributionMode.ReceiveProfitDistribution
        );
    }

    function test_DistributeRevenueToZeroAddressReverts() public {
        vm.prank(timelock);
        vm.expectRevert(Registry.ZeroAddress.selector);
        treasury.distributeRevenue(address(0), 1e18, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function test_DistributeRevenueZeroAmountReverts() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.distributeRevenue(recipient, 0, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function test_NonAdminCannotDistributeRevenue() public {
        vm.expectRevert(_unauthorizedAdmin(alice));
        vm.prank(alice);
        treasury.distributeRevenue(recipient, 1e18, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    // -- Weighted profit-receiver distribution ----------------------------

    address constant recipient2 = address(0xFEED);

    /// @dev Mint 100 USD8 of supply and add 20 USDC surplus, WITHOUT harvesting —
    ///      harvestAndDistribute realizes it (19.9e18 after the 10 bps buffer).
    function _setupSurplus() internal {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();
        usdc.mint(address(treasury), 20e6);
    }

    /// @dev Park amount USD8 in the Treasury's revenue pool by minting it to
    ///      alice (via USDC) and donating it in — the only way to hold USD8 at
    ///      the Treasury now that harvest always distributes. amount must be
    ///      divisible by 1e12 (USDC granularity).
    function _seedTreasuryUsd8(uint256 amount) internal {
        uint256 usdcNeeded = amount / 1e12;
        usdc.mint(alice, usdcNeeded);
        vm.startPrank(alice);
        usdc.approve(address(treasury), usdcNeeded);
        treasury.mintUSD8(usdcNeeded);
        usd8.transfer(address(treasury), amount);
        vm.stopPrank();
    }

    function test_SetProfitReceiverRegistersAndUpserts() public {
        vm.startPrank(admin);
        treasury.setProfitReceiver(recipient, 3, Treasury.RevenueDistributionMode.DirectTransfer);
        assertEq(treasury.profitReceiversLength(), 1);
        (address r, uint256 w, Treasury.RevenueDistributionMode m) = treasury.profitReceivers(0);
        assertEq(r, recipient);
        assertEq(w, 3);
        assertEq(uint256(m), uint256(Treasury.RevenueDistributionMode.DirectTransfer));

        // Re-register: upsert overwrites weight + mode, no new entry.
        treasury.setProfitReceiver(recipient, 5, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        assertEq(treasury.profitReceiversLength(), 1);
        (, uint256 w2, Treasury.RevenueDistributionMode m2) = treasury.profitReceivers(0);
        assertEq(w2, 5);
        assertEq(uint256(m2), uint256(Treasury.RevenueDistributionMode.ReceiveProfitDistribution));
        vm.stopPrank();
    }

    function test_HarvestAndDistributeSplitsProRata() public {
        _setupSurplus();
        vm.startPrank(admin);
        treasury.setProfitReceiver(recipient, 3, Treasury.RevenueDistributionMode.DirectTransfer);
        treasury.setProfitReceiver(recipient2, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();
        vm.stopPrank();

        assertEq(harvested, 19.9e18); // 20e18 surplus − 10 bps buffer
        assertEq(distributed, 19.9e18); // full pool flushed
        assertEq(usd8.balanceOf(recipient), 19.9e18 * 3 / 4); // 14.925e18
        assertEq(usd8.balanceOf(recipient2), 19.9e18 - 19.9e18 * 3 / 4); // 4.975e18, remainder to last
        assertEq(usd8.balanceOf(address(treasury)), 0);
    }

    function test_HarvestAndDistributeLastReceiverAbsorbsDust() public {
        _setupSurplus();
        address recipient3 = address(0xF00D);
        vm.startPrank(admin);
        treasury.setProfitReceiver(recipient, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        treasury.setProfitReceiver(recipient2, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        treasury.setProfitReceiver(recipient3, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        (, uint256 distributed) = treasury.harvestAndDistribute();
        vm.stopPrank();

        // 19.9e18 / 3 doesn't divide evenly; the last receiver takes the remainder.
        uint256 sum = usd8.balanceOf(recipient) + usd8.balanceOf(recipient2) + usd8.balanceOf(recipient3);
        assertEq(sum, distributed, "full amount distributed, no dust stranded");
        assertEq(usd8.balanceOf(recipient3), usd8.balanceOf(recipient) + 1); // absorbs +1 wei dust
    }

    function test_HarvestAndDistributeSkipsZeroWeight() public {
        _setupSurplus();
        vm.startPrank(admin);
        treasury.setProfitReceiver(recipient, 3, Treasury.RevenueDistributionMode.DirectTransfer);
        treasury.setProfitReceiver(recipient2, 0, Treasury.RevenueDistributionMode.DirectTransfer);
        treasury.harvestAndDistribute();
        vm.stopPrank();

        assertEq(usd8.balanceOf(recipient), 19.9e18); // sole positive weight takes all
        assertEq(usd8.balanceOf(recipient2), 0);
    }

    /// forge-config: default.isolate = true
    function test_HarvestAndDistributeToMorphoSavingsAdapter() public {
        (VaultV2 savings, USD8SavingsAdapter adapter) = _deployMorphoSavings();
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        usd8.approve(address(savings), 100e18);
        savings.deposit(100e18, alice);
        vm.stopPrank();

        usdc.mint(address(treasury), 20e6); // surplus → 19.9e18

        vm.startPrank(admin);
        treasury.setProfitReceiver(address(adapter), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
        treasury.setProfitReceiver(recipient, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        treasury.harvestAndDistribute(); // 19.9e18 split 1:1 → 9.95e18 each
        vm.stopPrank();

        assertEq(usd8.balanceOf(recipient), 9.95e18);
        assertEq(usd8.balanceOf(address(adapter)), 109.95e18);
        assertEq(savings.totalAssets(), 100e18, "maxRate prevents instant jump");
    }

    function test_HarvestAndDistributeRevertsIfSurplusButNoEligible() public {
        _setupSurplus();
        // A registered but zero-weight receiver is not eligible; the harvest mint
        // rolls back with the distribution (atomic).
        vm.startPrank(admin);
        treasury.setProfitReceiver(recipient, 0, Treasury.RevenueDistributionMode.DirectTransfer);
        vm.expectRevert(Treasury.NoEligibleProfitReceivers.selector);
        treasury.harvestAndDistribute();
        vm.stopPrank();
        assertEq(usd8.balanceOf(address(treasury)), 0, "harvest reverted atomically");
    }

    function test_RemoveProfitReceiver() public {
        vm.startPrank(admin);
        treasury.setProfitReceiver(recipient, 3, Treasury.RevenueDistributionMode.DirectTransfer);
        treasury.setProfitReceiver(recipient2, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        treasury.removeProfitReceiver(recipient);
        assertEq(treasury.profitReceiversLength(), 1);
        (address r,,) = treasury.profitReceivers(0);
        assertEq(r, recipient2); // swap-and-pop moved recipient2 into slot 0

        vm.expectRevert(abi.encodeWithSelector(Treasury.ProfitReceiverNotFound.selector, recipient));
        treasury.removeProfitReceiver(recipient);
        vm.stopPrank();
    }

    function test_SetProfitReceiverZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(RegistryManaged.ZeroAddress.selector);
        treasury.setProfitReceiver(address(0), 1, Treasury.RevenueDistributionMode.DirectTransfer);
    }

    function test_HarvestAndDistributeNoSurplusNoReceiversIsNoOp() public {
        // No surplus and no receivers: nothing to harvest or distribute, no revert.
        vm.prank(admin);
        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();
        assertEq(harvested, 0);
        assertEq(distributed, 0);
    }

    function test_NonAdminCannotManageProfitReceivers() public {
        vm.startPrank(alice);
        vm.expectRevert(_unauthorizedAdmin(alice));
        treasury.setProfitReceiver(recipient, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        vm.expectRevert(_unauthorizedAdmin(alice));
        treasury.removeProfitReceiver(recipient);
        vm.expectRevert(_unauthorizedAdmin(alice));
        treasury.harvestAndDistribute();
        vm.stopPrank();
    }

    function test_HarvestNoOpWhenNoSurplus() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        vm.prank(timelock);
        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();
        assertEq(harvested, 0);
        assertEq(distributed, 0);
        assertEq(usd8.balanceOf(address(treasury)), 0);
    }

    function test_HarvestRetainsSubBufferSurplus() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        // Sub-USDC dust redemption leaves a tiny (5e11) surplus that sits far
        // below the 10 bps buffer (~1e17), so harvest retains all of it.
        vm.prank(alice);
        treasury.redeemUSD8(5e11, 0);

        vm.prank(timelock);
        (uint256 harvested, uint256 distributed) = treasury.harvestAndDistribute();
        assertEq(harvested, 0);
        assertEq(distributed, 0);
        assertEq(usd8.balanceOf(address(treasury)), 0);
    }

    function test_HarvestAndDistributeMintsSurplusAboveBuffer() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();
        usdc.mint(address(treasury), 20e6);

        vm.prank(admin);
        treasury.setProfitReceiver(recipient, 1, Treasury.RevenueDistributionMode.DirectTransfer);

        uint256 supplyBefore = usd8.totalSupply();
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 buffer = supplyBefore / treasury.HARVEST_BUFFER_DIVISOR();

        vm.expectEmit(false, false, false, true, address(treasury));
        emit RevenueHarvested(20e18 - buffer);
        vm.prank(timelock);
        (uint256 harvested,) = treasury.harvestAndDistribute();

        assertEq(harvested, 20e18 - buffer, "minted USD8 equals surplus minus retained buffer");
        assertEq(usd8.balanceOf(recipient), 20e18 - buffer, "distributed to the receiver");
        assertEq(usd8.balanceOf(address(treasury)), 0);
        assertEq(treasury.getReserveBalance(), reserveBefore);
        assertEq(usd8.totalSupply(), supplyBefore + 20e18 - buffer);
        // Peg sits at supply + buffer after harvest, not exact equality.
        assertEq(treasury.getReserveBalance() * 1e12, usd8.totalSupply() + buffer);
    }

    function test_HarvestAndDistributeDoesNotTouchStrategies() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        MockStrategy strat = new MockStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        treasury.depositToStrategy(strat, 100e6);
        vm.stopPrank();

        usdc.mint(address(strat), 15e6);
        assertEq(treasury.getReserveBalance(), 115e6);

        vm.prank(admin);
        treasury.setProfitReceiver(recipient, 1, Treasury.RevenueDistributionMode.DirectTransfer);
        vm.prank(timelock);
        (uint256 harvested,) = treasury.harvestAndDistribute();
        // 15e18 surplus minus the 10 bps buffer (100e18 / 1000 = 0.1e18).
        assertEq(harvested, 14.9e18);
        assertEq(usd8.balanceOf(recipient), 14.9e18);
        assertEq(strat.withdrawCallCount(), 0, "strategy not touched");
        assertEq(usdc.balanceOf(address(strat)), 115e6);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    /// @dev A redeem funded from an ERC-4626-style strategy whose withdraw leaks
    ///      sub-USDC dust (ceil shares vs floor totalAssets) drops the reserve a
    ///      hair beyond the payout. The reserveSupplyStatusCheck tolerates up to
    ///      one USDC unit per strategy, so it doesn't false-revert; a larger
    ///      shortfall is a real worsening and still reverts.
    function test_RedeemToleratesStrategyWithdrawDust() public {
        // 100 USDC in -> 100e18 USD8, all deployed to a lossy strategy; +10 USDC
        // "yield" donated so the system is healthy with a 10e18 surplus.
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        LossyWithdrawStrategy strat = new LossyWithdrawStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        treasury.depositToStrategy(strat, 100e6); // idle -> 0
        vm.stopPrank();
        usdc.mint(address(strat), 10e6); // simulated yield -> 10e18 surplus

        // Withdraw leaks 5 USDC units (the per-strategy allowance — sized for
        // offset-0 ERC-4626 wrappers like stataUSDC whose share unit is worth
        // >1 USDC unit): tol = 1 strategy * 5e12 covers it, so the redeem
        // succeeds instead of false-reverting.
        strat.setLossOnNextWithdraw(5);
        vm.prank(alice);
        treasury.redeemUSD8(50e18, 0);
        assertEq(usdc.balanceOf(alice), 50e6);

        // A shortfall beyond the per-strategy dust bound is a real worsening.
        strat.setLossOnNextWithdraw(6);
        vm.prank(alice);
        vm.expectRevert(); // ReserveSupplyStatusWorsened
        treasury.redeemUSD8(10e18, 0);
    }

    /// @dev When idle can't cover a redeem and every strategy that reports funds
    ///      is stuck (paused/compromised → withdraw reverts), the walk can't top
    ///      up, so redeem fails with a clear InsufficientLiquidity, not a generic
    ///      transfer revert. Funds are safe: the burn rolls back with the tx.
    function test_RedeemRevertsInsufficientLiquidityWhenStrategyStuck() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        MockStrategy strat = new MockStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        treasury.depositToStrategy(strat, 100e6); // idle -> 0, strategy holds 100e6
        vm.stopPrank();
        strat.setWithdrawReverts(true); // strategy still reports 100e6 but can't deliver

        uint256 supplyBefore = usd8.totalSupply();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Treasury.InsufficientLiquidity.selector, 50e6, 0));
        treasury.redeemUSD8(50e18, 0);
        assertEq(usd8.totalSupply(), supplyBefore, "burn rolled back");
    }

    function test_SystemPauseBlocksGatedAdminFunctions() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);

        vm.prank(timelock);
        registry.setPaused(address(treasury), true);

        bytes memory pauseErr = abi.encodeWithSelector(Registry.Paused.selector);

        vm.prank(timelock);
        vm.expectRevert(pauseErr);
        treasury.distributeRevenue(recipient, 1e18, Treasury.RevenueDistributionMode.DirectTransfer);

        vm.prank(timelock);
        vm.expectRevert(pauseErr);
        treasury.harvestAndDistribute();

        usdc.mint(address(treasury), 10e6);
        vm.prank(timelock);
        vm.expectRevert(pauseErr);
        treasury.depositToStrategy(strat, 10e6);

        vm.prank(timelock);
        vm.expectRevert(pauseErr);
        treasury.withdrawFromStrategy(strat, 1);
    }

    function test_SystemPauseDoesNotBlockUnpausing() public {
        vm.startPrank(timelock);
        registry.setPaused(address(treasury), true);
        registry.setPaused(address(treasury), false);
        vm.stopPrank();
        assertFalse(registry.paused(address(treasury)));
    }

    function test_SystemPauseDoesNotBlockAddRemoveStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        registry.setPaused(address(treasury), true);

        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        assertEq(treasury.strategiesLength(), 1);

        vm.prank(timelock);
        treasury.removeStrategy(strat);
        assertEq(treasury.strategiesLength(), 0);
    }

    function test_HarvestAndDistributeOnlyAdmin() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();
        usdc.mint(address(treasury), 5e6);

        vm.prank(admin);
        treasury.setProfitReceiver(recipient, 1, Treasury.RevenueDistributionMode.DirectTransfer);

        vm.expectRevert(_unauthorizedAdmin(alice));
        vm.prank(alice);
        treasury.harvestAndDistribute();

        vm.prank(timelock);
        treasury.harvestAndDistribute();
        // 5e18 surplus minus the 10 bps buffer (100e18 / 1000 = 0.1e18).
        assertEq(usd8.balanceOf(recipient), 4.9e18);
    }

    // -- Strategy ---------------------------------------------------------

    function _approveAndFundStrategy(MockStrategy strat, uint256 amount) internal {
        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        usdc.mint(address(treasury), amount);
        vm.prank(timelock);
        treasury.depositToStrategy(strat, amount);
    }

    function test_StrategiesEmptyByDefault() public view {
        assertEq(treasury.strategiesLength(), 0);
    }

    function test_AdminCanAddStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit StrategyAdded(strat);
        treasury.addStrategy(strat, type(uint256).max);

        assertEq(treasury.strategiesLength(), 1);
        assertEq(address(treasury.strategies(0)), address(strat));
    }

    function test_AddStrategyRejectsZeroAddress() public {
        vm.prank(timelock);
        vm.expectRevert(Registry.ZeroAddress.selector);
        treasury.addStrategy(IStrategy(address(0)), type(uint256).max);
    }

    function test_AddStrategyRejectsDuplicate() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StrategyAlreadyApproved.selector, strat));
        treasury.addStrategy(strat, type(uint256).max);
        vm.stopPrank();
    }

    function test_NonAdminCannotAddStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.expectRevert(_unauthorizedTimelock(alice));
        vm.prank(alice);
        treasury.addStrategy(strat, type(uint256).max);
    }

    function test_AddStrategyRejectsWrongUnderlying() public {
        WrongUsdcStrategy bad = new WrongUsdcStrategy();
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                Treasury.StrategyAssetMismatch.selector, IStrategy(address(bad)), USDC_ADDR, address(0xDEAD)
            )
        );
        treasury.addStrategy(IStrategy(address(bad)), type(uint256).max);
    }

    function test_RemoveStrategyForcesRemovalIgnoringFunds() public {
        MockStrategy strat = new MockStrategy(usdc);
        _approveAndFundStrategy(strat, 50e6);

        vm.prank(timelock);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit StrategyRemoved(strat);
        treasury.removeStrategy(strat);

        assertEq(treasury.strategiesLength(), 0);
        assertEq(usdc.balanceOf(address(strat)), 50e6, "funds orphaned in strategy");
    }

    function test_RemoveStrategyAfterDrain() public {
        MockStrategy strat = new MockStrategy(usdc);
        _approveAndFundStrategy(strat, 50e6);

        vm.startPrank(timelock);
        treasury.withdrawFromStrategy(strat, 50e6);
        treasury.removeStrategy(strat);
        vm.stopPrank();

        assertEq(treasury.strategiesLength(), 0);
    }

    function test_RemoveStrategyNotApprovedReverts() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StrategyNotApproved.selector, strat));
        treasury.removeStrategy(strat);
    }

    function test_AddStrategyAtIndexAndReorder() public {
        MockStrategy a = new MockStrategy(usdc);
        MockStrategy b = new MockStrategy(usdc);
        MockStrategy c = new MockStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(a, type(uint256).max); // [a]
        treasury.addStrategy(b, 0); // [b, a] — insert at front
        treasury.addStrategy(c, 1); // [b, c, a] — insert mid

        // Reposition existing: remove + re-add at the target index.
        // Mid-queue removal must not disturb the order of the others.
        treasury.removeStrategy(c); // [b, a]
        treasury.addStrategy(c, 2); // [b, a, c]
        treasury.removeStrategy(b); // [a, c]
        treasury.addStrategy(b, 1); // [a, b, c]
        vm.stopPrank();

        assertEq(address(treasury.strategies(0)), address(a));
        assertEq(address(treasury.strategies(1)), address(b));
        assertEq(address(treasury.strategies(2)), address(c));
    }

    function test_DepositToStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        usdc.mint(address(treasury), 100e6);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit DepositedToStrategy(strat, 100e6);
        treasury.depositToStrategy(strat, 100e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(treasury)), 0);
        assertEq(usdc.balanceOf(address(strat)), 100e6);
        assertEq(strat.deployCallCount(), 1);
    }

    function test_DepositToUnapprovedStrategyReverts() public {
        MockStrategy strat = new MockStrategy(usdc);
        usdc.mint(address(treasury), 100e6);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Treasury.StrategyNotApproved.selector, strat));
        treasury.depositToStrategy(strat, 100e6);
    }

    function test_DepositZeroReverts() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.depositToStrategy(strat, 0);
        vm.stopPrank();
    }

    function test_WithdrawFromStrategy() public {
        MockStrategy strat = new MockStrategy(usdc);
        _approveAndFundStrategy(strat, 100e6);

        vm.prank(timelock);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit WithdrawnFromStrategy(strat, 40e6);
        treasury.withdrawFromStrategy(strat, 40e6);

        assertEq(usdc.balanceOf(address(treasury)), 40e6);
        assertEq(usdc.balanceOf(address(strat)), 60e6);
        assertEq(strat.withdrawCallCount(), 1);
    }

    function test_NonAdminCannotDepositOrWithdraw() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);

        vm.expectRevert(_unauthorizedAdmin(alice));
        vm.prank(alice);
        treasury.depositToStrategy(strat, 1);

        vm.expectRevert(_unauthorizedAdmin(alice));
        vm.prank(alice);
        treasury.withdrawFromStrategy(strat, 1);
    }

    function test_MintLeavesUsdcIdle() public {
        MockStrategy strat = new MockStrategy(usdc);
        vm.prank(timelock);
        treasury.addStrategy(strat, type(uint256).max);

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(treasury)), 100e6, "mint does not auto-deploy");
        assertEq(usdc.balanceOf(address(strat)), 0);
    }

    function test_ReserveBalanceSumsAcrossStrategies() public {
        MockStrategy a = new MockStrategy(usdc);
        MockStrategy b = new MockStrategy(usdc);
        _approveAndFundStrategy(a, 60e6);
        _approveAndFundStrategy(b, 30e6);
        usdc.mint(address(treasury), 10e6);

        assertEq(treasury.getReserveBalance(), 100e6, "idle + A + B");

        usdc.mint(address(a), 5e6);
        assertEq(treasury.getReserveBalance(), 105e6);
    }

    function test_RedeemPullsAcrossMultipleStrategies() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        MockStrategy a = new MockStrategy(usdc);
        MockStrategy b = new MockStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(a, type(uint256).max);
        treasury.addStrategy(b, type(uint256).max);
        treasury.depositToStrategy(a, 60e6);
        treasury.depositToStrategy(b, 40e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(treasury)), 0);
        assertEq(treasury.getReserveBalance(), 100e6);

        vm.prank(alice);
        treasury.redeemUSD8(80e18, 0);

        assertEq(usdc.balanceOf(alice), 80e6);
        assertEq(a.withdrawCallCount(), 1);
        assertEq(b.withdrawCallCount(), 1);
        assertEq(usdc.balanceOf(address(a)), 0, "A drained");
        assertEq(usdc.balanceOf(address(b)), 20e6, "B has remainder");
    }

    function test_RedeemDetectsSurplusHiddenStrategyLoss() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        LossyWithdrawStrategy strat = new LossyWithdrawStrategy(usdc);
        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        treasury.depositToStrategy(strat, 100e6);
        vm.stopPrank();

        usdc.mint(address(strat), 20e6);
        strat.setLossOnNextWithdraw(5e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Treasury.ReserveSupplyStatusWorsened.selector, 120e6, 100e18, 105e6, 90e18)
        );
        treasury.redeemUSD8(10e18, 0);
    }

    function test_RedeemSkipsEmptyStrategies() public {
        MockStrategy a = new MockStrategy(usdc);
        MockStrategy b = new MockStrategy(usdc);
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        vm.startPrank(timelock);
        treasury.addStrategy(a, type(uint256).max);
        treasury.addStrategy(b, type(uint256).max);
        treasury.depositToStrategy(b, 100e6);
        vm.stopPrank();

        vm.prank(alice);
        treasury.redeemUSD8(50e18, 0);

        assertEq(a.withdrawCallCount(), 0, "empty strategy not called");
        assertEq(b.withdrawCallCount(), 1);
        assertEq(usdc.balanceOf(alice), 50e6);
    }

    function test_RedeemRevertsIfShortfallExceedsAllStrategies() public {
        MockStrategy strat = new MockStrategy(usdc);
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        vm.startPrank(timelock);
        treasury.addStrategy(strat, type(uint256).max);
        treasury.depositToStrategy(strat, 100e6);
        vm.stopPrank();

        vm.prank(address(strat));
        usdc.transfer(address(0xD), 100e6);

        vm.prank(alice);
        treasury.redeemUSD8(10e18, 0);
        assertEq(usdc.balanceOf(alice), 0, "total haircut, no USDC paid");
    }

    function test_MintUSD8() public {
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Minted(alice, 100e6, 100e18);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(address(treasury)), 100e6);
        assertEq(usd8.balanceOf(alice), 100e18);
        assertEq(usd8.totalSupply(), 100e18);
    }

    function test_Redeem() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Redeemed(alice, 40e18, 40e6);
        treasury.redeemUSD8(40e18, 0);
        vm.stopPrank();

        assertEq(usd8.balanceOf(alice), 60e18);
        assertEq(usdc.balanceOf(alice), 40e6);
        assertEq(usdc.balanceOf(address(treasury)), 60e6);
    }

    function test_MintZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.mintUSD8(0);
    }

    function test_RedeemZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.redeemUSD8(0, 0);
    }

    function test_RedeemWhenSupplyZeroRevertsCleanly() public {
        vm.prank(alice);
        vm.expectRevert(Treasury.NoUsd8Supply.selector);
        treasury.redeemUSD8(1e18, 0);
    }

    function test_RedeemRoundsDownInFavorOfProtocol() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);

        uint256 amount = 1e18 + 5e11;
        vm.expectEmit(true, false, false, true, address(treasury));
        emit Redeemed(alice, amount, 1e6);
        treasury.redeemUSD8(amount, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 1e6);
        assertEq(usdc.balanceOf(address(treasury)), 99e6);
        assertEq(usd8.balanceOf(alice), 100e18 - amount);
    }

    function test_RedeemSubUsdcUnitYieldsZeroUsdc() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);

        treasury.redeemUSD8(5e11, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(address(treasury)), 100e6);
        assertEq(usd8.balanceOf(alice), 100e18 - 5e11);
    }

    function test_RedeemRequiresUsd8Balance() public {
        vm.prank(alice);
        vm.expectRevert();
        treasury.redeemUSD8(1e18, 0);
    }

    function test_GetReserveBalanceMirrorsUsdcBalance() public {
        assertEq(treasury.getReserveBalance(), 0);
        usdc.mint(address(treasury), 250e6);
        assertEq(treasury.getReserveBalance(), 250e6);
    }

    // -- Pro-rata redemption ----------------------------------------------

    function _setupDistressed(address holder, uint256 lossUsdc)
        internal
        returns (uint256 supplyBefore, uint256 reserveBefore)
    {
        usdc.mint(holder, 100e6);
        vm.startPrank(holder);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        vm.prank(address(treasury));
        usdc.transfer(address(0xDEAD), lossUsdc);

        supplyBefore = usd8.totalSupply();
        reserveBefore = treasury.getReserveBalance();
    }

    function test_RedeemHaircutInDistress() public {
        (uint256 supplyBefore, uint256 reserveBefore) = _setupDistressed(alice, 10e6);
        assertEq(supplyBefore, 100e18);
        assertEq(reserveBefore, 90e6);

        vm.prank(alice);
        treasury.redeemUSD8(50e18, 0);

        assertEq(usdc.balanceOf(alice), 45e6, "alice gets pro-rata haircut");
        assertEq(usdc.balanceOf(address(treasury)), 45e6, "treasury holds the other half");
        assertEq(usd8.balanceOf(alice), 50e18);

        assertEq(treasury.getReserveBalance() * 1e18, usd8.totalSupply() * 90e6 / 100);
    }

    function test_RedeemSlippageReverts() public {
        (uint256 supplyBefore, uint256 reserveBefore) = _setupDistressed(alice, 10e6);
        assertEq(supplyBefore, 100e18);
        assertEq(reserveBefore, 90e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Treasury.InsufficientUsdcOut.selector, 45e6, 50e6));
        treasury.redeemUSD8(50e18, 50e6);

        vm.prank(alice);
        treasury.redeemUSD8(50e18, 45e6);
        assertEq(usdc.balanceOf(alice), 45e6);
    }

    function test_RedeemRatioPreservedAcrossPartialRedemptions() public {
        _setupDistressed(alice, 10e6);

        uint256 ratioBeforeNumer = treasury.getReserveBalance();
        uint256 ratioBeforeDenom = usd8.totalSupply();

        vm.startPrank(alice);
        treasury.redeemUSD8(20e18, 0);
        treasury.redeemUSD8(30e18, 0);
        vm.stopPrank();

        assertEq(treasury.getReserveBalance() * ratioBeforeDenom, usd8.totalSupply() * ratioBeforeNumer);
    }

    function test_MintDuringDistressIsDonation() public {
        _setupDistressed(alice, 10e6);

        address bob = address(0xB0B);
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        treasury.redeemUSD8(100e18, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), 95e6, "bob loses 5 USDC by minting into distress");
        assertEq(treasury.getReserveBalance(), 95e6);
        assertEq(usd8.totalSupply(), 100e18);
    }

    function test_RedeemSurplusCapsAtPeg() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        usdc.mint(address(treasury), 50e6);
        assertEq(treasury.getReserveBalance(), 150e6);

        vm.prank(alice);
        treasury.redeemUSD8(100e18, 0);

        assertEq(usdc.balanceOf(alice), 100e6, "redeem capped at 1:1");
        assertEq(usdc.balanceOf(address(treasury)), 50e6, "surplus retained");
        assertEq(usd8.totalSupply(), 0);
    }

    function test_NoArbitrageInHealthyState() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        treasury.redeemUSD8(100e18, 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(usd8.balanceOf(alice), 0);
    }

    function test_NoArbitrageWithFlashMintRedeemInDistress() public {
        _setupDistressed(alice, 10e6);
        address bob = address(0xB0B);
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(treasury), 1_000e6);
        uint256 startUsdc = usdc.balanceOf(bob);
        treasury.mintUSD8(1_000e6);
        treasury.redeemUSD8(1_000e18, 0);
        uint256 endUsdc = usdc.balanceOf(bob);
        vm.stopPrank();

        assertLt(endUsdc, startUsdc, "attacker strictly loses USDC on the round-trip");
    }

    // -- Post-allocation reserve invariant (audit test gap 7) --------------

    /// @dev Allocating reserve through the REAL ERC4626Strategy into an honest
    ///      vault is reserve-neutral: getReserveBalance() is identical before and
    ///      after deposit, and again after a full withdrawal — USDC only changes
    ///      classification (idle ↔ strategy-held), never total.
    function test_Audit_StrategyAllocationIsReserveNeutral() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(treasury), 100e6);
        treasury.mintUSD8(100e6);
        vm.stopPrank();

        HonestVault vault = new HonestVault(IERC20(USDC_ADDR));
        ERC4626Strategy strat = new ERC4626Strategy(address(treasury), vault);
        vm.prank(timelock);
        treasury.addStrategy(strat, 0);

        uint256 reserveBefore = treasury.getReserveBalance();
        vm.prank(admin);
        treasury.depositToStrategy(strat, 100e6);
        assertGt(vault.balanceOf(address(strat)), 0, "shares actually minted");
        assertEq(strat.totalAssets(), 100e6, "strategy reports the full allocation");
        assertEq(treasury.getReserveBalance(), reserveBefore, "deposit is reserve-neutral");

        vm.prank(admin);
        treasury.withdrawFromStrategy(strat, 100e6);
        assertEq(treasury.getReserveBalance(), reserveBefore, "withdrawal is reserve-neutral");
        assertEq(usdc.balanceOf(address(treasury)), 100e6, "USDC back to idle");
    }

    // -- Rescue -----------------------------------------------------------

    function test_RescueTokenSendsToRecipient() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(treasury), 7e18);

        vm.prank(timelock);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit TokenSwept(address(stray), recipient, 7e18);
        treasury.sweepToken(IERC20(address(stray)), recipient);

        assertEq(stray.balanceOf(recipient), 7e18);
        assertEq(stray.balanceOf(address(treasury)), 0);
    }

    function test_RescueTokenRejectsUSDC() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(RegistryManaged.NothingToSweep.selector, address(usdc)));
        treasury.sweepToken(IERC20(address(usdc)), recipient);
    }

    function test_RescueTokenRejectsUSD8() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(RegistryManaged.NothingToSweep.selector, address(usd8)));
        treasury.sweepToken(IERC20(address(usd8)), recipient);
    }

    function test_RescueTokenRejectsZeroAddress() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        vm.prank(timelock);
        vm.expectRevert(Registry.ZeroAddress.selector);
        treasury.sweepToken(IERC20(address(stray)), address(0));
    }

    function test_RescueETHSendsToRecipient() public {
        vm.deal(address(treasury), 1 ether);

        vm.prank(timelock);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit ETHSwept(recipient, 1 ether);
        treasury.sweepETH(payable(recipient));

        assertEq(recipient.balance, 1 ether);
    }
}

/// @dev Spec-conforming ERC-4626 vault (stock OZ behavior) for the reserve-
///      neutrality test of the real ERC4626Strategy.
contract HonestVault is ERC20, ERC4626 {
    constructor(IERC20 asset_) ERC20("Honest Vault", "HON") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }
}

/// @dev Strategy whose underlying() returns a non-USDC address, used to
///      exercise StrategyAssetMismatch in Treasury.
contract WrongUsdcStrategy is IStrategy {
    function underlying() external pure override returns (address) {
        return address(0xDEAD);
    }

    function deploy(uint256) external override {}
    function withdraw(uint256) external override {}

    function totalAssets() external pure override returns (uint256) {
        return 0;
    }
}

/// @dev Trivial upgrade target: same storage layout as Treasury plus a version()
///      probe, to prove in-place UUPS upgrades preserve state (M-06).
contract TreasuryV2 is Treasury {
    function version() external pure returns (uint256) {
        return 2;
    }
}
