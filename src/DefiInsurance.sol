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
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @notice Minimal view of the deployed ERC-1155 USD8Booster: standard
///         transfers plus the `ERC1155Burnable` batch burn (this contract, as
///         the token holder, is authorized to call it). Boosters are
///         semi-fungible — `id` denotes a tier (id 1 = the 1% booster), held in
///         quantity — so commits always work in (ids, amounts) batches.
interface IERC1155Burnable is IERC1155 {
    function burnBatch(address account, uint256[] calldata ids, uint256[] calldata values) external;
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
///         against a single deterministic pool. Settlement is admin-gated and
///         optimistic: the admin opens incidents and submits the root computed
///         off-chain from {Incident.inputHash}; anyone reproduces it and the
///         admin/timelock can {voidSettlement} a bad root within the dispute
///         window (deny-only — never redirects funds).
/// @dev    UUPS upgradeable; timelock authorizes upgrades. Holds insured-token
///         escrow and booster NFTs (ERC1155Holder).
contract DefiInsurance is Initializable, UUPSUpgradeable, ReentrancyGuardTransient, ERC1155Holder {
    using SafeERC20 for IERC20;

    // ─────────────────────────── State (roles + pool) ───────────────────────────

    /// @notice The capital base this product draws on. Set once at init.
    ICoverPool public coverPool;

    /// @notice Slow governance role (TimelockController). Authorizes upgrades.
    address public timelock;

    /// @notice Fast operational role (opens/settles incidents).
    address public admin;

    // ─────────────────────────── State (insured tokens) ───────────────────────────

    /// @notice Basis-point denominator (100%) and the hard ceiling for a token's
    ///         coverage factor κ ({InsuredToken.maxCoverageBps}): κ ∈ `(0, 100%]`.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Per-insured-token config. `maxCoverageBps == 0` means not listed.
    /// @param maxCoverageBps  κ in `(0, 100%]` (bps) while listed.
    /// @param priceOracle  underlying→USD oracle (Chainlink AggregatorV3
    ///                      interface; for non-USD/comparative/LP underlyings,
    ///                      point at an adapter conforming to it).
    /// @param underlyingConversionAddress  token→underlying ratio. The settler
    ///                      reads `staticcall(addr, callData)` and interprets the
    ///                      returned uint256 as WAD-scaled underlying per 1e18 of
    ///                      the insured token. Then `priceOracle` turns underlying
    ///                      into USD. Two layers so any wrapper can be valued.
    ///                      See {setUnderlyingConversion} for the recipes.
    /// @param underlyingConversionCallData  calldata for that staticcall (empty
    ///                      when `underlyingConversionAddress == address(0)`).
    struct InsuredToken {
        uint256 maxCoverageBps;
        address priceOracle;
        address underlyingConversionAddress;
        bytes underlyingConversionCallData;
    }

    /// @notice Per-insured-token config. `maxCoverageBps == 0` is the not-listed
    ///         signal. Auto-delisted the moment an incident opens on it.
    ///         Internal (carries `bytes`); read via {getInsuredToken}.
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
    ///         before it elapses; admin/timelock may {voidSettlement} until then.
    uint64 public constant DISPUTE_PERIOD = 4 days;

    /// @notice Finalization window after the dispute period ends. Total pool lock
    ///         is `CLAIM_WINDOW + [0, SUBMIT_DEADLINE] + DISPUTE_PERIOD +
    ///         FINALIZE_WINDOW` = 12–15 days (7 days if the incident voids).
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
    /// @param referenceBlock  Pre-incident block the admin pins: the "before"
    ///                        point losses are valued against.
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
    struct Claim {
        address user;
        uint256 incidentId;
        uint128 insuredTokenAmount;
        bool finalized;
        bool closed;
    }

    /// @notice All claims by id. Id 0 is reserved.
    mapping(uint256 claimId => Claim) public claims;

    /// @notice Next claim id to assign. Starts at 1.
    uint256 public nextClaimId;

    /// @notice Booster units ((id, amount) pairs of the pool's booster
    ///         collection) escrowed by a claim while open, as parallel arrays.
    ///         Committed id-0 units boost
    ///         the claimant's insurance score (see {BOOSTER_BOOST_BPS}, applied
    ///         off-chain). Burned on {finalizeClaim}; returned on cancel/withdraw.
    mapping(uint256 claimId => uint256[] ids) internal _claimBoosterIds;
    mapping(uint256 claimId => uint256[] amounts) internal _claimBoosterAmounts;

    /// @notice Insured tokens currently held as live claim escrow (summed over
    ///         unresolved claims). Decremented on cancel/withdraw/finalize. Lets
    ///         {sweepInsuredToken} compute the accountable balance without
    ///         iterating claims, so claimant escrow is never sweepable.
    mapping(IERC20 insuredToken => uint256) public escrowedInsuredTokens;

    /// @notice Hard-coded booster policy: each committed unit of booster id 1
    ///         adds 100 bps (+1%) to the claimant's insurance-score multiplier;
    ///         every other id carries no weight. Applied off-chain (the boosting
    ///         id is enforced by the settlement code, not on-chain). The booster
    ///         collection address itself lives on the pool ({ICoverPool.boosterNFT}).
    uint256 public constant BOOSTER_BOOST_BPS = 100;

    // ─────────────────────────── State (settlement config) ───────────────────────────

    /// @notice Global settlement windows, in BLOCKS. Timelock-settable; frozen
    ///         while an incident is active and snapshot into each incident at
    ///         open. See the field docs for the exact meaning.
    /// @param twapLookbackBlocks   W: averaging window for the token→underlying
    ///                             ratio, TWAP'd over `[referenceBlock − W,
    ///                             referenceBlock]` — the pre-incident value.
    /// @param holdingMarginBlocks  margin: how far before {Incident.referenceBlock}
    ///                             the holding must reach. Eligibility is the MIN
    ///                             balance over `[referenceBlock − margin,
    ///                             windowEndBlock]`, capped at escrow (anti-gaming).
    /// @param sampleStepBlocks     stride between TWAP samples (cost↔precision).
    struct SettlementParams {
        uint64 twapLookbackBlocks;
        uint64 holdingMarginBlocks;
        uint64 sampleStepBlocks;
    }

    /// @notice Global settlement windows (in blocks). Frozen while an incident is
    ///         active and snapshot per incident at open.
    SettlementParams public settlementParams;

    /// @notice Full settlement config snapshot taken at {openIncident}, used
    ///         off-chain (and any disputer) for the incident's computation. Pins
    ///         all tunable config so a later change can never alter an in-flight
    ///         or settled incident. `scoredTokens` is snapshot from the pool.
    /// @param maxCoverageBps                  κ for the insured token at open.
    /// @param priceOracle                  underlying→USD oracle at open.
    /// @param underlyingConversionAddress  token→underlying staticcall target at open.
    /// @param underlyingConversionCallData calldata for that staticcall at open.
    /// @param params                       global settlement windows at open.
    /// @param scoredTokens                 pool's insurance-score set at open.
    struct IncidentConfig {
        uint256 maxCoverageBps;
        address priceOracle;
        address underlyingConversionAddress;
        bytes underlyingConversionCallData;
        SettlementParams params;
        ICoverPool.ScoredToken[] scoredTokens;
    }

    /// @notice Settlement config snapshot per incident, frozen at open.
    mapping(uint256 incidentId => IncidentConfig) internal incidentConfig;

    /// @dev Reserved storage slots for future upgrades (sequential storage).
    uint256[50] private __gap;

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
    error BoosterArityMismatch();
    error UnauthorizedClaim(uint256 claimId);
    error ClaimAlreadyResolved(uint256 claimId);
    error NotActiveIncident(uint256 incidentId);
    error OutsideSettlementPhase(uint256 incidentId);
    error RootAlreadySet(uint256 incidentId);
    error NoStandingRoot(uint256 incidentId);
    error FinalizeNotOpen(uint256 incidentId);
    error InvalidProof(uint256 claimId);
    error ClaimNotWithdrawable(uint256 claimId);
    error IncidentsActive();
    error NotSweepable(uint256 requested, uint256 available);

    // ─────────────────────────── Events ──────────────────────────

    event InsuredTokenAdded(IERC20 indexed insuredToken);
    event MaxCoverageBpsSet(IERC20 indexed insuredToken, uint256 maxCoverageBps);
    event UnderlyingConversionSet(IERC20 indexed insuredToken, address conversionAddress, bytes conversionCallData);
    event PriceOracleSet(IERC20 indexed insuredToken, address priceOracle);
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
        uint256[] boosterIds,
        uint256[] boosterAmounts
    );
    event ClaimFinalized(uint256 indexed claimId, address indexed user);
    event ClaimCancelled(uint256 indexed claimId, address indexed user);
    event ClaimWithdrawn(uint256 indexed claimId, address indexed user);
    event Swept(IERC20 indexed token, address indexed to, uint256 amount);
    event TimelockChanged(address indexed oldTimelock, address indexed newTimelock);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);

    // ─────────────────────────── Modifiers ─────────────────────

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert UnauthorizedTimelock(msg.sender);
        _;
    }

    modifier onlyAdminOrTimelock() {
        if (msg.sender != admin && msg.sender != timelock) revert UnauthorizedAdmin(msg.sender);
        _;
    }

    // ─────────────────────────── Constructor / initializer ─────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. Callable once.
    /// @param _coverPool       CoverPool capital base (non-zero). This contract must
    ///                    be registered as a payout module on it (`setPayoutModule`).
    /// @param _timelock   Slow governance role; authorizes UUPS upgrades. Its
    ///                    `minDelay` MUST be comfortably under {DISPUTE_PERIOD}
    ///                    so it can {voidSettlement} a bad root in time.
    /// @param _admin      Fast operational role.
    function initialize(ICoverPool _coverPool, address _timelock, address _admin) external initializer {
        if (address(_coverPool) == address(0) || _timelock == address(0) || _admin == address(0)) revert ZeroAddress();
        coverPool = _coverPool;
        timelock = _timelock;
        admin = _admin;
        nextIncidentId = 1;
        nextClaimId = 1;
    }

    function _authorizeUpgrade(address) internal override onlyTimelock {}

    // ═══════════════════════════ Insured token management (timelock) ═══════════════════════════

    /// @notice Approve a new insured token and set the economic config settlement
    ///         consumes. Timelock only. Must not be USD8 or a pool stake asset,
    ///         nor already listed.
    /// @param insuredToken         Token to insure.
    /// @param _maxCoverageBps         κ in `(0, 100%]` (bps); the timelock picks it.
    /// @param priceOracle          underlying→USD oracle (non-zero).
    /// @param conversionAddress    token→underlying staticcall target (0 = identity).
    /// @param conversionCallData   calldata for that staticcall.
    function addInsuredToken(
        IERC20 insuredToken,
        uint256 _maxCoverageBps,
        address priceOracle,
        address conversionAddress,
        bytes calldata conversionCallData
    ) external onlyTimelock {
        if (address(insuredToken) == address(0) || priceOracle == address(0)) revert ZeroAddress();
        if (insuredToken == coverPool.usd8()) revert TokenConflict();
        if (coverPool.isCoverPoolAsset(insuredToken)) revert TokenConflict();
        if (insuredTokens[insuredToken].maxCoverageBps != 0) revert InsuredTokenAlreadyApproved(insuredToken);
        if (_maxCoverageBps == 0 || _maxCoverageBps > BPS_DENOMINATOR) revert InvalidMaxCoverageBps(_maxCoverageBps, BPS_DENOMINATOR);

        insuredTokens[insuredToken] = InsuredToken({
            maxCoverageBps: _maxCoverageBps,
            priceOracle: priceOracle,
            underlyingConversionAddress: conversionAddress,
            underlyingConversionCallData: conversionCallData
        });
        insuredTokenList.push(insuredToken);
        emit InsuredTokenAdded(insuredToken);
        emit MaxCoverageBpsSet(insuredToken, _maxCoverageBps);
        emit PriceOracleSet(insuredToken, priceOracle);
        emit UnderlyingConversionSet(insuredToken, conversionAddress, conversionCallData);
    }

    /// @notice Update an insured token's coverage factor κ. Timelock only.
    /// @param insuredToken  Listed insured token to update.
    /// @param _maxCoverageBps  New κ in `(0, 100%]` (bps).
    function setMaxCoverageBps(IERC20 insuredToken, uint256 _maxCoverageBps) external onlyTimelock {
        if (insuredTokens[insuredToken].maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
        if (_maxCoverageBps == 0 || _maxCoverageBps > BPS_DENOMINATOR) revert InvalidMaxCoverageBps(_maxCoverageBps, BPS_DENOMINATOR);
        insuredTokens[insuredToken].maxCoverageBps = _maxCoverageBps;
        emit MaxCoverageBpsSet(insuredToken, _maxCoverageBps);
    }

    /// @notice Update an insured token's token→underlying conversion recipe.
    ///         Timelock only.
    /// @param insuredToken       Listed insured token to update.
    /// @param conversionAddress  New staticcall target (0 = identity).
    /// @param conversionCallData New calldata for that staticcall.
    /// @dev    The (address, calldata) pair MUST staticcall-return a single
    ///         WAD-scaled (1e18) amount of underlying per 1e18 units of insured
    ///         token. Common recipes:
    ///         - 1:1 pegged / underlying == token: `conversionAddress = address(0)`
    ///           (identity, ratio = 1e18); set the oracle to the token's USD feed.
    ///         - ERC-4626 vault: `conversionAddress = vault`, `conversionCallData
    ///           = abi.encodeWithSelector(IERC4626.convertToAssets.selector, 1e18)`
    ///           (wrap in a WAD-normalizing adapter if the asset is not 18-dec).
    ///         - LST / rate-provider: `conversionAddress = token`, `conversionCallData`
    ///           = the rate getter returning 1e18-scaled underlying per token.
    ///         - AMM LP token: deploy a thin adapter pricing one 1e18 LP unit in
    ///           the underlying, WAD-scaled; point the recipe at its selector.
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
    /// @param priceOracle   New oracle address (non-zero).
    function setPriceOracle(IERC20 insuredToken, address priceOracle) external onlyTimelock {
        if (insuredTokens[insuredToken].maxCoverageBps == 0) revert InsuredTokenNotApproved(insuredToken);
        if (priceOracle == address(0)) revert ZeroAddress();
        insuredTokens[insuredToken].priceOracle = priceOracle;
        emit PriceOracleSet(insuredToken, priceOracle);
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
        settlementParams = p;
        emit SettlementParamsSet(p);
    }

    /// @notice Sweep any non-accountable insured-token balance (forfeited revenue
    ///         or strays) to a recipient. Admin or timelock. Live claim escrow
    ///         ({escrowedInsuredTokens}) is always protected.
    /// @param token   Insured (or stray) token to sweep.
    /// @param to      Recipient (non-zero).
    /// @param amount  Amount to sweep (≤ the non-accountable balance).
    function sweepInsuredToken(IERC20 token, address to, uint256 amount) external onlyAdminOrTimelock nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 accountable = escrowedInsuredTokens[token];
        uint256 bal = token.balanceOf(address(this));
        uint256 stray = bal > accountable ? bal - accountable : 0;
        if (amount > stray) revert NotSweepable(amount, stray);
        token.safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    // ═══════════════════════════ Incident + claim lifecycle ═══════════════════════════

    /// @notice Open an incident on `insuredToken`. Admin/timelock only, after
    ///         confirming a covered event off-chain. Locks the pool, snapshots
    ///         the full settlement config, and delists the token.
    /// @param  insuredToken    Token a covered event occurred on.
    /// @param  referenceBlock  Pre-incident block (`< block.number`, non-zero)
    ///                         the admin pins as the "before" valuation point.
    /// @return incidentId      The newly opened incident id.
    function openIncident(IERC20 insuredToken, uint64 referenceBlock)
        external
        onlyAdminOrTimelock
        returns (uint256 incidentId)
    {
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
        ic.priceOracle = it.priceOracle;
        ic.underlyingConversionAddress = it.underlyingConversionAddress;
        ic.underlyingConversionCallData = it.underlyingConversionCallData;
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
    /// @param boosterIds          Optional booster ids to commit (the pool's collection).
    /// @param boosterAmounts      Units per `boosterIds` entry (parallel array).
    /// @return claimId The newly minted claim id.
    function joinClaim(
        IERC20 insuredToken,
        uint128 insuredTokenAmount,
        uint256 scoreToSpend,
        uint256[] calldata boosterIds,
        uint256[] calldata boosterAmounts
    ) external nonReentrant returns (uint256 claimId) {
        if (insuredTokenAmount == 0) revert ZeroAmount();

        uint256 incidentId = activeIncidentId;
        bool sameToken = incidentId != 0 && incidents[incidentId].insuredToken == insuredToken;
        if (!sameToken || block.timestamp > incidents[incidentId].windowEndTime) {
            if (sameToken) revert ClaimWindowClosed(insuredToken, incidents[incidentId].windowEndTime);
            revert NoOpenIncident(insuredToken);
        }

        uint128 escrow = uint128(_pullToken(insuredToken, msg.sender, insuredTokenAmount));
        if (escrow == 0) revert ZeroAmount();
        escrowedInsuredTokens[insuredToken] += escrow;

        claimId = nextClaimId++;
        claims[claimId] = Claim({
            user: msg.sender, incidentId: incidentId, insuredTokenAmount: escrow, finalized: false, closed: false
        });

        if (boosterIds.length != 0) {
            if (boosterIds.length != boosterAmounts.length) revert BoosterArityMismatch();
            address booster = coverPool.boosterNFT();
            if (booster == address(0)) revert BoosterNFTUnset();
            IERC1155Burnable(booster).safeBatchTransferFrom(msg.sender, address(this), boosterIds, boosterAmounts, "");
            _claimBoosterIds[claimId] = boosterIds;
            _claimBoosterAmounts[claimId] = boosterAmounts;
        }

        Incident storage incRef = incidents[incidentId];
        incRef.claimCount += 1;
        incRef.inputHash = keccak256(
            abi.encode(incRef.inputHash, claimId, msg.sender, escrow, scoreToSpend, boosterIds, boosterAmounts)
        );

        emit ClaimRegistered(claimId, incidentId, msg.sender, escrow, scoreToSpend, boosterIds, boosterAmounts);
    }

    /// @dev Pull `amount` of `token` from `from`, returning the balance delta
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
        inc.inputHash = keccak256(abi.encode(inc.inputHash, claimId, "CANCEL"));
        escrowedInsuredTokens[inc.insuredToken] -= c.insuredTokenAmount;
        inc.insuredToken.safeTransfer(msg.sender, c.insuredTokenAmount);
        _returnBoosters(claimId, msg.sender);

        emit ClaimCancelled(claimId, msg.sender);
    }

    // ═══════════════════════════ Settlement (admin root) ═══════════════════════════

    /// @notice Submit the settlement root for the in-flight incident. Admin/
    ///         timelock only, in `(windowEnd, windowEnd + SUBMIT_DEADLINE]`. The
    ///         dispute window is a fixed {DISPUTE_PERIOD} from this moment.
    /// @param incidentId  In-flight incident to settle.
    /// @param root        Merkle root of the settlement table.
    function settleIncident(uint256 incidentId, bytes32 root) external onlyAdminOrTimelock {
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

    /// @notice Finalize a claim against the standing root. `amounts` is the
    ///         claimant's per-asset payout row aligned to the pool's stake-asset
    ///         list (frozen for the incident's life); `proof` is its merkle path.
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

        // Burn the committed booster batch — consumed on payout. No-op if none.
        if (_claimBoosterIds[claimId].length != 0) {
            IERC1155Burnable(coverPool.boosterNFT()).burnBatch(
                address(this), _claimBoosterIds[claimId], _claimBoosterAmounts[claimId]
            );
            delete _claimBoosterIds[claimId];
            delete _claimBoosterAmounts[claimId];
        }

        // Pay out of the pool (loss socialization + clamp happen there) and
        // record the consumed score in the pool's shared ledger — one atomic
        // call, so score is only ever spent as part of a payout.
        coverPool.payClaim(msg.sender, amounts, scoreSpent);

        emit ClaimFinalized(claimId, msg.sender);
    }

    /// @dev Return a claim's committed booster batch to `to` (cancel/withdraw).
    function _returnBoosters(uint256 claimId, address to) internal {
        uint256[] storage ids = _claimBoosterIds[claimId];
        if (ids.length == 0) return;
        IERC1155Burnable(coverPool.boosterNFT()).safeBatchTransferFrom(
            address(this), to, ids, _claimBoosterAmounts[claimId], ""
        );
        delete _claimBoosterIds[claimId];
        delete _claimBoosterAmounts[claimId];
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

    /// @notice The settlement config snapshotted for `incidentId` at open.
    /// @param incidentId  Incident to query.
    function getIncidentConfig(uint256 incidentId) external view returns (IncidentConfig memory) {
        return incidentConfig[incidentId];
    }

    /// @notice Booster units currently escrowed by a claim.
    /// @param claimId  Claim to query.
    function getClaimBoosters(uint256 claimId)
        external
        view
        returns (uint256[] memory ids, uint256[] memory amounts)
    {
        return (_claimBoosterIds[claimId], _claimBoosterAmounts[claimId]);
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
