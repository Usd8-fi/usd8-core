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
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Registry} from "./Registry.sol";
import {RegistryManaged} from "./RegistryManaged.sol";

/// @notice Minimal view of the deployed ERC-1155 USD8Booster: standard
///         transfers plus the ERC1155Burnable batch burn (this contract, as
///         the token holder, is authorized to call it). Boosters are
///         semi-fungible — id denotes a tier (id 1 = the 1% booster), held in
///         quantity — so commits always work in (ids, amounts) batches.
interface IERC1155Burnable is IERC1155 {
    function burn(address account, uint256 id, uint256 value) external;
}

/// @notice Minimal view of a single-asset stake pool. DefiInsurance is the
///         {Registry.defiInsurance}: it reads the registered pool set from the
///         Registry and pays each its settlement-row amount out of pooled capital.
///         Pools are product-agnostic; the insurance logic lives here.
interface ISingleAssetCoverPool {
    function payClaim(address to, uint256 amount) external;
    function totalAssets() external view returns (uint256);
    function maxPayoutPerIncident() external view returns (uint256);
}

/// @title  DefiInsurance v1
/// @notice DeFi-depeg insurance built on the {SingleAssetCoverPool} capital base
///         (one pool per stake asset, registered on the {Registry}). Holders of a
///         covered token that suffers a depeg escrow it here and are paid out of the
///         pools' staked capital. This contract owns all product logic — insured-token
///         registry, the four-phase claim lifecycle, claimant escrow, settlement — and
///         calls the pools only to pay ({SingleAssetCoverPool.payClaim}). It is the
///         single {Registry.defiInsurance}; the score a claim consumes is recorded as a
///         {ScoreSpent} event plus a cumulative total on the {Registry}.
///
///         ONE claim at a time: while a claim is live the whole system is frozen
///         ({Registry.payoutIncidentActive}) — CoverPool exits and topology curation
///         (pool set, scored tokens) are blocked — so settlement runs against a single
///         deterministic pool set. The freeze is implicit: the pools read the Registry,
///         which reads this module's {activeIncidentId}.
///
///         FOUR PHASES. Durations are the state constants; every CoverPool stays LOCKED
///         from the start of CLAIM until FINALIZE ends (or the claim voids in SETTLE):
///
///           CLAIM ({CLAIM_WINDOW}, 5d) — the FIRST {joinClaim} on a token opens the
///             window (there is no separate open step) and locks every CoverPool. That
///             first claim carries a TEE attestation — the enclave, running the
///             published depeg-detection code, signs {OPEN_TYPEHASH} (the same trust
///             root that signs SETTLE) — and anyone may relay it. Later claimants just
///             {joinClaim} (no attestation) / {cancelClaim} for the rest of the window.
///             The admin/timelock {openClaimIncident} is a claim-less fallback for when
///             the TEE is down/censoring or the event can't be attested. The open block
///             is recorded ({Incident.openBlock}) so the settlement config (insured-token
///             recipe, scored-token set) is reconstructible from on-chain state at that
///             block, immune to any later retune.
///
///           SETTLE ({SUBMIT_DEADLINE}, 0–3d after CLAIM) — anyone may {settleIncident}
///             with the settlement merkle root computed off-chain over the claim set,
///             carrying an EIP-712 signature from any authorized {isTeeSigner}
///             enclave key held only inside a published TEE build that runs the
///             open-source settlement code. The
///             root is the dispute anchor: each per-claim payout is proven against it at
///             FINALIZE, so a payout can only be one that survived DISPUTE. Optimistic —
///             anyone reproduces the root. ONE TEE settlement per incident (no resubmit);
///             a bad root is disputed by governance and re-rooted by the timelock, not
///             overwritten by another TEE root. If NO root is posted by the deadline the
///             claim VOIDS: escrow becomes recoverable and the CoverPools reopen.
///
///           DISPUTE ({DISPUTE_PERIOD}, 2d after a root is posted) — no payouts yet. The
///             admin/timelock reviews the settled (TEE-signed) root and may act on it —
///             deny-only, never redirects funds: {closeIncident} terminates it (unfreeze,
///             escrow recoverable), or {disputeIncident} halts it (pool stays frozen
///             awaiting a timelock {correctSettlement}, which supplies the right root and
///             runs a fresh DISPUTE → FINALIZE; auto-voids past {CORRECTION_WINDOW}).
///             This is the LAST stage either is allowed; after it the root is final.
///
///           FINALIZE ({FINALIZE_WINDOW}, 0–4d after DISPUTE) — each claimant
///             {finalizeClaim}s to pull their payout, proven against the final root. No
///             intervention possible. The CoverPools REOPEN the instant the last claim
///             finalizes — often well before the window ends.
///
///         Total CoverPool lock: CLAIM + [0, SETTLE] + DISPUTE + FINALIZE = 11–14 days
///         (≈8 days if the claim voids in SETTLE). Early reopen: a {closeIncident} ends it
///         any time up to the end of DISPUTE; all-finalized ends it inside FINALIZE. A
///         {disputeIncident} instead holds the freeze until the correction finalizes or the
///         window
///         lapses.
/// @dev    Non-upgradeable. To change it, deploy a fresh instance and re-point the
///         {Registry} payout-module slot (only between claims — the old instance still
///         custodies escrow + live claims). Custodies insured-token escrow only;
///         committed boosters stay in the claimant's wallet and are burned from it at
///         FINALIZE (not escrowed here).
contract DefiInsurance is ReentrancyGuardTransient, EIP712, RegistryManaged {
    using SafeERC20 for IERC20;

    // ─────────────────────────── State ───────────────────────────

    /// @notice Authorized TEE settlement/open signers (1-of-N): ANY one's EIP-712
    ///         signature is accepted at {settleIncident} and the {joinClaim} open
    ///         path. Timelock-managed via {setTeeSigner} — add the new key on each
    ///         enclave upgrade before removing the old (gap-free rotation), run
    ///         several for redundancy/liveness, or empty the set to disable the
    ///         signed paths. address(0) is never authorized, so a malformed
    ///         signature (which recovers to 0) can never pass. TRUST NOTE:
    ///         weakest-link — a compromise of ANY authorized key can sign a root or
    ///         a spurious open, bounded (as with one signer) by the DISPUTE window,
    ///         the per-pool cap, and {closeIncident}.
    mapping(address signer => bool) public isTeeSigner;

    // ─────────────────────────── State (insured tokens) ───────────────────────────

    /// @notice Basis-point denominator (100%) and the hard ceiling for a token's
    ///         coverage factor κ ({InsuredToken.maxCoverageBps}): κ ∈ (0, 100%].
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Per-insured-token config. maxCoverageBps == 0 means not listed.
    /// @param maxCoverageBps  Coverage factor κ, in (0, 100%] (bps) while listed: the
    ///                      fraction of a claimant's FULL pre-incident eligible value
    ///                      this product covers — a BUYOUT, not loss indemnity (audit
    ///                      D-01): the claimant forfeits the eligible tokens at
    ///                      {finalizeClaim}, so the payout is priced off what they
    ///                      were worth before the incident, and the protocol keeps
    ///                      their residual value. The off-chain settler caps each
    ///                      payout at κ × that value,
    ///                      payoutUsd = min(spentShare × poolUsd, κ × lossUsd). Only
    ///                      stored/validated on-chain; the κ cap is applied
    ///                      off-chain at settlement, so κ appears in no on-chain formula.
    /// @param underlyingPriceOracle  underlying→USD oracle (Chainlink AggregatorV3
    ///                      interface; for non-USD/comparative/LP underlyings,
    ///                      point at an adapter conforming to it). Settlement
    ///                      valuation ONLY — never decides whether an incident
    ///                      opens. Must be a MARKET-price feed, not another
    ///                      internal rate: coverage pays underlying-equivalent
    ///                      value at window-end, so an underlying depeg is
    ///                      meant to (and only can) reduce payouts if this
    ///                      feed actually reports it.
    /// @param underlyingConversionAddress  token→underlying rate source, read
    ///                      ONLY off-chain by the settler at historical blocks:
    ///                      staticcall(addr, callData) must return a single
    ///                      WAD-scaled uint256 (underlying per 1e18 of the
    ///                      insured token). underlyingPriceOracle then turns
    ///                      underlying into USD. address(0) = identity (the
    ///                      token IS the underlying, ratio 1e18). Recipes:
    ///                      4626 vault → convertToAssets(1e18); LST → its rate
    ///                      getter; a thin adapter for anything exotic.
    /// @param underlyingConversionCallData  calldata for that staticcall (empty
    ///                      when underlyingConversionAddress == address(0)).
    struct InsuredToken {
        uint256 maxCoverageBps;
        address underlyingPriceOracle;
        address underlyingConversionAddress;
        bytes underlyingConversionCallData;
    }

    /// @notice Per-insured-token config. maxCoverageBps == 0 is the not-listed
    ///         signal. Auto-delisted the moment an incident opens on it.
    ///         Read via {getInsuredToken}.
    mapping(IERC20 insuredToken => InsuredToken) internal insuredTokens;

    /// @notice Listed insured tokens in admin-determined order.
    IERC20[] public insuredTokenList;

    // ─────────────────────────── State (claim lifecycle) ───────────────────────────

    /// @notice Length of the CLAIM phase: the window in which claimants may
    ///         {joinClaim} / {cancelClaim} after the first open locks the CoverPools.
    uint64 public constant CLAIM_WINDOW = 5 days;

    /// @notice Length of the SETTLE phase: the deadline to submit a settlement root,
    ///         measured from the CLAIM phase end. No root by then ⇒ the claim voids and
    ///         escrow is recoverable.
    uint64 public constant SUBMIT_DEADLINE = 3 days;

    /// @notice Length of the DISPUTE phase, measured from {Incident.rootSubmittedAt} —
    ///         a fixed window so a late settlement can never compress it. No payout
    ///         before it elapses; admin/timelock may dispute ({disputeIncident}) or close ({closeIncident}) it until then.
    uint64 public constant DISPUTE_PERIOD = 2 days;

    /// @notice Length of the FINALIZE phase, after DISPUTE ends. Total CoverPool lock is
    ///         CLAIM_WINDOW + [0, SUBMIT_DEADLINE] + DISPUTE_PERIOD + FINALIZE_WINDOW =
    ///         11–14 days (8 days if the claim voids in SETTLE).
    uint64 public constant FINALIZE_WINDOW = 4 days;

    /// @notice How long a {Status.Disputed} incident stays frozen awaiting a timelock
    ///         {correctSettlement}. The halt ({disputeIncident})
    ///         is a fast, non-timelocked brake; the correction that replaces the bad
    ///         root is timelocked, so it can't land inside the bad root's DISPUTE
    ///         window — this is the runway that lets it. Generous enough to clear the
    ///         timelock delay, but bounded so a stalled/captured governance can't freeze
    ///         LP capital forever: past it the disputed incident auto-voids and unfreezes.
    uint64 public constant CORRECTION_WINDOW = 3 days;

    /// @notice Max age, in blocks, of an incident's referenceBlock at open. A TEE
    ///         open attestation ({OPEN_TYPEHASH}) pins referenceBlock but carries no
    ///         explicit expiry; requiring the open to land within this window of the
    ///         pinned block gives it one (I1) — a stale, never-relayed signed open
    ///         can't be replayed days later. ~5 days at 12s blocks (7200/day).
    uint64 public constant OPEN_MAX_REFERENCE_AGE = 36_000;

    /// @notice A claim incident on a particular insured token. See the v1
    ///         pool history for the full phase-machine rationale.
    /// @param insuredToken    Insured token being claimed against.
    /// @param claimWindowEndTime   Open time + CLAIM_WINDOW.
    /// @param root            TEE-signed merkle root over the whole claim table
    ///                        (dispute anchor; each payout is a leaf proven against
    ///                        it at {finalizeClaim}); 0 if none standing.
    /// @param unresolved      Count of live (unresolved) claims: ++ on {joinClaim},
    ///                        -- on every resolution (cancel/finalize/withdraw). The
    ///                        incident's claims are fully resolved when it reaches 0.
    ///                        Bound into the settlement signature: it is frozen across
    ///                        the entire SETTLE phase (joins and cancels end at
    ///                        window-close; finalization can't start until the dispute
    ///                        period passes), so it pins the exact live claim set the
    ///                        enclave scored — which it reconstructs from the on-chain
    ///                        claims (no separate commitment needed).
    /// @param rootSubmittedAt Timestamp the standing root was submitted.
    /// @param referenceBlock  Pre-incident block: the "before" point losses are
    ///                        valued against, provided by the TEE (or admin) at open.
    /// @param openBlock       Block the incident opened at. The settlement config
    ///                        (insured-token recipe, {settlementParams}, and the
    ///                        pool's scored-token set) is not snapshot on-chain;
    ///                        it is reconstructed off-chain by reading contract
    ///                        state as of this block. History is immutable, so a
    ///                        later governance retune can never alter an in-flight
    ///                        or settled incident. Settlement is already an archive
    ///                        computation (TWAP/min-balance over historical ranges),
    ///                        so this read adds no new dependency.
    /// @param status          Governance lifecycle state (see {Status}). Open unless a
    ///                        a dispute moved it to Disputed (halted, still frozen, awaiting a
    ///                        timelock correction) or Closed (killed; pool unlocks and
    ///                        claimants recover escrow).
    /// @param claimSetHash    Rolling commitment to the EXACT claim set: chained
    ///                        keccak over every {joinClaim} (claimId, user, escrow,
    ///                        scoreToSpend, boosterAmount) and {cancelClaim} (claimId),
    ///                        in call order. Bound into the settlement signature so a
    ///                        root signed for a different claim set — even one with
    ///                        the same {unresolved} count — can never settle (M-06).
    ///                        The settler reproduces it by replaying {ClaimRegistered}
    ///                        / {ClaimCancelled} events in (block, logIndex) order.
    struct Incident {
        IERC20 insuredToken;
        uint64 claimWindowEndTime;
        bytes32 root;
        uint256 unresolved;
        uint64 rootSubmittedAt;
        uint64 referenceBlock;
        uint64 openBlock;
        Status status;
        uint64 disputedAt;
        bytes32 claimSetHash;
    }

    /// @notice Governance lifecycle state of an incident. Mutually exclusive by
    ///         construction (unlike two bools), so an auditor need not prove the
    ///         "both set" combo unreachable.
    /// @custom:value Open    Running its phase machine; no governance intervention.
    /// @custom:value Disputed  A bad root was halted ({disputeIncident}):
    ///                       root cleared, pool STILL frozen, awaiting a timelock
    ///                       {correctSettlement} (or auto-void past {CORRECTION_WINDOW}).
    /// @custom:value Closed  Terminated ({closeIncident}): pool
    ///                       unlocks, claimants recover escrow, next incident may open.
    enum Status {
        Open,
        Disputed,
        Closed
    }

    /// @notice All incidents by id. Id 0 is reserved.
    mapping(uint256 incidentId => Incident) public incidents;

    /// @notice The registered pool set snapshotted at each incident's open — the
    ///         payout-row order {finalizeClaim} pays against (the settler built the
    ///         row over the same openBlock list). Pins alignment independent of any
    ///         later {Registry} topology change.
    mapping(uint256 incidentId => address[]) internal incidentPools;

    /// @notice Remaining payable budget per pool for each incident, aligned to
    ///         {incidentPools}. Set at {settleIncident} to the TEE-committed
    ///         `poolPayouts` (each already checked ≤ that pool's
    ///         {SingleAssetCoverPool.maxPayoutPerIncident}); {finalizeClaim}
    ///         decrements it and reverts once a pool's cumulative payout would
    ///         exceed it. This makes the per-incident LP-loss cap a HARD on-chain
    ///         bound on the actual sum of finalized payouts — not merely a check
    ///         against the signer's self-declared total. See {finalizeClaim}.
    mapping(uint256 incidentId => uint256[]) internal incidentPoolBudget;

    /// @notice Actual timestamp for incidents that end by transaction before a
    ///         deadline-derived auto-unfreeze, e.g. close or all claims finalized.
    mapping(uint256 incidentId => uint64) public incidentResolvedAt;

    /// @notice Next incident id to assign. Starts at 1.
    uint256 public nextIncidentId;

    /// @notice One user's claim: pure escrow registration. All economics are
    ///         computed off-chain over the complete claimant table.
    /// @param user                Claimant.
    /// @param incidentId          Incident this claim belongs to.
    /// @param insuredTokenAmount  Insured token escrowed at registration.
    /// @param resolved            True once the claim is resolved by ANY path —
    ///                            {finalizeClaim} (paid, escrow forfeited),
    ///                            {cancelClaim}, or {withdrawNonFinalizedClaim}
    ///                            (escrow returned). Which path resolved it lives
    ///                            in the emitted event, not on-chain state.
    /// @param boosterAmount       Units of {BOOSTER_ID} committed by this claim (0
    ///                            if none). Each unit boosts the claimant's
    ///                            insurance score (see {BOOSTER_BOOST_BPS}, applied
    ///                            off-chain). NOT escrowed — the claimant keeps them
    ///                            and must still hold them (and have approved this
    ///                            contract as operator) at {finalizeClaim}, which
    ///                            burns them from the claimant. If they don't,
    ///                            finalize reverts: keeping them is the user's
    ///                            responsibility. Nothing to return on cancel/withdraw.
    /// @param boosterCollection   The {Registry.boosterNFT} address at join time
    ///                            (snapshotted so the finalize burn hits the exact
    ///                            collection the boost was priced against, even if
    ///                            the pool later repoints it). Zero if no boosters.
    struct Claim {
        address user;
        uint256 incidentId;
        uint128 insuredTokenAmount;
        uint128 boosterAmount;
        bool resolved;
        address boosterCollection;
    }

    /// @notice All claims by id. Id 0 is reserved.
    mapping(uint256 claimId => Claim) public claims;

    /// @notice Next claim id to assign. Starts at 1.
    uint256 public nextClaimId;

    /// @notice The account's live claim id on an incident, or 0 if none. At most
    ///         one claim per (incident, account): set on {joinClaim}, cleared on
    ///         {cancelClaim}. This caps each account's insurance-score spend at
    ///         its single available budget — a user can't split into multiple
    ///         claims to multiply their score-weighted payout share — and lets
    ///         {cancelClaim} find the caller's claim without an id argument.
    mapping(uint256 incidentId => mapping(address account => uint256 claimId)) public activeClaimId;

    /// @notice Insured tokens currently held as live claim escrow (summed over
    ///         unresolved claims). Decremented on cancel/withdraw/finalize. Lets
    ///         {_sweepable} compute the accountable balance without iterating
    ///         claims, so claimant escrow is never rescuable.
    mapping(IERC20 insuredToken => uint256) public escrowedInsuredTokens;

    /// @notice The only booster token id in use. Claims commit units of this id;
    ///         the collection address lives on the pool ({Registry.boosterNFT}).
    uint256 public constant BOOSTER_ID = 1;

    /// @notice Hard-coded booster policy: each committed unit of {BOOSTER_ID}
    ///         adds 100 bps (+1%) to the claimant's insurance-score multiplier.
    ///         Applied off-chain by the settlement code.
    uint256 public constant BOOSTER_BOOST_BPS = 100;

    // ─────────────────────────── State (settlement config) ───────────────────────────

    /// @notice Global settlement windows, in BLOCKS. Timelock-settable. Read
    ///         off-chain as of each incident's {Incident.openBlock}, so a change
    ///         only ever affects incidents opened after it. All three gate the
    ///         off-chain settlement math (never on-chain). Bias is anti-gaming /
    ///         anti-manipulation over precision: a value that's conservative but hard
    ///         to move beats one that's accurate but cheap to game. See field docs.
    /// @param twapLookbackBlocks   W: averaging window for the token→underlying
    ///                             ratio, TWAP'd over [referenceBlock − W,
    ///                             referenceBlock] — the pre-incident "before" value.
    ///                             LONG on purpose: a wide TWAP is expensive to
    ///                             manipulate, and a result that lags below spot is
    ///                             acceptable (it only ever under-values the loss),
    ///                             whereas a short, spot-tracking window is gameable.
    ///                             Only the ratio leg; the underlying→USD price is a
    ///                             separate oracle, not smoothed here.
    /// @param holdingMarginBlocks  margin: required PRE-INCIDENT holding length.
    ///                             Eligibility is the MIN balance over
    ///                             [referenceBlock − margin, referenceBlock], capped
    ///                             at escrow. Anchored entirely before the incident:
    ///                             holdings AFTER referenceBlock are irrelevant (the
    ///                             claimant still swaps the token in as escrow, and
    ///                             {finalizeClaim} refunds any escrow above the signed
    ///                             eligible amount). Longer = stronger proof of genuine
    ///                             prior exposure, but a wider window also MIN's down
    ///                             holders who varied their balance in the run-up.
    /// @param sampleStepBlocks     stride between TWAP samples (cost↔precision).
    ///                             Only affects {twapLookbackBlocks}; eligibility uses
    ///                             exact Transfer-log replay, not sampling.
    struct SettlementParams {
        uint64 twapLookbackBlocks;
        uint64 holdingMarginBlocks;
        uint64 sampleStepBlocks;
    }

    /// @notice Global settlement windows (in blocks). Read off-chain as of each
    ///         incident's {Incident.openBlock}; changes apply to later incidents.
    SettlementParams public settlementParams;

    /// @notice EIP-712 struct the TEE signs over for {settleIncident}. Binding
    ///         {Incident.unresolved} pins the signature to the exact live claim set
    ///         the enclave scored: it is frozen across the whole SETTLE phase (no
    ///         join/cancel after window-close, no finalize until the DISPUTE phase
    ///         passes), every claim is on-chain, and a root signed for a different
    ///         count can never be submitted here (the recovered signer would not
    ///         authorize that altered digest).
    ///         {poolPayouts} is the enclave-committed total payout per pool (aligned
    ///         to {incidentPools}); settleIncident checks each against the pool's
    ///         {SingleAssetCoverPool.maxPayoutPerIncident} and records it as the
    ///         pool's per-incident budget that {finalizeClaim} draws down — so LP
    ///         loss per pool is hard-capped at the committed total (see
    ///         {incidentPoolBudget}).
    ///
    ///         `claimSet` is the incident's {Incident.claimSetHash} — the on-chain
    ///         rolling commitment to the exact claim set (ids / users / escrows /
    ///         score requests / cancels), so a root signed for a different set —
    ///         even one with the same count — can never settle (M-06). `configHash`
    ///         commits the signer to the exact off-chain configuration (feed map,
    ///         staleness policy, software version) the root was computed under
    ///         (M-04): the contract can't validate it, but it makes the config
    ///         commitment public — a root produced under a wrong/stale config is
    ///         provably disputable instead of deniable. `settlementInputHash` is a
    ///         separate, per-incident commitment to the canonical input rows used to
    ///         produce the root. Keeping it distinct from `configHash` preserves the
    ///         latter's meaning as static policy/configuration while allowing today's
    ///         raw-RPC score rows — and a future indexed snapshot — to use the same
    ///         signed settlement schema. The contract cannot validate either hash;
    ///         publishing their preimages and the DISPUTE phase remain the backstops.
    bytes32 internal constant SETTLEMENT_TYPEHASH = keccak256(
        "Settlement(uint256 incidentId,bytes32 root,uint256 unresolved,uint256[] poolPayouts,bytes32 pools,bytes32 claimSet,bytes32 configHash,bytes32 settlementInputHash)"
    );

    /// @notice EIP-712 struct the TEE signs to open an incident. The enclave —
    ///         running the published depeg-detection code — attests that
    ///         insuredToken has depegged and pins the pre-incident referenceBlock.
    ///         Binding incidentId (== {nextIncidentId} at open) makes each
    ///         signature single-use: once consumed, nextIncidentId advances past
    ///         it, so it can never open a second incident.
    bytes32 internal constant OPEN_TYPEHASH =
        keccak256("IncidentOpen(address insuredToken,uint64 referenceBlock,uint256 incidentId)");

    // ─────────────────────────── Errors ──────────────────────────

    error ZeroAmount();
    error InvalidMaxCoverageBps(uint256 given, uint256 max);
    error InvalidReferenceBlock(uint64 referenceBlock);
    error TokenConflict();
    error InsuredTokenAlreadyApproved(IERC20 insuredToken);
    error InsuredTokenNotApproved(IERC20 insuredToken);
    error ClaimWindowClosed(IERC20 insuredToken, uint64 claimWindowEndTime);
    error BoosterNFTUnset();
    error UnauthorizedClaim(uint256 claimId);
    error ClaimAlreadyResolved(uint256 claimId);
    error DuplicateClaim(uint256 incidentId);
    error NoActiveClaim();
    error NotActiveIncident(uint256 incidentId);
    error IncidentFinalizing(uint256 incidentId);
    error IncidentNotOpen(uint256 incidentId);
    error OutsideSettlementPhase(uint256 incidentId);
    error NoStandingRoot(uint256 incidentId);
    error ClaimWindowStillOpen(uint256 incidentId);
    error AlreadySettled(uint256 incidentId);
    error AlreadyDisputed(uint256 incidentId);
    error NotDisputed(uint256 incidentId);
    error FinalizeNotOpen(uint256 incidentId);
    error InvalidProof(uint256 claimId);
    error EligibleExceedsEscrow(uint256 eligibleAmount, uint256 escrow);
    error ClaimNotWithdrawable(uint256 claimId);
    error IncidentsActive();
    error InvalidSettlementParams();
    error UnexpectedOpenAttestation();
    error UnauthorizedOpenSigner(address recovered);
    error UnauthorizedSettlementSigner(address recovered);
    error BoosterAmountTooLarge(uint256 boosterAmount);
    error SettlementPoolMismatch(uint256 given, uint256 expected);
    error PayoutCapExceeded(uint256 poolIndex, uint256 requested, uint256 cap);
    error DefiInsuranceNotRegistered();

    // ─────────────────────────── Events ──────────────────────────

    event InsuredTokenAdded(IERC20 indexed insuredToken);
    event MaxCoverageBpsSet(IERC20 indexed insuredToken, uint256 maxCoverageBps);
    event UnderlyingConversionSet(IERC20 indexed insuredToken, address conversionAddress, bytes conversionCallData);
    event UnderlyingPriceOracleSet(IERC20 indexed insuredToken, address underlyingPriceOracle);
    event InsuredTokenRemoved(IERC20 indexed insuredToken);
    event SettlementParamsSet(SettlementParams params);
    event IncidentOpened(uint256 indexed incidentId, IERC20 indexed insuredToken, uint64 claimWindowEndTime);
    event IncidentSettled(uint256 indexed incidentId, bytes32 root, bytes32 configHash, bytes32 settlementInputHash);
    event IncidentClosed(uint256 indexed incidentId, address indexed closer);
    event IncidentDisputed(uint256 indexed incidentId, address indexed disputer);
    event IncidentCorrected(uint256 indexed incidentId, bytes32 root);
    event ClaimRegistered(
        uint256 indexed claimId,
        uint256 indexed incidentId,
        address indexed user,
        uint128 insuredTokenAmount,
        uint256 scoreToSpend,
        uint256 boosterAmount
    );
    event ClaimFinalized(uint256 indexed claimId, address indexed user);
    event ClaimCancelled(uint256 indexed claimId, address indexed user);
    event ClaimWithdrawn(uint256 indexed claimId, address indexed user);
    event TeeSignerSet(address indexed signer, bool authorized);

    /// @notice Emitted on {finalizeClaim} for the insurance score a claim consumed.
    ///         The incident-tagged log the settler sums per user (pinned before an
    ///         incident's openBlock) for the available budget; the cumulative total is
    ///         also mirrored on-chain via {Registry.recordScoreSpent}.
    event ScoreSpent(address indexed user, uint256 amount, uint256 indexed incidentId);

    // ─────────────────────────── Constructor ─────────────────────

    /// @notice Deploy the (non-upgradeable) insurance product. To replace it,
    ///         deploy a fresh DefiInsurance and re-point {Registry.setDefiInsurance}
    ///         — done only while no incident is in flight, since the old contract
    ///         still custodies escrow and any open claims.
    /// @param _registry  Shared access + topology registry(). This contract must be
    ///                    registered via {Registry.setDefiInsurance}. The timelock's
    ///                    minDelay MUST be comfortably under {DISPUTE_PERIOD} so it
    ///                    can {disputeIncident} on a bad root in time.
    constructor(Registry _registry) EIP712("DefiInsurance", "1") {
        _setRegistry(_registry);
        nextIncidentId = 1;
        nextClaimId = 1;
        // Safe nonzero settlement defaults so an incident opened before governance
        // tunes them can still settle, instead of the off-chain TWAP throwing on
        // sampleStepBlocks == 0 and forcing the incident to void (M-02). Assumes
        // ~12s blocks; setSettlementParams (timelock, between incidents) refines
        // them and can never set sampleStepBlocks back to 0. Governance SHOULD
        // review these for the product before opening the first incident.
        settlementParams = SettlementParams({
            twapLookbackBlocks: 50_400, // ~7d TWAP window before referenceBlock (anti-manipulation over recency)
            holdingMarginBlocks: 50_400, // ~7d required pre-incident holding for eligibility before refBlock
            sampleStepBlocks: 300 // ~1h TWAP sample stride (≈168 samples over a 7d window)
        });
    }

    /// @dev Reverts while an incident is active. Settlement reconstructs an
    ///      incident's economic config by archive-reading it at the incident's
    ///      {Incident.openBlock} — which returns END-OF-BLOCK state — so a config
    ///      mutation in the same block after the open (or any later block during the
    ///      incident) would desync the signed root from the config actually in force
    ///      at open (audit M-01). An incident goes active atomically in its open tx,
    ///      so gating these setters on it forecloses that window: nothing can change
    ///      settlement-critical config from the open tx through resolution.
    modifier notDuringIncident() {
        if (_activeIncidentId() != 0) revert IncidentsActive();
        _;
    }

    /// @dev The token must be a listed insured token (maxCoverageBps != 0).
    modifier onlyApprovedToken(IERC20 token) {
        if (insuredTokens[token].maxCoverageBps == 0) revert InsuredTokenNotApproved(token);
        _;
    }

    // ─────────────────────────── Insured token management (timelock) ───────────────────────────

    /// @notice Approve a new insured token and set the economic config settlement
    ///         consumes. Timelock only. Must not be a pool stake asset, nor
    ///         already listed.
    /// @param insuredToken         Token to insure.
    /// @param _maxCoverageBps      κ in (0, 100%] (bps); the timelock picks it. e.g. 8000=80%.
    /// @param underlyingPriceOracle  underlying→USD oracle (non-zero). Not the insured token. e.g. insure token is aUSDC, underlying is USDC, underlyingPriceOracle is for USDC.
    /// @param conversionAddress    token→underlying staticcall target (0 = identity). aUSDC -> USDC conversion.
    /// @param conversionCallData   calldata for that staticcall. depending on the conversionAddress, the fn name might be different, so we need conversionCallData.
    function addInsuredToken(
        IERC20 insuredToken,
        uint256 _maxCoverageBps,
        address underlyingPriceOracle,
        address conversionAddress,
        bytes calldata conversionCallData
    ) external onlyTimelock {
        if (address(insuredToken) == address(0) || underlyingPriceOracle == address(0)) revert ZeroAddress();
        if (registry().coverPool(insuredToken) != address(0)) revert TokenConflict();
        if (insuredTokens[insuredToken].maxCoverageBps != 0) revert InsuredTokenAlreadyApproved(insuredToken);
        if (_maxCoverageBps == 0 || _maxCoverageBps > BPS_DENOMINATOR) {
            revert InvalidMaxCoverageBps(_maxCoverageBps, BPS_DENOMINATOR);
        }

        insuredTokens[insuredToken] = InsuredToken({
            maxCoverageBps: _maxCoverageBps,
            underlyingPriceOracle: underlyingPriceOracle,
            underlyingConversionAddress: conversionAddress,
            underlyingConversionCallData: conversionCallData
        });
        insuredTokenList.push(insuredToken);
        emit InsuredTokenAdded(insuredToken);
        emit MaxCoverageBpsSet(insuredToken, _maxCoverageBps);
        emit UnderlyingPriceOracleSet(insuredToken, underlyingPriceOracle);
        emit UnderlyingConversionSet(insuredToken, conversionAddress, conversionCallData);
    }

    /// @notice Update an insured token's coverage factor κ. Timelock only.
    /// @param insuredToken  Listed insured token to update.
    /// @param _maxCoverageBps  New κ in (0, 100%] (bps).
    function setMaxCoverageBps(IERC20 insuredToken, uint256 _maxCoverageBps)
        external
        onlyTimelock
        notDuringIncident
        onlyApprovedToken(insuredToken)
    {
        if (_maxCoverageBps == 0 || _maxCoverageBps > BPS_DENOMINATOR) {
            revert InvalidMaxCoverageBps(_maxCoverageBps, BPS_DENOMINATOR);
        }
        insuredTokens[insuredToken].maxCoverageBps = _maxCoverageBps;
        emit MaxCoverageBpsSet(insuredToken, _maxCoverageBps);
    }

    /// @notice Update an insured token's token→underlying conversion recipe.
    ///         Timelock only. 0 = identity (ratio 1e18). See {InsuredToken}.
    /// @param insuredToken       Listed insured token to update.
    /// @param conversionAddress  New staticcall target (0 = identity).
    /// @param conversionCallData New calldata for that staticcall.
    function setUnderlyingConversion(IERC20 insuredToken, address conversionAddress, bytes calldata conversionCallData)
        external
        onlyTimelock
        notDuringIncident
        onlyApprovedToken(insuredToken)
    {
        InsuredToken storage t = insuredTokens[insuredToken];
        t.underlyingConversionAddress = conversionAddress;
        t.underlyingConversionCallData = conversionCallData;
        emit UnderlyingConversionSet(insuredToken, conversionAddress, conversionCallData);
    }

    /// @notice Update an insured token's underlying→USD price oracle. Timelock only.
    /// @param insuredToken  Listed insured token to update.
    /// @param underlyingPriceOracle   New oracle address (non-zero).
    function setUnderlyingPriceOracle(IERC20 insuredToken, address underlyingPriceOracle)
        external
        onlyTimelock
        notDuringIncident
        onlyApprovedToken(insuredToken)
    {
        if (underlyingPriceOracle == address(0)) revert ZeroAddress();
        insuredTokens[insuredToken].underlyingPriceOracle = underlyingPriceOracle;
        emit UnderlyingPriceOracleSet(insuredToken, underlyingPriceOracle);
    }

    /// @notice Remove an approved insured token. Admin or timelock — deny-only
    ///         and recoverable (re-add to relist); moves no funds. Blocked while an
    ///         incident is active (notDuringIncident, M-01): the active incident's
    ///         config must stay stable across settlement; delist once it resolves.
    /// @param insuredToken  Approved insured token to delist.
    function removeInsuredToken(IERC20 insuredToken)
        external
        onlyAdminOrTimelock
        notDuringIncident
        onlyApprovedToken(insuredToken)
    {
        _delistInsuredToken(insuredToken);
    }

    /// @notice Set the global settlement windows (blocks). Timelock only; blocked
    ///         while an incident is active (notDuringIncident, M-01). Each incident
    ///         is settled against these params as of its {Incident.openBlock}, and
    ///         freezing them for the incident's life keeps that archive read stable.
    /// @param p  New settlement windows. See {SettlementParams}.
    function setSettlementParams(SettlementParams calldata p) external onlyTimelock notDuringIncident {
        // sampleStepBlocks is the TWAP loop stride off-chain; 0 would never advance.
        if (p.sampleStepBlocks == 0) revert InvalidSettlementParams();
        settlementParams = p;
        emit SettlementParamsSet(p);
    }

    /// @dev Rescuable via {RegistryManaged-sweepToken}: only the non-accountable
    ///      balance — the surplus ABOVE live claim escrow ({escrowedInsuredTokens}),
    ///      i.e. strays and already-forfeited escrow. The escrow is protected by the
    ///      `bal - accounted` cap regardless of incident status (the accounting tracks
    ///      it in lockstep, so `bal >= accounted` always), and this contract's token
    ///      balance never feeds settlement (payouts come from the pools). So the
    ///      surplus is always safe to recover — no need to block during an incident.
    function _sweepable(address token) internal view override returns (uint256) {
        uint256 accounted = escrowedInsuredTokens[IERC20(token)];
        uint256 bal = IERC20(token).balanceOf(address(this));
        return bal > accounted ? bal - accounted : 0;
    }

    // ─────────────────────────── Claim lifecycle ───────────────────────────

    /// @notice Open a claim claim-lessly on insuredToken. Admin/timelock fallback for
    ///         when the TEE is down/censoring, or for covered events the TEE can't
    ///         attest. Opens the claim window WITHOUT filing a claim; use
    ///         {closeIncident} to abort. The permissionless (TEE-attested) open path is
    ///         the first {joinClaim} itself.
    /// @param  insuredToken    Token a covered event occurred on.
    /// @param  referenceBlock  Pre-incident block (< block.number, non-zero)
    ///                         the admin pins as the "before" valuation point.
    /// @return incidentId      The newly opened incident id.
    function openClaimIncident(IERC20 insuredToken, uint64 referenceBlock)
        external
        onlyAdminOrTimelock
        returns (uint256 incidentId)
    {
        return _openIncident(insuredToken, referenceBlock);
    }

    /// @dev Shared open path: validates and records {openBlock}. The system freeze
    ///      is implicit — pools read {Registry.frozen}, which reads this module's
    ///      {activeIncidentId}, non-zero once the incident is recorded below. The insured
    ///      token is delisted later, at root submission (a confirmed event), not
    ///      here — so an incident that opens and closes without a root leaves
    ///      the listing untouched.
    function _openIncident(IERC20 insuredToken, uint64 referenceBlock)
        internal
        whenNotPaused
        onlyApprovedToken(insuredToken)
        returns (uint256 incidentId)
    {
        // One-at-a-time guard (token approval is enforced by onlyApprovedToken).
        if (_activeIncidentId() != 0) revert IncidentsActive();
        // This module must be the registered payout module, else Registry.payoutIncidentActive()
        // (which delegates to the CURRENT module's activeIncidentId) would stay 0
        // and pools wouldn't freeze — LPs could move mid-incident and break the
        // deterministic-capital assumption settlement relies on (audit L-04).
        // Reachable only in a misconfig/transition (module cleared via the
        // setDefiInsurance(0) brake, or an incident opened in a de-registered old
        // instance during a module swap); this turns that into a clean revert.
        if (registry().defiInsurance() != address(this)) revert DefiInsuranceNotRegistered();

        // Non-zero, in the past, and recent: the freshness bound doubles as the
        // open attestation's expiry (I1) — a stale signed open can't be relayed late.
        if (
            referenceBlock == 0 || referenceBlock >= block.number
                || block.number - referenceBlock > OPEN_MAX_REFERENCE_AGE
        ) revert InvalidReferenceBlock(referenceBlock);

        // No explicit pool lock: this module is the single {Registry.defiInsurance},
        // so the pools' freeze (registry().payoutIncidentActive()) reads our activeIncidentId()
        // implicitly once the incident below is recorded. The _activeIncidentId() check
        // above is the one-at-a-time guard. No activeIncidentId to write: it is derived
        // as the last-opened incident ({nextIncidentId} - 1), which is this one.

        incidentId = nextIncidentId;
        nextIncidentId = incidentId + 1;
        uint64 wEnd = uint64(block.timestamp) + CLAIM_WINDOW;
        incidents[incidentId] = Incident({
            insuredToken: insuredToken,
            claimWindowEndTime: wEnd,
            root: bytes32(0),
            unresolved: 0,
            rootSubmittedAt: 0,
            referenceBlock: referenceBlock,
            openBlock: uint64(block.number),
            status: Status.Open,
            disputedAt: 0,
            claimSetHash: bytes32(0)
        });

        // Snapshot the pool set at open. finalizeClaim pays each claim's amounts[]
        // row against THIS list (not live {Registry.pools}), so payouts stay aligned
        // to the exact order the settler built the row over at openBlock — even if
        // topology were mutated mid-incident (only reachable via the setDefiInsurance(0)
        // emergency brake, which bypasses the freeze). Without the snapshot a reorder
        // would mispay or revert.
        (, address[] memory poolAddrs) = registry().coverPools();
        incidentPools[incidentId] = poolAddrs;

        emit IncidentOpened(incidentId, insuredToken, wEnd);
    }

    /// @notice File a claim on insuredToken — and OPEN one if none is live yet.
    ///         There is no separate open step: the FIRST claim on a token opens the
    ///         CLAIM window, gated by a TEE attestation (referenceBlock + signature
    ///         over {OPEN_TYPEHASH}); the enclave — running the published
    ///         depeg-detection code — decides "should this open", not on-chain rate
    ///         logic, and anyone may relay it. A spurious open is only a CoverPool
    ///         freeze, never a drain (payout still needs a signed root surviving
    ///         DISPUTE). If a claim is ALREADY live on the token, pass referenceBlock
    ///         = 0 and empty signature and this just joins it. Escrows the insured
    ///         token (and records any booster units); the claim's parameters are
    ///         emitted in {ClaimRegistered} for off-chain settlement to replay.
    ///         Admin/timelock can instead open claim-lessly via {openClaimIncident}.
    /// @param insuredToken        Token to claim on (and, on the first claim, open on).
    /// @param insuredTokenAmount  Escrow for this claim.
    /// @param scoreToSpend        Usd8 History Score the claimant REQUESTS to spend — the payout
    ///                            weight (share = your spent / all spent, capped at κ ×
    ///                            loss). Only a request: the settler caps it to
    ///                            `min(requested, available)`, so `type(uint256).max`
    ///                            means "spend all available" and can never overspend.
    ///                            Only emitted here (never stored/validated on-chain);
    ///                            the capped amount is recorded at {finalizeClaim} via
    ///                            {ScoreSpent} + {Registry.recordScoreSpent}, so an
    ///                            unfinalized claim spends nothing.
    /// @param boosterAmount       Units of the canonical booster ({BOOSTER_ID}) to
    ///                            commit (0 = none). Each unit boosts the score. Not
    ///                            transferred now — kept by the claimant and burned from
    ///                            them at {finalizeClaim}. You MUST still hold (and have
    ///                            approved) at least this many by then: committing more
    ///                            than you hold makes the finalize burn revert, blocking
    ///                            YOUR OWN finalization until you do. Holding them
    ///                            through finalize is the claimant's responsibility.
    /// @param referenceBlock      Pre-incident "before" block the TEE pinned — used
    ///                            ONLY when first claim opens; MUST be 0 when rest claims joining.
    /// @param signature           An authorized {isTeeSigner} enclave's EIP-712 open
    ///                            attestation — used ONLY when the first claim opens;
    ///                            MUST be empty when later claims join.
    /// @return claimId The newly minted claim id.
    function joinClaim(
        IERC20 insuredToken,
        uint128 insuredTokenAmount,
        uint256 scoreToSpend,
        uint256 boosterAmount,
        uint64 referenceBlock,
        bytes calldata signature
    ) external nonReentrant whenNotPaused returns (uint256 claimId) {
        if (insuredTokenAmount == 0) revert ZeroAmount();

        uint256 incidentId = _activeIncidentId();
        if (incidentId != 0) {
            // A claim is already live — just join it; no open attestation expected.
            if (referenceBlock != 0 || signature.length != 0) revert UnexpectedOpenAttestation();
            Incident storage cur = incidents[incidentId];
            // Defense-in-depth (audit L-A): only an Open incident accepts joins.
            // Given {disputeIncident} now requires a settled (post-window) root, a
            // Disputed incident always has a closed claim window, so the window
            // check below already blocks it — this makes the intent explicit and
            // holds even if the dispute/settle timing is ever changed.
            if (cur.status != Status.Open) revert IncidentNotOpen(incidentId);
            // A different token holding the system means one-at-a-time blocks us.
            if (cur.insuredToken != insuredToken) revert IncidentsActive();
            if (block.timestamp > cur.claimWindowEndTime) {
                revert ClaimWindowClosed(insuredToken, cur.claimWindowEndTime);
            }
            // One live claim per account per claim: stops a user splitting one
            // insurance-score budget across many claims to inflate their payout share.
            // Only meaningful here — a claim that OPENS below is on a fresh incidentId,
            // so it is always duplicate-free (checking it there just wastes a SLOAD).
            if (activeClaimId[incidentId][msg.sender] != 0) revert DuplicateClaim(incidentId);
        } else {
            // No live claim → this FIRST claim opens one, gated by the TEE attestation.
            // _openIncident enforces token-approved / one-at-a-time / referenceBlock
            // freshness / module-registered, and starts the CLAIM window.
            bytes32 digest = _hashTypedDataV4(
                keccak256(abi.encode(OPEN_TYPEHASH, address(insuredToken), referenceBlock, nextIncidentId))
            );
            address recovered = ECDSA.recover(digest, signature);
            if (!isTeeSigner[recovered]) revert UnauthorizedOpenSigner(recovered);
            incidentId = _openIncident(insuredToken, referenceBlock);
        }

        uint128 escrow = uint128(_pullToken(insuredToken, msg.sender, insuredTokenAmount));
        if (escrow == 0) revert ZeroAmount();
        escrowedInsuredTokens[insuredToken] += escrow;

        claimId = nextClaimId++;
        activeClaimId[incidentId][msg.sender] = claimId;
        claims[claimId] = Claim({
            user: msg.sender,
            incidentId: incidentId,
            insuredTokenAmount: escrow,
            boosterAmount: 0,
            resolved: false,
            boosterCollection: address(0)
        });

        if (boosterAmount != 0) {
            // Bound to uint128 so the stored value never diverges from the uint256
            // emitted in {ClaimRegistered} that the settler replays (I2).
            if (boosterAmount > type(uint128).max) revert BoosterAmountTooLarge(boosterAmount);
            address booster = registry().boosterNFT();
            if (booster == address(0)) revert BoosterNFTUnset();
            // Not escrowed: recorded and burned from the claimant at finalize.
            claims[claimId].boosterAmount = uint128(boosterAmount);
            claims[claimId].boosterCollection = booster; // snapshot the collection to burn from
        }

        Incident storage reg = incidents[incidentId];
        reg.unresolved += 1;
        // Chain this join into the claim-set commitment the settlement signature
        // binds (M-06). Exactly the fields {ClaimRegistered} emits, so the settler
        // reproduces the hash by replaying events in order.
        reg.claimSetHash =
            keccak256(abi.encode(reg.claimSetHash, claimId, msg.sender, escrow, scoreToSpend, boosterAmount));

        emit ClaimRegistered(claimId, incidentId, msg.sender, escrow, scoreToSpend, boosterAmount);
    }

    /// @dev Pull amount of token from from, returning the balance delta
    ///      actually received (a fee-on-transfer safety net; such tokens are
    ///      unsupported). Callers run under {nonReentrant}.
    function _pullToken(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
    }

    /// @notice Cancel your live claim on the active incident while its window is
    ///         still open; returns the escrow. No id argument — an account has at
    ///         most one live claim per incident, looked up from {activeClaimId}.
    function cancelClaim() external nonReentrant {
        uint256 incidentId = _activeIncidentId();
        uint256 claimId = activeClaimId[incidentId][msg.sender];
        if (claimId == 0) revert NoActiveClaim();

        Incident storage inc = incidents[incidentId];
        if (block.timestamp > inc.claimWindowEndTime) {
            revert ClaimWindowClosed(inc.insuredToken, inc.claimWindowEndTime);
        }

        // The referenced claim is live by construction: finalize can't run during
        // the window and cancel clears the ref, so no resolved check.
        Claim storage c = claims[claimId];
        c.resolved = true;
        inc.unresolved -= 1;
        // Chain the cancel into the claim-set commitment (M-06). Two words vs the
        // join's six, so a cancel entry can never collide with a join entry.
        inc.claimSetHash = keccak256(abi.encode(inc.claimSetHash, claimId));
        activeClaimId[incidentId][msg.sender] = 0; // may re-file within the window
        escrowedInsuredTokens[inc.insuredToken] -= c.insuredTokenAmount;
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);

        emit ClaimCancelled(claimId, msg.sender);
    }

    // ─────────────────────────── Settlement (TEE-signed root only) ───────────────────────────

    /// @notice Submit the settlement root permissionlessly, carrying the TEE's
    ///         EIP-712 signature. The enclave — running the open sourced settlement
    ///         code — reconstructs the claimant table from on-chain claims and signs
    ///         Settlement(incidentId, root, unresolved, poolPayouts, pools, claimSet,
    ///         configHash, settlementInputHash); binding unresolved + claimSet means
    ///         the signature is only valid for the exact (frozen) live claim set it
    ///         scored, and binding
    ///         `pools` pins the same ordered pool set the contract snapshotted
    ///         (positional row alignment). Anyone may relay the signed
    ///         root; the optimistic DISPUTE
    ///         phase and governance intervention ({disputeIncident} / {closeIncident}) still apply. ONE TEE settlement per incident — no
    ///         resubmit ({AlreadySettled}); a bad root is disputed via {disputeIncident} and
    ///         replaced by the timelock via {correctSettlement}, never overwritten by
    ///         another TEE root.
    /// @param incidentId   In-flight incident to settle.
    /// @param root         Settlement root — the commitment over the claim table.
    /// @param poolPayouts  Enclave-committed total payout per pool, aligned to the
    ///                     incident's {incidentPools} snapshot. Each is checked
    ///                     against that pool's {SingleAssetCoverPool.maxPayoutPerIncident}.
    /// @param configHash   Enclave's commitment to the exact off-chain settlement
    ///                     configuration (feed map, staleness policy, software
    ///                     version) the root was computed under (M-04). Not
    ///                     validated on-chain — bound into the signature and
    ///                     emitted so a root produced under a wrong or stale
    ///                     config is provably disputable.
    /// @param settlementInputHash Enclave's per-incident commitment to the
    ///                     canonical settlement input rows used to compute `root`.
    ///                     Phase 1 commits the raw-RPC score rows; a future indexed
    ///                     score snapshot uses the same field. The preimage is
    ///                     published off-chain for independent reproduction.
    /// @param signature    An authorized {isTeeSigner} enclave's EIP-712 signature
    ///                     over the Settlement struct (domain: name
    ///                     "DefiInsurance", version "1", this chain id, this contract).
    function settleIncident(
        uint256 incidentId,
        bytes32 root,
        uint256[] calldata poolPayouts,
        bytes32 configHash,
        bytes32 settlementInputHash,
        bytes calldata signature
    ) external whenNotPaused {
        Incident storage inc = incidents[incidentId];

        // Cheap phase + root checks first — fail fast before the ECDSA recover.
        // A closed incident is not the active one ({_activeIncidentId} returns 0 for
        // it), so it is rejected here.
        if (root == bytes32(0)) revert NoStandingRoot(incidentId);
        if (incidentId != _activeIncidentId()) revert NotActiveIncident(incidentId);
        // A disputed incident (root cleared, frozen) has distrusted its TEE — only a
        // timelock {correctSettlement} may re-root it, never a fresh TEE settle here.
        if (inc.status != Status.Open) revert AlreadyDisputed(incidentId);
        // ONE TEE settlement per incident — no resubmit/overwrite. Settlement is
        // deterministic (config + claim set frozen at open, signer can't rotate mid-
        // incident), so an honest TEE has exactly one root to submit and a compromised
        // one gains nothing from resubmitting. A wrong root is disputed ({disputeIncident})
        // and replaced by the timelock via {correctSettlement}, never overwritten by
        // another TEE root here. This also makes settle and finalize trivially exclusive
        // — no re-settle can collide with a payout.
        if (inc.root != bytes32(0)) revert AlreadySettled(incidentId);
        if (block.timestamp <= inc.claimWindowEndTime || block.timestamp > inc.claimWindowEndTime + SUBMIT_DEADLINE) {
            revert OutsideSettlementPhase(incidentId);
        }

        // Authorize: a valid TEE signature bound to this incident's exact live
        // claim set via unresolved (frozen across the SETTLE phase, on-chain), the
        // committed per-pool payout totals, AND the incident's pool set/order. Binding
        // `pools` pins the positional row alignment: the enclave must have scored against
        // the SAME ordered pool list the contract snapshotted at open ({incidentPools}),
        // so an enumeration-order divergence (an honest settler bug) fails here at settle
        // — before any payout — rather than silently misallocating loss across pools.
        _verifySettlementSig(incidentId, root, inc, poolPayouts, configHash, settlementInputHash, signature);

        _commitRoot(incidentId, inc, root, poolPayouts);
        emit IncidentSettled(incidentId, root, configHash, settlementInputHash);
    }

    /// @dev EIP-712 digest + recover for {settleIncident}, own frame to keep its
    ///      caller's stack shallow. Reverts unless the signature belongs to an
    ///      authorized {isTeeSigner} over the full Settlement struct (including
    ///      {Incident.claimSetHash}, the config commitment, and the per-incident
    ///      settlement-input commitment).
    function _verifySettlementSig(
        uint256 incidentId,
        bytes32 root,
        Incident storage inc,
        uint256[] calldata poolPayouts,
        bytes32 configHash,
        bytes32 settlementInputHash,
        bytes calldata signature
    ) private view {
        bytes32 payoutsHash = keccak256(abi.encodePacked(poolPayouts));
        bytes32 poolsHash = keccak256(abi.encodePacked(incidentPools[incidentId]));
        bytes32 structHash = _settlementStructHash(
            incidentId, root, inc.unresolved, payoutsHash, poolsHash, inc.claimSetHash, configHash, settlementInputHash
        );
        address recovered = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (!isTeeSigner[recovered]) revert UnauthorizedSettlementSigner(recovered);
    }

    /// @dev Builds the full Settlement struct hash in a separate frame to keep the
    ///      signature-verification caller below Solidity's stack limit.
    function _settlementStructHash(
        uint256 incidentId,
        bytes32 root,
        uint256 unresolved,
        bytes32 payoutsHash,
        bytes32 poolsHash,
        bytes32 claimSetHash,
        bytes32 configHash,
        bytes32 settlementInputHash
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SETTLEMENT_TYPEHASH,
                incidentId,
                root,
                unresolved,
                payoutsHash,
                poolsHash,
                claimSetHash,
                configHash,
                settlementInputHash
            )
        );
    }

    /// @notice Formally dispute the standing (or pending) settlement — the fast, non-
    ///         timelocked governance halt that DEFENDS claimants. Admin or timelock; deny-
    ///         only, never redirects funds. Clears the bad root but keeps the pool FROZEN,
    ///         marking the incident Disputed and starting the {CORRECTION_WINDOW} clock;
    ///         the timelock then supplies the right root via {correctSettlement}. This is
    ///         what makes correction viable: the correction is timelocked, so it can't land
    ///         inside the bad root's DISPUTE window — this halt freezes the pool so LPs
    ///         can't flee in the interim.
    ///
    ///         Allowed only from Open and only UP TO the end of the DISPUTE phase: once
    ///         FINALIZE opens the root is final and claims may already be paying out, so
    ///         intervening then would strand honest claimants mid-payout. Re-disputing an
    ///         already-Disputed incident is barred so a captured governance can't keep
    ///         resetting the auto-void clock — the only move left on it is {closeIncident}.
    ///         No id argument — one incident is live at a time ({activeIncidentId}).
    ///
    ///         Only for emergency when TEE is compromised. admin cant steal.
    function disputeIncident() external onlyAdminOrTimelock {
        uint256 incidentId = _requireActiveIncident();
        Incident storage inc = incidents[incidentId];
        if (inc.status != Status.Open) revert AlreadyDisputed(incidentId);
        // Dispute only ever targets a STANDING SETTLED root (audit L-A): a root
        // exists only after {settleIncident}, which requires the claim window
        // closed. This blocks a pre-settlement dispute — which would stamp
        // {disputedAt} before the claim window ends and let the CORRECTION_WINDOW
        // auto-void a valid incident before {correctSettlement} is even legal — and
        // makes a Disputed incident unreachable while its claim window is open (so
        // no one can escrow into a disputed incident). The pre-settlement emergency
        // stop is {closeIncident}, which voids and returns escrow.
        if (inc.root == bytes32(0)) revert NoStandingRoot(incidentId);
        // ...and only within its DISPUTE window: once FINALIZE opens the root is
        // final and claims may already be paying out.
        if (block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD) revert IncidentFinalizing(incidentId);
        inc.root = bytes32(0);
        inc.rootSubmittedAt = 0;
        inc.disputedAt = uint64(block.timestamp);
        inc.status = Status.Disputed;
        emit IncidentDisputed(incidentId, msg.sender);
    }

    /// @notice Terminate the in-flight incident: unfreeze the pool and let claimants
    ///         recover escrow via {withdrawNonFinalizedClaim}. Admin or timelock; deny-
    ///         only, never redirects funds. For a spurious event / bad open, or to give up
    ///         on a Disputed incident instead of correcting it. Callable from Open or
    ///         Disputed, but only UP TO the end of the DISPUTE phase — once FINALIZE opens
    ///         the root is final and claims may already be paying out, so closing then
    ///         would strand honest claimants mid-payout. No id argument — one incident is
    ///         live at a time ({activeIncidentId}).
    ///
    ///         Only for emergency when TEE is compromised. admin cant steal.
    function closeIncident() external onlyAdminOrTimelock {
        uint256 incidentId = _requireActiveIncident();
        Incident storage inc = incidents[incidentId];
        // Bar close once FINALIZE has opened on a standing root (payouts may be underway).
        // A Disputed incident has no root (cleared at dispute), so this never blocks it.
        if (inc.root != bytes32(0) && block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD) {
            revert IncidentFinalizing(incidentId);
        }
        // ACCEPTED (audit C7): if a root was already submitted, settleIncident delisted the
        // insured token, and closing does NOT re-list it — the token must be manually
        // re-added via {addInsuredToken} before it can be insured again. A close means the
        // token/event needs governance review anyway.
        inc.status = Status.Closed;
        incidentResolvedAt[incidentId] = uint64(block.timestamp);
        emit IncidentClosed(incidentId, msg.sender);
    }

    /// @notice Replace a disputed incident's root with the correct one. Timelock only, and
    ///         only from the Disputed state ({disputeIncident}). No TEE signature — the
    ///         compromised enclave is cut out; the timelock IS the recovery authority and
    ///         computes the root off-chain from its own honest settler. The pool stays
    ///         frozen throughout (Disputed → Open, never unfrozen), so LPs can't flee
    ///         between the dispute and the corrected payout. Runs the normal DISPUTE →
    ///         FINALIZE afterward (rootSubmittedAt reset to now), so even a bad correction
    ///         can itself be disputed before it pays out. Per-pool caps are enforced
    ///         exactly as in {settleIncident} (shared {_commitRoot}), so the timelock can't
    ///         over-drain. No id argument — one incident is live at a time.
    /// @param root         The corrected settlement root (non-zero).
    /// @param poolPayouts  Corrected per-pool payout totals, aligned to {incidentPools}.
    function correctSettlement(bytes32 root, uint256[] calldata poolPayouts) external onlyTimelock {
        uint256 incidentId = _requireActiveIncident();
        if (root == bytes32(0)) revert NoStandingRoot(incidentId);
        Incident storage inc = incidents[incidentId];
        if (inc.status != Status.Disputed) revert NotDisputed(incidentId);
        // No payable root may be committed until the claim set is frozen (CLAIM window
        // closed) — otherwise a correction installed mid-claim could finalize while
        // claims are still joining/cancelling (H-03). settleIncident enforces the same
        // window; correction is the timelock's parallel path and must match it.
        if (block.timestamp <= inc.claimWindowEndTime) revert ClaimWindowStillOpen(incidentId);

        _commitRoot(incidentId, inc, root, poolPayouts);
        inc.status = Status.Open;
        emit IncidentCorrected(incidentId, root);
    }

    /// @notice BETA-ONLY one-step correction: a trusted admin replaces a standing
    ///         settled root with a corrected one directly, skipping the
    ///         {disputeIncident} → timelock {correctSettlement} dance. Gated by
    ///         {RegistryManaged.onlyBetaMode}, so it stops working the moment the
    ///         timelock calls {Registry.endBetaMode} — after which correction is
    ///         timelock-only via {correctSettlement}. This is the deliberate
    ///         launch-phase centralization: it lets governance fix a bad TEE root
    ///         without a 24h delay while TVL is small, and is one-way removable.
    ///
    ///         Allowed exactly where a {disputeIncident} would be — a standing
    ///         (post-window) settled root still inside its DISPUTE window — so it
    ///         can never touch a claim set that isn't frozen (root != 0 ⇒ the claim
    ///         window is closed) nor a root that FINALIZE has already opened on.
    ///         Shares {_commitRoot}: the corrected per-pool totals are capped
    ///         identically (admin can't over-drain), and rootSubmittedAt resets so
    ///         the corrected root runs its OWN fresh DISPUTE window — even this
    ///         admin correction can be disputed by the timelock before it pays.
    /// @param root         The corrected settlement root (non-zero).
    /// @param poolPayouts  Corrected per-pool payout totals, aligned to {incidentPools}.
    function adminCorrectSettlement(bytes32 root, uint256[] calldata poolPayouts)
        external
        onlyAdminOrTimelock
        onlyBetaMode
    {
        uint256 incidentId = _requireActiveIncident();
        if (root == bytes32(0)) revert NoStandingRoot(incidentId);
        Incident storage inc = incidents[incidentId];
        // Same eligibility as disputeIncident: a standing settled root, still
        // within its DISPUTE window (FINALIZE not yet open, so no payout occurred).
        if (inc.status != Status.Open) revert AlreadyDisputed(incidentId);
        if (inc.root == bytes32(0)) revert NoStandingRoot(incidentId);
        if (block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD) revert IncidentFinalizing(incidentId);

        _commitRoot(incidentId, inc, root, poolPayouts);
        emit IncidentCorrected(incidentId, root);
    }

    /// @dev Commit a settlement root and its per-pool payout budget — the shared tail of
    ///      {settleIncident} (TEE-signed) and {correctSettlement} (timelock). Validates the
    ///      payout row against {incidentPools}, checks each pool's committed total against
    ///      its {SingleAssetCoverPool.maxPayoutPerIncident} cap (pool frozen ⇒ the open-
    ///      balance cap), and records it as the pool's remaining payable budget which
    ///      {finalizeClaim} draws down — so the ACTUAL summed payout per pool is hard-capped
    ///      at this committed total, not just the signer's assertion. Stamps rootSubmittedAt
    ///      (starting a fresh DISPUTE window) and delists the insured token on the confirmed
    ///      event (no-op if already delisted).
    function _commitRoot(uint256 incidentId, Incident storage inc, bytes32 root, uint256[] calldata poolPayouts)
        private
    {
        address[] storage poolAddrs = incidentPools[incidentId];
        if (poolPayouts.length != poolAddrs.length) {
            revert SettlementPoolMismatch(poolPayouts.length, poolAddrs.length);
        }
        for (uint256 i = 0; i < poolAddrs.length; i++) {
            uint256 cap = ISingleAssetCoverPool(poolAddrs[i]).maxPayoutPerIncident();
            if (poolPayouts[i] > cap) revert PayoutCapExceeded(i, poolPayouts[i], cap);
        }
        incidentPoolBudget[incidentId] = poolPayouts;

        inc.root = root;
        inc.rootSubmittedAt = uint64(block.timestamp);
        _delistInsuredToken(inc.insuredToken);
    }

    /// @notice Finalize your live claim on the active incident against the standing root
    ///         with its merkle proof. No id argument — an account has at most one live
    ///         claim per incident, looked up from {activeClaimId} (as {cancelClaim}); the
    ///         claim is the caller's by construction, so no ownership check is needed.
    ///         amounts is the claimant's per-pool payout row aligned to the pool set
    ///         snapshotted at open; proof is its merkle path against the standing
    ///         {Incident.root}. Paid out of each pool via {ISingleAssetCoverPool.payClaim};
    ///         escrow forfeits. Reverts {NoActiveClaim} if the incident is no longer active
    ///         (closed/void/finalize-expired) — escrow is recovered via
    ///         {withdrawNonFinalizedClaim} then.
    /// @param amounts     Per-pool payout row, aligned to the incident's pool list.
    /// @param scoreSpent  Insurance score this claim consumes (off-chain-capped),
    ///                    recorded via the {ScoreSpent} event.
    /// @param eligibleAmount  Insured-token amount actually covered, as signed in the leaf
    ///                    (= min(pre-incident holding, escrow)). This much escrow is
    ///                    forfeited; any escrow above it is refunded to the claimant,
    ///                    so over-escrowing is harmless.
    /// @param proof       Merkle proof of the claim's leaf against {Incident.root}.
    function finalizeClaim(
        uint256[] calldata amounts,
        uint256 scoreSpent,
        uint256 eligibleAmount,
        bytes32[] calldata proof
    ) external nonReentrant whenNotPaused {
        uint256 incidentId = _activeIncidentId();
        uint256 claimId = activeClaimId[incidentId][msg.sender];
        if (claimId == 0) revert NoActiveClaim();
        Claim storage c = claims[claimId];
        if (c.resolved) revert ClaimAlreadyResolved(claimId);

        Incident storage inc = incidents[incidentId];
        // Payout is valid only in the Open state: a Killed incident is terminal, and a
        // Disputed one has its root cleared (so the merkle check below would fail anyway) —
        // the status gate makes the intent explicit and blocks a payout on a distrusted
        // root regardless of timing. A correction lands the incident back in Open.
        if (
            inc.status != Status.Open || inc.root == bytes32(0) || block.timestamp <= inc.claimWindowEndTime
                || block.timestamp <= inc.rootSubmittedAt + DISPUTE_PERIOD
                || block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD + FINALIZE_WINDOW
        ) {
            // Independent backstop (H-03): a payout can NEVER land before the claim
            // window closes, regardless of how/when the root was committed. Today this
            // is implied by settle/correct both stamping rootSubmittedAt post-window,
            // but guarding the payout directly keeps that guarantee if either path changes.
            revert FinalizeNotOpen(incidentId);
        }

        address[] storage poolAddrs = incidentPools[incidentId];
        {
            // Row aligns to the pool list snapshotted at open — the exact order the
            // settler built it over — so alignment holds regardless of any later
            // topology change.
            if (amounts.length != poolAddrs.length) revert InvalidProof(claimId);
            // Merkle-prove this exact payout row is a leaf of the TEE-signed,
            // dispute-reviewed root: a payout can only be one that survived dispute.
            // Leaf is the OZ StandardMerkleTree double-hash of the claim tuple.
            bytes32 leaf = keccak256(
                bytes.concat(
                    keccak256(abi.encode(incidentId, claimId, msg.sender, amounts, scoreSpent, eligibleAmount))
                )
            );
            if (!MerkleProof.verifyCalldata(proof, inc.root, leaf)) revert InvalidProof(claimId);
        }

        // Mark THIS claim resolved so it can't be re-finalized, but DON'T drop the
        // incident's live-claim count yet (H-01). The refund/booster/payout steps
        // below make external calls (a callback-capable insured token or booster),
        // and if this is the last unresolved claim, decrementing here would flip
        // {activeIncidentId} to 0 mid-payout — a callback could then re-enter a cover
        // pool's {completeRedeem} while it reads as UNFROZEN and exit at the pre-loss
        // share price, dumping the loss on remaining LPs. nonReentrant guards
        // re-entry into THIS contract, not into the pool. Keep the incident active
        // through every external interaction; decrement only at the very end.
        c.resolved = true;

        // Escrow settles. Only the signed `eligibleAmount` is forfeited (kept here as
        // unaccounted balance, sweepable as protocol revenue); any excess the claimant
        // over-escrowed is refunded, so escrowing more than one's pre-incident holding
        // is harmless. eligibleAmount ≤ escrow always holds off-chain (eligibleAmount =
        // min(pre-incident holding, escrow)); guarded here against a malformed leaf.
        {
            uint256 escrow = c.insuredTokenAmount;
            if (eligibleAmount > escrow) revert EligibleExceedsEscrow(eligibleAmount, escrow);
            escrowedInsuredTokens[inc.insuredToken] -= escrow;
            uint256 refund = escrow - eligibleAmount;
            if (refund > 0) inc.insuredToken.safeTransfer(msg.sender, refund);
        }

        // Burn the committed boosters from the claimant — the cost of the boost.
        // They must still hold them and have approved this contract; otherwise this
        // reverts and the claim can't finalize (keeping them is their responsibility).
        // Burned from the collection snapshotted at join, not the pool's current one.
        //
        // ACCEPTED (audit C2): a claimant who burns/moves their booster first makes
        // their own finalize revert, so the claim stays unresolved and the pool
        // stays frozen for the rest of the FINALIZE phase. This is liveness-only,
        // not fund loss (the griefer forfeits their own boost and recovers escrow
        // afterward), and it extends the freeze no further than a claimant simply
        // never calling finalize already could — the freeze is bounded by the
        // FINALIZE phase either way. So it is not a new DoS; accepted as designed.
        {
            uint256 boosterAmount = c.boosterAmount;
            if (boosterAmount != 0) {
                IERC1155Burnable(c.boosterCollection).burn(msg.sender, BOOSTER_ID, boosterAmount); //continue here.
                c.boosterAmount = 0;
            }
        }

        // Pay each pool its settlement-row amount, drawing down that pool's remaining
        // per-incident budget ({incidentPoolBudget}, set to the TEE-committed
        // poolPayouts at settle). This hard-caps the ACTUAL summed payout per pool at
        // the committed total — the cap holds against the real leaves, not just the
        // signer's declared number. On an honest root Σ(row amounts) == committed, so
        // the budget lands exactly at 0 and every claim finalizes. Only a malformed
        // root whose leaves over-allocate a pool (Σ > committed) can exhaust the
        // budget early and revert a later claim; that is a bad root — the dispute
        // window / {disputeIncident} is its primary defense, and this is the LP-loss
        // backstop for one that slips through (the reverted claimant recovers escrow
        // via {withdrawNonFinalizedClaim}). Each pool also re-checks amount ≤ its live
        // balance and socializes the loss; zeros are skipped by the pool.
        uint256[] storage budget = incidentPoolBudget[incidentId];
        for (uint256 i = 0; i < poolAddrs.length; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;
            uint256 remaining = budget[i];
            if (amt > remaining) revert PayoutCapExceeded(i, amt, remaining);
            budget[i] = remaining - amt;
            ISingleAssetCoverPool(poolAddrs[i]).payClaim(msg.sender, amt);
        }

        // Consumed insurance score is recorded two ways: an incident-tagged
        // {ScoreSpent} event that the settler sums (pinned before the incident's
        // openBlock) for each claimant's per-incident budget, AND a cumulative running
        // total on the {Registry} ({recordScoreSpent}) for cheap on-chain / frontend
        // reads. The Registry total is a mirror of this authoritative number, not a
        // gate. No cross-product double-spend risk — a single payout module.
        if (scoreSpent != 0) {
            emit ScoreSpent(msg.sender, scoreSpent, incidentId);
            registry().recordScoreSpent(msg.sender, scoreSpent);
        }

        // All external interactions are done — NOW retire this claim from the live
        // count (H-01). Only here can the incident become {activeIncidentId} == 0
        // (pool unfrozen), after the payout has fully landed.
        inc.unresolved -= 1;
        if (inc.unresolved == 0 && incidentResolvedAt[incidentId] == 0) {
            incidentResolvedAt[incidentId] = uint64(block.timestamp);
        }

        emit ClaimFinalized(claimId, msg.sender);
    }

    /// @notice Recover the escrow of a claim that will never finalize: its incident was
    ///         killed, halted with no correction in time (auto-voided past
    ///         {CORRECTION_WINDOW}), voided (no root by the deadline), or its FINALIZE
    ///         phase expired unused. Callable anytime after, forever.
    /// @dev    Deliberately NOT whenNotPaused (unlike open/join/settle/finalize):
    ///         escrow recovery — and {cancelClaim} — must never be blockable by a
    ///         pause, so a pause can't trap claimant funds.
    /// @param claimId  Caller's claim whose escrow to recover.
    function withdrawNonFinalizedClaim(uint256 claimId) external nonReentrant {
        Claim storage c = claims[claimId];
        if (c.user != msg.sender) revert UnauthorizedClaim(claimId);
        if (c.resolved) revert ClaimAlreadyResolved(claimId);

        Incident storage inc = incidents[c.incidentId];
        // Escrow is recoverable once the incident can no longer pay this claim:

        //if it was killed;
        bool killed = inc.status == Status.Closed;

        //if it was halted and its correction never came (auto-voided past CORRECTION_WINDOW);
        bool disputeExpired = inc.status == Status.Disputed && block.timestamp > inc.disputedAt + CORRECTION_WINDOW;

        //The Open-state gates below exclude a live Disputed
        // incident (frozen, still correctable) — its root==0 must NOT read as "void" yet.
        // it voided in SETTLE (no root by the deadline);
        bool incidentVoid = inc.status == Status.Open && inc.root == bytes32(0)
            && block.timestamp > inc.claimWindowEndTime + SUBMIT_DEADLINE;

        // its FINALIZE phase expired unused.
        bool finalizeExpired = inc.status == Status.Open && inc.root != bytes32(0)
            && block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD + FINALIZE_WINDOW;

        if (!killed && !disputeExpired && !incidentVoid && !finalizeExpired) revert ClaimNotWithdrawable(claimId);

        c.resolved = true;
        inc.unresolved -= 1;
        escrowedInsuredTokens[inc.insuredToken] -= c.insuredTokenAmount;
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);

        emit ClaimWithdrawn(claimId, msg.sender);
    }

    // ─────────────────────────── Role management ───────────────────────────

    /// @notice Rotate the TEE settlement signer. Timelock only, and blocked while an
    ///         incident is active (L5): the settlement authority can't change out
    ///         from under an in-flight incident, so the signer that was current at
    ///         open is the one that settles it. Every enclave code upgrade generates
    ///         a fresh in-enclave key, so rotation is a publicly visible,
    ///         timelock-delayed event whose delay is the community's window to
    ///         reproduce the new build's published measurement. Zero disables
    ///         {settleIncident}.
    ///
    ///         Recovery: if the enclave is permanently down, rotate to a governance
    ///         recovery key BETWEEN incidents, then open + settle. A dead enclave
    ///         mid-incident can't be recovered in place — the incident voids after
    ///         SUBMIT_DEADLINE and escrow is returned; a mistaken or bad-root
    ///         incident is instead disputed ({disputeIncident}) or closed ({closeIncident}).
    /// @param signer      Enclave key address to add or remove (non-zero).
    /// @param authorized  true to authorize (add), false to revoke (remove).
    function setTeeSigner(address signer, bool authorized) external onlyTimelock notDuringIncident {
        if (signer == address(0)) revert ZeroAddress();
        isTeeSigner[signer] = authorized;
        emit TeeSignerSet(signer, authorized);
    }

    // ─────────────────────────── Views ───────────────────────────

    /// @notice The single active incident id, or 0 if none. Derived and validated —
    ///         never a stale non-zero (unlike a stored pointer would be). The Registry
    ///         reads this (as {IDefiInsurance}) and treats non-zero as "system frozen",
    ///         so the pools gate staker withdrawals and asset curation on it.
    function activeIncidentId() external view returns (uint256) {
        return _activeIncidentId();
    }

    /// @notice The full per-token config (κ, oracle, conversion recipe).
    /// @param insuredToken  Insured token to query.
    function getInsuredToken(IERC20 insuredToken) external view returns (InsuredToken memory) {
        return insuredTokens[insuredToken];
    }

    /// @notice Number of insured tokens currently in the approval list.
    function insuredTokenListLength() external view returns (uint256) {
        return insuredTokenList.length;
    }

    /// @notice Units of {BOOSTER_ID} committed by a claim (0 if none). Not escrowed
    ///         — burned from the claimant's wallet at finalize.
    /// @param claimId  Claim to query.
    function getClaimBoosterAmount(uint256 claimId) external view returns (uint256) {
        return claims[claimId].boosterAmount;
    }

    /// @notice Open and resolved timestamps for the latest incident.
    /// @dev resolvedAt is 0 while the latest incident is still active or not yet
    ///      deterministically ended. Deadline-derived endings report the first
    ///      timestamp at which {activeIncidentId} returns 0.
    function latestIncidentTimestamps() external view returns (uint64 openedAt, uint64 resolvedAt) {
        uint256 id = nextIncidentId - 1;
        if (id == 0) return (0, 0);
        Incident storage inc = incidents[id];
        openedAt = inc.claimWindowEndTime - CLAIM_WINDOW;
        resolvedAt = _incidentResolvedAt(id, inc);
    }

    // ─────────────────────────── Internal: incident lifecycle ───────────────────────────

    function _incidentResolvedAt(uint256 id, Incident storage inc) internal view returns (uint64) {
        uint64 stamped = incidentResolvedAt[id];
        if (stamped != 0) return stamped;
        // A Closed incident is always stamped above (closeIncident records the time),
        // so it never reaches the deadline-derived branches below.

        if (inc.status == Status.Disputed) {
            uint256 disputeEnd = uint256(inc.disputedAt) + CORRECTION_WINDOW;
            return block.timestamp > disputeEnd ? uint64(disputeEnd + 1) : 0;
        }

        if (block.timestamp <= inc.claimWindowEndTime) return 0;
        if (inc.unresolved == 0) return inc.claimWindowEndTime + 1;

        if (inc.root == bytes32(0)) {
            uint256 submitEnd = uint256(inc.claimWindowEndTime) + SUBMIT_DEADLINE;
            return block.timestamp > submitEnd ? uint64(submitEnd + 1) : 0;
        }

        uint256 finalizeEnd = uint256(inc.rootSubmittedAt) + DISPUTE_PERIOD + FINALIZE_WINDOW;
        return block.timestamp > finalizeEnd ? uint64(finalizeEnd + 1) : 0;
    }

    /// @dev The single active incident id, or 0 if none — the ONE source of truth.
    ///      Incidents are strictly one-at-a-time, so the only candidate is always the
    ///      last-opened ({nextIncidentId} - 1); its activeness (phase machine, until it
    ///      terminates) is validated inline. No stored pointer to go stale: every id
    ///      this returns is guaranteed active. Callers layer their own phase check
    ///      (claim window / settle / finalize) on top as needed.
    function _activeIncidentId() internal view returns (uint256) {
        uint256 id = nextIncidentId - 1; // 0 before the first open
        if (id == 0) return 0;
        Incident storage inc = incidents[id];
        if (inc.status == Status.Closed) return 0; // killed — pool unfrozen
        // Disputed: root cleared, pool STILL frozen awaiting a timelock correction. Auto-
        // voids (unfreezes) if none lands within CORRECTION_WINDOW, so a stalled
        // governance can't freeze forever.
        if (inc.status == Status.Disputed) return block.timestamp <= inc.disputedAt + CORRECTION_WINDOW ? id : 0;
        if (block.timestamp <= inc.claimWindowEndTime) return id;
        if (inc.unresolved == 0) return 0;
        if (inc.root == bytes32(0)) return block.timestamp <= inc.claimWindowEndTime + SUBMIT_DEADLINE ? id : 0;
        return block.timestamp <= inc.rootSubmittedAt + DISPUTE_PERIOD + FINALIZE_WINDOW ? id : 0;
    }

    /// @dev {_activeIncidentId} but reverts when there is none — for sites that require
    ///      a live incident (cancel, close).
    function _requireActiveIncident() internal view returns (uint256 id) {
        id = _activeIncidentId();
        if (id == 0) revert NotActiveIncident(0);
    }

    /// @dev Delist an insured token (zero its maxCoverageBps) and remove it from
    ///      {insuredTokenList}. No-op if absent.
    function _delistInsuredToken(IERC20 insuredToken) internal {
        if (insuredTokens[insuredToken].maxCoverageBps == 0) return;
        insuredTokens[insuredToken].maxCoverageBps = 0;
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
