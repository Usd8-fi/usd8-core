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
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IProfitDistributionReceiver} from "./interfaces/IProfitDistributionReceiver.sol";

/// @notice Minimal view of a registered insurance product (payout module). The pool
///         delegates "is the pool frozen?" to whichever payout module currently holds
///         it, so an incident's lazy, time-based lifecycle can live entirely in
///         the product without the pool depending on its internals.
interface IPayoutModule {
    function incidentActive() external view returns (bool);
}

/// @dev Minimal Chainlink-style feed surface. On-chain it is read ONLY for the
///      stake-size cap — a failing or bad feed is treated as "uncapped" so it
///      can never block staking. The off-chain settler ALSO prices pool assets
///      with it at window-end, so feed configuration is payout-critical
///      (timelock-only) even though no on-chain payout path reads it.
interface IAggregatorV3 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/// @title  CoverPool v1
/// @notice The shared CAPITAL BASE for the USD8 insurance system. Stakers
///         deposit assets to underwrite coverage and earn USD8 yield; the pool
///         tracks each staker's share, streams rewards, and holds the canonical
///         USD8 insurance-score ledger (earn registry + spent ledger). It is
///         product-AGNOSTIC: registered insurance products ("payout modules" —
///         {DefiInsurance}, future travel insurance, …) run their own claim
///         logic and call the pool only to {lockPool} it for an incident and
///         {payClaim} out of pooled capital (which also records spent score).
///
///         While a payout module holds the pool for an in-flight incident, LP
///         withdrawals and asset/score curation are frozen, so any settlement
///         the product computes runs against one deterministic pool. The freeze
///         is delegated to the active payout module's {IPayoutModule.incidentActive}
///         (lazy + time-based), so it releases automatically with no extra tx.
/// @dev    Per-asset reward math is Synthetix StakingRewards over shares (not
///         raw amounts), linear over rewardsDuration for JIT defense. No
///         receipt token — positions live in internal storage. Two asset
///         categories are held: stake assets ({coverPoolAssetList}, {totalAssets}
///         backs shares) and USD8 (via {receiveProfitDistribution}). Insured
///         tokens are held by the products, not here.
/// @custom:security-contact rick@usd8.fi
contract CoverPool is Initializable, UUPSUpgradeable, ReentrancyGuardTransient, IProfitDistributionReceiver {
    using SafeERC20 for IERC20;

    // ─────────────────────────── State (roles) ───────────────────────────

    /// @notice Slow governance role. Holds user-impacting powers: stake-asset
    ///         curation, scored-token curation, payout module registration, role
    ///         transfer. Expected to be a TimelockController.
    address public timelock;

    /// @notice Fast operational role. Tunes the reward emission window
    ///         ({setRewardsDuration}).
    address public admin;

    // ─────────────────────────── Cover Pool State (staking & rewards) ───────────────────────────

    /// @notice Standard cooldown applied to an unstake request when the pool is
    ///         not frozen. While a payout module holds the pool for an incident,
    ///         {completeUnstake} stays blocked until it releases, even after the
    ///         7-day cooldown elapses.
    uint64 public constant UNSTAKE_COOLDOWN = 7 days;

    /// @notice Scaling factor for the per-asset rewardPerShare accumulator.
    uint256 internal constant REWARD_SCALE = 1e30;

    /// @notice Seconds in a year, for annualizing the reward rate in the size cap.
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Basis-points denominator (target-APY math).
    uint256 internal constant BPS = 10_000;

    /// @notice USD8: the token paid as reward to stakers. Set once at init.
    IERC20 public usd8;

    /// @notice Emission window applied to every profit distribution.
    uint64 public rewardsDuration;

    /// @notice Per-stake-asset emission and share state.
    /// @param totalShares           Sum of all user shares for this asset.
    /// @param totalAssets           Actual asset tokens backing those shares.
    ///                              Decreases on claim payout; the share-to-asset
    ///                              ratio floats with it (loss socialization).
    /// @param unstakingShares       Shares with a pending unstake request: still
    ///                              counted in {totalShares} (absorb payouts) but
    ///                              excluded from the reward base.
    /// @param rewardRate            Current emission of {usd8} per second.
    /// @param periodFinish          Unix timestamp the emission window ends.
    /// @param lastUpdateTime        Timestamp of the last reward checkpoint.
    /// @param usdPriceFeed          Chainlink-style USD feed; a non-zero feed IS
    ///                              the listed/approved signal.
    /// @param rewardPerShareStored  Cumulative reward-per-share at the last
    ///                              checkpoint, scaled by {REWARD_SCALE}.
    struct CoverPoolAssetState {
        uint256 totalShares;
        uint256 totalAssets;
        uint256 unstakingShares;
        uint128 rewardRate;
        uint64 periodFinish;
        uint64 lastUpdateTime;
        address usdPriceFeed;
        uint256 rewardPerShareStored;
    }

    /// @notice Per-stake-asset state. See {CoverPoolAssetState}.
    mapping(IERC20 asset => CoverPoolAssetState) public coverPoolAssets;

    /// @notice Per-asset, per-user share and reward bookkeeping.
    /// @param shares                  User's current stake share count.
    /// @param userRewardPerSharePaid  Snapshot of rewardPerShareStored at the
    ///                                user's last checkpoint.
    /// @param rewards                 Accumulated, not-yet-claimed {usd8}.
    struct UserAssetState {
        uint256 shares;
        uint256 userRewardPerSharePaid;
        uint256 rewards;
    }

    /// @notice Per-stake-asset, per-user state. See {UserAssetState}.
    mapping(IERC20 asset => mapping(address user => UserAssetState)) public userAssetState;

    /// @notice Approved stake assets in admin-determined order. Settlement-table
    ///         amounts[] align to this order; it cannot change while the pool
    ///         is frozen, so it is stable for a product's settlement to read.
    IERC20[] public coverPoolAssetList;

    /// @notice Profit-distribution weight per stake asset. Incoming USD8 profit
    ///         ({receiveProfitDistribution}) is split across assets pro-rata to
    ///         these weights. Set at {addCoverPoolAsset}, adjustable via
    ///         {setCoverPoolAssetWeight}. A zero weight means the asset earns no
    ///         share of profit (still stakeable, still absorbs claim losses).
    ///         The sum is computed on demand by {totalAssetWeight}.
    mapping(IERC20 asset => uint256) public coverPoolAssetWeight;

    /// @notice A pending intent to redeem shares of asset after the cooldown.
    /// @param shares       Shares the user intends to redeem.
    /// @param requestedAt  Timestamp of {requestUnstake}.
    struct UnstakeRequest {
        uint256 shares;
        uint64 requestedAt;
    }

    /// @notice Pending unstake requests, one per (asset, user).
    mapping(IERC20 asset => mapping(address user => UnstakeRequest)) public unstakeRequests;

    // ─────────────────────────── State (insurance score) ───────────────────────────

    /// @notice A token whose holding accrues a non-expiring USD8 insurance score.
    ///         The score is Σ over [startBlock, B] (balance × blocks) ×
    ///         scorePerTokenPerBlock, summed across all scored tokens (off-chain).
    /// @param token                  Scored ERC20 (e.g. USD8, sUSD8).
    /// @param scorePerTokenPerBlock  Score earned per whole token per block,
    ///                               1e18-scaled: 1e18 ⇒ 1.0/token/block. The
    ///                               off-chain sum divides by 1e18, cancelling
    ///                               the token's raw decimals, so score is WAD.
    ///                               e.g. 1e18/7200 ⇒ 1.0 per token per day on a
    ///                               12s-block chain.
    /// @param startBlock             Block from which to begin counting.
    struct ScoredToken {
        IERC20 token;
        uint128 scorePerTokenPerBlock;
        uint64 startBlock;
    }

    /// @notice Tokens whose holding accrues a USD8 insurance score. Global,
    ///         timelock-managed; frozen while the pool is locked for an incident.
    ///         Products snapshot this at incident open. Read via {getScoredTokens}.
    ScoredToken[] internal scoredTokens;

    /// @notice Canonical, cumulative record of insurance score a user has already
    ///         spent. Score is EARNED off-chain (time-weighted holding of the
    ///         scored tokens) and SPENT here as part of {payClaim}: a product reads
    ///         available = earnedOffChain − insuranceScoreSpent[user]. Monotonic
    ///         per user. Lives in the pool (the shared base) so every product
    ///         draws from one budget without double-spending the same score.
    mapping(address user => uint256) public insuranceScoreSpent;

    /// @notice Canonical ERC-1155 booster collection (USD8Booster) address.
    ///         Committing boosters on a claim boosts a claimant's insurance score.
    ///         Lives here as the single source of truth shared by every payout
    ///         module; products read it (via {boosterNFT}) to escrow/burn/return
    ///         committed boosters. Timelock-settable; zero disables booster commits.
    address public boosterNFT;

    // ─────────────────────────── State (payout modules) ───────────────────────────

    /// @notice Registered insurance products (payout modules) allowed to
    ///         {lockPool} and {payClaim}. Timelock-managed. A payout module can
    ///         move pooled capital, so it is fully trusted.
    mapping(address module => bool) public isPayoutModule;

    /// @notice The payout module currently holding the pool for an in-flight
    ///         incident, or 0 if none. The freeze is active while this module
    ///         reports {IPayoutModule.incidentActive}. Cleared implicitly: a new
    ///         {lockPool} can take over once the prior holder is no longer active.
    address public activePayoutModule;

    /// @notice USD8 committed to staker rewards but not yet paid out (undripped
    ///         emissions + accrued-unclaimed). Lets {sweep} treat USD8 above this
    ///         reserve as recoverable while committed rewards stay untouchable.
    uint256 public rewardReserve;

    /// @notice Per-asset target APY (bps) for stakers. Caps the asset's size so
    ///         its yield (≈ profit streamed to it ÷ its size) stays at or above
    ///         this target: the live cap, in the asset's own units, is
    ///         rewardRate × SECONDS_PER_YEAR / targetAPY, converted via the
    ///         asset's USD feed. 0 = uncapped. Profit drives the cap directly,
    ///         so it self-adjusts every distribution and grows with the protocol.
    ///         Orthogonal to {coverPoolAssetWeight} (the asset's profit SHARE).
    ///         See {coverPoolAssetSizeCap}.
    mapping(IERC20 asset => uint256) public coverPoolAssetTargetApyBps;

    // ─────────────────────────── Errors ──────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error InvalidRewardsDuration();
    error TokenConflict();
    error CoverPoolAssetNotApproved(IERC20 asset);
    error CoverPoolAssetAlreadyApproved(IERC20 asset);
    error CoverPoolAssetHasShares(IERC20 asset, uint256 shares);
    error NoEligibleStakers();
    error InsufficientShares(uint256 requested, uint256 available);
    error RewardRateTooHigh();
    error UnauthorizedTimelock(address caller);
    error UnauthorizedAdmin(address caller);
    error ScoredTokenNotFound(IERC20 token);
    error ScoredTokenExists(IERC20 token);
    error NoUnstakeRequest();
    error UnstakeRequestExists();
    error CooldownNotElapsed();
    error PoolFrozen();
    error NotPayoutModule(address caller);
    error NotActivePayoutModule(address caller);
    error PayoutRowLengthMismatch(uint256 given, uint256 expected);
    error PayoutExceedsPoolAssets(IERC20 asset, uint256 requested, uint256 available);
    error CoverPoolAssetCapExceeded(IERC20 asset, uint256 cap, uint256 attempted);
    error NothingToSweep(IERC20 token);

    // ─────────────────────────── Events ──────────────────────────

    event CoverPoolAssetAdded(IERC20 indexed asset);
    event CoverPoolAssetRemoved(IERC20 indexed asset);
    event CoverPoolAssetUsdPriceFeedSet(IERC20 indexed asset, address usdPriceFeed);
    event CoverPoolAssetWeightSet(IERC20 indexed asset, uint256 weight);
    event CoverPoolAssetTargetApySet(IERC20 indexed asset, uint256 targetApyBps);
    event ScoredTokenSet(IERC20 indexed token, uint128 scorePerTokenPerBlock, uint64 startBlock);
    event ScoredTokenRemoved(IERC20 indexed token);
    event BoosterNFTSet(address indexed oldBooster, address indexed newBooster);
    event Staked(IERC20 indexed asset, address indexed user, uint256 amount, uint256 sharesMinted);
    event UnstakeRequested(IERC20 indexed asset, address indexed user, uint256 shares);
    event UnstakeCancelled(IERC20 indexed asset, address indexed user, uint256 shares);
    event Unstaked(IERC20 indexed asset, address indexed user, uint256 shares, uint256 assetsOut);
    event YieldWithdrawn(IERC20 indexed asset, address indexed user, uint256 amount);
    event RewardNotified(IERC20 indexed asset, uint256 amount, uint128 newRate, uint64 newPeriodFinish);
    event RewardsDurationSet(uint64 oldDuration, uint64 newDuration);

    /// @notice Emitted when a registered payout module records consumed insurance score.
    event InsuranceScoreSpent(address indexed user, uint256 amount);

    /// @notice Emitted by {payClaim} for each stake asset paid out to a claimant.
    event ClaimPaid(address indexed to, IERC20 indexed asset, uint256 amount);

    /// @notice Emitted when the timelock registers/deregisters a payout module.
    event PayoutModuleSet(address indexed module, bool allowed);

    /// @notice Emitted by {sweep} when non-accountable tokens are swept.
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

    modifier onlyPayoutModule() {
        if (!isPayoutModule[msg.sender]) revert NotPayoutModule(msg.sender);
        _;
    }

    // ─────────────────────────── Constructor / initializer ─────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. Callable once.
    /// @param _usd8       USD8 token address — paid to stakers as reward emissions.
    ///                    Non-zero; set once.
    /// @param _timelock   Slow governance role (TimelockController); authorizes
    ///                    UUPS upgrades.
    /// @param _admin      Fast operational role.
    /// @param _boosterNFT Canonical booster collection (zero to disable commits
    ///                    until set via {setBoosterNFT}).
    function initialize(IERC20 _usd8, address _timelock, address _admin, address _boosterNFT) external initializer {
        if (address(_usd8) == address(0) || _timelock == address(0) || _admin == address(0)) revert ZeroAddress();
        usd8 = _usd8;
        timelock = _timelock;
        admin = _admin;
        boosterNFT = _boosterNFT;
        rewardsDuration = 7 days;
    }

    function _authorizeUpgrade(address) internal override onlyTimelock {}

    // ═══════════════════════════ Insurance-score token management (timelock) ═══════════════════════════

    /// @notice Add a token to the USD8 insurance-score set (the off-chain script
    ///         computes score from this token's holding history). Timelock only;
    ///         frozen while the pool is locked. Reverts on a duplicate.
    /// @param token                  ERC20 whose holding accrues score (non-zero).
    /// @param scorePerTokenPerBlock  Score earned per whole token per block,
    ///                               1e18-scaled: 1e18 ⇒ 1.0/token/block. The
    ///                               off-chain sum divides by 1e18, cancelling
    ///                               the token's raw decimals, so score is WAD.
    ///                               for USD8, 138888888888889 ≈ 1.0 per token per day on a 12s-block chain.
    ///                               for sUSD8, 13888888888889 ≈ 0.1 per token per day on a 12s-block chain.
    /// @param startBlock             Block from which to begin counting.
    function addScoredToken(IERC20 token, uint128 scorePerTokenPerBlock, uint64 startBlock) external onlyTimelock {
        if (_incidentActive()) revert PoolFrozen();
        if (address(token) == address(0)) revert ZeroAddress();
        uint256 n = scoredTokens.length;
        for (uint256 i = 0; i < n; i++) {
            if (scoredTokens[i].token == token) revert ScoredTokenExists(token);
        }
        scoredTokens.push(
            ScoredToken({token: token, scorePerTokenPerBlock: scorePerTokenPerBlock, startBlock: startBlock})
        );
        emit ScoredTokenSet(token, scorePerTokenPerBlock, startBlock);
    }

    /// @notice Update a scored token's rate and start block. Timelock only;
    ///         frozen while the pool is locked.
    /// @param token                  Scored token to update.
    /// @param scorePerTokenPerBlock  New score earned per token per block.
    /// @param startBlock             New block from which to begin counting.
    function updateScoredToken(IERC20 token, uint128 scorePerTokenPerBlock, uint64 startBlock) external onlyTimelock {
        if (_incidentActive()) revert PoolFrozen();
        uint256 n = scoredTokens.length;
        for (uint256 i = 0; i < n; i++) {
            if (scoredTokens[i].token == token) {
                scoredTokens[i].scorePerTokenPerBlock = scorePerTokenPerBlock;
                scoredTokens[i].startBlock = startBlock;
                emit ScoredTokenSet(token, scorePerTokenPerBlock, startBlock);
                return;
            }
        }
        revert ScoredTokenNotFound(token);
    }

    /// @notice Remove a token from the score set. Timelock only; frozen while the
    ///         pool is locked. Swap-and-pop.
    /// @param token  Scored token to remove.
    function removeScoredToken(IERC20 token) external onlyTimelock {
        if (_incidentActive()) revert PoolFrozen();
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

    /// @notice Set the canonical booster NFT collection that payout modules use
    ///         for score-boost commits. Timelock only; blocked while the pool is
    ///         frozen for an incident. Zero disables future commits.
    /// @dev    Safe to repoint regardless: each claim snapshots the collection it
    ///         escrowed into ({DefiInsurance.Claim.boosterCollection}) and
    ///         burns/returns against that snapshot, so a change never strands
    ///         already-escrowed boosters — even ones recovered long after via
    ///         {withdrawNonFinalizedClaim}. The freeze here is belt-and-suspenders.
    /// @param newBooster  New booster NFT address (zero to disable).
    function setBoosterNFT(address newBooster) external onlyTimelock {
        if (_incidentActive()) revert PoolFrozen();
        emit BoosterNFTSet(boosterNFT, newBooster);
        boosterNFT = newBooster;
    }

    /// @notice Sweep the entire non-accountable balance of a token to a recipient.
    ///         Admin or timelock. Anything above the protocol's accountable
    ///         balance is sweepable: staked principal for a stake asset, or the
    ///         committed {rewardReserve} for USD8 — so blindly-sent USD8 above
    ///         the reserve is recoverable while committed rewards and staked
    ///         principal stay untouchable. Strays are inert (accounting is
    ///         internal, not balanceOf) — pure recovery, not a safety mechanism.
    /// @param token   Token to sweep the non-accountable balance of.
    /// @param to      Recipient (non-zero).
    function sweep(IERC20 token, address to) external onlyAdminOrTimelock nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 accountable = token == usd8 ? rewardReserve : coverPoolAssets[token].totalAssets;
        uint256 bal = token.balanceOf(address(this));
        uint256 stray = bal > accountable ? bal - accountable : 0;
        if (stray == 0) revert NothingToSweep(token);
        token.safeTransfer(to, stray);
        emit Swept(token, to, stray);
    }

    // ═══════════════════════════ Payout module registry + hooks ═══════════════════════════

    /// @notice Register or deregister an insurance product as a payout module.
    ///         Timelock only. A payout module can lock the pool, pay claims out
    ///         of pooled capital, and record spent score — fully trusted.
    /// @param module   Product contract (e.g. {DefiInsurance}).
    /// @param allowed  True to permit, false to revoke.
    function setPayoutModule(address module, bool allowed) external onlyTimelock {
        if (module == address(0)) revert ZeroAddress();
        isPayoutModule[module] = allowed;
        emit PayoutModuleSet(module, allowed);
    }

    /// @notice Claim the pool for the caller's incident, freezing LP withdrawals
    ///         and asset/score curation. Payout module only. Exclusive: reverts
    ///         while the current holder still has an active incident — so a module
    ///         must call this BEFORE recording its own new incident (otherwise its
    ///         own {incidentActive} would already read true and block it). The
    ///         lock releases implicitly once the holder's {incidentActive} returns
    ///         false — no explicit unlock needed.
    function lockPool() external onlyPayoutModule {
        address cur = activePayoutModule;
        if (cur != address(0) && IPayoutModule(cur).incidentActive()) revert PoolFrozen();
        activePayoutModule = msg.sender;
    }

    /// @notice Pay a settlement row out of pooled capital to a claimant AND record
    ///         the insurance score the claim consumed. Active payout module only
    ///         (the one currently holding the {lockPool} lock). Score
    ///         spend is bound to the payout here — it can never be recorded
    ///         without a claim payout, and the recorded amount is the payout
    ///         weight. amounts aligns to {coverPoolAssetList} (frozen for the
    ///         incident's life; length must match exactly); an amount exceeding
    ///         an asset's live {totalAssets} reverts (an honest root never
    ///         over-allocates — see the loop comment). The paid amount reduces
    ///         {totalAssets}, socializing the loss across that asset's stakers.
    ///         With the pool frozen, the balance can only shrink, so a malicious
    ///         root can at most drain the pool.
    ///         scoreSpent is monotonic in the shared ledger so the same score
    ///         can't be spent twice across products.
    /// @param to          Claimant to pay (and whose score is consumed).
    /// @param amounts     Per-asset payout row, aligned to {coverPoolAssetList}.
    /// @param scoreSpent  Insurance score this claim consumes (0 to spend none;
    ///                     capped to the claimant's availability off-chain).
    function payClaim(address to, uint256[] calldata amounts, uint256 scoreSpent)
        external
        nonReentrant
    {
        // Only the module that currently holds the lock may move capital — not any
        // sibling registered module. (We can't also require the pool be frozen here:
        // the payout module marks the final claim resolved before calling, so the
        // incident reads inactive on the last finalize.)
        if (msg.sender != activePayoutModule) revert NotActivePayoutModule(msg.sender);
        // The row must align 1:1 with the (incident-frozen) asset list — a length
        // mismatch means the payout was computed against a different list, and
        // silently truncating would pay the wrong assets.
        uint256 n = coverPoolAssetList.length;
        if (amounts.length != n) revert PayoutRowLengthMismatch(amounts.length, n);
        for (uint256 i = 0; i < n; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            IERC20 a = coverPoolAssetList[i];
            CoverPoolAssetState storage s = coverPoolAssets[a];
            // An honest root never over-allocates (off-chain math floors every
            // division and the frozen pool only shrinks via payClaim itself), so
            // exceeding the live balance means a corrupt root: fail loudly — the
            // claimant falls back to escrow recovery — instead of silently
            // underpaying while still forfeiting their escrow.
            if (amount > s.totalAssets) revert PayoutExceedsPoolAssets(a, amount, s.totalAssets);
            s.totalAssets -= amount;
            a.safeTransfer(to, amount);
            emit ClaimPaid(to, a, amount);
        }

        if (scoreSpent != 0) {
            insuranceScoreSpent[to] += scoreSpent;
            emit InsuranceScoreSpent(to, scoreSpent);
        }
    }

    // ═══════════════════════════ Cover Pool asset staking ═══════════════════════════
    //
    //   Which assets may be staked (timelock curation) and the staker operations
    //   on them. STAKING / UNSTAKING — underwriters deposit assets, earn USD8
    //   yield, and absorb claim losses pro-rata. A claim payout lowers
    //   totalAssets but not totalShares, so assets-per-share drops for every
    //   holder at once.

    // ─── Asset curation (timelock) ───

    /// @notice Approve a new stake asset. Timelock only. Must be non-zero, not
    ///         USD8, and not already approved. No on-chain oracle — pricing is
    ///         computed off-chain at settlement. Must be a standard ERC20:
    ///         fee-on-transfer and rebasing tokens are NOT supported.
    /// @dev    Frozen while the pool is locked for an incident: the stake-asset
    ///         set must stay fixed so a settlement stays aligned to the live list.
    /// @param asset         Stake asset to approve.
    /// @param usdPriceFeed  Chainlink-style USD price feed (non-zero).
    /// @param weight        Profit-distribution weight (0 = earns no profit share).
    /// @param targetApyBps  Target staker APY (bps) used to size the deposit cap
    ///                      (0 = uncapped). See {coverPoolAssetTargetApyBps}.
    function addCoverPoolAsset(IERC20 asset, address usdPriceFeed, uint256 weight, uint256 targetApyBps)
        external
        onlyTimelock
    {
        if (_incidentActive()) revert PoolFrozen();
        if (address(asset) == address(0) || usdPriceFeed == address(0)) revert ZeroAddress();
        if (address(asset) == address(usd8)) revert TokenConflict(); //usd8 and sUSD8 are not good fit for this design. Besides needing USD oralces, USD8 balance in contract would be mixed with existing profit distribution, problem. So do not add USD8/sUSD8 as staking assets.
        if (coverPoolAssets[asset].usdPriceFeed != address(0)) revert CoverPoolAssetAlreadyApproved(asset);
        coverPoolAssets[asset].usdPriceFeed = usdPriceFeed;
        coverPoolAssetList.push(asset);
        coverPoolAssetWeight[asset] = weight;
        coverPoolAssetTargetApyBps[asset] = targetApyBps;
        emit CoverPoolAssetAdded(asset);
        emit CoverPoolAssetUsdPriceFeedSet(asset, usdPriceFeed);
        emit CoverPoolAssetWeightSet(asset, weight);
        emit CoverPoolAssetTargetApySet(asset, targetApyBps);
    }

    /// @notice Set a stake asset's target staker APY (bps), which sizes its
    ///         deposit cap (see {coverPoolAssetTargetApyBps}). Admin or timelock,
    ///         adjustable any time — it only moves a soft deposit gate, never
    ///         payouts. 0 removes the cap. Existing stake is never force-removed;
    ///         only future {stake} above the new cap is blocked.
    /// @param asset         Approved stake asset to update.
    /// @param targetApyBps  New target APY in basis points (0 = uncapped).
    function setCoverPoolAssetTargetApy(IERC20 asset, uint256 targetApyBps) external onlyAdminOrTimelock {
        if (coverPoolAssets[asset].usdPriceFeed == address(0)) revert CoverPoolAssetNotApproved(asset);
        coverPoolAssetTargetApyBps[asset] = targetApyBps;
        emit CoverPoolAssetTargetApySet(asset, targetApyBps);
    }

    /// @notice Set a stake asset's profit-distribution weight. Admin or
    ///         timelock — it only re-splits FUTURE profit distributions across
    ///         assets (never principal, payouts, or settlement math). Frozen
    ///         while the pool is locked.
    /// @param asset   Approved stake asset to update.
    /// @param weight  New profit-distribution weight (0 = earns no profit share).
    function setCoverPoolAssetWeight(IERC20 asset, uint256 weight) external onlyAdminOrTimelock {
        if (_incidentActive()) revert PoolFrozen();
        if (coverPoolAssets[asset].usdPriceFeed == address(0)) revert CoverPoolAssetNotApproved(asset);
        coverPoolAssetWeight[asset] = weight;
        emit CoverPoolAssetWeightSet(asset, weight);
    }

    /// @notice Update a stake asset's USD price feed. Timelock only — the
    ///         off-chain settler prices pool assets with this feed at window-end,
    ///         so it shapes claim payouts, not just the stake-size cap. Frozen
    ///         while the pool is locked.
    /// @param asset         Approved stake asset to update.
    /// @param usdPriceFeed  New Chainlink-style USD price feed (non-zero).
    function setCoverPoolAssetUsdPriceFeed(IERC20 asset, address usdPriceFeed) external onlyTimelock {
        if (_incidentActive()) revert PoolFrozen();
        if (coverPoolAssets[asset].usdPriceFeed == address(0)) revert CoverPoolAssetNotApproved(asset);
        if (usdPriceFeed == address(0)) revert ZeroAddress();
        coverPoolAssets[asset].usdPriceFeed = usdPriceFeed;
        emit CoverPoolAssetUsdPriceFeedSet(asset, usdPriceFeed);
    }

    /// @notice Remove an approved stake asset. Timelock only. Requires
    ///         totalShares == 0. Frozen while the pool is locked.
    /// @param asset  Approved stake asset to remove (must have zero shares).
    function removeCoverPoolAsset(IERC20 asset) external onlyTimelock {
        if (_incidentActive()) revert PoolFrozen();
        CoverPoolAssetState storage s = coverPoolAssets[asset];
        if (s.usdPriceFeed == address(0)) revert CoverPoolAssetNotApproved(asset);
        if (s.totalShares != 0) revert CoverPoolAssetHasShares(asset, s.totalShares);

        s.usdPriceFeed = address(0);
        delete coverPoolAssetWeight[asset];
        uint256 n = coverPoolAssetList.length;
        for (uint256 i = 0; i < n; i++) {
            if (coverPoolAssetList[i] == asset) {
                coverPoolAssetList[i] = coverPoolAssetList[n - 1];
                coverPoolAssetList.pop();
                break;
            }
        }
        emit CoverPoolAssetRemoved(asset);
    }

    // ─── Staking ───

    /// @notice Stake amount of asset. Shares minted at the current price-per-
    ///         share: 1:1 when the pool is empty, else amount × totalShares /
    ///         totalAssets. Blocked while the pool is frozen — with staking and
    ///         {completeUnstake} both frozen for the incident's life, the balance
    ///         can only shrink, so a settled root can never reach later capital.
    /// @param asset         Approved stake asset to deposit.
    /// @param amount        Amount to pull from the caller (must be approved).
    /// @return sharesMinted Shares credited for the amount actually received.
    function stake(IERC20 asset, uint256 amount) external nonReentrant returns (uint256 sharesMinted) {
        if (amount == 0) revert ZeroAmount();
        if (_incidentActive()) revert PoolFrozen();
        CoverPoolAssetState storage s = coverPoolAssets[asset];
        if (s.usdPriceFeed == address(0)) revert CoverPoolAssetNotApproved(asset);

        // Keep the asset's size at or below its target-APY cap (soft gate).
        // Checked against amount up front (fail early, before checkpoints and
        // the pull): stake assets are standard ERC20s, so amount == received.
        uint256 cap = coverPoolAssetSizeCap(asset);
        if (s.totalAssets + amount > cap) revert CoverPoolAssetCapExceeded(asset, cap, s.totalAssets + amount);

        _checkpointReward(s);
        _checkpointUser(asset, msg.sender);

        uint256 received = _pullToken(asset, msg.sender, amount);
        if (received == 0) revert ZeroAmount();

        // Price-per-share = totalAssets / totalShares. A claim payout can drain an
        // asset to totalAssets == 0 while shares are still outstanding (e.g. a holder
        // who never exits). The normal branch would then divide by zero and brick the
        // asset forever: no one can stake, and the asset can't be removed while shares
        // remain. So when fully drained, mint as if each existing share is worth ~0 —
        // received * totalShares — which lets fresh capital recapitalize the asset. The
        // dead shares collectively reclaim only received/(1+received) < 1 base unit (a
        // sub-wei rounding crumb, independent of how many dead shares exist).
        sharesMinted = s.totalShares == 0
            ? received
            : s.totalAssets == 0
                ? received * s.totalShares
                : (received * s.totalShares) / s.totalAssets;

        s.totalAssets += received;
        s.totalShares += sharesMinted;
        userAssetState[asset][msg.sender].shares += sharesMinted;

        emit Staked(asset, msg.sender, received, sharesMinted);
    }

    /// @notice File an intent to unstake shares of asset. Starts the 7-day
    ///         cooldown. The shares stay exposed to payouts but STOP earning
    ///         rewards until the request completes or is cancelled.
    /// @param asset   Stake asset to unstake from.
    /// @param shares  Shares to queue for redemption (≤ caller's balance).
    function requestUnstake(IERC20 asset, uint256 shares) external {
        if (shares == 0) revert ZeroAmount();
        CoverPoolAssetState storage s = coverPoolAssets[asset];
        UserAssetState storage u = userAssetState[asset][msg.sender];
        if (u.shares < shares) revert InsufficientShares(shares, u.shares);
        if (unstakeRequests[asset][msg.sender].shares != 0) revert UnstakeRequestExists();

        _checkpointReward(s);
        _checkpointUser(asset, msg.sender);
        s.unstakingShares += shares;

        unstakeRequests[asset][msg.sender] = UnstakeRequest({shares: shares, requestedAt: uint64(block.timestamp)});

        emit UnstakeRequested(asset, msg.sender, shares);
    }

    /// @notice Cancel a pending unstake request. The shares resume earning
    ///         rewards from now; only the request record is cleared.
    /// @param asset  Stake asset whose pending request to cancel.
    function cancelUnstakeRequest(IERC20 asset) external {
        UnstakeRequest memory r = unstakeRequests[asset][msg.sender];
        if (r.shares == 0) revert NoUnstakeRequest();

        CoverPoolAssetState storage s = coverPoolAssets[asset];
        _checkpointReward(s);
        _checkpointUser(asset, msg.sender);
        s.unstakingShares -= r.shares;

        delete unstakeRequests[asset][msg.sender];
        emit UnstakeCancelled(asset, msg.sender, r.shares);
    }

    /// @notice Redeem the shares in a matured unstake request. Requires the
    ///         cooldown elapsed AND the pool not frozen. Pays at the live
    ///         price-per-share. Pending yield is checkpointed, not paid —
    ///         it stays claimable via {withdrawYield} (separate action).
    /// @param asset      Stake asset whose matured request to redeem.
    /// @return assetsOut Amount of asset transferred to the caller.
    function completeUnstake(IERC20 asset) external nonReentrant returns (uint256 assetsOut) {
        UnstakeRequest memory r = unstakeRequests[asset][msg.sender];
        if (r.shares == 0) revert NoUnstakeRequest();
        if (block.timestamp < uint256(r.requestedAt) + UNSTAKE_COOLDOWN) revert CooldownNotElapsed();
        if (_incidentActive()) revert PoolFrozen();

        CoverPoolAssetState storage s = coverPoolAssets[asset];
        // Checkpoint only: materialize accrued yield into u.rewards at the
        // pre-reduction share count. Claiming stays a separate action.
        _checkpointReward(s);
        _checkpointUser(asset, msg.sender);

        UserAssetState storage u = userAssetState[asset][msg.sender];
        if (u.shares < r.shares) revert InsufficientShares(r.shares, u.shares);

        assetsOut = (r.shares * s.totalAssets) / s.totalShares;

        u.shares -= r.shares;
        s.totalShares -= r.shares;
        s.unstakingShares -= r.shares;
        s.totalAssets -= assetsOut;
        delete unstakeRequests[asset][msg.sender];

        // assetsOut can round to 0 only when a claim payout has driven this
        // asset's totalAssets far below totalShares (shares are then worth ~0).
        // Still burn the shares so the staker can exit; skip the transfer both
        // because there's nothing to send and because some ERC20s revert on a
        // zero-value transfer (which would otherwise brick the exit).
        if (assetsOut > 0) asset.safeTransfer(msg.sender, assetsOut);
        emit Unstaked(asset, msg.sender, r.shares, assetsOut);
    }

    /// @notice Withdraw pending USD8 (yield) for a single asset without
    ///         touching the stake position.
    /// @param asset  Stake asset whose accrued yield to withdraw.
    /// @return reward The USD8 amount transferred to the caller.
    function withdrawYield(IERC20 asset) external nonReentrant returns (uint256 reward) {
        CoverPoolAssetState storage s = coverPoolAssets[asset];
        _checkpointReward(s);
        _checkpointUser(asset, msg.sender);

        UserAssetState storage u = userAssetState[asset][msg.sender];
        reward = u.rewards;
        if (reward == 0) return 0;
        u.rewards = 0;
        rewardReserve -= reward;
        usd8.safeTransfer(msg.sender, reward);
        emit YieldWithdrawn(asset, msg.sender, reward);
    }

    // ═══════════════════════════ Profit distribution (USD8 Treasury) ═══════════════════════════

    /// @notice Receive a USD8 profit distribution from the Treasury and stream it
    ///         to stakers, split across assets by {coverPoolAssetWeight}. Pulls
    ///         amount from msg.sender (the {IProfitDistributionReceiver}
    ///         contract: the Treasury approves then calls this). Permissionless —
    ///         anyone may donate; it always pulls from the caller.
    /// @dev    Only assets that currently have an earning base (stakers not all
    ///         unstaking) receive a share; a weighted asset with no stakers has
    ///         its share redistributed to the others (its weight is excluded from
    ///         the denominator), so the entire amount is streamed. The last
    ///         eligible asset absorbs rounding dust. Reverts if NO asset is
    ///         eligible (nothing could be streamed) so the Treasury keeps the funds.
    /// @param amount  USD8 profit to pull and stream.
    function receiveProfitDistribution(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Pass 1: sum the weights of assets that can currently earn, and find the
        // last such asset (it absorbs rounding dust).
        uint256 n = coverPoolAssetList.length;
        uint256 eligibleWeight;
        uint256 lastEligible = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            IERC20 a = coverPoolAssetList[i];
            CoverPoolAssetState storage s = coverPoolAssets[a];
            if (coverPoolAssetWeight[a] != 0 && uint256(s.totalShares) - s.unstakingShares != 0) {
                eligibleWeight += coverPoolAssetWeight[a];
                lastEligible = i;
            }
        }
        if (eligibleWeight == 0) revert NoEligibleStakers();

        usd8.safeTransferFrom(msg.sender, address(this), amount);
        rewardReserve += amount;

        // Pass 2: stream each eligible asset its pro-rata profit share. Integer
        // division truncates, so summing amount * w / eligibleWeight over all
        // assets would fall a few wei short and leave that dust pulled-but-never-
        // streamed (stuck in rewardReserve). The LAST eligible asset instead takes
        // the remainder (amount - distributed) — its true weight share plus the
        // accumulated truncation dust (at most ~(eligibleCount-1) wei) — so the
        // full amount is always streamed.
        uint256 distributed;
        for (uint256 i = 0; i < n; i++) {
            IERC20 a = coverPoolAssetList[i];
            CoverPoolAssetState storage s = coverPoolAssets[a];
            uint256 w = coverPoolAssetWeight[a];
            if (w == 0 || uint256(s.totalShares) - s.unstakingShares == 0) continue;
            uint256 profitShare = i == lastEligible ? amount - distributed : (amount * w) / eligibleWeight;
            distributed += profitShare;
            _streamReward(s, a, profitShare);
        }
    }

    /// @dev Stream amount USD8 to asset's stakers, folding any undripped
    ///      leftover into a new rate. Assumes USD8 already received and a non-zero
    ///      earning base (caller ensures both). The new end-time is a weighted
    ///      average of the remaining schedule (for the leftover) and a fresh
    ///      rewardsDuration (for amount), weighted by their USD8 amounts — so a
    ///      tiny donation barely moves the schedule (a 1-wei call can't reset
    ///      periodFinish to a full fresh window and stretch/dilute the funded
    ///      emission), while a large amount still behaves like a fresh window.
    function _streamReward(CoverPoolAssetState storage s, IERC20 asset, uint256 amount) internal {
        _checkpointReward(s);

        uint256 remaining = block.timestamp < s.periodFinish ? s.periodFinish - block.timestamp : 0;
        uint256 leftover = remaining * s.rewardRate; // undripped USD8 in the current window
        uint256 total = leftover + amount;
        if (total == 0) return; // nothing to stream (zero share to an asset)
        uint256 newDuration = (leftover * remaining + amount * rewardsDuration) / total;
        if (newDuration == 0) newDuration = rewardsDuration; // defensive (only the remaining==0 path)
        uint256 newRate = total / newDuration;
        if (newRate > type(uint128).max) revert RewardRateTooHigh();

        s.rewardRate = uint128(newRate);
        s.lastUpdateTime = uint64(block.timestamp);
        s.periodFinish = uint64(block.timestamp + newDuration);

        emit RewardNotified(asset, amount, uint128(newRate), s.periodFinish);
    }

    /// @notice Set the emission window for future profit distributions. Admin or
    ///         timelock. In-flight emissions are unaffected.
    /// @param newDuration  New emission window in seconds (non-zero).
    function setRewardsDuration(uint64 newDuration) external onlyAdminOrTimelock {
        if (newDuration == 0) revert InvalidRewardsDuration();
        emit RewardsDurationSet(rewardsDuration, newDuration);
        rewardsDuration = newDuration;
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

    /// @notice The full approved stake-asset list (settlement amounts[] align
    ///         to this order; stable while the pool is frozen).
    function getCoverPoolAssetList() external view returns (IERC20[] memory) {
        return coverPoolAssetList;
    }

    /// @notice True if asset is an approved stake asset.
    function isCoverPoolAsset(IERC20 asset) external view returns (bool) {
        return coverPoolAssets[asset].usdPriceFeed != address(0);
    }

    /// @notice Sum of all stake-asset profit-distribution weights, computed from
    ///         the live {coverPoolAssetWeight} entries (cannot drift).
    function totalAssetWeight() external view returns (uint256 total) {
        uint256 n = coverPoolAssetList.length;
        for (uint256 i = 0; i < n; i++) {
            total += coverPoolAssetWeight[coverPoolAssetList[i]];
        }
    }

    /// @notice All approved stake assets with their profit-distribution weights,
    ///         as parallel arrays in {coverPoolAssetList} order.
    /// @return assets   The approved stake assets.
    /// @return weights  Each asset's {coverPoolAssetWeight} (aligned to assets).
    function getCoverPoolAssets() external view returns (IERC20[] memory assets, uint256[] memory weights) {
        uint256 n = coverPoolAssetList.length;
        assets = coverPoolAssetList;
        weights = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            weights[i] = coverPoolAssetWeight[assets[i]];
        }
    }

    /// @notice The full USD8 insurance-score token set. See {ScoredToken}.
    function getScoredTokens() external view returns (ScoredToken[] memory) {
        return scoredTokens;
    }

    /// @notice Number of scored tokens.
    function scoredTokensLength() external view returns (uint256) {
        return scoredTokens.length;
    }

    /// @notice Cumulative reward-per-share for asset now, scaled by {REWARD_SCALE}.
    function rewardPerShare(IERC20 asset) external view returns (uint256) {
        return _rewardPerShare(coverPoolAssets[asset]);
    }

    /// @notice USD8 amount user would receive on {withdrawYield}(asset)
    ///         now. Shares under a pending unstake request are excluded.
    function earned(IERC20 asset, address user) public view returns (uint256) {
        UserAssetState storage u = userAssetState[asset][user];
        uint256 earningShares = uint256(u.shares) - unstakeRequests[asset][user].shares;
        return (earningShares * (_rewardPerShare(coverPoolAssets[asset]) - u.userRewardPerSharePaid)) / REWARD_SCALE
            + u.rewards;
    }

    /// @notice Total shares outstanding for asset.
    function totalShares(IERC20 asset) external view returns (uint256) {
        return coverPoolAssets[asset].totalShares;
    }

    /// @notice Actual asset tokens held backing those shares.
    function totalAssets(IERC20 asset) external view returns (uint256) {
        return coverPoolAssets[asset].totalAssets;
    }

    /// @notice Shares currently held by user in asset.
    function userShares(IERC20 asset, address user) external view returns (uint256) {
        return userAssetState[asset][user].shares;
    }

    /// @notice Number of currently-approved stake assets.
    function coverPoolAssetListLength() external view returns (uint256) {
        return coverPoolAssetList.length;
    }

    /// @notice True while the pool is frozen for an in-flight incident
    ///         ({completeUnstake}, staking, and curation are blocked).
    function frozen() external view returns (bool) {
        return _incidentActive();
    }

    /// @notice Live maximum stakeable size for asset, in the asset's own units.
    ///         Derived from the asset's reward rate and target APY:
    ///         rewardRate × SECONDS_PER_YEAR / targetAPY, converted to asset
    ///         units via the USD feed. Returns type(uint256).max (uncapped)
    ///         when the target is 0, no profit is streaming yet (bootstrap), or
    ///         the feed is unavailable (fail-open — a bad oracle never blocks
    ///         staking). {stake} rejects deposits that would exceed this.
    /// @param asset  Approved stake asset to query.
    function coverPoolAssetSizeCap(IERC20 asset) public view returns (uint256) {
        uint256 apyBps = coverPoolAssetTargetApyBps[asset];
        CoverPoolAssetState storage s = coverPoolAssets[asset];
        if (apyBps == 0 || s.rewardRate == 0) return type(uint256).max;
        uint256 priceWad = _assetPriceWad(s.usdPriceFeed);
        if (priceWad == 0) return type(uint256).max;
        // capUsd is the asset size (1e18 USD) whose target-APY yield equals the
        // asset's annualized reward stream; convert to the asset's own units.
        // Stake assets are timelock-curated standard ERC20s, so decimals() is trusted.
        uint256 capUsd = (uint256(s.rewardRate) * SECONDS_PER_YEAR * BPS) / apyBps;
        return (capUsd * (10 ** IERC20Metadata(address(asset)).decimals())) / priceWad;
    }

    /// @notice How much more of asset can be staked before its cap is hit
    ///         (0 when full, uncapped reports the remaining headroom up to max).
    /// @param asset  Approved stake asset to query.
    function coverPoolAssetRemainingCapacity(IERC20 asset) external view returns (uint256) {
        uint256 cap = coverPoolAssetSizeCap(asset);
        uint256 size = coverPoolAssets[asset].totalAssets;
        return cap > size ? cap - size : 0;
    }

    /// @dev USD price per whole feed token, normalized to 1e18. Returns 0
    ///      (treated as uncapped by callers) if the feed reverts, is missing, or
    ///      reports a non-positive / oversized-decimals answer — fail-open.
    function _assetPriceWad(address feed) internal view returns (uint256) {
        try IAggregatorV3(feed).decimals() returns (uint8 fd) {
            if (fd > 18) return 0;
            try IAggregatorV3(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
                if (answer <= 0) return 0;
                return uint256(answer) * (10 ** (18 - fd));
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    // ═══════════════════════════ Internal: reward math ═══════════════════════════

    /// @dev Cumulative reward-per-share for s now, including pending emission.
    function _rewardPerShare(CoverPoolAssetState storage s) internal view returns (uint256) {
        uint256 earningShares = uint256(s.totalShares) - s.unstakingShares;
        if (earningShares == 0) return s.rewardPerShareStored;
        uint256 t = block.timestamp < s.periodFinish ? block.timestamp : s.periodFinish;
        if (t <= s.lastUpdateTime) return s.rewardPerShareStored;
        return s.rewardPerShareStored + ((t - s.lastUpdateTime) * uint256(s.rewardRate) * REWARD_SCALE) / earningShares;
    }

    /// @dev Roll s.rewardPerShareStored forward to now. When no shares are
    ///      earning (the whole base is unstaking or absent), the emission that
    ///      would have streamed over the elapsed interval has no recipients;
    ///      rather than strand it, defer it by pushing periodFinish out by the
    ///      same span so it re-streams once an earning base returns
    ///      (Synthetix-style carry-forward) — otherwise that USD8 would be locked
    ///      in rewardReserve forever.
    function _checkpointReward(CoverPoolAssetState storage s) internal {
        uint256 earningShares = uint256(s.totalShares) - s.unstakingShares;
        uint256 t = block.timestamp < s.periodFinish ? block.timestamp : s.periodFinish;
        if (t > s.lastUpdateTime) {
            if (earningShares == 0) {
                if (s.rewardRate != 0) s.periodFinish += uint64(t - s.lastUpdateTime);
            } else {
                s.rewardPerShareStored += ((t - s.lastUpdateTime) * uint256(s.rewardRate) * REWARD_SCALE) / earningShares;
            }
        }
        // Reuse t (computed against the PRE-extension periodFinish): after a
        // deferral the re-stream window must start where emission stopped, so
        // the extended window re-emits the full deferred span. Recomputing the
        // min against the extended periodFinish would set lastUpdateTime past
        // t and permanently strand the gap's emission in rewardReserve.
        s.lastUpdateTime = uint64(t);
    }

    /// @dev Materialize the user's outstanding reward and snapshot the accumulator.
    function _checkpointUser(IERC20 asset, address user) internal {
        UserAssetState storage u = userAssetState[asset][user];
        u.rewards = earned(asset, user);
        u.userRewardPerSharePaid = coverPoolAssets[asset].rewardPerShareStored;
    }

    /// @dev Pull amount of token from from, returning the balance delta
    ///      actually received (a fee-on-transfer safety net). Runs under {nonReentrant}.
    function _pullToken(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
    }

    // ═══════════════════════════ Internal: incident freeze ═══════════════════════════

    /// @dev True while the active payout module reports an in-flight incident. Releases
    ///      automatically (lazy + time-based) when the payout module's incident ends.
    ///      The registration check runs BEFORE the external call and doubles as the
    ///      emergency brake: a module that freezes the pool forever — or reverts in
    ///      incidentActive() — is neutralized by timelock-deregistering it
    ///      ({setPayoutModule}). A module holds the pool only while it stays registered.
    function _incidentActive() internal view returns (bool) {
        address cur = activePayoutModule;
        return cur != address(0) && isPayoutModule[cur] && IPayoutModule(cur).incidentActive();
    }
}
