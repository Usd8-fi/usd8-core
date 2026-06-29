// SPDX-License-Identifier: MIT
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

/// @title  USD8
/// @notice UUPS-upgradeable ERC20 stablecoin. The configured Treasury can mint
///         and burn USD8; transfers and approvals follow the standard ERC20
///         semantics from OpenZeppelin v5.
/// @dev    USD8 keeps authority minimal:
///         - `timelock` — single-key authority that sets the Treasury address
///           and authorizes UUPS upgrades. Single-step transfer; cannot be
///           set to address(0).
///         - `treasury` — the only account allowed to mint and burn.
///
///         Security choices:
///         - The implementation contract calls `_disableInitializers` in its
///           constructor, so it cannot be initialized standalone and only the
///           proxy holds live state.
///         - Treasury is stored independently of timelock, so timelock handover
///           does not disturb synchronous mint/redeem flows.
///         - Zero-address mint/burn targets are rejected by OpenZeppelin's
///           `_mint` / `_burn` (`ERC20InvalidReceiver` /
///           `ERC20InvalidSender`).
///         - No external calls are made by mint or burn, so no reentrancy
///           surface is introduced beyond standard ERC20 behavior.
/// @custom:security-contact rick@usd8.fi
contract USD8 is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, UUPSUpgradeable {
    /// @notice Single-key timelock. Sets {treasury} and authorizes UUPS upgrades.
    address public timelock;

    /// @notice Account allowed to mint and burn USD8. Intended holder: Treasury.
    address public treasury;

    /// @notice Thrown when a zero address is supplied where one is not allowed.
    error ZeroAddress();

    /// @notice Thrown when a non-timelock account calls an timelock function.
    error UnauthorizedTimelock(address caller);

    /// @notice Thrown when a non-Treasury account tries to mint or burn.
    error UnauthorizedTreasury(address caller);

    /// @notice Emitted when timelock is transferred.
    event TimelockChanged(address indexed oldTimelock, address indexed newTimelock);

    /// @notice Emitted when the timelock changes the Treasury address.
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. Callable exactly once.
    /// @param  initialTimelock    Initial timelock / upgrade authority.
    /// @param  initialTreasury Initial Treasury address allowed to mint/burn.
    function initialize(address initialTimelock, address initialTreasury) external initializer {
        if (initialTimelock == address(0) || initialTreasury == address(0)) revert ZeroAddress();
        __ERC20_init("USD8", "USD8");
        __ERC20Permit_init("USD8");

        _setTimelock(initialTimelock);
        _setTreasury(initialTreasury);
    }

    // ═══════════════════════════ Timelock fns ═══════════════════════════

    /// @notice Transfer timelock. Single-step; timelock cannot be zero.
    function setTimelock(address newTimelock) external onlyTimelock {
        if (newTimelock == address(0)) revert ZeroAddress();
        _setTimelock(newTimelock);
    }

    /// @notice Set the account allowed to mint and burn USD8.
    function setTreasury(address newTreasury) external onlyTimelock {
        if (newTreasury == address(0)) revert ZeroAddress();
        _setTreasury(newTreasury);
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Only {timelock} can authorize. Treasury cannot upgrade unless it
    ///      is also the timelock.
    function _authorizeUpgrade(address) internal view override onlyTimelock {}

    // ═══════════════════════════ Treasury actions mint/burn ═══════════════════════════

    /// @notice Mint `amount` USD8 to `to`. Callable only by {treasury}.
    function mint(address to, uint256 amount) external onlyTreasury {
        _mint(to, amount);
    }

    /// @notice Burn `amount` USD8 from `from`. Callable only by {treasury}.
    function burn(address from, uint256 amount) external onlyTreasury {
        _burn(from, amount);
    }

    // ═══════════════════════════ Internal helpers & modifiers ═══════════════════════════

    /// @dev USD8 intentionally does NOT support ERC-2771 meta-transactions.
    ///      Both role checks use `msg.sender` directly rather than
    ///      `_msgSender()`. Do not add `ERC2771ContextUpgradeable` to the
    ///      inheritance chain without revisiting these call sites — a
    ///      trusted forwarder would otherwise allow `msg.sender` to be a
    ///      relayer address that doesn't match `timelock` or `treasury`.
    ///      Gasless flows are intended to go through the standard
    ///      `permit` + `transferFrom` relayer pattern instead.
    modifier onlyTimelock() {
        if (msg.sender != timelock) revert UnauthorizedTimelock(msg.sender);
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert UnauthorizedTreasury(msg.sender);
        _;
    }

    function _setTimelock(address newTimelock) internal {
        emit TimelockChanged(timelock, newTimelock);
        timelock = newTimelock;
    }

    function _setTreasury(address newTreasury) internal {
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }
}
