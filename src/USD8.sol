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
import {RegistryManaged} from "./RegistryManaged.sol";

/// @notice Minimal reciprocal-binding view required of the final Treasury.
///         Return types are addresses so this interface stays independent of
///         Treasury.sol while remaining ABI-compatible with its typed getters.
interface ITreasuryBinding {
    function usd8() external view returns (address);
    function registry() external view returns (address);
    function treasuryProxyMarker() external view returns (bytes32);
}

/// @title  USD8
/// @notice UUPS-upgradeable ERC20 stablecoin. The configured Treasury can mint
///         and burn USD8; transfers and approvals follow the standard ERC20
///         semantics from OpenZeppelin v5.
/// @dev    USD8 keeps authority minimal:
///         - timelock — the shared {Registry}'s root role; sets the Treasury
///           address and authorizes UUPS upgrades (via {RegistryManaged-onlyTimelock}).
///         - treasury — the only account allowed to mint and burn (USD8-local,
///           stored here, not in {Registry}).
///
///         Security choices:
///         - The implementation contract calls _disableInitializers in its
///           constructor, so it cannot be initialized standalone and only the
///           proxy holds live state.
///         - Treasury is stored independently of the timelock, so timelock
///           handover does not disturb synchronous mint/redeem flows.
///         - Zero-address mint/burn targets are rejected by OpenZeppelin's
///           _mint / _burn (ERC20InvalidReceiver /
///           ERC20InvalidSender).
///         - No external calls are made by mint or burn, so no reentrancy
///           surface is introduced beyond standard ERC20 behavior.
/// @custom:security-contact rick@usd8.fi
contract USD8 is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, UUPSUpgradeable, RegistryManaged {
    // ─────────────────────────── State ───────────────────────────

    /// @dev Must match Treasury's marker, whose getter is protected by UUPS
    ///      {onlyProxy}. Constants consume no proxy storage.
    bytes32 private constant EXPECTED_TREASURY_PROXY_MARKER = keccak256("usd8.treasury.uups");

    /// @notice Account allowed to mint and burn USD8. Intended holder: Treasury.
    address public treasury;

    /// @notice One-way issuance latch. Set on the first nonzero mint/burn and
    ///         never cleared, so the Treasury cannot be rotated after USD8 has
    ///         ever gone live — even if all supply is later redeemed to zero.
    bool public treasuryLocked;

    // ─────────────────────────── Errors / events ───────────────────────────

    /// @notice Thrown when a non-Treasury account tries to mint or burn.
    error UnauthorizedTreasury(address caller);

    /// @notice Thrown when {setTreasury} is called after USD8 has ever been
    ///         issued (M-06). The Treasury address stays fixed even if supply
    ///         later returns to zero, so residual reserve/strategy positions
    ///         cannot be abandoned. Evolve it by UUPS-upgrading in place.
    error TreasuryLocked();

    /// @notice Thrown when final Treasury wiring does not target an active UUPS
    ///         Treasury proxy exposing the required reciprocal-binding getters.
    error InvalidTreasury(address candidate);

    /// @notice Thrown when a candidate Treasury is bound to a different USD8
    ///         or Registry than this token.
    error InvalidTreasuryBinding(address candidate, address boundUsd8, address boundRegistry);

    /// @notice Emitted when the timelock changes the Treasury address.
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);

    // ─────────────────────────── Constructor / initializer ───────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. Callable exactly once.
    /// @param  _registry      Shared access + pause registry (sets proxy storage;
    ///                         the impl constructor only set impl storage).
    /// @param  _treasury Initial Treasury address allowed to mint/burn.
    function initialize(Registry _registry, address _treasury) external initializer {
        if (_treasury == address(0)) revert ZeroAddress();
        __ERC20_init("USD8", "USD8");
        __ERC20Permit_init("USD8");

        _setRegistry(_registry);
        _setTreasury(_treasury);
    }

    // ─────────────────────────── Governance (timelock) ───────────────────────────

    /// @notice Set the account allowed to mint and burn USD8. Timelock only, and
    ///         only before the first issuance — the initial wiring at deploy. Once
    ///         USD8 has ever been live, the Treasury is permanently LOCKED (M-06),
    ///         even if supply later returns to zero: rotating it could strand the
    ///         old Treasury's reserve and strategy positions. Change Treasury logic
    ///         by UUPS-upgrading its proxy in place instead.
    function setTreasury(address newTreasury) external onlyTimelock {
        if (newTreasury == address(0)) revert ZeroAddress();
        if (treasuryLocked || totalSupply() != 0) revert TreasuryLocked();
        _validateTreasuryBinding(newTreasury);
        _setTreasury(newTreasury);
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Only the timelock can authorize. Treasury cannot upgrade unless it
    ///      is also the timelock.
    function _authorizeUpgrade(address) internal view override onlyTimelock {}

    // ─────────────────────────── Mint / burn (treasury) ───────────────────────────

    /// @notice Mint amount USD8 to to. Callable only by {treasury}.
    function mint(address to, uint256 amount) external onlyTreasury {
        if (amount != 0) treasuryLocked = true;
        _mint(to, amount);
    }

    /// @notice Burn amount USD8 from from. Callable only by {treasury}.
    function burn(address from, uint256 amount) external onlyTreasury {
        if (amount != 0) treasuryLocked = true;
        _burn(from, amount);
    }

    // ─────────────────────────── Internal / modifiers ───────────────────────────

    /// @dev USD8 intentionally does NOT support ERC-2771 meta-transactions.
    ///      The treasury check uses msg.sender directly rather than
    ///      _msgSender(). Do not add ERC2771ContextUpgradeable to the
    ///      inheritance chain without revisiting this call site — a
    ///      trusted forwarder would otherwise allow msg.sender to be a
    ///      relayer address that doesn't match treasury.
    ///      Gasless flows are intended to go through the standard
    ///      permit + transferFrom relayer pattern instead.
    modifier onlyTreasury() {
        if (msg.sender != treasury) revert UnauthorizedTreasury(msg.sender);
        _;
    }

    function _setTreasury(address newTreasury) internal {
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @dev Fail closed unless the candidate is a deployed contract whose
    ///      fixed wiring points back to this exact USD8 + Registry.
    ///      This catches bootstrap typos before the first issuance makes the
    ///      Treasury selection irreversible.
    function _validateTreasuryBinding(address candidate) internal view {
        if (candidate.code.length == 0) revert InvalidTreasury(candidate);

        bytes32 proxyMarker;
        address boundUsd8;
        address boundRegistry;
        try ITreasuryBinding(candidate).treasuryProxyMarker() returns (bytes32 value) {
            proxyMarker = value;
        } catch {
            revert InvalidTreasury(candidate);
        }
        if (proxyMarker != EXPECTED_TREASURY_PROXY_MARKER) revert InvalidTreasury(candidate);

        try ITreasuryBinding(candidate).usd8() returns (address value) {
            boundUsd8 = value;
        } catch {
            revert InvalidTreasury(candidate);
        }
        try ITreasuryBinding(candidate).registry() returns (address value) {
            boundRegistry = value;
        } catch {
            revert InvalidTreasury(candidate);
        }

        if (boundUsd8 != address(this) || boundRegistry != address(registry())) {
            revert InvalidTreasuryBinding(candidate, boundUsd8, boundRegistry);
        }
    }

    /// @dev USD8 custodies no accounted tokens — it is just the ERC-20. Any
    ///      balance at this address (foreign tokens, or USD8 mis-sent to the
    ///      token contract) is stray, so the full balance is sweepable via
    ///      {RegistryManaged-sweepToken}.
    function _sweepable(address token) internal view override returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
