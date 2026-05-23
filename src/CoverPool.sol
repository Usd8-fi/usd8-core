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
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IUsdOracle} from "./IUsdOracle.sol";

/// @title  CoverPool v1
/// @notice Two-sided cover pool for the USD8 system.
///
///         STAKERS deposit any admin-approved ERC20 ("stake asset") and
///         earn pro-rata USD8 rewards from {notifyReward}. Stake is
///         accounted in shares (`shares` per (asset, user)); the
///         redeemable asset per share floats with the pool's
///         {totalAssets}, so claim payouts that drain {totalAssets}
///         dilute every share-holder of that asset proportionally — i.e.,
///         underwriting losses socialize automatically.
///
///         CLAIMANTS bring a registered "cover token" (typically an LP
///         token of a protected protocol) plus an off-chain signed USD8
///         history score, register a claim, wait out a 10-day window
///         during which other holders of the same cover token can join,
///         then finalize against a snapshot of the pool to receive a
///         pro-rata slice of every stake asset (`(score / totalScore) ×
///         snapshot[asset]` each).
///
///         INCIDENTS are queued in creation order and finalized
///         strictly serially. Concurrent registration is allowed across
///         different cover tokens, but a later incident cannot finalize
///         until the earlier one is fully resolved (every claim
///         finalized or cancelled). This gives claimants in later
///         incidents a deterministic pool size to decide against.
///         While any incident is unresolved, all stakers'
///         {completeUnstake} calls are blocked — the cooldown effectively
///         extends until the queue is empty.
/// @dev    Per-asset reward math is Synthetix `StakingRewards` over
///         shares (not raw amounts), with linear emission over
///         `rewardsDuration` for JIT defense.
///
///         No receipt token. Stake positions, claims, and unstake
///         requests live in internal storage; cover-pool positions
///         don't typically need active secondary markets.
///
///         The contract holds three distinct asset categories:
///         1) Stake assets — the user-deposited ERC20s, indexed by
///            {assetList}. {totalAssets} per asset tracks the pool
///            balance backing stake shares.
///         2) Reward token — USD8 streamed to stakers via {notifyReward}.
///         3) Cover tokens — submitted by claimants. On finalize they
///            forfeit to the protocol and become admin-sweepable via
///            {sweepCoverToken}; on cancel they return to the claimant.
/// @custom:security-contact rick@usd8.fi
contract CoverPool is Ownable2Step, EIP712 {
    using SafeERC20 for IERC20;

    // ─────────────────────────── Constants ───────────────────────────

    /// @notice Length of an incident's claim window. New claims may be
    ///         registered up to {Incident.windowEndTime}; after that, the
    ///         cover token is delisted (no new claims accepted) and the
    ///         incident awaits its turn in the global queue to be
    ///         finalized.
    uint64 public constant CLAIM_WINDOW = 10 days;

    /// @notice Standard cooldown applied to an unstake request when there
    ///         are no active incidents. If an incident is in the queue,
    ///         {completeUnstake} stays blocked until the queue is empty,
    ///         even after the 2-day cooldown elapses.
    uint64 public constant UNSTAKE_COOLDOWN = 2 days;

    /// @notice Scaling factor for the per-asset `rewardPerShare`
    ///         accumulator. Sized large enough that sub-1-wei-per-second
    ///         emission rates do not vanish to zero when divided by
    ///         `totalShares`.
    uint256 internal constant REWARD_SCALE = 1e30;

    /// @notice EIP-712 type hash for the claim attestation. The off-chain
    ///         signer signs `Claim(user, coverToken, coverTokenAmount,
    ///         score, nonce)`.
    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "Claim(address user,address coverToken,uint128 coverTokenAmount,uint256 score,uint256 nonce)"
    );

    /// @notice Maximum coverage applied to every claim payout, in basis
    ///         points of the claim's USD-valued cover-token loss. Caps
    ///         each user's payout at `lossUsd * MAX_COVERAGE_BPS / 1e4`.
    ///         Hardcoded to 80% — the per-protocol coverage factor κ
    ///         from the website is baked into the off-chain history
    ///         score, not this on-chain cap.
    uint256 public constant MAX_COVERAGE_BPS = 8000;

    /// @notice Denominator for {MAX_COVERAGE_BPS}.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ─────────────────────────── Types ───────────────────────────

    /// @notice Per-stake-asset emission and share state.
    /// @param totalShares           Sum of all user shares for this asset.
    ///                              Drives the per-second reward
    ///                              distribution. Not affected by claim
    ///                              payouts (only stake/unstake adjusts it).
    /// @param totalAssets           Actual asset tokens backing those
    ///                              shares. Decreases on claim payout;
    ///                              the share-to-asset ratio
    ///                              ({totalAssets} / {totalShares})
    ///                              floats with this value.
    /// @param rewardRate            Current emission of {rewardToken} per
    ///                              second for this asset's stakers.
    /// @param periodFinish          Unix timestamp at which the current
    ///                              emission window ends.
    /// @param lastUpdateTime        Timestamp of the most recent reward
    ///                              checkpoint, clamped to `periodFinish`
    ///                              when the window has elapsed.
    /// @param approved              True once admin has approved this
    ///                              asset via {addAsset}; flipped to
    ///                              false on {removeAsset}.
    /// @param rewardPerShareStored  Cumulative reward-per-share at the
    ///                              last checkpoint, scaled by
    ///                              {REWARD_SCALE}.
    struct AssetState {
        uint128 totalShares;
        uint128 totalAssets;
        uint128 rewardRate;
        uint64 periodFinish;
        uint64 lastUpdateTime;
        bool approved;
        uint256 rewardPerShareStored;
    }

    /// @notice Per-asset, per-user share and reward bookkeeping.
    /// @param shares                  User's current stake share count
    ///                                for this asset.
    /// @param userRewardPerSharePaid  Snapshot of `rewardPerShareStored`
    ///                                at the user's last checkpoint.
    /// @param rewards                 Accumulated, not-yet-claimed
    ///                                {rewardToken} amount.
    struct UserAssetState {
        uint128 shares;
        uint256 userRewardPerSharePaid;
        uint256 rewards;
    }

    /// @notice A pending intent to redeem `shares` of `asset` after the
    ///         cooldown. Shares stay in the system (still earning
    ///         rewards and still exposed to claim payouts) during the
    ///         wait — the request only gates {completeUnstake}.
    /// @param shares       Shares the user intends to redeem.
    /// @param requestedAt  Timestamp of {requestUnstake}.
    struct UnstakeRequest {
        uint128 shares;
        uint64 requestedAt;
    }

    /// @notice A claim incident, i.e. a 10-day claim window opened by
    ///         the first claim on a particular cover token. All
    ///         subsequent claims on the same cover token within the
    ///         window join the same incident.
    /// @param coverToken      Cover token being claimed against.
    /// @param startTime       When the first claim opened the incident.
    /// @param windowEndTime   `startTime + CLAIM_WINDOW`. After this
    ///                        moment no new claims are accepted; the
    ///                        cover token is delisted.
    /// @param totalScore      Live sum of scores while the window is
    ///                        open and the incident is not yet
    ///                        snapshotted. Frozen at snapshot.
    /// @param claimCount      Number of claims registered (including
    ///                        any later cancelled).
    /// @param resolvedCount   Number of claims that have been finalized
    ///                        or cancelled.
    /// @param snapshotted     True once {snapshotIncident} has captured
    ///                        the pool composition for this incident.
    /// @param resolved        True once every claim in this incident
    ///                        is finalized or cancelled.
    struct Incident {
        IERC20 coverToken;
        uint64 startTime;
        uint64 windowEndTime;
        uint256 totalScore;
        uint256 claimCount;
        uint256 resolvedCount;
        bool snapshotted;
        bool resolved;
    }

    /// @notice One user's claim against a specific incident.
    /// @param user               Claimant.
    /// @param incidentId         Incident this claim belongs to.
    /// @param coverTokenAmount   Cover token escrowed at registration.
    ///                           Returned on cancel, forfeited on
    ///                           finalize.
    /// @param lossUsd            USD value of `coverTokenAmount` at the
    ///                           registration block, via the cover
    ///                           token's oracle. Frozen for the life
    ///                           of the claim; drives the 80% payout
    ///                           cap (`lossUsd * MAX_COVERAGE_BPS /
    ///                           BPS_DENOMINATOR`).
    /// @param score              History score asserted by the off-chain
    ///                           signer. Determines this claim's share
    ///                           of the incident snapshot.
    /// @param finalized          True once {finalizeClaim} has paid out.
    /// @param cancelled          True once {cancelClaim} has refunded.
    struct Claim {
        address user;
        uint256 incidentId;
        uint128 coverTokenAmount;
        uint256 lossUsd;
        uint256 score;
        bool finalized;
        bool cancelled;
    }

    // ─────────────────────────── State (staking & rewards) ───────────────────────────

    /// @notice Token paid as reward to stakers (typically USD8). Set
    ///         once at construction.
    IERC20 public immutable rewardToken;

    /// @notice Emission window applied to every {notifyReward} call.
    ///         Existing emissions keep their original schedules.
    uint64 public rewardsDuration;

    /// @notice Per-stake-asset state. See {AssetState}.
    mapping(IERC20 asset => AssetState) public assets;

    /// @notice Per-stake-asset, per-user state. See {UserAssetState}.
    mapping(IERC20 asset => mapping(address user => UserAssetState)) public users;

    /// @notice Approved stake assets in admin-determined order.
    IERC20[] public assetList;

    /// @notice Per-token USD oracle, used for both stake assets and
    ///         cover tokens. Admin sets one at registration time via
    ///         {addAsset}/{addCoverToken}; can be rotated later via
    ///         {setOracle}.
    mapping(IERC20 token => IUsdOracle) public oracles;

    /// @notice Pending unstake requests, one per (asset, user). Setting
    ///         a new request while one is active reverts; cancel first.
    mapping(IERC20 asset => mapping(address user => UnstakeRequest)) public unstakeRequests;

    // ─────────────────────────── State (claims) ───────────────────────────

    /// @notice Admin-approved cover tokens. A cover token is auto-
    ///         delisted (`approved` flipped to false) the moment a claim
    ///         opens an incident on it — only the active incident
    ///         accepts further joins; future incidents require admin
    ///         re-listing via {addCoverToken}.
    mapping(IERC20 coverToken => bool) public coverTokenApproved;

    /// @notice Approved cover tokens in admin-determined order. Entries
    ///         can be present while `coverTokenApproved` is false
    ///         (after auto-delist) — admin removes them via
    ///         {removeCoverToken} when appropriate.
    IERC20[] public coverTokenList;

    /// @notice Address whose ECDSA signatures over the {CLAIM_TYPEHASH}
    ///         struct are accepted as proof of a user's history score.
    ///         Admin-settable. Zero address disables claim registration.
    address public claimSigner;

    /// @notice Per-user EIP-712 nonce to prevent signature replay.
    ///         Incremented by every successful {registerClaim}.
    mapping(address user => uint256) public claimNonces;

    /// @notice Currently-open incident for a cover token (0 if none).
    ///         Cleared when the incident is resolved.
    mapping(IERC20 coverToken => uint256 incidentId) public openIncidentByToken;

    /// @notice All incidents by id. Id 0 is reserved.
    mapping(uint256 incidentId => Incident) public incidents;

    /// @notice Next incident id to assign. Starts at 1.
    uint256 public nextIncidentId;

    /// @notice FIFO queue of incident ids in creation order. Finalization
    ///         must walk from `queueHead` forward — only the head
    ///         incident may have claims finalized.
    uint256[] public incidentQueue;

    /// @notice Index into {incidentQueue} of the first unresolved
    ///         incident. Auto-advances past resolved entries.
    uint256 public queueHead;

    /// @notice Snapshot of `totalAssets` per stake asset taken at the
    ///         moment {snapshotIncident} runs for an incident. Drives
    ///         the per-claim asset distribution: each finalize sends
    ///         `(payoutUsd × snapshot[asset]) / incidentPoolUsd` of
    ///         each stake asset.
    mapping(uint256 incidentId => mapping(IERC20 stakeAsset => uint256)) public incidentSnapshot;

    /// @notice Total USD value of the staked pool at {snapshotIncident}
    ///         time, summed across all stake assets via their oracles.
    ///         Used as the denominator for the score-weighted payout
    ///         and as the multiplier for per-asset distribution.
    mapping(uint256 incidentId => uint256) public incidentPoolUsd;

    /// @notice All claims by id. Id 0 is reserved.
    mapping(uint256 claimId => Claim) public claims;

    /// @notice Next claim id to assign. Starts at 1.
    uint256 public nextClaimId;

    /// @notice Cover token amount forfeited to the protocol by
    ///         finalized claims, available for admin {sweepCoverToken}.
    ///         Cover tokens escrowed by still-pending or cancelled
    ///         claims are NOT included.
    mapping(IERC20 coverToken => uint256) public forfeitedCoverTokens;

    // ─────────────────────────── Errors ──────────────────────────

    /// @notice Thrown on a zero-amount or zero-shares argument.
    error ZeroAmount();

    /// @notice Thrown on a zero-address argument where one is not allowed.
    error ZeroAddress();

    /// @notice Thrown by {setRewardsDuration} or the constructor on a
    ///         zero duration.
    error InvalidRewardsDuration();

    /// @notice Thrown by {addAsset} or {addCoverToken} when the same
    ///         token would be added as both stake asset and cover token,
    ///         or when either is the {rewardToken}.
    error TokenConflict();

    /// @notice Thrown when an operation targets a stake asset that has
    ///         not been approved via {addAsset}.
    error AssetNotApproved(IERC20 asset);

    /// @notice Thrown by {addAsset} when the asset is already approved.
    error AssetAlreadyApproved(IERC20 asset);

    /// @notice Thrown by {removeAsset} when the asset still has shares
    ///         outstanding.
    error AssetHasShares(IERC20 asset, uint256 shares);

    /// @notice Thrown by {notifyReward} when nobody has staked into the
    ///         asset yet.
    error NoStakersForAsset(IERC20 asset);

    /// @notice Thrown by {requestUnstake} when the caller requests more
    ///         shares than they hold.
    error InsufficientShares(uint256 requested, uint256 available);

    /// @notice Thrown by {notifyReward} when the computed per-second
    ///         rate would not fit in `uint128`.
    error RewardRateTooHigh();

    /// @notice Thrown by {renounceOwnership}.
    error RenounceOwnershipDisabled();

    /// @notice Thrown by {addCoverToken} on a duplicate, or by
    ///         {removeCoverToken} when the cover token is not approved.
    error CoverTokenAlreadyApproved(IERC20 coverToken);

    /// @notice Thrown when an operation targets a cover token not on
    ///         the approval list.
    error CoverTokenNotApproved(IERC20 coverToken);

    /// @notice Thrown by {registerClaim} when the target cover token's
    ///         current incident has expired its claim window (no new
    ///         claims accepted; cover token delisted).
    error ClaimWindowClosed(IERC20 coverToken, uint64 windowEndTime);

    /// @notice Thrown by {registerClaim} when the signer recovered from
    ///         the signature does not equal {claimSigner}.
    error InvalidSignature();

    /// @notice Thrown by {registerClaim} when {claimSigner} is the zero
    ///         address.
    error ClaimSignerUnset();

    /// @notice Thrown when an operation targets a claim id that does
    ///         not exist or is not owned by the caller.
    error UnauthorizedClaim(uint256 claimId);

    /// @notice Thrown when an operation targets a claim that has
    ///         already been finalized or cancelled.
    error ClaimAlreadyResolved(uint256 claimId);

    /// @notice Thrown by {finalizeClaim} when the claim's incident has
    ///         not yet been snapshotted (either its window hasn't
    ///         elapsed or it's not at the queue head yet).
    error IncidentNotReady(uint256 incidentId);

    /// @notice Thrown by {snapshotIncident} when the target is not at
    ///         the queue head.
    error NotQueueHead(uint256 incidentId);

    /// @notice Thrown by {snapshotIncident} on an incident whose claim
    ///         window has not yet elapsed.
    error WindowNotElapsed(uint256 incidentId);

    /// @notice Thrown by {snapshotIncident} when the incident has
    ///         already been snapshotted.
    error AlreadySnapshotted(uint256 incidentId);

    /// @notice Thrown by {completeUnstake} when there is no pending
    ///         request for (asset, caller).
    error NoUnstakeRequest();

    /// @notice Thrown by {requestUnstake} when a pending request
    ///         already exists for (asset, caller).
    error UnstakeRequestExists();

    /// @notice Thrown by {completeUnstake} when the 2-day cooldown has
    ///         not elapsed.
    error CooldownNotElapsed();

    /// @notice Thrown by {completeUnstake} while any incident in the
    ///         queue remains unresolved.
    error IncidentsActive();

    /// @notice Thrown by {sweepCoverToken} when admin requests more
    ///         than the forfeited balance.
    error InsufficientForfeited(uint256 requested, uint256 available);

    /// @notice Thrown by {setOracle} or registration paths when the
    ///         oracle reference is the zero address.
    error OracleUnset(IERC20 token);

    // ─────────────────────────── Events ──────────────────────────

    /// @notice Emitted when admin approves a stake asset.
    event AssetAdded(IERC20 indexed asset);

    /// @notice Emitted when admin removes an approved stake asset.
    event AssetRemoved(IERC20 indexed asset);

    /// @notice Emitted when admin approves a cover token.
    event CoverTokenAdded(IERC20 indexed coverToken);

    /// @notice Emitted when admin removes a cover token (or it is
    ///         auto-delisted at incident open).
    event CoverTokenRemoved(IERC20 indexed coverToken);

    /// @notice Emitted when admin sets the claim signer.
    event ClaimSignerSet(address indexed oldSigner, address indexed newSigner);

    /// @notice Emitted on a successful {stake}. `sharesMinted` is the
    ///         resulting share count credited to the user.
    event Staked(IERC20 indexed asset, address indexed user, uint256 amount, uint256 sharesMinted);

    /// @notice Emitted when a user files an {requestUnstake}.
    event UnstakeRequested(IERC20 indexed asset, address indexed user, uint256 shares);

    /// @notice Emitted when a user calls {cancelUnstakeRequest}.
    event UnstakeCancelled(IERC20 indexed asset, address indexed user, uint256 shares);

    /// @notice Emitted on a successful {completeUnstake}. `assetsOut`
    ///         is the amount of `asset` transferred to the user.
    event Unstaked(IERC20 indexed asset, address indexed user, uint256 shares, uint256 assetsOut);

    /// @notice Emitted when a user collects accrued reward token via
    ///         {claim} or one of the auto-claim paths.
    event RewardClaimed(IERC20 indexed asset, address indexed user, uint256 amount);

    /// @notice Emitted by {notifyReward}.
    event RewardNotified(IERC20 indexed asset, uint256 amount, uint128 newRate, uint64 newPeriodFinish);

    /// @notice Emitted when admin updates {rewardsDuration}.
    event RewardsDurationSet(uint64 oldDuration, uint64 newDuration);

    /// @notice Emitted when the first claim on a cover token opens an
    ///         incident.
    event IncidentOpened(uint256 indexed incidentId, IERC20 indexed coverToken, uint64 windowEndTime);

    /// @notice Emitted when {snapshotIncident} captures the pool state.
    event IncidentSnapshotted(uint256 indexed incidentId);

    /// @notice Emitted when an incident has been fully resolved.
    event IncidentResolved(uint256 indexed incidentId);

    /// @notice Emitted by {registerClaim}.
    event ClaimRegistered(
        uint256 indexed claimId,
        uint256 indexed incidentId,
        address indexed user,
        uint128 coverTokenAmount,
        uint256 score
    );

    /// @notice Emitted by {finalizeClaim}.
    event ClaimFinalized(uint256 indexed claimId, address indexed user);

    /// @notice Emitted by {cancelClaim}.
    event ClaimCancelled(uint256 indexed claimId, address indexed user);

    /// @notice Emitted by {finalizeClaim} for each stake asset paid out.
    event ClaimPayout(uint256 indexed claimId, IERC20 indexed asset, uint256 amount);

    /// @notice Emitted by {sweepCoverToken}.
    event CoverTokenSwept(IERC20 indexed coverToken, address indexed to, uint256 amount);

    /// @notice Emitted when admin sets or rotates a token's oracle.
    event OracleSet(IERC20 indexed token, IUsdOracle indexed oracle);

    // ─────────────────────────── Constructor ─────────────────────

    /// @notice Deploy a CoverPool.
    /// @param _rewardToken      Reward ERC20 (typically USD8). Non-zero,
    ///                          immutable.
    /// @param _admin            Initial admin.
    /// @param _rewardsDuration  Initial emission window for {notifyReward}.
    constructor(IERC20 _rewardToken, address _admin, uint64 _rewardsDuration)
        Ownable(_admin)
        EIP712("USD8 CoverPool", "1")
    {
        if (address(_rewardToken) == address(0)) revert ZeroAddress();
        if (_rewardsDuration == 0) revert InvalidRewardsDuration();
        rewardToken = _rewardToken;
        rewardsDuration = _rewardsDuration;
        nextIncidentId = 1;
        nextClaimId = 1;
    }

    // ═══════════════════════════ Asset management (admin) ═══════════════════════════

    /// @notice Approve a new stake asset and register its USD oracle.
    ///         Admin only. The asset must be non-zero, not the reward
    ///         token, not already approved as a stake asset, and not
    ///         approved as a cover token. The oracle must be non-zero.
    function addAsset(IERC20 asset, IUsdOracle oracle) external onlyOwner {
        if (address(asset) == address(0)) revert ZeroAddress();
        if (address(oracle) == address(0)) revert OracleUnset(asset);
        if (address(asset) == address(rewardToken)) revert TokenConflict();
        if (coverTokenApproved[asset]) revert TokenConflict();
        if (assets[asset].approved) revert AssetAlreadyApproved(asset);
        assets[asset].approved = true;
        assetList.push(asset);
        oracles[asset] = oracle;
        emit AssetAdded(asset);
        emit OracleSet(asset, oracle);
    }

    /// @notice Remove an approved stake asset. Admin only. Requires
    ///         `totalShares == 0`.
    /// @dev    Swap-and-pop on {assetList}.
    function removeAsset(IERC20 asset) external onlyOwner {
        AssetState storage s = assets[asset];
        if (!s.approved) revert AssetNotApproved(asset);
        if (s.totalShares != 0) revert AssetHasShares(asset, s.totalShares);

        s.approved = false;
        uint256 n = assetList.length;
        for (uint256 i = 0; i < n; i++) {
            if (assetList[i] == asset) {
                assetList[i] = assetList[n - 1];
                assetList.pop();
                break;
            }
        }
        emit AssetRemoved(asset);
    }

    // ═══════════════════════════ Cover token management (admin) ═══════════════════════════

    /// @notice Approve a new cover token and register its USD oracle.
    ///         Admin only. Must not be the reward token or any approved
    ///         stake asset. The oracle must be non-zero.
    function addCoverToken(IERC20 coverToken, IUsdOracle oracle) external onlyOwner {
        if (address(coverToken) == address(0)) revert ZeroAddress();
        if (address(oracle) == address(0)) revert OracleUnset(coverToken);
        if (address(coverToken) == address(rewardToken)) revert TokenConflict();
        if (assets[coverToken].approved) revert TokenConflict();
        if (coverTokenApproved[coverToken]) revert CoverTokenAlreadyApproved(coverToken);
        coverTokenApproved[coverToken] = true;
        coverTokenList.push(coverToken);
        oracles[coverToken] = oracle;
        emit CoverTokenAdded(coverToken);
        emit OracleSet(coverToken, oracle);
    }

    /// @notice Rotate the oracle for a previously-registered token
    ///         (stake asset or cover token). Admin only.
    function setOracle(IERC20 token, IUsdOracle oracle) external onlyOwner {
        if (address(oracle) == address(0)) revert OracleUnset(token);
        oracles[token] = oracle;
        emit OracleSet(token, oracle);
    }

    /// @notice Remove an approved cover token. Admin only. Allowed
    ///         even if a prior incident is unresolved — existing claims
    ///         on that incident continue normally; this just prevents
    ///         future re-listings from this entry.
    function removeCoverToken(IERC20 coverToken) external onlyOwner {
        if (!coverTokenApproved[coverToken]) revert CoverTokenNotApproved(coverToken);
        coverTokenApproved[coverToken] = false;
        uint256 n = coverTokenList.length;
        for (uint256 i = 0; i < n; i++) {
            if (coverTokenList[i] == coverToken) {
                coverTokenList[i] = coverTokenList[n - 1];
                coverTokenList.pop();
                break;
            }
        }
        emit CoverTokenRemoved(coverToken);
    }

    /// @notice Sweep forfeited cover tokens to a recipient. Admin only.
    ///         Only the portion that has accumulated from finalized
    ///         claims is sweepable — cover tokens escrowed by still-
    ///         pending or cancelled claims are untouchable.
    function sweepCoverToken(IERC20 coverToken, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 available = forfeitedCoverTokens[coverToken];
        if (amount > available) revert InsufficientForfeited(amount, available);
        forfeitedCoverTokens[coverToken] = available - amount;
        coverToken.safeTransfer(to, amount);
        emit CoverTokenSwept(coverToken, to, amount);
    }

    // ═══════════════════════════ Claim signer (admin) ═══════════════════════════

    /// @notice Set the address whose signatures attest to USD8 history
    ///         scores. Admin only. Set to zero to halt new claim
    ///         registration.
    function setClaimSigner(address newSigner) external onlyOwner {
        emit ClaimSignerSet(claimSigner, newSigner);
        claimSigner = newSigner;
    }

    // ═══════════════════════════ Staker operations ═══════════════════════════

    /// @notice Stake `amount` of `asset`. Caller must have approved
    ///         this contract. Shares minted at the current
    ///         price-per-share: 1:1 when the pool is empty, otherwise
    ///         `amount × totalShares / totalAssets`.
    /// @dev    Staking during an active incident is allowed but exposes
    ///         the new shares to any remaining claim payouts.
    function stake(IERC20 asset, uint256 amount) external returns (uint256 sharesMinted) {
        if (amount == 0) revert ZeroAmount();
        AssetState storage s = assets[asset];
        if (!s.approved) revert AssetNotApproved(asset);

        _checkpointReward(s);
        _checkpointUser(asset, msg.sender);

        sharesMinted = s.totalShares == 0
            ? amount
            : (amount * uint256(s.totalShares)) / uint256(s.totalAssets);

        asset.safeTransferFrom(msg.sender, address(this), amount);
        s.totalAssets += uint128(amount);
        s.totalShares += uint128(sharesMinted);
        users[asset][msg.sender].shares += uint128(sharesMinted);

        emit Staked(asset, msg.sender, amount, sharesMinted);
    }

    /// @notice File an intent to unstake `shares` of `asset`. Starts
    ///         the 2-day cooldown. Shares remain in the pool (still
    ///         earning rewards and still exposed to incident payouts)
    ///         until {completeUnstake}.
    /// @dev    Only one pending request per (asset, caller). Cancel
    ///         the existing one first via {cancelUnstakeRequest}.
    function requestUnstake(IERC20 asset, uint128 shares) external {
        if (shares == 0) revert ZeroAmount();
        UserAssetState storage u = users[asset][msg.sender];
        if (u.shares < shares) revert InsufficientShares(shares, u.shares);
        if (unstakeRequests[asset][msg.sender].shares != 0) revert UnstakeRequestExists();

        unstakeRequests[asset][msg.sender] =
            UnstakeRequest({shares: shares, requestedAt: uint64(block.timestamp)});

        emit UnstakeRequested(asset, msg.sender, shares);
    }

    /// @notice Cancel a pending unstake request. The shares are
    ///         unaffected; only the request record is cleared.
    function cancelUnstakeRequest(IERC20 asset) external {
        UnstakeRequest memory r = unstakeRequests[asset][msg.sender];
        if (r.shares == 0) revert NoUnstakeRequest();
        delete unstakeRequests[asset][msg.sender];
        emit UnstakeCancelled(asset, msg.sender, r.shares);
    }

    /// @notice Redeem the shares in a matured unstake request. Requires
    ///         that the cooldown has elapsed AND the incident queue is
    ///         empty. Pays out at the live price-per-share and
    ///         auto-claims any pending rewards.
    /// @return assetsOut Amount of `asset` transferred to the caller.
    function completeUnstake(IERC20 asset) external returns (uint256 assetsOut) {
        UnstakeRequest memory r = unstakeRequests[asset][msg.sender];
        if (r.shares == 0) revert NoUnstakeRequest();
        if (block.timestamp < uint256(r.requestedAt) + UNSTAKE_COOLDOWN) revert CooldownNotElapsed();
        if (_hasActiveIncidents()) revert IncidentsActive();

        AssetState storage s = assets[asset];
        _checkpointReward(s);
        _claim(asset, msg.sender);

        UserAssetState storage u = users[asset][msg.sender];
        if (u.shares < r.shares) revert InsufficientShares(r.shares, u.shares);

        assetsOut = (uint256(r.shares) * uint256(s.totalAssets)) / uint256(s.totalShares);

        u.shares -= r.shares;
        s.totalShares -= r.shares;
        s.totalAssets -= uint128(assetsOut);
        delete unstakeRequests[asset][msg.sender];

        asset.safeTransfer(msg.sender, assetsOut);
        emit Unstaked(asset, msg.sender, r.shares, assetsOut);
    }

    /// @notice Claim pending reward token for a single `asset` without
    ///         touching the stake position.
    /// @return The reward token amount transferred to the caller.
    function claim(IERC20 asset) external returns (uint256) {
        return _claim(asset, msg.sender);
    }

    /// @notice Claim across every currently-approved stake asset.
    /// @return total Reward token amount transferred to the caller.
    function claimAll() external returns (uint256 total) {
        uint256 n = assetList.length;
        for (uint256 i = 0; i < n; i++) {
            total += _claim(assetList[i], msg.sender);
        }
    }

    // ═══════════════════════════ Reward emission (admin) ═══════════════════════════

    /// @notice Top up `asset`'s reward stream. Admin only. Pulls
    ///         atomically; resets the asset's emission window, folding
    ///         leftover into the new rate.
    /// @dev    Requires `totalShares > 0` for the asset.
    function notifyReward(IERC20 asset, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        AssetState storage s = assets[asset];
        if (!s.approved) revert AssetNotApproved(asset);
        if (s.totalShares == 0) revert NoStakersForAsset(asset);

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        _checkpointReward(s);

        uint256 newRate;
        if (block.timestamp >= s.periodFinish) {
            newRate = amount / rewardsDuration;
        } else {
            uint256 leftover = (s.periodFinish - block.timestamp) * s.rewardRate;
            newRate = (amount + leftover) / rewardsDuration;
        }
        if (newRate > type(uint128).max) revert RewardRateTooHigh();

        s.rewardRate = uint128(newRate);
        s.lastUpdateTime = uint64(block.timestamp);
        s.periodFinish = uint64(block.timestamp + rewardsDuration);

        emit RewardNotified(asset, amount, uint128(newRate), s.periodFinish);
    }

    /// @notice Set the emission window for future {notifyReward} calls.
    ///         Admin only. In-flight emissions are unaffected.
    function setRewardsDuration(uint64 newDuration) external onlyOwner {
        if (newDuration == 0) revert InvalidRewardsDuration();
        emit RewardsDurationSet(rewardsDuration, newDuration);
        rewardsDuration = newDuration;
    }

    // ═══════════════════════════ Claim flow (claimant) ═══════════════════════════

    /// @notice Register a new claim. Pulls `coverTokenAmount` of
    ///         `coverToken` in escrow and binds the call to the signed
    ///         (user, coverToken, amount, score, nonce) tuple.
    ///         If `coverToken` already has an open incident, the new
    ///         claim joins it (must be within the 10-day window);
    ///         otherwise a fresh incident is opened and the cover
    ///         token auto-delisted.
    /// @param coverToken         Cover token being claimed against.
    ///                           Must be approved.
    /// @param coverTokenAmount   Amount of cover token to escrow.
    /// @param score              Off-chain-attested history score.
    /// @param signature          EIP-712 signature over the
    ///                           {CLAIM_TYPEHASH} struct by
    ///                           {claimSigner}. Binds the current
    ///                           user nonce.
    /// @return claimId           The newly minted claim id.
    function registerClaim(
        IERC20 coverToken,
        uint128 coverTokenAmount,
        uint256 score,
        bytes calldata signature
    ) external returns (uint256 claimId) {
        if (claimSigner == address(0)) revert ClaimSignerUnset();
        if (coverTokenAmount == 0) revert ZeroAmount();
        if (!coverTokenApproved[coverToken] && openIncidentByToken[coverToken] == 0) {
            revert CoverTokenNotApproved(coverToken);
        }

        // Signature verification (current nonce, then bump).
        uint256 nonce = claimNonces[msg.sender];
        bytes32 structHash = keccak256(
            abi.encode(CLAIM_TYPEHASH, msg.sender, address(coverToken), coverTokenAmount, score, nonce)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        if (ECDSA.recover(digest, signature) != claimSigner) revert InvalidSignature();
        claimNonces[msg.sender] = nonce + 1;

        coverToken.safeTransferFrom(msg.sender, address(this), coverTokenAmount);

        IUsdOracle oracle = oracles[coverToken];
        if (address(oracle) == address(0)) revert OracleUnset(coverToken);
        uint256 lossUsd = oracle.getUsdValue(coverTokenAmount);

        uint256 incidentId = openIncidentByToken[coverToken];
        if (incidentId == 0) {
            // Open new incident; auto-delist the cover token from future
            // re-claim until admin re-adds it.
            incidentId = nextIncidentId++;
            uint64 wEnd = uint64(block.timestamp) + CLAIM_WINDOW;
            incidents[incidentId] = Incident({
                coverToken: coverToken,
                startTime: uint64(block.timestamp),
                windowEndTime: wEnd,
                totalScore: 0,
                claimCount: 0,
                resolvedCount: 0,
                snapshotted: false,
                resolved: false
            });
            openIncidentByToken[coverToken] = incidentId;
            incidentQueue.push(incidentId);
            _delistCoverToken(coverToken);
            emit IncidentOpened(incidentId, coverToken, wEnd);
        } else {
            Incident storage inc = incidents[incidentId];
            if (block.timestamp > inc.windowEndTime) {
                revert ClaimWindowClosed(coverToken, inc.windowEndTime);
            }
        }

        claimId = nextClaimId++;
        claims[claimId] = Claim({
            user: msg.sender,
            incidentId: incidentId,
            coverTokenAmount: coverTokenAmount,
            lossUsd: lossUsd,
            score: score,
            finalized: false,
            cancelled: false
        });

        Incident storage incRef = incidents[incidentId];
        incRef.totalScore += score;
        incRef.claimCount += 1;

        emit ClaimRegistered(claimId, incidentId, msg.sender, coverTokenAmount, score);
    }

    /// @notice Cancel a claim. Anytime before finalize. Returns the
    ///         escrowed cover tokens to the caller. If called before
    ///         the incident is snapshotted, the score is removed from
    ///         the incident total; after snapshot, totalScore is frozen
    ///         and the cancelled claim simply forfeits its share to
    ///         the residual.
    function cancelClaim(uint256 claimId) external {
        Claim storage c = claims[claimId];
        if (c.user != msg.sender) revert UnauthorizedClaim(claimId);
        if (c.finalized || c.cancelled) revert ClaimAlreadyResolved(claimId);

        Incident storage inc = incidents[c.incidentId];

        c.cancelled = true;
        inc.resolvedCount += 1;
        if (!inc.snapshotted) {
            inc.totalScore -= c.score;
        }

        IERC20 token = inc.coverToken;
        token.safeTransfer(msg.sender, c.coverTokenAmount);

        emit ClaimCancelled(claimId, msg.sender);

        _tryResolveIncident(c.incidentId);
    }

    /// @notice Snapshot the queue-head incident's stake pool. Callable
    ///         by anyone once the incident is at queueHead and its
    ///         claim window has elapsed.
    function snapshotIncident(uint256 incidentId) external {
        _advanceQueue();
        if (incidentQueue.length == 0 || incidentQueue[queueHead] != incidentId) {
            revert NotQueueHead(incidentId);
        }
        Incident storage inc = incidents[incidentId];
        if (block.timestamp <= inc.windowEndTime) revert WindowNotElapsed(incidentId);
        if (inc.snapshotted) revert AlreadySnapshotted(incidentId);

        inc.snapshotted = true;
        uint256 n = assetList.length;
        uint256 poolUsd = 0;
        for (uint256 i = 0; i < n; i++) {
            IERC20 a = assetList[i];
            uint256 amt = uint256(assets[a].totalAssets);
            incidentSnapshot[incidentId][a] = amt;
            if (amt == 0) continue;
            IUsdOracle oracle = oracles[a];
            if (address(oracle) == address(0)) revert OracleUnset(a);
            poolUsd += oracle.getUsdValue(amt);
        }
        incidentPoolUsd[incidentId] = poolUsd;

        // No further claims can join after window expires; nothing to
        // do for the cover token here (it was auto-delisted at open).

        emit IncidentSnapshotted(incidentId);

        // If the incident has zero outstanding claims (all already
        // cancelled), resolve immediately.
        _tryResolveIncident(incidentId);
    }

    /// @notice Finalize a claim after its incident has been
    ///         snapshotted. Pays out `(score / totalScore) ×
    ///         snapshot[asset]` of each approved stake asset to the
    ///         caller; forfeits the cover tokens to the protocol.
    function finalizeClaim(uint256 claimId) external {
        Claim storage c = claims[claimId];
        if (c.user != msg.sender) revert UnauthorizedClaim(claimId);
        if (c.finalized || c.cancelled) revert ClaimAlreadyResolved(claimId);

        Incident storage inc = incidents[c.incidentId];
        if (!inc.snapshotted) revert IncidentNotReady(c.incidentId);

        c.finalized = true;
        inc.resolvedCount += 1;

        uint256 totalScore = inc.totalScore;
        uint256 poolUsd = incidentPoolUsd[c.incidentId];

        // Score-weighted share, capped at 80% of the claimant's USD
        // loss. Residual (when the cap binds) stays in the pool and
        // re-accrues to stakers.
        uint256 rawShareUsd = totalScore == 0 ? 0 : (c.score * poolUsd) / totalScore;
        uint256 capUsd = (c.lossUsd * MAX_COVERAGE_BPS) / BPS_DENOMINATOR;
        uint256 payoutUsd = rawShareUsd < capUsd ? rawShareUsd : capUsd;

        if (payoutUsd > 0 && poolUsd > 0) {
            uint256 n = assetList.length;
            for (uint256 i = 0; i < n; i++) {
                IERC20 a = assetList[i];
                uint256 snap = incidentSnapshot[c.incidentId][a];
                if (snap == 0) continue;
                // Per-asset distribution: flat fraction of each asset's
                // snapshot. The oracle prices cancel in this ratio, so
                // no re-quote is needed at finalize time.
                uint256 payout = (payoutUsd * snap) / poolUsd;
                if (payout == 0) continue;
                AssetState storage s = assets[a];
                if (payout > s.totalAssets) payout = s.totalAssets;
                s.totalAssets -= uint128(payout);
                a.safeTransfer(msg.sender, payout);
                emit ClaimPayout(claimId, a, payout);
            }
        }

        forfeitedCoverTokens[inc.coverToken] += c.coverTokenAmount;

        emit ClaimFinalized(claimId, msg.sender);

        _tryResolveIncident(c.incidentId);
    }

    // ═══════════════════════════ Ownership ═══════════════════════════

    /// @notice Disabled. Reverts with {RenounceOwnershipDisabled}.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    // ═══════════════════════════ Views ═══════════════════════════

    /// @notice Cumulative reward-per-share for `asset` at the current
    ///         block, scaled by {REWARD_SCALE}.
    function rewardPerShare(IERC20 asset) external view returns (uint256) {
        return _rewardPerShare(assets[asset]);
    }

    /// @notice Reward token amount `user` would receive on
    ///         {claim}(asset) right now.
    function earned(IERC20 asset, address user) public view returns (uint256) {
        UserAssetState storage u = users[asset][user];
        return (uint256(u.shares) * (_rewardPerShare(assets[asset]) - u.userRewardPerSharePaid))
            / REWARD_SCALE + u.rewards;
    }

    /// @notice Total shares outstanding for `asset`.
    function totalShares(IERC20 asset) external view returns (uint256) {
        return assets[asset].totalShares;
    }

    /// @notice Actual asset tokens held backing those shares.
    function totalAssets(IERC20 asset) external view returns (uint256) {
        return assets[asset].totalAssets;
    }

    /// @notice Shares currently held by `user` in `asset`.
    function userShares(IERC20 asset, address user) external view returns (uint256) {
        return users[asset][user].shares;
    }

    /// @notice Number of currently-approved stake assets.
    function assetListLength() external view returns (uint256) {
        return assetList.length;
    }

    /// @notice Number of cover tokens currently in the approval list.
    function coverTokenListLength() external view returns (uint256) {
        return coverTokenList.length;
    }

    /// @notice Total incidents created so far (resolved or not).
    function incidentQueueLength() external view returns (uint256) {
        return incidentQueue.length;
    }

    /// @notice True while at least one incident in the queue is
    ///         unresolved. {completeUnstake} is blocked in this state.
    function hasActiveIncidents() external view returns (bool) {
        return _hasActiveIncidents();
    }

    // ═══════════════════════════ Internal: reward math ═══════════════════════════

    /// @dev Cumulative reward-per-share for `s` at the current block,
    ///      including pending emission since the last checkpoint.
    function _rewardPerShare(AssetState storage s) internal view returns (uint256) {
        if (s.totalShares == 0) return s.rewardPerShareStored;
        uint256 t = block.timestamp < s.periodFinish ? block.timestamp : s.periodFinish;
        if (t <= s.lastUpdateTime) return s.rewardPerShareStored;
        return s.rewardPerShareStored
            + ((t - s.lastUpdateTime) * uint256(s.rewardRate) * REWARD_SCALE) / s.totalShares;
    }

    /// @dev Roll `s.rewardPerShareStored` forward to now and update
    ///      `lastUpdateTime`.
    function _checkpointReward(AssetState storage s) internal {
        s.rewardPerShareStored = _rewardPerShare(s);
        s.lastUpdateTime = uint64(block.timestamp < s.periodFinish ? block.timestamp : s.periodFinish);
    }

    /// @dev Materialize the user's outstanding reward into
    ///      `users[asset][user].rewards` and snapshot
    ///      `userRewardPerSharePaid`.
    function _checkpointUser(IERC20 asset, address user) internal {
        UserAssetState storage u = users[asset][user];
        u.rewards = earned(asset, user);
        u.userRewardPerSharePaid = assets[asset].rewardPerShareStored;
    }

    /// @dev Checkpoint and pay any pending reward to `user`.
    function _claim(IERC20 asset, address user) internal returns (uint256 reward) {
        AssetState storage s = assets[asset];
        _checkpointReward(s);
        _checkpointUser(asset, user);

        UserAssetState storage u = users[asset][user];
        reward = u.rewards;
        if (reward == 0) return 0;
        u.rewards = 0;
        rewardToken.safeTransfer(user, reward);
        emit RewardClaimed(asset, user, reward);
    }

    // ═══════════════════════════ Internal: incident queue ═══════════════════════════

    /// @dev True if there is at least one unresolved incident in the
    ///      queue from `queueHead` onward.
    function _hasActiveIncidents() internal view returns (bool) {
        uint256 len = incidentQueue.length;
        for (uint256 i = queueHead; i < len; i++) {
            if (!incidents[incidentQueue[i]].resolved) return true;
        }
        return false;
    }

    /// @dev Walk `queueHead` past any leading resolved incidents.
    function _advanceQueue() internal {
        uint256 len = incidentQueue.length;
        while (queueHead < len && incidents[incidentQueue[queueHead]].resolved) {
            queueHead += 1;
        }
    }

    /// @dev If every claim in the incident is finalized or cancelled
    ///      AND the incident has been snapshotted (or has zero claims
    ///      and window has elapsed), mark it resolved.
    function _tryResolveIncident(uint256 incidentId) internal {
        Incident storage inc = incidents[incidentId];
        if (inc.resolved) return;
        if (!inc.snapshotted) return;
        if (inc.resolvedCount < inc.claimCount) return;

        inc.resolved = true;
        delete openIncidentByToken[inc.coverToken];
        emit IncidentResolved(incidentId);
        _advanceQueue();
    }

    // ═══════════════════════════ Internal: cover token bookkeeping ═══════════════════════════

    /// @dev Flip a cover token's approved flag off and remove it from
    ///      {coverTokenList}. No-op if already absent.
    function _delistCoverToken(IERC20 coverToken) internal {
        if (!coverTokenApproved[coverToken]) return;
        coverTokenApproved[coverToken] = false;
        uint256 n = coverTokenList.length;
        for (uint256 i = 0; i < n; i++) {
            if (coverTokenList[i] == coverToken) {
                coverTokenList[i] = coverTokenList[n - 1];
                coverTokenList.pop();
                break;
            }
        }
        emit CoverTokenRemoved(coverToken);
    }
}
