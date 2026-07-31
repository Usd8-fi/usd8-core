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
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Registry} from "../Registry.sol";
import {ITreasuryReserveAsset, StrategyBase} from "./StrategyBase.sol";

/// @title ERC4626Strategy
/// @notice Treasury adapter for a fixed ERC-4626 vault whose asset is USDC.
/// @dev Only Treasury can deploy or withdraw principal. Deposits reject zero shares
///      and value loss beyond ERC-4626 rounding. Withdrawals must deliver the full
///      requested USDC atomically. Current value is the vault value of held shares.
///      Swap routes remain limited by {StrategyBase} and Registry approval.
/// @custom:security-contact rick@usd8.fi
contract ERC4626Strategy is IStrategy, StrategyBase {
    using SafeERC20 for IERC20;

    /// @notice The ERC-4626 vault this strategy deposits into. Immutable —
    ///         deploy a new strategy contract to target a different vault.
    IERC4626 public immutable vault;

    /// @notice Thrown when the supplied vault's asset() is not USDC.
    error VaultAssetMismatch(address expected, address actual);

    /// @notice Thrown when the vault returns fewer USDC than requested.
    error WithdrawShort(uint256 requested, uint256 received);

    /// @notice Thrown when a deposit mints no shares.
    error ZeroSharesMinted();

    /// @notice Thrown when minted shares are worth less than the deposit after rounding tolerance.
    error DepositValueShort(uint256 deposited, uint256 received);

    /// @notice Emitted when Treasury deploys USDC into the vault.
    event Deployed(uint256 amount);

    /// @notice Emitted when Treasury pulls USDC from the vault back to itself.
    event Withdrawn(uint256 amount);

    /// @param _treasury The Treasury contract that owns this strategy.
    /// @param _registry Shared role and approved-swap-route registry.
    /// @param _vault    The ERC-4626 vault to deposit into. Must report asset() == USDC.
    constructor(address _treasury, Registry _registry, IERC4626 _vault)
        StrategyBase(_treasury, _registry, ITreasuryReserveAsset(_treasury).USDC())
    {
        if (address(_vault) == address(0)) revert ZeroAddress();
        address vaultAsset = _vault.asset();
        if (vaultAsset != address(USDC)) revert VaultAssetMismatch(address(USDC), vaultAsset);
        vault = _vault;
        // One-time unlimited approval to the trusted, fixed vault.
        USDC.forceApprove(address(_vault), type(uint256).max);
    }

    /// @inheritdoc IStrategy
    function underlying() external view returns (address) {
        return address(USDC);
    }

    /// @inheritdoc IStrategy
    /// @dev Caller (Treasury) is expected to have pushed amount USDC to this
    ///      contract immediately before this call. The vault mints shares to
    ///      this contract (receiver = address(this)).
    ///
    ///      The deposit must mint nonzero shares and preserve value within the
    ///      vault's unavoidable rounding bound. ERC-4626 deposits round shares
    ///      down by less than one share base unit; converting those shares back
    ///      to assets can round down by one additional USDC base unit. Therefore
    ///      the tolerance is `vault.convertToAssets(1) + 1`, not a fixed 2 units.
    function deploy(uint256 amount) external onlyTreasury {
        uint256 valueBefore = totalAssets();
        uint256 shares = vault.deposit(amount, address(this));
        if (shares == 0) revert ZeroSharesMinted();
        uint256 received = totalAssets() - valueBefore;
        // Allow at most one share unit of value plus one asset unit for both rounding steps.
        uint256 tolerance = vault.convertToAssets(1) + 1;
        if (received + tolerance < amount) revert DepositValueShort(amount, received);
        emit Deployed(amount);
    }

    /// @inheritdoc IStrategy
    /// @dev Fixes the shares required for `amount` before execution, then routes
    ///      the vault's USDC payout directly to {treasury}. The balance-delta
    ///      check enforces `amount` as the minimum output.
    function withdraw(uint256 amount) external onlyTreasury {
        uint256 shares = vault.previewWithdraw(amount);
        uint256 balanceBefore = USDC.balanceOf(treasury);
        vault.redeem(shares, treasury, address(this));
        uint256 received = USDC.balanceOf(treasury) - balanceBefore;
        if (received < amount) revert WithdrawShort(amount, received);
        emit Withdrawn(received);
    }

    /// @inheritdoc IStrategy
    /// @dev convertToAssets(balanceOf(this)) reflects principal, accrued yield,
    ///      and any fee-share dilution at the current vault share price.
    function totalAssets() public view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }

    function _isPositionToken(address token) internal view override returns (bool) {
        return token == address(vault);
    }

    function _principalBalance() internal view override returns (uint256) {
        return vault.balanceOf(address(this));
    }
}
