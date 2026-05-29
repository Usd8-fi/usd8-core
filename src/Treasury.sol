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
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
///         Strategy model: the Treasury holds an admin-approved list of
///         strategies (see {addStrategy} / {removeStrategy}), each
///         implementing `IStrategy`. Mints leave USDC idle in the Treasury;
///         admin explicitly allocates idle USDC into strategies via
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

    /// @notice Approval flag + distribution mode for a revenue recipient.
    /// @dev    Packs into a single storage slot. `approved` distinguishes
    ///         "not on the allowlist" from "on the allowlist with the
    ///         default-zero `DirectTransfer` mode".
    struct RevenueRecipient {
        bool approved;
        RevenueDistributionMode mode;
    }

    // ─────────────────────────── State ───────────────────────────

    /// @notice Mainnet USDC token. Fixed at compile time.
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    /// @notice Decimal-scale factor between USDC (6) and USD8 (18): `1e12`.
    uint256 public constant USDC_TO_USD8_SCALE = 1e12;

    /// @notice The USD8 token this Treasury mints and burns. Immutable.
    USD8 public immutable usd8;

    /// @notice Governance/admin address.
    address public admin;

    /// @notice Account allowed to manage approved strategies.
    address public strategyManager;

    /// @notice Current pause state. Defaults to `None` on deployment.
    ///         Settable by admin via {setPauseState}.
    PauseState public pauseState;

    /// @notice Approved strategies, in admin-determined order. Membership
    ///         in this array IS the approval — there is no separate
    ///         approval mapping. The array order doubles as the redeem
    ///         fallback withdrawal queue: idle USDC is consumed first, then
    ///         each strategy in `strategies` order until the redemption is
    ///         satisfied.
    /// @dev    No hard cap is enforced on-chain. Admin is responsible for
    ///         keeping the count under ~10 — every approved strategy adds
    ///         external-call overhead to {getReserveBalance} (called twice
    ///         per mint/redeem) and the redeem fallback walk. Membership
    ///         checks are O(n) array scans, also cheap at small N.
    IStrategy[] public strategies;

    /// @notice Approved revenue recipients and their distribution modes.
    ///         {harvestRevenue} mints USD8 into this Treasury itself; admin
    ///         then forwards it via {distributeRevenue} to addresses in
    ///         this mapping. The mapping is the allowlist — there is no
    ///         on-chain enumeration. Track the active set off-chain via
    ///         the {RevenueRecipientAdded} / {RevenueRecipientRemoved}
    ///         events.
    /// @dev    INVARIANT: the Treasury's USD8 balance is reserved
    ///         exclusively as the harvested-revenue pool. No other code
    ///         path parks USD8 at `address(this)` — `mintUSD8` sends to
    ///         the caller, `redeemUSD8` burns from the caller, and the
    ///         USDC reserve metric ({getReserveBalance}) is denominated
    ///         in USDC and does not count Treasury-held USD8. External
    ///         transfers of USD8 in are treated as additional revenue.
    mapping(address recipient => RevenueRecipient) public revenueRecipients;

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

    /// @notice Thrown when a non-admin account calls an admin function.
    error UnauthorizedAdmin(address caller);

    /// @notice Thrown when a caller is neither admin nor strategy manager.
    error UnauthorizedStrategyManager(address caller);

    /// @notice Thrown when an admin operation targets a strategy that has
    ///         not been approved via {addStrategy}.
    error StrategyNotApproved(IStrategy strategy);

    /// @notice Thrown by {addStrategy} when the strategy is already approved.
    error StrategyAlreadyApproved(IStrategy strategy);

    /// @notice Thrown by {addStrategy} when the strategy's reported
    ///         `underlying()` is not USDC. Prevents wiring a USD8-denominated
    ///         strategy into Treasury by mistake.
    error StrategyAssetMismatch(IStrategy strategy, address expected, address actual);

    /// @notice Thrown by {moveStrategy} when `newIndex` is out of bounds.
    error IndexOutOfRange(uint256 given, uint256 length);

    /// @notice Thrown by {distributeRevenue} and {removeRevenueRecipient}
    ///         when `recipient` is not approved in {revenueRecipients}.
    error RevenueRecipientNotApproved(address recipient);

    /// @notice Thrown by {addRevenueRecipient} when the recipient is
    ///         already approved in {revenueRecipients}.
    error RevenueRecipientAlreadyApproved(address recipient);

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

    /// @notice Emitted when admin updates the pause state.
    event PauseStateChanged(PauseState oldState, PauseState newState);

    /// @notice Emitted when admin is transferred.
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Emitted when admin updates the strategy manager.
    event StrategyManagerChanged(address indexed oldStrategyManager, address indexed newStrategyManager);

    /// @notice Emitted when admin approves a new strategy.
    event StrategyAdded(IStrategy indexed strategy);

    /// @notice Emitted when admin revokes approval for a strategy. See
    ///         {removeStrategy} — this is a force-removal that does not
    ///         require the strategy to be drained first.
    event StrategyRemoved(IStrategy indexed strategy);

    /// @notice Emitted when admin reorders a strategy. `fromIndex` was its
    ///         previous position; `toIndex` is its new position. Strategies
    ///         between the two are shifted by one slot to make room.
    event StrategyMoved(IStrategy indexed strategy, uint256 fromIndex, uint256 toIndex);

    /// @notice Emitted when admin pushes idle USDC to a strategy.
    event DepositedToStrategy(IStrategy indexed strategy, uint256 amount);

    /// @notice Emitted when admin pulls USDC from a strategy back to idle.
    ///         `amount` is the actual delta observed in the Treasury's USDC
    ///         balance, not the requested amount.
    event WithdrawnFromStrategy(IStrategy indexed strategy, uint256 amount);

    /// @notice Emitted when admin rescues a stray ERC20 token.
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when admin rescues stuck native ETH.
    event ETHRescued(address indexed to, uint256 amount);

    /// @notice Emitted when admin approves a new revenue recipient.
    event RevenueRecipientAdded(address indexed recipient, RevenueDistributionMode mode);

    /// @notice Emitted when admin removes an approved revenue recipient.
    event RevenueRecipientRemoved(address indexed recipient);

    /// @notice Emitted when admin forwards USD8 from the harvested-revenue
    ///         balance to an approved revenue recipient.
    event RevenueDistributed(address indexed recipient, uint256 amount);

    /// @notice Emitted when {harvestRevenue} mints surplus into this Treasury.
    ///         `amount` is in USD8 base units (18 decimals).
    event RevenueHarvested(uint256 amount);

    // ─────────────────────────── Constructor ─────────────────────

    /// @param _usd8            The USD8 token. This Treasury must be set as
    ///                         USD8's `treasury` address for mint/redeem.
    /// @param _admin           Admin, expected to be governance timelock.
    /// @param _strategyManager Account allowed to manage approved strategies
    ///                         and move funds to/from them.
    constructor(USD8 _usd8, address _admin, address _strategyManager) {
        if (address(_usd8) == address(0) || _admin == address(0) || _strategyManager == address(0)) {
            revert ZeroAddress();
        }
        usd8 = _usd8;
        admin = _admin;
        strategyManager = _strategyManager;
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
    ///      admin/strategy-gated operations that move funds or alter revenue routing.
    ///      `setPauseState` is intentionally NOT gated (otherwise admin
    ///      couldn't unpause). Strategy curation is also not gated — strategy
    ///      managers can still curate the strategy set during a freeze.
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

    modifier onlyApprovedRecipient(address recipient) {
        if (!revenueRecipients[recipient].approved) revert RevenueRecipientNotApproved(recipient);
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
        } else if (reserveAfterInUsd8 * supplyBefore < reserveBeforeInUsd8 * supplyAfter) {
            revert ReserveSupplyStatusWorsened(reserveBefore, supplyBefore, reserveAfter, supplyAfter);
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

    /// @notice Approve USDC via EIP-2612 permit and mint USD8 in one call.
    /// @param  usdcAmount Amount of USDC (6 decimals) to deposit.
    /// @param  deadline Permit deadline.
    /// @param  v ECDSA signature `v`.
    /// @param  r ECDSA signature `r`.
    /// @param  s ECDSA signature `s`.
    function permitAndMint(uint256 usdcAmount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        whenMintNotPaused
        reserveSupplyStatusCheck
    {
        if (usdcAmount == 0) revert ZeroAmount();
        IERC20Permit(address(USDC)).permit(msg.sender, address(this), usdcAmount, deadline, v, r, s);
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

    /// @notice Approve a new strategy. Strategy role or admin only.
    ///         Strategy approval is a trusted process — admin is expected to
    ///         verify the contract implements `IStrategy` correctly off-chain.
    function addStrategy(IStrategy s) external onlyAdmin {
        if (address(s) == address(0)) revert ZeroAddress();
        address underlying = s.underlying();
        if (underlying != address(USDC)) revert StrategyAssetMismatch(s, address(USDC), underlying);
        (, bool exists) = _findStrategy(s);
        if (exists) revert StrategyAlreadyApproved(s);
        strategies.push(s);
        emit StrategyAdded(s);
    }

    /// @notice Remove a previously approved strategy. Strategy role or
    ///         admin only. **Force removal**: no zero-assets precondition is
    ///         enforced — admin can drop a strategy that's reverting on
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
    /// @dev    Swap-and-pop: the last array element is moved into the
    ///         removed slot, so the relative order of remaining strategies
    ///         may change. The new ordering becomes the redeem fallback
    ///         withdrawal queue.
    function removeStrategy(IStrategy s) external onlyAdmin {
        (uint256 idx, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);

        uint256 n = strategies.length;
        strategies[idx] = strategies[n - 1];
        strategies.pop();
        emit StrategyRemoved(s);
    }

    /// @notice Reorder an approved strategy. Strategy role or admin only.
    ///         Sets the priority of `s` for the redeem fallback walk in
    ///         {_ensureIdleUsdc} — `strategies[0]` is consulted first.
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

    /// @notice Push `amount` idle USDC to an approved strategy. Strategy role
    ///         or admin only. Blocked when `pauseState` is
    ///         `SystemPaused`.
    /// @dev    Push pattern: USDC is `safeTransfer`'d to the strategy first,
    ///         then `strategy.deploy(amount)` is called as a notification.
    function depositToStrategy(IStrategy s, uint256 amount)
        external
        nonReentrant
        onlyStrategyOrAdmin
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
    ///         Strategy role or admin only. Blocked when `pauseState`
    ///         is `SystemPaused`.
    /// @dev    The emitted `WithdrawnFromStrategy` amount reflects the
    ///         actual delta observed in this contract's USDC balance,
    ///         which equals `amount` for any strategy that honors its
    ///         `IStrategy` contract (exact transfer or revert), and may
    ///         be less for a misbehaving strategy.
    function withdrawFromStrategy(IStrategy s, uint256 amount)
        external
        nonReentrant
        onlyStrategyOrAdmin
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
    ///         forwarded via {distributeRevenue}. Admin only — restricting
    ///         the trigger lets admin time harvests around any per-strategy
    ///         `totalAssets()` volatility (LP positions, oracle-priced
    ///         collateral, etc.) so a transient spike cannot be permanently
    ///         coined into supply. No-ops silently when there's no surplus.
    /// @dev    Revenue is `reserve·1e12 − supply` in USD8 base units. The
    ///         USDC stays in this Treasury as backing for the freshly-
    ///         minted USD8; the protocol's peg status holds with equality
    ///         after the mint (supply equals reserve·1e12). No USDC moves
    ///         out — strategies and idle USDC are untouched. The revenue is
    ///         denominated in USD8 from the moment of harvest, which is the
    ///         currency every downstream vault expects.
    /// @return revenueUsd8 The USD8 amount minted (0 if there was no surplus).
    function harvestRevenue() external onlyAdmin whenSystemNotPaused returns (uint256 revenueUsd8) {
        uint256 supply = usd8.totalSupply();
        uint256 reserve = getReserveBalance();
        uint256 reserveInUsd8 = reserve * USDC_TO_USD8_SCALE;
        if (reserveInUsd8 <= supply) return 0;

        revenueUsd8 = reserveInUsd8 - supply;

        usd8.mint(address(this), revenueUsd8);

        emit RevenueHarvested(revenueUsd8);
    }

    /// @notice Approve a new revenue recipient for {distributeRevenue}.
    ///         Admin only. The mode is set here and cannot be changed
    ///         later — admin must remove and re-add to switch mode.
    function addRevenueRecipient(address recipient, RevenueDistributionMode mode) external onlyAdmin {
        revenueRecipients[recipient] = RevenueRecipient({approved: true, mode: mode});
        emit RevenueRecipientAdded(recipient, mode);
    }

    /// @notice Remove an approved revenue recipient. Admin only.
    function removeRevenueRecipient(address recipient) external onlyAdmin onlyApprovedRecipient(recipient) {
        delete revenueRecipients[recipient];
        emit RevenueRecipientRemoved(recipient);
    }

    /// @notice Forward `amount` of the Treasury's USD8 balance to an
    ///         approved `recipient`. Admin only. Blocked when `pauseState`
    ///         is `SystemPaused`. The recipient's configured mode controls
    ///         whether USD8 is sent directly or delivered through
    ///         {IProfitDistributionReceiver-receiveProfitDistribution} for
    ///         vesting-aware consumers such as {SavingsUSD8}.
    function distributeRevenue(address recipient, uint256 amount)
        external
        nonReentrant
        onlyAdmin
        onlyApprovedRecipient(recipient)
        whenSystemNotPaused
    {
        if (amount == 0) revert ZeroAmount();

        RevenueRecipient memory r = revenueRecipients[recipient];

        if (r.mode == RevenueDistributionMode.DirectTransfer) {
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

    /// @notice Set the pause state. Admin only. Out-of-range values are
    ///         rejected automatically by Solidity's enum bounds check
    ///         (`Panic(0x21)`).
    function setPauseState(PauseState newState) external onlyAdmin {
        emit PauseStateChanged(pauseState, newState);
        pauseState = newState;
    }

    /// @notice Rescue stray ERC20 tokens accidentally sent to this contract.
    ///         Admin only. The reserve asset ({USDC}) and the harvested-
    ///         revenue token ({usd8}) are not rescuable; admin must use
    ///         {distributeRevenue} for USD8 and the protocol's normal
    ///         redeem/strategy flows for USDC.
    /// @dev    `to` must be an address that's currently approved in
    ///         {revenueRecipients}. This reuses the existing allowlist as
    ///         the set of valid protocol destinations, so a compromised
    ///         admin cannot exfiltrate funds to an arbitrary address
    ///         without first going through {addRevenueRecipient} (which
    ///         is governance-controlled).
    ///         Not gated by pause: rescue is an emergency function.
    function rescueToken(IERC20 token, address to, uint256 amount)
        external
        nonReentrant
        onlyAdmin
        onlyApprovedRecipient(to)
    {
        if (address(token) == address(USDC) || address(token) == address(usd8)) {
            revert RescueProtected(address(token));
        }
        token.safeTransfer(to, amount);
        emit TokenRescued(address(token), to, amount);
    }

    /// @notice Rescue native ETH stuck in this contract (e.g., from a
    ///         `selfdestruct` or coinbase). Admin only. The contract does
    ///         not implement `receive`/`fallback`, so this only handles
    ///         out-of-band ETH arrivals.
    /// @dev    `to` must be an address that's currently approved in
    ///         {revenueRecipients}. See {rescueToken} for the rationale.
    ///         Not gated by pause: rescue is an emergency function.
    function rescueETH(address payable to, uint256 amount)
        external
        nonReentrant
        onlyAdmin
        onlyApprovedRecipient(to)
    {
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
            total += strategies[i].totalAssets();
        }
        return total;
    }

    /// @notice Number of approved strategies. Convenience getter; callers
    ///         can also index into `strategies(uint256)` directly.
    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }

    /// @notice Distribution mode for an approved revenue recipient. Returns
    ///         `DirectTransfer` for unapproved recipients; callers that need
    ///         to distinguish unapproved from approved-with-DirectTransfer
    ///         should read {revenueRecipients} directly and check `approved`.
    function revenueDistributionMode(address recipient) external view returns (RevenueDistributionMode) {
        return revenueRecipients[recipient].mode;
    }

    // ═══════════════════════════ Internal helpers ═══════════════════════════

    function _mintUSD8(address receiver, uint256 usdcAmount) internal {
        USDC.safeTransferFrom(receiver, address(this), usdcAmount);
        uint256 usd8Amount = usdcAmount * USDC_TO_USD8_SCALE;
        usd8.mint(receiver, usd8Amount);

        emit Minted(receiver, usdcAmount, usd8Amount);
        // USDC sits idle until admin explicitly allocates it via
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
            s.withdraw(toPull);
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
