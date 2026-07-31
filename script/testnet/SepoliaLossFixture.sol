// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Agent-administered test token for a public Sepolia loss rehearsal.
/// @dev Staging only. It has no production or mainnet use.
contract SepoliaLossToken is ERC20 {
    address public immutable admin;

    error Unauthorized();
    error ZeroAddress();

    constructor(address admin_) ERC20("Sepolia Loss Fixture", "mLOSS") {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != admin) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }
}

/// @notice Slashable ERC-4626 used to prove TEE incident opening after a real
///         on-chain share-to-immediate-underlying conversion loss on Sepolia.
/// @dev Staging only. The admin-controlled loss hook is intentionally unsafe.
contract SepoliaLossVault is ERC4626 {
    using SafeERC20 for IERC20;

    address public immutable admin;

    error Unauthorized();
    error ZeroAddress();

    constructor(IERC20 asset_, address admin_) ERC20("Sepolia Slashable Loss Vault", "msLOSS") ERC4626(asset_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
    }

    function realizeLoss(address recipient, uint256 assets) external {
        if (msg.sender != admin) revert Unauthorized();
        if (recipient == address(0)) revert ZeroAddress();
        IERC20(asset()).safeTransfer(recipient, assets);
    }
}
