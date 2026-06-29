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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {USD8} from "./USD8.sol";
import {IProfitDistributionReceiver} from "./interfaces/IProfitDistributionReceiver.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// @title  USD8 Treasury v1
/// @notice Wraps USDC into USD8 at a fixed 1:1 dollar peg. Holds the USDC
///         reserve and is expected to be configured as USD8's treasury.
/// @dev    Terminology used throughout:
///           - "reserve" (`R`)            = total balance under the Treasury's
///                                          control, including any accrued
///                                          surplus from yield. Read via
///                                          {getReserveBalance}.
///           - "effective collateral"     = `min(R·1e12, supply)` in USD8
///                                          units; the portion of the reserve
///                                          that actually backs the supply at
///                                          the 1:1 peg.
///           - "surplus"                  = `R·1e12 − supply` when positive;
///                                          the part of the reserve above
///                                          backing. Routed via
///                                          {harvestRevenue} →
///                                          {distributeRevenue} to approved
///                                          recipients such as {SavingsUSD8};
///                                          never paid out directly to USD8
///                                          redeemers.
///
///         The reserve asset is fixed to mainnet USDC and baked in as a
///         constant. Swapping it after any USD8 has been minted would orphan
///         the backing and silently break the peg, so the only safe place to
///         "change" it is at deploy time — which is what a constant gives
///         you. A different chain or a different reserve asset requires a
///         fresh compile and deploy of this contract.
///
///         Decimal handling: USDC is 6-decimal, USD8 is 18-decimal, so 1 USDC
///         corresponds to `1e12` units of USD8. `mintUSD8` takes a USDC-unit
///         amount; `redeemUSD8` takes a USD8-unit amount and rounds the
///         returned USDC down to the nearest whole base unit. Sub-USDC-unit
///         USD8 dust is still burned but pays out zero USDC, so the rounding
///         error always accrues to the Treasury — never to the redeemer.
///
///         Pro-rata redemption: `redeemUSD8` pays out
///             `amount * min(supply, reserveInUsd8Units) / (supply * 1e12)`
///         USDC. When the reserve is healthy or in surplus (`R*1e12 >= S`)
///         this is exactly the 1:1 peg. When the reserve is below supply
///         (`R*1e12 < S`, only reachable once strategy losses are possible)
///         every redeemer takes the same proportional haircut, so there is
///         no first-mover advantage and no bank-run incentive. Minting stays
///         at 1:1; minting during a distressed state is therefore a donation
///         to existing holders and rational minters won't do it. Surplus
///         (`R*1e12 > S`) is NOT paid out to redeemers.
///
///         Strategy model: the Treasury holds a timelock-approved list of
///         strategies (see {addStrategy} / {removeStrategy}), each
///         implementing `IStrategy`. Mints leave USDC idle in the Treasury;
///         admin (fast ops role) explicitly allocates idle USDC into strategies via
///         {depositToStrategy} and pulls it back via {withdrawFromStrategy}.
///         Redeems consume idle first, then walk `strategies` in order to
///         top up any shortfall — so the array order doubles as the
///         withdrawal-priority queue.
/// @custom:security-contact rick@usd8.fi
contract Treasury is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ─────────────────────────── Types ───────────────────────────

    /// @notice Pause-state values. Mutually exclusive.
    ///         - `None`         : both mint and redeem allowed.
    ///         - `SystemPaused` : neither mint nor redeem allowed.
    ///         - `MintPaused`   : mint blocked, redeem allowed.
    ///         - `RedeemPaused` : redeem blocked, mint allowed.
    enum PauseState {
        None,
        SystemPaused,
        MintPaused,
        RedeemPaused
    }

    /// @notice How harvested USD8 revenue is routed to a recipient.
    ///         - `DirectTransfer`: raw USD8 transfer; use only when
    ///           immediate accounting is acceptable.
    ///         - `ReceiveProfitDistribution`: approve the recipient and
    ///           call {IProfitDistributionReceiver-receiveProfitDistribution};
    ///           use for vaults that must vest or linearize incoming profit for
    ///           anti JIT attacks.
    enum RevenueDistributionMode {
        DirectTransfer,
        ReceiveProfitDistribution
    }

    // ─────────────────────────── State ───────────────────────────

    /// @notice Mainnet USDC token. Fixed at compile time.
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    /// @notice Decimal-scale factor between USDC (6) and USD8 (18): `1e12`.
    uint256 public constant USDC_TO_USD8_SCALE = 1e12;

    /// @notice Overcollateralization buffer retained by {harvestRevenue},
    ///         expressed as a divisor of supply: `buffer = supply / 1000`,
    ///         i.e. 10 bps. After every harvest the reserve sits at
    ///         `supply + buffer` rather than exactly at `supply`, keeping the
    ///         peg strictly above 1:1 so block-to-block strategy `totalAssets()`
    ///         drift (interest accrual, fee dilution) doesn't repeatedly tip
    ///         the system across the distressed-redemption boundary.
    uint256 public constant HARVEST_BUFFER_DIVISOR = 1000;

    /// @notice The USD8 token this Treasury mints and burns. Immutable.
    USD8 public immutable usd8;

    /// @notice Slow governance role. Holds user-impacting powers: strategy
    ///         approval, role assignment, rescues. Expected to be a
    ///         TimelockController in production.
    address public timelock;

    /// @notice Fast operational role. Runs pause, strategy fund moves,
    ///         force-removal, and revenue harvest/distribution.
    address public admin;

    /// @notice Current pause state. Defaults to `None` on deployment.
    ///         Settable by admin or timelock via {setPauseState}.
    PauseState public pauseState;

    /// @notice Approved strategies, in timelock-determined order. Membership
    ///         in this array IS the approval — there is no separate
    ///         approval mapping. The array order doubles as the redeem
    ///         fallback withdrawal queue: idle USDC is consumed first, then
    ///         each strategy in `strategies` order until the redemption is
    ///         satisfied.
    /// @dev    No hard cap is enforced on-chain. Admin is responsible for
    ///         keeping the count under ~10 (timelock curates the set) — every approved strategy adds
    ///         external-call overhead to {getReserveBalance} (called twice
    ///         per mint/redeem) and the redeem fallback walk. Membership
    ///         checks are O(n) array scans, also cheap at small N.
    IStrategy[] public strategies;

    // ─────────────────────────── Errors ──────────────────────────

    /// @notice Thrown when a mint or redeem is called with zero amount.
    error ZeroAmount();

    /// @notice Thrown by {redeemUSD8} when there is no USD8 supply to redeem against.
    error NoUsd8Supply();

    /// @notice Thrown when mint or redeem worsens the Treasury's reserve/supply
    ///         status.
    error ReserveSupplyStatusWorsened(
        uint256 reserveBefore, uint256 supplyBefore, uint256 reserveAfter, uint256 supplyAfter
    );

    /// @notice Thrown by {redeemUSD8} when the computed USDC payout is below
    ///         the caller's `minUsdcOut`. Protects redeemers from being
    ///         surprised by an in-flight transition into a distressed state.
    error InsufficientUsdcOut(uint256 usdcOut, uint256 minUsdcOut);

    /// @notice Thrown when the operation is blocked by the current pause
    ///         state.
    /// @param  state The active {pauseState} value.
    error Paused(PauseState state);

    /// @notice Thrown when a zero address is passed where one is not allowed.
    error ZeroAddress();

    /// @notice Thrown when a non-timelock account calls an timelock function.
    error UnauthorizedTimelock(address caller);

    /// @notice Thrown when a caller is neither admin nor timelock.
    error UnauthorizedAdmin(address caller);

    /// @notice Thrown when an timelock operation targets a strategy that has
    ///         not been approved via {addStrategy}.
    error StrategyNotApproved(IStrategy strategy);

    /// @notice Thrown by {addStrategy} when the strategy is already approved.
    error StrategyAlreadyApproved(IStrategy strategy);

    /// @notice Thrown by {addStrategy} when the strategy's reported
    ///         `underlying()` is not USDC. Prevents wiring a USD8-denominated
    ///         strategy into Treasury by mistake.
    error StrategyAssetMismatch(IStrategy strategy, address expected, address actual);

    /// @notice Thrown by {rescueToken} when the token is the reserve asset
    ///         or the USD8 revenue token.
    error RescueProtected(address token);

    /// @notice Thrown by {rescueETH} when the low-level call to the
    ///         recipient fails.
    error EthTransferFailed();

    // ─────────────────────────── Events ──────────────────────────

    /// @notice Emitted when `user` deposits USDC and receives USD8.
    event Minted(address indexed user, uint256 usdcAmount, uint256 usd8Amount);

    /// @notice Emitted when `user` redeems USD8 and receives USDC.
    event Redeemed(address indexed user, uint256 usd8Amount, uint256 usdcAmount);

    /// @notice Emitted when timelock updates the pause state.
    event PauseStateChanged(PauseState oldState, PauseState newState);

    /// @notice Emitted when timelock is transferred.
    event TimelockChanged(address indexed oldTimelock, address indexed newTimelock);

    /// @notice Emitted when timelock updates the fast operational admin.
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Emitted when timelock approves a new strategy.
    event StrategyAdded(IStrategy indexed strategy);

    /// @notice Emitted when timelock revokes approval for a strategy. See
    ///         {removeStrategy} — this is a force-removal that does not
    ///         require the strategy to be drained first.
    event StrategyRemoved(IStrategy indexed strategy);

    /// @notice Emitted when timelock pushes idle USDC to a strategy.
    event DepositedToStrategy(IStrategy indexed strategy, uint256 amount);

    /// @notice Emitted when timelock pulls USDC from a strategy back to idle.
    ///         `amount` is the actual delta observed in the Treasury's USDC
    ///         balance, not the requested amount.
    event WithdrawnFromStrategy(IStrategy indexed strategy, uint256 amount);

    /// @notice Emitted when timelock rescues a stray ERC20 token.
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when timelock rescues stuck native ETH.
    event ETHRescued(address indexed to, uint256 amount);

    /// @notice Emitted when timelock forwards USD8 from the harvested-revenue
    ///         balance to a recipient.
    event RevenueDistributed(address indexed recipient, uint256 amount);

    /// @notice Emitted when {harvestRevenue} mints surplus into this Treasury.
    ///         `amount` is in USD8 base units (18 decimals).
    event RevenueHarvested(uint256 amount);

    // ─────────────────────────── Constructor ─────────────────────

    /// @param _usd8            The USD8 token. This Treasury must be set as
    ///                         USD8's `treasury` address for mint/redeem.
    /// @param _timelock Slow governance role, expected to be a TimelockController.
    /// @param _admin    Fast operational role for pause and strategy flows
    ///                         and move funds to/from them.
    constructor(USD8 _usd8, address _timelock, address _admin) {
        if (address(_usd8) == address(0) || _timelock == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }
        usd8 = _usd8;
        timelock = _timelock;
        admin = _admin;
    }

    // ─────────────────────────── Modifiers ───────────────────────

    /// @dev Reverts {Paused} if `pauseState` is `SystemPaused` or `MintPaused`.
    modifier whenMintNotPaused() {
        PauseState s = pauseState;
        if (s == PauseState.SystemPaused || s == PauseState.MintPaused) revert Paused(s);
        _;
    }

    /// @dev Reverts {Paused} if `pauseState` is `SystemPaused` or `RedeemPaused`.
    modifier whenRedeemNotPaused() {
        PauseState s = pauseState;
        if (s == PauseState.SystemPaused || s == PauseState.RedeemPaused) revert Paused(s);
        _;
    }

    /// @dev Reverts {Paused} if `pauseState` is `SystemPaused`. Applied to
    ///      timelock/strategy-gated operations that move funds or alter revenue routing.
    ///      `setPauseState` is intentionally NOT gated (otherwise timelock
    ///      couldn't unpause). Strategy curation is also not gated — strategy
    ///      managers can still curate the strategy set during a freeze.
    modifier whenSystemNotPaused() {
        if (pauseState == PauseState.SystemPaused) revert Paused(PauseState.SystemPaused);
        _;
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert UnauthorizedTimelock(msg.sender);
        _;
    }

    /// @dev Admin runs fast operational flows, while timelock retains the
    ///      same authority for governance/timelock execution.
    modifier onlyAdminOrTimelock() {
        address sender = msg.sender;
        if (sender != timelock && sender != admin) revert UnauthorizedAdmin(sender);
        _;
    }

    /// @dev Validates mint/redeem using only pre-state and post-state. If the
    ///      system starts healthy or in surplus, absolute surplus must not
    ///      decrease. If it starts distressed, the reserve/supply ratio must
    ///      not decrease.
    modifier reserveSupplyStatusCheck() {
        uint256 reserveBefore = getReserveBalance();
        uint256 supplyBefore = usd8.totalSupply();
        _;

        uint256 reserveAfter = getReserveBalance();
        uint256 supplyAfter = usd8.totalSupply();
        uint256 reserveBeforeInUsd8 = reserveBefore * USDC_TO_USD8_SCALE;
        uint256 reserveAfterInUsd8 = reserveAfter * USDC_TO_USD8_SCALE;

        if (reserveBeforeInUsd8 >= supplyBefore) {
            uint256 surplusBefore = reserveBeforeInUsd8 - supplyBefore;
            if (reserveAfterInUsd8 < supplyAfter || reserveAfterInUsd8 - supplyAfter < surplusBefore) {
                revert ReserveSupplyStatusWorsened(reserveBefore, supplyBefore, reserveAfter, supplyAfter);
            }
        } else {
            (uint256 lh, uint256 ll) = Math.mul512(reserveAfterInUsd8, supplyBefore);
            (uint256 rh, uint256 rl) = Math.mul512(reserveBeforeInUsd8, supplyAfter);
            if (lh < rh || (lh == rh && ll < rl)) {
                revert ReserveSupplyStatusWorsened(reserveBefore, supplyBefore, reserveAfter, supplyAfter);
            }
        }
    }

    // ═══════════════════════════ User operations (mint / redeem) ═══════════════════════════

    /// @notice Deposit USDC and mint USD8 at a 1:1 dollar peg. The caller
    ///         must have approved `usdcAmount` USDC to this contract.
    /// @param  usdcAmount Amount of USDC (6 decimals) to deposit.
    function mintUSD8(uint256 usdcAmount) external nonReentrant whenMintNotPaused reserveSupplyStatusCheck {
        if (usdcAmount == 0) revert ZeroAmount();
        _mintUSD8(msg.sender, usdcAmount);
    }

    /// @notice Burn USD8 from the caller and return USDC. Payout is
    ///         `amount * min(supply, reserveInUsd8Units) / (supply * 1e12)`
    ///         USDC, rounded down. Healthy reserve redeems 1:1; distressed
    ///         reserve applies a pro-rata haircut shared equally by all
    ///         redeemers (pro-rata preserves the effective USD8 ratio across
    ///         the redemption).
    /// @param  usd8Amount  Amount of USD8 (18 decimals) to redeem.
    /// @param  minUsdcOut  Minimum acceptable USDC payout (6 decimals). Pass
    ///                     `0` to accept any payout; pass the expected 1:1
    ///                     value to revert if an in-flight strategy loss has
    ///                     dropped the system into distress.
    function redeemUSD8(uint256 usd8Amount, uint256 minUsdcOut)
        external
        nonReentrant
        whenRedeemNotPaused
        reserveSupplyStatusCheck
    {
        if (usd8Amount == 0) revert ZeroAmount();

        uint256 supply = usd8.totalSupply();
        if (supply == 0) revert NoUsd8Supply();
        uint256 reserveInUsd8 = getReserveBalance() * USDC_TO_USD8_SCALE;
        // Effective collateral is capped at peg: surplus is reserved for
        // the harvested-revenue pool and never paid to redeemers.
        uint256 eff = reserveInUsd8 < supply ? reserveInUsd8 : supply;
        uint256 usdcAmount = (usd8Amount * eff) / supply / USDC_TO_USD8_SCALE;
        if (usdcAmount < minUsdcOut) revert InsufficientUsdcOut(usdcAmount, minUsdcOut);

        usd8.burn(msg.sender, usd8Amount);
        _ensureIdleUsdc(usdcAmount);
        USDC.safeTransfer(msg.sender, usdcAmount);

        emit Redeemed(msg.sender, usd8Amount, usdcAmount);
    }

    // ═══════════════════════════ Strategy management ═══════════════════════════

    /// @notice Approve a new strategy and insert it at `index` in the
    ///         redeem fallback withdrawal queue (`strategies[0]` is consulted
    ///         first). Timelock only. Any `index >= strategies.length` appends.
    ///         To reposition an existing strategy, {removeStrategy} it and
    ///         re-add it at the desired index — drain it first if funded.
    ///         Strategy approval is a trusted process — timelock is expected to
    ///         verify the contract implements `IStrategy` correctly off-chain.
    function addStrategy(IStrategy s, uint256 index) external onlyTimelock {
        if (address(s) == address(0)) revert ZeroAddress();
        address underlying = s.underlying();
        if (underlying != address(USDC)) revert StrategyAssetMismatch(s, address(USDC), underlying);
        (, bool exists) = _findStrategy(s);
        if (exists) revert StrategyAlreadyApproved(s);

        uint256 n = strategies.length;
        if (index > n) index = n;
        strategies.push(s);
        for (uint256 i = n; i > index; i--) {
            strategies[i] = strategies[i - 1];
        }
        strategies[index] = s;
        emit StrategyAdded(s);
    }

    /// @notice Remove a previously approved strategy. Admin or timelock.
    ///         **Force removal**: no zero-assets precondition is
    ///         enforced — timelock can drop a strategy that's reverting on
    ///         `totalAssets()` or otherwise stuck, recovering the rest of
    ///         the system at the cost of orphaning the strategy's reported
    ///         balance.
    /// @dev    DANGER: Removing a strategy that still holds funds
    ///         permanently orphans those funds from the protocol's
    ///         accounting. The strategy's `totalAssets()` no longer
    ///         contributes to {getReserveBalance}, which creates unbacked
    ///         USD8 against the orphaned USDC. Use {withdrawFromStrategy}
    ///         to drain first; only force-remove a strategy when its
    ///         reported balance is known-lost (e.g., the strategy is
    ///         compromised, the underlying protocol is dead, or
    ///         `totalAssets()` reverts and recovery is impossible).
    /// @dev    Order-preserving: strategies after the removed slot shift
    ///         down one position, so the relative priority of the remaining
    ///         withdrawal queue is unchanged. To reorder, remove and
    ///         re-{addStrategy} at the desired index (drain first if funded).
    function removeStrategy(IStrategy s) external onlyTimelock {
        (uint256 idx, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);

        uint256 last = strategies.length - 1;
        for (uint256 i = idx; i < last; i++) {
            strategies[i] = strategies[i + 1];
        }
        strategies.pop();
        emit StrategyRemoved(s);
    }

    /// @notice Push `amount` idle USDC to an approved strategy. Admin or timelock. Blocked when `pauseState` is
    ///         `SystemPaused`.
    /// @dev    Push pattern: USDC is `safeTransfer`'d to the strategy first,
    ///         then `strategy.deploy(amount)` is called as a notification.
    function depositToStrategy(IStrategy s, uint256 amount)
        external
        nonReentrant
        onlyAdminOrTimelock
        whenSystemNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        (, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);
        USDC.safeTransfer(address(s), amount);
        s.deploy(amount);
        emit DepositedToStrategy(s, amount);
    }

    /// @notice Pull `amount` USDC from an approved strategy back to idle.
    ///         Admin or timelock. Blocked when `pauseState`
    ///         is `SystemPaused`.
    /// @dev    The emitted `WithdrawnFromStrategy` amount reflects the
    ///         actual delta observed in this contract's USDC balance,
    ///         which equals `amount` for any strategy that honors its
    ///         `IStrategy` contract (exact transfer or revert), and may
    ///         be less for a misbehaving strategy.
    function withdrawFromStrategy(IStrategy s, uint256 amount)
        external
        nonReentrant
        onlyAdminOrTimelock
        whenSystemNotPaused
    {
        (, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);
        if (amount == 0) revert ZeroAmount();
        uint256 balanceBefore = USDC.balanceOf(address(this));
        s.withdraw(amount);
        uint256 received = USDC.balanceOf(address(this)) - balanceBefore;
        emit WithdrawnFromStrategy(s, received);
    }

    // ═══════════════════════════ Revenue harvesting & routing ═══════════════════════════

    /// @notice Mint USD8 representing the protocol's surplus (reserve in
    ///         USD8 units minus supply) into this Treasury, ready to be
    ///         forwarded via {distributeRevenue}. Admin or timelock — restricting
    ///         the trigger lets the protocol time harvests around any per-strategy
    ///         `totalAssets()` volatility (LP positions, oracle-priced
    ///         collateral, etc.) so a transient spike cannot be permanently
    ///         coined into supply. No-ops silently when there's no surplus.
    /// @dev    Revenue is `reserve·1e12 − supply − buffer` in USD8 base units,
    ///         where `buffer = supply · harvestBufferBps / 1e4`. The USDC
    ///         stays in this Treasury as backing for the freshly-minted USD8;
    ///         after the mint the reserve sits at `supply + buffer`, i.e. the
    ///         peg holds strictly above 1:1 by the retained buffer. The buffer
    ///         is shock absorption: a strategy loss must first eat through it
    ///         before redemptions go distressed, so block-to-block strategy
    ///         drift doesn't oscillate the system across the boundary. No USDC
    ///         moves out — strategies and idle USDC are untouched. The revenue
    ///         is denominated in USD8 from the moment of harvest, which is the
    ///         currency every downstream vault expects.
    /// @return revenueUsd8 The USD8 amount minted (0 if surplus is at or below
    ///         the retained buffer).
    function harvestRevenue() external onlyAdminOrTimelock whenSystemNotPaused returns (uint256 revenueUsd8) {
        uint256 supply = usd8.totalSupply();
        uint256 reserveInUsd8 = getReserveBalance() * USDC_TO_USD8_SCALE;

        // Retain a permanent overcollateralization buffer above supply.
        uint256 retain = supply + supply / HARVEST_BUFFER_DIVISOR;
        if (reserveInUsd8 <= retain) return 0;

        revenueUsd8 = reserveInUsd8 - retain;

        usd8.mint(address(this), revenueUsd8);

        emit RevenueHarvested(revenueUsd8);
    }

    /// @notice Forward `amount` of the Treasury's USD8 balance to
    ///         `recipient`. Admin or timelock. Blocked when `pauseState` is
    ///         `SystemPaused`. `mode` controls whether USD8 is sent directly
    ///         or delivered through
    ///         {IProfitDistributionReceiver-receiveProfitDistribution} —
    ///         vesting-aware consumers such as {SavingsUSD8} MUST be paid
    ///         via `ReceiveProfitDistribution`; a direct transfer to a vault
    ///         bypasses profit vesting.
    /// @dev    INVARIANT: the Treasury's USD8 balance is reserved
    ///         exclusively as the harvested-revenue pool. No other code
    ///         path parks USD8 at `address(this)` — `mintUSD8` sends to
    ///         the caller, `redeemUSD8` burns from the caller, and
    ///         {getReserveBalance} is denominated in USDC and does not
    ///         count Treasury-held USD8. External transfers of USD8 in
    ///         are treated as additional revenue.
    function distributeRevenue(address recipient, uint256 amount, RevenueDistributionMode mode)
        external
        nonReentrant
        onlyAdminOrTimelock
        whenSystemNotPaused
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (mode == RevenueDistributionMode.DirectTransfer) {
            // no need for SafeTransfer here, usd8 is our own token.
            usd8.transfer(recipient, amount);
        } else {
            usd8.approve(recipient, amount);
            IProfitDistributionReceiver(recipient).receiveProfitDistribution(amount);
            // Reset any residual allowance — recipient may pull less than
            // `amount`, and we don't want stale approval to persist.
            usd8.approve(recipient, 0);
        }

        emit RevenueDistributed(recipient, amount);
    }

    // ═══════════════════════════ Admin control ═══════════════════════════

    /// @notice Transfer timelock authority. Current timelock only.
    function setTimelock(address newTimelock) external onlyTimelock {
        if (newTimelock == address(0)) revert ZeroAddress();
        emit TimelockChanged(timelock, newTimelock);
        timelock = newTimelock;
    }

    /// @notice Set the fast operational admin. Timelock only.
    function setAdmin(address newAdmin) external onlyTimelock {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Set the pause state. Admin or timelock. Out-of-range values are
    ///         rejected automatically by Solidity's enum bounds check
    ///         (`Panic(0x21)`).
    function setPauseState(PauseState newState) external onlyAdminOrTimelock {
        emit PauseStateChanged(pauseState, newState);
        pauseState = newState;
    }

    /// @notice Rescue stray ERC20 tokens accidentally sent to this contract.
    ///         Timelock only. The reserve asset ({USDC}) and the harvested-
    ///         revenue token ({usd8}) are not rescuable; admin must use
    ///         {distributeRevenue} for USD8 and the protocol's normal
    ///         redeem/strategy flows for USDC.
    /// @dev    Not gated by pause: rescue is an emergency function.
    function rescueToken(IERC20 token, address to, uint256 amount) external nonReentrant onlyTimelock {
        if (to == address(0)) revert ZeroAddress();
        if (address(token) == address(USDC) || address(token) == address(usd8)) {
            revert RescueProtected(address(token));
        }
        token.safeTransfer(to, amount);
        emit TokenRescued(address(token), to, amount);
    }

    /// @notice Rescue native ETH stuck in this contract (e.g., from a
    ///         `selfdestruct` or coinbase). Timelock only. The contract does
    ///         not implement `receive`/`fallback`, so this only handles
    ///         out-of-band ETH arrivals.
    /// @dev    Not gated by pause: rescue is an emergency function.
    function rescueETH(address payable to, uint256 amount) external nonReentrant onlyTimelock {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit ETHRescued(to, amount);
    }

    // ═══════════════════════════ Views ═══════════════════════════

    /// @notice Total USDC-denominated reserve controlled by this Treasury.
    ///         Sums the Treasury's idle USDC balance plus the reported
    ///         `totalAssets()` of every approved strategy. Includes backing
    ///         collateral plus any accrued surplus (yield, donations) — not
    ///         just the collateral portion. Returned amount is in USDC base
    ///         units (6 decimals).
    function getReserveBalance() public view returns (uint256) {
        uint256 total = USDC.balanceOf(address(this));
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            total += strategies[i].totalAssets(); // strategy should not revert even if totalAsset is underwater.
        }
        return total;
    }

    /// @notice Number of approved strategies. Convenience getter; callers
    ///         can also index into `strategies(uint256)` directly.
    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }

    // ═══════════════════════════ Internal helpers ═══════════════════════════

    function _mintUSD8(address receiver, uint256 usdcAmount) internal {
        USDC.safeTransferFrom(receiver, address(this), usdcAmount);
        uint256 usd8Amount = usdcAmount * USDC_TO_USD8_SCALE;
        usd8.mint(receiver, usd8Amount);

        emit Minted(receiver, usdcAmount, usd8Amount);
        // USDC sits idle until timelock explicitly allocates it via
        // {depositToStrategy}. No auto-deploy.
    }

    /// @dev Pulls `amount` of USDC into idle if there isn't already enough
    ///      on hand. Walks `strategies` in array order, re-reading the
    ///      Treasury's USDC balance after each pull so a strategy that
    ///      delivers short doesn't cause the next iteration to under-ask.
    ///      If idle + all strategies is still insufficient after the walk,
    ///      the caller's subsequent `safeTransfer` will revert.
    function _ensureIdleUsdc(uint256 amount) internal {
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 idle = USDC.balanceOf(address(this));
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

    /// @dev Linear scan of `strategies` for `s`. Returns its index plus a
    ///      `found` flag. O(n), acceptable at the operational count of <10.
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
