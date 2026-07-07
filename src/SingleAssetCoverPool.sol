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
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Registry} from "./Registry.sol";
import {Managed} from "./Managed.sol";
import {IProfitDistributionReceiver} from "./interfaces/IProfitDistributionReceiver.sol";

/// @title  SingleAssetCoverPool
/// @notice A single-asset staking pool that underwrites the USD8 insurance
///         system. Stakers deposit one asset to earn USD8 yield and absorb claim
///         losses pro-rata; the pool tracks each staker's share, streams rewards
///         (Synthetix StakingRewards over shares, linear over {rewardsDuration}
///         for JIT defense), and pays claims out of pooled capital. Multi-asset
///         coverage is REPLICATION: deploy one pool per asset behind the shared
///         beacon and register each on the {Registry}; cross-pool profit routing
///         is the Treasury's receiver weights, so no per-asset weighting here.
/// @dev    Beacon-upgradeable (all pools upgrade in one `beacon.upgradeTo`). No
///         per-instance immutables — `asset`/`rewardToken` are set in
///         {initialize}. The system-wide incident freeze is delegated to the
///         {Registry} ({Registry.frozen}); while frozen, stakes and
///         {completeUnstake} are blocked so a settlement runs against a
///         deterministic pool. Scored tokens, the booster, and the payout module
///         all live on the Registry.
/// @custom:security-contact rick@usd8.fi
contract SingleAssetCoverPool is Initializable, ReentrancyGuardTransient, Managed, IProfitDistributionReceiver {
    using SafeERC20 for IERC20;

    // ─────────────────────────── Constants ───────────────────────────

    /// @notice Cooldown before a filed unstake request may complete.
    uint64 public constant UNSTAKE_COOLDOWN = 7 days;

    /// @notice Window after the cooldown in which {completeUnstake} must be called
    ///         (stkAAVE-style). Shares keep earning the whole time a request is
    ///         pending, so a matured request is a standing cost-free exit; bounding
    ///         it stops requests parking forever. Miss it → re-request. Completion
    ///         is valid over [requestedAt + COOLDOWN, requestedAt + COOLDOWN + WINDOW].
    uint64 public constant UNSTAKE_WINDOW = 2 days;

    /// @notice Scaling factor for the rewardPerShare accumulator.
    uint256 internal constant REWARD_SCALE = 1e30;

    /// @notice Sink for the permanent seed shares (see {seed}). Uncontrollable, so
    ///         those shares can never unstake — totalShares stays > 0 for good.
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    /// @notice Basis-point denominator for {maxPayoutPerIncident} (matches {Registry}).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ─────────────────────────── State ───────────────────────────

    /// @notice The staked asset (backs shares). Set once at init.
    IERC20 public asset;

    /// @notice The reward token paid to stakers (USD8). Set once at init.
    IERC20 public rewardToken;

    /// @notice Whether the one-time permanent seed has been supplied. See {seed}.
    bool public seeded;

    /// @notice Emission window applied to every profit distribution.
    uint64 public rewardsDuration;

    /// @notice Sum of all staker shares.
    uint256 public totalShares;

    /// @notice Actual asset tokens backing those shares. Decreases on claim
    ///         payout; assets-per-share floats with it (loss socialization).
    uint256 public totalAssets;

    /// @notice Current emission of {rewardToken} per second.
    uint128 public rewardRate;

    /// @notice Unix timestamp the emission window ends.
    uint64 public periodFinish;

    /// @notice Timestamp of the last reward checkpoint.
    uint64 public lastUpdateTime;

    /// @notice Cumulative reward-per-share at the last checkpoint, scaled by {REWARD_SCALE}.
    uint256 public rewardPerShareStored;

    /// @notice Reward token committed to stakers but not yet paid out (undripped
    ///         emissions + accrued-unclaimed). {_sweepable} treats reward-token
    ///         balance above this as recoverable while committed rewards stay untouchable.
    uint256 public rewardReserve;

    /// @param shares                  Staker's current share count.
    /// @param userRewardPerSharePaid  rewardPerShareStored snapshot at last checkpoint.
    /// @param rewards                 Accumulated, not-yet-claimed reward token.
    struct UserState {
        uint256 shares;
        uint256 userRewardPerSharePaid;
        uint256 rewards;
    }

    /// @notice Per-user share + reward bookkeeping.
    mapping(address user => UserState) public userState;

    /// @param shares       Shares the user intends to redeem.
    /// @param requestedAt  Timestamp of {requestUnstake}.
    struct UnstakeRequest {
        uint256 shares;
        uint64 requestedAt;
    }

    /// @notice Pending unstake requests, one per user.
    mapping(address user => UnstakeRequest) public unstakeRequests;

    // ─────────────────────────── Errors ──────────────────────────

    error ZeroAmount();
    error InvalidRewardsDuration();
    error NoEligibleStakers();
    error InsufficientShares(uint256 requested, uint256 available);
    error RewardRateTooHigh();
    error NoUnstakeRequest();
    error UnstakeRequestExists();
    error CooldownNotElapsed();
    error UnstakeWindowExpired();
    error PoolFrozen();
    error NotPayoutModule(address caller);
    error PayoutExceedsPoolAssets(uint256 requested, uint256 available);
    error InvalidRecipient();
    error AlreadySeeded();
    error NotSeeded();

    // ─────────────────────────── Events ──────────────────────────

    event Staked(address indexed user, uint256 amount, uint256 sharesMinted);
    event UnstakeRequested(address indexed user, uint256 shares);
    event UnstakeCancelled(address indexed user, uint256 shares);
    event Unstaked(address indexed user, uint256 shares, uint256 assetsOut);
    event YieldWithdrawn(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount, uint128 newRate, uint64 newPeriodFinish);
    event RewardsDurationSet(uint64 oldDuration, uint64 newDuration);
    event ClaimPaid(address indexed to, uint256 amount);
    event Seeded(address indexed from, uint256 amount, uint256 sharesMinted);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the beacon proxy. Callable once.
    /// @param _authority    Shared access + pause + freeze registry.
    /// @param _asset        The staked asset (non-zero).
    /// @param _rewardToken  The reward token paid to stakers, i.e. USD8 (non-zero).
    function initialize(Registry _authority, IERC20 _asset, IERC20 _rewardToken) external initializer {
        if (address(_asset) == address(0) || address(_rewardToken) == address(0)) revert ZeroAddress();
        _setAuthority(_authority);
        asset = _asset;
        rewardToken = _rewardToken;
        rewardsDuration = 7 days;
    }

    /// @notice Supply the one-time permanent seed. Pulls `amount` of {asset} from the
    ///         caller and mints matching shares to an uncontrollable burn sink (never
    ///         withdrawable). A real (non-zero) seed guarantees totalShares > 0 for
    ///         the pool's lifetime, so a profit distribution never reverts
    ///         {NoEligibleStakers} — production pools MUST seed a meaningful amount.
    ///         Permissionless and idempotent-once; mirrors {stake}'s price-per-share
    ///         so it is safe to call even if a stake already landed. The seed shares
    ///         accrue yield that is likewise locked. (amount == 0 merely opens the
    ///         {seeded} gate with no locked capital — a degenerate case, not for prod.)
    ///
    ///         ⚠️ MUST be called immediately after deployment, as the very next step
    ///         in the same deploy sequence that creates the pool and BEFORE the pool
    ///         is exposed to anyone. {stake} reverts {NotSeeded} until this runs, so
    ///         an unseeded pool is inert — but do not register it, route Treasury
    ///         profit to it, or advertise it before seeding.
    function seed(uint256 amount) external nonReentrant {
        if (seeded) revert AlreadySeeded();
        _checkpointReward();

        uint256 received = _pullToken(asset, msg.sender, amount);

        uint256 sharesMinted = totalShares == 0
            ? received
            : totalAssets == 0 ? received * totalShares : (received * totalShares) / totalAssets;

        seeded = true;
        totalAssets += received;
        totalShares += sharesMinted;
        userState[BURN].shares += sharesMinted;

        emit Seeded(msg.sender, received, sharesMinted);
    }

    // ═══════════════════════════ Staking ═══════════════════════════

    /// @notice Stake amount of {asset}. Shares mint at the current price-per-share
    ///         (1:1 when empty). Reverts until the pool is seeded (see {seed}), and
    ///         is blocked while paused or while the system is frozen for an incident
    ///         — with stakes and {completeUnstake} both blocked, the balance can
    ///         only shrink, so a settled root can't reach later capital.
    /// @return sharesMinted Shares credited for the amount actually received.
    function stake(uint256 amount) external nonReentrant whenNotPaused returns (uint256 sharesMinted) {
        if (!seeded) revert NotSeeded();
        if (amount == 0) revert ZeroAmount();
        if (authority.frozen()) revert PoolFrozen();

        _checkpointReward();
        _checkpointUser(msg.sender);

        uint256 received = _pullToken(asset, msg.sender, amount);
        if (received == 0) revert ZeroAmount();

        // Price-per-share = totalAssets / totalShares. The per-incident payout cap
        // (Registry.maxPayoutBps < 100%, enforced at settle) keeps an honest
        // settlement from ever draining totalAssets to 0, so the middle branch is a
        // safety net. Should it ever be reached — totalAssets == 0 with shares
        // outstanding — the normal branch would div-by-zero and brick the pool; mint
        // received * totalShares instead so fresh capital recapitalizes and the dead
        // shares collectively reclaim < 1 base unit.
        sharesMinted = totalShares == 0
            ? received
            : totalAssets == 0 ? received * totalShares : (received * totalShares) / totalAssets;

        totalAssets += received;
        totalShares += sharesMinted;
        userState[msg.sender].shares += sharesMinted;

        emit Staked(msg.sender, received, sharesMinted);
    }

    /// @notice File an intent to unstake shares. Starts the cooldown; the shares
    ///         stay fully staked (exposed to payouts AND still earning) until
    ///         {completeUnstake}. One live request per user; an expired one may be
    ///         overwritten.
    function requestUnstake(uint256 shares) external {
        if (shares == 0) revert ZeroAmount();
        UserState storage u = userState[msg.sender];
        if (u.shares < shares) revert InsufficientShares(shares, u.shares);

        UnstakeRequest memory existing = unstakeRequests[msg.sender];
        if (
            existing.shares != 0 && block.timestamp <= uint256(existing.requestedAt) + UNSTAKE_COOLDOWN + UNSTAKE_WINDOW
        ) {
            revert UnstakeRequestExists();
        }

        unstakeRequests[msg.sender] = UnstakeRequest({shares: shares, requestedAt: uint64(block.timestamp)});
        emit UnstakeRequested(msg.sender, shares);
    }

    /// @notice Cancel a pending unstake request. Pure bookkeeping — the shares kept
    ///         earning throughout, so no reward state to touch.
    function cancelUnstakeRequest() external {
        UnstakeRequest memory r = unstakeRequests[msg.sender];
        if (r.shares == 0) revert NoUnstakeRequest();
        delete unstakeRequests[msg.sender];
        emit UnstakeCancelled(msg.sender, r.shares);
    }

    /// @notice Redeem the shares in a matured request. Requires cooldown elapsed,
    ///         window not expired, and the system not frozen. Pays at the live
    ///         price-per-share; pending yield is checkpointed, not paid (claim via
    ///         {withdrawYield}).
    /// @return assetsOut Amount of asset transferred to the caller.
    function completeUnstake() external nonReentrant whenNotPaused returns (uint256 assetsOut) {
        UnstakeRequest memory r = unstakeRequests[msg.sender];
        if (r.shares == 0) revert NoUnstakeRequest();
        uint256 cooldownEnd = uint256(r.requestedAt) + UNSTAKE_COOLDOWN;
        if (block.timestamp < cooldownEnd) revert CooldownNotElapsed();
        if (block.timestamp > cooldownEnd + UNSTAKE_WINDOW) revert UnstakeWindowExpired();
        if (authority.frozen()) revert PoolFrozen();

        _checkpointReward();
        _checkpointUser(msg.sender);

        UserState storage u = userState[msg.sender];
        if (u.shares < r.shares) revert InsufficientShares(r.shares, u.shares);

        assetsOut = (r.shares * totalAssets) / totalShares;

        u.shares -= r.shares;
        totalShares -= r.shares;
        totalAssets -= assetsOut;
        delete unstakeRequests[msg.sender];

        // assetsOut rounds to 0 only after a payout drove totalAssets far below
        // totalShares. Still burn the shares so the staker can exit; skip the
        // zero transfer (some ERC20s revert on it, which would brick the exit).
        if (assetsOut > 0) asset.safeTransfer(msg.sender, assetsOut);
        emit Unstaked(msg.sender, r.shares, assetsOut);
    }

    /// @notice Withdraw pending reward-token yield without touching the stake.
    /// @return reward The reward token amount transferred to the caller.
    function withdrawYield() external nonReentrant whenNotPaused returns (uint256 reward) {
        _checkpointReward();
        _checkpointUser(msg.sender);

        UserState storage u = userState[msg.sender];
        reward = u.rewards;
        if (reward == 0) return 0;
        u.rewards = 0;
        rewardReserve -= reward;
        rewardToken.safeTransfer(msg.sender, reward);
        emit YieldWithdrawn(msg.sender, reward);
    }

    // ═══════════════════════════ Profit distribution ═══════════════════════════

    /// @notice Receive a reward-token profit distribution and stream it to stakers.
    ///         Pulls amount from msg.sender (the Treasury approves then calls this).
    ///         Permissionless — anyone may donate. Reverts {NoEligibleStakers} if
    ///         the pool has no shares (nothing to stream), so the caller keeps funds.
    ///         No weights or dust loop — cross-pool routing is the Treasury's
    ///         receiver weights.
    function receiveProfitDistribution(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (totalShares == 0) revert NoEligibleStakers();

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardReserve += amount;
        _streamReward(amount);
    }

    /// @dev Stream amount to stakers, folding any undripped leftover into a new
    ///      rate. The new end-time is a USD-amount-weighted average of the
    ///      remaining schedule and a fresh {rewardsDuration}, so a tiny donation
    ///      barely moves the schedule while a large one behaves like a fresh window.
    ///
    ///      ACCEPTED (audit L-01/C6): `newRate = total / newDuration` floors, so the
    ///      remainder (`total mod newDuration`, always < newDuration ≤ rewardsDuration
    ///      = 604800) is never streamed. It was already added to {rewardReserve} in
    ///      full by {receiveProfitDistribution}, so it stays there — protected by
    ///      {_sweepable} (accounted as owed) yet unclaimable (never in any staker's
    ///      earned) and unstreamed. We deliberately DO NOT roll it forward or make it
    ///      sweepable: at < ~6e-13 USD8 per distribution it is economically zero, and
    ///      the extra state/branch isn't worth it. Dust of this size is ignored by
    ///      design across the pool.
    function _streamReward(uint256 amount) internal {
        _checkpointReward();

        uint256 remaining = block.timestamp < periodFinish ? periodFinish - block.timestamp : 0;
        uint256 leftover = remaining * rewardRate;
        uint256 total = leftover + amount;
        if (total == 0) return;
        uint256 newDuration = (leftover * remaining + amount * rewardsDuration) / total;
        if (newDuration == 0) newDuration = rewardsDuration; // defensive (remaining==0 path)
        uint256 newRate = total / newDuration;
        if (newRate > type(uint128).max) revert RewardRateTooHigh();

        rewardRate = uint128(newRate);
        lastUpdateTime = uint64(block.timestamp);
        periodFinish = uint64(block.timestamp + newDuration);

        emit RewardNotified(amount, uint128(newRate), periodFinish);
    }

    // ═══════════════════════════ Payout hook ═══════════════════════════

    /// @notice The most this pool may pay out for one incident: {totalAssets} ×
    ///         {Registry.maxPayoutBps} / 10_000. At settle the payout module checks
    ///         the TEE-committed per-pool total against this (the pool is frozen, so
    ///         it equals the balance the incident opened on) AND records it as the
    ///         pool's per-incident budget, which finalize draws down — so the actual
    ///         summed payout is hard-capped here, bounding LP loss per incident.
    function maxPayoutPerIncident() external view returns (uint256) {
        return totalAssets * authority.maxPayoutBps() / BPS_DENOMINATOR;
    }

    /// @notice Pay a settlement amount out of pooled capital. The single registered
    ///         payout module only ({Registry.payoutModule}). An amount exceeding the
    ///         live {totalAssets} reverts; the per-incident cap ({maxPayoutPerIncident})
    ///         is enforced up front at settle, not here, so this stays a simple
    ///         balance check. Reduces {totalAssets}, socializing the loss across stakers.
    /// @dev    whenNotPaused: pausing this pool mid-incident blocks every
    ///         finalization whose payout routes through it (finalizeClaim reverts
    ///         on the payClaim call). Accepted — pause is a trusted-admin emergency
    ///         lever; claimants recover escrow via withdrawNonFinalizedClaim once
    ///         the finalize window lapses, and admin can unpause to let finalization
    ///         resume. See {Registry.setPaused}.
    /// @param to      Claimant to pay.
    /// @param amount  Asset amount to pay (0 = no-op for this pool's row).
    function payClaim(address to, uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender != authority.payoutModule()) revert NotPayoutModule(msg.sender);
        // Paying the pool itself would drop totalAssets while the tokens stay put,
        // silently reclassifying staker principal as sweepable surplus.
        if (to == address(this)) revert InvalidRecipient();
        if (amount == 0) return;
        if (amount > totalAssets) revert PayoutExceedsPoolAssets(amount, totalAssets);
        totalAssets -= amount;
        asset.safeTransfer(to, amount);
        emit ClaimPaid(to, amount);
    }

    // ═══════════════════════════ Admin ═══════════════════════════

    /// @notice Set the emission window for future distributions. Admin or timelock.
    ///         In-flight emissions are unaffected.
    function setRewardsDuration(uint64 newDuration) external onlyAdminOrTimelock {
        if (newDuration == 0) revert InvalidRewardsDuration();
        emit RewardsDurationSet(rewardsDuration, newDuration);
        rewardsDuration = newDuration;
    }

    /// @dev Rescuable via {Managed-sweepToken}: only balance above accounting.
    ///      Staked principal ({asset}) and committed rewards ({rewardReserve} of
    ///      the reward token) are protected; anything else is a stray, fully
    ///      sweepable. Accumulate additively so a pool whose asset IS its reward
    ///      token protects totalAssets + rewardReserve, not just one.
    function _sweepable(address token) internal view override returns (uint256) {
        uint256 accounted;
        if (IERC20(token) == asset) accounted += totalAssets;
        if (IERC20(token) == rewardToken) accounted += rewardReserve;
        uint256 bal = IERC20(token).balanceOf(address(this));
        return bal > accounted ? bal - accounted : 0;
    }

    // ═══════════════════════════ Views ═══════════════════════════

    /// @notice Cumulative reward-per-share now, scaled by {REWARD_SCALE}.
    function rewardPerShare() external view returns (uint256) {
        return _rewardPerShare();
    }

    /// @notice Reward-token amount user would receive on {withdrawYield} now.
    function earned(address user) public view returns (uint256) {
        UserState storage u = userState[user];
        return (u.shares * (_rewardPerShare() - u.userRewardPerSharePaid)) / REWARD_SCALE + u.rewards;
    }

    /// @notice Shares currently held by user.
    function userShares(address user) external view returns (uint256) {
        return userState[user].shares;
    }

    // ═══════════════════════════ Internal: reward math ═══════════════════════════

    function _rewardPerShare() internal view returns (uint256) {
        uint256 earningShares = totalShares;
        if (earningShares == 0) return rewardPerShareStored;
        uint256 t = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (t <= lastUpdateTime) return rewardPerShareStored;
        return rewardPerShareStored + ((t - lastUpdateTime) * uint256(rewardRate) * REWARD_SCALE) / earningShares;
    }

    /// @dev Roll rewardPerShareStored forward to now. With no shares staked, defer
    ///      the elapsed emission by pushing periodFinish out by the same span so it
    ///      re-streams once stakers return (Synthetix carry-forward), rather than
    ///      stranding it in rewardReserve.
    function _checkpointReward() internal {
        uint256 earningShares = totalShares;
        uint256 t = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (t > lastUpdateTime) {
            if (earningShares == 0) {
                if (rewardRate != 0) periodFinish += uint64(t - lastUpdateTime);
            } else {
                rewardPerShareStored += ((t - lastUpdateTime) * uint256(rewardRate) * REWARD_SCALE) / earningShares;
            }
        }
        lastUpdateTime = uint64(t);
    }

    function _checkpointUser(address user) internal {
        UserState storage u = userState[user];
        u.rewards = earned(user);
        u.userRewardPerSharePaid = rewardPerShareStored;
    }

    /// @dev Pull amount of token, returning the actual balance delta (fee-on-transfer
    ///      safety net; such tokens are unsupported). Runs under {nonReentrant}.
    function _pullToken(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
    }
}
