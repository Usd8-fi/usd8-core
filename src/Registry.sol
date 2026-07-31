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
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Minimal view of the single registered insurance product (payout module).
///         The registry delegates "is the system frozen?" to it, so an incident's
///         lazy, time-based lifecycle lives entirely in the product.
interface IDefiInsurance {
    function activeIncidentId() external view returns (uint256);
    function isInsuredToken(IERC20 token) external view returns (bool);
}

/// @notice Minimal view of a cover pool and its underlying asset. {addPool}/{removePool}
///         read this so a pool is always registered under its own asset.
interface ICoverPool {
    function asset() external view returns (IERC20);
}

/// @title Registry
/// @notice Shared access, pause, configuration, and topology registry for USD8.
///         The timelock manages roles and protocol topology. Admins share limited
///         operational powers such as per-contract pause controls.
/// @dev Topology and settlement-critical settings are frozen during incidents, except
///      the timelock may clear a stuck insurance module. UUPS upgrades require beta mode.
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

    /// @notice Registered cover pools, one per asset, in current array order. Settlement
    ///         payout rows align to this list; it is frozen while an incident is
    ///         active so a product's settlement reads a stable pool set.
    IERC20[] public coverPoolAssets;

    /// @notice Cover pool address for an asset (zero if none).
    mapping(IERC20 asset => address pool) public coverPool;

    /// @notice Insurance module allowed to freeze pools and pay claims. A nonzero
    ///         replacement is blocked during incidents; timelock may clear it to zero.
    address public defiInsurance;

    /// @notice Maximum share of each pool's active `totalAssets()` committed per incident.
    uint256 public maxCoverPoolPayoutBps;

    /// @notice Basis-point denominator for {maxCoverPoolPayoutBps}.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum protocol share of gross claim settlements or reserve revenue.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 2_000;

    /// @notice Shared protocol revenue destination and fee policy.
    /// @param receiver Address receiving claim and reserve-yield protocol fees.
    /// @param claimProtocolFeeShareBps Protocol share of each gross claim settlement.
    /// @param reserveYieldFeeBps Protocol share of Treasury revenue distributions.
    struct ProtocolFeeConfig {
        address receiver;
        uint16 claimProtocolFeeShareBps;
        uint16 reserveYieldFeeBps;
    }

    ProtocolFeeConfig private _protocolFeeConfig;

    // ─────────────────────────── USD8 Insurance-score topology ───────────────────────────

    /// @notice One append-only scoring-rate segment. It applies from `fromBlock`
    ///         until the next segment; a zero rate disables future accrual.
    struct RatePoint {
        uint64 fromBlock;
        uint128 rate;
    }

    /// @notice Every token ever scored, including tokens whose current rate is zero.
    IERC20[] internal scoredTokenList;

    /// @notice Append-only rate timeline per token (see {RatePoint}). Frozen while
    ///         an incident is active. A token's presence in {scoredTokenList} is
    ///         gated on its history being non-empty.
    mapping(IERC20 token => RatePoint[]) internal scoredRates;

    /// @notice Permanent ERC-1155 booster policy. The three values are configured
    ///         atomically once, before claims can use boosters, and cannot be changed.
    struct BoosterConfig {
        address collection;
        uint64 tokenId;
        uint16 boostBps;
    }

    BoosterConfig public boosterConfig;

    /// @notice Cumulative score spent by each account, recorded by the payout module.
    mapping(address account => uint256) public scoreSpent;

    // ─────────────────────────── System settings ───────────────────────────
    /// @notice Enables UUPS upgrades and the direct admin settlement correction path.
    /// @dev The timelock may disable beta mode once, permanently. Pool-beacon
    ///      ownership is separate and must be renounced independently.
    bool public betaMode;

    /// @notice Governance-approved Nitro PCR commitment bound into incident-open
    ///         and settlement signatures.
    bytes32 public teePcrHash;

    /// @notice Canonical USD8 token used throughout the protocol.
    address public usd8;

    /// @notice Active Treasury holding USD8 mint/burn authority and reserves.
    address public treasury;

    /// @notice Canonical Morpho Vault V2 savings token (sUSD8).
    address public savingsVault;

    /// @notice Canonical USD8/USD composite price oracle.
    address public usd8PriceOracle;

    /// @notice Chainlink-style USD feed used to value each registered pool asset
    ///         during settlement. Historical reads are pinned to the incident.
    mapping(IERC20 asset => address feed) public assetUsdFeed;

    /// @notice Maximum accepted oracle answer age at the pinned settlement block.
    ///         Global by design; governance admits only feeds whose heartbeat fits.
    uint64 public maxOracleStaleness;

    /// @notice Timelock-approved `(call target, token approval spender)` pairs
    ///         that strategies may use for reward-token swaps. The addresses are
    ///         separate because aggregators such as 0x can execute through one
    ///         contract while pulling tokens through another.
    mapping(address target => mapping(address spender => bool allowed)) public approvedSwapRoute;

    /// @notice Global timing used by future insurance incidents.
    struct IncidentTimingConfig {
        uint64 phaseWindow;
        uint64 maxReferenceBlockAge;
    }

    /// @notice Global timing used by future cover-pool exit requests.
    struct ExitTimingConfig {
        uint64 unstakeCooldown;
        uint64 exitBatchInterval;
    }

    /// @notice Price-ratio policy used by the TEE before authorizing an incident open.
    /// @dev The same TWAP duration is sampled immediately before and after the
    ///      reference block. Ratios are insured-token units in the configured
    ///      immediate underlying, never insured-token/USD.
    struct IncidentOpenPriceConfig {
        uint64 twapBlocks;
        uint64 sampleStepBlocks;
        uint16 minimumDropBps;
    }

    /// @dev Mutable protocol timing and incident-open configuration.
    IncidentTimingConfig private _incidentTimingConfig;
    ExitTimingConfig private _exitTimingConfig;
    IncidentOpenPriceConfig private _incidentOpenPriceConfig;

    // ─────────────────────────── Errors / events ───────────────────────────

    error UnauthorizedTimelock(address caller);
    error UnauthorizedAdmin(address caller);
    error Paused();
    error ZeroAddress();
    error Frozen();
    error PoolExists(IERC20 asset);
    error PoolNotFound(IERC20 asset);
    error TokenConflict(IERC20 token);
    error InvalidMaxCoverPoolPayoutBps(uint256 bps);
    error UnauthorizedModule(address caller);
    error CandidateIncidentActive(address module, uint256 incidentId);
    error InvalidTeePcrHash();
    error NonIncreasingScoredRateBlock(IERC20 token, uint64 previousBlock, uint64 newBlock);
    error InvalidOracleStaleness();
    error InvalidAssetUsdFeed(address feed);
    error UpgradesPermanentlyDisabled();
    error InvalidIncidentTimingConfig();
    error InvalidExitTimingConfig();
    error InvalidIncidentOpenPriceConfig();
    error BoosterConfigAlreadySet();
    error InvalidBoosterBoostBps();
    error Usd8AlreadySet();
    error TreasuryAlreadySet();
    error SavingsVaultAlreadySet();
    error InvalidProtocolFeeBps(uint256 bps);

    event TimelockChanged(address indexed oldTimelock, address indexed newTimelock);
    event MaxCoverPoolPayoutBpsSet(uint256 oldBps, uint256 newBps);
    event AdminSet(address indexed account, bool allowed);
    event PausedSet(address indexed target, bool paused);
    event PoolAdded(IERC20 indexed asset, address indexed pool);
    event PoolRemoved(IERC20 indexed asset);
    event DefiInsuranceSet(address indexed oldModule, address indexed newModule);
    event ScoredTokenSet(IERC20 indexed token, uint128 rate, uint64 fromBlock);
    event BoosterConfigSet(address indexed collection, uint64 tokenId, uint16 boostBps);
    event ScoreSpentRecorded(address indexed account, uint256 amount, uint256 newTotal);
    event BetaModeEnded();
    event TeePcrHashSet(bytes32 indexed oldHash, bytes32 indexed newHash);
    event Usd8Set(address indexed oldUsd8, address indexed newUsd8);
    event TreasurySet(address indexed oldTreasury, address indexed newTreasury);
    event SavingsVaultSet(address indexed oldSavingsVault, address indexed newSavingsVault);
    event Usd8PriceOracleSet(address indexed oldOracle, address indexed newOracle);
    event AssetUsdFeedSet(IERC20 indexed asset, address indexed oldFeed, address indexed newFeed);
    event MaxOracleStalenessSet(uint64 oldStaleness, uint64 newStaleness);
    event SwapRouteSet(address indexed target, address indexed spender, bool allowed);
    event IncidentTimingConfigSet(IncidentTimingConfig config);
    event ExitTimingConfigSet(ExitTimingConfig config);
    event IncidentOpenPriceConfigSet(IncidentOpenPriceConfig config);
    event ProtocolFeeConfigSet(ProtocolFeeConfig config);

    /// @dev Reverts while an incident is active — topology must be stable for the
    ///      whole settlement, mirroring the old pool asset-list/curation freeze.
    function _requireNotFrozen() internal view {
        if (payoutIncidentActive()) revert Frozen();
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
        _protocolFeeConfig =
            ProtocolFeeConfig({receiver: _admin, claimProtocolFeeShareBps: 2_000, reserveYieldFeeBps: 2_000});
        maxOracleStaleness = 36 hours;
        emit MaxOracleStalenessSet(0, 36 hours);
        _incidentTimingConfig = IncidentTimingConfig({phaseWindow: 3 days, maxReferenceBlockAge: 43_200});
        _exitTimingConfig = ExitTimingConfig({unstakeCooldown: 7 days, exitBatchInterval: 3 days});
        _incidentOpenPriceConfig =
            IncidentOpenPriceConfig({twapBlocks: 7_200, sampleStepBlocks: 300, minimumDropBps: 2_000});
        betaMode = true; // launch in beta; timelock ends it via {endBetaMode}
    }

    /// @notice Current timing for the next insurance incident.
    function incidentTimingConfig() public view returns (IncidentTimingConfig memory config) {
        config = _incidentTimingConfig;
    }

    /// @notice Current shared protocol fee destination and rates.
    function protocolFeeConfig() public view returns (ProtocolFeeConfig memory config) {
        config = _protocolFeeConfig;
    }

    /// @notice Atomically update the shared protocol fee destination and rates.
    function setProtocolFeeConfig(ProtocolFeeConfig calldata config) external {
        _requireAdminOrTimelock(msg.sender);
        if (config.receiver == address(0)) revert ZeroAddress();
        if (config.claimProtocolFeeShareBps > MAX_PROTOCOL_FEE_BPS) {
            revert InvalidProtocolFeeBps(config.claimProtocolFeeShareBps);
        }
        if (config.reserveYieldFeeBps > MAX_PROTOCOL_FEE_BPS) {
            revert InvalidProtocolFeeBps(config.reserveYieldFeeBps);
        }
        _protocolFeeConfig = config;
        emit ProtocolFeeConfigSet(config);
    }

    /// @notice Current timing for future cover-pool exit requests.
    function exitTimingConfig() public view returns (ExitTimingConfig memory config) {
        config = _exitTimingConfig;
    }

    /// @notice Current insured-token/immediate-underlying price policy for incident opening.
    function incidentOpenPriceConfig() public view returns (IncidentOpenPriceConfig memory config) {
        config = _incidentOpenPriceConfig;
    }

    /// @notice Atomically update timing for future incidents.
    function setIncidentTimingConfig(IncidentTimingConfig calldata config) external {
        _requireTimelock(msg.sender);
        _requireNotFrozen();
        if (
            config.phaseWindow == 0 || config.maxReferenceBlockAge == 0
                || config.maxReferenceBlockAge <= incidentOpenPriceConfig().twapBlocks
        ) revert InvalidIncidentTimingConfig();
        _incidentTimingConfig = config;
        emit IncidentTimingConfigSet(config);
    }

    /// @notice Atomically update timing for future exit requests.
    function setExitTimingConfig(ExitTimingConfig calldata config) external {
        _requireTimelock(msg.sender);
        _requireNotFrozen();
        if (config.unstakeCooldown == 0 || config.exitBatchInterval == 0) revert InvalidExitTimingConfig();
        _exitTimingConfig = config;
        emit ExitTimingConfigSet(config);
    }

    /// @notice Atomically update the TEE incident-opening price policy.
    function setIncidentOpenPriceConfig(IncidentOpenPriceConfig calldata config) external {
        _requireTimelock(msg.sender);
        _requireNotFrozen();
        if (
            config.twapBlocks == 0 || config.sampleStepBlocks == 0 || config.sampleStepBlocks > config.twapBlocks
                || config.twapBlocks % config.sampleStepBlocks != 0 || config.twapBlocks / config.sampleStepBlocks < 2
                || config.minimumDropBps == 0 || config.minimumDropBps >= BPS_DENOMINATOR
                || config.twapBlocks >= incidentTimingConfig().maxReferenceBlockAge
        ) revert InvalidIncidentOpenPriceConfig();
        _incidentOpenPriceConfig = config;
        emit IncidentOpenPriceConfigSet(config);
    }

    /// @notice Permanently disable UUPS upgrades and beta-only admin actions.
    ///         Timelock only; blocked during an incident.
    function endBetaMode() external {
        _requireTimelock(msg.sender);
        _requireNotFrozen();
        betaMode = false;
        emit BetaModeEnded();
    }

    /// @dev Only the timelock can upgrade the Registry, and only during beta.
    function _authorizeUpgrade(address) internal view override {
        _requireTimelock(msg.sender);
        if (!betaMode) revert UpgradesPermanentlyDisabled();
    }

    // ─────────────────────────── Governance (timelock) ───────────────────────────

    /// @notice Transfer the root timelock. Timelock only, single-step — verify the
    ///         address; a wrong one permanently loses governance of the system.
    function setTimelock(address newTimelock) external {
        _requireTimelock(msg.sender);
        if (newTimelock == address(0)) revert ZeroAddress();
        emit TimelockChanged(timelock, newTimelock);
        timelock = newTimelock;
    }

    /// @notice Add or remove an admin. Timelock only.
    function setAdmin(address account, bool allowed) external {
        _requireTimelock(msg.sender);
        if (account == address(0)) revert ZeroAddress();
        isAdmin[account] = allowed;
        emit AdminSet(account, allowed);
    }

    /// @notice Approve or revoke an aggregator execution-target / allowance-
    ///         spender pair used by strategies. Timelock only; admins may execute
    ///         swaps but cannot widen the contracts that receive calls or approvals.
    function setSwapRoute(address target, address spender, bool allowed) external {
        _requireTimelock(msg.sender);
        if (target == address(0) || spender == address(0)) revert ZeroAddress();
        approvedSwapRoute[target][spender] = allowed;
        emit SwapRouteSet(target, spender, allowed);
    }

    /// @notice Set the exact enclave-code PCR commitment accepted by settlement.
    ///         Timelock-only and immutable while an incident is active.
    function setTeePcrHash(bytes32 newHash) external {
        _requireTimelock(msg.sender);
        _requireNotFrozen();
        if (newHash == bytes32(0)) revert InvalidTeePcrHash();
        emit TeePcrHashSet(teePcrHash, newHash);
        teePcrHash = newHash;
    }

    // ─────────────────────────── Canonical topology (timelock only) ───────────────────────────

    /// @notice Permanently register the canonical USD8 token. Timelock only.
    function setUsd8(address newUsd8) external {
        _requireTimelock(msg.sender);
        if (usd8 != address(0)) revert Usd8AlreadySet();
        if (newUsd8 == address(0)) revert ZeroAddress();
        emit Usd8Set(usd8, newUsd8);
        usd8 = newUsd8;
    }

    /// @notice Permanently register the canonical Treasury proxy. Timelock only.
    function setTreasury(address newTreasury) external {
        _requireTimelock(msg.sender);
        if (treasury != address(0)) revert TreasuryAlreadySet();
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasurySet(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Permanently register the canonical sUSD8 savings vault. Timelock only.
    function setSavingsVault(address newSavingsVault) external {
        _requireTimelock(msg.sender);
        if (savingsVault != address(0)) revert SavingsVaultAlreadySet();
        if (newSavingsVault == address(0)) revert ZeroAddress();
        emit SavingsVaultSet(savingsVault, newSavingsVault);
        savingsVault = newSavingsVault;
    }

    /// @notice Set the canonical USD8/USD price oracle. Timelock only.
    function setUsd8PriceOracle(address newOracle) external {
        _requireTimelock(msg.sender);
        if (newOracle == address(0)) revert ZeroAddress();
        emit Usd8PriceOracleSet(usd8PriceOracle, newOracle);
        usd8PriceOracle = newOracle;
    }

    // ─────────────────────────── Topology (timelock; frozen-gated) ───────────────────────────

    /// @notice Set the canonical USD feed for a pool asset. Timelock only and
    ///         frozen during incidents so the open-block value is authoritative.
    function setAssetUsdFeed(IERC20 asset, address newFeed) external {
        _requireTimelock(msg.sender);
        _requireNotFrozen();
        if (address(asset) == address(0) || newFeed == address(0)) revert ZeroAddress();
        _validateAssetUsdFeed(newFeed);
        emit AssetUsdFeedSet(asset, assetUsdFeed[asset], newFeed);
        assetUsdFeed[asset] = newFeed;
    }

    /// @notice Set the global maximum oracle age accepted by settlement. Timelock
    ///         only and frozen during incidents; zero would make every feed unusable.
    function setMaxOracleStaleness(uint64 newStaleness) external {
        _requireTimelock(msg.sender);
        _requireNotFrozen();
        if (newStaleness == 0) revert InvalidOracleStaleness();
        emit MaxOracleStalenessSet(maxOracleStaleness, newStaleness);
        maxOracleStaleness = newStaleness;
    }

    /// @notice Register a cover pool and its canonical USD feed atomically. Timelock
    ///         only; blocked while frozen. The asset is read from the pool itself.
    function addPool(address pool, address usdFeed) external {
        _requireTimelock(msg.sender);
        _requireNotFrozen();
        if (pool == address(0) || usdFeed == address(0)) revert ZeroAddress();
        _validateAssetUsdFeed(usdFeed);
        IERC20 asset = ICoverPool(pool).asset();
        if (address(asset) == address(0)) revert ZeroAddress();
        if (coverPool[asset] != address(0)) revert PoolExists(asset);
        if (defiInsurance != address(0) && IDefiInsurance(defiInsurance).isInsuredToken(asset)) {
            revert TokenConflict(asset);
        }
        coverPool[asset] = pool;
        address oldFeed = assetUsdFeed[asset];
        assetUsdFeed[asset] = usdFeed;
        coverPoolAssets.push(asset);
        emit AssetUsdFeedSet(asset, oldFeed, usdFeed);
        emit PoolAdded(asset, pool);
    }

    function _validateAssetUsdFeed(address feed) internal view {
        if (feed.code.length == 0) revert InvalidAssetUsdFeed(feed);
        (bool decimalsOk, bytes memory decimalsData) = feed.staticcall(abi.encodeWithSignature("decimals()"));
        if (!decimalsOk || decimalsData.length != 32 || abi.decode(decimalsData, (uint256)) > 18) {
            revert InvalidAssetUsdFeed(feed);
        }
        (bool roundOk, bytes memory roundData) = feed.staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (!roundOk || roundData.length < 160) revert InvalidAssetUsdFeed(feed);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            abi.decode(roundData, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) revert InvalidAssetUsdFeed(feed);
    }

    /// @notice Remove a cover pool with swap-and-pop. Timelock only; blocked during
    ///         incidents. Existing incidents retain their stored pool order.
    function removePool(address pool) external {
        _requireTimelock(msg.sender);
        _requireNotFrozen();
        IERC20 asset = ICoverPool(pool).asset();
        if (coverPool[asset] != pool) revert PoolNotFound(asset);
        coverPool[asset] = address(0);
        address oldFeed = assetUsdFeed[asset];
        delete assetUsdFeed[asset];
        uint256 n = coverPoolAssets.length;
        for (uint256 i = 0; i < n; i++) {
            if (coverPoolAssets[i] == asset) {
                coverPoolAssets[i] = coverPoolAssets[n - 1];
                coverPoolAssets.pop();
                break;
            }
        }
        emit AssetUsdFeedSet(asset, oldFeed, address(0));
        emit PoolRemoved(asset);
    }

    /// @notice Set the insurance payout module. Timelock only.
    /// @dev A nonzero module must report no active incident and cannot replace an
    ///      active module. Setting zero is an emergency escape that removes the
    ///      module's system freeze and blocks further settlement, correction, payout,
    ///      score writes, and finalization. Unresolved claimants retain recovery exits.
    function setDefiInsurance(address newModule) external {
        _requireTimelock(msg.sender);
        // Clearing must work even if the current module's activeIncidentId() reverts.
        if (newModule != address(0)) {
            if (payoutIncidentActive()) revert Frozen();
            uint256 candidateIncidentId = IDefiInsurance(newModule).activeIncidentId();
            if (candidateIncidentId != 0) revert CandidateIncidentActive(newModule, candidateIncidentId);
        }
        emit DefiInsuranceSet(defiInsurance, newModule);
        defiInsurance = newModule;
    }

    /// @notice Append a token scoring rate effective from the current block. Timelock only.
    ///         A zero rate stops future accrual; history and token enumeration remain.
    /// @dev Generic replay supports only non-rebasing ERC-20s whose balance changes
    ///      are fully represented by standard `Transfer` events.
    /// @param token  Scored ERC20 (e.g. USD8, sUSD8).
    /// @param rate   New score-per-whole-token-per-block, 1e18-scaled (0 = off).
    function setScoredToken(IERC20 token, uint128 rate) external {
        _requireTimelock(msg.sender);
        _requireNotFrozen();
        if (address(token) == address(0)) revert ZeroAddress();
        RatePoint[] storage pts = scoredRates[token];
        uint64 fromBlock = uint64(block.number);
        if (pts.length != 0) {
            uint64 previousBlock = pts[pts.length - 1].fromBlock;
            if (fromBlock <= previousBlock) {
                revert NonIncreasingScoredRateBlock(token, previousBlock, fromBlock);
            }
        } else {
            scoredTokenList.push(token); // first appearance → enumerable set
        }
        pts.push(RatePoint({fromBlock: fromBlock, rate: rate}));
        emit ScoredTokenSet(token, rate, fromBlock);
    }

    /// @notice Permanently configure the canonical booster collection, token id, and
    ///         score boost per unit. This can succeed exactly once.
    function setBoosterConfig(address collection, uint64 tokenId, uint16 boostBps) external {
        _requireTimelock(msg.sender);
        _requireNotFrozen();
        if (collection == address(0)) revert ZeroAddress();
        if (boostBps == 0) revert InvalidBoosterBoostBps();
        if (boosterConfig.collection != address(0)) revert BoosterConfigAlreadySet();
        boosterConfig = BoosterConfig({collection: collection, tokenId: tokenId, boostBps: boostBps});
        emit BoosterConfigSet(collection, tokenId, boostBps);
    }

    /// @notice Set the per-incident pool payout cap. Timelock only; blocked during
    ///         an incident. Must be above zero and below {BPS_DENOMINATOR}.
    function setMaxCoverPoolPayoutBps(uint256 newBps) external {
        _requireTimelock(msg.sender);
        _requireNotFrozen();
        if (newBps == 0 || newBps >= BPS_DENOMINATOR) revert InvalidMaxCoverPoolPayoutBps(newBps);
        emit MaxCoverPoolPayoutBpsSet(maxCoverPoolPayoutBps, newBps);
        maxCoverPoolPayoutBps = newBps;
    }

    // ─────────────────────────── Insurance-score recording (payout module) ───────────────────────────

    /// @notice Add finalized score spending to an account's cumulative total.
    /// @dev Only the registered payout module may call. Earned score is not checked on-chain.
    function recordScoreSpent(address account, uint256 amount) external {
        if (msg.sender != defiInsurance) revert UnauthorizedModule(msg.sender);
        uint256 newTotal = scoreSpent[account] + amount;
        scoreSpent[account] = newTotal;
        emit ScoreSpentRecorded(account, amount, newTotal);
    }

    // ─────────────────────────── Pause (admin or timelock) ───────────────────────────

    /// @notice Set one contract's pause flag. Admin or timelock.
    /// @dev Pause remains available during incidents. Pausing a pool can delay payouts;
    ///      after the payout window, claims can resolve without payment.
    function setPaused(address target, bool p) external {
        _requireAdminOrTimelock(msg.sender);
        paused[target] = p;
        emit PausedSet(target, p);
    }

    /// @notice Set the pause flag for many targets at once — a one-tx system-wide
    ///         halt (or unhalt). Admin or timelock.
    function setPausedBatch(address[] calldata targets, bool p) external {
        _requireAdminOrTimelock(msg.sender);
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

    // Registry setters and SharedBase's external checks share these helpers.
    function _requireTimelock(address caller) internal view {
        if (caller != timelock) revert UnauthorizedTimelock(caller);
    }

    function _requireAdminOrTimelock(address caller) internal view {
        if (caller != timelock && !isAdmin[caller]) revert UnauthorizedAdmin(caller);
    }
}
