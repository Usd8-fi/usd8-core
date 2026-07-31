// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Registry} from "../../src/Registry.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";
import {StrategyBase} from "../../src/strategies/StrategyBase.sol";
import {
    ERC4626StrategyAdversarialVault,
    ERC4626StrategyFeeVault,
    ERC4626StrategyHarnessTreasury,
    ERC4626StrategyKontrolBase,
    ERC4626StrategyZeroShareVault
} from "./ERC4626StrategyHarness.k.sol";

/// @notice Treasury authorization, ERC-4626 deployment/withdrawal accounting, and rollback properties.
contract ERC4626StrategyDeployWithdrawKontrolTest is ERC4626StrategyKontrolBase {
    function test_outsiderCannotDeployOrWithdrawBeforeExternalStateChanges() public {
        _fundStrategy(100);
        (bool deploySuccess, bytes memory deployData) =
            address(strategy).call(abi.encodeCall(ERC4626Strategy.deploy, (uint256(100))));
        assert(!deploySuccess);
        _assertExactBytes(deployData, abi.encodeWithSelector(StrategyBase.UnauthorizedTreasury.selector, address(this)));
        (bool withdrawSuccess, bytes memory withdrawData) =
            address(strategy).call(abi.encodeCall(ERC4626Strategy.withdraw, (uint256(1))));
        assert(!withdrawSuccess);
        _assertExactBytes(
            withdrawData, abi.encodeWithSelector(StrategyBase.UnauthorizedTreasury.selector, address(this))
        );
        assert(usdc.balanceOf(address(strategy)) == 100);
        assert(usdc.balanceOf(address(vault)) == 0);
        assert(vault.balanceOf(address(strategy)) == 0);
    }

    function test_standardDeployMovesExactAssetsAndMintsExactPreviewedShares(uint128 amount) public {
        vm.assume(amount > 0);
        _fundStrategy(amount);
        uint256 expectedShares = vault.previewDeposit(amount);
        _deploy(amount);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(usdc.balanceOf(address(vault)) == amount);
        assert(vault.balanceOf(address(strategy)) == expectedShares);
        assert(strategy.totalAssets() == amount);
        assert(usdc.allowance(address(strategy), address(vault)) == type(uint256).max);
    }

    function test_deployIntoExistingAppreciatedPositionUsesExactValueDelta() public {
        _fundStrategy(100);
        _deploy(100);
        usdc.mint(address(vault), 10);
        uint256 valueBefore = strategy.totalAssets();
        uint256 sharesBefore = vault.balanceOf(address(strategy));
        _fundStrategy(50);
        uint256 expectedShares = vault.previewDeposit(50);
        _deploy(50);
        assert(usdc.balanceOf(address(vault)) == 160);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(vault.balanceOf(address(strategy)) == sharesBefore + expectedShares);
        assert(strategy.totalAssets() == vault.convertToAssets(sharesBefore + expectedShares));
        assert(strategy.totalAssets() >= valueBefore + 50 - (vault.convertToAssets(1) + 1));
    }

    function test_zeroShareDepositRevertsAndRollsBackTokenTransfer() public {
        ERC4626StrategyZeroShareVault zeroVault = new ERC4626StrategyZeroShareVault(usdc);
        ERC4626Strategy zeroStrategy = new ERC4626Strategy(address(treasury), registry, IERC4626(address(zeroVault)));
        usdc.mint(address(zeroStrategy), 100);
        (bool success, bytes memory data) = address(treasury)
            .call(abi.encodeCall(ERC4626StrategyHarnessTreasury.deployInto, (zeroStrategy, uint256(100))));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(ERC4626Strategy.ZeroSharesMinted.selector));
        assert(usdc.balanceOf(address(zeroStrategy)) == 100);
        assert(usdc.balanceOf(address(zeroVault)) == 0);
        assert(zeroVault.balanceOf(address(zeroStrategy)) == 0);
    }

    function test_valueShortDepositRevertsAndRollsBackVaultAndTokenState() public {
        ERC4626StrategyFeeVault feeVault = new ERC4626StrategyFeeVault(usdc);
        ERC4626Strategy feeStrategy = new ERC4626Strategy(address(treasury), registry, IERC4626(address(feeVault)));
        usdc.mint(address(feeStrategy), 100);
        (bool success, bytes memory data) = address(treasury)
            .call(abi.encodeCall(ERC4626StrategyHarnessTreasury.deployInto, (feeStrategy, uint256(100))));
        assert(!success);
        _assertExactBytes(
            data, abi.encodeWithSelector(ERC4626Strategy.DepositValueShort.selector, uint256(100), uint256(90))
        );
        assert(usdc.balanceOf(address(feeStrategy)) == 100);
        assert(usdc.balanceOf(address(feeVault)) == 0);
        assert(usdc.balanceOf(address(0xFEE)) == 0);
        assert(feeVault.balanceOf(address(feeStrategy)) == 0);
    }

    function test_zeroPartialAndFullWithdrawalsDeliverExactlyToTreasury() public {
        _fundStrategy(100);
        _deploy(100);
        uint256 treasuryBefore = usdc.balanceOf(address(treasury));
        _withdraw(0);
        assert(usdc.balanceOf(address(treasury)) == treasuryBefore);
        _withdraw(40);
        assert(usdc.balanceOf(address(treasury)) == treasuryBefore + 40);
        assert(strategy.totalAssets() == 60);
        _withdraw(60);
        assert(usdc.balanceOf(address(treasury)) == treasuryBefore + 100);
        assert(strategy.totalAssets() == 0);
        assert(vault.balanceOf(address(strategy)) == 0);
    }

    function test_excessWithdrawalRevertsAndRollsBackSharesAndBalances() public {
        _fundStrategy(100);
        _deploy(100);
        uint256 sharesBefore = vault.balanceOf(address(strategy));
        uint256 vaultAssetsBefore = usdc.balanceOf(address(vault));
        uint256 treasuryBefore = usdc.balanceOf(address(treasury));
        (bool success, bytes memory data) = address(treasury)
            .call(abi.encodeCall(ERC4626StrategyHarnessTreasury.withdrawFrom, (strategy, uint256(101))));
        assert(!success);
        _assertExactBytes(
            data,
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxRedeem.selector, address(strategy), uint256(101), uint256(100)
            )
        );
        assert(vault.balanceOf(address(strategy)) == sharesBefore);
        assert(usdc.balanceOf(address(vault)) == vaultAssetsBefore);
        assert(usdc.balanceOf(address(treasury)) == treasuryBefore);
        assert(strategy.totalAssets() == 100);
    }

    function test_shortRedeemReachesExactWithdrawShortAndRollsBackAllVaultState() public {
        ERC4626StrategyAdversarialVault shortVault = new ERC4626StrategyAdversarialVault(usdc);
        ERC4626Strategy shortStrategy = new ERC4626Strategy(address(treasury), registry, IERC4626(address(shortVault)));
        usdc.mint(address(shortStrategy), 100);
        treasury.deployInto(shortStrategy, 100);

        uint256 requested = 40;
        uint256 expectedShares = shortVault.previewWithdraw(requested);
        // [C:OZ_ERC4626_PREVIEW_CORRELATED] Share expectation intentionally uses
        // the pinned vendor preview; this property targets strategy rollback,
        // not an independent proof of ERC-4626 conversion arithmetic.
        assert(expectedShares == 40);
        shortVault.setWithdrawMode(ERC4626StrategyAdversarialVault.WithdrawMode.Short, 1);
        _assertShortVaultRollbackState(shortVault, shortStrategy);

        (bool success, bytes memory data) = address(treasury)
            .call(abi.encodeCall(ERC4626StrategyHarnessTreasury.withdrawFrom, (shortStrategy, requested)));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(ERC4626Strategy.WithdrawShort.selector, requested, uint256(39)));

        _assertShortVaultRollbackState(shortVault, shortStrategy);
    }

    function test_zeroDeliveryReachesExactWithdrawShortAndRollsBackAllVaultState() public {
        ERC4626StrategyAdversarialVault zeroVault = new ERC4626StrategyAdversarialVault(usdc);
        ERC4626Strategy zeroStrategy = new ERC4626Strategy(address(treasury), registry, IERC4626(address(zeroVault)));
        usdc.mint(address(zeroStrategy), 100);
        treasury.deployInto(zeroStrategy, 100);
        zeroVault.setWithdrawMode(ERC4626StrategyAdversarialVault.WithdrawMode.Short, 40);

        (bool success, bytes memory data) = address(treasury)
            .call(abi.encodeCall(ERC4626StrategyHarnessTreasury.withdrawFrom, (zeroStrategy, uint256(40))));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(ERC4626Strategy.WithdrawShort.selector, uint256(40), uint256(0)));
        assert(usdc.balanceOf(address(treasury)) == 0);
        assert(zeroVault.balanceOf(address(zeroStrategy)) == 100);
        assert(usdc.balanceOf(address(zeroVault)) == 100);
        assert(zeroVault.totalSupply() == 100);
        assert(usdc.allowance(address(zeroStrategy), address(zeroVault)) == type(uint256).max);
        assert(zeroVault.redeemCalls() == 0);
        assert(zeroVault.withdrawMode() == ERC4626StrategyAdversarialVault.WithdrawMode.Short);
        assert(zeroVault.shortfall() == 40);
    }

    function _assertShortVaultRollbackState(ERC4626StrategyAdversarialVault shortVault, ERC4626Strategy shortStrategy)
        internal
        view
    {
        assert(usdc.balanceOf(address(treasury)) == 0);
        assert(shortVault.balanceOf(address(shortStrategy)) == 100);
        assert(usdc.balanceOf(address(shortVault)) == 100);
        assert(shortVault.totalSupply() == 100);
        assert(shortStrategy.totalAssets() == 100);
        assert(usdc.balanceOf(address(shortStrategy)) == 0);
        assert(usdc.allowance(address(shortStrategy), address(shortVault)) == type(uint256).max);
        assert(shortVault.redeemCalls() == 0);
        assert(shortVault.lastRedeemShares() == 0);
        assert(shortVault.lastRedeemAssets() == 0);
        assert(shortVault.withdrawMode() == ERC4626StrategyAdversarialVault.WithdrawMode.Short);
        assert(shortVault.shortfall() == 1);
    }

    function test_registryPauseDoesNotGateTreasuryDeployOrWithdraw() public {
        registry.setPaused(address(strategy), true);
        _fundStrategy(100);
        _deploy(100);
        assert(strategy.totalAssets() == 100);
        _withdraw(100);
        assert(strategy.totalAssets() == 0);
        assert(usdc.balanceOf(address(treasury)) == 100);
    }
}
