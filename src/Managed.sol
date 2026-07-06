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

/// @title  Managed
/// @notice Thin base wiring a contract to the shared {Registry}. Holds the
///         registry and exposes the three access/pause modifiers every core
///         contract uses, so roles and the pause flag live in one place
///         ({Registry}) instead of a copy per contract. Also provides the
///         shared ETH/ERC-20 sweep path.
/// @dev    {authority} is a settable pointer, not immutable: since {Registry}
///         itself is non-upgradeable, {setAuthority} (timelock only) is the
///         migration path to a replacement registry without redeploying this
///         contract. Set in the constructor for non-upgradeable contracts and in
///         initialize() for UUPS proxies. The `require*` calls are view calls
///         into {Registry} that revert on failure, so the auth errors are
///         defined there alone.
///
///         SECURITY: {setAuthority} lets the timelock re-point this contract's
///         entire ACL in one move — it is as trusted as the timelock itself.
///         Point only at a verified, correctly-owned registry.
abstract contract Managed {
    using SafeERC20 for IERC20;

    /// @notice The system's access + pause registry. Timelock-settable.
    Registry public authority;

    /// @dev Storage gap. Managed is a base of UUPS (USD8, SavingsUSD8) and beacon
    ///      (SingleAssetCoverPool) upgradeable contracts; reserving slots here lets
    ///      a future version add state to Managed without shifting any child's
    ///      layout. Reduce this array by the number of slots any new var consumes.
    uint256[50] private __gap;

    error ZeroAddress();
    error EthTransferFailed();
    /// @notice Nothing sweepable for this token (address(0) = ETH).
    error NothingToSweep(address token);

    event AuthorityChanged(address indexed oldAuthority, address indexed newAuthority);
    event ETHSwept(address indexed to, uint256 amount);
    event TokenSwept(address indexed token, address indexed to, uint256 amount);

    /// @dev No constructor: each contract seeds {authority} via {_setAuthority}
    ///      from its own constructor (non-upgradeable) or initialize() (UUPS), so
    ///      a UUPS impl never dead-writes its own storage.

    /// @notice Re-point this contract at a new {Registry}. Timelock only.
    ///         Authorized by the CURRENT registry, so migration requires the
    ///         sitting timelock's approval.
    function setAuthority(Registry newAuthority) external onlyTimelock {
        _setAuthority(newAuthority);
    }

    function _setAuthority(Registry newAuthority) internal {
        if (address(newAuthority) == address(0)) revert ZeroAddress();
        emit AuthorityChanged(address(authority), address(newAuthority));
        authority = newAuthority;
    }

    /// @dev Caller must be the timelock.
    modifier onlyTimelock() {
        authority.requireTimelock(msg.sender);
        _;
    }

    /// @dev Caller must be an admin or the timelock.
    modifier onlyAdminOrTimelock() {
        authority.requireAdminOrTimelock(msg.sender);
        _;
    }

    /// @dev Reverts while THIS contract is paused in the registry.
    modifier whenNotPaused() {
        authority.requireNotPaused(address(this));
        _;
    }

    /// @notice Sweep ALL force-sent ETH from this contract to `to`. Admin or
    ///         timelock. No managed contract has a payable entrypoint, so any ETH
    ///         balance here can only have arrived by force-send — always stray.
    ///         Reverts if there is none.
    /// @param to  Recipient (non-zero).
    function sweepETH(address payable to) external onlyAdminOrTimelock {
        if (to == address(0)) revert ZeroAddress();
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
