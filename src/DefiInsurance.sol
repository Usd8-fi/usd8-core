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
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
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

/// @title DefiInsurance
/// @notice Handles one depeg incident at a time using registered cover pools.
///         The first signed claim, or an admin fallback, opens an incident and
///         freezes topology and matured exits. Each incident snapshots one phase
///         duration used for claim filing, settlement, correction, and payouts.
/// @dev Claims escrow the insured token, USD8 bond, and optional booster. A signed
///      Merkle root sets per-pool payout budgets. Upgrades are allowed only during
///      Registry beta mode and between incidents.
contract DefiInsurance is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
    EIP712Upgradeable,
    ERC1155Holder,
    SharedBase
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ─────────────────────────── State ───────────────────────────

    /// @notice Timelock-managed 1-of-N TEE signers for incident opens and settlements.
    ///         Any compromised signer can attest a false open or root; phase timing,
    ///         pool caps, and beta correction bound that trust assumption.
    mapping(address signer => bool) public isTeeSigner;

    // ─────────────────────────── State (insured tokens) ───────────────────────────

    /// @notice Basis-point denominator (100%) and the hard ceiling for a token's
    ///         coverage factor κ ({InsuredToken.maxCoverageBps}): κ ∈ (0, 100%].
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum claimant share of verified loss; the remaining 20% permits
    ///         a full-loss gross settlement when the protocol fee is at its maximum.
    uint256 public constant MAX_CLAIMANT_COVERAGE_BPS = 8_000;

    /// @notice Per-token coverage and historical valuation recipe; zero coverage means unlisted.
    /// @dev Coverage applies only to direct impairment versus the configured immediate
    ///      underlying. The TEE/admin determines incident eligibility; this recipe only
    ///      values an accepted incident. Finalization buys out the eligible tokens.
    /// @param maxCoverageBps Buyout cap κ in bps, applied off-chain to pre-incident value.
    /// @param underlyingPriceOracle Market-price oracle from underlying to USD.
    /// @param underlyingConversionAddress Historical token-to-underlying rate source;
    ///        zero means identity. Off-chain settlement expects a WAD-scaled uint256.
    /// @param underlyingConversionCallData Calldata for the conversion staticcall.
    struct InsuredToken {
        uint16 maxCoverageBps;
        address underlyingPriceOracle;
        address underlyingConversionAddress;
        bytes underlyingConversionCallData;
    }

    /// @notice Token config; zero coverage means unlisted. Committing a root delists it.
    mapping(IERC20 insuredToken => InsuredToken) internal insuredTokens;

    // ─────────────────────────── State (claim lifecycle) ───────────────────────────

    /// @notice State for one insured-token incident.
    /// @param insuredToken Token covered by the incident.
    /// @param resolvedAt Timestamp when the incident became resolved.
    /// @param referenceBlock Pre-incident valuation block.
    /// @param openBlock Block used to archive-read settlement configuration.
    /// @param phaseDeadline Current phase deadline. It is the claim deadline while
    ///        `root == 0`, then the correction deadline after settlement.

    /// @param root Standing settlement Merkle root, or zero.
    /// @param unresolvedClaims Number of live claims; zero resolves the incident.
    /// @param claimSetHash Ordered commitment to joins and cancellations.
    /// @param teePcrHash Timelock-approved TEE PCR commitment snapshotted at incident open.
    /// @param pools Pool snapshot defining payout-row order.
    /// @param poolBudget Remaining payout budgets aligned to {pools}.
    /// @param protocolFeeShareBps Protocol share of gross payouts, snapshotted at opening.
    struct Incident {
        IERC20 insuredToken;
        uint64 resolvedAt;
        uint64 referenceBlock;
        uint64 openBlock;
        uint64 phaseDeadline;
        bytes32 root;
        uint256 unresolvedClaims;
        bytes32 claimSetHash;
        bytes32 teePcrHash;
        address[] pools;
        uint256[] poolBudget;
        uint16 protocolFeeShareBps;
    }

    /// @notice Incident scalar state by id. Dynamic arrays have dedicated getters.
    mapping(uint256 incidentId => Incident) public incidents;

    /// @notice Common phase duration snapshotted when each incident opens.
    mapping(uint256 incidentId => uint64 phaseWindow) public incidentPhaseWindow;

    /// @notice Pool addresses snapshotted for an incident.
    function incidentPools(uint256 incidentId) external view returns (address[] memory) {
        return incidents[incidentId].pools;
    }

    /// @notice Remaining pool budgets aligned with {incidentPools} after settlement.
    function incidentPoolBudget(uint256 incidentId) external view returns (uint256[] memory) {
        return incidents[incidentId].poolBudget;
    }

    /// @notice Next incident id to assign. Starts at 1.
    uint64 public nextIncidentId;

    /// @notice Escrow registration for one claimant; economics are computed off-chain.
    /// @param user Claimant.
    /// @param incidentId Incident id.
    /// @param insuredTokenAmount Escrowed insured-token amount.
    /// @param boosterAmount Booster units escrowed when the claim is filed.
    /// @param bondAmount USD8 bond posted with this claim.
    /// @param resolved Whether any resolution path has completed.
    struct Claim {
        address user;
        uint64 incidentId;
        uint128 insuredTokenAmount;
        uint128 boosterAmount;
        uint128 bondAmount;
        bool resolved;
    }

    /// @notice Next claim id to assign. Starts at 1.
    uint64 public nextClaimId;

    /// @notice Configurable anti-spam bond posted in USD8 when filing a claim.
    uint128 public claimBondAmount;

    /// @notice All claims by id. Id 0 is reserved.
    mapping(uint256 claimId => Claim) public claims;

    /// @notice Claim id for an account and incident. Cancellation clears it so the
    ///         account may re-file; all other resolution paths retain it.
    mapping(uint256 incidentId => mapping(address account => uint256 claimId)) public claimIdByIncidentAndUser;

    /// @notice Live insured-token escrow excluded from token sweeping.
    mapping(IERC20 insuredToken => uint256) public escrowedInsuredTokens;

    // ─────────────────────────── State (settlement config) ───────────────────────────

    /// @notice Off-chain settlement windows, archive-read at {Incident.openBlock}.
    /// @param twapLookbackBlocks Pre-incident token-to-underlying TWAP lookback.
    /// @param minHoldingRequired Window used to prove minimum pre-incident holdings.
    /// @param sampleStepBlocks TWAP sampling stride; eligibility replay is exact.
    struct SettlementParams {
        uint64 twapLookbackBlocks;
        uint64 minHoldingRequired;
        uint64 sampleStepBlocks;
    }

    /// @notice Global settlement windows (in blocks). Read off-chain as of each
    ///         incident's {Incident.openBlock}; changes apply to later incidents.
    SettlementParams public settlementParams;

    /// @notice Live claim bonds excluded from token sweeping.
    uint256 internal _escrowedClaimBonds;

    /// @notice EIP-712 settlement schema binds the active incident, root, exact claim set,
    ///         ordered pools, per-pool budgets, and approved TEE PCR.
    bytes32 internal constant SETTLEMENT_TYPEHASH = keccak256(
        "Settlement(uint256 incidentId,bytes32 root,uint256 unresolvedClaims,uint256[] poolPayouts,bytes32 pools,bytes32 claimSet,bytes32 teePcrHash)"
    );

    /// @notice EIP-712 open schema binds token, reference block, single-use incident id,
    ///         PCR, and the exact Registry price policy / conversion recipe.
    bytes32 internal constant OPEN_TYPEHASH = keccak256(
        "IncidentOpen(address insuredToken,uint64 referenceBlock,uint256 incidentId,bytes32 teePcrHash,bytes32 eligibilityHash)"
    );

    // ─────────────────────────── Errors ──────────────────────────

    error ZeroAmount();

    error InvalidMaxCoverageBps(uint256 given, uint256 max);

    error InvalidReferenceBlock(uint64 referenceBlock);

    error TokenConflict();

    error InsuredTokenNotApproved(IERC20 insuredToken);

    error ClaimWindowClosed(IERC20 insuredToken, uint64 claimDeadline);

    error UnauthorizedClaim(uint256 claimId);

    error ClaimAlreadyResolved(uint256 claimId);

    error DuplicateClaim(uint256 incidentId);

    error NoActiveClaim();

    error NotActiveIncident(uint256 incidentId);

    error IncidentFinalizing(uint256 incidentId);

    error OutsideSettlementPhase(uint256 incidentId);

    error NoStandingRoot(uint256 incidentId);

    error AlreadySettled(uint256 incidentId);

    error FinalizeNotOpen(uint256 incidentId);

    error InvalidProof(uint256 claimId);

    /// @notice Signed eligible escrow exceeds the amount actually escrowed.
    error EligibleExceedsEscrow(uint256 eligibleAmount, uint256 escrow);

    /// @notice Merkle row's boosted score does not match its raw score and escrowed booster units.
    error InvalidBoostedScore(uint256 provided, uint256 expected);

    error IncidentsActive();

    error IncidentTokenMismatch(uint256 incidentId, IERC20 expectedToken, IERC20 suppliedToken);

    error InvalidSettlementParams();

    error UnexpectedOpenAttestation();

    error UnauthorizedOpenSigner(address recovered);

    error UnauthorizedSettlementSigner(address recovered);

    error SettlementPoolMismatch(uint256 given, uint256 expected);

    error PayoutCapExceeded(uint256 poolIndex, uint256 requested, uint256 cap);

    /// @notice This contract is not the Registry's active insurance module.
    error DefiInsuranceNotRegistered();

    // ─────────────────────────── Events ──────────────────────────

    event InsuredTokenAdded(IERC20 indexed insuredToken);

    event MaxCoverageBpsSet(IERC20 indexed insuredToken, uint256 maxCoverageBps);

    event UnderlyingConversionSet(IERC20 indexed insuredToken, address conversionAddress, bytes conversionCallData);

    event UnderlyingPriceOracleSet(IERC20 indexed insuredToken, address underlyingPriceOracle);

    event InsuredTokenRemoved(IERC20 indexed insuredToken);

    event SettlementParamsSet(SettlementParams params);

    event IncidentOpened(
        uint256 indexed incidentId, IERC20 indexed insuredToken, uint64 claimDeadline, uint16 protocolFeeShareBps
    );

    event IncidentSettled(uint256 indexed incidentId, bytes32 root, bytes32 teePcrHash);

    /// @notice Emitted when beta governance corrects a root; zero means voided.
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

    event ProtocolFeePaid(uint256 indexed incidentId, address indexed pool, address indexed receiver, uint256 amount);

    event ClaimCancelled(uint256 indexed claimId, address indexed user);

    /// @notice Emitted when a claim resolves without accepting its offered payout.
    event ClaimDeclined(uint256 indexed claimId, address indexed user, bool eligible);

    event TeeSignerSet(address indexed signer, bool authorized);

    /// @notice Emitted when an accepted payout consumes score. Off-chain settlement
    ///         uses incident-tagged logs; Registry records the cumulative user total.
    event ScoreSpent(address indexed user, uint256 amount, uint256 indexed incidentId);

    // ─────────────────────────── Initialization ─────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the payout-module proxy. Callable once.
    /// @param _registry Shared access, topology, and timing registry.
    function initialize(Registry _registry) external initializer {
        __EIP712_init("DefiInsurance", "1");
        _setRegistry(_registry);
        nextIncidentId = 1;
        nextClaimId = 1;
        claimBondAmount = 10e18;
        // Nonzero block-based defaults keep settlement live before governance tunes policy.
        settlementParams = SettlementParams({
            twapLookbackBlocks: 50_400, // TWAP lookback
            minHoldingRequired: 50_400, // pre-incident holding window
            sampleStepBlocks: 300 // TWAP sampling stride
        });
    }

    /// @dev Timelock-only during beta and blocked while an incident is active;
    ///      Registry.endBetaMode disables this forever.
    function _authorizeUpgrade(address) internal view override {
        _requireTimelock();
        _requireBetaMode();
        _requireNoActiveIncident();
    }

    /// @dev Freezes settlement-critical configuration from incident open through resolution.
    function _requireNoActiveIncident() internal view {
        if (_activeIncidentId() != 0) revert IncidentsActive();
    }

    /// @dev A deregistered module is recovery-only: unresolved claimants may
    ///      cancel or withdraw, but the stale module cannot advance settlement.
    function _requireRegisteredDefiInsurance() internal view {
        if (registry().defiInsurance() != address(this)) revert DefiInsuranceNotRegistered();
    }

    //--─────────────────────────── System related settings ───────────────────────────

    /// @notice Set the USD8 bond required for each new claim. Timelock only.
    function setClaimBondAmount(uint128 amount) external {
        _requireTimelock();
        claimBondAmount = amount;
    }

    /// @notice Set archive-read settlement windows between incidents. Timelock only.
    /// @param p  New settlement windows. See {SettlementParams}.
    function setSettlementParams(SettlementParams calldata p) external {
        _requireTimelock();
        _requireNoActiveIncident();
        // sampleStepBlocks is the TWAP loop stride off-chain; 0 would never advance.
        if (p.sampleStepBlocks == 0) revert InvalidSettlementParams();
        settlementParams = p;
        emit SettlementParamsSet(p);
    }

    /// @dev Only token balance above live escrow is sweepable; payouts come from pools.
    function _sweepable(address token) internal view override returns (uint256) {
        IERC20 erc20 = IERC20(token);
        uint256 accounted = escrowedInsuredTokens[erc20];
        if (token == registry().usd8()) accounted += _escrowedClaimBonds;
        uint256 bal = erc20.balanceOf(address(this));
        return bal > accounted ? bal - accounted : 0;
    }

    // ─────────────────────────── Insured token management (timelock) ───────────────────────────

    /// @notice Add, atomically update, or delist an insured token's settlement configuration.
    /// @dev A zero maxCoverageBps delists an existing token. New tokens may be listed during
    ///      an unrelated incident; updates and delisting remain frozen until it resolves.
    function editInsuredToken(
        IERC20 insuredToken,
        uint256 maxCoverageBps,
        address underlyingPriceOracle,
        address conversionAddress,
        bytes calldata conversionCallData
    ) external {
        _requireTimelock();
        if (address(insuredToken) == address(0)) revert ZeroAddress();
        bool isNew = insuredTokens[insuredToken].maxCoverageBps == 0;
        if (maxCoverageBps == 0) {
            // Delist an existing token.
            if (isNew) revert InsuredTokenNotApproved(insuredToken);
            if (_activeIncidentId() != 0) revert IncidentsActive();
            _delistInsuredToken(insuredToken);
            return;
        }
        if (underlyingPriceOracle == address(0)) revert ZeroAddress();
        if (maxCoverageBps > MAX_CLAIMANT_COVERAGE_BPS) {
            revert InvalidMaxCoverageBps(maxCoverageBps, MAX_CLAIMANT_COVERAGE_BPS);
        }
        if (isNew) {
            // Add a new token.
            if (registry().coverPool(insuredToken) != address(0)) revert TokenConflict();
            emit InsuredTokenAdded(insuredToken);
        } else if (_activeIncidentId() != 0) {
            revert IncidentsActive();
        }

        insuredTokens[insuredToken] = InsuredToken({
            maxCoverageBps: maxCoverageBps.toUint16(),
            underlyingPriceOracle: underlyingPriceOracle,
            underlyingConversionAddress: conversionAddress,
            underlyingConversionCallData: conversionCallData
        });
        emit MaxCoverageBpsSet(insuredToken, maxCoverageBps);
        emit UnderlyingPriceOracleSet(insuredToken, underlyingPriceOracle);
        emit UnderlyingConversionSet(insuredToken, conversionAddress, conversionCallData);
    }

    // ─────────────────────────── Claim lifecycle ───────────────────────────

    /// @notice Open an incident without filing a claim or supplying a TEE signature.
    ///         Admin or timelock only.
    /// @param insuredToken Covered token.
    /// @param referenceBlock Recent pre-incident valuation block.
    /// @return incidentId Newly opened incident id.
    function openClaimIncident(IERC20 insuredToken, uint64 referenceBlock)
        external
        nonReentrant
        returns (uint256 incidentId)
    {
        _requireAdminOrTimelock();
        return _openIncident(insuredToken, referenceBlock, registry().teePcrHash());
    }

    /// @dev Opens an incident with the supplied PCR commitment after caller-specific checks.
    function _openIncident(IERC20 insuredToken, uint64 referenceBlock, bytes32 teePcrHash)
        internal
        returns (uint256 incidentId)
    {
        _requireNotPaused();
        if (insuredTokens[insuredToken].maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
        // One-at-a-time guard; token listing is checked above.
        if (_activeIncidentId() != 0) revert IncidentsActive();
        // An unregistered module cannot activate the Registry-driven pool freeze.
        if (registry().defiInsurance() != address(this)) revert DefiInsuranceNotRegistered();

        // The reference block also expires signed open attestations.
        Registry.IncidentTimingConfig memory timing = registry().incidentTimingConfig();
        if (
            referenceBlock == 0 || referenceBlock >= block.number
                || block.number - referenceBlock > timing.maxReferenceBlockAge
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

        incidentId = nextIncidentId++;
        uint64 claimDeadline = uint64(block.timestamp) + timing.phaseWindow;
        Incident storage inc = incidents[incidentId];
        inc.insuredToken = insuredToken;
        inc.referenceBlock = referenceBlock;
        inc.openBlock = uint64(block.number);
        inc.phaseDeadline = claimDeadline;
        inc.protocolFeeShareBps = registry().protocolFeeConfig().claimProtocolFeeShareBps;
        incidentPhaseWindow[incidentId] = timing.phaseWindow;
        // Pin payout-row ordering independently of later Registry topology.
        inc.pools = poolAddrs;
        inc.teePcrHash = teePcrHash;

        emit IncidentOpened(incidentId, insuredToken, claimDeadline, inc.protocolFeeShareBps);
    }

    /// @notice File a claim, atomically opening an incident when none is active.
    /// @param insuredToken Token being claimed.
    /// @param insuredTokenAmount Amount to transfer; the claim records the nonzero amount received.
    /// @param scoreToSpend Requested score spend; settlement caps it to availability.
    /// @param boosterAmount Booster units transferred into escrow with the claim.
    /// @param referenceBlock TEE-selected block for the first claim; otherwise zero.
    /// @param signature TEE open signature for the first claim; otherwise empty.
    /// @return claimId The newly minted claim id.
    function fileClaim(
        IERC20 insuredToken,
        uint128 insuredTokenAmount,
        uint256 scoreToSpend,
        uint256 boosterAmount,
        uint64 referenceBlock,
        bytes calldata signature
    ) external nonReentrant returns (uint256 claimId) {
        _requireNotPaused();
        _requireRegisteredDefiInsurance();
        if (insuredTokenAmount == 0) revert ZeroAmount();

        uint256 incidentId = _activeIncidentId();

        if (incidentId == 0) {
            // Open a new incident.
            if (signature.length != 65) revert ECDSA.ECDSAInvalidSignatureLength(signature.length);
            incidentId = nextIncidentId;
            bytes32 teePcrHash = registry().teePcrHash();

            address recovered =
                ECDSA.recover(_incidentOpenDigest(insuredToken, referenceBlock, incidentId, teePcrHash), signature);
            if (!isTeeSigner[recovered]) revert UnauthorizedOpenSigner(recovered);

            _openIncident(insuredToken, referenceBlock, teePcrHash);
        } else {
            // Join the active incident.
            if (referenceBlock != 0 || signature.length != 0) revert UnexpectedOpenAttestation();

            Incident storage cur = incidents[incidentId];
            if (cur.root != bytes32(0)) revert IncidentFinalizing(incidentId);
            if (cur.insuredToken != insuredToken) {
                revert IncidentTokenMismatch(incidentId, cur.insuredToken, insuredToken);
            }

            if (block.timestamp > cur.phaseDeadline) {
                revert ClaimWindowClosed(insuredToken, cur.phaseDeadline);
            }

            // Prevent score-budget multiplication through claim splitting.
            if (claimIdByIncidentAndUser[incidentId][msg.sender] != 0) revert DuplicateClaim(incidentId);
        }

        uint128 bondAmount = claimBondAmount;
        uint128 escrow = _pullToken(insuredToken, msg.sender, insuredTokenAmount).toUint128();
        if (escrow == 0) revert ZeroAmount();
        escrowedInsuredTokens[insuredToken] += escrow;

        {
            IERC20 usd8 = IERC20(registry().usd8());
            usd8.safeTransferFrom(msg.sender, address(this), bondAmount);
            _escrowedClaimBonds += bondAmount;
        }

        claimId = nextClaimId++;
        claimIdByIncidentAndUser[incidentId][msg.sender] = claimId;
        claims[claimId] = Claim({
            user: msg.sender,
            incidentId: incidentId.toUint64(),
            insuredTokenAmount: escrow,
            boosterAmount: boosterAmount.toUint128(),
            bondAmount: bondAmount,
            resolved: false
        });

        if (boosterAmount != 0) {
            (address booster, uint64 boosterId,) = registry().boosterConfig();
            IERC1155(booster).safeTransferFrom(msg.sender, address(this), boosterId, boosterAmount, "");
        }

        Incident storage inc = incidents[incidentId];

        inc.unresolvedClaims += 1;
        // Commit the emitted join fields in replay order.
        inc.claimSetHash =
            keccak256(abi.encode(inc.claimSetHash, claimId, msg.sender, escrow, scoreToSpend, boosterAmount));

        emit ClaimRegistered(claimId, incidentId, msg.sender, escrow, scoreToSpend, boosterAmount);
    }

    /// @notice Cancel your active claim during the claim phase. Returns insured-token
    ///         escrow, boosters, and bond, then allows a new claim id in the same phase.
    function cancelClaim() external nonReentrant {
        uint256 incidentId = _activeIncidentId();
        uint256 claimId = claimIdByIncidentAndUser[incidentId][msg.sender];
        if (claimId == 0) revert NoActiveClaim();

        Incident storage inc = incidents[incidentId];
        if (inc.root != bytes32(0)) revert IncidentFinalizing(incidentId);
        if (block.timestamp > inc.phaseDeadline) {
            revert ClaimWindowClosed(inc.insuredToken, inc.phaseDeadline);
        }

        Claim storage c = claims[claimId];
        if (c.resolved) revert ClaimAlreadyResolved(claimId);
        c.resolved = true;
        inc.unresolvedClaims -= 1;
        // Chain cancellations into the claim-set commitment with a distinct encoding
        // from claim entries.
        inc.claimSetHash = keccak256(abi.encode(inc.claimSetHash, claimId));
        claimIdByIncidentAndUser[incidentId][msg.sender] = 0; // may re-file within the window with a different claim id
        escrowedInsuredTokens[inc.insuredToken] -= c.insuredTokenAmount;
        _returnBoosters(c, msg.sender);
        _resolveClaimBond(c, msg.sender);
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);

        emit ClaimCancelled(claimId, msg.sender);
    }

    /// @dev Pull tokens and return the actual balance delta.
    function _pullToken(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Return a claim's escrowed boosters on a non-acceptance exit.
    function _returnBoosters(Claim storage c, address recipient) internal {
        uint256 amount = c.boosterAmount;
        if (amount != 0) {
            (address booster, uint64 boosterId,) = registry().boosterConfig();
            IERC1155(booster).safeTransferFrom(address(this), recipient, boosterId, amount, "");
        }
    }

    /// @dev Release a resolved claim's USD8 bond.
    function _resolveClaimBond(Claim storage c, address recipient) internal {
        uint256 amount = c.bondAmount;
        IERC20 token = IERC20(registry().usd8());
        _escrowedClaimBonds -= amount;
        token.safeTransfer(recipient, amount);
    }

    // ─────────────────────────── Settlement (TEE-signed root only) ───────────────────────────

    /// @notice Relay the sole TEE-signed settlement root for the active incident.
    /// @param root Merkle root over claimant payout rows.
    /// @param poolPayouts Per-pool budgets aligned to the open-time pool snapshot.
    /// @param signature EIP-712 signature from an authorized TEE signer.
    function settleIncident(bytes32 root, uint256[] calldata poolPayouts, bytes calldata signature) external {
        _requireNotPaused();
        _requireRegisteredDefiInsurance();
        uint256 incidentId = _requireActiveIncident();
        Incident storage inc = incidents[incidentId];

        // Fail on phase errors before signature recovery.
        if (root == bytes32(0)) revert NoStandingRoot(incidentId);
        // A standing root can only be replaced by beta governance.
        if (inc.root != bytes32(0)) revert AlreadySettled(incidentId);
        uint256 settlementDeadline = uint256(inc.phaseDeadline) + incidentPhaseWindow[incidentId];
        if (block.timestamp <= inc.phaseDeadline || block.timestamp > settlementDeadline) {
            revert OutsideSettlementPhase(incidentId);
        }

        // Bind the signature to the PCR snapshotted when the incident opened.
        bytes32 teePcrHash = inc.teePcrHash;
        {
            bytes32 structHash = keccak256(
                abi.encode(
                    SETTLEMENT_TYPEHASH,
                    incidentId,
                    root,
                    inc.unresolvedClaims,
                    keccak256(abi.encodePacked(poolPayouts)),
                    keccak256(abi.encodePacked(inc.pools)),
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

    /// @notice Beta-only correction of a standing root during its correction window.
    ///         A zero root voids the incident; a nonzero root starts a fresh correction window.
    /// @param root Corrected root, or zero to void the settlement.
    /// @param poolPayouts Corrected budgets aligned to the incident's pool snapshot; empty when voiding.
    function adminCorrectSettlement(bytes32 root, uint256[] calldata poolPayouts) external {
        _requireAdminOrTimelock();
        _requireBetaMode();
        _requireRegisteredDefiInsurance();
        uint256 incidentId = _requireActiveIncident();
        Incident storage inc = incidents[incidentId];
        // Only a standing pre-finalization root is directly correctable.
        if (inc.root == bytes32(0)) revert NoStandingRoot(incidentId);
        if (block.timestamp > inc.phaseDeadline) revert IncidentFinalizing(incidentId);

        if (root == bytes32(0)) {
            if (poolPayouts.length != 0) revert SettlementPoolMismatch(poolPayouts.length, 0);
            delete inc.poolBudget;
            inc.root = bytes32(0);
            inc.phaseDeadline = 0;
            inc.resolvedAt = uint64(block.timestamp);
            emit IncidentCorrected(incidentId, root);
            return;
        }

        _commitRoot(incidentId, inc, root, poolPayouts);
        emit IncidentCorrected(incidentId, root);
    }

    /// @dev Commit a root and capped per-pool budgets, start its correction window, and
    ///      delist the affected token.
    function _commitRoot(uint256 incidentId, Incident storage inc, bytes32 root, uint256[] calldata poolPayouts)
        private
    {
        address[] storage poolAddrs = inc.pools;
        if (poolPayouts.length != poolAddrs.length) {
            revert SettlementPoolMismatch(poolPayouts.length, poolAddrs.length);
        }
        for (uint256 i = 0; i < poolAddrs.length; i++) {
            uint256 cap = ISingleAssetCoverPool(poolAddrs[i]).maxPayoutPerIncident();
            if (poolPayouts[i] > cap) revert PayoutCapExceeded(i, poolPayouts[i], cap);
        }
        inc.poolBudget = poolPayouts;

        inc.root = root;
        inc.phaseDeadline = uint64(block.timestamp) + incidentPhaseWindow[incidentId];
        _delistInsuredToken(inc.insuredToken);
    }

    // ─────────────────────────── Finalize Claim ───────────────────────────

    /// @notice Resolve a claim using its Merkle-proven payout row. The claimant may
    ///         accept or decline an eligible payout; anyone may resolve a proven
    ///         bond-ineligible row without accepting a payout.
    /// @param claimId Claim being resolved.
    /// @param acceptPayout Whether to consume eligibility and accept the offered payout.
    /// @param amounts Per-pool payouts aligned to the incident pool snapshot.
    /// @param scoreSpent Raw historical score consumed by this claim and recorded in the Registry.
    /// @param boostedScore Booster-adjusted score used only for off-chain payout weighting.
    /// @param eligibleAmount Covered escrow amount. Bond and payout eligibility also
    ///        require nonzero score spent.
    /// @param proof Merkle proof against the standing root.
    function finalizeClaim(
        uint256 claimId,
        bool acceptPayout,
        uint256[] calldata amounts,
        uint256 scoreSpent,
        uint256 boostedScore,
        uint256 eligibleAmount,
        bytes32[] calldata proof
    ) external nonReentrant {
        Claim storage c = claims[claimId];
        if (c.user == address(0)) revert UnauthorizedClaim(claimId);
        if (c.resolved) revert ClaimAlreadyResolved(claimId);

        uint256 incidentId = c.incidentId;
        Incident storage inc = incidents[incidentId];
        bool moduleInactive = registry().defiInsurance() != address(this);

        // A removed module or missing/voided root has no usable proof. After the
        // applicable deadline, the claimant may recover without settlement.
        if (moduleInactive || inc.root == bytes32(0)) {
            if (msg.sender != c.user) revert UnauthorizedClaim(claimId);
            bool unavailable =
                moduleInactive || block.timestamp > uint256(inc.phaseDeadline) + incidentPhaseWindow[incidentId];
            if (acceptPayout || !unavailable) revert FinalizeNotOpen(incidentId);
            _resolveWithoutSettlement(claimId, c, inc);
            return;
        }

        // A proof-backed decline remains available after payout expiry so an eligible
        // claimant can recover the bond without accepting an inadequate offer.
        if (block.timestamp <= inc.phaseDeadline) revert FinalizeNotOpen(incidentId);
        if (acceptPayout) {
            uint256 finalizeDeadline = uint256(inc.phaseDeadline) + incidentPhaseWindow[incidentId];
            if (block.timestamp > finalizeDeadline) revert FinalizeNotOpen(incidentId);
            registry().requireNotPaused(address(this));
        }

        {
            if (amounts.length != inc.pools.length) revert InvalidProof(claimId);
            bytes32 leaf =
                _settlementLeaf(incidentId, claimId, c.user, amounts, scoreSpent, boostedScore, eligibleAmount);
            if (!MerkleProof.verifyCalldata(proof, inc.root, leaf)) revert InvalidProof(claimId);
        }

        {
            (,, uint16 boosterBoostBps) = registry().boosterConfig();
            uint256 expectedBoostedScore =
                Math.mulDiv(scoreSpent, BPS_DENOMINATOR + uint256(c.boosterAmount) * boosterBoostBps, BPS_DENOMINATOR);
            if (boostedScore != expectedBoostedScore) revert InvalidBoostedScore(boostedScore, expectedBoostedScore);
        }

        bool eligible = eligibleAmount != 0 && scoreSpent != 0;
        // A third party can only close a proven bond-ineligible row and can never
        // exercise the claimant's payout choice.
        if (msg.sender != c.user && (acceptPayout || eligible)) revert UnauthorizedClaim(claimId);
        c.resolved = true; // Keep unresolved nonzero through external calls so pools remain frozen.

        {
            uint256 escrow = c.insuredTokenAmount;
            if (eligibleAmount > escrow) revert EligibleExceedsEscrow(eligibleAmount, escrow);
            escrowedInsuredTokens[inc.insuredToken] -= escrow;
            uint256 refund = acceptPayout && eligible ? escrow - eligibleAmount : escrow;
            if (refund != 0) inc.insuredToken.safeTransfer(c.user, refund);
        }

        uint256 boosterAmount = c.boosterAmount;
        if (boosterAmount != 0) {
            if (acceptPayout && eligible) {
                (address booster, uint64 boosterId,) = registry().boosterConfig();
                IERC1155Burnable(booster).burn(address(this), boosterId, boosterAmount);
            } else {
                _returnBoosters(c, c.user);
            }
        }

        // Eligibility—not payout size or acceptance—determines who receives the bond.
        _resolveClaimBond(c, eligible ? c.user : registry().treasury());

        if (acceptPayout && eligible) {
            _payClaimAmounts(incidentId, c.user, amounts);
            if (scoreSpent != 0) {
                emit ScoreSpent(c.user, scoreSpent, incidentId);
                registry().recordScoreSpent(c.user, scoreSpent);
            }
        }

        inc.unresolvedClaims -= 1;
        if (inc.unresolvedClaims == 0 && inc.resolvedAt == 0) {
            inc.resolvedAt = uint64(block.timestamp);
        }

        if (acceptPayout && eligible) emit ClaimFinalized(claimId, c.user);
        else emit ClaimDeclined(claimId, c.user, eligible);
    }

    /// @dev Resolve an incident that cannot produce a usable Merkle decision.
    function _resolveWithoutSettlement(uint256 claimId, Claim storage c, Incident storage inc) internal {
        c.resolved = true;
        inc.unresolvedClaims -= 1;
        if (inc.unresolvedClaims == 0 && inc.resolvedAt == 0) {
            inc.resolvedAt = uint64(block.timestamp);
        }
        escrowedInsuredTokens[inc.insuredToken] -= c.insuredTokenAmount;
        _returnBoosters(c, msg.sender);
        _resolveClaimBond(c, msg.sender);
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);
        emit ClaimDeclined(claimId, msg.sender, false);
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
    function _payClaimAmounts(uint256 incidentId, address claimant, uint256[] calldata amounts) internal {
        Incident storage inc = incidents[incidentId];
        Registry.ProtocolFeeConfig memory feeConfig = registry().protocolFeeConfig();
        for (uint256 i = 0; i < inc.pools.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            uint256 grossAmount = Math.mulDiv(amount, BPS_DENOMINATOR, BPS_DENOMINATOR - inc.protocolFeeShareBps);
            uint256 remaining = inc.poolBudget[i];
            if (grossAmount > remaining) revert PayoutCapExceeded(i, grossAmount, remaining);
            inc.poolBudget[i] = remaining - grossAmount;
            address pool = inc.pools[i];
            ISingleAssetCoverPool(pool).payClaim(claimant, amount);
            uint256 protocolFee = grossAmount - amount;
            if (protocolFee != 0) {
                ISingleAssetCoverPool(pool).payClaim(feeConfig.receiver, protocolFee);
                emit ProtocolFeePaid(incidentId, pool, feeConfig.receiver, protocolFee);
            }
        }
    }

    // ─────────────────────────── Role management ───────────────────────────

    /// @notice Add or remove a TEE signer between incidents. Timelock only.
    /// @param signer Nonzero signer address.
    /// @param authorized Whether to authorize it.
    function setTeeSigner(address signer, bool authorized) external {
        _requireTimelock();
        _requireNoActiveIncident();
        if (signer == address(0)) revert ZeroAddress();
        isTeeSigner[signer] = authorized;
        emit TeeSignerSet(signer, authorized);
    }

    // ─────────────────────────── Views ───────────────────────────

    /// @notice Active incident id used by Registry to freeze pools, or zero.
    function activeIncidentId() external view returns (uint256) {
        return _activeIncidentId();
    }

    function _incidentOpenDigest(IERC20 insuredToken, uint64 referenceBlock, uint256 incidentId, bytes32 teePcrHash)
        internal
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    OPEN_TYPEHASH,
                    address(insuredToken),
                    referenceBlock,
                    incidentId,
                    teePcrHash,
                    incidentOpenEligibilityHash(insuredToken)
                )
            )
        );
    }

    /// @notice Hash of the exact incident-open price policy and conversion recipe
    ///         that a TEE authorization must bind.
    function incidentOpenEligibilityHash(IERC20 insuredToken) public view returns (bytes32) {
        Registry reg = registry();
        Registry.IncidentOpenPriceConfig memory price = reg.incidentOpenPriceConfig();
        InsuredToken storage token = insuredTokens[insuredToken];
        return keccak256(
            abi.encode(
                address(reg),
                price.twapBlocks,
                price.sampleStepBlocks,
                price.minimumDropBps,
                token.underlyingConversionAddress,
                keccak256(token.underlyingConversionCallData)
            )
        );
    }

    /// @notice The full per-token config (coverage, oracle, and conversion recipe).
    /// @param insuredToken  Insured token to query.
    function getInsuredToken(IERC20 insuredToken) external view returns (InsuredToken memory) {
        return insuredTokens[insuredToken];
    }

    /// @notice Whether `token` is currently approved for insurance.
    function isInsuredToken(IERC20 token) external view returns (bool) {
        return insuredTokens[token].maxCoverageBps != 0;
    }

    // ─────────────────────────── Internal: incident lifecycle ───────────────────────────

    /// @dev Derive the sole active incident from the last-opened id and current phase deadline.
    function _activeIncidentId() internal view returns (uint256) {
        uint256 id = nextIncidentId - 1; // 0 before the first open
        if (id == 0) return 0;
        Incident storage inc = incidents[id];
        if (block.timestamp <= inc.phaseDeadline) return id;
        if (inc.unresolvedClaims == 0) return 0;
        uint256 terminalDeadline = uint256(inc.phaseDeadline) + incidentPhaseWindow[id];
        return block.timestamp <= terminalDeadline ? id : 0;
    }

    /// @dev {_activeIncidentId} but reverts when there is none — for sites that require
    ///      a live incident.
    function _requireActiveIncident() internal view returns (uint256 id) {
        id = _activeIncidentId();
        if (id == 0) revert NotActiveIncident(0);
    }

    /// @dev Delist an insured token by zeroing its maxCoverageBps. No-op if absent.
    function _delistInsuredToken(IERC20 insuredToken) internal {
        if (insuredTokens[insuredToken].maxCoverageBps == 0) return;
        insuredTokens[insuredToken].maxCoverageBps = 0;
        emit InsuredTokenRemoved(insuredToken);
    }
}
