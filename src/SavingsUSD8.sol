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
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {USD8} from "./USD8.sol";
import {IProfitDistributionReceiver} from "./interfaces/IProfitDistributionReceiver.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// @title  SavingsUSD8 (sUSD8) v1
/// @notice ERC4626 savings vault for USD8 with linear profit vesting and
///         multi-strategy deployment. Users deposit USD8, receive sUSD8.
///         The underlying USD8 may be deployed by admin to external
///         strategies (LP positions, lending markets, etc.) to generate
///         yield, which is received via {receiveProfitDistribution} and vests
///         smoothly into the share price.
/// @dev    Synthetic-totalAssets ("Pattern B") implementation: no shares
///         are minted or burned for vesting. `totalAssets()` returns idle
///         USD8 + strategy assets minus the still-unvested reported profit.
///         `_withdraw()` pulls any shortfall from strategies in array order
///         before the standard ERC4626 transfer, matching {Treasury}.
///
///         Strategy management mirrors the {Treasury} contract — same
///         {IStrategy} interface, same array-as-approval semantics, same
///         expectation that strategies support atomic withdrawal.
/// @custom:security-contact rick@usd8.fi
contract SavingsUSD8 is ERC4626, ERC20Permit, ReentrancyGuardTransient, IProfitDistributionReceiver {
    using SafeERC20 for IERC20;

    // ─────────────────────────── Types ───────────────────────────

    /// @notice Pause-state values. Mutually exclusive.
    ///         - `None`           : deposit and withdraw allowed.
    ///         - `SystemPaused`   : all user actions and admin fund moves blocked.
    ///         - `DepositPaused`  : deposit/mint blocked; withdraw/redeem allowed.
    ///         - `WithdrawPaused` : withdraw/redeem blocked; deposit/mint allowed.
    enum PauseState {
        None,
        SystemPaused,
        DepositPaused,
        WithdrawPaused
    }

    // ─────────────────────────── State ───────────────────────────

    /// @notice Governance/admin address.
    address public admin;

    /// @notice Account allowed to manage approved strategies.
    address public strategyManager;

    /// @notice Current pause state. Defaults to `None` on deployment.
    ///         Settable by admin via {setPauseState}.
    PauseState public pauseState;

    /// @notice Amount of profit still vesting (in asset base units).
    ///         When 0, no active schedule.
    uint128 public pendingProfit;

    /// @notice Start of the current vesting schedule.
    uint64 public profitStartTime;

    /// @notice End of the current vesting schedule.
    uint64 public profitEndTime;

    /// @notice Maximum duration (seconds) over which freshly-reported
    ///         profit is vested. Set once at deploy. Recommended >= 1 week
    ///         to defeat JIT attacks economically.
    uint64 public immutable profitMaxUnlockTime;

    /// @notice Approved USD8 strategies, in admin-determined order.
    ///         Order doubles as the withdrawal fallback queue.
    IStrategy[] public strategies;

    // ─────────────────────────── Errors ──────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error InvalidProfitMaxUnlockTime();
    error ProfitTooLarge();
    error UnauthorizedAdmin(address caller);
    error UnauthorizedStrategyManager(address caller);
    error StrategyNotApproved(IStrategy strategy);
    error StrategyAlreadyApproved(IStrategy strategy);
    error StrategyAssetMismatch(IStrategy strategy, address expected, address actual);
    error IndexOutOfRange(uint256 given, uint256 length);
    error SharePriceDecreased(uint256 assetsBefore, uint256 supplyBefore, uint256 assetsAfter, uint256 supplyAfter);
    error RescueProtected(address token);
    error EthTransferFailed();

    /// @notice Thrown when the operation is blocked by the current pause
    ///         state.
    error Paused(PauseState state);

    /// @notice Thrown by {receiveProfitDistribution} when the vault has no
    ///         depositors. Distributing profit into a zero-supply vault
    ///         strands the asset and turns the next depositor's small
    ///         deposit into 0 shares (the classic inflation-attack DoS).
    ///         Treasury should retain the surplus until users have entered.
    error NoDepositors();

    /// @notice Thrown by {depositToStrategy} when `amount` exceeds the
    ///         deployable balance (idle minus still-unvested profit).
    ///         Unvested profit must remain idle so a strategy loss can
    ///         never push `_rawAssets()` below `_unvestedProfit()`, which
    ///         would brick {totalAssets} and every ERC4626 entrypoint.
    error ExceedsDeployable(uint256 amount, uint256 deployable);

    // ─────────────────────────── Events ──────────────────────────

    event ProfitReported(address indexed reporter, uint256 amount, uint256 newPending, uint64 newEndTime);
    event PauseStateChanged(PauseState oldState, PauseState newState);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event StrategyManagerChanged(address indexed oldStrategyManager, address indexed newStrategyManager);
    event StrategyAdded(IStrategy indexed strategy);
    event StrategyRemoved(IStrategy indexed strategy);
    event StrategyMoved(IStrategy indexed strategy, uint256 fromIndex, uint256 toIndex);
    event DepositedToStrategy(IStrategy indexed strategy, uint256 amount);

    /// @notice Emitted when admin pulls USD8 from a strategy back to idle.
    ///         `amount` is the actual delta observed in this vault's USD8
    ///         balance, not the requested amount.
    event WithdrawnFromStrategy(IStrategy indexed strategy, uint256 amount);

    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ETHRescued(address indexed to, uint256 amount);

    // ─────────────────────────── Constructor ─────────────────────

    /// @param _usd8                 The USD8 token (underlying asset).
    /// @param _admin                Admin, expected to be governance timelock.
    /// @param _strategyManager      Account allowed to manage strategies.
    /// @param _profitMaxUnlockTime  Vesting duration in seconds.
    constructor(USD8 _usd8, address _admin, address _strategyManager, uint64 _profitMaxUnlockTime)
        ERC20("Savings USD8", "sUSD8")
        ERC20Permit("Savings USD8")
        ERC4626(IERC20(address(_usd8)))
    {
        if (address(_usd8) == address(0) || _admin == address(0) || _strategyManager == address(0)) {
            revert ZeroAddress();
        }
        if (_profitMaxUnlockTime == 0) revert InvalidProfitMaxUnlockTime();
        profitMaxUnlockTime = _profitMaxUnlockTime;
        admin = _admin;
        strategyManager = _strategyManager;
    }

    // ─────────────────────────── Modifiers ───────────────────────

    /// @dev Reverts {Paused} if `pauseState` is `SystemPaused` or `DepositPaused`.
    modifier whenDepositNotPaused() {
        PauseState s = pauseState;
        if (s == PauseState.SystemPaused || s == PauseState.DepositPaused) revert Paused(s);
        _;
    }

    /// @dev Reverts {Paused} if `pauseState` is `SystemPaused` or `WithdrawPaused`.
    modifier whenWithdrawNotPaused() {
        PauseState s = pauseState;
        if (s == PauseState.SystemPaused || s == PauseState.WithdrawPaused) revert Paused(s);
        _;
    }

    /// @dev Reverts {Paused} if `pauseState` is `SystemPaused`. Applied to
    ///      profit reporting and strategy fund moves. `setPauseState` and
    ///      strategy curation (`addStrategy`/`removeStrategy`) are NOT gated.
    modifier whenSystemNotPaused() {
        if (pauseState == PauseState.SystemPaused) revert Paused(PauseState.SystemPaused);
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert UnauthorizedAdmin(msg.sender);
        _;
    }

    /// @dev Strategy manager can run strategy flows, while admin retains the
    ///      same authority for governance/timelock execution.
    modifier onlyStrategyOrAdmin() {
        address sender = msg.sender;
        if (sender != admin && sender != strategyManager) revert UnauthorizedStrategyManager(sender);
        _;
    }

    /// @dev Preserve or improve the normalized ERC4626 share price across
    ///      user flows. Exact equality is too strict because ERC4626 rounds
    ///      in the vault's favor.
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

    // ═══════════════════════════ Profit distribution ═══════════════════════════

    /// @notice Receive `amount` of USD8 as profit distribution. Pulls
    ///         atomically via `transferFrom` (caller must approve). The
    ///         amount vests linearly over the weighted-average duration
    ///         combining any remaining unvested portion with a fresh
    ///         `profitMaxUnlockTime` window.
    /// @dev    Permissionless — anyone may donate. The weighted-average
    ///         schedule reset means tiny calls don't significantly extend
    ///         the end-time, so there's no griefing vector.
    ///         Reverts {NoDepositors} when `totalSupply() == 0` to prevent
    ///         profit being stranded in a vault with no shares (and to
    ///         block the inflation-DoS path on the next depositor).
    function receiveProfitDistribution(uint256 amount) external override nonReentrant whenSystemNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert ProfitTooLarge();
        if (totalSupply() == 0) revert NoDepositors();

        // Clear stale schedule storage if the previous vesting window has
        // fully elapsed. `_unvestedProfit()` already returns 0 in this case
        // and the math below works regardless, but clearing keeps `pendingProfit`
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

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        emit ProfitReported(msg.sender, amount, newPending, newEndTime);
    }

    // ═══════════════════════════ Vesting math ═══════════════════════════

    /// @notice Current unvested profit. Decreases linearly to zero as
    ///         `block.timestamp` advances toward `profitEndTime`.
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

    /// @notice Total assets recognized by the vault for ERC4626 math.
    ///         Idle USD8 plus strategy assets minus the still-unvested
    ///         portion of any reported profit.
    function totalAssets() public view override returns (uint256) {
        return _rawAssets() - _unvestedProfit();
    }

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    /// @dev Idle USD8 in this contract plus every approved strategy's
    ///      reported `totalAssets`. The vesting overlay subtracts the
    ///      unvested-profit portion in {totalAssets}.
    function _rawAssets() internal view returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            total += strategies[i].totalAssets();
        }
        return total;
    }

    // ═══════════════════════════ Admin ═══════════════════════════

    /// @notice Transfer admin authority. Current admin only.
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Set the account allowed to manage strategies. Admin only.
    function setStrategyManager(address newStrategyManager) external onlyAdmin {
        if (newStrategyManager == address(0)) revert ZeroAddress();
        emit StrategyManagerChanged(strategyManager, newStrategyManager);
        strategyManager = newStrategyManager;
    }

    /// @notice Set the pause state. Admin only. Intentionally not gated by
    ///         the pause itself — otherwise admin couldn't unpause.
    ///         Out-of-range values revert via Solidity's enum bounds check.
    function setPauseState(PauseState newState) external onlyAdmin {
        emit PauseStateChanged(pauseState, newState);
        pauseState = newState;
    }

    /// @notice Rescue stray ERC20 tokens accidentally sent to this contract.
    ///         Admin only. The underlying ({asset}) cannot be rescued; it
    ///         backs depositor shares. Direct donations of the underlying
    ///         intentionally accrue to share price.
    /// @dev    Not gated by pause: rescue is an emergency function.
    function rescueToken(IERC20 token, address to, uint256 amount) external nonReentrant onlyAdmin {
        if (to == address(0)) revert ZeroAddress();
        if (address(token) == asset()) revert RescueProtected(address(token));
        token.safeTransfer(to, amount);
        emit TokenRescued(address(token), to, amount);
    }

    /// @notice Rescue native ETH stuck in this contract. Admin only. The
    ///         contract does not implement `receive`/`fallback`, so this
    ///         only handles out-of-band ETH arrivals.
    /// @dev    Not gated by pause: rescue is an emergency function.
    function rescueETH(address payable to, uint256 amount) external nonReentrant onlyAdmin {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit ETHRescued(to, amount);
    }

    // ═══════════════════════════ ERC4626 entry points ═══════════════════════════

    /// @dev `nonReentrant` on all four user-facing entry points. The override
    ///      of `_withdraw` calls `strategy.withdraw` via `_ensureIdle`, which
    ///      is the reentry surface a malicious strategy could exploit.
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenDepositNotPaused
        sharePriceInvariant
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenDepositNotPaused
        sharePriceInvariant
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        whenWithdrawNotPaused
        sharePriceInvariant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        whenWithdrawNotPaused
        sharePriceInvariant
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        PauseState s = pauseState;
        if (s == PauseState.SystemPaused || s == PauseState.DepositPaused) return 0;
        return super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view override returns (uint256) {
        PauseState s = pauseState;
        if (s == PauseState.SystemPaused || s == PauseState.DepositPaused) return 0;
        return super.maxMint(receiver);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        PauseState s = pauseState;
        if (s == PauseState.SystemPaused || s == PauseState.WithdrawPaused) return 0;
        return super.maxWithdraw(owner);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        PauseState s = pauseState;
        if (s == PauseState.SystemPaused || s == PauseState.WithdrawPaused) return 0;
        return super.maxRedeem(owner);
    }

    /// @dev Pull `assets` of underlying from strategies into idle before
    ///      the standard ERC4626 burn-and-transfer. Strategies are walked
    ///      in `strategies` array order; idle is consumed first.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        // Keep still-unvested profit idle after the withdrawal. Otherwise a
        // user withdrawal can spend the buffer, leaving unvested profit backed
        // only by strategies and making totalAssets vulnerable to underflow
        // after a strategy loss.
        _ensureIdle(assets + _unvestedProfit());
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ═══════════════════════════ Strategy management (admin) ═══════════════════════════

    /// @notice Approve a new strategy. Admin only. Strategy approval is a
    ///         trusted process — admin is expected to verify the contract
    ///         implements {IStrategy} correctly off-chain.
    function addStrategy(IStrategy s) external onlyAdmin {
        if (address(s) == address(0)) revert ZeroAddress();
        address underlying = s.underlying();
        if (underlying != asset()) revert StrategyAssetMismatch(s, asset(), underlying);
        (, bool exists) = _findStrategy(s);
        if (exists) revert StrategyAlreadyApproved(s);
        strategies.push(s);
        emit StrategyAdded(s);
    }

    /// @notice Remove an approved strategy. Admin only. **Force removal**:
    ///         no zero-assets precondition — admin can drop a strategy
    ///         that's reverting on `totalAssets()` or otherwise stuck,
    ///         unblocking the rest of the vault at the cost of orphaning
    ///         the strategy's reported balance.
    /// @dev    DANGER: removing a strategy that still holds funds
    ///         permanently strands those funds. The strategy's
    ///         `totalAssets()` no longer contributes to {_rawAssets} and
    ///         the share price drops by the orphaned amount, taking the
    ///         loss out of existing depositors. Use {withdrawFromStrategy}
    ///         to drain first; only force-remove when the strategy is
    ///         compromised or its `totalAssets()` is permanently broken.
    function removeStrategy(IStrategy s) external onlyAdmin {
        (uint256 idx, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);

        uint256 n = strategies.length;
        strategies[idx] = strategies[n - 1];
        strategies.pop();
        emit StrategyRemoved(s);
    }

    /// @notice Reorder an approved strategy. Strategy role or admin only.
    ///         Sets the priority of `s` for the withdrawal fallback walk in
    ///         {_ensureIdle} — `strategies[0]` is consulted first.
    /// @dev    Shift semantics: strategies between the current and new
    ///         positions are moved by one slot so the relative order of
    ///         all other strategies is preserved. Reverts if `s` is not
    ///         approved or `newIndex` is out of range.
    function moveStrategy(IStrategy s, uint256 newIndex) external onlyStrategyOrAdmin {
        (uint256 currentIdx, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);
        uint256 n = strategies.length;
        if (newIndex >= n) revert IndexOutOfRange(newIndex, n);
        if (currentIdx == newIndex) return;

        if (currentIdx < newIndex) {
            for (uint256 i = currentIdx; i < newIndex; i++) {
                strategies[i] = strategies[i + 1];
            }
        } else {
            for (uint256 i = currentIdx; i > newIndex; i--) {
                strategies[i] = strategies[i - 1];
            }
        }
        strategies[newIndex] = s;
        emit StrategyMoved(s, currentIdx, newIndex);
    }

    /// @notice Push `amount` of idle USD8 to an approved strategy. Admin
    ///         only. Capped at {maxDeployableToStrategy} so a total strategy
    ///         loss can never reduce `_rawAssets()` below `_unvestedProfit()`.
    function depositToStrategy(IStrategy s, uint256 amount)
        external
        nonReentrant
        onlyStrategyOrAdmin
        whenSystemNotPaused
    {
        (, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);
        if (amount == 0) revert ZeroAmount();
        uint256 deployable = maxDeployableToStrategy();
        if (amount > deployable) revert ExceedsDeployable(amount, deployable);
        IERC20(asset()).safeTransfer(address(s), amount);
        s.deploy(amount);
        emit DepositedToStrategy(s, amount);
    }

    /// @notice Pull `amount` USD8 from an approved strategy back to idle.
    ///         Admin only.
    /// @dev    The emitted `WithdrawnFromStrategy` amount reflects the
    ///         actual delta observed in this vault's USD8 balance.
    function withdrawFromStrategy(IStrategy s, uint256 amount)
        external
        nonReentrant
        onlyStrategyOrAdmin
        whenSystemNotPaused
    {
        (, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);
        if (amount == 0) revert ZeroAmount();
        IERC20 underlying = IERC20(asset());
        uint256 balanceBefore = underlying.balanceOf(address(this));
        s.withdraw(amount);
        uint256 received = underlying.balanceOf(address(this)) - balanceBefore;
        emit WithdrawnFromStrategy(s, received);
    }

    // ═══════════════════════════ Views ═══════════════════════════

    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }

    /// @notice Maximum USD8 amount currently deployable to strategies:
    ///         `balanceOf(this) - _unvestedProfit()`. Unvested profit must
    ///         remain idle; admin's {depositToStrategy} is capped at this.
    function maxDeployableToStrategy() public view returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 unvested = _unvestedProfit();
        return idle > unvested ? idle - unvested : 0;
    }

    // ═══════════════════════════ Internal helpers ═══════════════════════════

    /// @dev Top up idle balance to at least `amount` by pulling from
    ///      strategies in array order. Re-reads idle after each pull so
    ///      a strategy that delivers short doesn't cause the next
    ///      iteration to under-ask. If idle + all strategies is still
    ///      insufficient after the walk, the caller's subsequent
    ///      `safeTransfer` will revert.
    function _ensureIdle(uint256 amount) internal {
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 idle = IERC20(asset()).balanceOf(address(this));
            if (idle >= amount) return;
            uint256 needed = amount - idle;
            IStrategy s = strategies[i];
            uint256 available = s.totalAssets();
            if (available == 0) continue;
            uint256 toPull = needed < available ? needed : available;
            // Skip strategies that revert (e.g. illiquid Aave during stress)
            // so the walk continues to the next strategy and remaining idle.
            try s.withdraw(toPull) {} catch {}
        }
    }

    /// @dev Linear scan of `strategies` for `s`. O(n), small N expected.
    function _findStrategy(IStrategy s) internal view returns (uint256 idx, bool found) {
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            if (strategies[i] == s) {
                return (i, true);
            }
        }
        return (0, false);
    }
}
