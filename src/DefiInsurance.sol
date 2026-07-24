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
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Registry} from "./Registry.sol";
import {SharedBase} from "./SharedBase.sol";

/// @notice Booster interface used for ERC-1155 transfers and holder-authorized burns.
interface IERC1155Burnable is IERC1155 {
    /// @notice Burn booster units from an authorized account.
    function burn(address account, uint256 id, uint256 value) external;
}

/// @notice Cover-pool interface used to reserve exits, cap loss, and pay claims.
interface ISingleAssetCoverPool {
    /// @notice Pay a finalized claim from pool capital.
    function payClaim(address to, uint256 amount) external;

    /// @notice Current pool assets backing underwriting.
    function totalAssets() external view returns (uint256);

    /// @notice Maximum loss this pool accepts for one incident.
    function maxPayoutPerIncident() external view returns (uint256);

    /// @notice Settle at most `maxEpochs` matured exit batches.
    function settleMaturedExitEpochs(uint256 maxEpochs) external returns (uint256);
}

/// @title  DefiInsurance v1
/// @notice Depeg insurance backed by registered cover pools. A first TEE-attested
///         {joinClaim}, or an admin fallback, opens the single active incident and
///         freezes pending exit settlement and topology changes. Claims may join or cancel
///         during {CLAIM_WINDOW}; anyone may relay one TEE-signed settlement root by
///         {SUBMIT_DEADLINE}. During beta, governance may correct or void the root during
///         {DISPUTE_PERIOD}; claimants then pull Merkle-proven payouts during
///         {FINALIZE_WINDOW}. Missing and expired roots void automatically.
/// @dev UUPS-upgradeable during Registry beta mode only. Once beta ends, upgrades
///      are permanently disabled. Registry replacement is safe only between incidents. This
///      contract escrows insured tokens and committed boosters. Boosters burn on
///      finalization or return on cancellation/withdrawal. Consumed score is emitted
///      and mirrored on the {Registry}.
contract DefiInsurance is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
    EIP712Upgradeable,
    ERC1155Holder,
    SharedBase
{
    using SafeERC20 for IERC20;

    // ─────────────────────────── State ───────────────────────────

    /// @notice Timelock-managed 1-of-N TEE signers for incident opens and settlements.
    ///         Any compromised signer can attest a false open or root; phase timing,
    ///         pool caps, and beta correction bound that trust assumption.
    mapping(address signer => bool) public isTeeSigner;

    // ─────────────────────────── State (insured tokens) ───────────────────────────

    /// @notice Basis-point denominator (100%) and the hard ceiling for a token's
    ///         coverage factor κ ({InsuredToken.maxCoverageBps}): κ ∈ (0, 100%].
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Per-token coverage and historical valuation recipe; zero coverage means unlisted.
    /// @dev Coverage applies only to direct impairment versus the configured immediate
    ///      underlying. The TEE/admin determines incident eligibility; this recipe only
    ///      values an accepted incident. Finalization buys out the eligible tokens.
    /// @param maxCoverageBps Buyout cap κ in bps, applied off-chain to pre-incident value.
    /// @param underlyingPriceOracle Market-price oracle from underlying to USD.
    /// @param underlyingConversionAddress Historical token-to-underlying rate source;
    ///        zero means identity. Off-chain settlement expects a WAD-scaled uint256.
    /// @param underlyingConversionCallData Calldata for the conversion staticcall.
    /// @param minClaimAmount Minimum escrow in insured-token base units.
    struct InsuredToken {
        uint256 maxCoverageBps;
        address underlyingPriceOracle;
        address underlyingConversionAddress;
        bytes underlyingConversionCallData;
        uint128 minClaimAmount;
    }

    /// @notice Token config; zero coverage means unlisted. Confirmed incidents delist it.
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
    ///         before it elapses; during beta, admin/timelock may correct or void the root.
    uint64 public constant DISPUTE_PERIOD = 2 days;

    /// @notice Length of the FINALIZE phase, after DISPUTE ends. Total CoverPool lock is
    ///         CLAIM_WINDOW + [0, SUBMIT_DEADLINE] + DISPUTE_PERIOD + FINALIZE_WINDOW =
    ///         11–14 days (8 days if the claim voids in SETTLE).
    uint64 public constant FINALIZE_WINDOW = 4 days;

    /// @notice Maximum reference-block age at open; about six days at 12-second blocks.
    uint64 public constant MAX_REFERENCE_BLOCK_AGE = 43_200;

    /// @notice State for one insured-token incident.
    /// @param insuredToken Token covered by the incident.
    /// @param claimWindowEndTime Last timestamp for joins and cancellations.
    /// @param root Standing settlement Merkle root, or zero.
    /// @param unresolved Number of live claims; zero resolves the incident.
    /// @param rootSubmittedAt Start of the dispute period.
    /// @param referenceBlock Pre-incident valuation block.
    /// @param openBlock Block used to archive-read settlement configuration.
    /// @param status Open or beta-voided lifecycle state.
    /// @param disputedAt Reserved zero value retained for getter ABI compatibility.
    /// @param claimSetHash Ordered commitment to joins and cancellations.
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

    /// @notice Mutually exclusive incident lifecycle state.
    /// @custom:value Open Running normally.
    /// @custom:value Disputed Reserved legacy value; no function enters this state.
    /// @custom:value Closed Voided by beta correction; escrow is recoverable.
    enum Status {
        Open,
        Disputed,
        Closed
    }

    /// @notice All incidents by id. Id 0 is reserved.
    mapping(uint256 incidentId => Incident) public incidents;

    /// @notice Pool snapshot defining each incident's payout-row order.
    mapping(uint256 incidentId => address[]) internal incidentPools;

    /// @notice Remaining per-pool payout budgets, aligned to {incidentPools}.
    ///         Finalization decrements them, hard-capping cumulative pool loss.
    mapping(uint256 incidentId => uint256[]) internal incidentPoolBudget;

    /// @notice Actual timestamp for incidents resolved by beta void or final claim.
    mapping(uint256 incidentId => uint64) public incidentResolvedAt;

    /// @notice Next incident id to assign. Starts at 1.
    uint256 public nextIncidentId;

    /// @notice Escrow registration for one claimant; economics are computed off-chain.
    /// @param user Claimant.
    /// @param incidentId Incident id.
    /// @param insuredTokenAmount Escrowed insured-token amount.
    /// @param boosterAmount Booster units escrowed when the claim is filed.
    /// @param resolved Whether any resolution path has completed.
    /// @param boosterCollection Booster collection snapshotted at registration.
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

    /// @notice One live claim per account and incident; zero means none.
    mapping(uint256 incidentId => mapping(address account => uint256 claimId)) public activeClaimId;

    /// @notice Live escrow excluded from token sweeping.
    mapping(IERC20 insuredToken => uint256) public escrowedInsuredTokens;

    /// @notice The only booster token id in use. Claims commit units of this id;
    ///         the collection address lives on the pool ({Registry.boosterNFT}).
    uint256 public constant BOOSTER_ID = 1;

    /// @notice Hard-coded booster policy: each escrowed unit of {BOOSTER_ID}
    ///         adds 100 bps (+1%) to the claimant's insurance-score multiplier.
    ///         Applied off-chain and verified on-chain at finalization.
    uint256 public constant BOOSTER_BOOST_BPS = 100;

    // ─────────────────────────── State (settlement config) ───────────────────────────

    /// @notice Off-chain settlement windows, archive-read at {Incident.openBlock}.
    /// @param twapLookbackBlocks Pre-incident token-to-underlying TWAP lookback.
    /// @param holdingMarginBlocks Window used to prove minimum pre-incident holdings.
    /// @param sampleStepBlocks TWAP sampling stride; eligibility replay is exact.
    struct SettlementParams {
        uint64 twapLookbackBlocks;
        uint64 holdingMarginBlocks;
        uint64 sampleStepBlocks;
    }

    /// @notice Global settlement windows (in blocks). Read off-chain as of each
    ///         incident's {Incident.openBlock}; changes apply to later incidents.
    SettlementParams public settlementParams;

    /// @notice Timelock-approved TEE PCR commitment snapshotted at incident open.
    mapping(uint256 incidentId => bytes32 pcrHash) public incidentTeePcrHash;

    /// @notice EIP-712 settlement schema binds the active incident, root, exact claim set,
    ///         ordered pools, per-pool budgets, and approved TEE PCR.
    bytes32 internal constant SETTLEMENT_TYPEHASH = keccak256(
        "Settlement(uint256 incidentId,bytes32 root,uint256 unresolved,uint256[] poolPayouts,bytes32 pools,bytes32 claimSet,bytes32 teePcrHash)"
    );

    /// @notice EIP-712 open schema binds token, reference block, single-use incident id, and PCR.
    bytes32 internal constant OPEN_TYPEHASH =
        keccak256("IncidentOpen(address insuredToken,uint64 referenceBlock,uint256 incidentId,bytes32 teePcrHash)");

    // ─────────────────────────── Errors ──────────────────────────

    /// @notice A required token or payout amount is zero.
    error ZeroAmount();

    /// @notice Received claim escrow is below the token's configured minimum.
    error ClaimBelowMinimum(IERC20 insuredToken, uint256 received, uint256 minimum);

    /// @notice The configured minimum claim amount is zero.
    error InvalidMinClaimAmount(uint256 given);

    /// @notice The coverage factor is zero or exceeds the basis-point denominator.
    error InvalidMaxCoverageBps(uint256 given, uint256 max);

    /// @notice The reference block is zero, future, or older than the permitted age.
    error InvalidReferenceBlock(uint64 referenceBlock);

    /// @notice A token cannot be both insured and used as a cover-pool asset.
    error TokenConflict();

    /// @notice The insured token is already listed.
    error InsuredTokenAlreadyApproved(IERC20 insuredToken);

    /// @notice The insured token is not listed.
    error InsuredTokenNotApproved(IERC20 insuredToken);

    /// @notice Claims can no longer join or cancel for this token.
    error ClaimWindowClosed(IERC20 insuredToken, uint64 claimWindowEndTime);

    /// @notice No booster collection is configured.
    error BoosterNFTUnset();

    /// @notice The caller does not own the referenced claim.
    error UnauthorizedClaim(uint256 claimId);

    /// @notice The claim already completed a resolution path.
    error ClaimAlreadyResolved(uint256 claimId);

    /// @notice The caller already has a live claim on this incident.
    error DuplicateClaim(uint256 incidentId);

    /// @notice The caller has no live claim on the active incident.
    error NoActiveClaim();

    /// @notice The referenced incident is not currently active.
    error NotActiveIncident(uint256 incidentId);

    /// @notice Finalization has opened, so governance can no longer intervene.
    error IncidentFinalizing(uint256 incidentId);

    /// @notice The incident is not in the Open lifecycle state.
    error IncidentNotOpen(uint256 incidentId);

    /// @notice A settlement was submitted outside its allowed phase.
    error OutsideSettlementPhase(uint256 incidentId);

    /// @notice The incident has no usable settlement root.
    error NoStandingRoot(uint256 incidentId);

    /// @notice The incident already has its one permitted TEE settlement.
    error AlreadySettled(uint256 incidentId);

    /// @notice The incident is outside its claim-finalization phase.
    error FinalizeNotOpen(uint256 incidentId);

    /// @notice The payout row or Merkle proof does not match the standing root.
    error InvalidProof(uint256 claimId);

    /// @notice Signed eligible escrow exceeds the amount actually escrowed.
    error EligibleExceedsEscrow(uint256 eligibleAmount, uint256 escrow);

    /// @notice Merkle row's boosted score does not match its raw score and escrowed booster units.
    error InvalidBoostedScore(uint256 provided, uint256 expected);

    /// @notice The claim still has a possible payout path and cannot be withdrawn.
    error ClaimNotWithdrawable(uint256 claimId);

    /// @notice Settlement-critical configuration cannot change during an incident.
    error IncidentsActive();

    /// @notice Settlement sampling parameters are invalid.
    error InvalidSettlementParams();

    /// @notice A later claimant supplied first-claim open-attestation data.
    error UnexpectedOpenAttestation();

    /// @notice The recovered incident-open signer is unauthorized.
    error UnauthorizedOpenSigner(address recovered);

    /// @notice The recovered settlement signer is unauthorized.
    error UnauthorizedSettlementSigner(address recovered);

    /// @notice The booster commitment cannot fit in claim storage.
    error BoosterAmountTooLarge(uint256 boosterAmount);

    /// @notice The payout row length differs from the incident pool snapshot.
    error SettlementPoolMismatch(uint256 given, uint256 expected);

    /// @notice A payout exceeds the pool's committed incident budget.
    error PayoutCapExceeded(uint256 poolIndex, uint256 requested, uint256 cap);

    /// @notice This contract is not the Registry's active insurance module.
    error DefiInsuranceNotRegistered();

    // ─────────────────────────── Events ──────────────────────────

    /// @notice Emitted when governance lists an insured token.
    event InsuredTokenAdded(IERC20 indexed insuredToken);

    /// @notice Emitted when a token's coverage factor changes.
    event MaxCoverageBpsSet(IERC20 indexed insuredToken, uint256 maxCoverageBps);

    /// @notice Emitted when a token's minimum claim escrow changes.
    event MinClaimAmountSet(IERC20 indexed insuredToken, uint128 minClaimAmount);

    /// @notice Emitted when a token's historical conversion recipe changes.
    event UnderlyingConversionSet(IERC20 indexed insuredToken, address conversionAddress, bytes conversionCallData);

    /// @notice Emitted when a token's underlying price oracle changes.
    event UnderlyingPriceOracleSet(IERC20 indexed insuredToken, address underlyingPriceOracle);

    /// @notice Emitted when governance delists an insured token.
    event InsuredTokenRemoved(IERC20 indexed insuredToken);

    /// @notice Emitted when global settlement windows change.
    event SettlementParamsSet(SettlementParams params);

    /// @notice Emitted when the sole active incident opens.
    event IncidentOpened(uint256 indexed incidentId, IERC20 indexed insuredToken, uint64 claimWindowEndTime);

    /// @notice Emitted when a TEE-signed settlement root is committed.
    event IncidentSettled(uint256 indexed incidentId, bytes32 root, bytes32 teePcrHash);

    /// @notice Emitted when beta governance corrects a root; zero means voided.
    event IncidentCorrected(uint256 indexed incidentId, bytes32 root);

    /// @notice Emitted when a claimant escrows tokens and joins an incident.
    event ClaimRegistered(
        uint256 indexed claimId,
        uint256 indexed incidentId,
        address indexed user,
        uint128 insuredTokenAmount,
        uint256 scoreToSpend,
        uint256 boosterAmount
    );

    /// @notice Emitted when a claim successfully finalizes its payout.
    event ClaimFinalized(uint256 indexed claimId, address indexed user);

    /// @notice Emitted when a claimant cancels during the claim window.
    event ClaimCancelled(uint256 indexed claimId, address indexed user);

    /// @notice Emitted when an unresolved claim recovers escrow after payout becomes impossible.
    event ClaimWithdrawn(uint256 indexed claimId, address indexed user);

    /// @notice Emitted when timelock changes a TEE signer's authorization.
    event TeeSignerSet(address indexed signer, bool authorized);

    /// @notice Emitted on {finalizeClaim} for the insurance score a claim consumed.
    ///         The incident-tagged log the settler sums per user (pinned before an
    ///         incident's openBlock) for the available budget; the cumulative total is
    ///         also mirrored on-chain via {Registry.recordScoreSpent}.
    event ScoreSpent(address indexed user, uint256 amount, uint256 indexed incidentId);

    // ─────────────────────────── Initialization ─────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the payout-module proxy. Callable once.
    /// @param _registry Shared access and topology registry; its timelock delay must
    ///        leave enough of {DISPUTE_PERIOD} to intervene on a bad root.
    function initialize(Registry _registry) external initializer {
        __EIP712_init("DefiInsurance", "1");
        _setRegistry(_registry);
        nextIncidentId = 1;
        nextClaimId = 1;
        // Nonzero defaults keep settlement live before governance tunes the policy.
        settlementParams = SettlementParams({
            twapLookbackBlocks: 50_400, // ~7d TWAP window before referenceBlock (anti-manipulation over recency)
            holdingMarginBlocks: 50_400, // ~7d required pre-incident holding for eligibility before refBlock
            sampleStepBlocks: 300 // ~1h TWAP sample stride (≈168 samples over a 7d window)
        });
    }

    /// @dev Timelock-only during beta and blocked while an incident is active;
    ///      Registry.endBetaMode disables this forever.
    function _authorizeUpgrade(address) internal view override onlyTimelock onlyBetaMode notDuringIncident {}

    /// @dev Freezes settlement-critical configuration from incident open through resolution.
    modifier notDuringIncident() {
        if (_activeIncidentId() != 0) revert IncidentsActive();
        _;
    }

    /// @dev The token must be a listed insured token (maxCoverageBps != 0).
    modifier onlyInsuredToken(IERC20 token) {
        if (insuredTokens[token].maxCoverageBps == 0) revert InsuredTokenNotApproved(token);
        _;
    }

    // ─────────────────────────── Insured token management (timelock) ───────────────────────────

    /// @notice List an insured token and its settlement recipe. Timelock only.
    /// @dev Generic history replay requires non-rebasing ERC-20s whose balance changes
    ///      emit canonical `Transfer` events; other semantics need a reviewed adapter.
    /// @param insuredToken Token to insure; must not be a pool asset.
    /// @param _maxCoverageBps Buyout cap κ in bps.
    /// @param _minClaimAmount Minimum nonzero escrow in token base units.
    /// @param underlyingPriceOracle Underlying-to-USD oracle.
    /// @param conversionAddress Token-to-underlying staticcall target; zero is identity.
    /// @param conversionCallData Calldata for the conversion staticcall.
    function addInsuredToken(
        IERC20 insuredToken,
        uint256 _maxCoverageBps,
        uint128 _minClaimAmount,
        address underlyingPriceOracle,
        address conversionAddress,
        bytes calldata conversionCallData
    ) external onlyTimelock {
        if (address(insuredToken) == address(0) || underlyingPriceOracle == address(0)) {
            revert ZeroAddress();
        }
        if (registry().coverPool(insuredToken) != address(0)) revert TokenConflict();
        if (insuredTokens[insuredToken].maxCoverageBps != 0) revert InsuredTokenAlreadyApproved(insuredToken);
        if (_maxCoverageBps == 0 || _maxCoverageBps > BPS_DENOMINATOR) {
            revert InvalidMaxCoverageBps(_maxCoverageBps, BPS_DENOMINATOR);
        }
        if (_minClaimAmount == 0) revert InvalidMinClaimAmount(_minClaimAmount);
        insuredTokens[insuredToken] = InsuredToken({
            maxCoverageBps: _maxCoverageBps,
            underlyingPriceOracle: underlyingPriceOracle,
            underlyingConversionAddress: conversionAddress,
            underlyingConversionCallData: conversionCallData,
            minClaimAmount: _minClaimAmount
        });
        insuredTokenList.push(insuredToken);
        emit InsuredTokenAdded(insuredToken);
        emit MaxCoverageBpsSet(insuredToken, _maxCoverageBps);
        emit MinClaimAmountSet(insuredToken, _minClaimAmount);
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
        onlyInsuredToken(insuredToken)
    {
        if (_maxCoverageBps == 0 || _maxCoverageBps > BPS_DENOMINATOR) {
            revert InvalidMaxCoverageBps(_maxCoverageBps, BPS_DENOMINATOR);
        }
        insuredTokens[insuredToken].maxCoverageBps = _maxCoverageBps;
        emit MaxCoverageBpsSet(insuredToken, _maxCoverageBps);
    }

    /// @notice Update an insured token's minimum claim escrow. Timelock only.
    /// @param insuredToken Listed insured token to update.
    /// @param _minClaimAmount New non-zero minimum, in insured-token base units.
    function setMinClaimAmount(IERC20 insuredToken, uint128 _minClaimAmount)
        external
        onlyTimelock
        notDuringIncident
        onlyInsuredToken(insuredToken)
    {
        if (_minClaimAmount == 0) revert InvalidMinClaimAmount(_minClaimAmount);
        insuredTokens[insuredToken].minClaimAmount = _minClaimAmount;
        emit MinClaimAmountSet(insuredToken, _minClaimAmount);
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
        onlyInsuredToken(insuredToken)
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
        onlyInsuredToken(insuredToken)
    {
        if (underlyingPriceOracle == address(0)) revert ZeroAddress();
        insuredTokens[insuredToken].underlyingPriceOracle = underlyingPriceOracle;
        emit UnderlyingPriceOracleSet(insuredToken, underlyingPriceOracle);
    }

    /// @notice Delist an insured token without moving funds. Admin or timelock.
    /// @param insuredToken  Approved insured token to delist.
    function removeInsuredToken(IERC20 insuredToken)
        external
        onlyAdminOrTimelock
        notDuringIncident
        onlyInsuredToken(insuredToken)
    {
        _delistInsuredToken(insuredToken);
    }

    /// @notice Set archive-read settlement windows between incidents. Timelock only.
    /// @param p  New settlement windows. See {SettlementParams}.
    function setSettlementParams(SettlementParams calldata p) external onlyTimelock notDuringIncident {
        // sampleStepBlocks is the TWAP loop stride off-chain; 0 would never advance.
        if (p.sampleStepBlocks == 0) revert InvalidSettlementParams();
        settlementParams = p;
        emit SettlementParamsSet(p);
    }

    /// @dev Only token balance above live escrow is sweepable; payouts come from pools.
    function _sweepable(address token) internal view override returns (uint256) {
        uint256 accounted = escrowedInsuredTokens[IERC20(token)];
        uint256 bal = IERC20(token).balanceOf(address(this));
        return bal > accounted ? bal - accounted : 0;
    }

    // ─────────────────────────── Claim lifecycle ───────────────────────────

    /// @notice Claim-less admin fallback when the TEE cannot open an incident.
    /// @param insuredToken Covered token.
    /// @param referenceBlock Recent pre-incident valuation block.
    /// @return incidentId Newly opened incident id.
    function openClaimIncident(IERC20 insuredToken, uint64 referenceBlock)
        external
        nonReentrant
        onlyAdminOrTimelock
        returns (uint256 incidentId)
    {
        return _openIncident(insuredToken, referenceBlock);
    }

    /// @dev Opens the sole incident and snapshots its settlement inputs and pool order.
    function _openIncident(IERC20 insuredToken, uint64 referenceBlock)
        internal
        whenNotPaused
        onlyInsuredToken(insuredToken)
        returns (uint256 incidentId)
    {
        // One-at-a-time guard; token listing is enforced by onlyInsuredToken.
        if (_activeIncidentId() != 0) revert IncidentsActive();
        // An unregistered module cannot activate the Registry-driven pool freeze.
        if (registry().defiInsurance() != address(this)) revert DefiInsuranceNotRegistered();

        // The reference block also expires signed open attestations.
        if (
            referenceBlock == 0 || referenceBlock >= block.number
                || block.number - referenceBlock > MAX_REFERENCE_BLOCK_AGE
        ) revert InvalidReferenceBlock(referenceBlock);

        // Matured exits are no longer underwriting capital. Settle them before
        // recording the incident so the frozen balances contain only active capital.
        (, address[] memory poolAddrs) = registry().coverPools();
        for (uint256 i = 0; i < poolAddrs.length;) {
            ISingleAssetCoverPool(poolAddrs[i]).settleMaturedExitEpochs(type(uint256).max);
            unchecked {
                ++i;
            }
        }

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
        incidentTeePcrHash[incidentId] = registry().teePcrHash();

        // Pin payout-row ordering independently of later Registry topology.
        incidentPools[incidentId] = poolAddrs;

        emit IncidentOpened(incidentId, insuredToken, wEnd);
    }

    /// @notice Escrow a claim, opening an incident if none is active. The first claim
    ///         requires a TEE open attestation; later claims must omit it.
    /// @param insuredToken Token being claimed.
    /// @param insuredTokenAmount Requested escrow; received amount must meet the minimum.
    /// @param scoreToSpend Requested score spend; settlement caps it to availability.
    /// @param boosterAmount Booster units transferred into escrow with the claim.
    /// @param referenceBlock Pre-incident block for the first claim; otherwise zero.
    /// @param signature TEE open signature for the first claim; otherwise empty.
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
            // Only an open incident accepts new claims.
            if (cur.status != Status.Open) revert IncidentNotOpen(incidentId);
            // A different token holding the system means one-at-a-time blocks us.
            if (cur.insuredToken != insuredToken) revert IncidentsActive();
            if (block.timestamp > cur.claimWindowEndTime) {
                revert ClaimWindowClosed(insuredToken, cur.claimWindowEndTime);
            }
            // Prevent score-budget multiplication through claim splitting.
            if (activeClaimId[incidentId][msg.sender] != 0) revert DuplicateClaim(incidentId);
        } else {
            // Preserve ECDSA's canonical malformed-signature errors before the
            // open, then verify valid-length signatures against its PCR snapshot.
            if (signature.length != 65) ECDSA.recover(bytes32(0), signature);
            incidentId = _openIncident(insuredToken, referenceBlock);
            bytes32 digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        OPEN_TYPEHASH, address(insuredToken), referenceBlock, incidentId, incidentTeePcrHash[incidentId]
                    )
                )
            );
            address recovered = ECDSA.recover(digest, signature);
            if (!isTeeSigner[recovered]) revert UnauthorizedOpenSigner(recovered);
        }

        uint128 escrow = uint128(_pullToken(insuredToken, msg.sender, insuredTokenAmount));
        if (escrow == 0) revert ZeroAmount();
        uint128 minimum = insuredTokens[insuredToken].minClaimAmount;
        if (escrow < minimum) revert ClaimBelowMinimum(insuredToken, escrow, minimum);
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
            // Keep stored and emitted booster amounts identical.
            if (boosterAmount > type(uint128).max) revert BoosterAmountTooLarge(boosterAmount);
            address booster = registry().boosterNFT();
            if (booster == address(0)) revert BoosterNFTUnset();
            claims[claimId].boosterAmount = uint128(boosterAmount);
            claims[claimId].boosterCollection = booster;
            IERC1155(booster).safeTransferFrom(msg.sender, address(this), BOOSTER_ID, boosterAmount, "");
        }

        Incident storage reg = incidents[incidentId];
        reg.unresolved += 1;
        // Commit the emitted join fields in replay order.
        reg.claimSetHash =
            keccak256(abi.encode(reg.claimSetHash, claimId, msg.sender, escrow, scoreToSpend, boosterAmount));

        emit ClaimRegistered(claimId, incidentId, msg.sender, escrow, scoreToSpend, boosterAmount);
    }

    /// @dev Pull tokens and return the actual balance delta.
    function _pullToken(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Return a claim's escrowed boosters on a non-finalization exit.
    function _returnBoosters(Claim storage c, address recipient) internal {
        uint256 amount = c.boosterAmount;
        if (amount != 0) {
            IERC1155(c.boosterCollection).safeTransferFrom(address(this), recipient, BOOSTER_ID, amount, "");
        }
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
        _returnBoosters(c, msg.sender);
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);

        emit ClaimCancelled(claimId, msg.sender);
    }

    // ─────────────────────────── Settlement (TEE-signed root only) ───────────────────────────

    /// @notice Relay the sole TEE-signed settlement root for the active incident.
    /// @param root Merkle root over claimant payout rows.
    /// @param poolPayouts Per-pool budgets aligned to the open-time pool snapshot.
    /// @param signature EIP-712 signature from an authorized TEE signer.
    function settleIncident(bytes32 root, uint256[] calldata poolPayouts, bytes calldata signature)
        external
        whenNotPaused
    {
        uint256 incidentId = _requireActiveIncident();
        Incident storage inc = incidents[incidentId];

        // Fail on phase errors before signature recovery.
        if (root == bytes32(0)) revert NoStandingRoot(incidentId);
        // A standing root can only be replaced by beta governance.
        if (inc.root != bytes32(0)) revert AlreadySettled(incidentId);
        if (block.timestamp <= inc.claimWindowEndTime || block.timestamp > inc.claimWindowEndTime + SUBMIT_DEADLINE) {
            revert OutsideSettlementPhase(incidentId);
        }

        // Bind the signature to the PCR snapshotted when the incident opened.
        bytes32 teePcrHash = incidentTeePcrHash[incidentId];
        {
            bytes32 structHash = keccak256(
                abi.encode(
                    SETTLEMENT_TYPEHASH,
                    incidentId,
                    root,
                    inc.unresolved,
                    keccak256(abi.encodePacked(poolPayouts)),
                    keccak256(abi.encodePacked(incidentPools[incidentId])),
                    inc.claimSetHash,
                    teePcrHash
                )
            );
            address recovered = ECDSA.recover(_hashTypedDataV4(structHash), signature);
            if (!isTeeSigner[recovered]) revert UnauthorizedSettlementSigner(recovered);
        }

        _commitRoot(incidentId, inc, root, poolPayouts);
        emit IncidentSettled(incidentId, root, teePcrHash);
    }

    /// @notice Beta-only correction of a standing root during its dispute period.
    ///         A zero root voids the incident; a nonzero root starts a fresh dispute period.
    /// @param root Corrected root, or zero to void the settlement.
    /// @param poolPayouts Corrected budgets aligned to {incidentPools}; empty when voiding.
    function adminCorrectSettlement(bytes32 root, uint256[] calldata poolPayouts)
        external
        onlyAdminOrTimelock
        onlyBetaMode
    {
        uint256 incidentId = _requireActiveIncident();
        Incident storage inc = incidents[incidentId];
        // Only a standing pre-finalization root is directly correctable.
        if (inc.root == bytes32(0)) revert NoStandingRoot(incidentId);
        if (block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD) revert IncidentFinalizing(incidentId);

        if (root == bytes32(0)) {
            if (poolPayouts.length != 0) revert SettlementPoolMismatch(poolPayouts.length, 0);
            delete incidentPoolBudget[incidentId];
            inc.root = bytes32(0);
            inc.rootSubmittedAt = 0;
            inc.status = Status.Closed;
            incidentResolvedAt[incidentId] = uint64(block.timestamp);
            emit IncidentCorrected(incidentId, root);
            return;
        }

        _commitRoot(incidentId, inc, root, poolPayouts);
        emit IncidentCorrected(incidentId, root);
    }

    /// @dev Commit a root and capped per-pool budgets, start its dispute period, and
    ///      delist the affected token.
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

    // ─────────────────────────── Finalize Claim ───────────────────────────

    /// @notice Finalize the caller's live claim using its Merkle-proven payout row.
    ///         Eligible escrow is forfeited, excess escrow is refunded, and pools pay
    ///         amounts within their remaining incident budgets.
    /// @param amounts Per-pool payouts aligned to the incident pool snapshot.
    /// @param scoreSpent Raw historical score consumed by this claim and recorded in the Registry.
    /// @param boostedScore Booster-adjusted score used only for off-chain payout weighting.
    /// @param eligibleAmount Covered escrow amount; cannot exceed total escrow.
    /// @param proof Merkle proof against the standing root.
    function finalizeClaim(
        uint256[] calldata amounts,
        uint256 scoreSpent,
        uint256 boostedScore,
        uint256 eligibleAmount,
        bytes32[] calldata proof
    ) external nonReentrant whenNotPaused {
        uint256 incidentId = _activeIncidentId();
        uint256 claimId = activeClaimId[incidentId][msg.sender];
        if (claimId == 0) revert NoActiveClaim();
        if (claims[claimId].resolved) revert ClaimAlreadyResolved(claimId);

        Incident storage inc = incidents[incidentId];
        // Require a standing root inside its finalization window.
        if (
            inc.status != Status.Open || inc.root == bytes32(0)
                || block.timestamp <= inc.rootSubmittedAt + DISPUTE_PERIOD
                || block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD + FINALIZE_WINDOW
        ) {
            revert FinalizeNotOpen(incidentId);
        }

        {
            // Verify the row against the open-time pool ordering.
            if (amounts.length != incidentPools[incidentId].length) revert InvalidProof(claimId);
            // StandardMerkleTree double-hashed claim leaf.
            bytes32 leaf =
                _settlementLeaf(incidentId, claimId, msg.sender, amounts, scoreSpent, boostedScore, eligibleAmount);
            if (!MerkleProof.verifyCalldata(proof, inc.root, leaf)) revert InvalidProof(claimId);
        }

        Claim storage c = claims[claimId];
        {
            uint256 expectedBoostedScore = Math.mulDiv(
                scoreSpent, BPS_DENOMINATOR + uint256(c.boosterAmount) * BOOSTER_BOOST_BPS, BPS_DENOMINATOR
            );
            if (boostedScore != expectedBoostedScore) revert InvalidBoostedScore(boostedScore, expectedBoostedScore);
        }

        // Keep unresolved nonzero through external calls so pools remain frozen.
        c.resolved = true;

        // Forfeit eligible escrow and refund any signed excess.
        {
            uint256 escrow = c.insuredTokenAmount;
            if (eligibleAmount > escrow) revert EligibleExceedsEscrow(eligibleAmount, escrow);
            escrowedInsuredTokens[inc.insuredToken] -= escrow;
            uint256 refund = escrow - eligibleAmount;
            if (refund > 0) inc.insuredToken.safeTransfer(msg.sender, refund);
        }

        // Burn the boosters escrowed when the claim was filed.
        {
            uint256 boosterAmount = c.boosterAmount;
            if (boosterAmount != 0) {
                IERC1155Burnable(c.boosterCollection).burn(address(this), BOOSTER_ID, boosterAmount);
                // Preserve the committed-and-burned amount as permanent claim history.
            }
        }

        _payClaimAmounts(incidentId, amounts);

        // Emit incident-specific raw score use and mirror only that cumulative total in Registry.
        if (scoreSpent != 0) {
            emit ScoreSpent(msg.sender, scoreSpent, incidentId);
            registry().recordScoreSpent(msg.sender, scoreSpent);
        }

        // Only unfreeze after every external interaction completes.
        inc.unresolved -= 1;
        if (inc.unresolved == 0 && incidentResolvedAt[incidentId] == 0) {
            incidentResolvedAt[incidentId] = uint64(block.timestamp);
        }

        emit ClaimFinalized(claimId, msg.sender);
    }

    /// @dev OpenZeppelin StandardMerkleTree double-hashed settlement leaf.
    function _settlementLeaf(
        uint256 incidentId,
        uint256 claimId,
        address user,
        uint256[] calldata amounts,
        uint256 scoreSpent,
        uint256 boostedScore,
        uint256 eligibleAmount
    ) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(incidentId, claimId, user, amounts, scoreSpent, boostedScore, eligibleAmount))
            )
        );
    }

    /// @dev Draw down hard per-pool budgets before each external payout.
    function _payClaimAmounts(uint256 incidentId, uint256[] calldata amounts) internal {
        address[] storage poolAddrs = incidentPools[incidentId];
        uint256[] storage budget = incidentPoolBudget[incidentId];
        for (uint256 i = 0; i < poolAddrs.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            uint256 remaining = budget[i];
            if (amount > remaining) revert PayoutCapExceeded(i, amount, remaining);
            budget[i] = remaining - amount;
            ISingleAssetCoverPool(poolAddrs[i]).payClaim(msg.sender, amount);
        }
    }

    /// @notice Recover escrow after beta void, missing root, or finalize expiry.
    /// @dev Available while paused so claimant funds cannot be trapped.
    /// @param claimId Caller's unresolved claim.
    function withdrawNonFinalizedClaim(uint256 claimId) external nonReentrant {
        Claim storage c = claims[claimId];
        if (c.user != msg.sender) revert UnauthorizedClaim(claimId);
        if (c.resolved) revert ClaimAlreadyResolved(claimId);

        Incident storage inc = incidents[c.incidentId];
        // A claim is recoverable only after every payout path is closed.
        bool killed = inc.status == Status.Closed;
        bool incidentVoid = inc.status == Status.Open && inc.root == bytes32(0)
            && block.timestamp > inc.claimWindowEndTime + SUBMIT_DEADLINE;
        bool finalizeExpired = inc.status == Status.Open && inc.root != bytes32(0)
            && block.timestamp > inc.rootSubmittedAt + DISPUTE_PERIOD + FINALIZE_WINDOW;

        if (!killed && !incidentVoid && !finalizeExpired) revert ClaimNotWithdrawable(claimId);

        c.resolved = true;
        inc.unresolved -= 1;
        escrowedInsuredTokens[inc.insuredToken] -= c.insuredTokenAmount;
        _returnBoosters(c, msg.sender);
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);

        emit ClaimWithdrawn(claimId, msg.sender);
    }

    // ─────────────────────────── Role management ───────────────────────────

    /// @notice Add or remove a TEE signer between incidents. Timelock only.
    ///         Missing settlement automatically voids after {SUBMIT_DEADLINE}.
    /// @param signer Nonzero signer address.
    /// @param authorized Whether to authorize it.
    function setTeeSigner(address signer, bool authorized) external onlyTimelock notDuringIncident {
        if (signer == address(0)) revert ZeroAddress();
        isTeeSigner[signer] = authorized;
        emit TeeSignerSet(signer, authorized);
    }

    // ─────────────────────────── Views ───────────────────────────

    /// @notice Active incident id used by Registry to freeze pools, or zero.
    function activeIncidentId() external view returns (uint256) {
        return _activeIncidentId();
    }

    /// @notice The full per-token config (κ, minimum claim, oracle, conversion recipe).
    /// @param insuredToken  Insured token to query.
    function getInsuredToken(IERC20 insuredToken) external view returns (InsuredToken memory) {
        return insuredTokens[insuredToken];
    }

    /// @notice Whether `token` is currently approved for insurance.
    function isInsuredToken(IERC20 token) external view returns (bool) {
        return insuredTokens[token].maxCoverageBps != 0;
    }

    /// @notice Number of insured tokens currently in the approval list.
    function insuredTokenListLength() external view returns (uint256) {
        return insuredTokenList.length;
    }

    /// @notice Units of {BOOSTER_ID} committed and initially escrowed by a claim (0 if none).
    /// @param claimId  Claim to query.
    function getClaimBoosterAmount(uint256 claimId) external view returns (uint256) {
        return claims[claimId].boosterAmount;
    }

    // ─────────────────────────── Internal: incident lifecycle ───────────────────────────

    /// @dev Derive the sole active incident from the last-opened id and phase deadlines.
    function _activeIncidentId() internal view returns (uint256) {
        uint256 id = nextIncidentId - 1; // 0 before the first open
        if (id == 0) return 0;
        Incident storage inc = incidents[id];
        if (inc.status == Status.Closed) return 0; // beta-voided — pool unfrozen
        if (block.timestamp <= inc.claimWindowEndTime) return id;
        if (inc.unresolved == 0) return 0;
        if (inc.root == bytes32(0)) return block.timestamp <= inc.claimWindowEndTime + SUBMIT_DEADLINE ? id : 0;
        return block.timestamp <= inc.rootSubmittedAt + DISPUTE_PERIOD + FINALIZE_WINDOW ? id : 0;
    }

    /// @dev {_activeIncidentId} but reverts when there is none — for sites that require
    ///      a live incident.
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
