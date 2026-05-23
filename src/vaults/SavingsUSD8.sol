// SPDX-License-Identifier: MIT
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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {USD8} from "../USD8.sol";
import {IStrategy} from "../IStrategy.sol";
import {VestedERC4626} from "./VestedERC4626.sol";

/// @title  SavingsUSD8 (sUSD8) v1
/// @notice ERC4626 savings vault for USD8 with linear profit vesting and
///         multi-strategy deployment. Users deposit USD8, receive sUSD8.
///         The underlying USD8 may be deployed by admin to external
///         strategies (LP positions, lending markets, etc.) to generate
///         yield, which is reported back via {reportProfit} and vests
///         smoothly into the share price.
/// @dev    Two extensions over {VestedERC4626}:
///         1. `_rawAssets()` is overridden to sum idle USD8 + every
///            approved strategy's `totalAssets()`. This is what the
///            vesting overlay subtracts from.
///         2. `_withdraw()` is overridden to pull any shortfall from
///            strategies in array order before the standard ERC4626
///            transfer, matching the pattern used by {Treasury}.
///
///         Strategy management mirrors the {Treasury} contract — same
///         {IStrategy} interface, same array-as-approval semantics, same
///         expectation that strategies support atomic withdrawal.
/// @custom:security-contact rick@usd8.fi
contract SavingsUSD8 is VestedERC4626 {
    using SafeERC20 for IERC20;

    // ─────────────────────────── State ───────────────────────────

    /// @notice Approved USD8 strategies, in admin-determined order.
    ///         Order doubles as the withdrawal fallback queue.
    IStrategy[] public strategies;

    // ─────────────────────────── Errors ──────────────────────────

    error ZeroAddress();
    error StrategyNotApproved(IStrategy strategy);
    error StrategyAlreadyApproved(IStrategy strategy);
    error StrategyHasFunds(IStrategy strategy, uint256 assets);

    // ─────────────────────────── Events ──────────────────────────

    event StrategyAdded(IStrategy indexed strategy);
    event StrategyRemoved(IStrategy indexed strategy);
    event DepositedToStrategy(IStrategy indexed strategy, uint256 amount);
    event WithdrawnFromStrategy(IStrategy indexed strategy, uint256 amount);

    // ─────────────────────────── Constructor ─────────────────────

    /// @param _usd8                 The USD8 token (underlying asset).
    /// @param _admin                Initial owner.
    /// @param _profitMaxUnlockTime  Vesting duration in seconds.
    constructor(USD8 _usd8, address _admin, uint64 _profitMaxUnlockTime)
        ERC20("Savings USD8", "sUSD8")
        ERC4626(IERC20(address(_usd8)))
        Ownable(_admin)
        VestedERC4626(_profitMaxUnlockTime)
    {}

    // ═══════════════════════════ Asset accounting (override) ═══════════════════════════

    /// @dev Idle USD8 in this contract plus every approved strategy's
    ///      reported `totalAssets`. The vesting overlay (inherited from
    ///      {VestedERC4626}) then subtracts the unvested-profit portion.
    function _rawAssets() internal view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            total += strategies[i].totalAssets();
        }
        return total;
    }

    // ═══════════════════════════ Withdrawal (override) ═══════════════════════════

    /// @dev Pull `assets` of underlying from strategies into idle before
    ///      the standard ERC4626 burn-and-transfer. Strategies are walked
    ///      in `strategies` array order; idle is consumed first.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _ensureIdle(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ═══════════════════════════ Strategy management (admin) ═══════════════════════════

    /// @notice Approve one or more new strategies. Admin only. Reverts on
    ///         zero address or duplicates (including within the input
    ///         array). Strategy approval is a trusted process — admin is
    ///         expected to verify each contract implements {IStrategy}
    ///         correctly off-chain.
    function addStrategies(IStrategy[] calldata newStrategies) external onlyOwner {
        for (uint256 i = 0; i < newStrategies.length; i++) {
            IStrategy s = newStrategies[i];
            if (address(s) == address(0)) revert ZeroAddress();
            (, bool exists) = _findStrategy(s);
            if (exists) revert StrategyAlreadyApproved(s);
            strategies.push(s);
            emit StrategyAdded(s);
        }
    }

    /// @notice Remove an approved strategy. Requires the strategy to have
    ///         zero `totalAssets()`. Admin must drain it via
    ///         {withdrawFromStrategy} first.
    function removeStrategy(IStrategy s) external onlyOwner {
        (uint256 idx, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);
        uint256 assets = s.totalAssets();
        if (assets != 0) revert StrategyHasFunds(s, assets);

        uint256 n = strategies.length;
        strategies[idx] = strategies[n - 1];
        strategies.pop();
        emit StrategyRemoved(s);
    }

    /// @notice Push `amount` of idle USD8 to an approved strategy. Admin
    ///         only.
    function depositToStrategy(IStrategy s, uint256 amount) external onlyOwner {
        (, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);
        if (amount == 0) revert ZeroAmount();
        IERC20(asset()).safeTransfer(address(s), amount);
        s.deploy(amount);
        emit DepositedToStrategy(s, amount);
    }

    /// @notice Pull `amount` USD8 from an approved strategy back to idle.
    ///         Admin only.
    function withdrawFromStrategy(IStrategy s, uint256 amount) external onlyOwner {
        (, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);
        if (amount == 0) revert ZeroAmount();
        s.withdraw(amount);
        emit WithdrawnFromStrategy(s, amount);
    }

    // ═══════════════════════════ Views ═══════════════════════════

    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }

    // ═══════════════════════════ Internal helpers ═══════════════════════════

    /// @dev Top up idle balance to at least `amount` by pulling from
    ///      strategies in array order. Per the {IStrategy} contract,
    ///      individual strategy withdrawals are atomic — `withdraw`
    ///      either delivers the exact requested amount or reverts.
    function _ensureIdle(uint256 amount) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= amount) return;
        uint256 needed = amount - idle;
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            if (needed == 0) break;
            IStrategy s = strategies[i];
            uint256 available = s.totalAssets();
            if (available == 0) continue;
            uint256 toPull = needed < available ? needed : available;
            s.withdraw(toPull);
            needed -= toPull;
        }
    }

    /// @dev Linear scan of `strategies` for `s`. O(n), small N expected.
    function _findStrategy(IStrategy s) internal view returns (uint256 idx, bool found) {
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            if (strategies[i] == s) {
                return (i, true);
            }
        }
        return (0, false);
    }
}
