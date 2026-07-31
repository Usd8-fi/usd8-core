// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";
import {StrategyBase} from "../../src/strategies/StrategyBase.sol";
import {ERC4626StrategyFactory} from "./ERC4626StrategyHarness.k.sol";
import {
    ERC4626StrategyAssetResponseVault,
    ERC4626StrategyModeRouter,
    ERC4626StrategyModeToken,
    ERC4626StrategyModeTreasury,
    ERC4626StrategyModeVault
} from "./ERC4626StrategyAdversarialHarness.k.sol";

abstract contract ERC4626StrategyCurrentSourceBase is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant RECIPIENT = address(0xB0B);

    Registry internal registry;
    ERC4626StrategyModeToken internal usdc;
    ERC4626StrategyModeToken internal reward;
    ERC4626StrategyModeTreasury internal treasury;
    ERC4626StrategyModeVault internal vault;
    ERC4626StrategyModeRouter internal router;
    ERC4626Strategy internal strategy;

    function setUp() public virtual {
        registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
        usdc = new ERC4626StrategyModeToken();
        reward = new ERC4626StrategyModeToken();
        treasury = new ERC4626StrategyModeTreasury(usdc);
        vault = new ERC4626StrategyModeVault(usdc);
        strategy = new ERC4626Strategy(address(treasury), registry, vault);
        router = new ERC4626StrategyModeRouter();
        registry.setSwapRoute(address(router), address(router), true);
    }

    function _deploy(uint256 amount) internal {
        usdc.mint(address(strategy), amount);
        treasury.deployInto(strategy, amount);
    }

    function _swap(bytes memory route, uint256 amountIn, uint256 minimum)
        internal
        returns (bool success, bytes memory data)
    {
        return address(strategy)
            .call(
                abi.encodeCall(
                    strategy.swap,
                    (
                        IERC20(address(reward)),
                        IERC20(address(usdc)),
                        amountIn,
                        address(router),
                        address(router),
                        route,
                        minimum
                    )
                )
            );
    }

    function _selector(bytes memory data) internal pure returns (bytes4 selector) {
        if (data.length >= 4) {
            assembly { selector := mload(add(data, 32)) }
        }
    }

    function _assertExactBytes(bytes memory actual, bytes memory expected) internal pure {
        assert(actual.length == expected.length);
        assert(keccak256(actual) == keccak256(expected));
    }

    function _assertPanic(bytes memory data) internal pure {
        _assertExactBytes(data, abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
    }
}

