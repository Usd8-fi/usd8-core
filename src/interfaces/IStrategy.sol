// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

/// @title  IStrategy
/// @notice Minimal interface a USD8 yield strategy must implement.
/// @dev    Strategies must support **atomic** withdrawal — there is no
///         buffer in the Treasury, so every redeem may trigger a
///         withdraw in the same transaction. Strategies that have
///         unbonding periods, withdrawal queues, or non-atomic exit
///         (e.g., epoch-based vaults, locked LP positions) are not safe
///         to use with this Treasury without an explicit buffer layer.
///         - deploy(amount): receives a push transfer of USDC
///           immediately before being called; may assume the USDC is
///           already in its balance.
///         - withdraw(amount): must transfer exactly amount USDC
///           back to the caller (the Treasury). MUST revert if the
///           full amount cannot be delivered in the same transaction.
///           Partial withdrawals are NOT permitted — the Treasury's
///           accounting (in {Treasury-_ensureIdleUsdc}) assumes each
///           successful return delivered exactly the requested amount.
///           A strategy that silently transfers less would break the
///           redeem and harvest paths.
///         - totalAssets(): returns the strategy's current USDC-
///           equivalent value (deployed principal plus accrued yield,
///           minus losses), in USDC base units (6 decimals).
/// @custom:security-contact rick@usd8.fi
interface IStrategy {
    /// @notice The underlying asset this strategy accepts and reports in.
    /// @dev    Treasury strategies must report USDC. Verified by the consuming
    ///         contract on addStrategy to prevent cross-wiring.
    function underlying() external view returns (address);

    function deploy(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function totalAssets() external view returns (uint256);
}
