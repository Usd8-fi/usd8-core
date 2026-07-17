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
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Registry} from "./Registry.sol";
import {SharedBase} from "./SharedBase.sol";
import {IProfitDistributionReceiver} from "./interfaces/IProfitDistributionReceiver.sol";

/// @title  SingleAssetCoverPool
/// @notice A single-asset ERC-4626 cover vault that underwrites the USD8 insurance
///         system. Stakers deposit one asset, receive TRANSFERABLE ERC-20 shares
///         (composable with other DeFi), earn USD8 yield, and absorb claim losses
///         pro-rata. Multi-asset coverage is REPLICATION: one pool per asset behind
///         the shared beacon, each registered on the {Registry}.
/// @dev    Deposits are synchronous ERC-4626; exits are asynchronous — request shares,
///         wait at least {UNSTAKE_COOLDOWN}, then claim fixed assets at any later time.
///         Standard `redeem` / `withdraw` are disabled because requested shares are
///         escrowed and batch-burned when their daily exit epoch matures.
///
///         Two-token model: `asset` (ERC-4626 underlying, backs shares) and
///         `usd8` (USD8, a SEPARATE Synthetix-style stream claimed via
///         {claimReward}). Rewards survive share transfers — {_update} checkpoints
///         both parties on every mint/burn/transfer.
///
///         totalAssets is INTERNAL accounting ({_accountedAssets}), not balanceOf, so
///         a stray donation can't inflate share price and is swept as surplus; the
///         ERC-4626 virtual-shares offset ({_decimalsOffset}) is the backstop. Losses
///         socialize automatically: {payClaim} reduces _accountedAssets → share price
///         falls. During an incident ({Registry.payoutIncidentActive}), deposits and
///         unsettled exit epochs are frozen so settlement uses deterministic active
///         capital. Exit requests remain available and stay loss-exposed; assets
///         reserved before the incident remain claimable because they are no longer
///         underwriting capital. Ordinary share transfers stay open.
/// @custom:security-contact rick@usd8.fi
contract SingleAssetCoverPool is
    Initializable,
    ERC4626Upgradeable,
    ERC20PermitUpgradeable,
    ReentrancyGuardTransient,
    SharedBase,
    IProfitDistributionReceiver
{
    using SafeERC20 for IERC20;

    // ─────────────────────────── Constants ───────────────────────────

    /// @notice Cooldown before a filed redeem request may complete.
    uint64 public constant UNSTAKE_COOLDOWN = 7 days;

    /// @notice Exit requests are grouped into three-day epochs. Rounding the
    ///         seven-day cooldown up to the next boundary makes the wait 7–10 days
    ///         and keeps incident-open processing bounded by a small number of epochs.
    uint64 public constant EXIT_BATCH_INTERVAL = 3 days;

    /// @notice Upper bound on {rewardsDuration} (L-F). A duration so long that
    ///         total/duration floors the rate to 0 would brick funding
    ///         ({RewardRateZero}) and risks overflow in the weighted-duration math;
    ///         a year is far beyond any real emission schedule.
    uint64 public constant MAX_REWARDS_DURATION = 365 days;

    /// @notice Fixed-point scaling for the {rewardPerShareStored} accumulator
    ///         (Synthetix pattern): the per-share increment floors to 0 without it.
    ///         See earlier revisions for the full precision/overflow rationale.
    uint256 internal constant REWARD_SCALE = 1e30;

    /// @notice Basis-point denominator for {maxPayoutPerIncident} (matches {Registry}).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ─────────────────────────── State ───────────────────────────

    /// @notice The reward token paid to stakers. Resolved once from Registry's
    ///         canonical USD8 address at initialization.
    IERC20 public usd8;

    /// @notice Emission window applied to every profit distribution.
    uint64 public rewardsDuration;

    /// @notice Asset the vault accounts as backing shares: staked principal net of
    ///         redemptions and claim payouts. Internal accounting (not balanceOf), so
    ///         donations don't inflate price and are sweepable. {totalAssets} returns it.
    uint256 private _accountedAssets;

    /// @notice Current emission of {usd8} per second.
    uint128 public rewardRate;

    /// @notice Unix timestamp the emission window ends.
    uint64 public periodFinish;

    /// @notice Timestamp of the last reward checkpoint.
    uint64 public lastUpdateTime;

    /// @notice Cumulative reward-per-share at the last checkpoint, scaled by {REWARD_SCALE}.
    uint256 public rewardPerShareStored;

    /// @notice Reward token committed to stakers but not yet paid out.
    uint256 public rewardReserve;

    /// @param userRewardPerSharePaid  rewardPerShareStored snapshot at last checkpoint.
    /// @param rewards                 Accumulated, not-yet-claimed reward token.
    struct RewardState {
        uint256 userRewardPerSharePaid;
        uint256 rewards;
    }

    /// @notice Per-user reward bookkeeping (share count is the ERC-20 balance).
    mapping(address user => RewardState) public rewardState;

    /// @param shares    Shares escrowed for the user.
    /// @param exitEpoch Daily boundary when those shares leave underwriting risk.
    struct ExitRequest {
        uint256 shares;
        uint64 exitEpoch;
    }

    /// @notice Pending exit receipts, one per user.
    mapping(address user => ExitRequest) public exitRequests;

    /// @notice Max total staked assets ({totalAssets}) this pool will accept;
    ///         0 = uncapped. Admin/timelock-set, sized off-chain (e.g. from a
    ///         target staker APY given the reward budget and asset price).
    ///         Enforced via {maxDeposit}/{maxMint}, so ERC-4626 deposit/mint revert
    ///         once full and integrators see the gate. Soft: an existing pool over
    ///         a newly-lowered cap isn't force-unwound, it just stops accepting more.
    uint256 public depositCap;

    /// @param totalShares     Escrowed shares assigned to this exit epoch.
    /// @param totalAssets     Assets fixed for the epoch when it settles.
    /// @param remainingShares Unclaimed receipt shares (rounding bookkeeping).
    /// @param remainingAssets Assets still owed to epoch claimants.
    /// @param settled         Whether shares were burned and assets reserved.
    struct ExitEpoch {
        uint256 totalShares;
        uint256 totalAssets;
        uint256 remainingShares;
        uint256 remainingAssets;
        bool settled;
    }

    /// @notice Exit epoch state keyed by its boundary timestamp.
    mapping(uint64 exitEpoch => ExitEpoch) public exitEpochs;

    /// @notice Index of the first unsettled entry in {_exitEpochQueue}.
    uint256 public nextExitEpochIndex;

    /// @notice Pool assets fixed for matured exits but not yet claimed.
    uint256 public withdrawalReserve;

    uint64[] private _exitEpochQueue;

    // ─────────────────────────── Errors ──────────────────────────

    error ZeroAmount();
    error InvalidRewardsDuration();
    error NoEligibleStakers();
    error InsufficientShares(uint256 requested, uint256 available);
    error RewardRateTooHigh();
    error NoUnstakeRequest();
    error UnstakeRequestExists();

    error PoolFrozen();
    error NotDefiInsurance(address caller);
    error PayoutExceedsPoolAssets(uint256 requested, uint256 available);
    error InvalidRecipient();
    error FeeOnTransferUnsupported();
    error RewardRateZero(uint256 total, uint256 duration);
    error WithdrawNotSupported();
    error RedeemNotSupported();
    error CooldownNotElapsed(uint64 exitEpoch);

    // ─────────────────────────── Events ──────────────────────────

    event RedeemRequested(address indexed user, uint256 shares);

    event ExitEpochSettled(uint64 indexed exitEpoch, uint256 shares, uint256 assets);
    event ExitClaimed(address indexed user, address indexed receiver, uint256 shares, uint256 assets);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount, uint128 newRate, uint64 newPeriodFinish);
    event RewardsDurationSet(uint64 oldDuration, uint64 newDuration);
    event ClaimPaid(address indexed to, uint256 amount);
    event DepositCapSet(uint256 newCap);

    // ─────────────────────────── Initialization ───────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the beacon proxy. Callable once.
    /// @param _registry    Shared access + pause + freeze registry.
    /// @param _asset        The staked asset / ERC-4626 underlying (non-zero).
    /// @param name_         ERC-20 share name (per-pool, e.g. "USD8 wstETH Cover").
    /// @param symbol_       ERC-20 share symbol (per-pool, e.g. "cpwstETH").
    function initialize(Registry _registry, IERC20 _asset, string calldata name_, string calldata symbol_)
        external
        initializer
    {
        if (address(_asset) == address(0)) revert ZeroAddress();
        _setRegistry(_registry);
        address registryUsd8 = _registry.usd8();
        if (registryUsd8 == address(0)) revert ZeroAddress();
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __ERC4626_init(_asset);
        usd8 = IERC20(registryUsd8);
        rewardsDuration = 7 days;
    }

    // ─────────────────────────── ERC-4626 config ───────────────────────────

    /// @notice Backing assets = internal accounting (donation-immune), not balanceOf.
    function totalAssets() public view override returns (uint256) {
        return _accountedAssets;
    }

    /// @dev Virtual-shares offset: inflation backstop (donations already can't inflate
    ///      via the accounting var; this covers first-depositor rounding).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /// @notice Returns the share-token decimals.
    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }

    /// @dev Rewards survive ordinary transfers: checkpoint the accumulator, then
    ///      both parties before balances change. Shares sent through {requestRedeem}
    ///      bypass this hook after explicitly checkpointing and are held by the pool;
    ///      direct transfers to the pool are rejected so every escrowed share has an
    ///      exit receipt.
    function _update(address from, address to, uint256 value) internal override {
        _checkpointGlobalRewards();
        if (to == address(this)) revert InvalidRecipient();
        if (from != address(0) && from != address(this)) _checkpointUserRewards(from);
        if (to != address(0)) _checkpointUserRewards(to);
        super._update(from, to, value);
    }

    // ─────────────────────────── Deposit (stake) ───────────────────────────

    /// @inheritdoc ERC4626Upgradeable
    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        if (registry().payoutIncidentActive()) revert PoolFrozen();
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626Upgradeable
    function mint(uint256 shares, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        if (registry().payoutIncidentActive()) revert PoolFrozen();
        return super.mint(shares, receiver);
    }

    /// @dev Deposit funnel: keeps {_accountedAssets} in lockstep (freeze/pause gated by
    ///      the public entrypoints above and by {maxDeposit}). Rejects a
    ///      fee-on-transfer asset — it would deliver less than `assets`, so crediting
    ///      the nominal amount would push totalAssets above the real balance. ERC-4626
    ///      doesn't support such tokens; governance lists only standard assets, and
    ///      this makes a slip fail loudly instead of silently corrupting accounting.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        uint256 balBefore = IERC20(asset()).balanceOf(address(this));
        super._deposit(caller, receiver, assets, shares);
        if (IERC20(asset()).balanceOf(address(this)) - balBefore < assets) revert FeeOnTransferUnsupported();
        _accountedAssets += assets;
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxDeposit(address) public view override returns (uint256) {
        if (registry().paused(address(this)) || registry().payoutIncidentActive()) return 0;
        uint256 cap = depositCap;
        if (cap == 0) return type(uint256).max;
        uint256 size = totalAssets();
        return cap > size ? cap - size : 0;
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxMint(address) public view override returns (uint256) {
        if (registry().paused(address(this)) || registry().payoutIncidentActive()) return 0;
        uint256 cap = depositCap;
        if (cap == 0) return type(uint256).max;
        uint256 size = totalAssets();
        return cap > size ? convertToShares(cap - size) : 0;
    }

    // ─────────────────────────── Redeem (async) ───────────────────────────

    /// @notice File an irreversible exit for `shares`. The shares move into pool
    ///         escrow and stop earning immediately, but remain exposed to claim losses
    ///         until their daily epoch settles after the cooldown. One live request
    ///         per user; settled receipts remain claimable indefinitely.
    function requestRedeem(uint256 shares) external nonReentrant whenNotPaused {
        // Requests remain available during an incident: shares stay loss-exposed,
        // but stop earning immediately. Existing matured epochs settle only while
        // unfrozen so an already-open incident keeps its committed capital.
        if (!registry().payoutIncidentActive()) {
            _settleMaturedExitEpochs(_exitEpochQueue.length - nextExitEpochIndex);
        }
        if (shares == 0) revert ZeroAmount();
        uint256 bal = balanceOf(msg.sender);
        if (bal < shares) revert InsufficientShares(shares, bal);

        ExitRequest memory existing = exitRequests[msg.sender];
        if (existing.shares != 0) revert UnstakeRequestExists();

        uint64 exitEpoch = _calculateExitEpoch(block.timestamp);
        exitRequests[msg.sender] = ExitRequest({shares: shares, exitEpoch: exitEpoch});

        ExitEpoch storage epoch = exitEpochs[exitEpoch];
        if (epoch.totalShares == 0) _exitEpochQueue.push(exitEpoch);
        epoch.totalShares += shares;

        // Requested shares stop earning immediately and are held by the pool until
        // the exit matures. Bypass this contract's transfer hook because rewards for
        // the requester were checkpointed above and the pool itself never earns.
        _checkpointGlobalRewards();
        _checkpointUserRewards(msg.sender);
        super._update(msg.sender, address(this), shares);
        emit RedeemRequested(msg.sender, shares);
    }

    /// @notice Settle up to `maxEpochs` ended exit epochs. Permissionless.
    /// @param maxEpochs Maximum number of epochs to process in this call.
    /// @return settled Number of epochs processed.
    function settleMaturedExitEpochs(uint256 maxEpochs) external returns (uint256 settled) {
        if (registry().payoutIncidentActive()) revert PoolFrozen();
        return _settleMaturedExitEpochs(maxEpochs);
    }

    /// @dev Settles at most `maxEpochs` queued epochs and reserves their assets.
    function _settleMaturedExitEpochs(uint256 maxEpochs) internal returns (uint256 settled) {
        uint256 i = nextExitEpochIndex;
        uint256 length = _exitEpochQueue.length;
        while (i < length && settled < maxEpochs) {
            uint64 exitEpoch = _exitEpochQueue[i];
            if (block.timestamp < exitEpoch) break;

            ExitEpoch storage epoch = exitEpochs[exitEpoch];
            uint256 shares = epoch.totalShares;
            // Drain all active assets for the final shares so virtual rounding leaves no dust.
            uint256 assets = shares == totalSupply() ? _accountedAssets : previewRedeem(shares);

            epoch.totalAssets = assets;
            epoch.remainingShares = shares;
            epoch.remainingAssets = assets;
            epoch.settled = true;

            _accountedAssets -= assets;
            withdrawalReserve += assets;
            _burn(address(this), shares);

            emit ExitEpochSettled(exitEpoch, shares, assets);
            unchecked {
                ++i;
                ++settled;
            }
        }
        nextExitEpochIndex = i;
    }

    /// @dev Rounds the earliest exit time up to the next batch boundary.
    function _calculateExitEpoch(uint256 requestedAt) internal pure returns (uint64) {
        uint256 earliest = requestedAt + UNSTAKE_COOLDOWN;
        uint256 interval = EXIT_BATCH_INTERVAL;
        return SafeCast.toUint64(Math.ceilDiv(earliest, interval) * interval);
    }

    /// @notice Complete the caller's matured redemption. No claim window:
    ///         once an epoch settles its reserve remains available indefinitely.
    function completeRedeem(address receiver) external nonReentrant whenNotPaused returns (uint256 assets) {
        if (receiver == address(0) || receiver == address(this)) revert InvalidRecipient();
        ExitRequest memory request = exitRequests[msg.sender];
        if (request.shares == 0) revert NoUnstakeRequest();

        ExitEpoch storage epoch = exitEpochs[request.exitEpoch];
        if (!epoch.settled) {
            if (block.timestamp < request.exitEpoch) revert CooldownNotElapsed(request.exitEpoch);
            if (registry().payoutIncidentActive()) revert PoolFrozen();
            _settleMaturedExitEpochs(_exitEpochQueue.length - nextExitEpochIndex);
        }

        uint256 shares = request.shares;
        if (shares == epoch.remainingShares) {
            assets = epoch.remainingAssets;
        } else {
            assets = Math.mulDiv(epoch.totalAssets, shares, epoch.totalShares);
        }

        delete exitRequests[msg.sender];
        epoch.remainingShares -= shares;
        epoch.remainingAssets -= assets;
        withdrawalReserve -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);

        emit ExitClaimed(msg.sender, receiver, shares, assets);
    }

    /// @notice Standard ERC-4626 redemption is disabled because requested shares are
    ///         escrowed and burned at epoch settlement. Complete exits via {completeRedeem}.
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert RedeemNotSupported();
    }

    /// @notice Asset-denominated ERC-4626 exits are disabled. Exit shares are
    ///         specified once in {requestRedeem}, batch-burned at epoch settlement,
    ///         and their fixed asset receipt is collected through {completeRedeem}.
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert WithdrawNotSupported();
    }

    /// @notice Always 0 — exits complete through {completeRedeem}, not ERC-4626 redeem.
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Always 0 — asset-denominated exit is unsupported (see {withdraw}).
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    // ─────────────────────────── Rewards ───────────────────────────

    /// @notice Claim pending reward-token yield without touching the stake.
    /// @return reward The reward token amount transferred to the caller.
    function claimReward() external nonReentrant whenNotPaused returns (uint256 reward) {
        _checkpointGlobalRewards();
        _checkpointUserRewards(msg.sender);

        RewardState storage u = rewardState[msg.sender];
        reward = u.rewards;
        if (reward == 0) return 0;
        u.rewards = 0;
        rewardReserve -= reward;
        usd8.safeTransfer(msg.sender, reward);
        emit RewardClaimed(msg.sender, reward);
    }

    /// @notice Receive a reward-token profit distribution and stream it to stakers.
    ///         Pulls amount from msg.sender. Reverts {NoEligibleStakers} with no shares,
    ///         {RewardRateZero} when total/duration floors to zero (L-01: the amount
    ///         would be reserved but never stream — batch it with the next distribution
    ///         instead). Per-notification flooring dust (≤ duration wei) stays accepted.
    /// @dev    Weighted-average schedule; floored remainder dust accepted (audit L-01/C6).
    function receiveProfitDistribution(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (_earningShares() == 0) revert NoEligibleStakers();

        usd8.safeTransferFrom(msg.sender, address(this), amount);
        rewardReserve += amount;

        _checkpointGlobalRewards();

        uint256 remaining = block.timestamp < periodFinish ? periodFinish - block.timestamp : 0;
        uint256 leftover = remaining * rewardRate;
        uint256 total = leftover + amount; // amount > 0 above, so total > 0
        uint256 newDuration = (leftover * remaining + amount * rewardsDuration) / total;
        if (newDuration == 0) newDuration = rewardsDuration; // defensive (remaining==0 path)
        uint256 newRate = total / newDuration;
        if (newRate == 0) revert RewardRateZero(total, newDuration);
        if (newRate > type(uint128).max) revert RewardRateTooHigh();

        rewardRate = uint128(newRate);
        lastUpdateTime = uint64(block.timestamp);
        periodFinish = uint64(block.timestamp + newDuration);

        emit RewardNotified(amount, uint128(newRate), periodFinish);
    }

    // ─────────────────────────── Payout hook ───────────────────────────

    /// @notice The most this pool may pay out for one incident: {totalAssets} ×
    ///         {Registry.maxCoverPoolPayoutBps} / 10_000. Enforced at settle.
    function maxPayoutPerIncident() external view returns (uint256) {
        return totalAssets() * registry().maxCoverPoolPayoutBps() / BPS_DENOMINATOR;
    }

    /// @notice Pay a settlement amount out of pooled capital. The single registered
    ///         payout module only ({Registry.defiInsurance}). Reduces {totalAssets},
    ///         socializing the loss across all shareholders (share price falls).
    /// @param to      Claimant to pay.
    /// @param amount  Asset amount to pay (0 = no-op for this pool's row).
    function payClaim(address to, uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender != registry().defiInsurance()) revert NotDefiInsurance(msg.sender);
        // Paying the pool itself would drop _accountedAssets while tokens stay put,
        // silently reclassifying staker principal as sweepable surplus.
        if (to == address(this)) revert InvalidRecipient();
        if (amount == 0) return;
        if (amount > _accountedAssets) revert PayoutExceedsPoolAssets(amount, _accountedAssets);
        _accountedAssets -= amount;
        IERC20(asset()).safeTransfer(to, amount);
        emit ClaimPaid(to, amount);
    }

    // ─────────────────────────── Admin ───────────────────────────

    /// @notice Set the emission window for future distributions. Admin or timelock.
    function setRewardsDuration(uint64 newDuration) external onlyAdminOrTimelock {
        if (newDuration == 0 || newDuration > MAX_REWARDS_DURATION) revert InvalidRewardsDuration();
        emit RewardsDurationSet(rewardsDuration, newDuration);
        rewardsDuration = newDuration;
    }

    /// @notice Set the max total staked assets this pool accepts (0 = uncapped).
    ///         Admin or timelock. Soft cap: lowering it below the current size
    ///         stops new deposits but never force-unwinds existing stake.
    function setDepositCap(uint256 newCap) external onlyAdminOrTimelock {
        depositCap = newCap;
        emit DepositCapSet(newCap);
    }

    /// @dev Rescuable via {SharedBase-sweepToken}: only balance above accounting.
    ///      Staked principal ({asset} → {_accountedAssets}) and committed rewards
    ///      ({usd8} → {rewardReserve}) are protected; the rest is stray.
    ///      Additive so a pool whose asset IS its reward token protects both.
    function _sweepable(address token) internal view override returns (uint256) {
        // The pool's own share balance is exit escrow, never an accidental token.
        if (token == address(this)) return 0;
        uint256 accounted;
        if (token == asset()) accounted += _accountedAssets + withdrawalReserve;
        if (IERC20(token) == usd8) accounted += rewardReserve;
        uint256 bal = IERC20(token).balanceOf(address(this));
        return bal > accounted ? bal - accounted : 0;
    }

    // ─────────────────────────── Views ───────────────────────────

    /// @notice Cumulative reward-per-share now, scaled by {REWARD_SCALE}.
    function rewardPerShare() external view returns (uint256) {
        return _rewardPerShare();
    }

    /// @notice Reward-token amount `user` would receive on {claimReward} now.
    function earned(address user) public view returns (uint256) {
        RewardState storage u = rewardState[user];
        uint256 earningBalance = user == address(this) ? 0 : balanceOf(user);
        return (earningBalance * (_rewardPerShare() - u.userRewardPerSharePaid)) / REWARD_SCALE + u.rewards;
    }

    // ─────────────────────────── Internal: reward math ───────────────────────────

    /// @dev Returns the current scaled cumulative reward per earning share.
    function _rewardPerShare() internal view returns (uint256) {
        uint256 earningShares = _earningShares();
        if (earningShares == 0) return rewardPerShareStored;
        uint256 t = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (t <= lastUpdateTime) return rewardPerShareStored;
        return rewardPerShareStored + ((t - lastUpdateTime) * uint256(rewardRate) * REWARD_SCALE) / earningShares;
    }

    /// @dev before changes, recalculate rewardPerShareStored based on current earningShares amt since it has changed. With no shares, nothing streams:
    ///      rebase the UNSTREAMED remainder to start now (periodFinish = now +
    ///      remaining, lastUpdateTime = now), so the next staker earns it over the
    ///      full remaining duration. Capping the elapsed time at the (possibly long-
    ///      expired) periodFinish instead would leave the deferred window in the past,
    ///      letting the first staker after a long empty gap claim it all instantly (M-01).
    function _checkpointGlobalRewards() internal {
        uint256 earningShares = _earningShares();
        if (earningShares == 0) {
            if (rewardRate != 0 && periodFinish > lastUpdateTime) {
                periodFinish = uint64(block.timestamp) + (periodFinish - lastUpdateTime);
            }
            lastUpdateTime = uint64(block.timestamp);
            return;
        }
        uint256 t = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (t > lastUpdateTime) {
            rewardPerShareStored += ((t - lastUpdateTime) * uint256(rewardRate) * REWARD_SCALE) / earningShares;
        }
        lastUpdateTime = uint64(t);
    }

    /// @dev before changes, Accrues user through the current global reward checkpoint.
    function _checkpointUserRewards(address user) internal {
        RewardState storage u = rewardState[user];
        u.rewards = earned(user);
        u.userRewardPerSharePaid = rewardPerShareStored;
    }

    /// @dev Returns total shares excluding exit escrow held by the pool.
    function _earningShares() internal view returns (uint256) {
        return totalSupply() - balanceOf(address(this));
    }
}
