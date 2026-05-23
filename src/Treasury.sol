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
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {USD8} from "./USD8.sol";
import {IStrategy} from "./IStrategy.sol";

/// @title  USD8 Treasury v1
/// @notice Wraps USDC into USD8 at a fixed 1:1 dollar peg. Holds the USDC
///         reserve and acts as the sole authority that can mint or burn USD8
///         (it is, or will be, the owner of the USD8 token).
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
///                                          backing. Reserved for a future
///                                          `sUSD8` wrapper, never paid out
///                                          to USD8 redeemers.
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
contract Treasury is Ownable2Step {
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

    // ─────────────────────────── State ───────────────────────────

    /// @notice Mainnet USDC token. Fixed at compile time.
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    /// @notice Decimal-scale factor between USDC (6) and USD8 (18): `1e12`.
    uint256 public constant USDC_TO_USD8_SCALE = 1e12;

    /// @notice The USD8 token this Treasury mints and burns. Immutable.
    USD8 public immutable usd8;

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

    /// @notice Approved revenue recipients, in admin-determined order.
    ///         Membership in this array IS the approval — there is no
    ///         separate approval mapping. {harvestRevenue} mints USD8 into
    ///         this Treasury itself; admin then forwards it via
    ///         {distributeRevenue} to entries in this list.
    /// @dev    INVARIANT: the Treasury's USD8 balance is reserved
    ///         exclusively as the harvested-revenue pool. No other code
    ///         path parks USD8 at `address(this)` — `mintUSD8` sends to
    ///         the caller, `redeemUSD8` burns from the caller, and the
    ///         USDC reserve metric ({getReserveBalance}) is denominated
    ///         in USDC and does not count Treasury-held USD8. External
    ///         transfers of USD8 in are treated as additional revenue.
    address[] public revenueRecipients;

    // ─────────────────────────── Errors ──────────────────────────

    /// @notice Thrown when a mint or redeem is called with zero amount.
    error ZeroAmount();

    /// @notice Thrown by {priceInvariantCheck} when an operation would
    ///         decrease the effective USD8 price (USDC redeemable per USD8,
    ///         capped at the 1:1 peg). Math: `min(R·1e12, S)/S`. Compared
    ///         via cross-products to avoid division.
    error Usd8PriceDecreased(uint256 effAfter, uint256 supplyAfter, uint256 effBefore, uint256 supplyBefore);

    /// @notice Thrown when the operation is blocked by the current pause
    ///         state.
    /// @param  state The active {pauseState} value.
    error Paused(PauseState state);

    /// @notice Thrown when `renounceOwnership` is called. Renouncing the
    ///         admin would permanently freeze the pause state with no path
    ///         to recover.
    error RenounceOwnershipDisabled();

    /// @notice Thrown when a zero address is passed where one is not allowed.
    error ZeroAddress();

    /// @notice Thrown when an admin operation targets a strategy that has
    ///         not been approved via {addStrategy}.
    error StrategyNotApproved(IStrategy strategy);

    /// @notice Thrown by {addStrategy} when the strategy is already approved.
    error StrategyAlreadyApproved(IStrategy strategy);

    /// @notice Thrown by {removeStrategy} when the strategy still reports a
    ///         non-zero `totalAssets()`. Admin must drain it via
    ///         {withdrawFromStrategy} first.
    error StrategyHasFunds(IStrategy strategy, uint256 assets);

    /// @notice Thrown by {distributeRevenue} and {removeRevenueRecipient}
    ///         when `recipient` is not on the {revenueRecipients} allowlist.
    error RevenueRecipientNotApproved(address recipient);

    /// @notice Thrown by {addRevenueRecipient} when the recipient is
    ///         already on the {revenueRecipients} allowlist.
    error RevenueRecipientAlreadyApproved(address recipient);

    // ─────────────────────────── Events ──────────────────────────

    /// @notice Emitted when `user` deposits USDC and receives USD8.
    event Minted(address indexed user, uint256 usdcAmount, uint256 usd8Amount);

    /// @notice Emitted when `user` redeems USD8 and receives USDC.
    event Redeemed(address indexed user, uint256 usd8Amount, uint256 usdcAmount);

    /// @notice Emitted when admin updates the pause state.
    event PauseStateChanged(PauseState oldState, PauseState newState);

    /// @notice Emitted when admin approves a new strategy.
    event StrategyAdded(IStrategy indexed strategy);

    /// @notice Emitted when admin revokes approval for a strategy. Only
    ///         possible when the strategy has zero `totalAssets()`.
    event StrategyRemoved(IStrategy indexed strategy);

    /// @notice Emitted when admin pushes idle USDC to a strategy.
    event DepositedToStrategy(IStrategy indexed strategy, uint256 amount);

    /// @notice Emitted when admin pulls USDC from a strategy back to idle.
    event WithdrawnFromStrategy(IStrategy indexed strategy, uint256 amount);

    /// @notice Emitted when admin approves a new revenue recipient.
    event RevenueRecipientAdded(address indexed recipient);

    /// @notice Emitted when admin removes an approved revenue recipient.
    event RevenueRecipientRemoved(address indexed recipient);

    /// @notice Emitted when admin forwards USD8 from the harvested-revenue
    ///         balance to an approved revenue recipient.
    event RevenueDistributed(address indexed recipient, uint256 amount);

    /// @notice Emitted when {harvestRevenue} mints surplus into this Treasury.
    ///         `amount` is in USD8 base units (18 decimals).
    event RevenueHarvested(uint256 amount);

    // ─────────────────────────── Constructor ─────────────────────

    /// @param _usd8  The USD8 token. Treasury must hold (or be transferred
    ///               to) the USD8 owner role for `mintUSD8` and `redeemUSD8`
    ///               to work.
    /// @param _admin Initial admin (Ownable owner). Must be non-zero;
    ///               reverts with `OwnableInvalidOwner(0)` otherwise. Can
    ///               be rotated via two-step transfer.
    constructor(USD8 _usd8, address _admin) Ownable(_admin) {
        usd8 = _usd8;
    }

    // ─────────────────────────── Modifiers ───────────────────────

    /// @dev Reverts {Paused} if `pauseState` is `SystemPaused` or `MintPaused`.
    modifier whenMintAllowed() {
        PauseState s = pauseState;
        if (s == PauseState.SystemPaused || s == PauseState.MintPaused) revert Paused(s);
        _;
    }

    /// @dev Reverts {Paused} if `pauseState` is `SystemPaused` or `RedeemPaused`.
    modifier whenRedeemAllowed() {
        PauseState s = pauseState;
        if (s == PauseState.SystemPaused || s == PauseState.RedeemPaused) revert Paused(s);
        _;
    }

    /// @dev Reverts {Paused} if `pauseState` is `SystemPaused`. Applied to
    ///      admin operations that move funds, change ownership, or alter
    ///      revenue routing. `setPauseState` is intentionally NOT gated
    ///      (otherwise admin couldn't unpause). `addStrategies` /
    ///      `removeStrategy` are also not gated — admin can still curate
    ///      the strategy set during a freeze.
    modifier whenSystemNotPaused() {
        if (pauseState == PauseState.SystemPaused) revert Paused(PauseState.SystemPaused);
        _;
    }

    /// @dev Asserts the effective USD8 price (USDC per USD8 capped at peg)
    ///      does not decrease across the wrapped function body. Applied to
    ///      both `mintUSD8` and `redeemUSD8` as a single unified invariant.
    modifier priceInvariantCheck() {
        uint256 supplyBefore = usd8.totalSupply();
        uint256 effBefore = _effectiveCollateral(getReserveBalance(), supplyBefore);
        _;
        uint256 supplyAfter = usd8.totalSupply();
        uint256 effAfter = _effectiveCollateral(getReserveBalance(), supplyAfter);
        if (effAfter * supplyBefore < effBefore * supplyAfter) {
            revert Usd8PriceDecreased(effAfter, supplyAfter, effBefore, supplyBefore);
        }
    }

    // ═══════════════════════════ User operations (mint / redeem) ═══════════════════════════

    /// @notice Deposit USDC and mint USD8 at a 1:1 dollar peg. The caller
    ///         must have approved `usdcAmount` USDC to this contract.
    /// @param  usdcAmount Amount of USDC (6 decimals) to deposit.
    function mintUSD8(uint256 usdcAmount) external whenMintAllowed priceInvariantCheck {
        if (usdcAmount == 0) revert ZeroAmount();
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        uint256 usd8Amount = usdcAmount * USDC_TO_USD8_SCALE;
        usd8.mint(msg.sender, usd8Amount);
        emit Minted(msg.sender, usdcAmount, usd8Amount);
        // USDC sits idle until admin explicitly allocates it via
        // {depositToStrategy}. No auto-deploy.
    }

    /// @notice Burn USD8 from the caller and return USDC. Payout is
    ///         `amount * min(supply, reserveInUsd8Units) / (supply * 1e12)`
    ///         USDC, rounded down. Healthy reserve redeems 1:1; distressed
    ///         reserve applies a pro-rata haircut shared equally by all
    ///         redeemers (pro-rata preserves the effective USD8 price across
    ///         the redemption). Surplus reserve is not paid out — yield is
    ///         retained by the Treasury.
    /// @param  usd8Amount Amount of USD8 (18 decimals) to redeem.
    function redeemUSD8(uint256 usd8Amount) external whenRedeemAllowed priceInvariantCheck {
        if (usd8Amount == 0) revert ZeroAmount();

        uint256 supply = usd8.totalSupply();
        uint256 reserve = getReserveBalance();
        uint256 usdcAmount = (usd8Amount * _effectiveCollateral(reserve, supply)) / supply / USDC_TO_USD8_SCALE;

        usd8.burn(msg.sender, usd8Amount);
        _ensureIdleUsdc(usdcAmount);
        USDC.safeTransfer(msg.sender, usdcAmount);

        emit Redeemed(msg.sender, usd8Amount, usdcAmount);
    }

    // ═══════════════════════════ Strategy management (admin) ═══════════════════════════

    /// @notice Approve one or more new strategies. Admin only. Each entry
    ///         is checked individually; if any fails the whole call reverts
    ///         and no strategies are added. Reverts on zero address or
    ///         duplicates (including duplicates within the input array).
    /// @dev    Strategy approval is a trusted process — admin is expected
    ///         to verify the contract implements `IStrategy` correctly
    ///         off-chain. No interface probe is performed here.
    /// @param  newStrategies Array of strategy contracts to approve. Pass
    ///                       a single-element array to add one strategy.
    function addStrategies(IStrategy[] calldata newStrategies) external onlyOwner {
        for (uint256 i = 0; i < newStrategies.length; i++) {
            IStrategy s = newStrategies[i];
            if (address(s) == address(0)) revert ZeroAddress();
            (, bool exists) = _findStrategy(s);
            if (exists) revert StrategyAlreadyApproved(s);
            strategies.push(s);
            emit StrategyAdded(s);
        }
    }

    /// @notice Remove a previously approved strategy. Admin only. Requires
    ///         the strategy to report zero `totalAssets()`. Admin must call
    ///         {withdrawFromStrategy} first to drain it.
    /// @dev    Swap-and-pop: the last array element is moved into the
    ///         removed slot, so the relative order of remaining strategies
    ///         may change. The new ordering becomes the redeem fallback
    ///         withdrawal queue.
    function removeStrategy(IStrategy s) external onlyOwner {
        (uint256 idx, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);
        uint256 assets = s.totalAssets();
        if (assets != 0) revert StrategyHasFunds(s, assets);

        uint256 n = strategies.length;
        strategies[idx] = strategies[n - 1];
        strategies.pop();
        emit StrategyRemoved(s);
    }

    /// @notice Push `amount` idle USDC to an approved strategy. Admin only.
    ///         Blocked when `pauseState` is `SystemPaused`.
    /// @dev    Push pattern: USDC is `safeTransfer`'d to the strategy first,
    ///         then `strategy.deploy(amount)` is called as a notification.
    function depositToStrategy(IStrategy s, uint256 amount) external onlyOwner whenSystemNotPaused {
        (, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);
        if (amount == 0) revert ZeroAmount();
        USDC.safeTransfer(address(s), amount);
        s.deploy(amount);
        emit DepositedToStrategy(s, amount);
    }

    /// @notice Pull `amount` USDC from an approved strategy back to idle.
    ///         Admin only. Blocked when `pauseState` is `SystemPaused`.
    function withdrawFromStrategy(IStrategy s, uint256 amount) external onlyOwner whenSystemNotPaused {
        (, bool found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);
        if (amount == 0) revert ZeroAmount();
        s.withdraw(amount);
        emit WithdrawnFromStrategy(s, amount);
    }

    // ═══════════════════════════ Revenue harvesting & routing ═══════════════════════════

    /// @notice Mint USD8 representing the protocol's surplus (reserve in
    ///         USD8 units minus supply) into this Treasury, ready to be
    ///         forwarded via {distributeRevenue}. Anyone may call —
    ///         there's no abuse path because the destination is
    ///         `address(this)`. No-ops silently when there's no surplus.
    /// @dev    Revenue is `reserve·1e12 − supply` in USD8 base units. The
    ///         USDC stays in this Treasury as backing for the freshly-
    ///         minted USD8; the protocol's peg invariant holds with
    ///         equality after the mint (supply equals reserve·1e12).
    ///         No USDC moves out — strategies and idle USDC are untouched.
    ///         The revenue is denominated in USD8 from the moment of
    ///         harvest, which is the currency every downstream vault
    ///         expects.
    /// @return revenueUsd8 The USD8 amount minted (0 if there was no surplus).
    function harvestRevenue() external whenSystemNotPaused priceInvariantCheck returns (uint256 revenueUsd8) {
        uint256 supply = usd8.totalSupply();
        uint256 reserve = getReserveBalance();
        uint256 reserveInUsd8 = reserve * USDC_TO_USD8_SCALE;
        if (reserveInUsd8 <= supply) return 0;

        revenueUsd8 = reserveInUsd8 - supply;

        usd8.mint(address(this), revenueUsd8);

        emit RevenueHarvested(revenueUsd8);
    }

    /// @notice Approve a new revenue recipient for {distributeRevenue}.
    ///         Admin only.
    function addRevenueRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        (, bool exists) = _findRevenueRecipient(recipient);
        if (exists) revert RevenueRecipientAlreadyApproved(recipient);
        revenueRecipients.push(recipient);
        emit RevenueRecipientAdded(recipient);
    }

    /// @notice Remove an approved revenue recipient. Admin only.
    /// @dev    Swap-and-pop: the last array element is moved into the
    ///         removed slot, so the relative order of remaining recipients
    ///         may change.
    function removeRevenueRecipient(address recipient) external onlyOwner {
        (uint256 idx, bool found) = _findRevenueRecipient(recipient);
        if (!found) revert RevenueRecipientNotApproved(recipient);

        uint256 n = revenueRecipients.length;
        revenueRecipients[idx] = revenueRecipients[n - 1];
        revenueRecipients.pop();
        emit RevenueRecipientRemoved(recipient);
    }

    /// @notice Forward `amount` of the Treasury's USD8 balance to an
    ///         approved `recipient`. Admin only. Blocked when `pauseState`
    ///         is `SystemPaused`. Used to route harvested revenue out to
    ///         downstream consumers (e.g., SavingsUSD8, CoverPool); each
    ///         consumer linearizes incoming USD8 internally for JIT
    ///         defense, so lump-sum transfers from here are safe.
    function distributeRevenue(address recipient, uint256 amount) external onlyOwner whenSystemNotPaused {
        (, bool found) = _findRevenueRecipient(recipient);
        if (!found) revert RevenueRecipientNotApproved(recipient);
        if (amount == 0) revert ZeroAmount();
        IERC20(address(usd8)).safeTransfer(recipient, amount);
        emit RevenueDistributed(recipient, amount);
    }

    // ═══════════════════════════ Pause control (admin) ═══════════════════════════

    /// @notice Set the pause state. Admin only. Out-of-range values are
    ///         rejected automatically by Solidity's enum bounds check
    ///         (`Panic(0x21)`).
    function setPauseState(PauseState newState) external onlyOwner {
        emit PauseStateChanged(pauseState, newState);
        pauseState = newState;
    }

    // ═══════════════════════════ Ownership ═══════════════════════════

    /// @notice Completes the two-step ownership transfer of USD8 to this
    ///         Treasury. Anyone may call; the underlying check in
    ///         {Ownable2Step-acceptOwnership} requires that this Treasury is
    ///         the pending owner, which is set by the previous USD8 owner.
    ///         Blocked when `pauseState` is `SystemPaused`.
    function acceptUsd8Ownership() external whenSystemNotPaused {
        usd8.acceptOwnership();
    }

    /// @notice Hand off USD8 ownership to a new owner (typically a new
    ///         Treasury contract being migrated to). Admin only. Starts the
    ///         two-step transfer on USD8 — `newOwner` must then call
    ///         `usd8.acceptOwnership()` to complete it. If `newOwner` is a
    ///         contract, it needs its own bridge function (e.g., another
    ///         Treasury's {acceptUsd8Ownership}). Blocked when `pauseState`
    ///         is `SystemPaused`.
    function transferUsd8Ownership(address newOwner) external onlyOwner whenSystemNotPaused {
        usd8.transferOwnership(newOwner);
    }

    /// @notice Accept admin role transfer on this Treasury. Inherited from
    ///         `Ownable2Step` and overridden to block during system pause.
    function acceptOwnership() public override whenSystemNotPaused {
        super.acceptOwnership();
    }

    /// @notice Disabled. Reverts with {RenounceOwnershipDisabled}.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
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

    /// @notice Number of approved revenue recipients. Convenience getter;
    ///         callers can also index into `revenueRecipients(uint256)`.
    function revenueRecipientsLength() external view returns (uint256) {
        return revenueRecipients.length;
    }

    // ═══════════════════════════ Internal helpers ═══════════════════════════

    /// @dev `min(reserve·1e12, supply)` — the portion of the reserve in
    ///      USD8-decimal units that actually backs `supply`, capped to
    ///      exclude any surplus. Divided by supply this gives the effective
    ///      USD8 price (USDC per USD8 face unit, capped at peg). The reserve
    ///      is taken as an argument so callers (the modifier and `redeemUSD8`)
    ///      can read it from `getReserveBalance()` explicitly at their site.
    function _effectiveCollateral(uint256 reserve, uint256 supply) internal pure returns (uint256) {
        uint256 reserveInUsd8Units = reserve * USDC_TO_USD8_SCALE;
        return reserveInUsd8Units < supply ? reserveInUsd8Units : supply;
    }

    /// @dev Pulls `amount` of USDC into idle if there isn't already enough
    ///      on hand. Walks `strategies` in array order, pulling only the
    ///      shortfall from each. If the sum across idle + all strategies
    ///      is still insufficient after the walk, the caller's subsequent
    ///      `safeTransfer` will revert — there is no on-chain check here.
    ///      Shared by {redeemUSD8} and {harvestRevenue}.
    function _ensureIdleUsdc(uint256 amount) internal {
        uint256 idle = USDC.balanceOf(address(this));
        if (idle >= amount) return;
        uint256 needed = amount - idle;
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            if (needed == 0) break;
            IStrategy s = strategies[i];
            uint256 available = s.totalAssets();
            if (available == 0) continue;
            uint256 toPull = needed < available ? needed : available;
            s.withdraw(toPull);
            needed -= toPull;
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

    /// @dev Linear scan of `revenueRecipients` for `recipient`. Returns
    ///      its index plus a `found` flag. O(n), acceptable at the
    ///      operational count of <10.
    function _findRevenueRecipient(address recipient) internal view returns (uint256 idx, bool found) {
        uint256 n = revenueRecipients.length;
        for (uint256 i = 0; i < n; i++) {
            if (revenueRecipients[i] == recipient) {
                return (i, true);
            }
        }
        return (0, false);
    }
}
