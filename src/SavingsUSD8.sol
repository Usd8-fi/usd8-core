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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {USD8} from "./USD8.sol";
import {Registry} from "./Registry.sol";
import {RegistryManaged} from "./RegistryManaged.sol";
import {IProfitDistributionReceiver} from "./interfaces/IProfitDistributionReceiver.sol";

/// @title  SavingsUSD8 (sUSD8) v1
/// @notice UUPS-upgradeable ERC4626 savings vault for USD8 with linear profit
///         vesting. Users deposit USD8, receive sUSD8. Yield arrives as USD8 via
///         {receiveProfitDistribution} (routed from the {Treasury}, which earns
///         it on the USDC reserve backing USD8) and vests smoothly into the
///         share price — the vault itself holds deposited USD8 idle and does not
///         deploy it, so all yield is external.
/// @dev    Synthetic-totalAssets ("Pattern B") implementation: no shares are
///         minted or burned for vesting. totalAssets() is idle USD8 minus the
///         still-unvested reported profit. Because unvested profit is excluded
///         from totalAssets, no withdrawal can ever spend below it — the buffer
///         is preserved automatically (no strategy claw-back needed).
/// @custom:security-contact rick@usd8.fi
contract SavingsUSD8 is
    Initializable,
    ERC4626Upgradeable,
    ERC20PermitUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    RegistryManaged,
    IProfitDistributionReceiver
{
    using SafeERC20 for IERC20;

    // ─────────────────────────── State ───────────────────────────

    /// @notice Amount of profit still vesting (in asset base units).
    ///         When 0, no active schedule.
    uint128 public pendingProfit;

    /// @notice Start of the current vesting schedule.
    uint64 public profitStartTime;

    /// @notice End of the current vesting schedule.
    uint64 public profitEndTime;

    /// @notice Default {profitMaxUnlockTime}: 7 days, matching scrvUSD /
    ///         Yearn v3 and the expected weekly distribution cadence.
    uint64 public constant DEFAULT_PROFIT_MAX_UNLOCK_TIME = 7 days;

    /// @notice Upper bound for {setProfitMaxUnlockTime}. Vesting longer
    ///         than this only delays yield without adding JIT protection.
    uint64 public constant MAX_PROFIT_MAX_UNLOCK_TIME = 30 days;

    /// @notice Maximum duration (seconds) over which freshly-reported
    ///         profit is vested. Defaults to
    ///         {DEFAULT_PROFIT_MAX_UNLOCK_TIME}; timelock-settable via
    ///         {setProfitMaxUnlockTime}. Linear vesting means even short
    ///         windows defeat JIT deposit-sniping (sUSDe uses 8 hours),
    ///         but the window must be nonzero.
    uint64 public profitMaxUnlockTime;

    /// @notice USD8 the vault accounts as its own: deposited principal plus all
    ///         profit ever distributed (via {receiveProfitDistribution}), net of
    ///         withdrawals. Internal accounting instead of balanceOf, so a stray
    ///         direct USD8 donation is NOT counted — it never touches share price and
    ///         is instead recoverable as protocol surplus via {RegistryManaged-sweepToken}.
    ///         {totalAssets} = this minus the still-unvested portion.
    uint256 private _accountedAssets;

    // ─────────────────────────── Errors ──────────────────────────

    error ZeroAmount();
    error InvalidProfitMaxUnlockTime();
    error ProfitTooLarge();
    error SharePriceDecreased(uint256 assetsBefore, uint256 supplyBefore, uint256 assetsAfter, uint256 supplyAfter);

    /// @notice Thrown by {receiveProfitDistribution} when the vault has no
    ///         depositors. Distributing profit into a zero-supply vault
    ///         strands the asset and turns the next depositor's small
    ///         deposit into 0 shares (the classic inflation-attack DoS).
    ///         Treasury should retain the surplus until users have entered.
    error NoDepositors();

    // ─────────────────────────── Events ──────────────────────────

    event ProfitReported(address indexed reporter, uint256 amount, uint256 newPending, uint64 newEndTime);
    event ProfitMaxUnlockTimeChanged(uint64 oldTime, uint64 newTime);

    // ─────────────────────────── Constructor / initializer ─────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. Callable once.
    /// @param _registry  Shared access + pause registry (holds timelock/admin).
    /// @param _usd8       The USD8 token (underlying asset).
    function initialize(Registry _registry, USD8 _usd8) external initializer {
        if (address(_usd8) == address(0)) revert ZeroAddress();
        __ERC20_init("Savings USD8", "sUSD8");
        __ERC20Permit_init("Savings USD8");
        __ERC4626_init(IERC20(address(_usd8)));
        _setRegistry(_registry);
        profitMaxUnlockTime = DEFAULT_PROFIT_MAX_UNLOCK_TIME;
    }

    function _authorizeUpgrade(address) internal override onlyTimelock {}

    // ─────────────────────────── Modifiers ───────────────────────

    /// @dev Preserve or improve the normalized ERC4626 share price across
    ///      user flows. Exact equality is too strict because ERC4626 rounds
    ///      in the vault's favor. Belt-and-suspenders now that there are no
    ///      strategies: standard deposit/withdraw already preserve price, so
    ///      this catches any future regression.
    modifier sharePriceInvariant() {
        uint256 assetsBefore = totalAssets();
        uint256 supplyBefore = totalSupply();
        _;

        uint256 supplyAfter = totalSupply();
        if (supplyBefore == 0 || supplyAfter == 0) return;

        uint256 assetsAfter = totalAssets();
        (uint256 leftHigh, uint256 leftLow) = Math.mul512(assetsAfter + 1, supplyBefore + 1);
        (uint256 rightHigh, uint256 rightLow) = Math.mul512(assetsBefore + 1, supplyAfter + 1);

        if (leftHigh < rightHigh || (leftHigh == rightHigh && leftLow < rightLow)) {
            revert SharePriceDecreased(assetsBefore, supplyBefore, assetsAfter, supplyAfter);
        }
    }

    // ─────────────────────────── Profit distribution ───────────────────────────

    /// @notice Receive amount of USD8 as profit distribution. Pulls
    ///         atomically via transferFrom (caller must approve). The
    ///         amount vests linearly over the weighted-average duration
    ///         combining any remaining unvested portion with a fresh
    ///         profitMaxUnlockTime window.
    /// @dev    Permissionless — anyone may donate. The weighted-average
    ///         schedule reset means tiny calls don't significantly extend
    ///         the end-time, so there's no griefing vector.
    ///         Reverts {NoDepositors} when totalSupply() == 0 to prevent
    ///         profit being stranded in a vault with no shares (and to
    ///         block the inflation-DoS path on the next depositor).
    function receiveProfitDistribution(uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert ProfitTooLarge();
        if (totalSupply() == 0) revert NoDepositors();

        // Clear stale schedule storage if the previous vesting window has
        // fully elapsed. _unvestedProfit() already returns 0 in this case
        // and the math below works regardless, but clearing keeps pendingProfit
        // honest as a live indicator instead of a frozen historical value.
        if (pendingProfit != 0 && block.timestamp >= profitEndTime) {
            pendingProfit = 0;
            profitStartTime = 0;
            profitEndTime = 0;
        }

        // Checks → Effects → Interactions: compute new schedule, write
        // state, then pull the asset.
        uint256 unvested = _unvestedProfit();
        uint256 timeRemaining = block.timestamp < profitEndTime ? profitEndTime - block.timestamp : 0;

        uint256 newPending = unvested + amount;
        if (newPending > type(uint128).max) revert ProfitTooLarge();

        // Weighted-average vesting period: blend any unvested remainder
        // with the new profit to avoid material schedule extension from dust.
        uint256 newDuration = (unvested * timeRemaining + amount * uint256(profitMaxUnlockTime)) / newPending;
        uint64 newEndTime = uint64(block.timestamp + newDuration);

        pendingProfit = uint128(newPending);
        profitStartTime = uint64(block.timestamp);
        profitEndTime = newEndTime;
        _accountedAssets += amount; // official inflow — accrues to holders as it vests

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        emit ProfitReported(msg.sender, amount, newPending, newEndTime);
    }

    // ─────────────────────────── Vesting math ───────────────────────────

    /// @notice Current unvested profit. Decreases linearly to zero as
    ///         block.timestamp advances toward profitEndTime.
    function unvestedProfit() external view returns (uint256) {
        return _unvestedProfit();
    }

    function _unvestedProfit() internal view returns (uint256) {
        if (pendingProfit == 0) return 0;
        if (block.timestamp >= profitEndTime) return 0;
        uint256 elapsed = block.timestamp - profitStartTime;
        uint256 totalDuration = profitEndTime - profitStartTime;
        uint256 vested = (uint256(pendingProfit) * elapsed) / totalDuration;
        return uint256(pendingProfit) - vested;
    }

    /// @notice Total assets recognized by the vault for ERC4626 math: internally
    ///         accounted USD8 ({_accountedAssets} = principal + distributed profit)
    ///         minus the still-unvested portion of reported profit. Uses internal
    ///         accounting rather than balanceOf, so a stray direct donation is
    ///         excluded (never inflates share price; swept as surplus). Because the
    ///         unvested portion is excluded here, no withdrawal can spend below it, so
    ///         the buffer never underflows.
    function totalAssets() public view override returns (uint256) {
        return _accountedAssets - _unvestedProfit();
    }

    /// @dev Keep {_accountedAssets} in lockstep with ERC4626 deposit/withdraw so
    ///      totalAssets tracks only official inflows, never a stray donation.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        _accountedAssets += assets;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _accountedAssets -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }

    // ─────────────────────────── Admin ───────────────────────────

    /// @notice Set the vesting window applied to future profit reports.
    ///         Timelock only — a fast key that could shrink the window to
    ///         seconds could JIT-snipe the next distribution, so this is
    ///         deliberately not an admin power. Must be in
    ///         (0, MAX_PROFIT_MAX_UNLOCK_TIME]. The active vesting schedule
    ///         is unaffected; the new window applies from the next
    ///         {receiveProfitDistribution}.
    function setProfitMaxUnlockTime(uint64 newTime) external onlyTimelock {
        if (newTime == 0 || newTime > MAX_PROFIT_MAX_UNLOCK_TIME) revert InvalidProfitMaxUnlockTime();
        emit ProfitMaxUnlockTimeChanged(profitMaxUnlockTime, newTime);
        profitMaxUnlockTime = newTime;
    }

    /// @dev Rescuable via {RegistryManaged-sweepToken}: balance ABOVE what the vault
    ///      accounts for. For the underlying ({asset}) that is any balance beyond
    ///      {_accountedAssets} (principal + distributed profit) — i.e. stray direct
    ///      donations, which are excluded from totalAssets and so never back shares.
    ///      For any other token, the full balance is stray.
    function _sweepable(address token) internal view override returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (token == asset()) return bal > _accountedAssets ? bal - _accountedAssets : 0;
        return bal;
    }

    // ─────────────────────────── ERC4626 entry points ───────────────────────────

    /// @dev nonReentrant on all four user-facing entry points: USD8 is itself
    ///      UUPS-upgradeable, so a future transfer hook can't open a reentrancy
    ///      window here. sharePriceInvariant is belt-and-suspenders (see modifier).
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        sharePriceInvariant
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        sharePriceInvariant
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        sharePriceInvariant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        sharePriceInvariant
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (registry().paused(address(this))) return 0;
        return super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view override returns (uint256) {
        if (registry().paused(address(this))) return 0;
        return super.maxMint(receiver);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (registry().paused(address(this))) return 0;
        return super.maxWithdraw(owner);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (registry().paused(address(this))) return 0;
        return super.maxRedeem(owner);
    }
}
