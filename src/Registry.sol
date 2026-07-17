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
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Minimal view of the single registered insurance product (payout module).
///         The registry delegates "is the system frozen?" to it, so an incident's
///         lazy, time-based lifecycle lives entirely in the product.
interface IDefiInsurance {
    function activeIncidentId() external view returns (uint256);
}

/// @notice Minimal view of a cover pool — its stake asset. {addPool}/{removePool}
///         read this so a pool is always registered under its own asset.
interface ICoverPool {
    function asset() external view returns (IERC20);
}

/// @title  Registry
/// @notice The single access + pause + topology hub for the whole
///         USD8 system. Every core contract inherits {SharedBase}, holds this address,
///         and asks it "may this caller act?" / "am I paused?" / "is the system
///         frozen for an incident?" instead of tracking that itself — one audited
///         source of truth, one console to govern and to halt the system.
///
///         Two tiers of authority:
///         - TIMELOCK: a single root address. Sole manager of the role set and of
///           all topology (pools, payout module, scored tokens, booster). Gates the
///           heavy powers via {requireTimelock}.
///         - ADMIN: a SET (any number of keys/bots), curated only by the timelock.
///           Admins + the timelock share the fast operational powers (pause) via
///           {requireAdminOrTimelock}.
///
///         Pause is PER-CONTRACT, keyed by the target's address. Topology state
///         (pool set, payout module, scored tokens, booster) is frozen while an
///         incident is in flight ({frozen}), so a product's settlement runs against
///         a deterministic, unchanging system.
/// @dev    UUPS-upgradeable (timelock-only {_authorizeUpgrade}). It is the ONE
///         upgradeable hub: every {SharedBase} contract holds a fixed pointer to
///         this proxy and has no setRegistry, so the system evolves by upgrading this
///         contract in place — not by redeploy + re-point. Upgradeable because it now
///         carries durable per-user state (e.g. {scoreSpent}) that a fresh redeploy
///         could not preserve, and because forward features (multiple payout modules,
///         richer scoring) extend it. Storage is APPEND-ONLY: never reorder or insert
///         existing fields across an upgrade — only append new ones at the end (OZ v5
///         Initializable/UUPS state lives in its own ERC-7201 namespace, so it does
///         not collide with these sequential slots). Upgrades carry the same
///         timelock-gated discipline as USD8/Treasury.
/// @custom:security-contact rick@usd8.fi
contract Registry is Initializable, UUPSUpgradeable {
    /// @notice The single root governance address (expected: a TimelockController).
    ///         Manages the role set and all topology, and shares all admin powers.
    address public timelock;

    /// @notice The admin set. Admins share the fast operational powers (pause) with
    ///         the timelock; only the timelock curates this set.
    mapping(address account => bool) public isAdmin;

    /// @notice Per-contract pause flag, keyed by the target contract's address.
    mapping(address target => bool) public paused;

    // ─────────────────────────── Topology (pools + payout module) ───────────────────────────

    /// @notice Registered stake pools, one per asset, in add order. Settlement
    ///         payout rows align to this list; it is frozen while an incident is
    ///         active so a product's settlement reads a stable pool set.
    IERC20[] public coverPoolAssets;

    /// @notice Stake pool address for an asset (0 if none).
    mapping(IERC20 asset => address pool) public coverPool;

    /// @notice The single insurance product allowed to freeze the system and pay
    ///         claims. Set by the timelock; never swapped mid-incident.
    address public defiInsurance;

    /// @notice Universal cap, in basis points, on how much of a cover pool's balance
    ///         a single incident may pay out — so LPs never lose everything at once.
    ///         Each pool exposes {SingleAssetCoverPool.maxPayoutPerIncident} =
    ///         balance × this / 10_000; the settlement's per-pool totals are checked
    ///         against it at settle time. Defaults to 5000 (50%) at deploy;
    ///         {setMaxCoverPoolPayoutBps} (timelock) retunes it, strictly between 0
    ///         and 10_000 (100% would let a pool drain fully; 0 would block payouts).
    uint256 public maxCoverPoolPayoutBps;

    /// @notice Basis-point denominator for {maxCoverPoolPayoutBps}.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ─────────────────────────── Insurance-score topology ───────────────────────────

    /// @notice One segment of a scored token's rate timeline: `rate` (score per whole
    ///         token per block, 1e18-scaled) applies from `fromBlock` until the next
    ///         segment's `fromBlock` (or forever if last). `rate == 0` turns scoring
    ///         off from that block onward. Segments are append-only and effective at
    ///         the block they're set in, so a rate change NEVER re-prices already-
    ///         accrued score (the settler integrates each segment at its own rate).
    struct RatePoint {
        uint64 fromBlock;
        uint128 rate;
    }

    /// @notice Every token that has EVER been scored — never pruned. A token whose
    ///         rate is now 0 still earned score during its active windows, so the
    ///         settler must still see it. Enumerable set (mappings aren't iterable);
    ///         products snapshot it at the incident's openBlock. Read via
    ///         {getScoredTokens}; per-token timeline via {getScoredRateHistory}.
    IERC20[] internal scoredTokenList;

    /// @notice Append-only rate timeline per token (see {RatePoint}). Frozen while
    ///         an incident is active. A token's presence in {scoredTokenList} is
    ///         gated on its history being non-empty.
    mapping(IERC20 token => RatePoint[]) internal scoredRates;

    /// @notice Canonical ERC-1155 booster collection (USD8Booster) address.
    ///         Committing boosters on a claim boosts a claimant's insurance score.
    ///         Timelock-settable; zero disables booster commits.
    address public boosterNFT;

    /// @notice Cumulative insurance score each account has spent across all incidents,
    ///         recorded by the payout module at claim finalize via {recordScoreSpent}.
    ///         Kept here — one central total across all (current and future) payout
    ///         modules — so frontends and on-chain consumers read a running total with
    ///         a single view, instead of summing per-module {DefiInsurance.ScoreSpent}
    ///         logs. Off-chain settlement still uses those incident-tagged logs for
    ///         per-incident budgeting; this mirror is the convenience total.
    mapping(address account => uint256) public scoreSpent;

    /// @notice Beta launch mode. While true, functions gated by
    ///         {SharedBase.onlyBetaMode} let a trusted admin stand in for the
    ///         timelock on specific operational shortcuts (currently only
    ///         {DefiInsurance.adminCorrectSettlement} — direct admin root
    ///         correction without the two-step timelock dance). ONE-WAY: starts
    ///         true at {initialize}, the timelock flips it off permanently via
    ///         {endBetaMode}, and there is deliberately no re-enable — so the
    ///         centralization can be removed before real volume but never secretly
    ///         restored. It never relaxes the master powers (upgrades, role
    ///         changes, strategy approval), which stay timelock-only always.
    bool public betaMode;

    /// @notice Governance-approved commitment to the exact Nitro PCR0/PCR1/PCR2
    ///         measurements allowed to sign settlements. Appended for upgrade safety.
    bytes32 public teePcrHash;

    /// @notice Canonical USD8 token used throughout the protocol.
    address public usd8;

    /// @notice Active Treasury holding USD8 mint/burn authority and reserves.
    address public treasury;

    /// @notice Canonical Morpho Vault V2 savings token (sUSD8).
    address public savingsVault;

    /// @notice Canonical USD8/USD composite price oracle.
    address public usd8PriceOracle;

    // ─────────────────────────── Errors / events ───────────────────────────

    error UnauthorizedTimelock(address caller);
    error UnauthorizedAdmin(address caller);
    error Paused();
    error ZeroAddress();
    error Frozen();
    error PoolExists(IERC20 asset);
    error PoolNotFound(IERC20 asset);
    error InvalidMaxCoverPoolPayoutBps(uint256 bps);
    error UnauthorizedModule(address caller);
    error CandidateIncidentActive(address module, uint256 incidentId);
    error InvalidTeePcrHash();

    event TimelockChanged(address indexed oldTimelock, address indexed newTimelock);
    event MaxCoverPoolPayoutBpsSet(uint256 oldBps, uint256 newBps);
    event AdminSet(address indexed account, bool allowed);
    event PausedSet(address indexed target, bool paused);
    event PoolAdded(IERC20 indexed asset, address indexed pool);
    event PoolRemoved(IERC20 indexed asset);
    event DefiInsuranceSet(address indexed oldModule, address indexed newModule);
    event ScoredTokenSet(IERC20 indexed token, uint128 rate, uint64 fromBlock);
    event BoosterNFTSet(address indexed oldBooster, address indexed newBooster);
    event ScoreSpentRecorded(address indexed account, uint256 amount, uint256 newTotal);
    event BetaModeEnded();
    event TeePcrHashSet(bytes32 indexed oldHash, bytes32 indexed newHash);
    event Usd8Set(address indexed oldUsd8, address indexed newUsd8);
    event TreasurySet(address indexed oldTreasury, address indexed newTreasury);
    event SavingsVaultSet(address indexed oldSavingsVault, address indexed newSavingsVault);
    event Usd8PriceOracleSet(address indexed oldOracle, address indexed newOracle);

    modifier onlyTimelock() {
        _requireTimelock(msg.sender);
        _;
    }

    modifier onlyAdminOrTimelock() {
        _requireAdminOrTimelock(msg.sender);
        _;
    }

    /// @dev Reverts while an incident is active — topology must be stable for the
    ///      whole settlement, mirroring the old pool asset-list/curation freeze.
    modifier notFrozen() {
        if (payoutIncidentActive()) revert Frozen();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the Registry proxy. Callable exactly once.
    /// @param _timelock  Root governance address (non-zero).
    /// @param _admin     Initial admin (non-zero — the system must launch with an
    ///                   admin so the fast pause path is usable from day one).
    /// @dev   The per-incident cover-pool payout cap defaults to 5000 (50%); the
    ///        timelock retunes it later via {setMaxCoverPoolPayoutBps}.
    function initialize(address _timelock, address _admin) external initializer {
        if (_timelock == address(0) || _admin == address(0)) revert ZeroAddress();
        timelock = _timelock;
        emit TimelockChanged(address(0), _timelock);
        isAdmin[_admin] = true;
        emit AdminSet(_admin, true);
        maxCoverPoolPayoutBps = 5000; // 50% default; timelock-tunable
        emit MaxCoverPoolPayoutBpsSet(0, 5000);
        betaMode = true; // launch in beta; timelock ends it via {endBetaMode}
    }

    /// @notice Permanently leave beta: admin shortcuts gated by
    ///         {SharedBase.onlyBetaMode} stop working and those operations
    ///         become timelock-only. Timelock only, ONE-WAY (no re-enable).
    function endBetaMode() external onlyTimelock {
        betaMode = false;
        emit BetaModeEnded();
    }

    /// @dev Only the timelock can upgrade the Registry — the same authority that
    ///      gates USD8/Treasury upgrades. No admin upgrade path.
    function _authorizeUpgrade(address) internal override onlyTimelock {}

    // ─────────────────────────── Governance (timelock) ───────────────────────────

    /// @notice Transfer the root timelock. Timelock only, single-step — verify the
    ///         address; a wrong one permanently loses governance of the system.
    function setTimelock(address newTimelock) external onlyTimelock {
        if (newTimelock == address(0)) revert ZeroAddress();
        emit TimelockChanged(timelock, newTimelock);
        timelock = newTimelock;
    }

    /// @notice Add or remove an admin. Timelock only.
    function setAdmin(address account, bool allowed) external onlyTimelock {
        if (account == address(0)) revert ZeroAddress();
        isAdmin[account] = allowed;
        emit AdminSet(account, allowed);
    }

    /// @notice Set the exact enclave-code PCR commitment accepted by settlement.
    ///         Timelock-only and immutable while an incident is active.
    function setTeePcrHash(bytes32 newHash) external onlyTimelock notFrozen {
        if (newHash == bytes32(0)) revert InvalidTeePcrHash();
        emit TeePcrHashSet(teePcrHash, newHash);
        teePcrHash = newHash;
    }

    // ─────────────────────────── Canonical topology (timelock only) ───────────────────────────

    /// @notice Set the canonical USD8 token. Timelock only.
    function setUsd8(address newUsd8) external onlyTimelock {
        if (newUsd8 == address(0)) revert ZeroAddress();
        emit Usd8Set(usd8, newUsd8);
        usd8 = newUsd8;
    }

    /// @notice Set the active Treasury. Timelock only.
    function setTreasury(address newTreasury) external onlyTimelock {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasurySet(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Set the canonical sUSD8 savings vault. Timelock only.
    function setSavingsVault(address newSavingsVault) external onlyTimelock {
        if (newSavingsVault == address(0)) revert ZeroAddress();
        emit SavingsVaultSet(savingsVault, newSavingsVault);
        savingsVault = newSavingsVault;
    }

    /// @notice Set the canonical USD8/USD price oracle. Timelock only.
    function setUsd8PriceOracle(address newOracle) external onlyTimelock {
        if (newOracle == address(0)) revert ZeroAddress();
        emit Usd8PriceOracleSet(usd8PriceOracle, newOracle);
        usd8PriceOracle = newOracle;
    }

    // ─────────────────────────── Topology (timelock; frozen-gated) ───────────────────────────

    /// @notice Register a cover pool. Timelock only; blocked while frozen (the pool
    ///         set must be stable for an incident's settlement). The asset is read
    ///         from the pool itself ({SingleAssetCoverPool.asset}) so it can't be
    ///         mismatched to the wrong pool.
    function addPool(address pool) external onlyTimelock notFrozen {
        if (pool == address(0)) revert ZeroAddress();
        IERC20 asset = ICoverPool(pool).asset();
        if (address(asset) == address(0)) revert ZeroAddress();
        if (coverPool[asset] != address(0)) revert PoolExists(asset);
        coverPool[asset] = pool;
        coverPoolAssets.push(asset);
        emit PoolAdded(asset, pool);
    }

    /// @notice Deregister a cover pool by its address (asset read from the pool).
    ///         Timelock only; blocked while frozen. Swap-and-pop — payout rows
    ///         realign off the openBlock snapshot, not live order.
    function removePool(address pool) external onlyTimelock notFrozen {
        IERC20 asset = ICoverPool(pool).asset();
        if (coverPool[asset] != pool) revert PoolNotFound(asset);
        coverPool[asset] = address(0);
        uint256 n = coverPoolAssets.length;
        for (uint256 i = 0; i < n; i++) {
            if (coverPoolAssets[i] == asset) {
                coverPoolAssets[i] = coverPoolAssets[n - 1];
                coverPoolAssets.pop();
                break;
            }
        }
        emit PoolRemoved(asset);
    }

    /// @notice Set the single insurance payout module. Timelock only; blocked while
    ///         frozen (never swap the module mid-incident). A nonzero candidate must
    ///         also report no active incident, so installation cannot unexpectedly
    ///         freeze the system. Setting it to zero clears the module, which also
    ///         unfreezes the system — the emergency brake for a module stuck reporting
    ///         an incident forever.
    /// @dev    Accepted side-effect (L7): because {frozen} is delegated to the
    ///         module, clearing it to zero mid-incident flips payoutIncidentActive() false and
    ///         reopens stake/completeUnstake — it can interrupt a live settlement.
    ///         This is intentional and unavoidable: the freeze state lives inside
    ///         the module, so a stuck/compromised module could otherwise lock every
    ///         pool forever with no escape. It is a trusted, timelock-delayed,
    ///         transparent emergency lever, not a routine control.
    function setDefiInsurance(address newModule) external onlyTimelock {
        // Clearing to zero is the emergency brake and MUST work even if the
        // current module reverts (or is stuck non-zero) in activeIncidentId().
        if (newModule != address(0)) {
            if (payoutIncidentActive()) revert Frozen();
            uint256 candidateIncidentId = IDefiInsurance(newModule).activeIncidentId();
            if (candidateIncidentId != 0) revert CandidateIncidentActive(newModule, candidateIncidentId);
        }
        emit DefiInsuranceSet(defiInsurance, newModule);
        defiInsurance = newModule;
    }

    /// @notice Set a token's insurance-score `rate` (score per whole token per block,
    ///         1e18-scaled), effective from THIS block onward. Timelock only; frozen
    ///         while an incident is active. APPEND-ONLY: each call adds a segment to
    ///         the token's rate timeline at {block.number}, so a rate change never
    ///         rewrites already-accrued score — the settler integrates each historical
    ///         segment at its own rate. The FIRST call for a token starts its scoring
    ///         (and registers it in {scoredTokenList} permanently); a call with
    ///         `rate == 0` turns scoring off from here — there is no separate remove.
    /// @dev Token-curation requirement (audit L-02): generic historical replay supports
    ///      only non-rebasing ERC-20s whose every balance change is represented by a
    ///      canonical `Transfer` event with the actual balance delta. Use a reviewed
    ///      token-specific snapshot/adapter instead for any other balance semantics.
    /// @param token  Scored ERC20 (e.g. USD8, sUSD8).
    /// @param rate   New score-per-whole-token-per-block, 1e18-scaled (0 = off).
    function setScoredToken(IERC20 token, uint128 rate) external onlyTimelock notFrozen {
        if (address(token) == address(0)) revert ZeroAddress();
        RatePoint[] storage pts = scoredRates[token];
        if (pts.length == 0) scoredTokenList.push(token); // first appearance → enumerable set
        pts.push(RatePoint({fromBlock: uint64(block.number), rate: rate}));
        emit ScoredTokenSet(token, rate, uint64(block.number));
    }

    /// @notice Set the canonical booster NFT collection. Timelock only; frozen-gated.
    ///         Zero disables future commits.
    function setBoosterNFT(address newBooster) external onlyTimelock notFrozen {
        emit BoosterNFTSet(boosterNFT, newBooster);
        boosterNFT = newBooster;
    }

    /// @notice Update the per-incident payout cap. Timelock only — it governs how
    ///         much of a pool a single incident may drain, a risk parameter rather
    ///         than a fast operational lever (and unlike pause it has no deny-only
    ///         safe direction: lowering suppresses legitimate payouts, raising
    ///         weakens LP protection), so it is timelock-gated like every other
    ///         economic setter. Blocked while an incident is active so the cap a
    ///         settlement is checked against can't shift mid-flight. Strictly
    ///         between 0 and {BPS_DENOMINATOR}.
    function setMaxCoverPoolPayoutBps(uint256 newBps) external onlyTimelock notFrozen {
        if (newBps == 0 || newBps >= BPS_DENOMINATOR) revert InvalidMaxCoverPoolPayoutBps(newBps);
        emit MaxCoverPoolPayoutBpsSet(maxCoverPoolPayoutBps, newBps);
        maxCoverPoolPayoutBps = newBps;
    }

    // ─────────────────────────── Insurance-score recording (payout module) ───────────────────────────

    /// @notice Record insurance score `account` consumed on a finalized claim. Only
    ///         the registered payout module ({defiInsurance}) may call — it passes the
    ///         TEE-committed spend from {DefiInsurance.finalizeClaim}. Kept as a single
    ///         cumulative total here so the figure survives a module swap and is read
    ///         with one view. NOT validated against earned score (which is off-chain);
    ///         this mirrors the module's authoritative number, it doesn't gate on it.
    function recordScoreSpent(address account, uint256 amount) external {
        if (msg.sender != defiInsurance) revert UnauthorizedModule(msg.sender);
        uint256 newTotal = scoreSpent[account] + amount;
        scoreSpent[account] = newTotal;
        emit ScoreSpentRecorded(account, amount, newTotal);
    }

    // ─────────────────────────── Pause (admin or timelock) ───────────────────────────

    /// @notice Set the pause flag for one target contract. Admin or timelock.
    /// @dev    INTENTIONALLY NOT frozen-gated (unlike topology setters): pause is
    ///         the fast admin emergency lever and MUST work during an active
    ///         incident — e.g. to halt a pool or the payout module if something
    ///         goes wrong mid-settlement. The accepted trade-off (audit C4) is that
    ///         this same power can pause a pool mid-incident and thereby deny an
    ///         already-validated, dispute-survived payout (payClaim is whenNotPaused);
    ///         claimants then recover escrow via withdrawNonFinalizedClaim, and an
    ///         admin can unpause to let finalization resume. It requires a trusted
    ///         admin key — griefing at worst, never theft. See {SingleAssetCoverPool.payClaim}.
    function setPaused(address target, bool p) external onlyAdminOrTimelock {
        paused[target] = p;
        emit PausedSet(target, p);
    }

    /// @notice Set the pause flag for many targets at once — a one-tx system-wide
    ///         halt (or unhalt). Admin or timelock.
    function setPausedBatch(address[] calldata targets, bool p) external onlyAdminOrTimelock {
        for (uint256 i = 0; i < targets.length; i++) {
            paused[targets[i]] = p;
            emit PausedSet(targets[i], p);
        }
    }

    // ─────────────────────────── Views ───────────────────────────

    /// @notice True while the payout module reports an in-flight incident. Releases
    ///         automatically (lazy + time-based) when the module's incident ends;
    ///         clearing the module (setDefiInsurance(0)) also unfreezes — the brake
    ///         for a module stuck active or reverting in activeIncidentId().
    function payoutIncidentActive() public view returns (bool) {
        address m = defiInsurance;
        return m != address(0) && IDefiInsurance(m).activeIncidentId() != 0;
    }

    /// @notice The aligned (assets, pools) topology.
    function coverPools() external view returns (IERC20[] memory assets, address[] memory poolAddrs) {
        uint256 n = coverPoolAssets.length;
        assets = coverPoolAssets;
        poolAddrs = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            poolAddrs[i] = coverPool[coverPoolAssets[i]];
        }
    }

    /// @notice Number of registered pools.
    function coverPoolsLength() external view returns (uint256) {
        return coverPoolAssets.length;
    }

    /// @notice Every token ever scored (includes now-inactive ones). The settler
    ///         iterates this and reads each token's {getScoredRateHistory}.
    function getScoredTokens() external view returns (IERC20[] memory) {
        return scoredTokenList;
    }

    /// @notice A scored token's full append-only rate timeline (see {RatePoint}).
    ///         Empty if the token was never scored.
    function getScoredRateHistory(IERC20 token) external view returns (RatePoint[] memory) {
        return scoredRates[token];
    }

    /// @notice Number of tokens ever scored.
    function scoredTokensLength() external view returns (uint256) {
        return scoredTokenList.length;
    }

    // ─────────────────────────── Checks (consumed by {SharedBase}) ───────────────────────────

    /// @notice Revert unless caller is the timelock.
    function requireTimelock(address caller) external view {
        _requireTimelock(caller);
    }

    /// @notice Revert unless caller is an admin or the timelock.
    function requireAdminOrTimelock(address caller) external view {
        _requireAdminOrTimelock(caller);
    }

    /// @notice Revert if the given target contract is paused.
    function requireNotPaused(address target) external view {
        if (paused[target]) revert Paused();
    }

    // Single source of truth for each check: the {onlyTimelock}/{onlyAdminOrTimelock}
    // modifiers (used by Registry's own functions) and the external require*
    // (called cross-contract by {SharedBase} in the other contracts) both route here.
    function _requireTimelock(address caller) internal view {
        if (caller != timelock) revert UnauthorizedTimelock(caller);
    }

    function _requireAdminOrTimelock(address caller) internal view {
        if (caller != timelock && !isAdmin[caller]) revert UnauthorizedAdmin(caller);
    }
}
