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
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Registry} from "./Registry.sol";
import {RegistryManaged} from "./RegistryManaged.sol";
import {IProfitDistributionReceiver} from "./interfaces/IProfitDistributionReceiver.sol";

/// @title  SingleAssetCoverPool
/// @notice A single-asset ERC-4626 cover vault that underwrites the USD8 insurance
///         system. Stakers deposit one asset, receive TRANSFERABLE ERC-20 shares
///         (composable with other DeFi), earn USD8 yield, and absorb claim losses
///         pro-rata. Multi-asset coverage is REPLICATION: one pool per asset behind
///         the shared beacon, each registered on the {Registry}.
/// @dev    Deposits are synchronous ERC-4626; REDEMPTION IS ASYNC — request, wait out
///         {UNSTAKE_COOLDOWN}, then redeem within {UNSTAKE_WINDOW}. `maxRedeem` /
///         `maxWithdraw` report the matured request (0 otherwise), so a conformant
///         integrator sees the async gate; the ERC-4626 interface and pricing views
///         are otherwise standard.
///
///         Two-token model: `asset` (ERC-4626 underlying, backs shares) and
///         `rewardToken` (USD8, a SEPARATE Synthetix-style stream claimed via
///         {claimReward}). Rewards survive share transfers — {_update} checkpoints
///         both parties on every mint/burn/transfer.
///
///         totalAssets is INTERNAL accounting ({_accountedAssets}), not balanceOf, so
///         a stray donation can't inflate share price and is swept as surplus; the
///         ERC-4626 virtual-shares offset ({_decimalsOffset}) is the backstop. Losses
///         socialize automatically: {payClaim} reduces _accountedAssets → share price
///         falls. Frozen during an incident ({Registry.payoutIncidentActive}):
///         deposits and redemptions are blocked (max* = 0) so settlement runs against
///         a deterministic pool; transfers stay open (they don't move totalAssets/
///         supply, and the haircut is pro-rata regardless of holder).
/// @custom:security-contact rick@usd8.fi
contract SingleAssetCoverPool is
    Initializable,
    ERC4626Upgradeable,
    ERC20PermitUpgradeable,
    ReentrancyGuardTransient,
    RegistryManaged,
    IProfitDistributionReceiver
{
    using SafeERC20 for IERC20;

    // ─────────────────────────── Constants ───────────────────────────

    /// @notice Cooldown before a filed redeem request may complete.
    uint64 public constant UNSTAKE_COOLDOWN = 7 days;

    /// @notice Window after the cooldown in which the redeem must be completed
    ///         (stkAAVE-style). Shares keep earning the whole time a request is
    ///         pending. Miss it → re-request. Valid over
    ///         [requestedAt + COOLDOWN, requestedAt + COOLDOWN + WINDOW].
    uint64 public constant UNSTAKE_WINDOW = 2 days;

    /// @notice Fixed-point scaling for the {rewardPerShareStored} accumulator
    ///         (Synthetix pattern): the per-share increment floors to 0 without it.
    ///         See earlier revisions for the full precision/overflow rationale.
    uint256 internal constant REWARD_SCALE = 1e30;

    /// @notice Basis-point denominator for {maxPayoutPerIncident} (matches {Registry}).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ─────────────────────────── State ───────────────────────────

    /// @notice The reward token paid to stakers (USD8). Set once at init.
    IERC20 public rewardToken;

    /// @notice Emission window applied to every profit distribution.
    uint64 public rewardsDuration;

    /// @notice Asset the vault accounts as backing shares: staked principal net of
    ///         redemptions and claim payouts. Internal accounting (not balanceOf), so
    ///         donations don't inflate price and are sweepable. {totalAssets} returns it.
    uint256 private _accountedAssets;

    /// @notice Current emission of {rewardToken} per second.
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

    /// @param shares       Shares the user intends to redeem.
    /// @param requestedAt  Timestamp of {requestRedeem}.
    struct UnstakeRequest {
        uint256 shares;
        uint64 requestedAt;
    }

    /// @notice Pending redeem requests, one per user.
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
    error NotDefiInsurance(address caller);
    error PayoutExceedsPoolAssets(uint256 requested, uint256 available);
    error InvalidRecipient();
    error PartialRedeemNotSupported(uint256 requested, uint256 requestShares);
    error FeeOnTransferUnsupported();
    error SharesLockedByRequest(uint256 locked);
    error RewardRateZero(uint256 total, uint256 duration);

    // ─────────────────────────── Events ──────────────────────────

    event RedeemRequested(address indexed user, uint256 shares);
    event RedeemRequestCancelled(address indexed user, uint256 shares);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount, uint128 newRate, uint64 newPeriodFinish);
    event RewardsDurationSet(uint64 oldDuration, uint64 newDuration);
    event ClaimPaid(address indexed to, uint256 amount);

    // ─────────────────────────── Initialization ───────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the beacon proxy. Callable once.
    /// @param _registry    Shared access + pause + freeze registry.
    /// @param _asset        The staked asset / ERC-4626 underlying (non-zero).
    /// @param _rewardToken  The reward token paid to stakers, i.e. USD8 (non-zero).
    /// @param name_         ERC-20 share name (per-pool, e.g. "USD8 wstETH Cover").
    /// @param symbol_       ERC-20 share symbol (per-pool, e.g. "cpwstETH").
    function initialize(
        Registry _registry,
        IERC20 _asset,
        IERC20 _rewardToken,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        if (address(_asset) == address(0) || address(_rewardToken) == address(0)) {
            revert ZeroAddress();
        }
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __ERC4626_init(_asset);
        _setRegistry(_registry);
        rewardToken = _rewardToken;
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

    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }

    /// @dev Rewards survive transfers: checkpoint the accumulator, then both parties'
    ///      earned, BEFORE any balance (and totalSupply) changes.
    ///
    ///      Shares backing a live redeem request are locked in place (M-03): still
    ///      owned, still earning, still payout-exposed — but non-transferable, so the
    ///      cooldown seasons THESE shares. Otherwise a requester could transfer them
    ///      away for the cooldown and re-acquire fresh ones just before maturity,
    ///      trading "seasoned exit capacity" without ever locking capital. Only the
    ///      excess above the requested amount stays transferable; cancel/expiry
    ///      unlocks. The redeem burn itself passes — {_withdraw} deletes the request
    ///      before burning.
    function _update(address from, address to, uint256 value) internal override {
        _checkpointReward();
        if (from != address(0)) {
            _checkpointUser(from);
            UnstakeRequest memory r = unstakeRequests[from];
            if (
                r.shares != 0 && block.timestamp <= uint256(r.requestedAt) + UNSTAKE_COOLDOWN + UNSTAKE_WINDOW
                    && balanceOf(from) < value + r.shares
            ) revert SharesLockedByRequest(r.shares);
        }
        if (to != address(0)) _checkpointUser(to);
        super._update(from, to, value);
    }

    // ─────────────────────────── Deposit (stake) ───────────────────────────

    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        if (registry().payoutIncidentActive()) revert PoolFrozen();
        return super.deposit(assets, receiver);
    }

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

    function maxDeposit(address) public view override returns (uint256) {
        return (registry().paused(address(this)) || registry().payoutIncidentActive()) ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return (registry().paused(address(this)) || registry().payoutIncidentActive()) ? 0 : type(uint256).max;
    }

    // ─────────────────────────── Redeem (async) ───────────────────────────

    /// @notice File an intent to redeem `shares`. Starts the cooldown; the shares
    ///         stay staked (exposed to payouts AND still earning) until redeemed, but
    ///         are locked non-transferable while the request is live (see {_update}).
    ///         One live request per user; an expired one may be overwritten.
    function requestRedeem(uint256 shares) external {
        if (shares == 0) revert ZeroAmount();
        uint256 bal = balanceOf(msg.sender);
        if (bal < shares) revert InsufficientShares(shares, bal);

        UnstakeRequest memory existing = unstakeRequests[msg.sender];
        if (
            existing.shares != 0 && block.timestamp <= uint256(existing.requestedAt) + UNSTAKE_COOLDOWN + UNSTAKE_WINDOW
        ) {
            revert UnstakeRequestExists();
        }

        unstakeRequests[msg.sender] = UnstakeRequest({shares: shares, requestedAt: uint64(block.timestamp)});
        emit RedeemRequested(msg.sender, shares);
    }

    /// @notice Cancel a pending redeem request. Pure bookkeeping.
    function cancelRedeemRequest() external {
        UnstakeRequest memory r = unstakeRequests[msg.sender];
        if (r.shares == 0) revert NoUnstakeRequest();
        delete unstakeRequests[msg.sender];
        emit RedeemRequestCancelled(msg.sender, r.shares);
    }

    /// @notice Complete the caller's matured redeem request in one call (sugar over
    ///         {redeem}), with specific errors for the cooldown/window/freeze gates.
    /// @return assetsOut Asset amount transferred.
    function completeRedeem() external returns (uint256 assetsOut) {
        UnstakeRequest memory r = unstakeRequests[msg.sender];
        if (r.shares == 0) revert NoUnstakeRequest();
        uint256 cooldownEnd = uint256(r.requestedAt) + UNSTAKE_COOLDOWN;
        if (block.timestamp < cooldownEnd) revert CooldownNotElapsed();
        if (block.timestamp > cooldownEnd + UNSTAKE_WINDOW) revert UnstakeWindowExpired();
        if (registry().payoutIncidentActive()) revert PoolFrozen();
        return redeem(r.shares, msg.sender, msg.sender);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    /// @notice Matured redeem amount for `owner`: the full requested shares once the
    ///         cooldown has elapsed and the window hasn't expired, and the pool is
    ///         neither paused nor frozen. 0 otherwise — the async gate integrators read.
    function maxRedeem(address owner) public view override returns (uint256) {
        return _maturedRequestShares(owner);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return previewRedeem(_maturedRequestShares(owner));
    }

    function _maturedRequestShares(address owner) internal view returns (uint256) {
        if (registry().paused(address(this)) || registry().payoutIncidentActive()) return 0;
        UnstakeRequest memory r = unstakeRequests[owner];
        if (r.shares == 0) return 0;
        uint256 cooldownEnd = uint256(r.requestedAt) + UNSTAKE_COOLDOWN;
        if (block.timestamp < cooldownEnd || block.timestamp > cooldownEnd + UNSTAKE_WINDOW) return 0;
        return r.shares;
    }

    /// @dev Redemption funnel: only completes a FULL matured request (maxRedeem gated
    ///      it to that amount); consumes the request and keeps {_accountedAssets} synced.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        UnstakeRequest memory r = unstakeRequests[owner];
        if (shares != r.shares) revert PartialRedeemNotSupported(shares, r.shares);
        delete unstakeRequests[owner];
        _accountedAssets -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ─────────────────────────── Rewards ───────────────────────────

    /// @notice Claim pending reward-token yield without touching the stake.
    /// @return reward The reward token amount transferred to the caller.
    function claimReward() external nonReentrant whenNotPaused returns (uint256 reward) {
        _checkpointReward();
        _checkpointUser(msg.sender);

        RewardState storage u = rewardState[msg.sender];
        reward = u.rewards;
        if (reward == 0) return 0;
        u.rewards = 0;
        rewardReserve -= reward;
        rewardToken.safeTransfer(msg.sender, reward);
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
        if (totalSupply() == 0) revert NoEligibleStakers();

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardReserve += amount;

        _checkpointReward();

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
        if (newDuration == 0) revert InvalidRewardsDuration();
        emit RewardsDurationSet(rewardsDuration, newDuration);
        rewardsDuration = newDuration;
    }

    /// @dev Rescuable via {RegistryManaged-sweepToken}: only balance above accounting.
    ///      Staked principal ({asset} → {_accountedAssets}) and committed rewards
    ///      ({rewardToken} → {rewardReserve}) are protected; the rest is stray.
    ///      Additive so a pool whose asset IS its reward token protects both.
    function _sweepable(address token) internal view override returns (uint256) {
        uint256 accounted;
        if (token == asset()) accounted += _accountedAssets;
        if (IERC20(token) == rewardToken) accounted += rewardReserve;
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
        return (balanceOf(user) * (_rewardPerShare() - u.userRewardPerSharePaid)) / REWARD_SCALE + u.rewards;
    }

    // ─────────────────────────── Internal: reward math ───────────────────────────

    function _rewardPerShare() internal view returns (uint256) {
        uint256 earningShares = totalSupply();
        if (earningShares == 0) return rewardPerShareStored;
        uint256 t = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (t <= lastUpdateTime) return rewardPerShareStored;
        return rewardPerShareStored + ((t - lastUpdateTime) * uint256(rewardRate) * REWARD_SCALE) / earningShares;
    }

    /// @dev Roll rewardPerShareStored forward to now. With no shares, nothing streams:
    ///      rebase the UNSTREAMED remainder to start now (periodFinish = now +
    ///      remaining, lastUpdateTime = now), so the next staker earns it over the
    ///      full remaining duration. Capping the elapsed time at the (possibly long-
    ///      expired) periodFinish instead would leave the deferred window in the past,
    ///      letting the first staker after a long empty gap claim it all instantly (M-01).
    function _checkpointReward() internal {
        uint256 earningShares = totalSupply();
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

    function _checkpointUser(address user) internal {
        RewardState storage u = rewardState[user];
        u.rewards = earned(user);
        u.userRewardPerSharePaid = rewardPerShareStored;
    }
}
