// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

/// @dev Minimal 4626-shaped vault with a settable share rate, for the
///      ERC4626RateAdapter / depeg-trigger tests.
contract MockERC4626 {
    address public immutable asset;
    uint256 public rate; // assets per 1e18 shares

    constructor(address _asset, uint256 _rate) {
        asset = _asset;
        rate = _rate;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }
}
