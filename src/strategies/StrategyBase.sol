// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Registry} from "../Registry.sol";
import {SharedBase} from "../SharedBase.sol";

/// @title StrategyBase
/// @notice Shared authorization and aggregator-swap boundary for Treasury
///         strategies. Each strategy defines one deployment token. Swaps may
///         convert USDC into that token for deployment, or any non-position
///         token back into USDC for Treasury.
/// @dev Swap routes are selected off-chain at execution time, constrained to a
///      timelock-approved `(target, spender)` pair in Registry. Only an admin or
///      the timelock may execute. Derived strategies identify protected principal
///      so reward swaps cannot consume it.
abstract contract StrategyBase is SharedBase, ReentrancyGuardTransient {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @notice Mainnet USDC, the sole Treasury accounting asset.
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    /// @notice Treasury that owns this strategy and receives all USDC swap output.
    address public immutable treasury;

    /// @notice Token this strategy deploys into its external yield venue.
    IERC20 public immutable strategyToken;

    error UnauthorizedTreasury(address caller);
    error ZeroAmount();
    error SwapRouteNotApproved(address target, address spender);
    error ProtectedSwapAsset(address token);
    error UnsupportedSwapPair(address tokenIn, address tokenOut);
    error InsufficientSwapOutput(uint256 minimum, uint256 received);
    error PrincipalDecreased(uint256 beforeBalance, uint256 afterBalance);

    event TokenSwapped(
        address indexed tokenIn, address indexed tokenOut, address indexed target, uint256 amountIn, uint256 amountOut
    );

    constructor(address treasury_, Registry registry_, IERC20 strategyToken_) {
        if (treasury_ == address(0) || address(strategyToken_) == address(0)) revert ZeroAddress();
        treasury = treasury_;
        strategyToken = strategyToken_;
        _setRegistry(registry_);
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert UnauthorizedTreasury(msg.sender);
        _;
    }

    /// @notice Execute an approved aggregator route. Allowed directions are
    ///         USDC -> strategyToken (output remains here for deployment), or
    ///         any non-position token -> USDC (output is sent to Treasury).
    /// @param tokenIn    Input token already held by this strategy.
    /// @param tokenOut   USDC or this strategy's declared strategyToken.
    /// @param amountIn   Maximum input amount the spender may pull.
    /// @param target     Aggregator contract called with `route`.
    /// @param spender    Contract receiving the exact temporary token approval.
    /// @param route      Fresh route calldata produced off-chain.
    /// @param minAmountOut Minimum acceptable output-token balance increase.
    function swap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        address target,
        address spender,
        bytes calldata route,
        uint256 minAmountOut
    ) external onlyAdminOrTimelock returns (uint256 amountOut) {
        return _swap(tokenIn, tokenOut, amountIn, target, spender, route, minAmountOut);
    }

    /// @dev Shared execution primitive for derived deploy/withdraw workflows.
    ///      Derived external entrypoints remain responsible for their own caller
    ///      authorization; this helper enforces route, pair and asset safety.
    function _swap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        address target,
        address spender,
        bytes calldata route,
        uint256 minAmountOut
    ) internal nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0 || minAmountOut == 0) revert ZeroAmount();
        if (!registry().approvedSwapRoute(target, spender)) revert SwapRouteNotApproved(target, spender);

        bool returnsToTreasury = address(tokenOut) == address(USDC);
        bool deploysStrategyToken = address(tokenIn) == address(USDC) && address(tokenOut) == address(strategyToken);
        if (address(tokenIn) == address(tokenOut) || (!returnsToTreasury && !deploysStrategyToken)) {
            revert UnsupportedSwapPair(address(tokenIn), address(tokenOut));
        }
        if (_isPositionToken(address(tokenIn))) revert ProtectedSwapAsset(address(tokenIn));
        if (_isProtectedCallTarget(target)) revert ProtectedSwapAsset(target);
        if (_isProtectedCallTarget(spender)) revert ProtectedSwapAsset(spender);

        uint256 principalBefore = _principalBalance();
        uint256 outputBefore = tokenOut.balanceOf(address(this));

        tokenIn.forceApprove(spender, amountIn);
        target.functionCall(route);
        tokenIn.forceApprove(spender, 0);

        uint256 principalAfter = _principalBalance();
        if (principalAfter < principalBefore) revert PrincipalDecreased(principalBefore, principalAfter);

        amountOut = tokenOut.balanceOf(address(this)) - outputBefore;
        if (amountOut < minAmountOut) revert InsufficientSwapOutput(minAmountOut, amountOut);
        if (returnsToTreasury) USDC.safeTransfer(treasury, amountOut);

        emit TokenSwapped(address(tokenIn), address(tokenOut), target, amountIn, amountOut);
    }

    /// @dev Call targets and approval spenders must never be a token contract
    ///      that directly holds or controls strategy principal.
    function _isProtectedCallTarget(address target) internal view virtual returns (bool) {
        return target == address(USDC) || target == address(strategyToken) || _isPositionToken(target);
    }

    /// @dev Position tokens cannot be sold through the operational swap entrypoint.
    function _isPositionToken(address token) internal view virtual returns (bool) {
        token;
        return false;
    }

    /// @dev Principal-token balance used to prove the swap did not consume the
    ///      strategy position. Derived strategies define their position token.
    function _principalBalance() internal view virtual returns (uint256);
}
