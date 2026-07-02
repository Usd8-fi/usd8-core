// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @notice Minimal subset of the Aave v3 Pool interface used here.
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @title  AaveV3UsdcStrategy
/// @notice {IStrategy} adapter that deploys USDC into the Aave v3 USDC
///         market on Ethereum mainnet, earning the aUSDC supply rate.
/// @dev    Deposits via {IAaveV3Pool-supply}, exits via {IAaveV3Pool-withdraw}.
///         The aUSDC balance held by this contract is the source of truth
///         for {totalAssets} — aUSDC is rebasing, so the balance accrues
///         interest passively without any harvest call.
///
///         Authority model:
///         - {deploy} and {withdraw} are callable only by {treasury}.
///         - No admin functions, no parameters to tune, no upgrades. If
///           Aave breaks or the rate becomes uncompetitive, Treasury
///           force-removes this strategy via {Treasury-removeStrategy}
///           and deploys a replacement contract.
///
///         Atomic withdrawal: Aave's withdraw either delivers the
///         requested amount exactly or reverts. A return value less
///         than amount is treated as a strategy bug and reverts
///         explicitly via {WithdrawShort}.
///
///         Liquidity caveat: Aave's withdraw can revert under high
///         utilization (borrowed > supplied) — that's the structural
///         risk of any lending-market strategy. Treasury's redeem-
///         fallback walk handles this by trying the next strategy in
///         {Treasury-strategies}; admin should keep idle USDC and/or
///         a more-liquid secondary strategy at lower indices for
///         stress-event coverage.
/// @custom:security-contact rick@usd8.fi
contract AaveV3UsdcStrategy is IStrategy {
    using SafeERC20 for IERC20;

    /// @notice Mainnet USDC.
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    /// @notice Mainnet Aave v3 Pool (proxy address).
    IAaveV3Pool public constant AAVE_POOL = IAaveV3Pool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    /// @notice Mainnet Aave v3 aEthUSDC (interest-bearing USDC). Balance
    ///         is rebasing and equals deployed principal + accrued yield.
    IERC20 public constant A_USDC = IERC20(0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c);

    /// @notice The Treasury allowed to call {deploy} and {withdraw}.
    address public immutable treasury;

    /// @notice Thrown when a non-Treasury account calls a gated function.
    error UnauthorizedTreasury(address caller);

    /// @notice Thrown when a zero address is supplied where one is not allowed.
    error ZeroAddress();

    /// @notice Thrown when Aave returns fewer USDC than requested.
    error WithdrawShort(uint256 requested, uint256 received);

    /// @notice Emitted when Treasury deploys USDC into Aave.
    event Deployed(uint256 amount);

    /// @notice Emitted when Treasury pulls USDC from Aave back to itself.
    event Withdrawn(uint256 amount);

    /// @param _treasury The Treasury contract that owns this strategy.
    constructor(address _treasury) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        // One-time unlimited approval to the trusted Aave Pool proxy.
        // Saves gas on every {deploy}; Pool address is constant.
        USDC.forceApprove(address(AAVE_POOL), type(uint256).max);
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert UnauthorizedTreasury(msg.sender);
        _;
    }

    /// @inheritdoc IStrategy
    function underlying() external pure returns (address) {
        return address(USDC);
    }

    /// @inheritdoc IStrategy
    /// @dev Caller (Treasury) is expected to have pushed amount USDC
    ///      to this contract immediately before this call.
    function deploy(uint256 amount) external onlyTreasury {
        AAVE_POOL.supply(address(USDC), amount, address(this), 0);
        emit Deployed(amount);
    }

    /// @inheritdoc IStrategy
    /// @dev Routes Aave's USDC payout directly to {treasury}, avoiding
    ///      a temporary balance on this contract.
    function withdraw(uint256 amount) external onlyTreasury {
        uint256 received = AAVE_POOL.withdraw(address(USDC), amount, treasury);
        if (received != amount) revert WithdrawShort(amount, received);
        emit Withdrawn(received);
    }

    /// @inheritdoc IStrategy
    function totalAssets() external view returns (uint256) {
        return A_USDC.balanceOf(address(this));
    }
}
