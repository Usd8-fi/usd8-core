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
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/// @notice Test strategy that can leak extra USDC during the next withdrawal.
contract LossyWithdrawStrategy is IStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    uint256 public lossOnNextWithdraw;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }

    function setLossOnNextWithdraw(uint256 amount) external {
        lossOnNextWithdraw = amount;
    }

    function deploy(uint256) external override {}

    function withdraw(uint256 amount) external override {
        usdc.safeTransfer(msg.sender, amount);

        uint256 loss = lossOnNextWithdraw;
        if (loss != 0) {
            lossOnNextWithdraw = 0;
            usdc.safeTransfer(address(0xD), loss);
        }
    }

    function totalAssets() external view override returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function underlying() external view override returns (address) {
        return address(usdc);
    }
}
