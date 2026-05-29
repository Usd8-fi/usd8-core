// SPDX-License-Identifier: MIT
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @title  MorphoVaultStrategy
/// @notice {IStrategy} adapter that deploys USDC into a configured
///         MetaMorpho (ERC4626) vault on Ethereum mainnet — e.g., the
///         Gauntlet USDC Prime or Steakhouse USDC curated vaults — and
///         tracks the position via the vault's share balance.
/// @dev    Generic over any ERC4626 vault whose `asset()` is USDC.
///         Deploy one instance per vault you want to wire into the
///         Treasury (vault address is immutable per-instance).
///
///         Authority model:
///         - {deploy} and {withdraw} are callable only by {treasury}.
///         - No admin functions, no parameters to tune, no upgrades.
///         - If the underlying vault breaks, Treasury force-removes
///           this strategy and admin can deploy a replacement targeting
///           a different vault.
///
///         Atomic withdrawal: MetaMorpho's `withdraw` walks its
///         configured Morpho Blue markets in the curator's withdrawal
///         queue order and either delivers the full `amount` or reverts.
///         {WithdrawShort} catches any spec-violating vault that
///         under-delivers without reverting.
///
///         Liquidity caveat: MetaMorpho vaults are typically less liquid
///         than Aave on extreme drawdowns — underlying Morpho Blue
///         markets can hit high utilization. Best placed BEHIND a more
///         liquid primary (Aave/idle) in the Treasury's strategy queue,
///         not at index 0.
///
///         Fees: some MetaMorpho vaults take performance fees by minting
///         fee shares to the curator on profit accrual. This dilutes
///         this contract's share slightly but is reflected automatically
///         in `convertToAssets(balanceOf(this))`. Vaults with deposit-
///         time or withdraw-time fees will trigger {Treasury-
///         reserveSupplyStatusCheck} on the next mint/redeem if the
///         surplus shrinks — admin should vet for fee structure before
///         approval.
/// @custom:security-contact rick@usd8.fi
contract MorphoVaultStrategy is IStrategy {
    using SafeERC20 for IERC20;

    /// @notice Mainnet USDC.
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    /// @notice The Treasury allowed to call {deploy} and {withdraw}.
    address public immutable treasury;

    /// @notice The MetaMorpho (ERC4626) vault this strategy deposits into.
    ///         Immutable — deploy a new strategy contract to target a
    ///         different vault.
    IERC4626 public immutable vault;

    /// @notice Thrown when a non-Treasury account calls a gated function.
    error UnauthorizedTreasury(address caller);

    /// @notice Thrown when a zero address is supplied where one is not allowed.
    error ZeroAddress();

    /// @notice Thrown when the supplied vault's `asset()` is not USDC.
    error VaultAssetMismatch(address expected, address actual);

    /// @notice Thrown when the vault returns fewer USDC than requested.
    error WithdrawShort(uint256 requested, uint256 received);

    /// @notice Emitted when Treasury deploys USDC into the vault.
    event Deployed(uint256 amount);

    /// @notice Emitted when Treasury pulls USDC from the vault back to itself.
    event Withdrawn(uint256 amount);

    /// @param _treasury The Treasury contract that owns this strategy.
    /// @param _vault    The MetaMorpho / ERC4626 vault to deposit into.
    ///                  Must report `asset() == USDC`.
    constructor(address _treasury, IERC4626 _vault) {
        if (_treasury == address(0) || address(_vault) == address(0)) revert ZeroAddress();
        address vaultAsset = _vault.asset();
        if (vaultAsset != address(USDC)) revert VaultAssetMismatch(address(USDC), vaultAsset);
        treasury = _treasury;
        vault = _vault;
        // One-time unlimited approval to the trusted vault. Vault address
        // is fixed for this strategy instance.
        USDC.forceApprove(address(_vault), type(uint256).max);
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert UnauthorizedTreasury(msg.sender);
        _;
    }

    /// @inheritdoc IStrategy
    function underlying() external pure returns (address) {
        return address(USDC);
    }

    /// @inheritdoc IStrategy
    /// @dev Caller (Treasury) is expected to have pushed `amount` USDC
    ///      to this contract immediately before this call. The vault
    ///      mints shares to this contract (`receiver = address(this)`).
    function deploy(uint256 amount) external onlyTreasury {
        vault.deposit(amount, address(this));
        emit Deployed(amount);
    }

    /// @inheritdoc IStrategy
    /// @dev Routes the vault's USDC payout directly to {treasury} via
    ///      `receiver = treasury`, avoiding a temporary balance here.
    ///      Balance-delta check defends against a non-spec-compliant
    ///      vault under-delivering without reverting.
    function withdraw(uint256 amount) external onlyTreasury {
        uint256 balanceBefore = USDC.balanceOf(treasury);
        vault.withdraw(amount, treasury, address(this));
        uint256 received = USDC.balanceOf(treasury) - balanceBefore;
        if (received != amount) revert WithdrawShort(amount, received);
        emit Withdrawn(received);
    }

    /// @inheritdoc IStrategy
    /// @dev `convertToAssets(balanceOf(this))` reflects principal,
    ///      accrued yield, and curator-fee dilution at the current
    ///      vault share price.
    function totalAssets() external view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }
}
