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
import {Registry} from "./Registry.sol";

/// @title  SharedBase
/// @notice Thin base wiring a contract to the shared {Registry}. Holds the
///         registry and exposes the three access/pause modifiers every core
///         contract uses, so roles and the pause flag live in one place
///         ({Registry}) instead of a copy per contract. Also provides the
///         shared ETH/ERC-20 sweep path.
/// @dev    {registry} is set ONCE via {_setRegistry} — in the constructor for
///         non-upgradeable contracts, in initialize() for proxies — and never
///         changes afterward: there is no external setter. The {Registry} is itself
///         a UUPS proxy at a fixed address, so the system evolves by upgrading the
///         Registry in place, not by re-pointing each contract at a new one. This
///         removes an ACL-wide re-point lever from every managed contract. The
///         `require*` calls are view calls into {Registry} that revert on failure,
///         so the auth errors are defined there alone.
///
///         Storage is ERC-7201 namespaced: state lives in a struct at a fixed
///         hashed slot, not in sequential layout, so this shared base can gain
///         fields in a future version without a storage gap and without shifting
///         any child's storage — collisions are infeasible regardless of
///         inheritance order.
abstract contract SharedBase {
    using SafeERC20 for IERC20;

    // ─────────────────────────── Storage (ERC-7201) ───────────────────────────

    /// @custom:storage-location erc7201:usd8.storage.RegistryManaged
    /// @dev The original namespace is intentionally retained across the contract rename.
    struct SharedBaseStorage {
        /// @dev The system's access + pause registry. Set once at init, then fixed.
        Registry registry;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("usd8.storage.RegistryManaged")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SHARED_BASE_STORAGE = 0x9352834efe5044ee8cb502e43731eef76e3c874efee5a39ae6f2733fb284cb00;

    function _sharedBaseStorage() private pure returns (SharedBaseStorage storage $) {
        assembly {
            $.slot := SHARED_BASE_STORAGE
        }
    }

    /// @notice The system's access + pause registry (a fixed UUPS proxy address).
    function registry() public view returns (Registry) {
        return _sharedBaseStorage().registry;
    }

    // ─────────────────────────── Errors / events ───────────────────────────

    error ZeroAddress();
    /// @notice A sweep cannot send assets back to the contract being swept.
    error InvalidSweepRecipient(address recipient);
    error EthTransferFailed();
    /// @notice Nothing sweepable for this token (address(0) = ETH).
    error NothingToSweep(address token);
    /// @notice A beta-only operation was called after {Registry.endBetaMode}.
    error NotBetaMode();

    event RegistryChanged(address indexed oldRegistry, address indexed newRegistry);
    event ETHSwept(address indexed to, uint256 amount);
    event TokenSwept(address indexed token, address indexed to, uint256 amount);

    // ─────────────────────────── Registry pointer (timelock) ───────────────────────────

    /// @dev No constructor: each contract sets {registry} ONCE via {_setRegistry}
    ///      from its own constructor (non-upgradeable) or initialize() (proxy), so a
    ///      proxy impl never dead-writes its own storage. There is no external setter
    ///      — the pointer is fixed for the contract's life; upgrade the Registry proxy
    ///      to evolve system-wide behavior.
    function _setRegistry(Registry newRegistry) internal {
        if (address(newRegistry) == address(0)) revert ZeroAddress();
        SharedBaseStorage storage $ = _sharedBaseStorage();
        emit RegistryChanged(address($.registry), address(newRegistry));
        $.registry = newRegistry;
    }

    // ─────────────────────────── Modifiers (access + pause) ───────────────────────────

    /// @dev Caller must be the timelock.
    modifier onlyTimelock() {
        _sharedBaseStorage().registry.requireTimelock(msg.sender);
        _;
    }

    /// @dev Caller must be an admin or the timelock.
    modifier onlyAdminOrTimelock() {
        _sharedBaseStorage().registry.requireAdminOrTimelock(msg.sender);
        _;
    }

    /// @dev Reverts while THIS contract is paused in the registry.
    modifier whenNotPaused() {
        _sharedBaseStorage().registry.requireNotPaused(address(this));
        _;
    }

    /// @dev Reverts once beta has ended ({Registry.endBetaMode}). Gates the
    ///      trusted-admin operational shortcuts that are only acceptable at launch;
    ///      pair it with {onlyAdminOrTimelock} on the guarded function. Does NOT by
    ///      itself grant any authority — it only widens WHEN an already-authorized
    ///      shortcut is allowed. Never applied to master powers.
    modifier onlyBetaMode() {
        if (!_sharedBaseStorage().registry.betaMode()) revert NotBetaMode();
        _;
    }

    // ─────────────────────────── Sweep (admin or timelock) ───────────────────────────

    /// @notice Sweep ALL stray ETH from this contract to `to`. Admin or timelock.
    ///         Managed contracts have no ordinary payable business entrypoint;
    ///         ETH may arrive by force-send or through payable UUPS upgrade
    ///         initialization. Reverts if there is none.
    /// @param to  Recipient (non-zero).
    function sweepETH(address payable to) external onlyAdminOrTimelock {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidSweepRecipient(to);
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToSweep(address(0));
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit ETHSwept(to, amount);
    }

    /// @notice Sweep the non-accountable balance of `token` to `to`. Admin or
    ///         timelock. Serves BOTH roles: rescuing stuck / mistakenly-sent
    ///         tokens AND routine admin collection of protocol surplus (forfeited
    ///         revenue, over-sends). The amount swept is {_sweepable} — the
    ///         balance ABOVE what the contract accounts as protected — so
    ///         sensitive holdings (reserves, share backing, staked principal,
    ///         committed rewards, live escrow) are never touched. Reverts if
    ///         nothing is sweepable.
    /// @param token  Token to sweep.
    /// @param to     Recipient (non-zero).
    function sweepToken(IERC20 token, address to) external onlyAdminOrTimelock {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidSweepRecipient(to);
        uint256 amount = _sweepable(address(token));
        if (amount == 0) revert NothingToSweep(address(token));
        token.safeTransfer(to, amount);
        emit TokenSwept(address(token), to, amount);
    }

    /// @dev How much of `token` may be swept: balance minus the accounted /
    ///      protected amount. DEFAULT 0 — FAIL-CLOSED, so a contract that does
    ///      not opt a token in exposes nothing. Overrides return 0 for sensitive
    ///      tokens and `balanceOf(this) − accounted` for everything else.
    function _sweepable(address token) internal view virtual returns (uint256) {
        return 0;
    }
}
