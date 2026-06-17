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
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

/// @title  CoverPool v1
/// @notice Two-sided cover pool for the USD8 system.
///
///         Incident timeline — offsets in days from the first claim that
///         opens the incident (CLAIM_WINDOW=5, ROOT_SUBMIT_CUTOFF=2,
///         DISPUTE_PERIOD=3, FINALIZE_WINDOW=5):
///
///           start=0                                     active to ~13d
///          I1 |--claim window--|--settle--|--dispute--|----finalize window----|
///             0   1   2   3   4   5    6    7      8    9   10   11   12   13
///                                   ^^^^^^^
///             join claims: [0, 5]        submit root: (5, 7]
///             dispute / void: (5, 8]     finalize claims: (8, 13]
///         No standing root at the end of the dispute period (t=8) → the
///         incident is void and every claimant recovers escrow via
///         {withdrawNonFinalizedClaim}. Settlement is processed one incident at a time.
///
///         STAKERS deposit any admin-approved ERC20 ("stake asset") and
///         earn pro-rata USD8 rewards from {notifyReward}. Stake is
///         accounted in shares (`shares` per (asset, user)); the
///         redeemable asset per share floats with the pool's
///         {totalAssets}, so claim payouts that drain {totalAssets}
///         dilute every share-holder of that asset proportionally — i.e.,
///         underwriting losses socialize automatically.
///
///         CLAIMANTS escrow a registered "insured token" (a vault/LP token
///         of a protected protocol). The first claim must {openIncident},
///         which requires a TEE attestation that a covered event occurred on
///         the token (gating out grief opens on healthy tokens); subsequent
///         claims {registerClaim} into the open incident signature-free. After
///         the 5-day claim window the frozen claimant table is settled in
///         one batch by the open-source TEE (incident-block validity,
///         pre-incident TWAP valuation, holding eligibility with
///         cross-claimant dedupe, USD8 history score, coverage factor κ),
///         delivered as a signed merkle root. After a public dispute
///         period, claimants finalize their table row with a merkle proof;
///         escrow forfeits to the protocol. No standing root → incident is
///         void and escrow is recoverable forever via {withdrawNonFinalizedClaim}.
///
///         INCIDENTS are processed strictly one at a time. Opening one (via
///         the TEE-gated {openIncident}) blocks both any other
///         incident from opening and every staker {completeUnstake} until it
///         terminates — giving the TEE a single deterministic pool to
///         compute against and bounding the staker lock to CLAIM_WINDOW +
///         DISPUTE_PERIOD + FINALIZE_WINDOW (13 days). Coverage is therefore
///         single-incident: a protocol exploited while another incident is
///         in flight can only open its own incident once that one resolves.
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
///         3) Insured tokens — submitted by claimants. On finalize they
///            forfeit to the protocol and become admin-sweepable via
///            {sweepInsuredToken}; on cancel they return to the claimant.
/// @custom:security-contact rick@usd8.fi
contract CoverPool is Initializable, EIP712Upgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ─────────────────────────── Constants ───────────────────────────

    /// @notice Length of an incident's claim window. New claims may be
    ///         registered up to {Incident.windowEndTime}; after that, the
    ///         claimant table is frozen and awaits TEE settlement.
    uint64 public constant CLAIM_WINDOW = 5 days;

    /// @notice Settlement root submission cutoff after the claim window
    ///         ends. Submitting up to here guarantees every root sits
    ///         publicly verifiable for at least
    ///         `DISPUTE_PERIOD − ROOT_SUBMIT_CUTOFF` before finalization.
    uint64 public constant ROOT_SUBMIT_CUTOFF = 2 days;

    /// @notice Dispute period after the claim window ends. Until it
    ///         elapses no payout can occur; admin/timelock may
    ///         {voidSettlement} a disputed root. A root standing at the
    ///         end of the period becomes immutable.
    uint64 public constant DISPUTE_PERIOD = 3 days;

    /// @notice Finalization window after the dispute period. Claimants
    ///         redeem their merkle leaf within it; unfinalized claims are
    ///         thereafter only escrow-recoverable via {withdrawNonFinalizedClaim} and
    ///         their payout portion stays in the pool. Bounds total
    ///         staker lock per incident to
    ///         `CLAIM_WINDOW + DISPUTE_PERIOD + FINALIZE_WINDOW` = 13 days.
    uint64 public constant FINALIZE_WINDOW = 5 days;

    /// @notice Standard cooldown applied to an unstake request when there
    ///         are no active incidents. While an incident is in flight,
    ///         {completeUnstake} stays blocked until it terminates, even
    ///         after the 7-day cooldown elapses.
    uint64 public constant UNSTAKE_COOLDOWN = 7 days;

    /// @notice Scaling factor for the per-asset `rewardPerShare`
    ///         accumulator. Sized large enough that sub-1-wei-per-second
    ///         emission rates do not vanish to zero when divided by
    ///         `totalShares`.
    uint256 internal constant REWARD_SCALE = 1e30;

    /// @notice EIP-712 type hash for the batch settlement attestation. The
    ///         TEE consumes the full on-chain claimant table after the
    ///         window closes, verifies every claim off-chain (post-incident
    ///         ratio drop θ, pre-incident TWAP valuation, holding since
    ///         `B − margin` with cross-claimant dedupe, USD8 history score,
    ///         coverage factor κ from {coverageBps}), computes each
    ///         claimant's per-asset payout against the pool composition,
    ///         and signs the merkle root of the resulting table. Leaves are
    ///         `keccak256(bytes.concat(keccak256(abi.encode(incidentId,
    ///         claimId, user, amounts))))` with `amounts` aligned to the
    ///         incident's frozen asset list ({getIncidentAssets}).
    bytes32 public constant SETTLEMENT_TYPEHASH =
        keccak256("Settlement(uint256 incidentId,bytes32 root,bytes32 inputHash)");

    /// @notice EIP-712 type hash for the incident-open attestation. The TEE
    ///         signs this only when its public policy recognizes a covered
    ///         event for `insuredToken` (e.g. a qualifying price drop). It
    ///         binds the exact `incidentId` being assigned (consumed once
    ///         {nextIncidentId} advances → no replay) and a `deadline`
    ///         (so a stale event cannot open an incident later). Gating the
    ///         open here is what prevents griefing LP withdrawals with claims
    ///         on healthy tokens; joining an open incident needs no signature.
    bytes32 public constant OPEN_INCIDENT_TYPEHASH =
        keccak256("OpenIncident(address insuredToken,uint256 incidentId,uint64 deadline)");

    /// @notice Maximum coverage applied to every claim payout, in basis
    ///         points. Ceiling for a insured token's per-protocol coverage
    ///         factor κ ({coverageBps}); no token may cover more than 80%
    ///         of a claimant's USD loss.
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
    /// @param unstakingShares       Shares with a pending unstake request.
    ///                              Still counted in {totalShares} (so they
    ///                              keep absorbing claim payouts) but excluded
    ///                              from the reward base — a position queued
    ///                              to exit stops earning. Reward emission is
    ///                              divided over `totalShares − unstakingShares`.
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
        uint128 unstakingShares;
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

    /// @notice A claim incident: a {CLAIM_WINDOW} opened via {openIncident}
    ///         on a particular insured token; all later claims on the same
    ///         token within the window join it. Settlement is a TEE-signed
    ///         merkle root over the full claimant table, submitted after
    ///         the window:
    ///           windowEnd .. +ROOT_SUBMIT_CUTOFF : root may be submitted
    ///           windowEnd .. +DISPUTE_PERIOD     : root publicly verifiable;
    ///                                              admin/timelock may void
    ///           +DISPUTE_PERIOD .. +FINALIZE_END : claimants finalize with
    ///                                              merkle proofs
    ///         No standing root past the dispute period → incident is void;
    ///         every claimant recovers escrow via {withdrawNonFinalizedClaim}.
    /// @param insuredToken    Insured token being claimed against.
    /// @param windowEndTime   Incident open time + CLAIM_WINDOW. After this
    ///                        moment no new claims are accepted.
    /// @param root            TEE-signed merkle root of the settlement
    ///                        table; 0 if none standing.
    /// @param inputHash       Running commitment to the claimant table:
    ///                        chained over every register and cancel while
    ///                        the window is open. The settlement signature
    ///                        must cover this exact value, so a root
    ///                        computed over a different/reordered/partial
    ///                        table can never verify.
    /// @param claimCount      Number of claims registered.
    /// @param resolvedCount   Claims finalized, cancelled, or withdrawn.
    struct Incident {
        IERC20 insuredToken;
        uint64 windowEndTime;
        bytes32 root;
        bytes32 inputHash;
        uint256 claimCount;
        uint256 resolvedCount;
    }

    /// @notice One user's claim: pure escrow registration. All economics
    ///         (history score, pre-incident TWAP valuation, coverage factor,
    ///         cross-claimant dedupe, payout split) are computed off-chain
    ///         by the TEE over the complete claimant table after the window
    ///         closes, and delivered as the settlement root.
    /// @param user                Claimant.
    /// @param incidentId          Incident this claim belongs to.
    /// @param insuredTokenAmount  Insured token escrowed at registration.
    ///                            Forfeited on finalize; returned on cancel
    ///                            or {withdrawNonFinalizedClaim}.
    /// @param finalized           True once {finalizeClaim} has paid out.
    /// @param closed              True once cancelled or withdrawn.
    struct Claim {
        address user;
        uint256 incidentId;
        uint128 insuredTokenAmount;
        bool finalized;
        bool closed;
    }

    // ─────────────────────────── State (roles) ───────────────────────────

    /// @notice Slow governance role. Holds user-impacting powers: asset and
    ///         insured-token curation, oracles, coverage factors, TEE signer,
    ///         and forfeited-token sweeps. Expected to be a TimelockController.
    address public timelock;

    /// @notice Fast operational role. Runs reward distribution
    ///         ({notifyReward}) and the emission-window parameter.
    address public admin;

    // ─────────────────────────── State (staking & rewards) ───────────────────────────

    /// @notice Token paid as reward to stakers (typically USD8). Set
    ///         once at initialization.
    IERC20 public rewardToken;

    /// @notice Emission window applied to every {notifyReward} call.
    ///         Existing emissions keep their original schedules.
    uint64 public rewardsDuration;

    /// @notice Per-stake-asset state. See {AssetState}.
    mapping(IERC20 asset => AssetState) public assets;

    /// @notice Per-stake-asset, per-user state. See {UserAssetState}.
    mapping(IERC20 asset => mapping(address user => UserAssetState)) public users;

    /// @notice Approved stake assets in admin-determined order.
    IERC20[] public assetList;

    /// @notice Pending unstake requests, one per (asset, user). Setting
    ///         a new request while one is active reverts; cancel first.
    mapping(IERC20 asset => mapping(address user => UnstakeRequest)) public unstakeRequests;

    // ─────────────────────────── State (claims) ───────────────────────────

    /// @notice Admin-approved insured tokens. A insured token is auto-
    ///         delisted (`approved` flipped to false) the moment a claim
    ///         opens an incident on it — only the active incident
    ///         accepts further joins; future incidents require admin
    ///         re-listing via {addInsuredToken}.
    mapping(IERC20 insuredToken => bool) public insuredTokenApproved;

    /// @notice Approved insured tokens in admin-determined order. Entries
    ///         can be present while `insuredTokenApproved` is false
    ///         (after auto-delist) — admin removes them via
    ///         {removeInsuredToken} when appropriate.
    IERC20[] public insuredTokenList;

    /// @notice Per-protocol coverage factor κ for each insured token, in
    ///         basis points (e.g. 8000 = 80%, 7000 = 70%). Set at
    ///         {addInsuredToken}, adjustable via {setCoverageBps}. Public
    ///         economic parameter consumed by the TEE at settlement.
    ///         Always in `(0, MAX_COVERAGE_BPS]` for an approved token.
    mapping(IERC20 insuredToken => uint256) public coverageBps;

    /// @notice Address the open-source TEE signs with. Its ECDSA signatures
    ///         authorize both {openIncident} ({OPEN_INCIDENT_TYPEHASH}) and
    ///         {settleIncident} ({SETTLEMENT_TYPEHASH}). Timelock-settable;
    ///         zero address disables opening and settlement.
    address public teeSigner;

    /// @notice All incidents by id. Id 0 is reserved.
    mapping(uint256 incidentId => Incident) public incidents;

    /// @notice Next incident id to assign. Starts at 1.
    uint256 public nextIncidentId;

    /// @notice The single in-flight incident, or 0 if none. Set when a
    ///         claim opens a fresh incident; a new incident may overwrite it
    ///         only once the prior one is inactive ({_incidentActive}).
    ///         While set and active it blocks both new incidents and staker
    ///         {completeUnstake}, so the TEE always settles against one
    ///         deterministic pool.
    uint256 public activeIncidentId;

    /// @notice Stake-asset list frozen at {settleIncident} time. The
    ///         settlement table's per-claim `amounts[]` align to this
    ///         order. Cleared and re-frozen if a voided root is replaced.
    mapping(uint256 incidentId => IERC20[]) internal incidentAssets;

    /// @notice All claims by id. Id 0 is reserved.
    mapping(uint256 claimId => Claim) public claims;

    /// @notice Next claim id to assign. Starts at 1.
    uint256 public nextClaimId;

    /// @notice Insured token amount forfeited to the protocol by
    ///         finalized claims, available for admin {sweepInsuredToken}.
    ///         Insured tokens escrowed by still-pending or cancelled
    ///         claims are NOT included.
    mapping(IERC20 insuredToken => uint256) public forfeitedInsuredTokens;

    // ─────────────────────────── Errors ──────────────────────────

    /// @notice Thrown on a zero-amount or zero-shares argument.
    error ZeroAmount();

    /// @notice Thrown on a zero-address argument where one is not allowed.
    error ZeroAddress();

    /// @notice Thrown by {setRewardsDuration} or the constructor on a
    ///         zero duration.
    error InvalidRewardsDuration();

    /// @notice Thrown when a coverage factor is zero or above {MAX_COVERAGE_BPS}.
    error InvalidCoverageBps(uint256 given, uint256 max);

    /// @notice Thrown by {addAsset} or {addInsuredToken} when the same
    ///         token would be added as both stake asset and insured token,
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

    /// @notice Thrown when a non-timelock calls a timelock-gated function.
    error UnauthorizedTimelock(address caller);

    /// @notice Thrown when a caller is neither admin nor timelock.
    error UnauthorizedAdmin(address caller);

    /// @notice Thrown by {addInsuredToken} on a duplicate, or by
    ///         {removeInsuredToken} when the insured token is not approved.
    error InsuredTokenAlreadyApproved(IERC20 insuredToken);

    /// @notice Thrown when an operation targets a insured token not on
    ///         the approval list.
    error InsuredTokenNotApproved(IERC20 insuredToken);

    /// @notice Thrown by {registerClaim} when the target insured token's
    ///         current incident has expired its claim window (no new
    ///         claims accepted; insured token delisted).
    error ClaimWindowClosed(IERC20 insuredToken, uint64 windowEndTime);

    /// @notice Thrown by {registerClaim} when no incident on the token is
    ///         currently accepting claims; open one via {openIncident}.
    error NoOpenIncident(IERC20 insuredToken);

    /// @notice Thrown by {openIncident} when the attestation deadline has
    ///         passed.
    error OpenAttestationExpired();

    /// @notice Thrown by {settleIncident} when the signer recovered from
    ///         the signature does not equal {teeSigner}.
    error InvalidSignature();

    /// @notice Thrown by {settleIncident} when {teeSigner} is the zero
    ///         address.
    error TeeSignerUnset();

    /// @notice Thrown when an operation targets a claim id that does
    ///         not exist or is not owned by the caller.
    error UnauthorizedClaim(uint256 claimId);

    /// @notice Thrown when an operation targets a claim that has
    ///         already been finalized, cancelled, or withdrawn.
    error ClaimAlreadyResolved(uint256 claimId);

    /// @notice Thrown by {settleIncident} when the target is not the
    ///         in-flight incident.
    error NotActiveIncident(uint256 incidentId);

    /// @notice Thrown by {settleIncident} before the claim window ends or
    ///         after {ROOT_SUBMIT_CUTOFF}, and by {voidSettlement} after
    ///         {DISPUTE_PERIOD}.
    error OutsideSettlementPhase(uint256 incidentId);

    /// @notice Thrown by {settleIncident} when a root is already standing.
    error RootAlreadySet(uint256 incidentId);

    /// @notice Thrown by {voidSettlement} when no root is standing.
    error NoStandingRoot(uint256 incidentId);

    /// @notice Thrown by {finalizeClaim} outside the finalize window or
    ///         with no standing root.
    error FinalizeNotOpen(uint256 incidentId);

    /// @notice Thrown by {finalizeClaim} when the merkle proof does not
    ///         bind (incidentId, claimId, user, amounts) to the root.
    error InvalidProof(uint256 claimId);

    /// @notice Thrown by {withdrawNonFinalizedClaim} while the claim's incident may
    ///         still settle or finalize.
    error ClaimNotWithdrawable(uint256 claimId);

    /// @notice Thrown by {completeUnstake} when there is no pending
    ///         request for (asset, caller).
    error NoUnstakeRequest();

    /// @notice Thrown by {requestUnstake} when a pending request
    ///         already exists for (asset, caller).
    error UnstakeRequestExists();

    /// @notice Thrown by {completeUnstake} when the 7-day cooldown has
    ///         not elapsed.
    error CooldownNotElapsed();

    /// @notice Thrown by {completeUnstake} while an incident is in flight,
    ///         and by {registerClaim} when a new incident would open while
    ///         one is already in flight.
    error IncidentsActive();

    /// @notice Thrown by {sweepInsuredToken} when admin requests more
    ///         than the forfeited balance.
    error InsufficientForfeited(uint256 requested, uint256 available);

    // ─────────────────────────── Events ──────────────────────────

    /// @notice Emitted when admin approves a stake asset.
    event AssetAdded(IERC20 indexed asset);

    /// @notice Emitted when admin removes an approved stake asset.
    event AssetRemoved(IERC20 indexed asset);

    /// @notice Emitted when admin approves a insured token.
    event InsuredTokenAdded(IERC20 indexed insuredToken);

    /// @notice Emitted when admin sets or updates a insured token's coverage factor.
    event CoverageBpsSet(IERC20 indexed insuredToken, uint256 coverageBps);

    /// @notice Emitted when admin removes a insured token (or it is
    ///         auto-delisted at incident open).
    event InsuredTokenRemoved(IERC20 indexed insuredToken);

    /// @notice Emitted when timelock sets the TEE signer.
    event TeeSignerSet(address indexed oldSigner, address indexed newSigner);

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
    ///         {withdrawYield} or one of the auto-withdraw paths.
    event YieldWithdrawn(IERC20 indexed asset, address indexed user, uint256 amount);

    /// @notice Emitted by {notifyReward}.
    event RewardNotified(IERC20 indexed asset, uint256 amount, uint128 newRate, uint64 newPeriodFinish);

    /// @notice Emitted when admin updates {rewardsDuration}.
    event RewardsDurationSet(uint64 oldDuration, uint64 newDuration);

    /// @notice Emitted when {openIncident} opens an incident on a insured
    ///         token.
    event IncidentOpened(uint256 indexed incidentId, IERC20 indexed insuredToken, uint64 windowEndTime);

    /// @notice Emitted when a TEE settlement root is accepted.
    event IncidentSettled(uint256 indexed incidentId, bytes32 root);

    /// @notice Emitted when admin/timelock voids a standing root.
    event SettlementVoided(uint256 indexed incidentId, address indexed vetoer);

    /// @notice Emitted by {registerClaim}. Together with all other claims
    ///         of the incident this forms the claimant table the TEE
    ///         settles over.
    event ClaimRegistered(
        uint256 indexed claimId, uint256 indexed incidentId, address indexed user, uint128 insuredTokenAmount
    );

    /// @notice Emitted by {finalizeClaim}.
    event ClaimFinalized(uint256 indexed claimId, address indexed user);

    /// @notice Emitted by {cancelRegisteredClaim}.
    event ClaimCancelled(uint256 indexed claimId, address indexed user);

    /// @notice Emitted by {withdrawNonFinalizedClaim} (void or expired incident).
    event ClaimWithdrawn(uint256 indexed claimId, address indexed user);

    /// @notice Emitted by {finalizeClaim} for each stake asset paid out.
    event ClaimPayout(uint256 indexed claimId, IERC20 indexed asset, uint256 amount);

    /// @notice Emitted by {sweepInsuredToken}.
    event InsuredTokenSwept(IERC20 indexed insuredToken, address indexed to, uint256 amount);

    /// @notice Emitted when timelock authority is transferred.
    event TimelockChanged(address indexed oldTimelock, address indexed newTimelock);

    /// @notice Emitted when the fast operational admin is changed.
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);

    // ─────────────────────────── Modifiers ─────────────────────

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert UnauthorizedTimelock(msg.sender);
        _;
    }

    /// @dev Admin runs fast operational flows; timelock retains the same
    ///      authority for governance execution.
    modifier onlyAdminOrTimelock() {
        if (msg.sender != admin && msg.sender != timelock) revert UnauthorizedAdmin(msg.sender);
        _;
    }

    // ─────────────────────────── Constructor / initializer ─────────────────────

    /// @dev Locks the implementation so it can only be used behind a proxy.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. Callable once.
    /// @param _rewardToken      Reward ERC20 (typically USD8). Non-zero.
    /// @param _timelock         Slow governance role (TimelockController).
    ///                          Also authorizes UUPS upgrades.
    /// @param _admin            Fast operational role.
    /// @param _rewardsDuration  Initial emission window for {notifyReward}.
    function initialize(IERC20 _rewardToken, address _timelock, address _admin, uint64 _rewardsDuration)
        external
        initializer
    {
        if (address(_rewardToken) == address(0) || _timelock == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }
        if (_rewardsDuration == 0) revert InvalidRewardsDuration();
        __EIP712_init("USD8 CoverPool", "1");
        rewardToken = _rewardToken;
        timelock = _timelock;
        admin = _admin;
        rewardsDuration = _rewardsDuration;
        nextIncidentId = 1;
        nextClaimId = 1;
    }

    /// @notice Restrict UUPS upgrades to the timelock — the same slow
    ///         governance role that holds the protocol's other privileged
    ///         powers. The implementation address is the only argument the
    ///         base {upgradeToAndCall} needs authorized here.
    function _authorizeUpgrade(address) internal override onlyTimelock {}

    // ═══════════════════════════ Asset management (timelock) ═══════════════════════════

    /// @notice Approve a new stake asset. Timelock only. The asset must be
    ///         non-zero, not the reward token, not already approved as a
    ///         stake asset, and not approved as a insured token. No
    ///         on-chain oracle — all pricing is computed by the TEE at
    ///         settlement.
    function addAsset(IERC20 asset) external onlyTimelock {
        if (address(asset) == address(0)) revert ZeroAddress();
        if (address(asset) == address(rewardToken)) revert TokenConflict();
        if (insuredTokenApproved[asset]) revert TokenConflict();
        if (assets[asset].approved) revert AssetAlreadyApproved(asset);
        assets[asset].approved = true;
        assetList.push(asset);
        emit AssetAdded(asset);
    }

    /// @notice Remove an approved stake asset. Timelock only. Requires
    ///         `totalShares == 0`.
    /// @dev    Swap-and-pop on {assetList}.
    function removeAsset(IERC20 asset) external onlyTimelock {
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

    // ═══════════════════════════ Insured token management (timelock) ═══════════════════════════

    /// @notice Approve a new insured token and set its per-protocol coverage
    ///         factor κ. Timelock only. Must not be the reward token or any
    ///         approved stake asset; `_coverageBps` in `(0, MAX_COVERAGE_BPS]`.
    ///         κ is a public economic parameter consumed by the TEE at
    ///         settlement; no valuation happens on-chain.
    function addInsuredToken(IERC20 insuredToken, uint256 _coverageBps) external onlyTimelock {
        if (address(insuredToken) == address(0)) revert ZeroAddress();
        if (address(insuredToken) == address(rewardToken)) revert TokenConflict();
        if (assets[insuredToken].approved) revert TokenConflict();
        if (insuredTokenApproved[insuredToken]) revert InsuredTokenAlreadyApproved(insuredToken);
        if (_coverageBps == 0 || _coverageBps > MAX_COVERAGE_BPS) {
            revert InvalidCoverageBps(_coverageBps, MAX_COVERAGE_BPS);
        }
        insuredTokenApproved[insuredToken] = true;
        insuredTokenList.push(insuredToken);
        coverageBps[insuredToken] = _coverageBps;
        emit InsuredTokenAdded(insuredToken);
        emit CoverageBpsSet(insuredToken, _coverageBps);
    }

    /// @notice Update a insured token's coverage factor κ. Timelock only.
    ///         Consumed by the TEE when it computes a settlement — takes
    ///         effect for any incident settled after the change.
    ///         `_coverageBps` must be in `(0, MAX_COVERAGE_BPS]`.
    function setCoverageBps(IERC20 insuredToken, uint256 _coverageBps) external onlyTimelock {
        if (!insuredTokenApproved[insuredToken]) revert InsuredTokenNotApproved(insuredToken);
        if (_coverageBps == 0 || _coverageBps > MAX_COVERAGE_BPS) {
            revert InvalidCoverageBps(_coverageBps, MAX_COVERAGE_BPS);
        }
        coverageBps[insuredToken] = _coverageBps;
        emit CoverageBpsSet(insuredToken, _coverageBps);
    }

    /// @notice Remove an approved insured token. Timelock only. Allowed
    ///         even if a prior incident is unresolved — existing claims
    ///         on that incident continue normally; this just prevents
    ///         future re-listings from this entry.
    function removeInsuredToken(IERC20 insuredToken) external onlyTimelock {
        if (!insuredTokenApproved[insuredToken]) revert InsuredTokenNotApproved(insuredToken);
        insuredTokenApproved[insuredToken] = false;
        uint256 n = insuredTokenList.length;
        for (uint256 i = 0; i < n; i++) {
            if (insuredTokenList[i] == insuredToken) {
                insuredTokenList[i] = insuredTokenList[n - 1];
                insuredTokenList.pop();
                break;
            }
        }
        emit InsuredTokenRemoved(insuredToken);
    }

    /// @notice Sweep forfeited insured tokens to a recipient. Admin or
    ///         timelock — forfeited tokens belong to the protocol. Only the
    ///         portion that has accumulated from finalized claims is
    ///         sweepable — insured tokens escrowed by still-pending or
    ///         cancelled claims are untouchable.
    function sweepInsuredToken(IERC20 insuredToken, address to, uint256 amount) external onlyAdminOrTimelock {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 available = forfeitedInsuredTokens[insuredToken];
        if (amount > available) revert InsufficientForfeited(amount, available);
        forfeitedInsuredTokens[insuredToken] = available - amount;
        insuredToken.safeTransfer(to, amount);
        emit InsuredTokenSwept(insuredToken, to, amount);
    }

    // ═══════════════════════════ TEE signer (timelock) ═══════════════════════════

    /// @notice Set the TEE signer that authorizes {openIncident} and
    ///         {settleIncident}. Timelock only. Set to zero to halt new
    ///         incident opening and settlement.
    function setTeeSigner(address newSigner) external onlyTimelock {
        emit TeeSignerSet(teeSigner, newSigner);
        teeSigner = newSigner;
    }

    // ═══════════════════════════ Staker operations ═══════════════════════════

    /// @notice Stake `amount` of `asset`. Caller must have approved
    ///         this contract. Shares minted at the current
    ///         price-per-share: 1:1 when the pool is empty, otherwise
    ///         `amount × totalShares / totalAssets`.
    /// @dev    Blocked while an incident is in flight: with both staking and
    ///         {completeUnstake} frozen for the incident's lifetime, the pool
    ///         balance can only shrink (via payouts), so a settled root can
    ///         never reach capital that arrived after it was computed, and
    ///         fresh deposits are never diluted by a payout they predate.
    function stake(IERC20 asset, uint256 amount) external returns (uint256 sharesMinted) {
        if (amount == 0) revert ZeroAmount();
        if (_hasActiveIncidents()) revert IncidentsActive();
        AssetState storage s = assets[asset];
        if (!s.approved) revert AssetNotApproved(asset);

        _checkpointReward(s);
        _checkpointUser(asset, msg.sender);

        sharesMinted = s.totalShares == 0 ? amount : (amount * uint256(s.totalShares)) / uint256(s.totalAssets);

        asset.safeTransferFrom(msg.sender, address(this), amount);
        s.totalAssets += uint128(amount);
        s.totalShares += uint128(sharesMinted);
        users[asset][msg.sender].shares += uint128(sharesMinted);

        emit Staked(asset, msg.sender, amount, sharesMinted);
    }

    /// @notice File an intent to unstake `shares` of `asset`. Starts the
    ///         7-day cooldown. The shares stay in the pool and remain exposed
    ///         to incident payouts, but they STOP earning rewards for the
    ///         duration of the request — a position queued to exit is no
    ///         longer underwriting-for-yield, so it forgoes emissions until
    ///         it either completes or is cancelled.
    /// @dev    Only one pending request per (asset, caller). Cancel the
    ///         existing one first via {cancelUnstakeRequest}.
    function requestUnstake(IERC20 asset, uint128 shares) external {
        if (shares == 0) revert ZeroAmount();
        AssetState storage s = assets[asset];
        UserAssetState storage u = users[asset][msg.sender];
        if (u.shares < shares) revert InsufficientShares(shares, u.shares);
        if (unstakeRequests[asset][msg.sender].shares != 0) revert UnstakeRequestExists();

        // Settle rewards accrued so far, then drop these shares from the
        // earning base. They keep their {totalShares} weight (still absorbing
        // payouts) but no longer accrue emissions.
        _checkpointReward(s);
        _checkpointUser(asset, msg.sender);
        s.unstakingShares += shares;

        unstakeRequests[asset][msg.sender] = UnstakeRequest({shares: shares, requestedAt: uint64(block.timestamp)});

        emit UnstakeRequested(asset, msg.sender, shares);
    }

    /// @notice Cancel a pending unstake request. The shares are unaffected
    ///         and resume earning rewards from now; only the request record
    ///         is cleared.
    function cancelUnstakeRequest(IERC20 asset) external {
        UnstakeRequest memory r = unstakeRequests[asset][msg.sender];
        if (r.shares == 0) revert NoUnstakeRequest();

        // Settle the (reduced) accrual to now, then return these shares to
        // the earning base so they accrue again going forward.
        AssetState storage s = assets[asset];
        _checkpointReward(s);
        _checkpointUser(asset, msg.sender);
        s.unstakingShares -= r.shares;

        delete unstakeRequests[asset][msg.sender];
        emit UnstakeCancelled(asset, msg.sender, r.shares);
    }

    /// @notice Redeem the shares in a matured unstake request. Requires
    ///         that the cooldown has elapsed AND no incident is in flight.
    ///         Pays out at the live price-per-share and auto-withdraws any
    ///         pending yield (which stopped accruing at {requestUnstake}).
    /// @return assetsOut Amount of `asset` transferred to the caller.
    function completeUnstake(IERC20 asset) external returns (uint256 assetsOut) {
        UnstakeRequest memory r = unstakeRequests[asset][msg.sender];
        if (r.shares == 0) revert NoUnstakeRequest();
        if (block.timestamp < uint256(r.requestedAt) + UNSTAKE_COOLDOWN) revert CooldownNotElapsed();
        if (_hasActiveIncidents()) revert IncidentsActive();

        AssetState storage s = assets[asset];
        _checkpointReward(s);
        _withdrawYield(asset, msg.sender);

        UserAssetState storage u = users[asset][msg.sender];
        if (u.shares < r.shares) revert InsufficientShares(r.shares, u.shares);

        assetsOut = (uint256(r.shares) * uint256(s.totalAssets)) / uint256(s.totalShares);

        u.shares -= r.shares;
        s.totalShares -= r.shares;
        s.unstakingShares -= r.shares;
        s.totalAssets -= uint128(assetsOut);
        delete unstakeRequests[asset][msg.sender];

        asset.safeTransfer(msg.sender, assetsOut);
        emit Unstaked(asset, msg.sender, r.shares, assetsOut);
    }

    /// @notice Withdraw pending reward token (yield) for a single `asset`
    ///         without touching the stake position. Per-asset only — call
    ///         once per staked token. Distinct from the insurance claim flow
    ///         ({registerClaim}/{finalizeClaim}).
    /// @return The reward token amount transferred to the caller.
    function withdrawYield(IERC20 asset) external returns (uint256) {
        return _withdrawYield(asset, msg.sender);
    }

    // ═══════════════════════════ Reward emission (admin) ═══════════════════════════

    /// @notice Top up `asset`'s reward stream. Admin or timelock. Pulls
    ///         atomically; resets the asset's emission window, folding
    ///         leftover into the new rate.
    /// @dev    Requires `totalShares > 0` for the asset.
    function notifyReward(IERC20 asset, uint256 amount) external onlyAdminOrTimelock {
        if (amount == 0) revert ZeroAmount();
        AssetState storage s = assets[asset];
        if (!s.approved) revert AssetNotApproved(asset);
        if (uint256(s.totalShares) - s.unstakingShares == 0) revert NoStakersForAsset(asset);

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
    ///         Admin or timelock. In-flight emissions are unaffected.
    function setRewardsDuration(uint64 newDuration) external onlyAdminOrTimelock {
        if (newDuration == 0) revert InvalidRewardsDuration();
        emit RewardsDurationSet(rewardsDuration, newDuration);
        rewardsDuration = newDuration;
    }

    // ═══════════════════════════ Claim flow (claimant) ═══════════════════════════

    /// @notice Open a new incident on `insuredToken` and register the
    ///         caller's first claim into it, in one call. Gated by a TEE
    ///         attestation: the {teeSigner} signs an {OPEN_INCIDENT_TYPEHASH}
    ///         message only when its public, open-source policy recognizes a
    ///         covered event for the token (e.g. a qualifying price drop in a
    ///         window). This blocks the grief vector of opening incidents on
    ///         healthy tokens to freeze LP withdrawals: no event, no
    ///         attestation, no open. Opening is still permissionless to
    ///         *relay* — anyone holding a valid attestation may submit it.
    ///         The attestation binds (`insuredToken`, the incident id being
    ///         assigned, `deadline`), so it authorizes exactly one open and
    ///         expires; it does not bind the caller or amount.
    /// @param  insuredToken       Token a covered event occurred on.
    /// @param  insuredTokenAmount Caller's escrow for their first claim.
    /// @param  deadline           Attestation expiry (unix seconds).
    /// @param  signature          {teeSigner}'s ECDSA signature over the
    ///                            {OPEN_INCIDENT_TYPEHASH} struct.
    /// @return claimId            The opener's newly minted claim id.
    function openIncident(IERC20 insuredToken, uint128 insuredTokenAmount, uint64 deadline, bytes calldata signature)
        external
        returns (uint256 claimId)
    {
        if (insuredTokenAmount == 0) revert ZeroAmount();
        if (teeSigner == address(0)) revert TeeSignerUnset();
        if (block.timestamp > deadline) revert OpenAttestationExpired();
        if (!insuredTokenApproved[insuredToken]) revert InsuredTokenNotApproved(insuredToken);
        // One incident at a time: the pool settles serially against a single
        // deterministic balance, so no new incident can open while the
        // in-flight one is unresolved.
        if (_hasActiveIncidents()) revert IncidentsActive();

        // The attestation authorizes exactly the id about to be assigned;
        // once consumed `nextIncidentId` advances, so it can never be replayed.
        uint256 incidentId = nextIncidentId;
        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(OPEN_INCIDENT_TYPEHASH, insuredToken, incidentId, deadline)));
        if (ECDSA.recover(digest, signature) != teeSigner) revert InvalidSignature();

        nextIncidentId = incidentId + 1;
        uint64 wEnd = uint64(block.timestamp) + CLAIM_WINDOW;
        incidents[incidentId] = Incident({
            insuredToken: insuredToken,
            windowEndTime: wEnd,
            root: bytes32(0),
            inputHash: bytes32(0),
            claimCount: 0,
            resolvedCount: 0
        });
        activeIncidentId = incidentId;
        _delistInsuredToken(insuredToken);
        emit IncidentOpened(incidentId, insuredToken, wEnd);

        claimId = _registerClaim(insuredToken, insuredTokenAmount, incidentId);
    }

    /// @notice Join the in-flight incident on `insuredToken` with a claim:
    ///         pure escrow, no attestation. Pulls `insuredTokenAmount` and
    ///         records (user, incident, amount). All economics are computed
    ///         by the TEE over the complete claimant table after the window
    ///         closes and delivered via {settleIncident}. Reverts if no
    ///         incident on the token is currently accepting claims — the
    ///         first claim must come through {openIncident}.
    /// @return claimId The newly minted claim id.
    function registerClaim(IERC20 insuredToken, uint128 insuredTokenAmount) external returns (uint256 claimId) {
        if (insuredTokenAmount == 0) revert ZeroAmount();

        // The only joinable incident is the in-flight one, and only while
        // its claim window is open and it covers this token.
        uint256 incidentId = activeIncidentId;
        bool sameToken = incidentId != 0 && incidents[incidentId].insuredToken == insuredToken;
        if (!sameToken || block.timestamp > incidents[incidentId].windowEndTime) {
            if (sameToken) revert ClaimWindowClosed(insuredToken, incidents[incidentId].windowEndTime);
            revert NoOpenIncident(insuredToken);
        }

        claimId = _registerClaim(insuredToken, insuredTokenAmount, incidentId);
    }

    /// @dev Escrow `insuredTokenAmount` and append a claim to `incidentId`,
    ///      chaining the claimant-table commitment. Shared by {openIncident}
    ///      and {registerClaim}; the incident-existence/phase checks are the
    ///      caller's responsibility.
    function _registerClaim(IERC20 insuredToken, uint128 insuredTokenAmount, uint256 incidentId)
        internal
        returns (uint256 claimId)
    {
        insuredToken.safeTransferFrom(msg.sender, address(this), insuredTokenAmount);

        claimId = nextClaimId++;
        claims[claimId] = Claim({
            user: msg.sender,
            incidentId: incidentId,
            insuredTokenAmount: insuredTokenAmount,
            finalized: false,
            closed: false
        });
        Incident storage incRef = incidents[incidentId];
        incRef.claimCount += 1;
        // Chain the claimant table commitment; the settlement signature must
        // cover the final value, binding the TEE to this exact table.
        incRef.inputHash = keccak256(abi.encode(incRef.inputHash, claimId, msg.sender, insuredTokenAmount));

        emit ClaimRegistered(claimId, incidentId, msg.sender, insuredTokenAmount);
    }

    /// @notice Cancel a claim while its window is still open (claimant
    ///         changed their mind). Returns the escrow. After the window
    ///         the table is frozen for settlement — recovery is then via
    ///         {withdrawNonFinalizedClaim} once the incident is void or expired.
    function cancelRegisteredClaim(uint256 claimId) external {
        Claim storage c = claims[claimId];
        if (c.user != msg.sender) revert UnauthorizedClaim(claimId);
        if (c.finalized || c.closed) revert ClaimAlreadyResolved(claimId);

        Incident storage inc = incidents[c.incidentId];
        if (block.timestamp > inc.windowEndTime) revert ClaimWindowClosed(inc.insuredToken, inc.windowEndTime);

        c.closed = true;
        inc.resolvedCount += 1;
        // Cancels mutate the claimant table, so they chain into the
        // commitment too (window is still open here by the check above).
        inc.inputHash = keccak256(abi.encode(inc.inputHash, claimId, "CANCEL"));
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);

        emit ClaimCancelled(claimId, msg.sender);
    }

    // ═══════════════════════════ Settlement (TEE root) ═══════════════════════════

    /// @notice Submit the TEE-signed settlement root for the in-flight
    ///         incident. Permissionless — the signature carries the
    ///         authority. Allowed only in
    ///         `(windowEnd, windowEnd + ROOT_SUBMIT_CUTOFF]`, so the root
    ///         is publicly verifiable for at least
    ///         `DISPUTE_PERIOD − ROOT_SUBMIT_CUTOFF` before any payout.
    ///         Freezes the stake-asset list and per-asset payout caps
    ///         (current `totalAssets`) for the incident.
    function settleIncident(uint256 incidentId, bytes32 root, bytes calldata signature) external {
        if (teeSigner == address(0)) revert TeeSignerUnset();
        if (root == bytes32(0)) revert NoStandingRoot(incidentId);
        if (incidentId != activeIncidentId) revert NotActiveIncident(incidentId);
        Incident storage inc = incidents[incidentId];
        if (block.timestamp <= inc.windowEndTime || block.timestamp > inc.windowEndTime + ROOT_SUBMIT_CUTOFF) {
            revert OutsideSettlementPhase(incidentId);
        }
        if (inc.root != bytes32(0)) revert RootAlreadySet(incidentId);

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(SETTLEMENT_TYPEHASH, incidentId, root, inc.inputHash)));
        if (ECDSA.recover(digest, signature) != teeSigner) revert InvalidSignature();

        inc.root = root;

        // Freeze the stake-asset list so finalize-time `amounts[]` align to
        // the order the TEE signed. No payout cap needed: staking is frozen
        // for the incident's lifetime, so the live balance can only shrink,
        // and {_payRow}'s balance clamp already bounds payouts to the pool.
        delete incidentAssets[incidentId];
        uint256 n = assetList.length;
        for (uint256 i = 0; i < n; i++) {
            incidentAssets[incidentId].push(assetList[i]);
        }

        emit IncidentSettled(incidentId, root);
    }

    /// @notice Void a standing settlement root. Admin or timelock — the
    ///         no-delay brake for a disputed root (anyone can recompute
    ///         the open-source TEE settlement and report a mismatch). Only
    ///         before the dispute period ends; after that a standing root
    ///         is immutable. A corrected root may be resubmitted within
    ///         the submission cutoff; if none stands when the dispute
    ///         period ends, the incident is void and every claimant
    ///         recovers escrow via {withdrawNonFinalizedClaim}.
    ///         Deny-only power: voiding can never redirect funds — worst
    ///         case is denied coverage with all escrow returned.
    function voidSettlement(uint256 incidentId) external onlyAdminOrTimelock {
        Incident storage inc = incidents[incidentId];
        if (inc.root == bytes32(0)) revert NoStandingRoot(incidentId);
        if (block.timestamp > inc.windowEndTime + DISPUTE_PERIOD) {
            revert OutsideSettlementPhase(incidentId);
        }
        inc.root = bytes32(0);
        emit SettlementVoided(incidentId, msg.sender);
    }

    /// @notice Finalize a claim against the standing settlement root.
    ///         Caller must be the claimant; `amounts` is the claimant's
    ///         per-asset payout row from the published settlement table,
    ///         aligned to {getIncidentAssets}; `proof` is its merkle path.
    ///         Only within
    ///         `(windowEnd + DISPUTE_PERIOD, windowEnd + DISPUTE_PERIOD +
    ///         FINALIZE_WINDOW]`. Escrow forfeits to the protocol.
    /// @dev    Payouts are clamped to the pool's live balance in {_payRow};
    ///         with staking frozen for the incident, a malicious root can at
    ///         most drain what the pool held, never more.
    function finalizeClaim(uint256 claimId, uint256[] calldata amounts, bytes32[] calldata proof) external {
        Claim storage c = claims[claimId];
        if (c.user != msg.sender) revert UnauthorizedClaim(claimId);
        if (c.finalized || c.closed) revert ClaimAlreadyResolved(claimId);

        uint256 incidentId = c.incidentId;
        Incident storage inc = incidents[incidentId];
        uint64 disputeEnd = inc.windowEndTime + DISPUTE_PERIOD;
        if (inc.root == bytes32(0) || block.timestamp <= disputeEnd || block.timestamp > disputeEnd + FINALIZE_WINDOW)
        {
            revert FinalizeNotOpen(incidentId);
        }

        {
            if (amounts.length != incidentAssets[incidentId].length) revert InvalidProof(claimId);
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(incidentId, claimId, msg.sender, amounts))));
            if (!MerkleProof.verifyCalldata(proof, inc.root, leaf)) revert InvalidProof(claimId);
        }

        c.finalized = true;
        inc.resolvedCount += 1;

        _payRow(incidentId, claimId, amounts);

        forfeitedInsuredTokens[inc.insuredToken] += c.insuredTokenAmount;

        emit ClaimFinalized(claimId, msg.sender);
    }

    /// @dev Transfer one settlement-table row to the claimant, clamping each
    ///      asset to the pool's live balance. Since staking is frozen for the
    ///      incident's lifetime, that balance never exceeds what the TEE
    ///      computed against — so a malicious root can at most drain the pool,
    ///      never more, and never reach later deposits (there are none).
    function _payRow(uint256 incidentId, uint256 claimId, uint256[] calldata amounts) internal {
        IERC20[] storage assetsAtSettle = incidentAssets[incidentId];
        uint256 n = assetsAtSettle.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            IERC20 a = assetsAtSettle[i];

            AssetState storage s = assets[a];
            if (amount > s.totalAssets) amount = s.totalAssets;
            if (amount == 0) continue;

            s.totalAssets -= uint128(amount);
            a.safeTransfer(msg.sender, amount);
            emit ClaimPayout(claimId, a, amount);
        }
    }

    /// @notice Recover the escrowed insured tokens of a claim that will
    ///         never finalize: its incident is void (no root stood when
    ///         the dispute period ended) or its finalize window expired
    ///         unused. Callable anytime after, forever. The expired
    ///         claim's payout portion stays in the pool and re-accrues
    ///         to stakers.
    function withdrawNonFinalizedClaim(uint256 claimId) external {
        Claim storage c = claims[claimId];
        if (c.user != msg.sender) revert UnauthorizedClaim(claimId);
        if (c.finalized || c.closed) revert ClaimAlreadyResolved(claimId);

        Incident storage inc = incidents[c.incidentId];
        uint64 disputeEnd = inc.windowEndTime + DISPUTE_PERIOD;
        bool incidentVoid = inc.root == bytes32(0) && block.timestamp > disputeEnd;
        bool finalizeExpired = block.timestamp > disputeEnd + FINALIZE_WINDOW;
        if (!incidentVoid && !finalizeExpired) revert ClaimNotWithdrawable(claimId);

        c.closed = true;
        inc.resolvedCount += 1;
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);

        emit ClaimWithdrawn(claimId, msg.sender);
    }

    // ═══════════════════════════ Role management ═══════════════════════════

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

    // ═══════════════════════════ Views ═══════════════════════════

    /// @notice Stake-asset list frozen for `incidentId` at settlement.
    ///         Settlement-table `amounts[]` align to this order.
    function getIncidentAssets(uint256 incidentId) external view returns (IERC20[] memory) {
        return incidentAssets[incidentId];
    }

    /// @notice Cumulative reward-per-share for `asset` at the current
    ///         block, scaled by {REWARD_SCALE}.
    function rewardPerShare(IERC20 asset) external view returns (uint256) {
        return _rewardPerShare(assets[asset]);
    }

    /// @notice Reward token amount `user` would receive on
    ///         {withdrawYield}(asset) right now. Shares under a pending unstake
    ///         request are excluded from the earning balance.
    function earned(IERC20 asset, address user) public view returns (uint256) {
        UserAssetState storage u = users[asset][user];
        uint256 earningShares = uint256(u.shares) - unstakeRequests[asset][user].shares;
        return (earningShares * (_rewardPerShare(assets[asset]) - u.userRewardPerSharePaid)) / REWARD_SCALE + u.rewards;
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

    /// @notice Number of insured tokens currently in the approval list.
    function insuredTokenListLength() external view returns (uint256) {
        return insuredTokenList.length;
    }

    /// @notice True while the in-flight incident is unresolved.
    ///         {completeUnstake} is blocked in this state.
    function hasActiveIncidents() external view returns (bool) {
        return _hasActiveIncidents();
    }

    // ═══════════════════════════ Internal: reward math ═══════════════════════════

    /// @dev Cumulative reward-per-share for `s` at the current block,
    ///      including pending emission since the last checkpoint. Emission is
    ///      divided over the earning base (`totalShares − unstakingShares`),
    ///      so shares queued to unstake do not accrue rewards.
    function _rewardPerShare(AssetState storage s) internal view returns (uint256) {
        uint256 earningShares = uint256(s.totalShares) - s.unstakingShares;
        if (earningShares == 0) return s.rewardPerShareStored;
        uint256 t = block.timestamp < s.periodFinish ? block.timestamp : s.periodFinish;
        if (t <= s.lastUpdateTime) return s.rewardPerShareStored;
        return s.rewardPerShareStored + ((t - s.lastUpdateTime) * uint256(s.rewardRate) * REWARD_SCALE) / earningShares;
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

    /// @dev Checkpoint and pay any pending yield to `user`.
    function _withdrawYield(IERC20 asset, address user) internal returns (uint256 reward) {
        AssetState storage s = assets[asset];
        _checkpointReward(s);
        _checkpointUser(asset, user);

        UserAssetState storage u = users[asset][user];
        reward = u.rewards;
        if (reward == 0) return 0;
        u.rewards = 0;
        rewardToken.safeTransfer(user, reward);
        emit YieldWithdrawn(asset, user, reward);
    }

    // ═══════════════════════════ Internal: incident lifecycle ═══════════════════════════

    /// @dev True while the in-flight incident is unresolved.
    function _hasActiveIncidents() internal view returns (bool) {
        return activeIncidentId != 0 && _incidentActive(activeIncidentId);
    }

    /// @dev An incident is active (blocks {completeUnstake}) until its
    ///      phase machine terminates:
    ///      - through the claim window and dispute period, always;
    ///      - with a standing root, through the finalize window — unless
    ///        every claim is already finalized/cancelled;
    ///      - no standing root after the dispute period → void, inactive
    ///        (claimants recover via {withdrawNonFinalizedClaim}, which never blocks
    ///        stakers).
    function _incidentActive(uint256 incidentId) internal view returns (bool) {
        Incident storage inc = incidents[incidentId];
        uint64 disputeEnd = inc.windowEndTime + DISPUTE_PERIOD;
        if (block.timestamp <= disputeEnd) return true;
        if (inc.root == bytes32(0)) return false; // void — escrow-recovery only
        if (inc.resolvedCount >= inc.claimCount) return false; // fully settled early
        return block.timestamp <= disputeEnd + FINALIZE_WINDOW;
    }

    // ═══════════════════════════ Internal: insured token bookkeeping ═══════════════════════════

    /// @dev Flip a insured token's approved flag off and remove it from
    ///      {insuredTokenList}. No-op if already absent.
    function _delistInsuredToken(IERC20 insuredToken) internal {
        if (!insuredTokenApproved[insuredToken]) return;
        insuredTokenApproved[insuredToken] = false;
        uint256 n = insuredTokenList.length;
        for (uint256 i = 0; i < n; i++) {
            if (insuredTokenList[i] == insuredToken) {
                insuredTokenList[i] = insuredTokenList[n - 1];
                insuredTokenList.pop();
                break;
            }
        }
        emit InsuredTokenRemoved(insuredToken);
    }
}
