// SPDX-License-Identifier: BUSL-1.1

//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\: \/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

/// @title IStrategy
/// @notice Interface for Treasury-managed USDC strategies.
/// @dev Treasury transfers USDC before {deploy}. {withdraw} must return funds in
///      the same transaction; Treasury measures the actual balance increase and may
///      continue after a short return or withdrawal revert. A {totalAssets} revert
///      propagates. Values use six-decimal USDC base units.
/// @custom:security-contact rick@usd8.fi
interface IStrategy {
    /// @notice The underlying asset this strategy accepts and reports in.
    /// @dev    Treasury strategies must report USDC. The trusted timelock verifies
    ///         this before addStrategy; Treasury does not enforce it on-chain.
    function underlying() external view returns (address);

    function deploy(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function totalAssets() external view returns (uint256);
}
