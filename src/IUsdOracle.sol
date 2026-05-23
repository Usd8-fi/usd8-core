// SPDX-License-Identifier: MIT
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

/// @title  IUsdOracle
/// @notice Single-token USD pricing oracle. Each registered token in
///         {CoverPool} points at one implementation of this interface;
///         the oracle hides token-decimals handling from the caller.
/// @dev    Implementations MUST return the USD value of `amount` token
///         base units scaled by 1e18 (so 1.00 USD == 1e18). The
///         contract performs no staleness or sanity checks — admin is
///         responsible for selecting trustworthy oracle implementations.
/// @custom:security-contact rick@usd8.fi
interface IUsdOracle {
    /// @notice USD value of `amount` token base units, 1e18-scaled.
    function getUsdValue(uint256 amount) external view returns (uint256);
}
