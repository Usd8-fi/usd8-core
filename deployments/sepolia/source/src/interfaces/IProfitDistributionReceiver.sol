// SPDX-License-Identifier: BUSL-1.1

//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\: \/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

/// @title IProfitDistributionReceiver
/// @notice Hook for profit receivers that pull and account for approved USD8.
/// @dev Implementations pull `amount` from the caller and apply their own accounting.
/// @custom:security-contact rick@usd8.fi
interface IProfitDistributionReceiver {
    function receiveProfitDistribution(uint256 amount) external;
}
