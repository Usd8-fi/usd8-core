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
import {USD8} from "./USD8.sol";
import {Registry} from "./Registry.sol";
import {RegistryManaged} from "./RegistryManaged.sol";
import {IProfitDistributionReceiver} from "./interfaces/IProfitDistributionReceiver.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// @title  USD8 Treasury v1
/// @notice Wraps USDC into USD8 at a fixed 1:1 dollar peg and holds the USDC reserve.
/// @dev    Units: USDC is 6-decimal, USD8 is 18-decimal, so 1 USDC == 1e12 USD8. Terms:
///           R  = reserve: all USDC the Treasury controls, incl. accrued yield ({getReserveBalance}).
///           eff = effective collateral = min(R·1e12, USD8Supply).
///           S  = surplus = R·1e12 − USD8Supply (signed): S > 0 is reserve above backing
///                (routed to yield via {harvestAndDistribute}/{distributeRevenue}); S < 0 is distress.
///         The reserve asset is USDC and cannot be changed.
///
///         Mint is always 1:1. Redeem pays redeemedUSDC = givenUSD8 · eff / (USD8Supply · 1e12),
///         rounded down (sub-unit dust burns for 0 USDC, favoring the Treasury). When S >= 0,
///         eff = USD8Supply and this is the exact 1:1 peg. In distress (S < 0, only reachable via a
///         strategy loss) eff = R·1e12, so every redeemer takes the same proportional haircut — no
///         first-mover advantage, no bank run. Surplus is never paid to redeemers, and minting in
///         distress only donates to holders, so no rational actor mints then.
///
///         Strategies: a timelock-approved list ({addStrategy}/{removeStrategy}). Mints leave USDC
///         idle; admin moves it via {depositToStrategy}/{withdrawFromStrategy}. Redeem spends idle
///         first, then walks the list in order — the array is the withdrawal-priority queue.
/// @custom:security-contact rick@usd8.fi
contract Treasury is ReentrancyGuardTransient, RegistryManaged {
    using SafeERC20 for IERC20;

    /// @notice How harvested USD8 revenue is routed to a recipient.
    ///         - DirectTransfer: raw USD8 transfer; use only when
    ///           immediate accounting is acceptable.
    ///         - ReceiveProfitDistribution: approve the recipient and
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

    /// @notice Decimal-scale factor between USDC (6) and USD8 (18): 1e12.
    uint256 public constant USDC_TO_USD8_SCALE = 1e12;

    /// @notice Overcollateralization buffer retained by {harvestAndDistribute},
    ///         expressed as a divisor of supply: buffer = supply / 1000,
    ///         i.e. 10 bps. After every harvest the reserve sits at
    ///         supply + buffer rather than exactly at supply, keeping the
    ///         peg strictly above 1:1 so block-to-block strategy totalAssets()
    ///         drift (interest accrual, fee dilution) doesn't repeatedly tip
    ///         the system across the distressed-redemption boundary.
    uint256 public constant HARVEST_BUFFER_DIVISOR = 1000;

    /// @notice The USD8 token this Treasury mints and burns. Immutable.
    USD8 public immutable usd8;

    /// @notice Approved strategies, in timelock-determined order. Membership
    ///         in this array IS the approval — there is no separate
    ///         approval mapping. The array order doubles as the redeem
    ///         fallback withdrawal queue: idle USDC is consumed first, then
    ///         each strategy in strategies order until the redemption is
    ///         satisfied.
    /// @dev    No hard cap is enforced on-chain. Admin is responsible for
    ///         keeping the count under ~10 (timelock curates the set) — every approved strategy adds
    ///         external-call overhead to {getReserveBalance} (called twice
    ///         per mint/redeem) and the redeem fallback walk. Membership
    ///         checks are O(n) array scans, also cheap at small N.
    IStrategy[] public strategies;

    /// @notice A registered profit receiver and its distribution config.
    /// @param receiver  Address paid a weighted share by {harvestAndDistribute}.
    /// @param weight    Relative share of each weighted distribution (0 = registered
    ///                  but currently earns nothing).
    /// @param mode      How USD8 is delivered: raw transfer, or the vesting-aware
    ///                  {IProfitDistributionReceiver-receiveProfitDistribution}.
    struct ProfitReceiver {
        address receiver;
        uint256 weight;
        RevenueDistributionMode mode;
    }

    /// @notice Registered profit receivers — the weighted-split targets of
    ///         {harvestAndDistribute}. Admin curates via
    ///         {setProfitReceiver}/{removeProfitReceiver}. Keep the count small:
    ///         each distribution is a linear scan plus one external call per
    ///         positive-weight receiver.
    ProfitReceiver[] public profitReceivers;

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
    ///         the caller's minUsdcOut. Protects redeemers from being
    ///         surprised by an in-flight transition into a distressed state.
    error InsufficientUsdcOut(uint256 usdcOut, uint256 minUsdcOut);

    /// @notice Thrown when idle USDC plus everything the strategy walk could
    ///         withdraw is still below the amount a redeem must pay out (e.g.
    ///         every strategy is illiquid or reverting).
    error InsufficientLiquidity(uint256 needed, uint256 available);

    /// @notice Thrown when an timelock operation targets a strategy that has
    ///         not been approved via {addStrategy}.
    error StrategyNotApproved(IStrategy strategy);

    /// @notice Thrown by {addStrategy} when the strategy is already approved.
    error StrategyAlreadyApproved(IStrategy strategy);

    /// @notice Thrown by {addStrategy} when the strategy's reported
    ///         underlying() is not USDC. Prevents wiring a USD8-denominated
    ///         strategy into Treasury by mistake.
    error StrategyAssetMismatch(IStrategy strategy, address expected, address actual);

    /// @notice Thrown by {removeProfitReceiver} when the address isn't registered.
    error ProfitReceiverNotFound(address receiver);

    /// @notice Thrown by {harvestAndDistribute} when there is revenue to
    ///         distribute but no registered receiver has a positive weight.
    error NoEligibleProfitReceivers();

    // ─────────────────────────── Events ──────────────────────────

    /// @notice Emitted when user deposits USDC and receives USD8.
    event Minted(address indexed user, uint256 usdcAmount, uint256 usd8Amount);

    /// @notice Emitted when user redeems USD8 and receives USDC.
    event Redeemed(address indexed user, uint256 usd8Amount, uint256 usdcAmount);

    /// @notice Emitted when timelock approves a new strategy.
    event StrategyAdded(IStrategy indexed strategy);

    /// @notice Emitted when timelock revokes approval for a strategy. See
    ///         {removeStrategy} — this is a force-removal that does not
    ///         require the strategy to be drained first.
    event StrategyRemoved(IStrategy indexed strategy);

    /// @notice Emitted when timelock pushes idle USDC to a strategy.
    event DepositedToStrategy(IStrategy indexed strategy, uint256 amount);

    /// @notice Emitted when timelock pulls USDC from a strategy back to idle.
    ///         amount is the actual delta observed in the Treasury's USDC
    ///         balance, not the requested amount.
    event WithdrawnFromStrategy(IStrategy indexed strategy, uint256 amount);

    /// @notice Emitted when timelock forwards USD8 from the harvested-revenue
    ///         balance to a recipient.
    event RevenueDistributed(address indexed recipient, uint256 amount);

    /// @notice Emitted when a profit receiver is registered or its weight/mode
    ///         updated via {setProfitReceiver}.
    event ProfitReceiverSet(address indexed receiver, uint256 weight, RevenueDistributionMode mode);

    /// @notice Emitted when a profit receiver is deregistered via {removeProfitReceiver}.
    event ProfitReceiverRemoved(address indexed receiver);

    /// @notice Emitted when {harvestAndDistribute} mints surplus into this Treasury.
    ///         amount is in USD8 base units (18 decimals).
    event RevenueHarvested(uint256 amount);

    // ─────────────────────────── Constructor ─────────────────────

    /// @param _usd8       The USD8 token. This Treasury must be set as
    ///                    USD8's treasury address for mint/redeem.
    /// @param _registry  Shared access + pause registry (holds timelock/admin).
    constructor(USD8 _usd8, Registry _registry) {
        if (address(_usd8) == address(0)) revert ZeroAddress();
        _setRegistry(_registry);
        usd8 = _usd8;
    }

    // ─────────────────────────── Modifiers ───────────────────────

    /// @dev Validates mint/redeem using only pre-state and post-state. If the
    ///      system starts healthy or in surplus, surplus must not decrease; if it
    ///      starts distressed, the reserve/supply ratio must not decrease.
    ///
    ///      Each check allows a small tolerance for the sub-USDC accounting dust
    ///      a strategy withdrawal can shave off getReserveBalance: an ERC-4626
    ///      strategy burns CEIL shares while reporting FLOOR assets, so a redeem
    ///      that pulls from it lowers the reserve a hair beyond the payout —
    ///      up to the value of ONE SHARE BASE UNIT per strategy. For 18-dec-share
    ///      vaults (MetaMorpho) that is ~1e-12 USDC; for offset-0 wrappers whose
    ///      rate grows above 1 (Aave stataUSDC) it is ~the share rate in USDC
    ///      units. The allowance is 5 USDC base units per approved strategy —
    ///      covers share rates to ~5 (decades of drift) and is NOT an extraction
    ///      budget: tol only decides revert-vs-pass; the redeemer's payout is
    ///      fixed by the formula either way, so slack cannot be farmed.
    modifier reserveSupplyStatusCheck() {
        uint256 reserveBefore = getReserveBalance();
        uint256 supplyBefore = usd8.totalSupply();
        _;

        uint256 reserveAfter = getReserveBalance();
        uint256 supplyAfter = usd8.totalSupply();
        uint256 reserveBeforeInUsd8 = reserveBefore * USDC_TO_USD8_SCALE;
        uint256 reserveAfterInUsd8 = reserveAfter * USDC_TO_USD8_SCALE;
        uint256 tol = strategies.length * 5 * USDC_TO_USD8_SCALE;

        if (reserveBeforeInUsd8 >= supplyBefore) {
            // surplusAfter >= surplusBefore - tol, rearranged to avoid underflow
            // (and to tolerate a dust-sized dip even across the zero boundary).
            uint256 surplusBefore = reserveBeforeInUsd8 - supplyBefore;
            if (reserveAfterInUsd8 + tol < supplyAfter + surplusBefore) {
                revert ReserveSupplyStatusWorsened(reserveBefore, supplyBefore, reserveAfter, supplyAfter);
            }
        } else {
            // (reserveAfter + tol) / supplyAfter >= reserveBefore / supplyBefore.
            (uint256 lh, uint256 ll) = Math.mul512(reserveAfterInUsd8 + tol, supplyBefore);
            (uint256 rh, uint256 rl) = Math.mul512(reserveBeforeInUsd8, supplyAfter);
            if (lh < rh || (lh == rh && ll < rl)) {
                revert ReserveSupplyStatusWorsened(reserveBefore, supplyBefore, reserveAfter, supplyAfter);
            }
        }
    }

    // ─────────────────────────── User operations (mint / redeem) ───────────────────────────

    /// @notice Deposit USDC and mint USD8 at a 1:1 dollar peg. The caller
    ///         must have approved usdcAmount USDC to this contract.
    /// @param  usdcAmount Amount of USDC (6 decimals) to deposit.
    function mintUSD8(uint256 usdcAmount) external nonReentrant whenNotPaused reserveSupplyStatusCheck {
        if (usdcAmount == 0) revert ZeroAmount();

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        uint256 usd8Amount = usdcAmount * USDC_TO_USD8_SCALE;
        usd8.mint(msg.sender, usd8Amount);

        emit Minted(msg.sender, usdcAmount, usd8Amount);
        // USDC sits idle until admin/timelock explicitly allocates it via
        // {depositToStrategy}. No auto-deploy.
    }

    /// @notice Burn USD8 from the caller and return USDC. Payout is
    ///         amount * min(supply, reserveInUsd8Units) / (supply * 1e12)
    ///         USDC, rounded down. Healthy reserve redeems 1:1; distressed
    ///         reserve applies a pro-rata haircut shared equally by all
    ///         redeemers (pro-rata preserves the effective USD8 ratio across
    ///         the redemption).
    /// @param  usd8Amount  Amount of USD8 (18 decimals) to redeem.
    /// @param  minUsdcOut  Minimum acceptable USDC payout (6 decimals). Pass
    ///                     0 to accept any payout; pass the expected 1:1
    ///                     value to revert if an in-flight strategy loss has
    ///                     dropped the system into distress.
    function redeemUSD8(uint256 usd8Amount, uint256 minUsdcOut)
        external
        nonReentrant
        whenNotPaused
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

    // ─────────────────────────── Strategy management ───────────────────────────

    /// @notice Approve a new strategy and insert it at index in the
    ///         redeem fallback withdrawal queue (strategies[0] is consulted
    ///         first). Timelock only. Any index >= strategies.length appends.
    ///         To reposition an existing strategy, {removeStrategy} it and
    ///         re-add it at the desired index — drain it first if funded.
    ///         Strategy approval is a trusted process — timelock is expected to
    ///         verify the contract implements IStrategy correctly off-chain.
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

    /// @notice Remove a previously approved strategy. Timelock only.
    ///         **Force removal**: no zero-assets precondition is
    ///         enforced — timelock can drop a strategy that's reverting on
    ///         totalAssets() or otherwise stuck, recovering the rest of
    ///         the system at the cost of orphaning the strategy's reported
    ///         balance.
    /// @dev    DANGER: Removing a strategy that still holds funds
    ///         permanently orphans those funds from the protocol's
    ///         accounting. The strategy's totalAssets() no longer
    ///         contributes to {getReserveBalance}, which creates unbacked
    ///         USD8 against the orphaned USDC. Use {withdrawFromStrategy}
    ///         to drain first; only force-remove a strategy when its
    ///         reported balance is known-lost (e.g., the strategy is
    ///         compromised, the underlying protocol is dead, or
    ///         totalAssets() reverts and recovery is impossible).
    /// @dev    Order-preserving: strategies after the removed slot shift
    ///         down one position, so the relative priority of the remaining
    ///         withdrawal queue is unchanged. To reorder, remove and
    ///         re-{addStrategy} at the desired index (drain first if funded).
    function removeStrategy(IStrategy s) external onlyTimelock {
        uint256 idx = _findApprovedStrategy(s);

        uint256 last = strategies.length - 1;
        for (uint256 i = idx; i < last; i++) {
            strategies[i] = strategies[i + 1];
        }
        strategies.pop();
        emit StrategyRemoved(s);
    }

    /// @notice Push amount idle USDC to an approved strategy. Admin or timelock.
    ///         Blocked while paused.
    /// @dev    Push pattern: USDC is safeTransfer'd to the strategy first,
    ///         then strategy.deploy(amount) is called as a notification.
    function depositToStrategy(IStrategy s, uint256 amount) external nonReentrant onlyAdminOrTimelock whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _findApprovedStrategy(s);
        USDC.safeTransfer(address(s), amount); // push USDC to strategies to avoid granting approvals.
        s.deploy(amount);
        emit DepositedToStrategy(s, amount);
    }

    /// @notice Pull amount USDC from an approved strategy back to idle.
    ///         Admin or timelock. Blocked while paused.
    /// @dev    The emitted WithdrawnFromStrategy amount reflects the
    ///         actual delta observed in this contract's USDC balance,
    ///         which equals amount for any strategy that honors its
    ///         IStrategy contract (exact transfer or revert), and may
    ///         be less for a misbehaving strategy.
    function withdrawFromStrategy(IStrategy s, uint256 amount) external nonReentrant onlyAdminOrTimelock whenNotPaused {
        _findApprovedStrategy(s);
        if (amount == 0) revert ZeroAmount();
        uint256 balanceBefore = USDC.balanceOf(address(this));
        s.withdraw(amount);
        uint256 received = USDC.balanceOf(address(this)) - balanceBefore;
        emit WithdrawnFromStrategy(s, received);
    }

    // ─────────────────────────── Revenue harvesting & routing ───────────────────────────

    /// @notice Harvest the protocol's surplus and split the entire resulting
    ///         revenue pool across the registered profit receivers by weight —
    ///         the whole recurring revenue flow in one call. Admin or timelock;
    ///         blocked while paused.
    ///
    ///         Harvest: mints reserve·1e12 − supply − buffer as USD8 into this
    ///         Treasury, where buffer = supply / {HARVEST_BUFFER_DIVISOR}. The USDC
    ///         stays as backing, so after the mint the reserve sits at supply +
    ///         buffer — the peg holds strictly above 1:1 by the retained buffer,
    ///         a shock absorber a strategy loss must eat through before redemptions
    ///         go distressed. No USDC moves; harvest no-ops when at/below buffer.
    ///         Restricting the trigger lets the protocol time harvests around
    ///         per-strategy totalAssets() volatility so a transient spike isn't
    ///         permanently coined into supply.
    ///
    ///         Distribute: the full USD8 balance (this harvest plus any residual)
    ///         is streamed to receivers pro-rata to {ProfitReceiver-weight}, each
    ///         via its configured mode. Zero-weight receivers are skipped; the last
    ///         positive-weight one absorbs integer-division dust so nothing strands.
    ///         Atomic: if there is revenue to distribute but no weighted receiver
    ///         (or a receiver rejects), the whole call — including the harvest
    ///         mint — reverts. No-ops cleanly when there is no revenue.
    /// @dev    INVARIANT: the Treasury's USD8 balance is exclusively the
    ///         harvested-revenue pool. No other path parks USD8 here — mintUSD8
    ///         sends to the caller, redeemUSD8 burns from the caller, and
    ///         {getReserveBalance} is USDC-denominated and ignores Treasury-held
    ///         USD8. So distributing the full balance is correct: it is all revenue.
    /// @return harvested   USD8 minted from surplus this call (0 if at/below buffer).
    /// @return distributed USD8 pushed to receivers (0 if the pool was empty).
    function harvestAndDistribute()
        external
        nonReentrant
        onlyAdminOrTimelock
        whenNotPaused
        returns (uint256 harvested, uint256 distributed)
    {
        // ── Harvest: mint surplus above the retained buffer. ──
        uint256 supply = usd8.totalSupply();
        uint256 reserveInUsd8 = getReserveBalance() * USDC_TO_USD8_SCALE;
        uint256 retain = supply + supply / HARVEST_BUFFER_DIVISOR;
        if (reserveInUsd8 > retain) {
            harvested = reserveInUsd8 - retain;
            usd8.mint(address(this), harvested); // no JIT concerns
            emit RevenueHarvested(harvested);
        }

        // ── Distribute the full revenue pool across receivers by weight. ──
        distributed = usd8.balanceOf(address(this));
        if (distributed == 0) return (harvested, distributed);

        // Pass 1: total the weights and find the last positive-weight receiver.
        uint256 n = profitReceivers.length;
        uint256 totalWeight;
        uint256 lastEligible = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            if (profitReceivers[i].weight != 0) {
                totalWeight += profitReceivers[i].weight;
                lastEligible = i;
            }
        }
        if (totalWeight == 0) revert NoEligibleProfitReceivers();

        // Pass 2: pay each its pro-rata share. The last positive-weight receiver
        // takes the remainder (its share plus truncation dust) so nothing strands.
        uint256 paid;
        for (uint256 i = 0; i < n; i++) {
            ProfitReceiver memory p = profitReceivers[i];
            if (p.weight == 0) continue;
            uint256 share = i == lastEligible ? distributed - paid : Math.mulDiv(distributed, p.weight, totalWeight);
            paid += share;
            if (share != 0) _deliverRevenue(p.receiver, share, p.mode);
        }
    }

    /// @notice Forward amount of the Treasury's USD8 balance to a single
    ///         recipient — an ad-hoc escape hatch alongside the weighted
    ///         {harvestAndDistribute}. Admin or timelock; blocked while paused.
    ///         mode controls whether USD8 is sent directly or delivered through
    ///         {IProfitDistributionReceiver-receiveProfitDistribution} —
    ///         vesting-aware consumers such as {SavingsUSD8} MUST be paid via
    ///         ReceiveProfitDistribution.
    function distributeRevenue(address recipient, uint256 amount, RevenueDistributionMode mode)
        external
        nonReentrant
        onlyAdminOrTimelock
        whenNotPaused
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _deliverRevenue(recipient, amount, mode);
    }

    /// @dev Deliver amount USD8 to recipient via mode. DirectTransfer sends the
    ///      token raw; ReceiveProfitDistribution approves and calls the vesting-
    ///      aware {IProfitDistributionReceiver-receiveProfitDistribution}, then
    ///      clears any residual allowance (the recipient may pull less).
    function _deliverRevenue(address recipient, uint256 amount, RevenueDistributionMode mode) internal {
        if (mode == RevenueDistributionMode.DirectTransfer) {
            // no need for SafeTransfer here, usd8 is our own token.
            usd8.transfer(recipient, amount);
        } else {
            usd8.approve(recipient, amount);
            IProfitDistributionReceiver(recipient).receiveProfitDistribution(amount);
            usd8.approve(recipient, 0);
        }

        emit RevenueDistributed(recipient, amount);
    }

    /// @notice Register a profit receiver or update its weight/mode. Admin or
    ///         timelock. Upsert: re-registering an existing receiver overwrites
    ///         its weight and mode. A zero weight keeps it registered but paid
    ///         nothing until re-weighted.
    /// @param receiver  Recipient of weighted distributions (non-zero).
    /// @param weight    Relative distribution share.
    /// @param mode      Delivery mode (see {RevenueDistributionMode}). Vesting
    ///                  vaults such as {SavingsUSD8} MUST use ReceiveProfitDistribution.
    function setProfitReceiver(address receiver, uint256 weight, RevenueDistributionMode mode)
        external
        onlyAdminOrTimelock
    {
        if (receiver == address(0)) revert ZeroAddress();
        uint256 n = profitReceivers.length;
        for (uint256 i = 0; i < n; i++) {
            if (profitReceivers[i].receiver == receiver) {
                profitReceivers[i].weight = weight;
                profitReceivers[i].mode = mode;
                emit ProfitReceiverSet(receiver, weight, mode);
                return;
            }
        }
        profitReceivers.push(ProfitReceiver({receiver: receiver, weight: weight, mode: mode}));
        emit ProfitReceiverSet(receiver, weight, mode);
    }

    /// @notice Deregister a profit receiver. Admin or timelock. Order among the
    ///         remaining receivers is not preserved (weighted split is order-
    ///         independent). Reverts if the receiver isn't registered.
    /// @param receiver  Registered receiver to remove.
    function removeProfitReceiver(address receiver) external onlyAdminOrTimelock {
        uint256 n = profitReceivers.length;
        for (uint256 i = 0; i < n; i++) {
            if (profitReceivers[i].receiver == receiver) {
                profitReceivers[i] = profitReceivers[n - 1];
                profitReceivers.pop();
                emit ProfitReceiverRemoved(receiver);
                return;
            }
        }
        revert ProfitReceiverNotFound(receiver);
    }

    // ─────────────────────────── Admin control ───────────────────────────

    /// @dev Rescuable via {RegistryManaged-rescueToken}: any stray token EXCEPT the
    ///      reserve asset ({USDC}) and the harvested-revenue token ({usd8}),
    ///      which are protected (cap 0). Their normal exits are redeem/strategy
    ///      flows (USDC) and {distributeRevenue} (USD8).
    function _sweepable(address token) internal view override returns (uint256) {
        if (token == address(USDC) || token == address(usd8)) return 0;
        return IERC20(token).balanceOf(address(this));
    }

    // ─────────────────────────── Views ───────────────────────────

    /// @notice Total USDC-denominated reserve controlled by this Treasury.
    ///         Sums the Treasury's idle USDC balance plus the reported
    ///         totalAssets() of every approved strategy. Includes backing
    ///         collateral plus any accrued surplus (yield, donations) — not
    ///         just the collateral portion. Returned amount is in USDC base
    ///         units (6 decimals).
    function getReserveBalance() public view returns (uint256) {
        uint256 total = USDC.balanceOf(address(this));
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            // INTENTIONAL: no try/catch. If a strategy can't report totalAssets the
            // reserve can't be fully valued, so mint/redeem (which wrap this in
            // reserveSupplyStatusCheck) revert rather than transact at a wrong price
            // — a fail-safe halt, not a bug. Swallowing the revert as 0 would
            // undercount the reserve and force an unfair haircut on redeemers.
            // Recover by force-removing the strategy via {removeStrategy} (timelock).
            total += strategies[i].totalAssets();
        }
        return total;
    }

    /// @notice Number of approved strategies. Convenience getter; callers
    ///         can also index into strategies(uint256) directly.
    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }

    /// @notice Number of registered profit receivers. Convenience getter;
    ///         callers can also index into profitReceivers(uint256) directly.
    function profitReceiversLength() external view returns (uint256) {
        return profitReceivers.length;
    }

    // ─────────────────────────── Internal helpers ───────────────────────────

    /// @dev Ensures the Treasury holds at least amount of idle USDC. Walks
    ///      strategies in array order, re-reading the Treasury's USDC balance
    ///      after each pull so a strategy that delivers short doesn't cause the
    ///      next iteration to under-ask, and skipping any that revert. Reverts
    ///      InsufficientLiquidity if idle + everything the walk could pull is
    ///      still below amount (post-condition: idle >= amount on return).
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

        // Walk exhausted: fail with a clear error rather than letting the
        // caller's transfer revert with a generic insufficient-balance error.
        uint256 finalIdle = USDC.balanceOf(address(this));
        if (finalIdle < amount) revert InsufficientLiquidity(amount, finalIdle);
    }

    /// @dev Linear scan of strategies for s. Returns its index plus a
    ///      found flag. O(n), acceptable at the operational count of <10.
    function _findStrategy(IStrategy s) internal view returns (uint256 idx, bool found) {
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            if (strategies[i] == s) {
                return (i, true);
            }
        }
        return (0, false);
    }

    /// @dev Return the index of an approved strategy, reverting StrategyNotApproved
    ///      if it isn't in the set. Shared find-or-revert for the deposit,
    ///      withdraw, and remove paths (callers that don't need the index ignore it).
    function _findApprovedStrategy(IStrategy s) internal view returns (uint256 idx) {
        bool found;
        (idx, found) = _findStrategy(s);
        if (!found) revert StrategyNotApproved(s);
    }
}
