// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";
import {
    ERC4626StrategyFactory,
    ERC4626StrategyHarnessToken,
    ERC4626StrategyHarnessTreasury,
    ERC4626StrategyHarnessVault,
    ERC4626StrategyKontrolBase
} from "./ERC4626StrategyHarness.k.sol";

/// @notice Constructor precedence, immutable wiring, allowance, and valuation-composition properties.
contract ERC4626StrategyConstructionViewsKontrolTest is ERC4626StrategyKontrolBase {
    event RegistryChanged(address indexed oldRegistry, address indexed newRegistry);

    function test_constructorRegistryChangedIsExactFirstLogUnderSilentDependencies() public {
        ERC4626StrategyFactory factory = new ERC4626StrategyFactory();
        address expectedStrategy = vm.computeCreateAddress(address(factory), 1);
        vm.expectEmit(true, true, false, true, expectedStrategy);
        emit RegistryChanged(address(0), address(registry));
        ERC4626Strategy fresh = factory.deploy(address(treasury), registry, vault);
        assert(address(fresh) == expectedStrategy);
    }

    function test_successfulConstructionWiresEveryImmutableAndRegistryExactly() public view {
        assert(address(strategy.USDC()) == address(usdc));
        assert(address(strategy.strategyToken()) == address(usdc));
        assert(strategy.treasury() == address(treasury));
        assert(address(strategy.vault()) == address(vault));
        assert(address(strategy.registry()) == address(registry));
        assert(strategy.underlying() == address(usdc));
        assert(usdc.allowance(address(strategy), address(vault)) == type(uint256).max);
        assert(strategy.totalAssets() == 0);
    }

    function test_totalAssetsIsExactlyVaultConversionAndIgnoresLooseUsdc() public {
        _fundStrategy(100);
        assert(strategy.totalAssets() == 0);
        _deploy(100);
        uint256 shares = vault.balanceOf(address(strategy));
        assert(strategy.totalAssets() == vault.convertToAssets(shares));
        usdc.mint(address(strategy), 7);
        assert(strategy.totalAssets() == vault.convertToAssets(shares));
    }

    function test_vaultAssetMismatchRevertsWithExactPayload() public {
        ERC4626StrategyHarnessToken other = new ERC4626StrategyHarnessToken();
        ERC4626StrategyHarnessVault wrongVault = new ERC4626StrategyHarnessVault(other);
        ERC4626StrategyFactory factory = new ERC4626StrategyFactory();
        (bool success, bytes memory data) = address(factory)
            .call(abi.encodeCall(factory.deploy, (address(treasury), registry, IERC4626(address(wrongVault)))));
        assert(!success);
        _assertExactBytes(
            data, abi.encodeWithSelector(ERC4626Strategy.VaultAssetMismatch.selector, address(usdc), address(other))
        );
    }

    function test_zeroRegistryAndZeroVaultUseExactZeroAddressGuard() public {
        ERC4626StrategyFactory factory = new ERC4626StrategyFactory();
        (bool registrySuccess, bytes memory registryData) = address(factory)
            .call(abi.encodeCall(factory.deploy, (address(treasury), Registry(address(0)), IERC4626(address(vault)))));
        assert(!registrySuccess);
        _assertExactBytes(registryData, abi.encodeWithSelector(SharedBase.ZeroAddress.selector));
        (bool vaultSuccess, bytes memory vaultData) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(treasury), registry, IERC4626(address(0)))));
        assert(!vaultSuccess);
        _assertExactBytes(vaultData, abi.encodeWithSelector(SharedBase.ZeroAddress.selector));
    }

    function test_zeroOrNoCodeTreasuryAndNoCodeVaultFailAtomically() public {
        ERC4626StrategyFactory factory = new ERC4626StrategyFactory();
        (bool zeroTreasury, bytes memory zeroTreasuryData) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(0), registry, IERC4626(address(vault)))));
        assert(!zeroTreasury && zeroTreasuryData.length == 0);

        address noCodeTreasury = address(0xDEAD);
        (bool noTreasury, bytes memory noTreasuryData) =
            address(factory).call(abi.encodeCall(factory.deploy, (noCodeTreasury, registry, IERC4626(address(vault)))));
        assert(!noTreasury && noTreasuryData.length == 0);

        address noCodeVault = address(0xBEEF);
        (bool noVault, bytes memory noVaultData) =
            address(factory).call(abi.encodeCall(factory.deploy, (address(treasury), registry, IERC4626(noCodeVault))));
        assert(!noVault && noVaultData.length == 0);
    }

    function test_repeatedViewsDoNotChangeBalancesAllowancesOrPosition() public {
        _fundStrategy(100);
        _deploy(100);
        uint256 usdcBalance = usdc.balanceOf(address(strategy));
        uint256 allowance = usdc.allowance(address(strategy), address(vault));
        uint256 shares = vault.balanceOf(address(strategy));
        uint256 assets = strategy.totalAssets();
        assert(strategy.totalAssets() == assets);
        assert(strategy.underlying() == address(usdc));
        assert(address(strategy.registry()) == address(registry));
        assert(usdc.balanceOf(address(strategy)) == usdcBalance);
        assert(usdc.allowance(address(strategy), address(vault)) == allowance);
        assert(vault.balanceOf(address(strategy)) == shares);
    }
}
