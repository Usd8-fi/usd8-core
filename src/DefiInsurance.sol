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
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IInsuredTokenAdapter} from "./interfaces/IInsuredTokenAdapter.sol";

/// @notice Minimal view of the deployed ERC-1155 USD8Booster: standard
///         transfers plus the ERC1155Burnable batch burn (this contract, as
///         the token holder, is authorized to call it). Boosters are
///         semi-fungible — id denotes a tier (id 1 = the 1% booster), held in
///         quantity — so commits always work in (ids, amounts) batches.
interface IERC1155Burnable is IERC1155 {
    function burn(address account, uint256 id, uint256 value) external;
}

/// @notice The CoverPool capital base this product draws on. DefiInsurance is a
///         registered payout module: it reads the pool's stake-asset list and scored
///         tokens, locks the pool for the incident's life, pays claims out of
///         pooled capital, and records consumed insurance score — all via these
///         hooks. The pool is product-agnostic; the insurance logic lives here.
interface ICoverPool {
    struct ScoredToken {
        IERC20 token;
        uint128 scorePerTokenPerBlock;
        uint64 startBlock;
    }

    function usd8() external view returns (IERC20);
    function isCoverPoolAsset(IERC20 asset) external view returns (bool);
    function coverPoolAssetListLength() external view returns (uint256);
    function getScoredTokens() external view returns (ScoredToken[] memory);
    function boosterNFT() external view returns (address);
    function lockPool() external;
    function payClaim(address to, uint256[] calldata amounts, uint256 scoreSpent) external;
}

