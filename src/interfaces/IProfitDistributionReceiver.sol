// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

/// @title  IProfitDistributionReceiver
/// @notice Interface for USD8 profit recipients that account incoming
///         profit through an explicit hook instead of a raw token transfer.
/// @dev    Implementations are expected to pull amount from msg.sender
///         using transferFrom and apply any required vesting or
///         linearization before the profit affects user accounting.
/// @custom:security-contact rick@usd8.fi
interface IProfitDistributionReceiver {
    function receiveProfitDistribution(uint256 amount) external;
}
