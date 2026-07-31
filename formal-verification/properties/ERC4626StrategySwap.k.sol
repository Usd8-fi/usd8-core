// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Registry} from "../../src/Registry.sol";
import {StrategyBase} from "../../src/strategies/StrategyBase.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";
import {
    ERC4626StrategyHarnessToken,
    ERC4626StrategyKontrolBase,
    ERC4626StrategySwapRouter
} from "./ERC4626StrategyHarness.k.sol";

/// @notice Final-derived-bytecode swap ACL, precedence, execution, rollback, and callback properties.
/// @dev [C:REGISTRY] production Registry role/route semantics; [C:TOKENS] exact, non-rebasing ERC-20 models.
contract ERC4626StrategySwapKontrolTest is ERC4626StrategyKontrolBase {
    ERC4626StrategyHarnessToken internal reward;
    ERC4626StrategyHarnessToken internal other;
    ERC4626StrategySwapRouter internal router;

    function setUp() public override {
        super.setUp();
        reward = new ERC4626StrategyHarnessToken();
        other = new ERC4626StrategyHarnessToken();
        router = new ERC4626StrategySwapRouter();
        registry.setSwapRoute(address(router), address(router), true);
    }

    function _route(uint256 amountIn, uint256 amountOut) internal view returns (bytes memory) {
        return abi.encodeCall(router.swap, (IERC20(address(reward)), amountIn, usdc, amountOut, address(strategy)));
    }

    function _callSwap(
        address caller,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        address target,
        address spender,
        bytes memory route,
        uint256 minimum
    ) internal returns (bool success, bytes memory data) {
        vm.prank(caller);
        return address(strategy)
            .call(abi.encodeCall(strategy.swap, (tokenIn, tokenOut, amountIn, target, spender, route, minimum)));
    }

    function _seedRollbackState() internal {
        _fundStrategy(19);
        _deploy(19);
        reward.mint(address(strategy), 13);
        other.mint(address(strategy), 23);
        usdc.mint(address(strategy), 17);
    }

    function _assertRollbackSeed() internal view {
        assert(vault.balanceOf(address(strategy)) == 19);
        assert(usdc.balanceOf(address(vault)) == 19);
        assert(reward.balanceOf(address(strategy)) == 13);
        assert(other.balanceOf(address(strategy)) == 23);
        assert(usdc.balanceOf(address(strategy)) == 17);
        assert(usdc.balanceOf(address(treasury)) == 0);
        assert(reward.allowance(address(strategy), address(router)) == 0);
    }

    function test_aclPrecedesZeroRoutePairAndProtectionChecks() public {
        (bool success, bytes memory data) =
            _callSwap(OUTSIDER, IERC20(address(vault)), other, 0, address(vault), address(usdc), "", 0);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, OUTSIDER));
    }

    function test_adminAndTimelockBothExecuteApprovedRoute() public {
        reward.mint(address(strategy), 20);
        uint256 adminOut = strategy.swap(reward, usdc, 10, address(router), address(router), _route(10, 7), 7);
        assert(adminOut == 7);
        reward.mint(address(strategy), 10);
        vm.prank(ADMIN);
        uint256 timelockOut = strategy.swap(reward, usdc, 10, address(router), address(router), _route(10, 8), 8);
        assert(timelockOut == 8);
        assert(usdc.balanceOf(address(treasury)) == 15);
    }

    function test_zeroAmountPrecedesRouteAndPairChecksAndRollsBackFundedState() public {
        _seedRollbackState();
        registry.setSwapRoute(address(router), address(router), false);
        (bool success, bytes memory data) = _callSwap(ADMIN, vault, other, 0, address(router), address(router), "", 1);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(StrategyBase.ZeroAmount.selector));
        _assertRollbackSeed();
    }

    function test_zeroMinimumPrecedesRouteAndPairChecksAndRollsBackFundedState() public {
        _seedRollbackState();
        registry.setSwapRoute(address(router), address(router), false);
        (bool success, bytes memory data) = _callSwap(ADMIN, vault, other, 1, address(router), address(router), "", 0);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(StrategyBase.ZeroAmount.selector));
        _assertRollbackSeed();
    }

    function test_routeApprovalUsesExactTargetSpenderPairAndPrecedesPairChecks() public {
        _seedRollbackState();
        address differentSpender = address(0x5150);
        (bool success, bytes memory data) = _callSwap(ADMIN, vault, other, 1, address(router), differentSpender, "", 1);
        assert(!success);
        _assertExactBytes(
            data, abi.encodeWithSelector(StrategyBase.SwapRouteNotApproved.selector, address(router), differentSpender)
        );
        _assertRollbackSeed();
    }

    function test_sameTokenPairRejectionIsExactAndRollsBackFundedState() public {
        _seedRollbackState();
        (bool success, bytes memory data) = _callSwap(ADMIN, reward, reward, 1, address(router), address(router), "", 1);
        assert(!success);
        _assertExactBytes(
            data, abi.encodeWithSelector(StrategyBase.UnsupportedSwapPair.selector, address(reward), address(reward))
        );
        _assertRollbackSeed();
    }

    function test_nonUsdcOutputPairRejectionIsExactAndRollsBackFundedState() public {
        _seedRollbackState();
        (bool success, bytes memory data) = _callSwap(ADMIN, reward, other, 1, address(router), address(router), "", 1);
        assert(!success);
        _assertExactBytes(
            data, abi.encodeWithSelector(StrategyBase.UnsupportedSwapPair.selector, address(reward), address(other))
        );
        _assertRollbackSeed();
    }

    function test_vaultInputProtectionIsExactAndRollsBackFundedState() public {
        _seedRollbackState();
        (bool success, bytes memory data) = _callSwap(ADMIN, vault, usdc, 1, address(router), address(router), "", 1);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(StrategyBase.ProtectedSwapAsset.selector, address(vault)));
        _assertRollbackSeed();
    }

    function test_protectedTargetAndSpenderAreCheckedSeparatelyAfterPair() public {
        _seedRollbackState();
        registry.setSwapRoute(address(usdc), address(router), true);
        registry.setSwapRoute(address(router), address(vault), true);
        (bool targetSuccess, bytes memory targetData) =
            _callSwap(ADMIN, reward, usdc, 1, address(usdc), address(router), "", 1);
        (bool spenderSuccess, bytes memory spenderData) =
            _callSwap(ADMIN, reward, usdc, 1, address(router), address(vault), "", 1);
        assert(!targetSuccess && !spenderSuccess);
        _assertExactBytes(targetData, abi.encodeWithSelector(StrategyBase.ProtectedSwapAsset.selector, address(usdc)));
        _assertExactBytes(spenderData, abi.encodeWithSelector(StrategyBase.ProtectedSwapAsset.selector, address(vault)));
        _assertRollbackSeed();
    }

    function test_exactOutputDeltaPreservesLooseReserveAndCleansAllowance(uint128 amountIn, uint128 amountOut) public {
        vm.assume(amountIn > 0 && amountOut > 0);
        reward.mint(address(strategy), amountIn);
        usdc.mint(address(strategy), 11);
        uint256 received = strategy.swap(
            reward, usdc, amountIn, address(router), address(router), _route(amountIn, amountOut), amountOut
        );
        assert(received == amountOut);
        assert(usdc.balanceOf(address(strategy)) == 11);
        assert(usdc.balanceOf(address(treasury)) == amountOut);
        assert(reward.balanceOf(address(router)) == amountIn);
        assert(reward.allowance(address(strategy), address(router)) == 0);
        assert(vault.balanceOf(address(strategy)) == 0);
    }

    function test_forceApproveReplacesPreexistingAllowanceAndStillCleans() public {
        reward.mint(address(strategy), 10);
        vm.prank(address(strategy));
        reward.approve(address(router), 3);
        uint256 received = strategy.swap(reward, usdc, 10, address(router), address(router), _route(10, 9), 9);
        assert(received == 9);
        assert(reward.allowance(address(strategy), address(router)) == 0);
    }

    function test_routerMayConsumeNoInputButMeasuredOutputStillControlsSuccess() public {
        reward.mint(address(strategy), 10);
        bytes memory route = abi.encodeCall(router.outputOnly, (usdc, uint256(6), address(strategy)));
        uint256 received = strategy.swap(reward, usdc, 10, address(router), address(router), route, 6);
        assert(received == 6);
        assert(reward.balanceOf(address(strategy)) == 10);
        assert(reward.allowance(address(strategy), address(router)) == 0);
    }

    function test_routerMayPartiallyConsumeInputAndOutputMayExceedMinimum() public {
        reward.mint(address(strategy), 10);
        bytes memory route =
            abi.encodeCall(router.swap, (IERC20(address(reward)), uint256(4), usdc, uint256(7), address(strategy)));
        uint256 received = strategy.swap(reward, usdc, 10, address(router), address(router), route, 6);
        assert(received == 7);
        assert(reward.balanceOf(address(strategy)) == 6);
        assert(reward.balanceOf(address(router)) == 4);
        assert(reward.allowance(address(strategy), address(router)) == 0);
    }

    function test_routeRemovalAppliesImmediatelyAndLeavesStateUntouched() public {
        registry.setSwapRoute(address(router), address(router), false);
        reward.mint(address(strategy), 1);
        (bool success, bytes memory data) =
            _callSwap(ADMIN, reward, usdc, 1, address(router), address(router), _route(1, 1), 1);
        assert(!success);
        _assertExactBytes(
            data, abi.encodeWithSelector(StrategyBase.SwapRouteNotApproved.selector, address(router), address(router))
        );
        assert(reward.balanceOf(address(strategy)) == 1);
        assert(reward.allowance(address(strategy), address(router)) == 0);
    }

    function test_zeroTokenInputReachesExactNoCodeFailureAndRollsBack() public {
        (bool success, bytes memory data) =
            _callSwap(ADMIN, IERC20(address(0)), usdc, 1, address(router), address(router), "", 1);
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(0)));
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_lowOutputRevertsAllRouterTokenAndAllowanceEffects() public {
        reward.mint(address(strategy), 10);
        (bool success, bytes memory data) =
            _callSwap(ADMIN, reward, usdc, 10, address(router), address(router), _route(10, 4), 5);
        assert(!success);
        _assertExactBytes(
            data, abi.encodeWithSelector(StrategyBase.InsufficientSwapOutput.selector, uint256(5), uint256(4))
        );
        assert(reward.balanceOf(address(strategy)) == 10);
        assert(reward.balanceOf(address(router)) == 0);
        assert(reward.allowance(address(strategy), address(router)) == 0);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(usdc.balanceOf(address(treasury)) == 0);
    }

    function test_routeRevertBubblesAndRollsBackTemporaryApproval() public {
        reward.mint(address(strategy), 10);
        (bool success, bytes memory data) = _callSwap(
            ADMIN, reward, usdc, 10, address(router), address(router), abi.encodeCall(router.revertRoute, ()), 1
        );
        assert(!success);
        _assertExactBytes(data, abi.encodeWithSignature("Error(string)", "ROUTE_REVERT"));
        assert(reward.allowance(address(strategy), address(router)) == 0);
        assert(reward.balanceOf(address(strategy)) == 10);
    }

    function test_noCodeAndMalformedRouteUseExactAddressErrors() public {
        address noCode = address(0xC0DE);
        registry.setSwapRoute(noCode, address(router), true);
        reward.mint(address(strategy), 1);
        (bool noCodeSuccess, bytes memory noCodeData) =
            _callSwap(ADMIN, reward, usdc, 1, noCode, address(router), "", 1);
        (bool malformedSuccess, bytes memory malformedData) =
            _callSwap(ADMIN, reward, usdc, 1, address(router), address(router), hex"deadbeef", 1);
        assert(!noCodeSuccess && !malformedSuccess);
        _assertExactBytes(noCodeData, abi.encodeWithSelector(Address.AddressEmptyCode.selector, noCode));
        _assertExactBytes(malformedData, abi.encodeWithSelector(Errors.FailedCall.selector));
        assert(reward.balanceOf(address(strategy)) == 1);
        assert(reward.allowance(address(strategy), address(router)) == 0);
    }

    function test_principalDecreaseRevertsAndRollsBackPositionAndOutput() public {
        _fundStrategy(10);
        _deploy(10);
        reward.mint(address(strategy), 1);
        vm.prank(address(strategy));
        vault.approve(address(router), 1);
        bytes memory route = abi.encodeCall(
            router.consumePositionAndOutput,
            (IERC20(address(vault)), address(strategy), usdc, uint256(2), address(strategy))
        );
        (bool success, bytes memory data) =
            _callSwap(ADMIN, reward, usdc, 1, address(router), address(router), route, 1);
        assert(!success);
        _assertExactBytes(
            data, abi.encodeWithSelector(StrategyBase.PrincipalDecreased.selector, uint256(10), uint256(9))
        );
        assert(vault.balanceOf(address(strategy)) == 10);
        assert(vault.allowance(address(strategy), address(router)) == 1);
        assert(usdc.balanceOf(address(strategy)) == 0);
        assert(reward.balanceOf(address(strategy)) == 1);
    }

    function test_recursiveSwapHitsTransientGuardAndGuardClearsAfterOuterSuccess() public {
        registry.setAdmin(address(router), true);
        reward.mint(address(strategy), 2);
        bytes memory route =
            abi.encodeCall(router.reenterAndCatch, (strategy, reward, usdc, uint256(1), usdc, uint256(3)));
        uint256 received = strategy.swap(reward, usdc, 1, address(router), address(router), route, 3);
        assert(received == 3);
        assert(router.callbackError() == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        reward.mint(address(strategy), 1);
        uint256 retry = strategy.swap(reward, usdc, 1, address(router), address(router), _route(1, 2), 2);
        assert(retry == 2);
    }

    function test_pauseDoesNotGateSwap() public {
        registry.setPaused(address(strategy), true);
        reward.mint(address(strategy), 1);
        uint256 received = strategy.swap(reward, usdc, 1, address(router), address(router), _route(1, 1), 1);
        assert(received == 1);
    }
}
