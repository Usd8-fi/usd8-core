// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
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

/// @title  USD8
/// @notice UUPS-upgradeable ERC20 stablecoin. The Registry's active Treasury can mint
///         and burn USD8; transfers and approvals follow the standard ERC20
///         semantics from OpenZeppelin v5.
/// @dev    USD8 keeps authority minimal:
///         - timelock — sets the active Treasury on the shared {Registry}.
///         - treasury — the only account allowed to mint and burn, resolved from Registry.
///
///         Security choices:
///         - The implementation contract calls _disableInitializers in its
///           constructor, so it cannot be initialized standalone and only the
///           proxy holds live state.
///         - Treasury authority has one topology source: {Registry.treasury}.
///         - Zero-address mint/burn targets are rejected by OpenZeppelin's
///           _mint / _burn (ERC20InvalidReceiver /
///           ERC20InvalidSender).
///         - Mint and burn resolve Treasury through Registry using a view call
///           before applying standard ERC-20 state changes.
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
    /// @dev Only the timelock can authorize. Treasury cannot upgrade unless it
    ///      is also the timelock.
    function _authorizeUpgrade(address) internal view override onlyTimelock {}

    // ─────────────────────────── Mint / burn (treasury) ───────────────────────────

    /// @notice Mint amount USD8 to to. Callable only by {treasury}.
    function mint(address to, uint256 amount) external onlyTreasury {
        _mint(to, amount);
    }

    /// @notice Burn amount USD8 from from. Callable only by {treasury}.
    function burn(address from, uint256 amount) external onlyTreasury {
        _burn(from, amount);
    }

    // ─────────────────────────── Internal / modifiers ───────────────────────────

    /// @notice Active Treasury resolved from the shared Registry.
    function treasury() public view returns (address) {
        return registry().treasury();
    }

    /// @dev USD8 intentionally does NOT support ERC-2771 meta-transactions.
    ///      The treasury check uses msg.sender directly rather than
    ///      _msgSender(). Do not add ERC2771ContextUpgradeable to the
    ///      inheritance chain without revisiting this call site — a
    ///      trusted forwarder would otherwise allow msg.sender to be a
    ///      relayer address that doesn't match treasury.
    ///      Gasless flows are intended to go through the standard
    ///      permit + transferFrom relayer pattern instead.
    modifier onlyTreasury() {
        if (msg.sender != treasury()) revert UnauthorizedTreasury(msg.sender);
        _;
    }

    /// @dev USD8 custodies no accounted tokens — it is just the ERC-20. Any
    ///      balance at this address (foreign tokens, or USD8 mis-sent to the
    ///      token contract) is stray, so the full balance is sweepable via
    ///      {SharedBase-sweepToken}.
    function _sweepable(address token) internal view override returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