/// @title  DefiInsurance v1
/// @notice DeFi-depeg insurance built on the {CoverPool} capital base. Holders
///         of a covered token that suffers a depeg escrow it here to claim a
///         payout out of the pool's staked capital. This contract owns all
///         product logic — insured-token registry, incident lifecycle, claimant
///         escrow, settlement — and calls the pool only to lock it, pay claims,
///         and record spent score. Other products (e.g. travel insurance) can
///         be additional pool payout modules with entirely different internals.
///
///         Incidents are processed ONE AT A TIME: an open incident locks the
///         pool (freezing LP withdrawals + asset curation) so settlement runs
///         against a single deterministic pool.
///
///         Both lifecycle transitions are permissionless once configured, with
///         admin/timelock kept only as fallbacks:
///         - OPEN: anyone may {openTriggeredIncident} when the insured token's
///           adapter ({IInsuredTokenAdapter.triggerState}) reports its metric
///           below {triggerThresholdBps} — one global setting for all tokens —
///           of the adapter's reference (typically a high-water mark) — loss
///           detection by the token's own accounting, no judgment call.
///           Admin/timelock retains {openClaimIncident} for events the metric
///           can't show (e.g. a vault lying about its rate).
///         - SETTLE: anyone may {settleIncidentSigned} with the merkle root
///           computed off-chain from {Incident.inputHash} plus an EIP-712
///           signature from {teeSigner} — the key held only inside the
///           published TEE build that runs the open-source settlement code.
///           Settlement stays optimistic: anyone reproduces the root and the
///           admin/timelock can {voidSettlement} a bad one within the dispute
///           window (deny-only — never redirects funds).
/// @dev    Non-upgradeable. To change it, deploy a fresh instance and re-point
///         CoverPool's payout-module registry (only between incidents — the old
///         instance still custodies escrow + open claims). Holds insured-token
///         escrow and booster NFTs (ERC1155Holder).
contract DefiInsurance is ReentrancyGuardTransient, ERC1155Holder, EIP712 {
    using SafeERC20 for IERC20;

    // ─────────────────────────── State (roles + pool) ───────────────────────────

    /// @notice The capital base this product draws on. Set once at init.
    ICoverPool public coverPool;

    /// @notice Slow governance role (TimelockController). Authorizes upgrades.
    address public timelock;

    /// @notice Fast operational role (fallback opens/settles, voids bad roots).
    address public admin;

    /// @notice The TEE settlement signer: the EIP-712 key generated and held
    ///         inside the published enclave build that runs the off-chain
    ///         settlement computation. {settleIncidentSigned} accepts a root
    ///         from anyone carrying this key's signature. Timelock-rotated on
    ///         every enclave code upgrade (per-release keygen); zero disables
    ///         the signed path (admin/timelock fallback still works).
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
    /// @param adapter  the token's {IInsuredTokenAdapter}: one immutable,
    ///                      ownerless instance per token whose CLASS encodes
    ///                      how this token kind is measured. Serves two
    ///                      consumers:
    ///                      1. The off-chain settler reads
    ///                         adapter.valuationRate() (WAD underlying per
    ///                         1e18 token) at historical blocks — TWAP ending
    ///                         at {Incident.referenceBlock} — to value losses;
    ///                         underlyingPriceOracle then turns underlying
    ///                         into USD.
    ///                      2. {openTriggeredIncident} reads
    ///                         adapter.triggerState() for the permissionless
    ///                         depeg trigger. Adapter classes whose metric
    ///                         can drop without genuine loss (mark-to-market
    ///                         LP pricing etc.) report no trigger reference —
    ///                         those tokens open via admin/timelock only.
    ///                      address(0) = identity: the token IS the underlying
    ///                      (ratio 1:1), no auto-trigger.
    struct InsuredToken {
        uint256 maxCoverageBps;
        address underlyingPriceOracle;
        IInsuredTokenAdapter adapter;
    }

    /// @notice Per-insured-token config. maxCoverageBps == 0 is the not-listed
    ///         signal. Auto-delisted the moment an incident opens on it.
    ///         Read via {getInsuredToken}.
    mapping(IERC20 insuredToken => InsuredToken) internal insuredTokens;

    /// @notice Listed insured tokens in admin-determined order.
    IERC20[] public insuredTokenList;

    /// @notice Global depeg-trigger threshold, all insured tokens: anyone may
    ///         open an incident when a token's trigger metric drops below
    ///         reference × triggerThresholdBps / 10_000 (8_000 ⇒ a ≥20%
    ///         drop — the default). Timelock-updatable via
    ///         {setTriggerThresholdBps}; must be < 10_000 (100% would fire on
    ///         rounding noise); 0 disables permissionless opens entirely
    ///         (admin/timelock fallback only).
    uint256 public triggerThresholdBps;

    // ─────────────────────────── State (incidents + claims) ───────────────────────────

    /// @notice Length of an incident's claim window.
    uint64 public constant CLAIM_WINDOW = 4 days;

    /// @notice Deadline to submit a settlement root, measured from the claim
    ///         window end. No root by then ⇒ incident void, escrow recoverable.
    uint64 public constant SUBMIT_DEADLINE = 3 days;

    /// @notice Dispute period, measured from {Incident.rootSubmittedAt} — a fixed
    ///         window so a late submission can never compress it. No payout
    ///         before it elapses; admin/timelock may {voidSettlement} until then.
    uint64 public constant DISPUTE_PERIOD = 4 days;

    /// @notice Finalization window after the dispute period ends. Total pool lock
    ///         is CLAIM_WINDOW + [0, SUBMIT_DEADLINE] + DISPUTE_PERIOD +
    ///         FINALIZE_WINDOW = 12–15 days (7 days if the incident voids).
    uint64 public constant FINALIZE_WINDOW = 4 days;

    /// @notice A claim incident on a particular insured token. See the v1
    ///         CoverPool history for the full phase-machine rationale.
    /// @param insuredToken    Insured token being claimed against.
    /// @param windowEndTime   Open time + CLAIM_WINDOW.
    /// @param root            admin-submitted merkle root; 0 if none standing.
    /// @param inputHash       Running commitment to the claimant table, chained
    ///                        over every register and cancel while open.
    /// @param claimCount      Number of claims registered.
    /// @param resolvedCount   Claims finalized, cancelled, or withdrawn.
    /// @param rootSubmittedAt Timestamp the standing root was submitted.
    /// @param referenceBlock  Pre-incident block: the "before" point losses are
    ///                        valued against. The high-water-mark block for
    ///                        triggered opens; admin-pinned on the fallback path.
    struct Incident {
        IERC20 insuredToken;
        uint64 windowEndTime;
        bytes32 root;
        bytes32 inputHash;
        uint256 claimCount;
        uint256 resolvedCount;
        uint64 rootSubmittedAt;
        uint64 referenceBlock;
    }

    /// @notice All incidents by id. Id 0 is reserved.
    mapping(uint256 incidentId => Incident) public incidents;

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
    /// @param finalized           True once {finalizeClaim} has paid out.
    /// @param closed              True once cancelled or withdrawn.
    /// @param boosterCollection   The {ICoverPool.boosterNFT} address at join time
    ///                            (snapshotted so burn/return always hit the exact
    ///                            collection the boosters were escrowed in, even if
    ///                            the pool later repoints it). Zero if no boosters.
    struct Claim {
        address user;
        uint256 incidentId;
        uint128 insuredTokenAmount;
        bool finalized;
        bool closed;
        address boosterCollection;
    }

    /// @notice All claims by id. Id 0 is reserved.
    mapping(uint256 claimId => Claim) public claims;

    /// @notice Next claim id to assign. Starts at 1.
    uint256 public nextClaimId;

    /// @notice Whether an account already has a live claim on an incident. At
    ///         most one claim per (incident, account): set on {joinClaim},
    ///         cleared on {cancelClaim}. This caps each account's insurance-score
    ///         spend at its single available budget — a user can't split into
    ///         multiple claims to multiply their score-weighted payout share.
    mapping(uint256 incidentId => mapping(address account => bool)) public hasActiveClaim;

    /// @notice Units of the canonical booster ({BOOSTER_ID}) escrowed by a claim
    ///         while open. Each unit boosts the claimant's insurance score (see
    ///         {BOOSTER_BOOST_BPS}, applied off-chain). Burned on {finalizeClaim};
    ///         returned on cancel/withdraw. 0 = no boosters committed.
    mapping(uint256 claimId => uint256 amount) internal _claimBoosterAmount;

    /// @notice Insured tokens currently held as live claim escrow (summed over
    ///         unresolved claims). Decremented on cancel/withdraw/finalize. Lets
    ///         {sweepInsuredToken} compute the accountable balance without
    ///         iterating claims, so claimant escrow is never sweepable.
    mapping(IERC20 insuredToken => uint256) public escrowedInsuredTokens;

    /// @notice The only booster token id in use. Claims commit units of this id;
    ///         the collection address lives on the pool ({ICoverPool.boosterNFT}).
    uint256 public constant BOOSTER_ID = 1;

    /// @notice Hard-coded booster policy: each committed unit of {BOOSTER_ID}
    ///         adds 100 bps (+1%) to the claimant's insurance-score multiplier.
    ///         Applied off-chain by the settlement code.
    uint256 public constant BOOSTER_BOOST_BPS = 100;

    // ─────────────────────────── State (settlement config) ───────────────────────────

    /// @notice Global settlement windows, in BLOCKS. Timelock-settable; frozen
    ///         while an incident is active and snapshot into each incident at
    ///         open. See the field docs for the exact meaning.
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

    /// @notice Global settlement windows (in blocks). Frozen while an incident is
    ///         active and snapshot per incident at open.
    SettlementParams public settlementParams;

    /// @notice Full settlement config snapshot taken at {openClaimIncident}, used
    ///         off-chain (and any disputer) for the incident's computation. Pins
    ///         all tunable config so a later change can never alter an in-flight
    ///         or settled incident. scoredTokens is snapshot from the pool.
    /// @param maxCoverageBps         κ for the insured token at open.
    /// @param underlyingPriceOracle  underlying→USD oracle at open.
    /// @param adapter                {IInsuredTokenAdapter} at open (0 = identity);
    ///                               the settler reads its valuationRate()
    ///                               at historical blocks.
    /// @param params                 global settlement windows at open.
    /// @param scoredTokens           pool's insurance-score set at open.
    struct IncidentConfig {
        uint256 maxCoverageBps;
        address underlyingPriceOracle;
        IInsuredTokenAdapter adapter;
        SettlementParams params;
        ICoverPool.ScoredToken[] scoredTokens;
    }

    /// @notice Settlement config snapshot per incident, frozen at open.
    mapping(uint256 incidentId => IncidentConfig) internal incidentConfig;

    /// @notice EIP-712 struct the TEE signs over for {settleIncidentSigned}.
    ///         Binding inputHash + claimCount pins the signature to the exact
    ///         claimant table the enclave scored: a root signed over a
    ///         different claim set can never be submitted here.
    bytes32 internal constant SETTLEMENT_TYPEHASH =
        keccak256("Settlement(uint256 incidentId,bytes32 root,bytes32 inputHash,uint256 claimCount)");

    // ─────────────────────────── Errors ──────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error InvalidMaxCoverageBps(uint256 given, uint256 max);
    error InvalidReferenceBlock(uint64 referenceBlock);
    error TokenConflict();
    error UnauthorizedTimelock(address caller);
    error UnauthorizedAdmin(address caller);
    error InsuredTokenAlreadyApproved(IERC20 insuredToken);
    error InsuredTokenNotApproved(IERC20 insuredToken);
    error ClaimWindowClosed(IERC20 insuredToken, uint64 windowEndTime);
    error NoOpenIncident(IERC20 insuredToken);
    error BoosterNFTUnset();
    error UnauthorizedClaim(uint256 claimId);
    error ClaimAlreadyResolved(uint256 claimId);
    error DuplicateClaim(uint256 incidentId);
    error NotActiveIncident(uint256 incidentId);
    error OutsideSettlementPhase(uint256 incidentId);
    error RootAlreadySet(uint256 incidentId);
    error NoStandingRoot(uint256 incidentId);
    error FinalizeNotOpen(uint256 incidentId);
    error InvalidProof(uint256 claimId);
    error ClaimNotWithdrawable(uint256 claimId);
    error IncidentsActive();
    error NothingToSweep(IERC20 token);
    error InvalidSettlementParams();
    error InvalidTriggerThresholdBps(uint256 bps);
    error TriggerNotArmed(IERC20 insuredToken);
    error TriggerNotMet(uint256 rate, uint256 ceiling);
    error InvalidAdapter(address adapter);
    error UnauthorizedSettlementSigner(address recovered);

    // ─────────────────────────── Events ──────────────────────────

    event InsuredTokenAdded(IERC20 indexed insuredToken);
    event MaxCoverageBpsSet(IERC20 indexed insuredToken, uint256 maxCoverageBps);
    event AdapterSet(IERC20 indexed insuredToken, address adapter);
    event UnderlyingPriceOracleSet(IERC20 indexed insuredToken, address underlyingPriceOracle);
    event InsuredTokenRemoved(IERC20 indexed insuredToken);
    event SettlementParamsSet(SettlementParams params);
    event IncidentOpened(uint256 indexed incidentId, IERC20 indexed insuredToken, uint64 windowEndTime);
    event IncidentSettled(uint256 indexed incidentId, bytes32 root);
    event SettlementVoided(uint256 indexed incidentId, address indexed vetoer);
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
    event Swept(IERC20 indexed token, address indexed to, uint256 amount);
    event TimelockChanged(address indexed oldTimelock, address indexed newTimelock);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event TriggerThresholdSet(uint256 triggerThresholdBps);
    event TeeSignerSet(address indexed oldSigner, address indexed newSigner);

    // ─────────────────────────── Modifiers ─────────────────────

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert UnauthorizedTimelock(msg.sender);
        _;
    }

    modifier onlyAdminOrTimelock() {
        if (msg.sender != admin && msg.sender != timelock) revert UnauthorizedAdmin(msg.sender);
        _;
    }

    // ─────────────────────────── Constructor ─────────────────────

    /// @notice Deploy the (non-upgradeable) insurance product. To replace it,
    ///         deploy a fresh DefiInsurance and re-point CoverPool's payout-module
    ///         registry — done only while no incident is in flight, since the old
    ///         contract still custodies escrow and any open claims.
    /// @param _coverPool  CoverPool capital base (non-zero). This contract must be
    ///                    registered as a payout module on it (setPayoutModule).
    /// @param _timelock   Slow governance role. Its minDelay MUST be comfortably
    ///                    under {DISPUTE_PERIOD} so it can {voidSettlement} a bad
    ///                    root in time.
    /// @param _admin      Fast operational role.
    constructor(ICoverPool _coverPool, address _timelock, address _admin) EIP712("DefiInsurance", "1") {
        if (address(_coverPool) == address(0) || _timelock == address(0) || _admin == address(0)) revert ZeroAddress();
        coverPool = _coverPool;
        timelock = _timelock;
        admin = _admin;
        nextIncidentId = 1;
        nextClaimId = 1;
        triggerThresholdBps = 8_000; // ≥20% drop from peak opens permissionlessly
    }

    // ═══════════════════════════ Insured token management (timelock) ═══════════════════════════

    /// @notice Approve a new insured token and set the economic config settlement
    ///         consumes. Timelock only. Must not be USD8 or a pool stake asset,
    ///         nor already listed.
    /// @param insuredToken         Token to insure.
    /// @param _maxCoverageBps         κ in (0, 100%] (bps); the timelock picks it.
    /// @param underlyingPriceOracle          underlying→USD oracle (non-zero). Not the insured token. e.g. insure token is sGHO, underlying is GHO, underlyingPriceOracle is for GHO.
    /// @param adapter              {IInsuredTokenAdapter} for the token (0 = identity).
    function addInsuredToken(
        IERC20 insuredToken,
        uint256 _maxCoverageBps,
        address underlyingPriceOracle,
        IInsuredTokenAdapter adapter
    ) external onlyTimelock {
        if (address(insuredToken) == address(0) || underlyingPriceOracle == address(0)) revert ZeroAddress();
        if (insuredToken == coverPool.usd8()) revert TokenConflict();
        if (coverPool.isCoverPoolAsset(insuredToken)) revert TokenConflict();
        if (insuredTokens[insuredToken].maxCoverageBps != 0) revert InsuredTokenAlreadyApproved(insuredToken);
        if (_maxCoverageBps == 0 || _maxCoverageBps > BPS_DENOMINATOR) revert InvalidMaxCoverageBps(_maxCoverageBps, BPS_DENOMINATOR);
        _validateAdapter(adapter);

        insuredTokens[insuredToken] = InsuredToken({
            maxCoverageBps: _maxCoverageBps,
            underlyingPriceOracle: underlyingPriceOracle,
            adapter: adapter
        });
        insuredTokenList.push(insuredToken);
        emit InsuredTokenAdded(insuredToken);
        emit MaxCoverageBpsSet(insuredToken, _maxCoverageBps);
        emit UnderlyingPriceOracleSet(insuredToken, underlyingPriceOracle);
        emit AdapterSet(insuredToken, address(adapter));
    }

    /// @notice Update an insured token's coverage factor κ. Timelock only.
    /// @param insuredToken  Listed insured token to update.
    /// @param _maxCoverageBps  New κ in (0, 100%] (bps).
    function setMaxCoverageBps(IERC20 insuredToken, uint256 _maxCoverageBps) external onlyTimelock {
        if (insuredTokens[insuredToken].maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
        if (_maxCoverageBps == 0 || _maxCoverageBps > BPS_DENOMINATOR) revert InvalidMaxCoverageBps(_maxCoverageBps, BPS_DENOMINATOR);
        insuredTokens[insuredToken].maxCoverageBps = _maxCoverageBps;
        emit MaxCoverageBpsSet(insuredToken, _maxCoverageBps);
    }

    /// @notice Repoint an insured token's {IInsuredTokenAdapter}. Timelock
    ///         only. 0 = identity (the token IS the underlying, ratio 1:1, no
    ///         auto-trigger). A new adapter starts with its own fresh trigger
    ///         reference, so any pre-existing drop must be opened via the
    ///         admin path before repointing. Deploy one instance per token:
    ///         e.g. {ERC4626RateAdapter} for 4626 yield vaults; new token
    ///         kinds (LSTs, AMM LPs, …) get their own adapter class encoding
    ///         both how to VALUE the token (valuationRate, read historically
    ///         by the settler) and whether/how it can auto-TRIGGER
    ///         (triggerState — only classes whose metric drops solely on
    ///         genuine loss may provide one).
    /// @param insuredToken  Listed insured token to update.
    /// @param adapter       New adapter (0 = identity).
    function setAdapter(IERC20 insuredToken, IInsuredTokenAdapter adapter) external onlyTimelock {
        InsuredToken storage t = insuredTokens[insuredToken];
        if (t.maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
        _validateAdapter(adapter);
        t.adapter = adapter;
        emit AdapterSet(insuredToken, address(adapter));
    }

    /// @notice Update the global depeg-trigger threshold (all insured tokens).
    ///         Timelock only. See {triggerThresholdBps}; 0 disables the
    ///         permissionless open path entirely.
    /// @param bps  New threshold in bps, < 10_000; 0 disables.
    function setTriggerThresholdBps(uint256 bps) external onlyTimelock {
        if (bps >= BPS_DENOMINATOR) revert InvalidTriggerThresholdBps(bps);
        triggerThresholdBps = bps;
        emit TriggerThresholdSet(bps);
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

    /// @notice Remove an approved insured token. Timelock only. Allowed even if a
    ///         prior incident is unresolved — existing claims continue.
    /// @param insuredToken  Approved insured token to delist.
    function removeInsuredToken(IERC20 insuredToken) external onlyTimelock {
        if (insuredTokens[insuredToken].maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
        _delistInsuredToken(insuredToken);
    }

    /// @notice Set the global settlement windows (blocks). Timelock only; frozen
    ///         while an incident is active. Takes effect for future incidents.
    /// @param p  New settlement windows. See {SettlementParams}.
    function setSettlementParams(SettlementParams calldata p) external onlyTimelock {
        if (_hasActiveIncident()) revert IncidentsActive();
        // sampleStepBlocks is the TWAP loop stride off-chain; 0 would never advance.
        if (p.sampleStepBlocks == 0) revert InvalidSettlementParams();
        settlementParams = p;
        emit SettlementParamsSet(p);
    }

    /// @notice Sweep the entire non-accountable insured-token balance (forfeited
    ///         revenue or strays) to a recipient. Admin or timelock. Live claim escrow
    ///         ({escrowedInsuredTokens}) is always protected.
    /// @param token   Insured (or stray) token to sweep.
    /// @param to      Recipient (non-zero).
    function sweepInsuredToken(IERC20 token, address to) external onlyAdminOrTimelock nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 accountable = escrowedInsuredTokens[token];
        uint256 bal = token.balanceOf(address(this));
        uint256 stray = bal > accountable ? bal - accountable : 0;
        if (stray == 0) revert NothingToSweep(token);
        token.safeTransfer(to, stray);
        emit Swept(token, to, stray);
    }

    // ═══════════════════════════ Incident + claim lifecycle ═══════════════════════════

    /// @notice Open an incident on insuredToken. Admin/timelock fallback path
    ///         for covered events the internal rate can't show (e.g. a
    ///         compromised vault lying about its rate) or unarmed tokens.
    ///         Locks the pool, snapshots the full settlement config, and
    ///         delists the token.
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

    /// @notice Open an incident permissionlessly: allowed for anyone when the
    ///         insured token's internal rate has dropped below the global
    ///         {triggerThresholdBps} of its high-water mark — the vault's own
    ///         accounting says assets left, no human judgment involved. The
    ///         mark's block becomes {Incident.referenceBlock} (the last
    ///         known-good valuation point). Reverts if the mark was set this
    ///         very block (a reference block must be strictly in the past —
    ///         retry next block).
    /// @param  insuredToken  Armed insured token that depegged.
    /// @return incidentId    The newly opened incident id.
    function openTriggeredIncident(IERC20 insuredToken) external returns (uint256 incidentId) {
        InsuredToken storage t = insuredTokens[insuredToken];
        if (t.maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
        uint256 bps = triggerThresholdBps;
        if (bps == 0 || address(t.adapter) == address(0)) revert TriggerNotArmed(insuredToken);
        (uint256 current, uint256 referenceRate, uint64 referenceBlock) = t.adapter.triggerState();
        if (referenceRate == 0) revert TriggerNotArmed(insuredToken); // adapter class has no auto-trigger
        uint256 ceiling = (referenceRate * bps) / BPS_DENOMINATOR;
        if (current >= ceiling) revert TriggerNotMet(current, ceiling);
        return _openIncident(insuredToken, referenceBlock);
    }

    /// @dev Shared open path: validates, locks the pool, snapshots config,
    ///      delists the token.
    function _openIncident(IERC20 insuredToken, uint64 referenceBlock) internal returns (uint256 incidentId) {
        InsuredToken memory it = insuredTokens[insuredToken];
        if (it.maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
        if (referenceBlock == 0 || referenceBlock >= block.number) revert InvalidReferenceBlock(referenceBlock);
        if (_hasActiveIncident()) revert IncidentsActive();

        // Claim the pool BEFORE recording the new incident, so the pool's
        // exclusivity check sees our prior (now-inactive) state, not the
        // incident we're about to open. Reverts if another module is still live.
        coverPool.lockPool();

        incidentId = nextIncidentId;
        nextIncidentId = incidentId + 1;
        uint64 wEnd = uint64(block.timestamp) + CLAIM_WINDOW;
        incidents[incidentId] = Incident({
            insuredToken: insuredToken,
            windowEndTime: wEnd,
            root: bytes32(0),
            inputHash: bytes32(0),
            claimCount: 0,
            resolvedCount: 0,
            rootSubmittedAt: 0,
            referenceBlock: referenceBlock
        });
        activeIncidentId = incidentId;

        // Freeze the full settlement config so the incident is reconstructible
        // from its own snapshot regardless of any later retune. Scored tokens
        // come from the pool (the shared score base).
        IncidentConfig storage ic = incidentConfig[incidentId];
        ic.maxCoverageBps = it.maxCoverageBps;
        ic.underlyingPriceOracle = it.underlyingPriceOracle;
        ic.adapter = it.adapter;
        ic.params = settlementParams;
        ICoverPool.ScoredToken[] memory st = coverPool.getScoredTokens();
        for (uint256 i = 0; i < st.length; i++) {
            ic.scoredTokens.push(st[i]);
        }

        _delistInsuredToken(insuredToken);
        emit IncidentOpened(incidentId, insuredToken, wEnd);
    }

    /// @notice File a claim into the in-flight incident: pure escrow. Reverts if
    ///         no incident on the token is currently accepting claims. Escrows the
    ///         insured token (and any booster units) and chains the claimant-table
    ///         commitment ({Incident.inputHash}).
    /// @param insuredToken        Token whose open incident to join.
    /// @param insuredTokenAmount  Escrow for this claim.
    /// @param scoreToSpend        Insurance score the claimant requests to spend
    ///                            (capped off-chain to their available).
    /// @param boosterAmount       Units of the canonical booster ({BOOSTER_ID}) to
    ///                            commit (0 = none). Each unit boosts the score.
    /// @return claimId The newly minted claim id.
    function joinClaim(
        IERC20 insuredToken,
        uint128 insuredTokenAmount,
        uint256 scoreToSpend,
        uint256 boosterAmount
    ) external nonReentrant returns (uint256 claimId) {
        if (insuredTokenAmount == 0) revert ZeroAmount();

        uint256 incidentId = activeIncidentId;
        bool sameToken = incidentId != 0 && incidents[incidentId].insuredToken == insuredToken;
        if (!sameToken || block.timestamp > incidents[incidentId].windowEndTime) {
            if (sameToken) revert ClaimWindowClosed(insuredToken, incidents[incidentId].windowEndTime);
            revert NoOpenIncident(insuredToken);
        }
        // One live claim per account per incident: stops a user splitting one
        // insurance-score budget across many claims to inflate their payout share.
        if (hasActiveClaim[incidentId][msg.sender]) revert DuplicateClaim(incidentId);
        hasActiveClaim[incidentId][msg.sender] = true;

        uint128 escrow = uint128(_pullToken(insuredToken, msg.sender, insuredTokenAmount));
        if (escrow == 0) revert ZeroAmount();
        escrowedInsuredTokens[insuredToken] += escrow;

        claimId = nextClaimId++;
        claims[claimId] = Claim({
            user: msg.sender,
            incidentId: incidentId,
            insuredTokenAmount: escrow,
            finalized: false,
            closed: false,
            boosterCollection: address(0)
        });

        if (boosterAmount != 0) {
            address booster = coverPool.boosterNFT();
            if (booster == address(0)) revert BoosterNFTUnset();
            IERC1155Burnable(booster).safeTransferFrom(msg.sender, address(this), BOOSTER_ID, boosterAmount, "");
            _claimBoosterAmount[claimId] = boosterAmount;
            claims[claimId].boosterCollection = booster; // snapshot for burn/return
        }

        Incident storage incRef = incidents[incidentId];
        incRef.claimCount += 1;
        incRef.inputHash =
            keccak256(abi.encode(incRef.inputHash, claimId, msg.sender, escrow, scoreToSpend, boosterAmount));

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

    /// @notice Cancel a claim while its window is still open. Returns the escrow.
    /// @param claimId  Caller's claim to cancel (window must still be open).
    function cancelClaim(uint256 claimId) external nonReentrant {
        Claim storage c = claims[claimId];
        if (c.user != msg.sender) revert UnauthorizedClaim(claimId);
        if (c.finalized || c.closed) revert ClaimAlreadyResolved(claimId);

        Incident storage inc = incidents[c.incidentId];
        if (block.timestamp > inc.windowEndTime) revert ClaimWindowClosed(inc.insuredToken, inc.windowEndTime);

        c.closed = true;
        inc.resolvedCount += 1;
        hasActiveClaim[c.incidentId][msg.sender] = false; // may re-file within the window
        inc.inputHash = keccak256(abi.encode(inc.inputHash, claimId, "CANCEL"));
        escrowedInsuredTokens[inc.insuredToken] -= c.insuredTokenAmount;
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);
        _returnBoosters(claimId, msg.sender);

        emit ClaimCancelled(claimId, msg.sender);
    }

    // ═══════════════════════════ Settlement (TEE-signed root, admin fallback) ═══════════════════════════

    /// @notice Submit the settlement root for the in-flight incident. Admin/
    ///         timelock fallback (e.g. the enclave is down and the
    ///         {SUBMIT_DEADLINE} would void the incident), in (windowEnd,
    ///         windowEnd + SUBMIT_DEADLINE]. The dispute window is a fixed
    ///         {DISPUTE_PERIOD} from this moment.
    /// @param incidentId  In-flight incident to settle.
    /// @param root        Merkle root of the settlement table.
    function settleIncident(uint256 incidentId, bytes32 root) external onlyAdminOrTimelock {
        _submitRoot(incidentId, root);
    }

    /// @notice Submit the settlement root permissionlessly, carrying the TEE's
    ///         EIP-712 signature. The enclave — running the published
    ///         settlement code — signs Settlement(incidentId, root, inputHash,
    ///         claimCount); binding the incident's on-chain claimant-table
    ///         commitment means the signature is only valid for the exact
    ///         claim set it scored. Anyone may relay the signed root; the
    ///         optimistic dispute window and {voidSettlement} still apply
    ///         unchanged.
    /// @param incidentId  In-flight incident to settle.
    /// @param root        Merkle root of the settlement table.
    /// @param signature   {teeSigner}'s EIP-712 signature over the Settlement
    ///                    struct (domain: name "DefiInsurance", version "1",
    ///                    this chain id, this contract).
    function settleIncidentSigned(uint256 incidentId, bytes32 root, bytes calldata signature) external {
        Incident storage inc = incidents[incidentId];
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(SETTLEMENT_TYPEHASH, incidentId, root, inc.inputHash, inc.claimCount))
        );
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != teeSigner || teeSigner == address(0)) revert UnauthorizedSettlementSigner(recovered);
        _submitRoot(incidentId, root);
    }

    /// @dev Shared root submission: phase checks + write. Callers authorize.
    function _submitRoot(uint256 incidentId, bytes32 root) internal {
        if (root == bytes32(0)) revert NoStandingRoot(incidentId);
        if (incidentId != activeIncidentId) revert NotActiveIncident(incidentId);
        Incident storage inc = incidents[incidentId];
        if (block.timestamp <= inc.windowEndTime || block.timestamp > inc.windowEndTime + SUBMIT_DEADLINE) {
            revert OutsideSettlementPhase(incidentId);
        }
        if (inc.root != bytes32(0)) revert RootAlreadySet(incidentId);

        inc.root = root;
        inc.rootSubmittedAt = uint64(block.timestamp);
        emit IncidentSettled(incidentId, root);
    }

    /// @notice Void a standing settlement root. Admin or timelock — the no-delay,
    ///         deny-only brake. Allowed only before the dispute period ends; a
    ///         corrected root may be resubmitted while the submit deadline holds.
    /// @param incidentId  Incident whose standing root to void.
    function voidSettlement(uint256 incidentId) external onlyAdminOrTimelock {
        Incident storage inc = incidents[incidentId];
        if (inc.root == bytes32(0)) revert NoStandingRoot(incidentId);
        if (block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD) revert OutsideSettlementPhase(incidentId);
        inc.root = bytes32(0);
        inc.rootSubmittedAt = 0;
        emit SettlementVoided(incidentId, msg.sender);
    }

    /// @notice Finalize a claim against the standing root. amounts is the
    ///         claimant's per-asset payout row aligned to the pool's stake-asset
    ///         list (frozen for the incident's life); proof is its merkle path.
    ///         Paid out of the pool via {ICoverPool.payClaim}; escrow forfeits.
    /// @param claimId     Caller's claim to finalize.
    /// @param amounts     Per-asset payout row, aligned to the pool asset list.
    /// @param scoreSpent  Insurance score this claim consumes (off-chain-capped),
    ///                    recorded to the pool's shared ledger.
    /// @param proof       Merkle proof of the leaf against the standing root.
    function finalizeClaim(uint256 claimId, uint256[] calldata amounts, uint256 scoreSpent, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Claim storage c = claims[claimId];
        if (c.user != msg.sender) revert UnauthorizedClaim(claimId);
        if (c.finalized || c.closed) revert ClaimAlreadyResolved(claimId);

        uint256 incidentId = c.incidentId;
        Incident storage inc = incidents[incidentId];
        if (
            inc.root == bytes32(0) || block.timestamp <= inc.rootSubmittedAt + DISPUTE_PERIOD
                || block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD + FINALIZE_WINDOW
        ) {
            revert FinalizeNotOpen(incidentId);
        }

        {
            // Pool stake-asset curation is frozen while the incident is active,
            // so its list still matches the committed settlement order.
            if (amounts.length != coverPool.coverPoolAssetListLength()) revert InvalidProof(claimId);
            bytes32 leaf =
                keccak256(bytes.concat(keccak256(abi.encode(incidentId, claimId, msg.sender, amounts, scoreSpent))));
            if (!MerkleProof.verifyCalldata(proof, inc.root, leaf)) revert InvalidProof(claimId);
        }

        c.finalized = true;
        inc.resolvedCount += 1;

        // Escrow leaves live accounting; forfeited tokens stay here as
        // unaccounted balance, sweepable as protocol revenue.
        escrowedInsuredTokens[inc.insuredToken] -= c.insuredTokenAmount;

        // Burn the committed boosters — consumed on payout. No-op if none.
        // Burn from the collection snapshotted at join, not the pool's current one.
        uint256 boosterAmount = _claimBoosterAmount[claimId];
        if (boosterAmount != 0) {
            IERC1155Burnable(c.boosterCollection).burn(address(this), BOOSTER_ID, boosterAmount);
            delete _claimBoosterAmount[claimId];
        }

        // Pay out of the pool (loss socialization + over-allocation check there) and
        // record the consumed score in the pool's shared ledger — one atomic
        // call, so score is only ever spent as part of a payout.
        coverPool.payClaim(msg.sender, amounts, scoreSpent);

        emit ClaimFinalized(claimId, msg.sender);
    }

    /// @dev Return a claim's committed boosters to to (cancel/withdraw), from
    ///      the collection snapshotted at join — not the pool's current one.
    function _returnBoosters(uint256 claimId, address to) internal {
        uint256 amount = _claimBoosterAmount[claimId];
        if (amount == 0) return;
        IERC1155Burnable(claims[claimId].boosterCollection).safeTransferFrom(
            address(this), to, BOOSTER_ID, amount, ""
        );
        delete _claimBoosterAmount[claimId];
    }

    /// @notice Recover the escrow of a claim that will never finalize: its
    ///         incident is void (no root by the deadline) or its finalize window
    ///         expired unused. Callable anytime after, forever.
    /// @param claimId  Caller's claim whose escrow to recover.
    function withdrawNonFinalizedClaim(uint256 claimId) external nonReentrant {
        Claim storage c = claims[claimId];
        if (c.user != msg.sender) revert UnauthorizedClaim(claimId);
        if (c.finalized || c.closed) revert ClaimAlreadyResolved(claimId);

        Incident storage inc = incidents[c.incidentId];
        bool incidentVoid = inc.root == bytes32(0) && block.timestamp > inc.windowEndTime + SUBMIT_DEADLINE;
        bool finalizeExpired =
            inc.root != bytes32(0) && block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD + FINALIZE_WINDOW;
        if (!incidentVoid && !finalizeExpired) revert ClaimNotWithdrawable(claimId);

        c.closed = true;
        inc.resolvedCount += 1;
        escrowedInsuredTokens[inc.insuredToken] -= c.insuredTokenAmount;
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);
        _returnBoosters(claimId, msg.sender);

        emit ClaimWithdrawn(claimId, msg.sender);
    }

    // ═══════════════════════════ Role management ═══════════════════════════

    /// @notice Transfer timelock authority. Current timelock only.
    /// @param newTimelock  New timelock address (non-zero).
    function setTimelock(address newTimelock) external onlyTimelock {
        if (newTimelock == address(0)) revert ZeroAddress();
        emit TimelockChanged(timelock, newTimelock);
        timelock = newTimelock;
    }

    /// @notice Set the fast operational admin. Timelock only.
    /// @param newAdmin  New admin address (non-zero).
    function setAdmin(address newAdmin) external onlyTimelock {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Rotate the TEE settlement signer. Timelock only — every enclave
    ///         code upgrade generates a fresh in-enclave key, so rotation is a
    ///         publicly visible, timelock-delayed event whose delay is the
    ///         community's window to reproduce the new build's published
    ///         measurement. Zero disables {settleIncidentSigned} (fallback
    ///         {settleIncident} remains).
    /// @param newSigner  The new enclave key's address (zero to disable).
    function setTeeSigner(address newSigner) external onlyTimelock {
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

    /// @notice The settlement config snapshotted for incidentId at open.
    /// @param incidentId  Incident to query.
    function getIncidentConfig(uint256 incidentId) external view returns (IncidentConfig memory) {
        return incidentConfig[incidentId];
    }

    /// @notice Units of {BOOSTER_ID} currently escrowed by a claim (0 if none).
    /// @param claimId  Claim to query.
    function getClaimBoosterAmount(uint256 claimId) external view returns (uint256) {
        return _claimBoosterAmount[claimId];
    }

    // ═══════════════════════════ Internal: incident lifecycle ═══════════════════════════

    /// @dev True while the in-flight incident is unresolved.
    function _hasActiveIncident() internal view returns (bool) {
        return activeIncidentId != 0 && _incidentActive(activeIncidentId);
    }

    /// @dev An incident is active until its phase machine terminates (see the
    ///      CoverPool v1 history for the full rationale).
    function _incidentActive(uint256 incidentId) internal view returns (bool) {
        Incident storage inc = incidents[incidentId];
        if (block.timestamp <= inc.windowEndTime) return true;
        if (inc.resolvedCount >= inc.claimCount) return false;
        if (inc.root == bytes32(0)) return block.timestamp <= inc.windowEndTime + SUBMIT_DEADLINE;
        return block.timestamp <= inc.rootSubmittedAt + DISPUTE_PERIOD + FINALIZE_WINDOW;
    }

    /// @dev Sanity-check a non-identity adapter at listing/repoint time so a
    ///      misconfigured one fails here, not mid-incident: it must report a
    ///      live valuation rate and answer triggerState().
    function _validateAdapter(IInsuredTokenAdapter adapter) internal view {
        if (address(adapter) == address(0)) return; // identity
        if (adapter.valuationRate() == 0) revert InvalidAdapter(address(adapter));
        adapter.triggerState();
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
