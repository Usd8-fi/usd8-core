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
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title  VestedERC4626 (abstract)
/// @notice ERC4626 base with built-in linear profit vesting to defeat
///         just-in-time (JIT) liquidity attacks on profit distributions.
///         Anyone can push profit in via {reportProfit}; the share price
///         absorbs that profit smoothly over `profitMaxUnlockTime` seconds
///         rather than as a step function.
/// @dev    Synthetic-totalAssets ("Pattern B") implementation: no shares
///         are minted or burned for vesting. `totalAssets()` is overridden
///         to return `_rawAssets() − _unvestedProfit()`. The unvested
///         portion shrinks linearly with `block.timestamp`, so the share
///         price advances continuously every block — there is no discrete
///         unlock event or per-block burn to trigger.
///
///         JIT defense: a flash-loan-deposit just before a profit report
///         sees their shares appreciate over the vesting window, not
///         instantly. Capturing meaningful value requires holding capital
///         for the full duration, which destroys the flash-loan economics.
///
///         New profit during an active vest folds in via weighted average
///         (Yearn V3 style): mid-vest reports neither truncate the existing
///         schedule nor create a step. Tiny `reportProfit` calls extend the
///         end-time negligibly, making schedule-griefing economically
///         pointless even with `reportProfit` exposed permissionlessly.
///
///         Concrete subclasses can override {_rawAssets} to include
///         externally-held positions (strategy balances, etc.) in the
///         vault's accounting.
/// @custom:security-contact rick@usd8.fi
abstract contract VestedERC4626 is ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;

    // ─────────────────────────── State ───────────────────────────

    /// @notice Amount of profit still vesting (in asset base units).
    ///         When 0, no active schedule.
    uint128 public pendingProfit;

    /// @notice Start of the current vesting schedule.
    uint64 public profitStartTime;

    /// @notice End of the current vesting schedule.
    uint64 public profitEndTime;

    /// @notice Maximum duration (seconds) over which freshly-reported
    ///         profit is vested. Admin-configurable. Recommended >= 1 week
    ///         to defeat JIT attacks economically.
    uint64 public profitMaxUnlockTime;

    // ─────────────────────────── Errors ──────────────────────────

    error ZeroAmount();
    error InvalidProfitMaxUnlockTime();
    error ProfitTooLarge();
    error RenounceOwnershipDisabled();

    // ─────────────────────────── Events ──────────────────────────

    event ProfitReported(address indexed reporter, uint256 amount, uint256 newPending, uint64 newEndTime);

    event ProfitMaxUnlockTimeSet(uint64 oldTime, uint64 newTime);

    // ─────────────────────────── Constructor ─────────────────────

    /// @param _profitMaxUnlockTime Initial vesting duration in seconds.
    constructor(uint64 _profitMaxUnlockTime) {
        if (_profitMaxUnlockTime == 0) revert InvalidProfitMaxUnlockTime();
        profitMaxUnlockTime = _profitMaxUnlockTime;
    }

    // ═══════════════════════════ Profit reporting ═══════════════════════════

    /// @notice Push `amount` of the underlying asset into the vault as
    ///         profit. Pulls atomically via `transferFrom` (caller must
    ///         approve). The amount vests linearly over the weighted-average
    ///         duration combining any remaining unvested portion with a
    ///         fresh `profitMaxUnlockTime` window.
    /// @dev    Permissionless — anyone may donate. The weighted-average
    ///         schedule reset means tiny calls don't significantly extend
    ///         the end-time, so there's no griefing vector.
    /// @param  amount Amount of the underlying asset (in its native
    ///                decimals) to report.
    function reportProfit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert ProfitTooLarge();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        uint256 unvested = _unvestedProfit();
        uint256 timeRemaining = block.timestamp < profitEndTime ? profitEndTime - block.timestamp : 0;

        uint256 newPending = unvested + amount;
        if (newPending > type(uint128).max) revert ProfitTooLarge();

        // Weighted-average vesting period: blend any unvested remainder
        // (at its current time-to-go) with the new profit (at the full
        // max duration). Prevents tiny dust reports from significantly
        // extending the schedule's end time.
        uint256 newDuration = (unvested * timeRemaining + amount * uint256(profitMaxUnlockTime)) / newPending;
        uint64 newEndTime = uint64(block.timestamp + newDuration);

        pendingProfit = uint128(newPending);
        profitStartTime = uint64(block.timestamp);
        profitEndTime = newEndTime;

        emit ProfitReported(msg.sender, amount, newPending, newEndTime);
    }

    // ═══════════════════════════ Vesting math ═══════════════════════════

    /// @notice Current unvested profit. Decreases linearly to zero as
    ///         `block.timestamp` advances toward `profitEndTime`.
    function unvestedProfit() external view returns (uint256) {
        return _unvestedProfit();
    }

    function _unvestedProfit() internal view returns (uint256) {
        if (pendingProfit == 0) return 0;
        if (block.timestamp >= profitEndTime) return 0;
        uint256 elapsed = block.timestamp - profitStartTime;
        uint256 totalDuration = profitEndTime - profitStartTime;
        uint256 vested = (uint256(pendingProfit) * elapsed) / totalDuration;
        return uint256(pendingProfit) - vested;
    }

    /// @notice Total assets recognized by the vault for ERC4626 math.
    ///         `_rawAssets()` minus the still-unvested portion of any
    ///         reported profit.
    function totalAssets() public view virtual override returns (uint256) {
        return _rawAssets() - _unvestedProfit();
    }

    /// @dev Effective on-chain asset balance the vault controls. Default
    ///      implementation returns this contract's balance of the
    ///      underlying. Subclasses with externally-deployed positions
    ///      (strategies, etc.) override this to sum them in.
    function _rawAssets() internal view virtual returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    // ═══════════════════════════ Admin ═══════════════════════════

    /// @notice Update `profitMaxUnlockTime`. Admin only. Affects only
    ///         future {reportProfit} calls — any active vest continues on
    ///         its original schedule.
    function setProfitMaxUnlockTime(uint64 newTime) external onlyOwner {
        if (newTime == 0) revert InvalidProfitMaxUnlockTime();
        emit ProfitMaxUnlockTimeSet(profitMaxUnlockTime, newTime);
        profitMaxUnlockTime = newTime;
    }

    /// @notice Disabled. Reverts with {RenounceOwnershipDisabled}.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }
}
