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
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @title  ERC4626Strategy
/// @notice {IStrategy} adapter that deploys USDC into any ERC-4626 vault whose
///         asset() is USDC, tracking the position via the vault's share balance.
///         Covers Aave v3 (via its canonical stataUSDC / static-aToken ERC4626
///         wrapper), MetaMorpho curated vaults (Gauntlet/Steakhouse USDC), and
///         any other USDC ERC-4626 — one deployed instance per vault.
/// @dev    Vault address is immutable per instance.
///
///         Registry model:
///         - {deploy} and {withdraw} are callable only by {treasury}.
///         - No admin functions, no parameters to tune, no upgrades.
///         - If the underlying vault breaks, Treasury force-removes this
///           strategy and admin deploys a replacement targeting another vault.
///
///         Atomic withdrawal: {withdraw} routes the vault's USDC payout straight
///         to {treasury} and either delivers the full amount or reverts;
///         {WithdrawShort} catches a spec-violating vault that under-delivers
///         without reverting.
///
///         Liquidity caveat: less-liquid vaults (e.g. MetaMorpho under high
///         Morpho Blue utilization) are best placed BEHIND a more liquid
///         primary in the Treasury's strategy queue, not at index 0.
///
///         Fees: vaults that take performance fees by minting fee shares dilute
///         this contract's share slightly, reflected automatically in
///         convertToAssets(balanceOf(this)). Deposit/withdraw-time fees will
///         trip {Treasury-reserveSupplyStatusCheck} on the next mint/redeem if
///         the surplus shrinks — admin should vet fee structure before approval.
/// @custom:security-contact rick@usd8.fi
contract ERC4626Strategy is IStrategy {
    using SafeERC20 for IERC20;

    /// @notice Mainnet USDC.
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    /// @notice The Treasury allowed to call {deploy} and {withdraw}.
    address public immutable treasury;

    /// @notice The ERC-4626 vault this strategy deposits into. Immutable —
    ///         deploy a new strategy contract to target a different vault.
    IERC4626 public immutable vault;

    /// @notice Thrown when a non-Treasury account calls a gated function.
    error UnauthorizedTreasury(address caller);

    /// @notice Thrown when a zero address is supplied where one is not allowed.
    error ZeroAddress();

    /// @notice Thrown when the supplied vault's asset() is not USDC.
    error VaultAssetMismatch(address expected, address actual);

    /// @notice Thrown when the vault returns fewer USDC than requested.
    error WithdrawShort(uint256 requested, uint256 received);

    /// @notice Thrown when a deposit mints zero shares — the funds would be
    ///         committed with nothing tracking them (M-02).
    error ZeroSharesMinted();

    /// @notice Thrown when the value of the shares minted by a deposit falls
    ///         materially short of the USDC put in (M-02): a donation-manipulated
    ///         share price, a deposit fee, or a nonconforming vault would
    ///         otherwise silently commit the reserve loss.
    error DepositValueShort(uint256 deposited, uint256 received);

    /// @notice Emitted when Treasury deploys USDC into the vault.
    event Deployed(uint256 amount);

    /// @notice Emitted when Treasury pulls USDC from the vault back to itself.
    event Withdrawn(uint256 amount);

    /// @param _treasury The Treasury contract that owns this strategy.
    /// @param _vault    The ERC-4626 vault to deposit into. Must report asset() == USDC.
    constructor(address _treasury, IERC4626 _vault) {
        if (_treasury == address(0) || address(_vault) == address(0)) revert ZeroAddress();
        address vaultAsset = _vault.asset();
        if (vaultAsset != address(USDC)) revert VaultAssetMismatch(address(USDC), vaultAsset);
        treasury = _treasury;
        vault = _vault;
        // One-time unlimited approval to the trusted, fixed vault.
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
    /// @dev Caller (Treasury) is expected to have pushed amount USDC to this
    ///      contract immediately before this call. The vault mints shares to
    ///      this contract (receiver = address(this)).
    ///
    ///      M-02 guards — the deposit must be value-neutral or revert, so a
    ///      reserve loss never commits: zero minted shares (vault banked the
    ///      USDC with nothing tracking it), or a position-value delta short of
    ///      `amount` (donation-inflated share price, deposit fee, nonconforming
    ///      vault). Honest conforming vaults lose at most wei-level rounding on
    ///      the round trip, so the tolerance is 2 wei — no bps knob to tune.
    function deploy(uint256 amount) external onlyTreasury {
        uint256 valueBefore = totalAssets();
        uint256 shares = vault.deposit(amount, address(this));
        if (shares == 0) revert ZeroSharesMinted();
        uint256 received = totalAssets() - valueBefore;
        if (received + 2 < amount) revert DepositValueShort(amount, received);
        emit Deployed(amount);
    }

    /// @inheritdoc IStrategy
    /// @dev Routes the vault's USDC payout directly to {treasury}. The
    ///      balance-delta check defends against a non-spec vault under-delivering
    ///      without reverting.
    function withdraw(uint256 amount) external onlyTreasury {
        uint256 balanceBefore = USDC.balanceOf(treasury);
        vault.withdraw(amount, treasury, address(this));
        uint256 received = USDC.balanceOf(treasury) - balanceBefore;
        if (received != amount) revert WithdrawShort(amount, received);
        emit Withdrawn(received);
    }

    /// @inheritdoc IStrategy
    /// @dev convertToAssets(balanceOf(this)) reflects principal, accrued yield,
    ///      and any fee-share dilution at the current vault share price.
    function totalAssets() public view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }
}
