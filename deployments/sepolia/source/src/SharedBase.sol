// SPDX-License-Identifier: BUSL-1.1

//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\: \/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Registry} from "./Registry.sol";

/// @title SharedBase
/// @notice Connects managed contracts to the shared Registry and provides common
///         access checks, pause checks, and asset sweep functions.
/// @dev Current contracts configure Registry during construction or initialization
///      and expose no external setter. ERC-7201 storage avoids shifting child layouts.
abstract contract SharedBase {
    using SafeERC20 for IERC20;

    // ─────────────────────────── Storage (ERC-7201) ───────────────────────────

    /// @custom:storage-location erc7201:usd8.storage.RegistryManaged
    /// @dev The original namespace is intentionally retained across the contract rename.
    struct SharedBaseStorage {
        /// @dev Registry pointer configured by the inheriting contract.
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

    /// @dev Stores the Registry pointer. Inheriting contracts should call this only
    ///      during construction or initialization.
    function _setRegistry(Registry newRegistry) internal {
        if (address(newRegistry) == address(0)) revert ZeroAddress();
        SharedBaseStorage storage $ = _sharedBaseStorage();
        emit RegistryChanged(address($.registry), address(newRegistry));
        $.registry = newRegistry;
    }

    // ─────────────────────────── Access + pause checks ───────────────────────────

    /// @dev Caller must be the timelock.
    function _requireTimelock() internal view {
        _sharedBaseStorage().registry.requireTimelock(msg.sender);
    }

    /// @dev Caller must be an admin or the timelock.
    function _requireAdminOrTimelock() internal view {
        _sharedBaseStorage().registry.requireAdminOrTimelock(msg.sender);
    }

    /// @dev Reverts while THIS contract is paused in the registry.
    function _requireNotPaused() internal view {
        _sharedBaseStorage().registry.requireNotPaused(address(this));
    }

    /// @dev Reverts after {Registry.endBetaMode}. This is a mode check, not authorization.
    function _requireBetaMode() internal view {
        if (!_sharedBaseStorage().registry.betaMode()) revert NotBetaMode();
    }

    // ─────────────────────────── Sweep (admin or timelock) ───────────────────────────

    /// @notice Sweep ALL stray ETH from this contract to `to`. Admin or timelock.
    ///         Managed contracts have no ordinary payable business entrypoint;
    ///         ETH may arrive by force-send or through payable UUPS upgrade
    ///         initialization. Reverts if there is none.
    /// @param to  Recipient (non-zero).
    function sweepETH(address payable to) external {
        _requireAdminOrTimelock();
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidSweepRecipient(to);
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToSweep(address(0));
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit ETHSwept(to, amount);
    }

    /// @notice Sweep the token balance that the managed contract does not protect.
    ///         Admin or timelock. Reverts when nothing is sweepable.
    /// @param token  Token to sweep.
    /// @param to     Recipient (non-zero).
    function sweepToken(IERC20 token, address to) external {
        _requireAdminOrTimelock();
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidSweepRecipient(to);
        uint256 amount = _sweepable(address(token));
        if (amount == 0) revert NothingToSweep(address(token));
        token.safeTransfer(to, amount);
        emit TokenSwept(address(token), to, amount);
    }

    /// @dev Maximum amount of `token` that may be swept. Defaults to zero.
    ///      Overrides must exclude all accounted or protected balances.
    function _sweepable(address token) internal view virtual returns (uint256) {
        return 0;
    }
}
