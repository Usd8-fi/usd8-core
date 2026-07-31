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
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {USD8} from "./USD8.sol";
import {Registry} from "./Registry.sol";
import {SharedBase} from "./SharedBase.sol";
import {IProfitDistributionReceiver} from "./interfaces/IProfitDistributionReceiver.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// @title USD8 Treasury
/// @notice Mints USD8 1:1 for six-decimal USDC and manages the USDC reserve.
/// @dev Healthy redemptions return USDC 1:1. If reserves fall below supply,
///      redemptions receive the same pro-rata haircut. Approved strategies are
///      counted as reserve and form an ordered withdrawal queue after idle USDC;
///      strategy liquidity can still block execution. Timelock upgrades require beta mode.
/// @custom:security-contact rick@usd8.fi
contract Treasury is Initializable, UUPSUpgradeable, ReentrancyGuardTransient, SharedBase {
    using SafeERC20 for IERC20;

    /// @notice Deliver revenue by direct transfer or a receiver hook for custom accounting.
    enum RevenueDistributionMode {
        DirectTransfer,
        ReceiveProfitDistribution
    }

    // ─────────────────────────── State ───────────────────────────

    /// @custom:storage-location erc7201:usd8.storage.Treasury
    struct TreasuryStorage {
        IERC20 usdc;
        uint256 harvestBufferDivisor;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("usd8.storage.Treasury")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TREASURY_STORAGE = 0x0d48627c939e6496875931395c567691a7923a2c61d5f538a81c0feb79245c00;

    function _treasuryStorage() private pure returns (TreasuryStorage storage $) {
        assembly {
            $.slot := TREASURY_STORAGE
        }
    }

    /// @notice Chain-specific USDC reserve asset, fixed for the proxy's lifetime.
    function USDC() public view returns (IERC20) {
        return _treasuryStorage().usdc;
    }

    /// @notice Decimal-scale factor between USDC (6) and USD8 (18): 1e12.
    uint256 public constant USDC_TO_USD8_SCALE = 1e12;

    /// @notice Default harvest buffer divisor; the effective divisor is returned by {harvestBufferDivisor}.
    uint256 public constant HARVEST_BUFFER_DIVISOR = 1000;

    /// @notice Current divisor used to retain a fraction of USD8 supply during harvest.
    function harvestBufferDivisor() public view returns (uint256) {
        uint256 divisor = _treasuryStorage().harvestBufferDivisor;
        return divisor == 0 ? HARVEST_BUFFER_DIVISOR : divisor;
    }

    /// @notice Maximum aggregate reserve-accounting difference allowed by one
    ///         mint or redeem, in USDC base units (100 = 0.0001 USDC).
    uint256 public constant RESERVE_CHECK_TOLERANCE = 100;

    /// @notice Approved strategies in withdrawal order after idle USDC.
    /// @dev This array is also the approval set and is scanned during reserve reads.
    ///      Mint values it twice; redeem values it three times and may walk it for liquidity.
    IStrategy[] public strategies;

    /// @notice A registered profit receiver and its distribution config.
    /// @param receiver  Address paid a weighted share by {harvestAndDistribute}.
    /// @param weight    Relative share of each weighted distribution (0 = registered
    ///                  but currently earns nothing).
    /// @param mode      How USD8 is delivered: raw transfer, or the vesting-aware
    ///                  {IProfitDistributionReceiver-receiveProfitDistribution}.
    struct ProfitReceiver {
        address receiver;
        uint88 weight;
        RevenueDistributionMode mode;
    }

    /// @notice Registered profit receivers — the weighted-split targets of
    ///         {harvestAndDistribute}. Admin or timelock curates via
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

    /// @notice Idle USDC plus successful strategy withdrawals cannot fund a redemption.
    error InsufficientLiquidity(uint256 needed, uint256 available);

    /// @notice A strategy operation targeted one not approved through {addStrategy}.
    error StrategyNotApproved(IStrategy strategy);

    /// @notice Thrown by {addStrategy} when the strategy is already approved.
    error StrategyAlreadyApproved(IStrategy strategy);

    /// @notice Thrown by {removeProfitReceiver} when the address isn't registered.
    error ProfitReceiverNotFound(address receiver);

    /// @notice The Treasury cannot distribute revenue to itself.
    error InvalidProfitReceiver(address receiver);

    /// @notice Thrown by {harvestAndDistribute} when there is revenue to
    ///         distribute but no registered receiver has a positive weight.
    error NoEligibleProfitReceivers();

    /// @notice Thrown when a hook-based receiver does not pull exactly the
    ///         approved revenue amount.
    error RevenueDeliveryMismatch(uint256 expected, uint256 actual);

    error InvalidReserveAsset(address candidate);
    error InvalidReserveDecimals(uint8 actual);
    error InvalidHarvestBufferDivisor(uint256 divisor);

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

    /// @notice Emitted when an admin or timelock deposits idle USDC into a strategy.
    event DepositedToStrategy(IStrategy indexed strategy, uint256 amount);

    /// @notice Emitted when an admin or timelock withdraws USDC from a strategy.
    ///         amount is the actual delta observed in the Treasury's USDC
    ///         balance, not the requested amount.
    event WithdrawnFromStrategy(IStrategy indexed strategy, uint256 amount);

    /// @notice Emitted when {harvestAndDistribute} sends USD8 to a receiver.
    event RevenueDistributed(address indexed recipient, uint256 amount);

    /// @notice Emitted when a profit receiver is registered or its weight/mode
    ///         updated via {setProfitReceiver}.
    event ProfitReceiverSet(address indexed receiver, uint256 weight, RevenueDistributionMode mode);

    /// @notice Emitted when a profit receiver is deregistered via {removeProfitReceiver}.
    event ProfitReceiverRemoved(address indexed receiver);

    /// @notice Emitted when {harvestAndDistribute} mints surplus into this Treasury.
    ///         amount is in USD8 base units (18 decimals).
    event RevenueHarvested(uint256 amount);

    /// @notice Emitted when the timelock updates the harvest buffer divisor.
    event HarvestBufferDivisorSet(uint256 oldDivisor, uint256 newDivisor);

    // ─────────────────────────── Constructor ─────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the Treasury proxy. Callable once.
    /// @param _registry Shared access, pause, and canonical-topology registry.
    /// @param usdc_ Chain-specific six-decimal reserve asset, fixed after initialization.
    function initialize(Registry _registry, IERC20 usdc_) external initializer {
        if (address(_registry) == address(0) || address(usdc_) == address(0)) revert ZeroAddress();
        _setRegistry(_registry);
        if (address(usdc_).code.length == 0) revert InvalidReserveAsset(address(usdc_));
        uint8 reserveDecimals = IERC20Metadata(address(usdc_)).decimals();
        if (reserveDecimals != 6) revert InvalidReserveDecimals(reserveDecimals);
        _treasuryStorage().usdc = usdc_;
    }

    /// @notice Canonical USD8 token resolved from the shared Registry.
    function usd8() public view returns (USD8) {
        return USD8(registry().usd8());
    }

    /// @notice Set the divisor used to retain a fraction of USD8 supply during harvest.
    function setHarvestBufferDivisor(uint256 divisor) external {
        _requireTimelock();
        if (divisor == 0) revert InvalidHarvestBufferDivisor(divisor);
        TreasuryStorage storage $ = _treasuryStorage();
        uint256 oldDivisor = harvestBufferDivisor();
        $.harvestBufferDivisor = divisor;
        emit HarvestBufferDivisorSet(oldDivisor, divisor);
    }

    /// @dev Only the timelock can upgrade the Treasury in place, and only during beta.
    function _authorizeUpgrade(address) internal view override {
        _requireTimelock();
        _requireBetaMode();
    }

    // ─────────────────────────── Modifiers ───────────────────────

    /// @dev After mint or redeem, healthy-state surplus or distressed-state backing
    ///      ratio must not worsen beyond {RESERVE_CHECK_TOLERANCE} USDC base units.
    modifier reserveSupplyStatusCheck() {
        _requireNotPaused();
        uint256 reserveBefore = getReserveBalance();
        uint256 supplyBefore = usd8().totalSupply();
        _;

        uint256 reserveAfter = getReserveBalance();
        uint256 supplyAfter = usd8().totalSupply();
        uint256 reserveBeforeInUsd8 = reserveBefore * USDC_TO_USD8_SCALE;
        uint256 reserveAfterInUsd8 = reserveAfter * USDC_TO_USD8_SCALE;
        uint256 tol = RESERVE_CHECK_TOLERANCE * USDC_TO_USD8_SCALE;

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

    // ─────────────────────────── USD8 / USDC conversion ───────────────────────────

    /// @notice WAD-scaled redemption ratio used by incident-open pricing.
    /// @dev Returns `min(reserve * 1e12, supply) / supply` without consulting a
    ///      USDC price oracle. Reverts when supply is zero.
    function usd8ToUsdcRate() external view returns (uint256) {
        uint256 supply = usd8().totalSupply();
        if (supply == 0) revert NoUsd8Supply();
        uint256 reserveInUsd8 = getReserveBalance() * USDC_TO_USD8_SCALE;
        uint256 effectiveReserve = reserveInUsd8 < supply ? reserveInUsd8 : supply;
        return Math.mulDiv(effectiveReserve, 1e18, supply);
    }

    // ─────────────────────────── User operations (mint / redeem) ───────────────────────────

    /// @notice Deposit USDC and mint USD8 at a 1:1 dollar peg. The caller
    ///         must have approved usdcAmount USDC to this contract.
    /// @param  usdcAmount Amount of USDC (6 decimals) to deposit.
    function mintUSD8(uint256 usdcAmount) external nonReentrant reserveSupplyStatusCheck {
        if (usdcAmount == 0) revert ZeroAmount();

        USDC().safeTransferFrom(msg.sender, address(this), usdcAmount);
        uint256 usd8Amount = usdcAmount * USDC_TO_USD8_SCALE;
        usd8().mint(msg.sender, usd8Amount);

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
    function redeemUSD8(uint256 usd8Amount, uint256 minUsdcOut) external nonReentrant reserveSupplyStatusCheck {
        if (usd8Amount == 0) revert ZeroAmount();

        uint256 supply = usd8().totalSupply();
        if (supply == 0) revert NoUsd8Supply();
        uint256 reserveInUsd8 = getReserveBalance() * USDC_TO_USD8_SCALE;
        // Effective collateral is capped at peg: surplus is reserved for
        // the harvested-revenue pool and never paid to redeemers.
        uint256 eff = reserveInUsd8 < supply ? reserveInUsd8 : supply;
        // mulDiv: usd8Amount * eff may exceed 2^256 at extreme supplies even though
        // the quotient always fits (usd8Amount ≤ supply ⇒ quotient ≤ eff).
        uint256 usdcAmount = Math.mulDiv(usd8Amount, eff, supply) / USDC_TO_USD8_SCALE;
        if (usdcAmount < minUsdcOut) revert InsufficientUsdcOut(usdcAmount, minUsdcOut);

        usd8().burn(msg.sender, usd8Amount);
        _ensureIdleUsdc(usdcAmount);
        USDC().safeTransfer(msg.sender, usdcAmount);

        emit Redeemed(msg.sender, usd8Amount, usdcAmount);
    }

    // ─────────────────────────── Strategy management ───────────────────────────

    /// @notice Approve a strategy and insert it into the withdrawal queue. Timelock only.
    /// @dev An index beyond the array appends. Strategy behavior is a trusted
    ///      governance boundary; Treasury does not verify the implementation.
    function addStrategy(IStrategy s, uint256 index) external {
        _requireTimelock();
        if (address(s) == address(0)) revert ZeroAddress();
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

    /// @notice Remove a strategy while preserving the order of the remaining queue.
    ///         Timelock only.
    /// @dev Removal does not require the strategy to be empty. Any funds left there
    ///      stop counting as reserve and may become unreachable; drain first unless
    ///      the position is already considered lost.
    function removeStrategy(IStrategy s) external {
        _requireTimelock();
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
    function depositToStrategy(IStrategy s, uint256 amount) external nonReentrant {
        _requireAdminOrTimelock();
        _requireNotPaused();
        if (amount == 0) revert ZeroAmount();
        _findApprovedStrategy(s);
        USDC().safeTransfer(address(s), amount); // push USDC to strategies to avoid granting approvals.
        s.deploy(amount);
        emit DepositedToStrategy(s, amount);
    }

    /// @notice Pull amount USDC from an approved strategy back to idle.
    ///         Admin or timelock. Blocked while paused.
    /// @dev The event records the actual USDC received, which may be less than requested.
    function withdrawFromStrategy(IStrategy s, uint256 amount) external nonReentrant {
        _requireAdminOrTimelock();
        _requireNotPaused();
        _findApprovedStrategy(s);
        if (amount == 0) revert ZeroAmount();
        uint256 balanceBefore = USDC().balanceOf(address(this));
        s.withdraw(amount);
        uint256 received = USDC().balanceOf(address(this)) - balanceBefore;
        emit WithdrawnFromStrategy(s, received);
    }

    // ─────────────────────────── Revenue harvesting & routing ───────────────────────────

    /// @notice Mint reserve surplus above the buffer, then distribute all USD8 held
    ///         by Treasury across positive-weight receivers. Admin or timelock.
    /// @dev Unsolicited USD8 is also distributed. The last eligible receiver gets
    ///      division dust; any receiver failure reverts the whole call.
    /// @return harvested   USD8 minted from surplus this call (0 if at/below buffer).
    /// @return distributed USD8 pushed to receivers (zero when no revenue exists).
    function harvestAndDistribute() external nonReentrant returns (uint256 harvested, uint256 distributed) {
        _requireAdminOrTimelock();
        _requireNotPaused();
        // ── Harvest: mint surplus above the retained buffer. ──
        uint256 supply = usd8().totalSupply();
        uint256 reserveInUsd8 = getReserveBalance() * USDC_TO_USD8_SCALE;
        uint256 retain = supply + supply / harvestBufferDivisor();
        if (reserveInUsd8 > retain) {
            harvested = reserveInUsd8 - retain;
            usd8().mint(address(this), harvested); // no JIT concerns
            emit RevenueHarvested(harvested);
        }

        // ── Distribute the full revenue pool across receivers by weight. ──
        distributed = usd8().balanceOf(address(this));
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
            if (share == 0) continue;

            if (p.mode == RevenueDistributionMode.DirectTransfer) {
                // No need for SafeTransfer here: USD8 is the protocol's own token.
                usd8().transfer(p.receiver, share);
            } else {
                uint256 balanceBefore = usd8().balanceOf(address(this));
                usd8().approve(p.receiver, share);
                IProfitDistributionReceiver(p.receiver).receiveProfitDistribution(share);
                usd8().approve(p.receiver, 0);

                uint256 balanceAfter = usd8().balanceOf(address(this));
                uint256 delivered = balanceAfter <= balanceBefore ? balanceBefore - balanceAfter : 0;
                if (delivered != share) revert RevenueDeliveryMismatch(share, delivered);
            }

            emit RevenueDistributed(p.receiver, share);
        }
    }

    /// @notice Register a profit receiver or update its weight/mode. Admin or
    ///         timelock. Upsert: re-registering an existing receiver overwrites
    ///         its weight and mode. A zero weight keeps it registered but paid
    ///         nothing until re-weighted.
    /// @param receiver  Recipient of weighted distributions (non-zero).
    /// @param weight    Relative distribution share.
    /// @param mode      Delivery mode (see {RevenueDistributionMode}). Vesting
    ///                  accounting-aware receivers MUST use ReceiveProfitDistribution.
    function setProfitReceiver(address receiver, uint256 weight, RevenueDistributionMode mode) external {
        _requireAdminOrTimelock();
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert InvalidProfitReceiver(receiver);
        uint88 packedWeight = SafeCast.toUint88(weight);
        uint256 n = profitReceivers.length;
        for (uint256 i = 0; i < n; i++) {
            if (profitReceivers[i].receiver == receiver) {
                profitReceivers[i].weight = packedWeight;
                profitReceivers[i].mode = mode;
                emit ProfitReceiverSet(receiver, weight, mode);
                return;
            }
        }
        profitReceivers.push(ProfitReceiver({receiver: receiver, weight: packedWeight, mode: mode}));
        emit ProfitReceiverSet(receiver, weight, mode);
    }

    /// @notice Deregister a profit receiver. Admin or timelock. Order among the
    ///         remaining receivers is not preserved (weighted split is order-
    ///         independent). Reverts if the receiver isn't registered.
    /// @param receiver  Registered receiver to remove.
    function removeProfitReceiver(address receiver) external {
        _requireAdminOrTimelock();
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

    /// @dev {SharedBase-sweepToken} may recover stray tokens, but never USDC or USD8.
    function _sweepable(address token) internal view override returns (uint256) {
        if (token == address(USDC()) || token == address(usd8())) return 0;
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
        uint256 total = USDC().balanceOf(address(this));
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

    /// @dev Pulls USDC in strategy order until `amount` is idle. A reverting
    ///      `withdraw` is skipped, but a reverting `totalAssets` call propagates.
    ///      Reverts with {InsufficientLiquidity} if successful pulls remain short.
    function _ensureIdleUsdc(uint256 amount) internal {
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 idle = USDC().balanceOf(address(this));
            if (idle >= amount) return;
            uint256 needed = amount - idle;
            IStrategy s = strategies[i];
            uint256 available = s.totalAssets();
            if (available == 0) continue;
            uint256 toPull = needed < available ? needed : available;
            // Skip reverting withdrawals and continue through the queue.
            try s.withdraw(toPull) {} catch {}
        }

        // Walk exhausted: fail with a clear error rather than letting the
        // caller's transfer revert with a generic insufficient-balance error.
        uint256 finalIdle = USDC().balanceOf(address(this));
        if (finalIdle < amount) revert InsufficientLiquidity(amount, finalIdle);
    }

    /// @dev Linear strategy scan returning its index and a found flag.
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
