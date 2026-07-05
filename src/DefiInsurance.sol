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
import {Managed} from "./Managed.sol";

/// @notice Minimal view of the deployed ERC-1155 USD8Booster: standard
///         transfers plus the ERC1155Burnable batch burn (this contract, as
///         the token holder, is authorized to call it). Boosters are
///         semi-fungible — id denotes a tier (id 1 = the 1% booster), held in
///         quantity — so commits always work in (ids, amounts) batches.
interface IERC1155Burnable is IERC1155 {
    function burn(address account, uint256 id, uint256 value) external;
}

/// @notice Minimal view of a single-asset stake pool. DefiInsurance is the
///         {Registry.payoutModule}: it reads the registered pool set from the
///         Registry and pays each its settlement-row amount out of pooled capital.
///         Pools are product-agnostic; the insurance logic lives here.
interface ISingleAssetCoverPool {
    function payClaim(address to, uint256 amount) external;
    function totalAssets() external view returns (uint256);
}

/// @title  DefiInsurance v1
/// @notice DeFi-depeg insurance built on the {SingleAssetCoverPool} capital base
///         (one pool per stake asset, registered on the {Registry}). Holders of a
///         covered token that suffers a depeg escrow it here to claim a payout out
///         of the pools' staked capital. This contract owns all product logic —
///         insured-token registry, incident lifecycle, claimant escrow, settlement
///         — and calls the pools only to pay claims ({SingleAssetCoverPool.payClaim}).
///         It is the single {Registry.payoutModule}; the score a claim consumes is
///         recorded as a {ScoreSpent} event (no on-chain ledger). Other products
///         (e.g. travel insurance) could later take over the payout-module slot.
///
///         Incidents are processed ONE AT A TIME: while one is active the whole
///         system is frozen ({Registry.frozen}) — pool exits and topology curation
///         (pool set, scored tokens) are blocked — so settlement runs against a
///         single deterministic pool set. The freeze is implicit: the pools read
///         {Registry.frozen}, which reads this module's {incidentActive}.
///
///         Both lifecycle transitions are TEE-signed and permissionless to
///         relay, with admin/timelock kept only as fallbacks:
///         - OPEN: anyone may {openIncidentSigned} carrying the TEE's EIP-712
///           attestation that the token depegged (the enclave evaluates the
///           depeg off-chain — the same trust root that signs settlement).
///           Admin/timelock retains {openClaimIncident} for when the TEE is
///           down/censoring or for events it can't attest.
///         - SETTLE: anyone may {settleIncident} with the settlement root computed
///           off-chain over the incident's on-chain claim set plus an EIP-712
///           signature from {teeSigner} — the key held only inside the
///           published TEE build that runs the open-source settlement code. The
///           root is the merkle commitment to the whole settlement table (the
///           dispute anchor); each per-claim payout is proven against it at
///           {finalizeClaim}, so a payout can only be one that survived dispute.
///           Settlement stays optimistic: anyone reproduces the root, a
///           corrected root may be resubmitted within the submit window, and the
///           admin/timelock can {closeIncident} to kill a bad one (deny-only —
///           never redirects funds).
///
///         Incident timeline (t measured from open; durations are the state
///         constants; the pool stays LOCKED for the whole span):
///
///           t=0     OPEN — pool locked; {Incident.openBlock} recorded so the
///            │            settlement config (insured-token recipe, windows,
///            │            scored-token set) is reconstructible from on-chain
///            │            state at that block, immune to any later retune.
///            │            {openIncidentSigned} (TEE-attested) or
///            │            {openClaimIncident} (admin/timelock fallback).
///            │  ┄ CLAIM_WINDOW (4d): {joinClaim} / {cancelClaim}.
///            ▼
///           4d      claim window ends.
///            │  ┄ SUBMIT phase (≤ SUBMIT_DEADLINE = 3d): {settleIncident} posts
///            │      the TEE-signed root; a corrected root may OVERWRITE here.
///            │      No root by t=7d ⇒ incident VOID, escrow recoverable.
///            ▼
///           T_s     root submitted, at some point in (4d, 7d].
///            │  ┄ DISPUTE_PERIOD (4d): no payouts; {closeIncident} may veto —
///            │      this is the LAST stage a close is allowed.
///            ▼
///           T_s+4d  dispute ends — root is now final.
///            │  ┄ FINALIZE_WINDOW (4d): {finalizeClaim} pays each claim; no
///            │      close possible. The pool UNLOCKS the instant the LAST claim
///            │      finalizes — often well before +4d.
///            ▼
///           T_s+8d  incident fully resolved.
///
///         Total pool-lock: CLAIM_WINDOW + [0, SUBMIT_DEADLINE] + DISPUTE_PERIOD
///         + FINALIZE_WINDOW = 12–15 days (≈7 days if it voids). Early unlocks:
///         {closeIncident} ends it any time up to the dispute-period end;
///         all-finalized ends it inside the finalize window.
/// @dev    Non-upgradeable. To change it, deploy a fresh instance and re-point
///         the {Registry} payout-module slot (only between incidents — the old
///         instance still custodies escrow + open claims). Custodies insured-token
///         escrow only; committed boosters stay in the claimant's wallet and are
///         burned from it at finalize (not escrowed here).
contract DefiInsurance is ReentrancyGuardTransient, EIP712, Managed {
    using SafeERC20 for IERC20;

    // ─────────────────────────── State ───────────────────────────

    /// @notice The TEE settlement signer: the EIP-712 key generated and held
    ///         inside the published enclave build that runs the off-chain
    ///         settlement computation. {settleIncident} accepts a root from
    ///         anyone carrying this key's signature — the ONLY settlement path.
    ///         Timelock-rotated on every enclave code upgrade (per-release
    ///         keygen), and the sole recovery lever: zero disables settlement,
    ///         and a permanent enclave outage is handled by rotating to a
    ///         governance key (see {setTeeSigner}).
    address public teeSigner;

    // ─────────────────────────── State (insured tokens) ───────────────────────────

    /// @notice Basis-point denominator (100%) and the hard ceiling for a token's
    ///         coverage factor κ ({InsuredToken.maxCoverageBps}): κ ∈ (0, 100%].
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Per-insured-token config. maxCoverageBps == 0 means not listed.
    /// @param maxCoverageBps  κ in (0, 100%] (bps) while listed.
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

    // ─────────────────────────── State (incidents + claims) ───────────────────────────

    /// @notice Length of an incident's claim window.
    uint64 public constant CLAIM_WINDOW = 4 days;

    /// @notice Deadline to submit a settlement root, measured from the claim
    ///         window end. No root by then ⇒ incident void, escrow recoverable.
    uint64 public constant SUBMIT_DEADLINE = 3 days;

    /// @notice Dispute period, measured from {Incident.rootSubmittedAt} — a fixed
    ///         window so a late submission can never compress it. No payout
    ///         before it elapses; admin/timelock may {closeIncident} until then.
    uint64 public constant DISPUTE_PERIOD = 4 days;

    /// @notice Finalization window after the dispute period ends. Total pool lock
    ///         is CLAIM_WINDOW + [0, SUBMIT_DEADLINE] + DISPUTE_PERIOD +
    ///         FINALIZE_WINDOW = 12–15 days (7 days if the incident voids).
    uint64 public constant FINALIZE_WINDOW = 4 days;

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
    ///                        the entire submit window (joins and cancels end at
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
    /// @param closed          True once terminated ({closeIncident}); the pool
    ///                        unlocks and claimants recover escrow.
    struct Incident {
        IERC20 insuredToken;
        uint64 claimWindowEndTime;
        bytes32 root;
        uint256 unresolved;
        uint64 rootSubmittedAt;
        uint64 referenceBlock;
        uint64 openBlock;
        bool closed;
    }

    /// @notice All incidents by id. Id 0 is reserved.
    mapping(uint256 incidentId => Incident) public incidents;

    /// @notice The registered pool set snapshotted at each incident's open — the
    ///         payout-row order {finalizeClaim} pays against (the settler built the
    ///         row over the same openBlock list). Pins alignment independent of any
    ///         later {Registry} topology change.
    mapping(uint256 incidentId => address[]) internal incidentPools;

    /// @notice Next incident id to assign. Starts at 1.
    uint256 public nextIncidentId;

    /// @notice The single in-flight incident, or 0 if none. While active it
    ///         blocks new incidents and keeps the pool locked.
    uint256 public activeIncidentId;

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
    ///         only ever affects incidents opened after it. See the field docs.
    /// @param twapLookbackBlocks   W: averaging window for the token→underlying
    ///                             ratio, TWAP'd over [referenceBlock − W,
    ///                             referenceBlock] — the pre-incident value.
    /// @param holdingMarginBlocks  margin: how far before {Incident.referenceBlock}
    ///                             the holding must reach. Eligibility is the MIN
    ///                             balance over [referenceBlock − margin,
    ///                             joinBlock − 1] — ending the block before the
    ///                             claim's joinClaim so the escrow transfer itself
    ///                             can't reduce it — capped at escrow (anti-gaming).
    /// @param sampleStepBlocks     stride between TWAP samples (cost↔precision).
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
    ///         the enclave scored: it is frozen across the whole submit window (no
    ///         join/cancel after window-close, no finalize until the dispute period
    ///         passes), every claim is on-chain, and a root signed for a different
    ///         count can never be submitted here (the digest wouldn't recover teeSigner).
    bytes32 internal constant SETTLEMENT_TYPEHASH =
        keccak256("Settlement(uint256 incidentId,bytes32 root,uint256 unresolved)");

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
    error OutsideSettlementPhase(uint256 incidentId);
    error NoStandingRoot(uint256 incidentId);
    error FinalizeNotOpen(uint256 incidentId);
    error InvalidProof(uint256 claimId);
    error ClaimNotWithdrawable(uint256 claimId);
    error IncidentsActive();
    error InvalidSettlementParams();
    error NoActiveIncidentToJoin(IERC20 insuredToken);
    error UnauthorizedOpenSigner(address recovered);
    error UnauthorizedSettlementSigner(address recovered);
    error BoosterAmountTooLarge(uint256 boosterAmount);

    // ─────────────────────────── Events ──────────────────────────

    event InsuredTokenAdded(IERC20 indexed insuredToken);
    event MaxCoverageBpsSet(IERC20 indexed insuredToken, uint256 maxCoverageBps);
    event UnderlyingConversionSet(IERC20 indexed insuredToken, address conversionAddress, bytes conversionCallData);
    event UnderlyingPriceOracleSet(IERC20 indexed insuredToken, address underlyingPriceOracle);
    event InsuredTokenRemoved(IERC20 indexed insuredToken);
    event SettlementParamsSet(SettlementParams params);
    event IncidentOpened(uint256 indexed incidentId, IERC20 indexed insuredToken, uint64 claimWindowEndTime);
    event IncidentSettled(uint256 indexed incidentId, bytes32 root);
    event IncidentClosed(uint256 indexed incidentId, address indexed closer);
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
    event TeeSignerSet(address indexed oldSigner, address indexed newSigner);

    /// @notice Emitted on {finalizeClaim} for the insurance score a claim consumed.
    ///         This IS the spent-score ledger — the settler sums these logs per user
    ///         (pinned before an incident's openBlock) for the available budget.
    event ScoreSpent(address indexed user, uint256 amount, uint256 indexed incidentId);

    // ─────────────────────────── Constructor ─────────────────────

    /// @notice Deploy the (non-upgradeable) insurance product. To replace it,
    ///         deploy a fresh DefiInsurance and re-point {Registry.setPayoutModule}
    ///         — done only while no incident is in flight, since the old contract
    ///         still custodies escrow and any open claims.
    /// @param _authority  Shared access + topology registry. This contract must be
    ///                    registered via {Registry.setPayoutModule}. The timelock's
    ///                    minDelay MUST be comfortably under {DISPUTE_PERIOD} so it
    ///                    can {closeIncident} on a bad root in time.
    constructor(Registry _authority) EIP712("DefiInsurance", "1") {
        _setAuthority(_authority);
        nextIncidentId = 1;
        nextClaimId = 1;
    }

    // ═══════════════════════════ Insured token management (timelock) ═══════════════════════════

    /// @notice Approve a new insured token and set the economic config settlement
    ///         consumes. Timelock only. Must not be a pool stake asset, nor
    ///         already listed.
    /// @param insuredToken         Token to insure.
    /// @param _maxCoverageBps      κ in (0, 100%] (bps); the timelock picks it.
    /// @param underlyingPriceOracle  underlying→USD oracle (non-zero). Not the insured token. e.g. insure token is sGHO, underlying is GHO, underlyingPriceOracle is for GHO.
    /// @param conversionAddress    token→underlying staticcall target (0 = identity).
    /// @param conversionCallData   calldata for that staticcall. See {InsuredToken}.
    function addInsuredToken(
        IERC20 insuredToken,
        uint256 _maxCoverageBps,
        address underlyingPriceOracle,
        address conversionAddress,
        bytes calldata conversionCallData
    ) external onlyTimelock {
        if (address(insuredToken) == address(0) || underlyingPriceOracle == address(0)) revert ZeroAddress();
        if (authority.poolOf(insuredToken) != address(0)) revert TokenConflict();
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
    function setMaxCoverageBps(IERC20 insuredToken, uint256 _maxCoverageBps) external onlyTimelock {
        if (insuredTokens[insuredToken].maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
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
    {
        InsuredToken storage t = insuredTokens[insuredToken];
        if (t.maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
        t.underlyingConversionAddress = conversionAddress;
        t.underlyingConversionCallData = conversionCallData;
        emit UnderlyingConversionSet(insuredToken, conversionAddress, conversionCallData);
    }

    /// @notice Update an insured token's underlying→USD price oracle. Timelock only.
    /// @param insuredToken  Listed insured token to update.
    /// @param underlyingPriceOracle   New oracle address (non-zero).
    function setUnderlyingPriceOracle(IERC20 insuredToken, address underlyingPriceOracle) external onlyTimelock {
        if (insuredTokens[insuredToken].maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
        if (underlyingPriceOracle == address(0)) revert ZeroAddress();
        insuredTokens[insuredToken].underlyingPriceOracle = underlyingPriceOracle;
        emit UnderlyingPriceOracleSet(insuredToken, underlyingPriceOracle);
    }

    /// @notice Remove an approved insured token. Admin or timelock — deny-only
    ///         and recoverable (re-add to relist); moves no funds. Allowed even
    ///         if a prior incident is unresolved — existing claims continue.
    /// @param insuredToken  Approved insured token to delist.
    function removeInsuredToken(IERC20 insuredToken) external onlyAdminOrTimelock {
        if (insuredTokens[insuredToken].maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
        _delistInsuredToken(insuredToken);
    }

    /// @notice Set the global settlement windows (blocks). Timelock only. Safe at
    ///         any time: each incident is settled against these params as of its
    ///         {Incident.openBlock}, so a change only affects later incidents.
    /// @param p  New settlement windows. See {SettlementParams}.
    function setSettlementParams(SettlementParams calldata p) external onlyTimelock {
        // sampleStepBlocks is the TWAP loop stride off-chain; 0 would never advance.
        if (p.sampleStepBlocks == 0) revert InvalidSettlementParams();
        settlementParams = p;
        emit SettlementParamsSet(p);
    }

    /// @dev Rescuable via {Managed-rescueToken}: only the non-accountable
    ///      insured-token balance (forfeited revenue or strays) — live claim
    ///      escrow ({escrowedInsuredTokens}) is protected. While an incident on
    ///      the token is live its balance is in flux, so the cap is 0 (blocked).
    function _sweepable(address token) internal view override returns (uint256) {
        if (_hasActiveIncident() && incidents[activeIncidentId].insuredToken == IERC20(token)) return 0;
        uint256 accounted = escrowedInsuredTokens[IERC20(token)];
        uint256 bal = IERC20(token).balanceOf(address(this));
        return bal > accounted ? bal - accounted : 0;
    }

    // ═══════════════════════════ Incident + claim lifecycle ═══════════════════════════

    /// @notice Open an incident permissionlessly with a TEE attestation. The
    ///         enclave — running the published depeg-detection code — evaluates
    ///         the depeg off-chain and signs {OPEN_TYPEHASH}(insuredToken,
    ///         referenceBlock, nextIncidentId); anyone may relay it. This is the
    ///         primary open path: the "should we open" decision lives in the
    ///         TEE (the same trust root that signs settlement), not in on-chain
    ///         rate logic. Opens WITHOUT a claim; use {closeIncident} to abort a
    ///         mistaken open. A spurious open is only a pool freeze, never a
    ///         drain (payout still needs a signed root surviving the dispute).
    /// @param  insuredToken    Token the TEE attested a covered event on.
    /// @param  referenceBlock  Pre-incident "before" block the TEE pinned.
    /// @param  signature       {teeSigner}'s EIP-712 signature over the open struct.
    /// @return incidentId      The newly opened incident id.
    function openIncidentSigned(IERC20 insuredToken, uint64 referenceBlock, bytes calldata signature)
        external
        returns (uint256 incidentId)
    {
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(OPEN_TYPEHASH, address(insuredToken), referenceBlock, nextIncidentId))
        );
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != teeSigner || teeSigner == address(0)) revert UnauthorizedOpenSigner(recovered);
        return _openIncident(insuredToken, referenceBlock);
    }

    /// @notice Open an incident on insuredToken. Admin/timelock fallback for
    ///         when the TEE is down/censoring, or for covered events the TEE
    ///         can't attest. Opens WITHOUT a claim; use {closeIncident} to abort.
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
    ///      {incidentActive}, true once the incident is recorded below. The insured
    ///      token is delisted later, at root submission (a confirmed event), not
    ///      here — so an incident that opens and closes without a root leaves
    ///      the listing untouched.
    function _openIncident(IERC20 insuredToken, uint64 referenceBlock) internal returns (uint256 incidentId) {
        // Global precondition, token-independent: fail fast before any storage copy.
        if (_hasActiveIncident()) revert IncidentsActive();

        InsuredToken memory it = insuredTokens[insuredToken];
        if (it.maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
        // Non-zero, in the past, and recent: the freshness bound doubles as the
        // open attestation's expiry (I1) — a stale signed open can't be relayed late.
        if (
            referenceBlock == 0 || referenceBlock >= block.number
                || block.number - referenceBlock > OPEN_MAX_REFERENCE_AGE
        ) revert InvalidReferenceBlock(referenceBlock);

        // No explicit pool lock: this module is the single {Registry.payoutModule},
        // so the pools' freeze (registry.frozen()) reads our incidentActive()
        // implicitly once the incident below is recorded. _hasActiveIncident()
        // above is the one-at-a-time guard.

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
            closed: false
        });
        activeIncidentId = incidentId;

        // Snapshot the pool set at open. finalizeClaim pays each claim's amounts[]
        // row against THIS list (not live {Registry.pools}), so payouts stay aligned
        // to the exact order the settler built the row over at openBlock — even if
        // topology were mutated mid-incident (only reachable via the setPayoutModule(0)
        // emergency brake, which bypasses the freeze). Without the snapshot a reorder
        // would mispay or revert.
        (, address[] memory poolAddrs) = authority.pools();
        incidentPools[incidentId] = poolAddrs;

        emit IncidentOpened(incidentId, insuredToken, wEnd);
    }

    /// @notice File a claim on the live incident for insuredToken. Requires an
    ///         incident already open on it (via {openIncidentSigned} or
    ///         {openClaimIncident}) with its claim window still open. Escrows the
    ///         insured token (and any booster units); the claim's parameters are
    ///         emitted in {ClaimRegistered} for off-chain settlement to replay.
    /// @param insuredToken        Token whose open incident to join.
    /// @param insuredTokenAmount  Escrow for this claim.
    /// @param scoreToSpend        Insurance score the claimant requests to spend
    ///                            (capped off-chain to their available).
    /// @param boosterAmount       Units of the canonical booster ({BOOSTER_ID}) to
    ///                            commit (0 = none). Each unit boosts the score.
    ///                            Not transferred now — kept by the claimant and
    ///                            burned from them at {finalizeClaim}.
    /// @return claimId The newly minted claim id.
    function joinClaim(IERC20 insuredToken, uint128 insuredTokenAmount, uint256 scoreToSpend, uint256 boosterAmount)
        external
        nonReentrant
        returns (uint256 claimId)
    {
        if (insuredTokenAmount == 0) revert ZeroAmount();

        uint256 incidentId = activeIncidentId;
        // An incident must be live on THIS token with an open window. A different
        // token holding the pool means one-at-a-time blocks us.
        if (incidentId == 0 || !_incidentActive(incidentId)) revert NoActiveIncidentToJoin(insuredToken);
        Incident storage cur = incidents[incidentId];
        if (cur.insuredToken != insuredToken) revert IncidentsActive();
        if (block.timestamp > cur.claimWindowEndTime) revert ClaimWindowClosed(insuredToken, cur.claimWindowEndTime);
        // One live claim per account per incident: stops a user splitting one
        // insurance-score budget across many claims to inflate their payout share.
        if (activeClaimId[incidentId][msg.sender] != 0) revert DuplicateClaim(incidentId);

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
            address booster = authority.boosterNFT();
            if (booster == address(0)) revert BoosterNFTUnset();
            // Not escrowed: recorded and burned from the claimant at finalize.
            claims[claimId].boosterAmount = uint128(boosterAmount);
            claims[claimId].boosterCollection = booster; // snapshot the collection to burn from
        }

        incidents[incidentId].unresolved += 1;

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
        uint256 incidentId = activeIncidentId;
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
        activeClaimId[incidentId][msg.sender] = 0; // may re-file within the window
        escrowedInsuredTokens[inc.insuredToken] -= c.insuredTokenAmount;
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);

        emit ClaimCancelled(claimId, msg.sender);
    }

    // ═══════════════════════════ Settlement (TEE-signed root only) ═══════════════════════════

    /// @notice Submit the settlement root permissionlessly, carrying the TEE's
    ///         EIP-712 signature. The enclave — running the published settlement
    ///         code — reconstructs the claimant table from on-chain claims and
    ///         signs Settlement(incidentId, root, unresolved); binding unresolved
    ///         means the signature is only valid for the exact (frozen) live claim
    ///         set it scored. Anyone may relay the signed root; the
    ///         optimistic dispute window and {closeIncident} still apply, and a
    ///         corrected root may be resubmitted within the submit window.
    /// @param incidentId  In-flight incident to settle.
    /// @param root        Settlement root — the commitment over the claim table.
    /// @param signature   {teeSigner}'s EIP-712 signature over the Settlement
    ///                    struct (domain: name "DefiInsurance", version "1",
    ///                    this chain id, this contract).
    function settleIncident(uint256 incidentId, bytes32 root, bytes calldata signature) external {
        Incident storage inc = incidents[incidentId];

        // Cheap phase + root checks first — fail fast before the ECDSA recover.
        // A corrected root may OVERWRITE a standing one while still inside the
        // submit window (resetting the dispute clock) — a bad root is fixed by
        // resubmission, no separate void step. A closed incident has
        // activeIncidentId == 0, so it is rejected here.
        if (root == bytes32(0)) revert NoStandingRoot(incidentId);
        if (incidentId != activeIncidentId) revert NotActiveIncident(incidentId);
        if (block.timestamp <= inc.claimWindowEndTime || block.timestamp > inc.claimWindowEndTime + SUBMIT_DEADLINE) {
            revert OutsideSettlementPhase(incidentId);
        }

        // Authorize: a valid teeSigner signature bound to this incident's exact
        // live claim set via unresolved (frozen across the submit window, on-chain).
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(SETTLEMENT_TYPEHASH, incidentId, root, inc.unresolved)));
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != teeSigner || teeSigner == address(0)) revert UnauthorizedSettlementSigner(recovered);

        inc.root = root;
        inc.rootSubmittedAt = uint64(block.timestamp);
        _delistInsuredToken(inc.insuredToken); // idempotent: no-op on an overwrite; delist on first confirmed event
        emit IncidentSettled(incidentId, root);
    }

    /// @notice Terminate the in-flight incident. Admin or timelock — the no-delay
    ///         deny-only brake. Unfreezes the pool immediately; claimants recover
    ///         escrow via {withdrawNonFinalizedClaim}. Use this to abort a
    ///         mistaken incident, or to kill one whose root is bad and
    ///         uncorrectable. A corrected (not bad) root is instead fixed by
    ///         resubmitting inside the submit window — see {settleIncident}.
    ///
    ///         Allowed only UP TO the end of the dispute period. Once the
    ///         finalize window opens the root is final and claims may already be
    ///         paying out — closing then would strand honest claimants mid-payout
    ///         (fast finalizers paid, the rest closed out), so the veto window is
    ///         the dispute period, never after. No id argument — one incident is
    ///         live at a time ({activeIncidentId}).
    function closeIncident() external onlyAdminOrTimelock {
        uint256 incidentId = activeIncidentId;
        if (incidentId == 0 || !_incidentActive(incidentId)) revert NotActiveIncident(incidentId);
        Incident storage inc = incidents[incidentId];
        if (inc.root != bytes32(0) && block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD) {
            revert IncidentFinalizing(incidentId);
        }
        inc.closed = true;
        activeIncidentId = 0;
        emit IncidentClosed(incidentId, msg.sender);
    }

    /// @notice Finalize a claim against the standing root with its merkle proof.
    ///         amounts is the claimant's per-pool payout row aligned to the pool set snapshotted at
    ///         open; proof is its merkle path against the standing {Incident.root}.
    ///         Paid out of each pool via {ISingleAssetCoverPool.payClaim}; escrow forfeits.
    /// @param claimId     Caller's claim to finalize.
    /// @param amounts     Per-pool payout row, aligned to the incident's pool list.
    /// @param scoreSpent  Insurance score this claim consumes (off-chain-capped),
    ///                    recorded via the {ScoreSpent} event.
    /// @param proof       Merkle proof of the claim's leaf against {Incident.root}.
    function finalizeClaim(uint256 claimId, uint256[] calldata amounts, uint256 scoreSpent, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Claim storage c = claims[claimId];
        if (c.user != msg.sender) revert UnauthorizedClaim(claimId);
        if (c.resolved) revert ClaimAlreadyResolved(claimId);

        uint256 incidentId = c.incidentId;
        Incident storage inc = incidents[incidentId];
        // A closed (admin-vetoed) incident is terminal: only escrow recovery via
        // {withdrawNonFinalizedClaim} is valid after it — never a payout. Without
        // this, close leaves root/rootSubmittedAt intact, so once the dispute
        // period elapsed the timing gate below would pass and a proof for the
        // vetoed root would still drain the pool.
        if (
            inc.closed || inc.root == bytes32(0) || block.timestamp <= inc.rootSubmittedAt + DISPUTE_PERIOD
                || block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD + FINALIZE_WINDOW
        ) {
            revert FinalizeNotOpen(incidentId);
        }

        address[] memory poolAddrs = incidentPools[incidentId];
        {
            // Row aligns to the pool list snapshotted at open — the exact order the
            // settler built it over — so alignment holds regardless of any later
            // topology change.
            if (amounts.length != poolAddrs.length) revert InvalidProof(claimId);
            // Merkle-prove this exact payout row is a leaf of the TEE-signed,
            // dispute-reviewed root: a payout can only be one that survived dispute.
            // Leaf is the OZ StandardMerkleTree double-hash of the claim tuple.
            bytes32 leaf =
                keccak256(bytes.concat(keccak256(abi.encode(incidentId, claimId, msg.sender, amounts, scoreSpent))));
            if (!MerkleProof.verifyCalldata(proof, inc.root, leaf)) revert InvalidProof(claimId);
        }

        c.resolved = true;
        inc.unresolved -= 1;

        // Escrow leaves live accounting; forfeited tokens stay here as
        // unaccounted balance, sweepable as protocol revenue.
        escrowedInsuredTokens[inc.insuredToken] -= c.insuredTokenAmount;

        // Burn the committed boosters from the claimant — the cost of the boost.
        // They must still hold them and have approved this contract; otherwise this
        // reverts and the claim can't finalize (keeping them is their responsibility).
        // Burned from the collection snapshotted at join, not the pool's current one.
        uint256 boosterAmount = c.boosterAmount;
        if (boosterAmount != 0) {
            IERC1155Burnable(c.boosterCollection).burn(msg.sender, BOOSTER_ID, boosterAmount);
            c.boosterAmount = 0;
        }

        // Pay each pool its settlement-row amount (each does its own over-allocation
        // check + loss socialization); zeros are skipped by the pool.
        for (uint256 i = 0; i < poolAddrs.length; i++) {
            if (amounts[i] != 0) ISingleAssetCoverPool(poolAddrs[i]).payClaim(msg.sender, amounts[i]);
        }

        // The consumed insurance score is recorded as an EVENT, not on-chain state:
        // the settler sums ScoreSpent logs (pinned before the incident's openBlock)
        // for each claimant's available budget. No cross-product double-spend risk —
        // a single payout module.
        if (scoreSpent != 0) emit ScoreSpent(msg.sender, scoreSpent, incidentId);

        emit ClaimFinalized(claimId, msg.sender);
    }

    /// @notice Recover the escrow of a claim that will never finalize: its
    ///         incident was closed (admin- or auto-), voided (no root by the
    ///         deadline), or its finalize window expired unused. Callable
    ///         anytime after, forever.
    /// @param claimId  Caller's claim whose escrow to recover.
    function withdrawNonFinalizedClaim(uint256 claimId) external nonReentrant {
        Claim storage c = claims[claimId];
        if (c.user != msg.sender) revert UnauthorizedClaim(claimId);
        if (c.resolved) revert ClaimAlreadyResolved(claimId);

        Incident storage inc = incidents[c.incidentId];
        bool closed = inc.closed; // admin-closed or auto-closed
        bool incidentVoid = inc.root == bytes32(0) && block.timestamp > inc.claimWindowEndTime + SUBMIT_DEADLINE;
        bool finalizeExpired =
            inc.root != bytes32(0) && block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD + FINALIZE_WINDOW;
        if (!closed && !incidentVoid && !finalizeExpired) revert ClaimNotWithdrawable(claimId);

        c.resolved = true;
        inc.unresolved -= 1;
        escrowedInsuredTokens[inc.insuredToken] -= c.insuredTokenAmount;
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);

        emit ClaimWithdrawn(claimId, msg.sender);
    }

    // ═══════════════════════════ Role management ═══════════════════════════

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
    ///         incident is instead vetoed with {closeIncident}.
    /// @param newSigner  The new enclave key's address (zero to disable).
    function setTeeSigner(address newSigner) external onlyTimelock {
        if (_hasActiveIncident()) revert IncidentsActive();
        emit TeeSignerSet(teeSigner, newSigner);
        teeSigner = newSigner;
    }

    // ═══════════════════════════ Views ═══════════════════════════

    /// @notice True while the in-flight incident is unresolved. The pool reads
    ///         this (as a registered consumer) to gate staker withdrawals and
    ///         asset curation for the incident's life.
    function incidentActive() external view returns (bool) {
        return _hasActiveIncident();
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

    // ═══════════════════════════ Internal: incident lifecycle ═══════════════════════════

    /// @dev True while the in-flight incident is unresolved.
    function _hasActiveIncident() internal view returns (bool) {
        return activeIncidentId != 0 && _incidentActive(activeIncidentId);
    }

    /// @dev An incident is active until its phase machine terminates (see the
    ///      pool v1 history for the full rationale).
    function _incidentActive(uint256 incidentId) internal view returns (bool) {
        Incident storage inc = incidents[incidentId];
        if (inc.closed) return false; // explicitly terminated
        if (block.timestamp <= inc.claimWindowEndTime) return true;
        if (inc.unresolved == 0) return false;
        if (inc.root == bytes32(0)) return block.timestamp <= inc.claimWindowEndTime + SUBMIT_DEADLINE;
        return block.timestamp <= inc.rootSubmittedAt + DISPUTE_PERIOD + FINALIZE_WINDOW;
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
