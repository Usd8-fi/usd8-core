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

/// @notice Minimal view of the single registered insurance product (payout module).
///         The registry delegates "is the system frozen?" to it, so an incident's
///         lazy, time-based lifecycle lives entirely in the product.
interface IPayoutModule {
    function incidentActive() external view returns (bool);
}

/// @title  Registry
/// @notice The single, non-upgradeable access + pause + topology hub for the whole
///         USD8 system. Every core contract inherits {Managed}, holds this address,
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
/// @dev    Deliberately NON-UPGRADEABLE and minimal: the access RULES are frozen
///         (the timelock can only change VALUES), turning "everything trusts one
///         contract" from a single point of failure into a single point of audit.
///         Holds ONLY state the timelock can recreate with setters — never per-user
///         balances or ledgers — so a redeploy + re-enter-settings always suffices.
/// @custom:security-contact rick@usd8.fi
contract Registry {
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
    IERC20[] public poolAssets;

    /// @notice Stake pool address for an asset (0 if none).
    mapping(IERC20 asset => address pool) public poolOf;

    /// @notice The single insurance product allowed to freeze the system and pay
    ///         claims. Set by the timelock; never swapped mid-incident.
    address public payoutModule;

    /// @notice Universal cap, in basis points, on how much of a cover pool's balance
    ///         a single incident may pay out — so LPs never lose everything at once.
    ///         Each pool exposes {SingleAssetCoverPool.maxPayoutPerIncident} =
    ///         balance × this / 10_000; the settlement's per-pool totals are checked
    ///         against it at settle time. Strictly between 0 and 10_000 (a payout of
    ///         100% would let a pool drain fully; 0 would block all payouts).
    uint256 public maxPayoutBps;

    /// @notice Basis-point denominator for {maxPayoutBps}.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ─────────────────────────── Insurance-score topology ───────────────────────────

    /// @notice A token whose holding accrues a non-expiring USD8 insurance score.
    /// @param token                  Scored ERC20 (e.g. USD8, sUSD8).
    /// @param scorePerTokenPerBlock  Score per whole token per block, 1e18-scaled.
    /// @param startBlock             Block from which to begin counting.
    struct ScoredToken {
        IERC20 token;
        uint128 scorePerTokenPerBlock;
        uint64 startBlock;
    }

    /// @notice Tokens whose holding accrues a USD8 insurance score. Frozen while an
    ///         incident is active; products snapshot this at the incident's openBlock
    ///         (off-chain, from state at that block). Read via {getScoredTokens}.
    ScoredToken[] internal scoredTokens;

    /// @notice Canonical ERC-1155 booster collection (USD8Booster) address.
    ///         Committing boosters on a claim boosts a claimant's insurance score.
    ///         Timelock-settable; zero disables booster commits.
    address public boosterNFT;

    // ─────────────────────────── Errors / events ───────────────────────────

    error UnauthorizedTimelock(address caller);
    error UnauthorizedAdmin(address caller);
    error Paused();
    error ZeroAddress();
    error Frozen();
    error PoolExists(IERC20 asset);
    error PoolNotFound(IERC20 asset);
    error ScoredTokenNotFound(IERC20 token);
    error InvalidMaxPayoutBps(uint256 bps);

    event TimelockChanged(address indexed oldTimelock, address indexed newTimelock);
    event MaxPayoutBpsSet(uint256 oldBps, uint256 newBps);
    event AdminSet(address indexed account, bool allowed);
    event PausedSet(address indexed target, bool paused);
    event PoolAdded(IERC20 indexed asset, address indexed pool);
    event PoolRemoved(IERC20 indexed asset);
    event PayoutModuleSet(address indexed oldModule, address indexed newModule);
    event ScoredTokenSet(IERC20 indexed token, uint128 scorePerTokenPerBlock, uint64 startBlock);
    event ScoredTokenRemoved(IERC20 indexed token);
    event BoosterNFTSet(address indexed oldBooster, address indexed newBooster);

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert UnauthorizedTimelock(msg.sender);
        _;
    }

    /// @dev Reverts while an incident is active — topology must be stable for the
    ///      whole settlement, mirroring the old pool asset-list/curation freeze.
    modifier notFrozen() {
        if (frozen()) revert Frozen();
        _;
    }

    /// @param _timelock      Root governance address (non-zero).
    /// @param _admin         Initial admin (non-zero — the system must launch with an
    ///                       admin so the fast pause path is usable from day one).
    /// @param _maxPayoutBps  Per-incident payout cap in bps (0 < bps < 10_000).
    constructor(address _timelock, address _admin, uint256 _maxPayoutBps) {
        if (_timelock == address(0) || _admin == address(0)) revert ZeroAddress();
        if (_maxPayoutBps == 0 || _maxPayoutBps >= BPS_DENOMINATOR) revert InvalidMaxPayoutBps(_maxPayoutBps);
        timelock = _timelock;
        emit TimelockChanged(address(0), _timelock);
        isAdmin[_admin] = true;
        emit AdminSet(_admin, true);
        maxPayoutBps = _maxPayoutBps;
        emit MaxPayoutBpsSet(0, _maxPayoutBps);
    }

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

    // ─────────────────────────── Topology (timelock; frozen-gated) ───────────────────────────

    /// @notice Register a stake pool for an asset. Timelock only; blocked while
    ///         frozen (the pool set must be stable for an incident's settlement).
    function addPool(IERC20 asset, address pool) external onlyTimelock notFrozen {
        if (address(asset) == address(0) || pool == address(0)) revert ZeroAddress();
        if (poolOf[asset] != address(0)) revert PoolExists(asset);
        poolOf[asset] = pool;
        poolAssets.push(asset);
        emit PoolAdded(asset, pool);
    }

    /// @notice Deregister a pool. Timelock only; blocked while frozen. Swap-and-pop
    ///         — payout rows realign off the openBlock snapshot, not live order.
    function removePool(IERC20 asset) external onlyTimelock notFrozen {
        if (poolOf[asset] == address(0)) revert PoolNotFound(asset);
        poolOf[asset] = address(0);
        uint256 n = poolAssets.length;
        for (uint256 i = 0; i < n; i++) {
            if (poolAssets[i] == asset) {
                poolAssets[i] = poolAssets[n - 1];
                poolAssets.pop();
                break;
            }
        }
        emit PoolRemoved(asset);
    }

    /// @notice Set the single insurance payout module. Timelock only; blocked while
    ///         frozen (never swap the module mid-incident). Setting it to zero
    ///         clears the module, which also unfreezes the system — the emergency
    ///         brake for a module stuck reporting an incident forever.
    /// @dev    Accepted side-effect (L7): because {frozen} is delegated to the
    ///         module, clearing it to zero mid-incident flips frozen() false and
    ///         reopens stake/completeUnstake — it can interrupt a live settlement.
    ///         This is intentional and unavoidable: the freeze state lives inside
    ///         the module, so a stuck/compromised module could otherwise lock every
    ///         pool forever with no escape. It is a trusted, timelock-delayed,
    ///         transparent emergency lever, not a routine control.
    function setPayoutModule(address newModule) external onlyTimelock {
        // Clearing to zero is the emergency brake and MUST work even if the
        // current module reverts (or is stuck true) in incidentActive() — so the
        // frozen() guard applies only when installing a new (non-zero) module.
        if (newModule != address(0) && frozen()) revert Frozen();
        emit PayoutModuleSet(payoutModule, newModule);
        payoutModule = newModule;
    }

    /// @notice Set a token in the USD8 insurance-score set. Timelock only; frozen
    ///         while an incident is active. Upsert: updates rate/start in place if
    ///         already scored, otherwise appends.
    function setScoredToken(IERC20 token, uint128 scorePerTokenPerBlock, uint64 startBlock)
        external
        onlyTimelock
        notFrozen
    {
        if (address(token) == address(0)) revert ZeroAddress();
        uint256 n = scoredTokens.length;
        for (uint256 i = 0; i < n; i++) {
            if (scoredTokens[i].token == token) {
                scoredTokens[i].scorePerTokenPerBlock = scorePerTokenPerBlock;
                scoredTokens[i].startBlock = startBlock;
                emit ScoredTokenSet(token, scorePerTokenPerBlock, startBlock);
                return;
            }
        }
        scoredTokens.push(
            ScoredToken({token: token, scorePerTokenPerBlock: scorePerTokenPerBlock, startBlock: startBlock})
        );
        emit ScoredTokenSet(token, scorePerTokenPerBlock, startBlock);
    }

    /// @notice Remove a token from the score set. Timelock only; frozen-gated. Swap-and-pop.
    function removeScoredToken(IERC20 token) external onlyTimelock notFrozen {
        uint256 n = scoredTokens.length;
        for (uint256 i = 0; i < n; i++) {
            if (scoredTokens[i].token == token) {
                scoredTokens[i] = scoredTokens[n - 1];
                scoredTokens.pop();
                emit ScoredTokenRemoved(token);
                return;
            }
        }
        revert ScoredTokenNotFound(token);
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
    function setMaxPayoutBps(uint256 newBps) external onlyTimelock notFrozen {
        if (newBps == 0 || newBps >= BPS_DENOMINATOR) revert InvalidMaxPayoutBps(newBps);
        emit MaxPayoutBpsSet(maxPayoutBps, newBps);
        maxPayoutBps = newBps;
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
    ///         clearing the module (setPayoutModule(0)) also unfreezes — the brake
    ///         for a module stuck active or reverting in incidentActive().
    function frozen() public view returns (bool) {
        address m = payoutModule;
        return m != address(0) && IPayoutModule(m).incidentActive();
    }

    /// @notice The aligned (assets, pools) topology.
    function pools() external view returns (IERC20[] memory assets, address[] memory poolAddrs) {
        uint256 n = poolAssets.length;
        assets = poolAssets;
        poolAddrs = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            poolAddrs[i] = poolOf[poolAssets[i]];
        }
    }

    /// @notice Number of registered pools.
    function poolsLength() external view returns (uint256) {
        return poolAssets.length;
    }

    /// @notice The full USD8 insurance-score token set. See {ScoredToken}.
    function getScoredTokens() external view returns (ScoredToken[] memory) {
        return scoredTokens;
    }

    /// @notice Number of scored tokens.
    function scoredTokensLength() external view returns (uint256) {
        return scoredTokens.length;
    }

    // ─────────────────────────── Checks (consumed by {Managed}) ───────────────────────────

    /// @notice Revert unless caller is the timelock.
    function requireTimelock(address caller) external view {
        if (caller != timelock) revert UnauthorizedTimelock(caller);
    }

    /// @notice Revert unless caller is an admin or the timelock.
    function requireAdminOrTimelock(address caller) external view {
        _requireAdminOrTimelock(caller);
    }

    /// @notice Revert if the given target contract is paused.
    function requireNotPaused(address target) external view {
        if (paused[target]) revert Paused();
    }

    function _requireAdminOrTimelock(address caller) internal view {
        if (caller != timelock && !isAdmin[caller]) revert UnauthorizedAdmin(caller);
    }
}
