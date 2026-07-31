// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Stateless batching helper for funding generated Sepolia E2E actors.
/// @dev Staging only. Recipients and amounts are entirely caller supplied.
contract SepoliaBatchSeeder {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_RECIPIENTS = 50;

    error InvalidDistribution();
    error ValueMismatch();
    error EtherTransferFailed(address recipient);

    function distributeEther(address[] calldata recipients, uint256 amountEach) external payable {
        uint256 length = recipients.length;
        if (length == 0 || length > MAX_RECIPIENTS || amountEach == 0) revert InvalidDistribution();
        if (msg.value != length * amountEach) revert ValueMismatch();

        for (uint256 i; i < length; ++i) {
            (bool success,) = payable(recipients[i]).call{value: amountEach}("");
            if (!success) revert EtherTransferFailed(recipients[i]);
        }
    }

    function distributeToken(IERC20 token, address[] calldata recipients, uint256 amountEach) external {
        uint256 length = recipients.length;
        if (address(token) == address(0) || length == 0 || length > MAX_RECIPIENTS || amountEach == 0) {
            revert InvalidDistribution();
        }

        for (uint256 i; i < length; ++i) {
            token.safeTransferFrom(msg.sender, recipients[i], amountEach);
        }
    }
}
