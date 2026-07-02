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
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/// @notice Minimal test strategy. Records call counts and reports its
///         current USDC balance as totalAssets. A test helper can mint
///         extra USDC to this address to simulate yield.
contract MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    uint256 public deployedAmount;
    uint256 public deployCallCount;
    uint256 public withdrawCallCount;
    bool public withdrawReverts; // simulate a stuck strategy (paused/compromised)

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function setWithdrawReverts(bool v) external {
        withdrawReverts = v;
    }

    function deploy(uint256 amount) external override {
        deployedAmount += amount;
        deployCallCount += 1;
    }

    function withdraw(uint256 amount) external override {
        withdrawCallCount += 1;
        require(!withdrawReverts, "stuck");
        usdc.safeTransfer(msg.sender, amount);
    }

    function totalAssets() external view override returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function underlying() external view override returns (address) {
        return address(usdc);
    }
}
