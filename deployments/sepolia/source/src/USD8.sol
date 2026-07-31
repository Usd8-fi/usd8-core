// SPDX-License-Identifier: BUSL-1.1

//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\: \/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "./Registry.sol";
import {SharedBase} from "./SharedBase.sol";

/// @title USD8
/// @notice Upgradeable ERC-20 stablecoin with permit support.
/// @dev Only the Treasury registered in Registry may mint or burn. The timelock
///      controls upgrades while Registry beta mode is active.
/// @custom:security-contact rick@usd8.fi
contract USD8 is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, UUPSUpgradeable, SharedBase {
    // ─────────────────────────── Errors / events ───────────────────────────

    /// @notice Thrown when a non-Treasury account tries to mint or burn.
    error UnauthorizedTreasury(address caller);

    // ─────────────────────────── Constructor / initializer ───────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. Callable exactly once.
    /// @param _registry Shared access, pause, and canonical-topology registry.
    function initialize(Registry _registry) external initializer {
        __ERC20_init("USD8", "USD8");
        __ERC20Permit_init("USD8");
        _setRegistry(_registry);
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Only the timelock can authorize, and only while Registry beta mode is active.
    function _authorizeUpgrade(address) internal view override {
        _requireTimelock();
        _requireBetaMode();
    }

    // ─────────────────────────── Mint / burn (treasury) ───────────────────────────

    /// @notice Mint `amount` USD8 to `to`. Callable only by {treasury}.
    function mint(address to, uint256 amount) external onlyTreasury {
        _mint(to, amount);
    }

    /// @notice Burn `amount` USD8 from `from` without allowance. Treasury only.
    function burn(address from, uint256 amount) external onlyTreasury {
        _burn(from, amount);
    }

    // ─────────────────────────── Internal / modifiers ───────────────────────────

    /// @notice Active Treasury resolved from the shared Registry.
    function treasury() public view returns (address) {
        return registry().treasury();
    }

    /// @dev Uses `msg.sender` directly and does not support ERC-2771 forwarding.
    ///      Gasless transfers should use permit followed by `transferFrom`.
    modifier onlyTreasury() {
        if (msg.sender != treasury()) revert UnauthorizedTreasury(msg.sender);
        _;
    }

    /// @dev USD8 accounts for no tokens held at its own address, so the full
    ///      balance of any token is sweepable.
    function _sweepable(address token) internal view override returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