/// @notice Constructor, deploy, withdrawal, and valuation closure against
/// state-selectable fixed-bytecode Treasury/token/vault models.
contract ERC4626StrategyExternalModesKontrolTest is ERC4626StrategyCurrentSourceBase {
    function _deployWithTreasuryMode(ERC4626StrategyModeTreasury.ResponseMode mode)
        internal
        returns (bool success, bytes memory data)
    {
        treasury.setMode(mode);
        ERC4626StrategyFactory factory = new ERC4626StrategyFactory();
        return
            address(factory)
                .call(abi.encodeCall(factory.deploy, (address(treasury), registry, IERC4626(address(vault)))));
    }

    function test_constructorTreasuryZeroReturnsExactZeroAddressBytes() public {
        (bool success, bytes memory data) = _deployWithTreasuryMode(ERC4626StrategyModeTreasury.ResponseMode.Zero);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SharedBase.ZeroAddress.selector));
    }

    function test_constructorTreasuryRevertBubblesExactBytes() public {
        (bool success, bytes memory data) = _deployWithTreasuryMode(ERC4626StrategyModeTreasury.ResponseMode.Revert);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "TREASURY_USDC_REVERT"));
    }

    function test_constructorTreasuryEmptyReturnsObservedEmptyBytes() public {
        (bool success, bytes memory data) = _deployWithTreasuryMode(ERC4626StrategyModeTreasury.ResponseMode.Empty);
        assert(!success && data.length == 0);
    }

    function test_constructorTreasuryShortReturnsObservedEmptyDecodeBytes() public {
        (bool success, bytes memory data) = _deployWithTreasuryMode(ERC4626StrategyModeTreasury.ResponseMode.Short);
        assert(!success && data.length == 0);
    }

    function test_constructorTreasuryMalformedReturnsObservedEmptyDecodeBytes() public {
        (bool success, bytes memory data) = _deployWithTreasuryMode(ERC4626StrategyModeTreasury.ResponseMode.Malformed);
        assert(!success && data.length == 0);
    }

    function _deployWithVaultMode(ERC4626StrategyAssetResponseVault.Mode mode)
        internal
        returns (bool success, bytes memory data, ERC4626StrategyAssetResponseVault responseVault)
    {
        ERC4626StrategyFactory factory = new ERC4626StrategyFactory();
        responseVault = new ERC4626StrategyAssetResponseVault(address(usdc));
        responseVault.setMode(mode);
        (success, data) = address(factory)
            .call(abi.encodeCall(factory.deploy, (address(treasury), registry, IERC4626(address(responseVault)))));
    }

    function test_constructorVaultAssetRevertBubblesExactBytesAndIsAtomic() public {
        (bool success, bytes memory data, ERC4626StrategyAssetResponseVault responseVault) =
            _deployWithVaultMode(ERC4626StrategyAssetResponseVault.Mode.Revert);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "VAULT_ASSET_REVERT"));
        assert(usdc.allowance(address(this), address(responseVault)) == 0);
    }

    function test_constructorVaultAssetEmptyReturnsObservedEmptyBytesAndIsAtomic() public {
        (bool success, bytes memory data,) = _deployWithVaultMode(ERC4626StrategyAssetResponseVault.Mode.Empty);
        assert(!success && data.length == 0);
    }

    function test_constructorVaultAssetShortReturnsObservedEmptyDecodeBytesAndIsAtomic() public {
        (bool success, bytes memory data,) = _deployWithVaultMode(ERC4626StrategyAssetResponseVault.Mode.Short);
        assert(!success && data.length == 0);
    }

    function test_constructorVaultAssetMalformedReturnsObservedEmptyDecodeBytesAndIsAtomic() public {
        (bool success, bytes memory data,) = _deployWithVaultMode(ERC4626StrategyAssetResponseVault.Mode.Malformed);
        assert(!success && data.length == 0);
    }

    function _deployWithApprovalMode(ERC4626StrategyModeToken.ReturnMode mode)
        internal
        returns (bool success, bytes memory data)
    {
        usdc.setApprovalScript(mode, mode, mode, false);
        ERC4626StrategyFactory factory = new ERC4626StrategyFactory();
        return
            address(factory)
                .call(abi.encodeCall(factory.deploy, (address(treasury), registry, IERC4626(address(vault)))));
    }

    function test_constructorForceApproveFalseReturnsExactSafeERC20Bytes() public {
        (bool success, bytes memory data) = _deployWithApprovalMode(ERC4626StrategyModeToken.ReturnMode.False);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
    }

    function test_constructorForceApproveMalformedReturnsExactSafeERC20Bytes() public {
        (bool success, bytes memory data) = _deployWithApprovalMode(ERC4626StrategyModeToken.ReturnMode.Malformed);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
    }

    function test_constructorForceApproveRevertBubblesExactBytes() public {
        (bool success, bytes memory data) = _deployWithApprovalMode(ERC4626StrategyModeToken.ReturnMode.Revert);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "APPROVE_REVERT"));
    }

    function test_constructorForceApproveNoReturnSucceedsExactly() public {
        usdc.setApprovalScript(
            ERC4626StrategyModeToken.ReturnMode.NoReturn,
            ERC4626StrategyModeToken.ReturnMode.Normal,
            ERC4626StrategyModeToken.ReturnMode.Normal,
            false
        );
        ERC4626StrategyFactory factory = new ERC4626StrategyFactory();
        ERC4626Strategy fresh = factory.deploy(address(treasury), registry, vault);
        assert(usdc.allowance(address(fresh), address(vault)) == type(uint256).max);
    }

    function test_totalAssetsFullWidthCompositionAndLooseUsdcExclusion(uint256 shares, uint256 assets) public {
        // The model's virtual-share/asset additions require each independently full-width input
        // to stay below max; zero is intentionally included.
        vm.assume(shares < type(uint256).max && assets <= type(uint256).max - 17);
        vault.mintShares(address(strategy), shares);
        usdc.mint(address(vault), assets);
        usdc.mint(address(strategy), 17);
        assert(strategy.totalAssets() == vault.convertToAssets(shares));
    }

    function test_totalAssetsShareBalanceRevertBubblesExactBytes() public {
        vault.setViewModes(false, false, true, false, false, false);
        (bool success, bytes memory data) = address(strategy).staticcall(abi.encodeCall(strategy.totalAssets, ()));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "SHARE_BALANCE_REVERT"));
    }

    function test_totalAssetsShareBalanceMalformedFailsClosedWithEmptyBytes() public {
        vault.setViewModes(false, false, false, true, false, false);
        (bool success, bytes memory data) = address(strategy).staticcall(abi.encodeCall(strategy.totalAssets, ()));
        assert(!success && data.length == 0);
    }

    function test_totalAssetsConvertRevertBubblesExactBytes() public {
        vault.setViewModes(true, false, false, false, false, false);
        (bool success, bytes memory data) = address(strategy).staticcall(abi.encodeCall(strategy.totalAssets, ()));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "CONVERT_REVERT"));
    }

    function test_totalAssetsConvertMalformedFailsClosedWithEmptyBytes() public {
        vault.setViewModes(false, true, false, false, false, false);
        (bool success, bytes memory data) = address(strategy).staticcall(abi.encodeCall(strategy.totalAssets, ()));
        assert(!success && data.length == 0);
    }

    function test_deployPositiveReturnWithoutSharesExactBoundarySucceeds(uint128 oneShareValue) public {
        vault.setDepositMode(ERC4626StrategyModeVault.DepositMode.PositiveNoShares, 0);
        vault.setOneShareValue(oneShareValue, true);
        uint256 independentlyDerivedTolerance = uint256(oneShareValue) + 1;
        uint256 amount = independentlyDerivedTolerance;
        usdc.mint(address(strategy), amount);
        treasury.deployInto(strategy, amount);
        assert(vault.convertToAssets(1) + 1 == amount);
        assert(vault.balanceOf(address(strategy)) == 0);
        assert(strategy.totalAssets() == 0);
        assert(usdc.balanceOf(address(vault)) == amount);
    }

    function test_deployPositiveReturnWithoutSharesOnePastBoundaryRevertsAndRollsBack() public {
        vault.setDepositMode(ERC4626StrategyModeVault.DepositMode.PositiveNoShares, 0);
        vault.setOneShareValue(1, true);
        usdc.mint(address(strategy), 3);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.deployInto, (strategy, uint256(3))));
        assert(!success);
        _assertExactBytes(
            data, abi.encodeWithSelector(ERC4626Strategy.DepositValueShort.selector, uint256(3), uint256(0))
        );
        assert(usdc.balanceOf(address(strategy)) == 3);
        assert(usdc.balanceOf(address(vault)) == 0);
    }

    function test_deployPostValueUnderflowIsExactPanicAndAtomic() public {
        _deploy(10);
        vault.setDepositMode(ERC4626StrategyModeVault.DepositMode.BurnOneShare, 0);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.deployInto, (strategy, uint256(0))));
        assert(!success);
        _assertPanic(data);
        assert(vault.balanceOf(address(strategy)) == 10);
        assert(usdc.balanceOf(address(vault)) == 10);
    }

    function test_deployTolerancePlusOneOverflowIsExactPanic() public {
        vault.setDepositMode(ERC4626StrategyModeVault.DepositMode.PositiveNoShares, 0);
        vault.setOneShareValue(type(uint256).max, true);
        usdc.mint(address(strategy), 1);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.deployInto, (strategy, uint256(1))));
        assert(!success);
        _assertPanic(data);
        assert(usdc.balanceOf(address(strategy)) == 1);
    }

    function test_deployReceivedPlusToleranceOverflowIsExactPanic() public {
        vault.setOneShareValue(type(uint256).max - 1, true);
        usdc.mint(address(strategy), 1);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.deployInto, (strategy, uint256(1))));
        assert(!success);
        _assertPanic(data);
        assert(vault.balanceOf(address(strategy)) == 0);
    }

    function _callDeployWithDepositMode(ERC4626StrategyModeVault.DepositMode mode)
        internal
        returns (bool success, bytes memory data)
    {
        vault.setDepositMode(mode, 0);
        usdc.mint(address(strategy), 1);
        return address(treasury).call(abi.encodeCall(treasury.deployInto, (strategy, uint256(1))));
    }

    function test_depositRevertBubblesExactBytesAndRollsBack() public {
        (bool success, bytes memory data) = _callDeployWithDepositMode(ERC4626StrategyModeVault.DepositMode.Revert);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "DEPOSIT_REVERT"));
        assert(usdc.balanceOf(address(strategy)) == 1);
    }

    function test_depositEmptyReturnFailsWithObservedEmptyBytesAndRollsBack() public {
        (bool success, bytes memory data) = _callDeployWithDepositMode(ERC4626StrategyModeVault.DepositMode.Empty);
        assert(!success && data.length == 0);
        assert(usdc.balanceOf(address(strategy)) == 1);
    }

    function test_depositMalformedReturnFailsWithObservedEmptyDecodeBytesAndRollsBack() public {
        (bool success, bytes memory data) = _callDeployWithDepositMode(ERC4626StrategyModeVault.DepositMode.Malformed);
        assert(!success && data.length == 0);
        assert(usdc.balanceOf(address(strategy)) == 1);
    }

    function test_depositTransferFromFalseReturnsExactSafeERC20BytesAndRollsBack() public {
        vault.setDepositMode(ERC4626StrategyModeVault.DepositMode.Standard, 0);
        usdc.mint(address(strategy), 1);
        usdc.setTransferModes(ERC4626StrategyModeToken.ReturnMode.Normal, ERC4626StrategyModeToken.ReturnMode.False);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.deployInto, (strategy, uint256(1))));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
        assert(usdc.balanceOf(address(strategy)) == 1);
        assert(usdc.balanceOf(address(vault)) == 0);
    }

    function test_depositTransferFromNoReturnSucceedsExactlyOnce() public {
        vault.setDepositMode(ERC4626StrategyModeVault.DepositMode.Standard, 0);
        usdc.mint(address(strategy), 1);
        usdc.setTransferModes(ERC4626StrategyModeToken.ReturnMode.Normal, ERC4626StrategyModeToken.ReturnMode.NoReturn);
        treasury.deployInto(strategy, 1);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(usdc.balanceOf(address(vault)) == 1);
        assert(vault.balanceOf(address(strategy)) == 1);
    }

    function test_depositTransferFromMalformedReturnsExactSafeERC20BytesAndRollsBack() public {
        vault.setDepositMode(ERC4626StrategyModeVault.DepositMode.Standard, 0);
        usdc.mint(address(strategy), 1);
        usdc.setTransferModes(ERC4626StrategyModeToken.ReturnMode.Normal, ERC4626StrategyModeToken.ReturnMode.Malformed);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.deployInto, (strategy, uint256(1))));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
        assert(usdc.balanceOf(address(strategy)) == 1);
    }

    function test_depositTransferFromRevertBubblesExactBytesAndRollsBack() public {
        vault.setDepositMode(ERC4626StrategyModeVault.DepositMode.Standard, 0);
        usdc.mint(address(strategy), 1);
        usdc.setTransferModes(ERC4626StrategyModeToken.ReturnMode.Normal, ERC4626StrategyModeToken.ReturnMode.Revert);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.deployInto, (strategy, uint256(1))));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "TRANSFER_FROM_REVERT"));
        assert(usdc.balanceOf(address(strategy)) == 1);
    }

    function test_withdrawOverdeliverySucceedsWithMeasuredBalanceDelta() public {
        _deploy(100);
        vault.setRedeemMode(ERC4626StrategyModeVault.RedeemMode.Over, 3);
        uint256 beforeTreasury = usdc.balanceOf(address(treasury));
        treasury.withdrawFrom(strategy, 40);
        assert(usdc.balanceOf(address(treasury)) == beforeTreasury + 43);
        assert(vault.balanceOf(address(strategy)) == 60);
    }

    function test_withdrawTreasuryBalanceDecreaseUnderflowsAndRollsBack() public {
        _deploy(100);
        usdc.mint(address(treasury), 10);
        vault.setRedeemMode(ERC4626StrategyModeVault.RedeemMode.TreasuryDecrease, 10);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.withdrawFrom, (strategy, uint256(4))));
        assert(!success);
        _assertPanic(data);
        assert(usdc.balanceOf(address(treasury)) == 10);
        assert(vault.balanceOf(address(strategy)) == 100);
    }

    function test_withdrawPostBalanceRevertIsBubbledAndAllStateRollsBack() public {
        _deploy(100);
        vault.setRedeemMode(ERC4626StrategyModeVault.RedeemMode.PoisonPostBalance, 0);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.withdrawFrom, (strategy, uint256(4))));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "BALANCE_REVERT"));
        assert(usdc.balanceOf(address(treasury)) == 0);
        assert(vault.balanceOf(address(strategy)) == 100);
        assert(usdc.balanceMode() == ERC4626StrategyModeToken.ReturnMode.Normal);
    }

    function test_withdrawPostBalanceMalformedRollsBackAllState() public {
        _deploy(100);
        vault.setRedeemMode(ERC4626StrategyModeVault.RedeemMode.PoisonPostBalanceMalformed, 0);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.withdrawFrom, (strategy, uint256(4))));
        assert(!success && data.length == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
        assert(vault.balanceOf(address(strategy)) == 100);
        assert(usdc.balanceMode() == ERC4626StrategyModeToken.ReturnMode.Normal);
    }

    function test_withdrawNoCodeVaultIsPreemptedAtPreviewWithEmptyBytes() public {
        _deploy(10);
        vm.etch(address(vault), bytes(""));
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.withdrawFrom, (strategy, uint256(1))));
        assert(!success && data.length == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
        assert(usdc.balanceOf(address(vault)) == 10);
    }

    function test_withdrawPreviewRevertBubblesExactBytesAndPreemptsRedeem() public {
        _deploy(10);
        vault.setViewModes(false, false, false, false, true, false);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.withdrawFrom, (strategy, uint256(1))));
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "PREVIEW_REVERT"));
        assert(vault.balanceOf(address(strategy)) == 10);
    }

    function test_withdrawPreviewMalformedFailsClosedAndPreemptsRedeem() public {
        _deploy(10);
        vault.setViewModes(false, false, false, false, false, true);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.withdrawFrom, (strategy, uint256(1))));
        assert(!success && data.length == 0);
        assert(vault.balanceOf(address(strategy)) == 10);
    }

    function _callWithdrawWithRedeemMode(ERC4626StrategyModeVault.RedeemMode mode)
        internal
        returns (bool success, bytes memory data)
    {
        _deploy(10);
        vault.setRedeemMode(mode, 0);
        return address(treasury).call(abi.encodeCall(treasury.withdrawFrom, (strategy, uint256(1))));
    }

    function test_withdrawRedeemRevertBubblesExactBytesAndIsAtomic() public {
        (bool success, bytes memory data) = _callWithdrawWithRedeemMode(ERC4626StrategyModeVault.RedeemMode.Revert);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "REDEEM_REVERT"));
        assert(vault.balanceOf(address(strategy)) == 10);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_withdrawRedeemEmptyReturnFailsWithObservedEmptyBytesAndIsAtomic() public {
        (bool success, bytes memory data) = _callWithdrawWithRedeemMode(ERC4626StrategyModeVault.RedeemMode.Empty);
        assert(!success && data.length == 0);
        assert(vault.balanceOf(address(strategy)) == 10);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_withdrawRedeemMalformedReturnFailsWithObservedEmptyDecodeBytesAndIsAtomic() public {
        (bool success, bytes memory data) = _callWithdrawWithRedeemMode(ERC4626StrategyModeVault.RedeemMode.Malformed);
        assert(!success && data.length == 0);
        assert(vault.balanceOf(address(strategy)) == 10);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_withdrawPostBalanceShortReportDriftRevertsExactlyAndRollsBack() public {
        _deploy(100);
        vault.setRedeemMode(ERC4626StrategyModeVault.RedeemMode.ReportPostBalanceShort, 1);
        (bool success, bytes memory data) =
            address(treasury).call(abi.encodeCall(treasury.withdrawFrom, (strategy, uint256(40))));
        assert(!success);
        _assertExactBytes(
            data, abi.encodeWithSelector(ERC4626Strategy.WithdrawShort.selector, uint256(40), uint256(39))
        );
        assert(vault.balanceOf(address(strategy)) == 100);
        assert(usdc.balanceOf(address(treasury)) == 0);
        assert(usdc.balanceMode() == ERC4626StrategyModeToken.ReturnMode.Normal);
        assert(usdc.balanceOffset() == 0);
    }

    function test_withdrawPostBalanceOverReportDriftCanAcceptPhantomOverdelivery() public {
        _deploy(100);
        vault.setRedeemMode(ERC4626StrategyModeVault.RedeemMode.ReportPostBalanceOver, 1);
        treasury.withdrawFrom(strategy, 40);
        assert(usdc.balanceOf(address(treasury)) == 41);
        usdc.setBalanceMode(ERC4626StrategyModeToken.ReturnMode.Normal, 0, false);
        assert(usdc.balanceOf(address(treasury)) == 40);
        assert(vault.balanceOf(address(strategy)) == 60);
    }
}

/// @notice Approval, balance-delta, principal-value, callback, and transient
/// guard closure for the only successful final-derived pair: reward -> USDC.
contract ERC4626StrategySwapModesKontrolTest is ERC4626StrategyCurrentSourceBase {
    function test_successfulTargetDistinctFromSpenderLeavesFiniteAllowanceZero() public {
        address spender = address(0x5150);
        registry.setSwapRoute(address(router), spender, true);
        reward.mint(address(strategy), 5);
        bytes memory route = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(7)));
        uint256 amountOut = strategy.swap(reward, usdc, 5, address(router), spender, route, 7);
        assert(amountOut == 7);
        assert(reward.balanceOf(address(strategy)) == 5);
        assert(reward.allowance(address(strategy), spender) == 0);
        assert(usdc.balanceOf(address(treasury)) == 7);
    }

    function test_usdtStyleFiniteAllowanceReplacementAndCleanup() public {
        reward.mint(address(strategy), 10);
        vm.prank(address(strategy));
        reward.approve(address(router), 3);
        reward.setApprovalScript(
            ERC4626StrategyModeToken.ReturnMode.Normal,
            ERC4626StrategyModeToken.ReturnMode.Normal,
            ERC4626StrategyModeToken.ReturnMode.Normal,
            true
        );
        bytes memory route = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(2)));
        uint256 amountOut = strategy.swap(reward, usdc, 10, address(router), address(router), route, 2);
        assert(amountOut == 2);
        assert(reward.allowance(address(strategy), address(router)) == 0);
        assert(reward.approveCalls() == 4);
    }

    function test_infinitePreexistingAllowanceIsReplacedThenCleaned() public {
        vm.prank(address(strategy));
        reward.approve(address(router), type(uint256).max);
        bytes memory route = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(2)));
        uint256 amountOut = strategy.swap(reward, usdc, 1, address(router), address(router), route, 2);
        assert(amountOut == 2);
        assert(reward.allowance(address(strategy), address(router)) == 0);
    }

    function _callSwapWithInitialApprovalMode(ERC4626StrategyModeToken.ReturnMode mode)
        internal
        returns (bool success, bytes memory data)
    {
        reward.setApprovalScript(mode, mode, mode, false);
        bytes memory route = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(1)));
        return _swap(route, 1, 1);
    }

    function test_approvalInitialFalseReturnsExactSafeERC20BytesBeforeRouter() public {
        (bool success, bytes memory data) = _callSwapWithInitialApprovalMode(ERC4626StrategyModeToken.ReturnMode.False);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(reward)));
        assert(usdc.balanceOf(address(treasury)) == 0);
        assert(reward.allowance(address(strategy), address(router)) == 0);
    }

    function test_approvalInitialMalformedReturnsExactSafeERC20BytesBeforeRouter() public {
        (bool success, bytes memory data) =
            _callSwapWithInitialApprovalMode(ERC4626StrategyModeToken.ReturnMode.Malformed);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(reward)));
        assert(usdc.balanceOf(address(treasury)) == 0);
        assert(reward.allowance(address(strategy), address(router)) == 0);
    }

    function test_approvalInitialRevertBubblesExactBytesBeforeRouter() public {
        (bool success, bytes memory data) = _callSwapWithInitialApprovalMode(ERC4626StrategyModeToken.ReturnMode.Revert);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "APPROVE_REVERT"));
        assert(usdc.balanceOf(address(treasury)) == 0);
        assert(reward.allowance(address(strategy), address(router)) == 0);
    }

    function test_approvalInitialNoReturnSucceedsAndCleanupIsExact() public {
        reward.setApprovalScript(
            ERC4626StrategyModeToken.ReturnMode.NoReturn,
            ERC4626StrategyModeToken.ReturnMode.Normal,
            ERC4626StrategyModeToken.ReturnMode.Normal,
            false
        );
        bytes memory route = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(1)));
        (bool success, bytes memory data) = _swap(route, 1, 1);
        assert(success && abi.decode(data, (uint256)) == 1);
        assert(reward.allowance(address(strategy), address(router)) == 0);
        assert(reward.approveCalls() == 2);
        assert(usdc.balanceOf(address(treasury)) == 1);
    }

    function test_resetFailureRollsBackOutputAndRestoresPriorFiniteAllowance() public {
        reward.mint(address(strategy), 5);
        vm.prank(address(strategy));
        reward.approve(address(router), 2);
        reward.setApprovalScript(
            ERC4626StrategyModeToken.ReturnMode.Normal,
            ERC4626StrategyModeToken.ReturnMode.False,
            ERC4626StrategyModeToken.ReturnMode.False,
            false
        );
        bytes memory route = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(3)));
        (bool success, bytes memory data) = _swap(route, 5, 3);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(reward)));
        assert(reward.allowance(address(strategy), address(router)) == 2);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_usdtRetryFailureRestoresPriorAllowance() public {
        reward.mint(address(strategy), 5);
        vm.prank(address(strategy));
        reward.approve(address(router), 2);
        reward.setApprovalScript(
            ERC4626StrategyModeToken.ReturnMode.Normal,
            ERC4626StrategyModeToken.ReturnMode.Normal,
            ERC4626StrategyModeToken.ReturnMode.False,
            true
        );
        bytes memory route = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(3)));
        (bool success, bytes memory data) = _swap(route, 5, 3);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(reward)));
        assert(reward.allowance(address(strategy), address(router)) == 2);
    }

    function test_routeRevertRestoresPriorFiniteAllowanceNotZero() public {
        reward.mint(address(strategy), 5);
        vm.prank(address(strategy));
        reward.approve(address(router), 2);
        (bool success, bytes memory data) = _swap(hex"deadbeef", 5, 1);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(Errors.FailedCall.selector));
        assert(reward.allowance(address(strategy), address(router)) == 2);
    }

    function test_routeFailureRestoresPriorInfiniteAllowanceExactly() public {
        reward.mint(address(strategy), 5);
        vm.prank(address(strategy));
        reward.approve(address(router), type(uint256).max);
        (bool success, bytes memory data) = _swap(hex"deadbeef", 5, 1);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(Errors.FailedCall.selector));
        assert(reward.allowance(address(strategy), address(router)) == type(uint256).max);
        assert(reward.balanceOf(address(strategy)) == 5);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function _consumeInputRoute(uint256 amountOut) internal view returns (bytes memory) {
        return
            abi.encodeCall(router.consume, (reward, address(strategy), uint256(5), usdc, address(strategy), amountOut));
    }

    function test_inputTransferFromFalseIsIgnoredByRouterAndSwapUsesMeasuredOutput() public {
        reward.mint(address(strategy), 5);
        reward.setTransferModes(ERC4626StrategyModeToken.ReturnMode.Normal, ERC4626StrategyModeToken.ReturnMode.False);
        (bool success, bytes memory data) = _swap(_consumeInputRoute(2), 5, 2);
        assert(success && abi.decode(data, (uint256)) == 2);
        assert(reward.balanceOf(address(strategy)) == 5);
        assert(reward.balanceOf(address(router)) == 0);
        assert(reward.allowance(address(strategy), address(router)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 2);
    }

    function test_inputTransferFromNoReturnYieldsExactFailedCallAndRollsBack() public {
        reward.mint(address(strategy), 5);
        reward.setTransferModes(
            ERC4626StrategyModeToken.ReturnMode.Normal, ERC4626StrategyModeToken.ReturnMode.NoReturn
        );
        (bool success, bytes memory data) = _swap(_consumeInputRoute(2), 5, 2);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(Errors.FailedCall.selector));
        assert(reward.balanceOf(address(strategy)) == 5);
        assert(reward.balanceOf(address(router)) == 0);
        assert(reward.allowance(address(strategy), address(router)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_inputTransferFromMalformedReturnYieldsExactFailedCallAndRollsBack() public {
        reward.mint(address(strategy), 5);
        reward.setTransferModes(
            ERC4626StrategyModeToken.ReturnMode.Normal, ERC4626StrategyModeToken.ReturnMode.Malformed
        );
        (bool success, bytes memory data) = _swap(_consumeInputRoute(2), 5, 2);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(Errors.FailedCall.selector));
        assert(reward.balanceOf(address(strategy)) == 5);
        assert(reward.balanceOf(address(router)) == 0);
        assert(reward.allowance(address(strategy), address(router)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_inputTransferFromRevertBubblesExactBytesAndRollsBack() public {
        reward.mint(address(strategy), 5);
        reward.setTransferModes(ERC4626StrategyModeToken.ReturnMode.Normal, ERC4626StrategyModeToken.ReturnMode.Revert);
        (bool success, bytes memory data) = _swap(_consumeInputRoute(2), 5, 2);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "TRANSFER_FROM_REVERT"));
        assert(reward.balanceOf(address(strategy)) == 5);
        assert(reward.balanceOf(address(router)) == 0);
        assert(reward.allowance(address(strategy), address(router)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_outputBalanceDecreaseUnderflowsAndRollsBack() public {
        usdc.mint(address(strategy), 5);
        bytes memory route = abi.encodeCall(router.depleteOutput, (usdc, address(strategy), uint256(1)));
        (bool success, bytes memory data) = _swap(route, 1, 1);
        assert(!success);
        _assertPanic(data);
        assert(usdc.balanceOf(address(strategy)) == 5);
        assert(reward.allowance(address(strategy), address(router)) == 0);
    }

    function _callSwapWithOutputTransferMode(ERC4626StrategyModeToken.ReturnMode mode)
        internal
        returns (bool success, bytes memory data)
    {
        usdc.setTransferModes(mode, ERC4626StrategyModeToken.ReturnMode.Normal);
        bytes memory route = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(2)));
        return _swap(route, 1, 2);
    }

    function test_usdcTransferFalseReturnsExactSafeERC20BytesAndRollsBackMeasuredOutput() public {
        (bool success, bytes memory data) = _callSwapWithOutputTransferMode(ERC4626StrategyModeToken.ReturnMode.False);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_usdcTransferMalformedReturnsExactSafeERC20BytesAndRollsBackMeasuredOutput() public {
        (bool success, bytes memory data) =
            _callSwapWithOutputTransferMode(ERC4626StrategyModeToken.ReturnMode.Malformed);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_usdcTransferRevertBubblesExactBytesAndRollsBackMeasuredOutput() public {
        (bool success, bytes memory data) = _callSwapWithOutputTransferMode(ERC4626StrategyModeToken.ReturnMode.Revert);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "TRANSFER_REVERT"));
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_usdcNoReturnTransferSucceedsWithExactOneTimeDelta() public {
        usdc.setTransferModes(ERC4626StrategyModeToken.ReturnMode.NoReturn, ERC4626StrategyModeToken.ReturnMode.Normal);
        bytes memory route = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(2)));
        (bool success, bytes memory data) = _swap(route, 1, 2);
        assert(success && abi.decode(data, (uint256)) == 2);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 2);
    }

    function test_outputBalanceRevertPreemptsApprovalAndRouterWithExactBytes() public {
        usdc.setBalanceMode(ERC4626StrategyModeToken.ReturnMode.Revert, 0, false);
        bytes memory route = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(2)));
        (bool success, bytes memory data) = _swap(route, 1, 2);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "BALANCE_REVERT"));
        usdc.setBalanceMode(ERC4626StrategyModeToken.ReturnMode.Normal, 0, false);
        assert(reward.allowance(address(strategy), address(router)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_outputBalanceMalformedPreemptsApprovalAndRouterWithObservedEmptyBytes() public {
        usdc.setBalanceMode(ERC4626StrategyModeToken.ReturnMode.Malformed, 0, false);
        bytes memory route = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(2)));
        (bool success, bytes memory data) = _swap(route, 1, 2);
        assert(!success && data.length == 0);
        usdc.setBalanceMode(ERC4626StrategyModeToken.ReturnMode.Normal, 0, false);
        assert(reward.allowance(address(strategy), address(router)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_shareCountPrincipalIncreaseSucceeds() public {
        bytes memory route =
            abi.encodeCall(router.outputAndIncreaseShares, (usdc, address(strategy), uint256(2), vault, uint256(3)));
        (bool success, bytes memory data) = _swap(route, 1, 2);
        assert(success);
        assert(abi.decode(data, (uint256)) == 2);
        assert(vault.balanceOf(address(strategy)) == 3);
    }

    function test_unchangedShareCountDoesNotPreventPrincipalValueLoss() public {
        _deploy(10);
        uint256 valueBefore = strategy.totalAssets();
        bytes memory route = abi.encodeCall(
            router.destroyVaultAssetsAndOutput, (usdc, address(vault), uint256(4), address(strategy), uint256(2))
        );
        (bool success,) = _swap(route, 1, 2);
        assert(success);
        assert(vault.balanceOf(address(strategy)) == 10);
        assert(strategy.totalAssets() < valueBefore);
    }

    function test_routerCanCallbackThroughTreasuryIntoUnguardedDeployOnce() public {
        usdc.mint(address(strategy), 10);
        bytes memory route =
            abi.encodeCall(router.treasuryDeployAndOutput, (treasury, strategy, uint256(10), usdc, uint256(12)));
        (bool success,) = _swap(route, 1, 2);
        assert(success);
        assert(vault.balanceOf(address(strategy)) == 10);
        assert(usdc.balanceOf(address(treasury)) == 2);
    }

    function test_routerTreasuryWithdrawCallbackHitsPrincipalCheckAndRollsBack() public {
        _deploy(10);
        bytes memory route =
            abi.encodeCall(router.treasuryWithdrawAndOutput, (treasury, strategy, uint256(1), usdc, uint256(2)));
        (bool success, bytes memory data) = _swap(route, 1, 2);
        assert(!success);
        _assertExactBytes(
            data, abi.encodeWithSelector(StrategyBase.PrincipalDecreased.selector, uint256(10), uint256(9))
        );
        assert(vault.balanceOf(address(strategy)) == 10);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_routerAdminCanCallbackIntoUnguardedEthSweep() public {
        registry.setAdmin(address(router), true);
        vm.deal(address(strategy), 3);
        bytes memory route = abi.encodeCall(router.sweepEthAndOutput, (strategy, payable(RECIPIENT), usdc, uint256(2)));
        (bool success,) = _swap(route, 1, 2);
        assert(success);
        assert(RECIPIENT.balance == 3);
        assert(address(strategy).balance == 0);
    }

    function test_routerAdminCanCallbackIntoUnguardedTokenSweepAndCatchExactFailure() public {
        registry.setAdmin(address(router), true);
        bytes memory route = abi.encodeCall(
            router.sweepTokenCatchAndOutput, (strategy, IERC20(address(reward)), RECIPIENT, usdc, uint256(2))
        );
        (bool success, bytes memory data) = _swap(route, 1, 2);
        assert(success && abi.decode(data, (uint256)) == 2);
        assert(usdc.balanceOf(address(treasury)) == 2);
    }

    function test_reentrantSwapBubblesExactFourBytesAndGuardClearsAfterRevert() public {
        registry.setAdmin(address(router), true);
        bytes memory route =
            abi.encodeCall(router.reenterBubble, (strategy, IERC20(address(reward)), IERC20(address(usdc))));
        (bool success, bytes memory data) = _swap(route, 1, 1);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));

        bytes memory retryRoute = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(2)));
        (bool retrySuccess, bytes memory retryData) = _swap(retryRoute, 1, 2);
        assert(retrySuccess && abi.decode(retryData, (uint256)) == 2);
    }

    function test_caughtExactReentrancyThenOuterRevertStillClearsGuard() public {
        registry.setAdmin(address(router), true);
        bytes memory route =
            abi.encodeCall(router.reenterCatchAndRevert, (strategy, IERC20(address(reward)), IERC20(address(usdc))));
        (bool success, bytes memory data) = _swap(route, 1, 1);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "OUTER_REVERT"));

        bytes memory retryRoute = abi.encodeCall(router.outputOnly, (usdc, address(strategy), uint256(2)));
        (bool retrySuccess,) = _swap(retryRoute, 1, 2);
        assert(retrySuccess);
    }

    function test_aclPoisonedDownstreamPrecedenceDoesNotReadTokensOrRouter() public {
        vault.setViewModes(false, false, true, false, false, false);
        reward.setApprovalScript(
            ERC4626StrategyModeToken.ReturnMode.Revert,
            ERC4626StrategyModeToken.ReturnMode.Revert,
            ERC4626StrategyModeToken.ReturnMode.Revert,
            false
        );
        vm.prank(address(0xBAD));
        (bool success, bytes memory data) = address(strategy)
            .call(
                abi.encodeCall(
                    strategy.swap,
                    (
                        IERC20(address(vault)),
                        IERC20(address(usdc)),
                        0,
                        address(0xDEAD),
                        address(0xBEEF),
                        hex"deadbeef",
                        0
                    )
                )
            );
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, address(0xBAD)));
    }
}
