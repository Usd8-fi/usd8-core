// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../src/Registry.sol";
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {USD8SavingsBootstrap} from "../src/deployment/USD8SavingsBootstrap.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {USD8PriceOracle} from "../src/oracles/USD8PriceOracle.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title 02 — Deploy USD8 System
/// @notice Second deployment step. Uses the TimelockController deployed by
///         `01_DeployTimelock.s.sol`, then deploys Registry, USD8 (proxy + impl),
///         Treasury (UUPS proxy + impl,
///         with two USDC yield strategies — Aave + Morpho), an official Morpho
///         Vault V2 savings share token (symbol `sUSD8`) with a custom idle/profit adapter,
///         a wstETH SingleAssetCoverPool
///         behind an UpgradeableBeacon (the capital base), and DefiInsurance (the
///         single payout module). Scored tokens (USD8, sUSD8), launch insured
///         tokens, and the booster are configured during deployment. Extra insured
///         tokens and cover pools remain timelock-governed additions.
///
/// @dev    Set TIMELOCK_ADDRESS to the verified step-01 deployment before running.
///         Governance split: the timelock role is a real OZ TimelockController
///         (minDelay {EXPECTED_TIMELOCK_MIN_DELAY}; sole proposer/canceller
///         {DEFAULT_ADMIN}; open execution; self-administered — admin param
///         address(0), so delay/role changes go through its own delayed
///         proposals). The Registry admin role stays with {DEFAULT_ADMIN} during
///         beta and is explicitly privileged: it can operate pauses, profit routing,
///         strategy allocations, and incident/root controls. This is an accepted
///         trust assumption; migrate it to a monitored Safe before real user volume.
///         All deploy parameters
///         (admin, vault addresses, rates) are hardcoded constants below —
///         edit them in-place for a different network/signer.
///
/// ════════════════════════════ HARD RULES ════════════════════════════
/// Operational invariants that are NOT (all) enforced on-chain. Whoever
/// deploys and governs the system MUST uphold these:
///
///  1. DURING BETA, TIMELOCK DELAY < DISPUTE_PERIOD. The governance timelock's
///     minDelay must be strictly less than DefiInsurance.DISPUTE_PERIOD so
///     {DefiInsurance.adminCorrectSettlement} can execute before finalization.
///     The admin can act without delay; root correction is disabled after beta.
///
///  2. KEEP A PAYOUT MODULE SET IN NORMAL OPS. The timelock replaces the module
///     via {Registry.setDefiInsurance}. Clearing it to zero is reserved as the
///     emergency brake for a module stuck reporting an incident — outside that,
///     never leave the slot empty.
///
///  3. NO DEFIINSURANCE WIRING CHANGES DURING AN ACTIVE INCIDENT. Do not
///     change/upgrade or re-point the DefiInsurance payout module registered
///     while an incident is in flight.
///
///  4. ONE INCIDENT AT A TIME — WAIT OUT FINALIZATION. Do not open a new
///     incident until the prior incident's finalization window has fully
///     closed. Keeps incidents cleanly isolated (the pool is only ever frozen
///     for / paid out of a single incident at once).
///
///  5. setTimelock IS IRREVERSIBLE — TRIPLE-CHECK THE ADDRESS. setTimelock is
///     single-step, and the timelock holds upgrade authority for Registry, USD8,
///     Treasury, and owns the immutable Morpho sUSD8 vault plus the pool beacon (all pools
///     upgrade through it). A wrong or
///     typo'd address permanently and unrecoverably loses governance AND
///     upgradeability. NOTE: the pool beacon is Ownable and its ownership is
///     transferred to the timelock in _handOffRoles — a separate handle from the
///     Registry timelock, so rotate BOTH on any governance migration.
///     Before calling, verify the new timelock is a live, correctly-owned
///     address/contract — on every contract. (admin is recoverable by the
///     timelock; the timelock itself is not.)
///
///  6. PRIVILEGED BETA ROLES ARE TRUSTED. DEFAULT_ADMIN proposes/cancels timelock
///     operations and retains immediate operational powers. Monitor every action,
///     use a Safe before meaningful TVL, and permanently end beta shortcuts when
///     governance is ready. Do not describe this role as deny-only.
/// ═════════════════════════════════════════════════════════════════════
contract DeployUSD8SystemScript is Script {
    error WrongChainId(uint256 actual, uint256 expected);

    error InvalidTimelockDelay(uint256 actual, uint256 expected);
    error MissingTimelockRole(bytes32 role, address account);
    error UnexpectedTimelockAdmin(address account);
    error InvalidTreasury(address candidate);
    error InvalidTreasuryBinding(address candidate, address boundUsd8, address boundRegistry);

    uint256 public constant ETHEREUM_MAINNET_CHAIN_ID = 1;

    /// @notice Savings receives no launch revenue while dead seed shares dominate
    ///         supply. Governance may raise this after meaningful organic TVL exists.
    uint256 public constant INITIAL_SAVINGS_PROFIT_WEIGHT = 0;

    /// @notice Privileged beta governance EOA: Registry admin and the
    ///         TimelockController's sole proposer/canceller. Accepted trust assumption;
    ///         migrate to a monitored Safe before meaningful TVL.
    address constant DEFAULT_ADMIN = 0xB2E999D531D45a9115dA7706adFc651999f3c1F1;

    /// @notice TimelockController minDelay. During beta, it must stay strictly under
    ///         DefiInsurance.DISPUTE_PERIOD (2 days) so timelock root correction fits.
    uint256 constant EXPECTED_TIMELOCK_MIN_DELAY = 24 hours;

    /// @notice USDC seeded into the protocol at deploy. Minted 1:1 into USD8
    ///         and deposited into the Morpho Vault V2 sUSD8 vault, with the shares
    ///         sent to {SEED_SINK}. They remain in totalSupply but are irrecoverable,
    ///         so the vault cannot be emptied to a near-zero supply and the
    ///         first-depositor inflation attack has no foothold. Backed by
    ///         real USDC, so it does NOT dilute the peg.
    ///         Deployer must hold at least this much USDC at run time.
    uint256 constant SEED_USDC = 10e6;

    /// @notice Irrecoverable holder for seed shares. It is not address(0), which
    ///         ERC20 minting rejects, and shares held here remain in totalSupply.
    address constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;

    /// @notice Insurance-score rate for the two scored tokens, 1e18-scaled
    ///         (1e18 ⇒ 1.0 score/token/block). Set for a 12s-block chain
    ///         (7200 blocks/day) so a whole token accrues, per day: USD8 → 1.0
    ///         (1e18/7200), sUSD8 → 0.1 (1e18/72000). Frontend shows rate ×
    ///         7200 / 1e18.
    uint128 constant USD8_SCORE_RATE = 138888888888889; // 1e18 / 7200  ≈ 1.0/day
    uint128 constant SUSD8_SCORE_RATE = 13888888888889; // 1e18 / 72000 ≈ 0.1/day

    /// @notice Already-deployed USD8Booster ERC-1155 collection (mainnet). Set on
    ///         the Registry as the canonical booster.
    address constant USD8_BOOSTER = 0x6f74Ce39Bb1D75C56E2fe5f349a6A5f51ce6f12d;

    /// @notice Launch cover-pool stake asset: wstETH (mainnet). Underwriters stake
    ///         wstETH to underwrite coverage; rewarded in USD8.
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice ERC-4626 USDC vaults for the two launch Treasury strategies (Aave +
    ///         Morpho). Each reports asset() == USDC (checked on mainnet), which the
    ///         ERC4626Strategy constructor also enforces.
    ///           - AAVE_USDC_VAULT   = stataEthUSDC (Aave v3 static aUSDC ERC-4626 wrapper).
    ///           - MORPHO_USDC_VAULT = steakUSDC (Steakhouse USDC MetaMorpho vault).
    ///         Re-confirm liquidity/curation before large allocations; the queue
    ///         order (Aave first) also matters for redeem-path liquidity.
    address constant AAVE_USDC_VAULT = 0x73edDFa87C71ADdC275c2b9890f5c3a8480bC9E6;
    address constant MORPHO_USDC_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    /// @notice Canonical Ethereum Morpho Vault V2 factory.
    address constant MORPHO_VAULT_V2_FACTORY = 0xA1D94F746dEfa1928926b84fB2596c06926C0405;

    /// @notice Maximum positive sUSD8 share-price growth: 20% simple annual rate, WAD per second.
    uint256 constant SUSD8_MAX_RATE = 20e16 / uint256(365 days);
    bytes32 constant SUSD8_SALT = keccak256("USD8 Savings Morpho Vault V2");

    /// @notice Launch insured ERC-4626 tokens and their underlying/USD Chainlink feeds.
    ///         Token→underlying valuation uses convertToAssets(1e18) on each vault.
    ///         Aave's legacy stkGHO (0x1a88...) is intentionally excluded in favor
    ///         of the new ERC-4626 sGHO deployment.
    address constant AAVE_SGHO = 0xE1753F2e00940cC31213dd92013cF019DFE4ca1d;
    address constant CURVE_SCRVUSD = 0x0655977FEb2f289A4aB78af67BAB0d17aAb84367;
    address constant SKY_SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant GHO_USD_ORACLE = 0xff221Bf2E61B62182210b3d42dE7f77da5b5b41F;
    address constant CRVUSD_USD_ORACLE = 0xf3A0a2363Ee3e5FC1CcF923F4eA9c06BaC1A6834;
    address constant USDS_USD_ORACLE = 0x592700e4FcDd674dC54d2681DED3B63f54F63f9A;
    address constant USDC_USD_ORACLE = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    uint128 constant INITIAL_MIN_CLAIM_AMOUNT = 1e18;

    struct InsuredTokenDeploymentConfig {
        address token;
        uint256 maxCoverageBps;
        uint128 minClaimAmount;
        address underlyingPriceOracle;
        address conversionAddress;
        bytes conversionCallData;
    }

    struct Deployed {
        TimelockController timelock;
        Registry registry;
        address usd8Impl;
        USD8 usd8;
        address treasuryImpl;
        Treasury treasury;
        IVaultV2 savings;
        address savingsAdapter;
        address savingsGate;
        address poolImpl;
        address poolBeacon;
        SingleAssetCoverPool wstethPool;
        address aaveStrategy;
        address morphoStrategy;
        DefiInsurance defiInsurance;
        address usd8PriceOracle;
    }

    function run() external {
        if (block.chainid != ETHEREUM_MAINNET_CHAIN_ID) {
            revert WrongChainId(block.chainid, ETHEREUM_MAINNET_CHAIN_ID);
        }

        address timelockAddress = vm.envAddress("TIMELOCK_ADDRESS");
        _validateTimelock(timelockAddress, DEFAULT_ADMIN);

        vm.startBroadcast();
        Deployed memory d = _deployAndWire(msg.sender, TimelockController(payable(timelockAddress)));
        _handOffRoles(d, msg.sender, DEFAULT_ADMIN);
        vm.stopBroadcast();

        _logResults(d, DEFAULT_ADMIN);
    }

    function _validateTimelock(address timelockAddress, address proposer) internal view {
        TimelockController timelock = TimelockController(payable(timelockAddress));
        uint256 actualDelay = timelock.getMinDelay();
        if (actualDelay != EXPECTED_TIMELOCK_MIN_DELAY) {
            revert InvalidTimelockDelay(actualDelay, EXPECTED_TIMELOCK_MIN_DELAY);
        }

        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        if (!timelock.hasRole(proposerRole, proposer)) revert MissingTimelockRole(proposerRole, proposer);

        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        if (!timelock.hasRole(cancellerRole, proposer)) revert MissingTimelockRole(cancellerRole, proposer);

        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        if (!timelock.hasRole(executorRole, address(0))) revert MissingTimelockRole(executorRole, address(0));

        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        if (!timelock.hasRole(adminRole, timelockAddress)) revert MissingTimelockRole(adminRole, timelockAddress);
        if (timelock.hasRole(adminRole, proposer)) revert UnexpectedTimelockAdmin(proposer);
    }

    function _validateTreasuryBinding(USD8 usd8, Registry registry, Treasury treasury) internal view {
        address candidate = address(treasury);
        address boundUsd8;
        address boundRegistry;
        try treasury.usd8() returns (USD8 value) {
            boundUsd8 = address(value);
        } catch {
            revert InvalidTreasury(candidate);
        }
        try treasury.registry() returns (Registry value) {
            boundRegistry = address(value);
        } catch {
            revert InvalidTreasury(candidate);
        }

        if (boundUsd8 != address(usd8) || boundRegistry != address(registry)) {
            revert InvalidTreasuryBinding(candidate, boundUsd8, boundRegistry);
        }
    }

    function _initialInsuredTokenConfigs() internal pure returns (InsuredTokenDeploymentConfig[3] memory configs) {
        bytes memory conversionCallData = abi.encodeCall(IERC4626.convertToAssets, (1e18));

        configs[0] = InsuredTokenDeploymentConfig({
            token: AAVE_SGHO,
            maxCoverageBps: 8000,
            minClaimAmount: INITIAL_MIN_CLAIM_AMOUNT,
            underlyingPriceOracle: GHO_USD_ORACLE,
            conversionAddress: AAVE_SGHO,
            conversionCallData: conversionCallData
        });
        configs[1] = InsuredTokenDeploymentConfig({
            token: CURVE_SCRVUSD,
            maxCoverageBps: 7000,
            minClaimAmount: INITIAL_MIN_CLAIM_AMOUNT,
            underlyingPriceOracle: CRVUSD_USD_ORACLE,
            conversionAddress: CURVE_SCRVUSD,
            conversionCallData: conversionCallData
        });
        configs[2] = InsuredTokenDeploymentConfig({
            token: SKY_SUSDS,
            maxCoverageBps: 7000,
            minClaimAmount: INITIAL_MIN_CLAIM_AMOUNT,
            underlyingPriceOracle: USDS_USD_ORACLE,
            conversionAddress: SKY_SUSDS,
            conversionCallData: conversionCallData
        });
    }

    function _protocolInsuredTokenConfigs(address usd8, address savings, address usd8PriceOracle)
        internal
        pure
        returns (InsuredTokenDeploymentConfig[2] memory configs)
    {
        configs[0] = InsuredTokenDeploymentConfig({
            token: usd8,
            maxCoverageBps: 8000,
            minClaimAmount: INITIAL_MIN_CLAIM_AMOUNT,
            underlyingPriceOracle: usd8PriceOracle,
            conversionAddress: address(0),
            conversionCallData: bytes("")
        });
        configs[1] = InsuredTokenDeploymentConfig({
            token: savings,
            maxCoverageBps: 8000,
            minClaimAmount: INITIAL_MIN_CLAIM_AMOUNT,
            underlyingPriceOracle: usd8PriceOracle,
            conversionAddress: savings,
            conversionCallData: abi.encodeCall(IERC4626.convertToAssets, (1e18))
        });
    }

    function _addProtocolInsuredTokens(
        DefiInsurance defiInsurance,
        address usd8,
        address savings,
        address usd8PriceOracle
    ) internal {
        InsuredTokenDeploymentConfig[2] memory configs = _protocolInsuredTokenConfigs(usd8, savings, usd8PriceOracle);
        for (uint256 i; i < configs.length; ++i) {
            InsuredTokenDeploymentConfig memory config = configs[i];
            defiInsurance.addInsuredToken(
                IERC20(config.token),
                config.maxCoverageBps,
                config.minClaimAmount,
                config.underlyingPriceOracle,
                config.conversionAddress,
                config.conversionCallData
            );
        }
    }

    function _addInitialInsuredTokens(DefiInsurance defiInsurance) internal {
        InsuredTokenDeploymentConfig[3] memory configs = _initialInsuredTokenConfigs();
        for (uint256 i; i < configs.length; ++i) {
            InsuredTokenDeploymentConfig memory config = configs[i];
            defiInsurance.addInsuredToken(
                IERC20(config.token),
                config.maxCoverageBps,
                config.minClaimAmount,
                config.underlyingPriceOracle,
                config.conversionAddress,
                config.conversionCallData
            );
        }
    }

    function _deployAndWire(address deployer, TimelockController timelock) internal returns (Deployed memory d) {
        d.timelock = timelock;

        // Central access + pause registry. Deployer is timelock AND initial admin
        // for setup; roles are handed to governance on the Registry in
        // _handOffRoles. Every contract below keeps this as its fixed registry
        // pointer.
        // Registry is UUPS-upgradeable (impl + ERC-1967 proxy), timelock-gated upgrades.
        // maxCoverPoolPayoutBps defaults to 50% in initialize.
        d.registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (deployer, deployer)))
            )
        );

        // USD8 impl + ERC-1967 proxy. Treasury authority resolves through Registry;
        // it remains unset until the real Treasury is deployed and validated below.
        USD8 impl = new USD8();
        d.usd8Impl = address(impl);
        d.usd8 = USD8(address(new ERC1967Proxy(address(impl), abi.encodeCall(USD8.initialize, (d.registry)))));
        d.registry.setUsd8(address(d.usd8));

        // Treasury impl + ERC-1967 proxy (UUPS, timelock-upgraded in place, M-06).
        // Fresh-deployment path only: this does not migrate a funded legacy
        // constructor Treasury's reserve, strategies, or receiver configuration.
        Treasury treasuryImpl = new Treasury();
        d.treasuryImpl = address(treasuryImpl);
        d.treasury = Treasury(
            address(new ERC1967Proxy(address(treasuryImpl), abi.encodeCall(Treasury.initialize, (d.registry))))
        );

        // Point Registry's canonical Treasury at the validated proxy so the seed mint goes
        // through the normal USDC-backed mint path (no unbacked supply).
        _validateTreasuryBinding(d.usd8, d.registry, d.treasury);
        d.registry.setTreasury(address(d.treasury));

        // Canonical Morpho Vault V2 sUSD8, custom idle/profit adapter, Registry pause gates,
        // and dead-share seed are created/configured atomically. The bootstrap owns the
        // fresh vault only during this transaction, then hands owner/curator/allocator
        // roles to the TimelockController. Seed USD8 is minted 1:1 from real USDC.
        USD8SavingsBootstrap savingsBootstrap = new USD8SavingsBootstrap();
        require(d.treasury.USDC().transfer(address(savingsBootstrap), SEED_USDC), "sUSD8 seed transfer failed");
        USD8SavingsBootstrap.Deployment memory savingsDeployment = savingsBootstrap.run(
            USD8SavingsBootstrap.Config({
                vaultFactory: MORPHO_VAULT_V2_FACTORY,
                registry: d.registry,
                usd8: d.usd8,
                treasury: d.treasury,
                seedUsdc: SEED_USDC,
                seedSink: SEED_SINK,
                governance: address(d.timelock),
                maxRate: SUSD8_MAX_RATE,
                salt: SUSD8_SALT
            })
        );
        d.savings = IVaultV2(savingsDeployment.vault);
        d.savingsAdapter = savingsDeployment.adapter;
        d.savingsGate = savingsDeployment.gate;
        d.registry.setSavingsVault(address(d.savings));

        // SingleAssetCoverPool implementation behind a shared UpgradeableBeacon (owner
        // = deployer, handed to the timelock in _handOffRoles). One beacon upgrade
        // re-points every pool at once. Launch pool: wstETH, rewarded in USD8.
        SingleAssetCoverPool poolImpl = new SingleAssetCoverPool();
        d.poolImpl = address(poolImpl);
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(poolImpl), deployer);
        d.poolBeacon = address(beacon);
        IERC20 wsteth = IERC20(WSTETH);

        // Deploy the pool beacon proxy. No seed step: totalAssets is tracked accounting
        // (not balanceOf), so donations can't inflate price-per-share, and per-share
        // value only ever falls (on payout) — the first-depositor inflation attack has
        // no foothold. The OZ-style +1 virtual offset in stake/completeUnstake covers
        // the total-loss edge without locking capital. The pool is live on init.
        d.wstethPool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize, (d.registry, wsteth, "USD8 wstETH Cover", "cpwstETH")
                    )
                )
            )
        );

        d.registry.addPool(address(d.wstethPool));

        // Scored tokens + booster live on the Registry. USD8 earns 10× sUSD8
        // (approximately 1.0 vs 0.1 score per whole token per day). Scoring starts
        // now; these first setScoredToken calls create the canonical onchain rate
        // histories that the offchain settlement computation reads at openBlock.
        d.registry.setScoredToken(IERC20(address(d.usd8)), USD8_SCORE_RATE);
        d.registry.setScoredToken(IERC20(address(d.savings)), SUSD8_SCORE_RATE);
        d.registry.setBoosterNFT(USD8_BOOSTER);

        // Register Morpho savings at zero launch weight: the irrecoverable seed
        // shares must not own pre-TVL Treasury revenue. Governance can re-weight
        // the adapter after meaningful organic deposits dilute the seed fraction.
        // The adapter mode is preconfigured correctly for that later activation.
        d.treasury
            .setProfitReceiver(
                d.savingsAdapter,
                INITIAL_SAVINGS_PROFIT_WEIGHT,
                Treasury.RevenueDistributionMode.ReceiveProfitDistribution
            );
        // Until savings is activated, all recurring Treasury revenue funds cover LPs.
        d.treasury
            .setProfitReceiver(address(d.wstethPool), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        // DefiInsurance — the single insurance product (payout module). Registered on
        // the Registry so it can freeze the system and pay claims out of the pools;
        // the score a claim consumes is emitted as a ScoreSpent event (no ledger).
        // Launch coverage includes USD8, sUSD8, new ERC-4626 sGHO, scrvUSD, and
        // sUSDS. USD8 uses the composite USD8/USD oracle directly; sUSD8 first
        // converts shares to immediate-underlying USD8, then uses that same oracle.
        // The external savings tokens use their vault rate plus underlying/USD.
        // Coverage is immediate-layer only: USD8 covers direct loss versus USDC;
        // sUSD8 covers direct vault/share loss versus USD8. A USD8 backing loss
        // alone must not open an sUSD8 incident. The USD8/USD oracle still prices
        // USD8 conservatively when settling a genuinely separate sUSD8 incident.
        d.defiInsurance = new DefiInsurance(d.registry);
        d.registry.setDefiInsurance(address(d.defiInsurance));
        d.usd8PriceOracle = address(new USD8PriceOracle(d.registry, USDC_USD_ORACLE));
        d.registry.setUsd8PriceOracle(d.usd8PriceOracle);
        _addProtocolInsuredTokens(d.defiInsurance, address(d.usd8), address(d.savings), d.usd8PriceOracle);
        _addInitialInsuredTokens(d.defiInsurance);

        // Treasury yield strategies: Aave + Morpho, each an ERC4626Strategy over a
        // USDC ERC-4626 vault (constructor reverts unless asset() == USDC). Added to
        // the withdrawal queue in order (index 0 = Aave, consulted first on redeem).
        // Idle USDC stays idle until governance moves it via depositToStrategy.
        d.aaveStrategy = address(new ERC4626Strategy(address(d.treasury), IERC4626(AAVE_USDC_VAULT)));
        d.morphoStrategy = address(new ERC4626Strategy(address(d.treasury), IERC4626(MORPHO_USDC_VAULT)));
        d.treasury.addStrategy(ERC4626Strategy(d.aaveStrategy), 0);
        d.treasury.addStrategy(ERC4626Strategy(d.morphoStrategy), 1);
    }

    function _handOffRoles(Deployed memory d, address deployer, address admin) internal {
        // The pool beacon is Ownable (holds upgrade authority for every pool) —
        // it belongs to the TIMELOCK (all upgrades are delayed), transferred
        // before dropping deployer roles.
        UpgradeableBeacon(d.poolBeacon).transferOwnership(address(d.timelock));

        // All access roles live on the single Registry. Hand off there once: grant
        // the governance admin, drop the deployer's bootstrap admin, then transfer
        // the timelock LAST (after which the deployer can no longer touch it). Skip
        // the drop when deployer == admin — else the two calls cancel out and the
        // system launches with an EMPTY admin set. setTimelock is IRREVERSIBLE
        // (HARD RULE 5): run() validated the predeployed timelock's code, delay,
        // proposer/canceller, open executor, and self-admin role before broadcasting.
        d.registry.setAdmin(admin, true);
        if (deployer != admin) d.registry.setAdmin(deployer, false);
        d.registry.setTimelock(address(d.timelock));
    }

    function _logResults(Deployed memory d, address admin) internal pure {
        console2.log("=== TimelockController ===");
        console2.log("Address:           ", address(d.timelock));
        console2.log("minDelay:          ", EXPECTED_TIMELOCK_MIN_DELAY);
        console2.log("Proposer/canceller:", admin);
        console2.log("Executor:           open (anyone after delay)");
        console2.log("");
        console2.log("=== Registry ===");
        console2.log("Address:           ", address(d.registry));
        console2.log("");
        console2.log("=== USD8 ===");
        console2.log("Implementation:    ", d.usd8Impl);
        console2.log("Proxy:             ", address(d.usd8));
        console2.log("");
        console2.log("=== Treasury ===");
        console2.log("Implementation:    ", d.treasuryImpl);
        console2.log("Proxy:             ", address(d.treasury));
        console2.log("");
        console2.log("=== Morpho Vault V2 savings (share symbol sUSD8) ===");
        console2.log("Canonical factory: ", MORPHO_VAULT_V2_FACTORY);
        console2.log("Vault/share token: ", address(d.savings));
        console2.log("Savings adapter:   ", d.savingsAdapter);
        console2.log("Registry pause gate:", d.savingsGate);
        console2.log("maxRate (WAD/sec): ", SUSD8_MAX_RATE);
        console2.log("");
        console2.log("=== SingleAssetCoverPool (wstETH) ===");
        console2.log("Implementation:    ", d.poolImpl);
        console2.log("Beacon:            ", d.poolBeacon);
        console2.log("wstETH pool proxy: ", address(d.wstethPool));
        console2.log("");
        console2.log("=== Treasury strategies ===");
        console2.log("Aave (ERC4626):    ", d.aaveStrategy);
        console2.log("Morpho (ERC4626):  ", d.morphoStrategy);
        console2.log("");
        console2.log("=== DefiInsurance ===");
        console2.log("Address:           ", address(d.defiInsurance));
        console2.log("USD8/USD oracle:    ", d.usd8PriceOracle);
        console2.log("Launch tokens:      USD8, sUSD8, sGHO, scrvUSD, sUSDS");
        console2.log("");
        console2.log("=== Privileged beta admin (accepted trust assumption) ===");
        console2.log("Address:           ", admin);
    }
}
