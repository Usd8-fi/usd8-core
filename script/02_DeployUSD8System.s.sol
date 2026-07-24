// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Registry} from "../src/Registry.sol";
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";

import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {USD8PriceOracle} from "../src/oracles/USD8PriceOracle.sol";
import {USD8SavingsBootstrap} from "../src/deployment/USD8SavingsBootstrap.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultV2Factory} from "vault-v2/src/interfaces/IVaultV2Factory.sol";
import {DeploymentConfig} from "./config/DeploymentConfig.sol";

/// @title 02 — Deploy USD8 System
/// @notice Second deployment step. Uses the TimelockController deployed by
///         `01_DeployTimelock.s.sol`, then deploys Registry, USD8 (proxy + impl),
///         Treasury (UUPS proxy + impl, with two USDC yield strategies — Aave +
///         Morpho), a wstETH SingleAssetCoverPool
///         behind an UpgradeableBeacon (the capital base), and DefiInsurance (UUPS
///         proxy + impl, the
///         single payout module). USD8 scoring, launch insured tokens, and the
///         booster are configured during deployment. Canonical sUSD8 is also
///         deployed, seeded, scored, insured and registered before role handoff.
///
/// @dev    Pass the verified step-01 deployment to {run(address)}.
///         Governance split: the timelock role is a real OZ TimelockController
///         (minDelay {EXPECTED_TIMELOCK_MIN_DELAY}; one configured
///         proposer/canceller; open execution; self-administered — admin param
///         address(0), so delay/role changes go through its own delayed
///         proposals). The Registry admin role stays with that configured account during
///         beta and is explicitly privileged: it can operate pauses, profit routing,
///         strategy allocations, and incident/root controls. This is an accepted
///         trust assumption; migrate it to a monitored Safe before real user volume.
///         Chain-specific addresses are resolved by {DeploymentConfig}; numeric
///         protocol parameters remain constants below.
///
/// ════════════════════════════ HARD RULES ════════════════════════════
/// Operational invariants that are NOT (all) enforced on-chain. Whoever
/// deploys and governs the system MUST uphold these:
///
///  1. DURING BETA, TIMELOCK DELAY (1 day) < DISPUTE_PERIOD (2 days). The governance timelock's
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
///     Treasury, DefiInsurance, the pool beacon (all pools upgrade through it),
///     and the immutable Morpho sUSD8 vault. A wrong or
///     typo'd address permanently and unrecoverably loses governance AND
///     upgradeability. NOTE: the pool beacon is Ownable and its ownership is
///     transferred to the timelock in _handOffRoles — a separate handle from the
///     Registry timelock, so rotate BOTH on any governance migration.
///     Before calling, verify the new timelock is a live, correctly-owned
///     address/contract — on every contract. (admin is recoverable by the
///     timelock; the timelock itself is not.)
///
///  6. PRIVILEGED BETA ROLES ARE TRUSTED. The configured admin proposes/cancels timelock
///     operations and retains immediate operational powers. Monitor every action,
///     use a Safe before meaningful TVL, and permanently end beta shortcuts when
///     governance is ready. Do not describe this role as deny-only.
/// ═════════════════════════════════════════════════════════════════════
contract DeployUSD8SystemScript is DeploymentConfig {
    using SafeERC20 for IERC20;

    error InvalidTimelockDelay(uint256 actual, uint256 expected);
    error MissingTimelockRole(bytes32 role, address account);
    error UnexpectedTimelockAdmin(address account);
    error InvalidTreasury(address candidate);
    error InvalidTreasuryBinding(address candidate, address boundUsd8, address boundRegistry);
    error InvalidConfiguredContract(bytes32 field, address candidate);
    error InvalidConfiguredDependency(bytes32 field, address candidate);
    error LaunchStrategyReviewNotConfirmed();

    /// @notice TimelockController minDelay. During beta, it must stay strictly under
    ///         DefiInsurance.DISPUTE_PERIOD (2 days) so timelock root correction fits.
    uint256 constant EXPECTED_TIMELOCK_MIN_DELAY = 24 hours;

    /// @notice USD8 insurance-score rate, 1e18-scaled. Set for a 12s-block chain
    ///         (7200 blocks/day) so a whole USD8 accrues approximately 1 score/day.
    uint128 constant USD8_SCORE_RATE = 138888888888889; // 1e18 / 7200  ≈ 1.0/day

    /// @notice sUSD8 insurance-score rate: approximately 0.1 score/token/day.
    uint128 public constant SUSD8_SCORE_RATE = 13888888888889;

    uint256 public constant INITIAL_SAVINGS_PROFIT_WEIGHT = 0;
    uint256 public constant SEED_USDC = 10e6;
    uint256 public constant SUSD8_MAX_RATE = 20e16 / uint256(365 days);
    bytes32 public constant SUSD8_SALT = keccak256("USD8 Savings Morpho Vault V2");

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

        address poolImpl;
        address poolBeacon;
        SingleAssetCoverPool wstethPool;
        address aaveStrategy;
        address morphoStrategy;
        address defiInsuranceImpl;
        DefiInsurance defiInsurance;
        address usd8PriceOracle;
        address savingsBootstrap;
        address savingsVault;
        address savingsAdapter;
    }

    function run(address timelockAddress) external {
        Addresses memory config = _deploymentConfig(block.chainid);

        _validateConfiguredContracts(config);
        _validateLaunchStrategyReview(vm.envOr("AAVE_STRATEGY_REVIEWED", false));
        _validateTimelock(timelockAddress, config.admin);

        vm.startBroadcast();
        Deployed memory d = _deployAndWire(msg.sender, TimelockController(payable(timelockAddress)), config);
        _handOffRoles(d, msg.sender, config.admin);
        vm.stopBroadcast();

        _logResults(d, config.admin);
    }

    function _validateLaunchStrategyReview(bool reviewed) internal pure {
        if (!reviewed) revert LaunchStrategyReviewNotConfirmed();
    }

    function _validateConfiguredContracts(Addresses memory a) internal view {
        _requireCode("usdc", a.usdc);
        _requireCode("morphoVaultV2Factory", a.morphoVaultV2Factory);
        _requireCode("booster", a.booster);
        _requireCode("coverAsset", a.coverAsset);
        _requireCode("coverAssetUsdOracle", a.coverAssetUsdOracle);
        _requireCode("aaveUsdcVault", a.aaveUsdcVault);
        _requireCode("morphoUsdcVault", a.morphoUsdcVault);
        _requireCode("aaveSgho", a.aaveSgho);
        _requireCode("ghoUsdOracle", a.ghoUsdOracle);
        _requireCode("skySusds", a.skySusds);
        _requireCode("usdsUsdOracle", a.usdsUsdOracle);
        _requireCode("usdcUsdOracle", a.usdcUsdOracle);

        _validateReserve(a.usdc);
        _validateFactory(a.morphoVaultV2Factory, a.usdc);
        _validateVault("aaveUsdcVault", a.aaveUsdcVault, a.usdc);
        _validateVault("morphoUsdcVault", a.morphoUsdcVault, a.usdc);

        bytes memory conversionCallData = abi.encodeCall(IERC4626.convertToAssets, (1e18));
        _validateConversion("aaveSgho", a.aaveSgho, conversionCallData);
        _validateConversion("skySusds", a.skySusds, conversionCallData);

        _validateOracle("coverAssetUsdOracle", a.coverAssetUsdOracle);
        _validateOracle("ghoUsdOracle", a.ghoUsdOracle);
        _validateOracle("usdsUsdOracle", a.usdsUsdOracle);
        _validateOracle("usdcUsdOracle", a.usdcUsdOracle);
    }

    function _requireCode(bytes32 field, address candidate) private view {
        if (candidate.code.length == 0) revert InvalidConfiguredContract(field, candidate);
    }

    function _validateReserve(address reserve) private view {
        (bool ok, bytes memory data) = reserve.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length != 32 || abi.decode(data, (uint256)) != 6) {
            revert InvalidConfiguredDependency("usdc", reserve);
        }
    }

    function _validateFactory(address factory, address reserve) private view {
        // Use a stable nonzero probe owner. Script contract addresses are ephemeral,
        // and Foundry rejects address(this) in broadcast scripts.
        (bool vaultOk, bytes memory vaultData) =
            factory.staticcall(abi.encodeCall(IVaultV2Factory.vaultV2, (address(1), reserve, SUSD8_SALT)));
        (bool membershipOk, bytes memory membershipData) =
            factory.staticcall(abi.encodeCall(IVaultV2Factory.isVaultV2, (address(0))));
        if (
            !vaultOk || vaultData.length != 32 || !membershipOk || membershipData.length != 32
                || abi.decode(membershipData, (uint256)) > 1
        ) {
            revert InvalidConfiguredDependency("morphoVaultV2Factory", factory);
        }
    }

    function _validateVault(bytes32 field, address vault, address reserve) private view {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeCall(IERC4626.asset, ()));
        if (!ok || data.length != 32 || abi.decode(data, (address)) != reserve) {
            revert InvalidConfiguredDependency(field, vault);
        }
    }

    function _validateConversion(bytes32 field, address target, bytes memory callData) private view {
        (bool ok, bytes memory data) = target.staticcall(callData);
        if (!ok || data.length != 32 || abi.decode(data, (uint256)) == 0) {
            revert InvalidConfiguredDependency(field, target);
        }
    }

    function _validateOracle(bytes32 field, address oracle) private view {
        (bool decimalsOk, bytes memory decimalsData) = oracle.staticcall(abi.encodeWithSignature("decimals()"));
        if (!decimalsOk || decimalsData.length != 32 || abi.decode(decimalsData, (uint256)) > 77) {
            revert InvalidConfiguredDependency(field, oracle);
        }

        (bool roundOk, bytes memory roundData) = oracle.staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (!roundOk || roundData.length < 160) revert InvalidConfiguredDependency(field, oracle);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            abi.decode(roundData, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) {
            revert InvalidConfiguredDependency(field, oracle);
        }
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

    function _initialInsuredTokenConfigs(Addresses memory addresses)
        internal
        pure
        returns (InsuredTokenDeploymentConfig[2] memory configs)
    {
        bytes memory conversionCallData = abi.encodeCall(IERC4626.convertToAssets, (1e18));

        configs[0] = InsuredTokenDeploymentConfig({
            token: addresses.aaveSgho,
            maxCoverageBps: 8000,
            minClaimAmount: INITIAL_MIN_CLAIM_AMOUNT,
            underlyingPriceOracle: addresses.ghoUsdOracle,
            conversionAddress: addresses.aaveSgho,
            conversionCallData: conversionCallData
        });
        configs[1] = InsuredTokenDeploymentConfig({
            token: addresses.skySusds,
            maxCoverageBps: 7000,
            minClaimAmount: INITIAL_MIN_CLAIM_AMOUNT,
            underlyingPriceOracle: addresses.usdsUsdOracle,
            conversionAddress: addresses.skySusds,
            conversionCallData: conversionCallData
        });
    }

    function _coreProtocolInsuredTokenConfig(address usd8, address usd8PriceOracle)
        internal
        pure
        returns (InsuredTokenDeploymentConfig memory config)
    {
        config = InsuredTokenDeploymentConfig({
            token: usd8,
            maxCoverageBps: 8000,
            minClaimAmount: INITIAL_MIN_CLAIM_AMOUNT,
            underlyingPriceOracle: usd8PriceOracle,
            conversionAddress: address(0),
            conversionCallData: bytes("")
        });
    }

    function _addCoreProtocolInsuredToken(DefiInsurance defiInsurance, address usd8, address usd8PriceOracle) internal {
        InsuredTokenDeploymentConfig memory config = _coreProtocolInsuredTokenConfig(usd8, usd8PriceOracle);
        defiInsurance.addInsuredToken(
            IERC20(config.token),
            config.maxCoverageBps,
            config.minClaimAmount,
            config.underlyingPriceOracle,
            config.conversionAddress,
            config.conversionCallData
        );
    }

    function _addInitialInsuredTokens(DefiInsurance defiInsurance, Addresses memory addresses) internal {
        InsuredTokenDeploymentConfig[2] memory configs = _initialInsuredTokenConfigs(addresses);
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

    function _configureSavings(
        Registry registry,
        DefiInsurance defiInsurance,
        Treasury treasury,
        address vault,
        address adapter,
        address usd8PriceOracle
    ) internal {
        registry.setSavingsVault(vault);
        registry.setScoredToken(IERC20(vault), SUSD8_SCORE_RATE);
        defiInsurance.addInsuredToken(
            IERC20(vault),
            8000,
            INITIAL_MIN_CLAIM_AMOUNT,
            usd8PriceOracle,
            vault,
            abi.encodeCall(IERC4626.convertToAssets, (1e18))
        );
        treasury.setProfitReceiver(
            adapter, INITIAL_SAVINGS_PROFIT_WEIGHT, Treasury.RevenueDistributionMode.ReceiveProfitDistribution
        );
    }

    function _deployAndWire(address deployer, TimelockController timelock, Addresses memory addresses)
        internal
        returns (Deployed memory d)
    {
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
            address(
                new ERC1967Proxy(
                    address(treasuryImpl), abi.encodeCall(Treasury.initialize, (d.registry, IERC20(addresses.usdc)))
                )
            )
        );

        // Point Registry's canonical Treasury at the validated proxy so the seed mint goes
        // through the normal USDC-backed mint path (no unbacked supply).
        _validateTreasuryBinding(d.usd8, d.registry, d.treasury);
        d.registry.setTreasury(address(d.treasury));

        // Canonical sUSD8 is deployed, configured and permanently seeded while
        // the deployer still holds bootstrap timelock authority. Governance is
        // assigned directly to the final TimelockController; no post-genesis
        // activation delay is required.
        USD8SavingsBootstrap savingsBootstrap = new USD8SavingsBootstrap();
        d.savingsBootstrap = address(savingsBootstrap);
        IERC20(address(d.treasury.USDC())).safeTransfer(d.savingsBootstrap, SEED_USDC);
        USD8SavingsBootstrap.Deployment memory savings = savingsBootstrap.run(
            USD8SavingsBootstrap.Config({
                vaultFactory: addresses.morphoVaultV2Factory,
                usd8: d.usd8,
                treasury: d.treasury,
                seedUsdc: SEED_USDC,
                seedSink: addresses.seedSink,
                governance: address(timelock),
                maxRate: SUSD8_MAX_RATE,
                salt: SUSD8_SALT
            })
        );
        d.savingsVault = savings.vault;
        d.savingsAdapter = savings.adapter;

        // SingleAssetCoverPool implementation behind a shared UpgradeableBeacon (owner
        // = deployer, handed to the timelock in _handOffRoles). One beacon upgrade
        // re-points every pool at once. Launch pool: wstETH, rewarded in USD8.
        SingleAssetCoverPool poolImpl = new SingleAssetCoverPool();
        d.poolImpl = address(poolImpl);
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(poolImpl), deployer);
        d.poolBeacon = address(beacon);
        IERC20 wsteth = IERC20(addresses.coverAsset);

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
                        SingleAssetCoverPool.initialize,
                        (d.registry, wsteth, "USD8 Cover Pool wstETH", "USD8-cp-wstETH")
                    )
                )
            )
        );

        d.registry.addPool(address(d.wstethPool), addresses.coverAssetUsdOracle);

        // USD8 scoring + booster live on the Registry. sUSD8 scoring is
        // configured below before bootstrap authority is handed off.
        d.registry.setScoredToken(IERC20(address(d.usd8)), USD8_SCORE_RATE);

        d.registry.setBoosterNFT(addresses.booster);

        // Savings launches at zero weight, so all recurring Treasury revenue initially funds cover LPs.
        d.treasury
            .setProfitReceiver(address(d.wstethPool), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        // DefiInsurance — the single insurance product (payout module). Registered on
        // the Registry so it can freeze the system and pay claims out of the pools;
        // the score a claim consumes is emitted as a ScoreSpent event (no ledger).
        // Launch coverage includes USD8, sUSD8, new ERC-4626 sGHO, and sUSDS.
        DefiInsurance defiInsuranceImpl = new DefiInsurance();
        d.defiInsuranceImpl = address(defiInsuranceImpl);
        d.defiInsurance = DefiInsurance(
            address(
                new ERC1967Proxy(address(defiInsuranceImpl), abi.encodeCall(DefiInsurance.initialize, (d.registry)))
            )
        );
        d.registry.setDefiInsurance(address(d.defiInsurance));
        require(d.registry.defiInsurance() == address(d.defiInsurance), "Registry/DefiInsurance mismatch");
        require(address(d.defiInsurance.registry()) == address(d.registry), "DefiInsurance/Registry mismatch");
        require(d.registry.assetUsdFeed(wsteth) == addresses.coverAssetUsdOracle, "cover asset feed mismatch");
        require(d.registry.maxOracleStaleness() != 0, "oracle staleness unset");
        d.usd8PriceOracle = address(new USD8PriceOracle(d.registry, addresses.usdcUsdOracle));
        d.registry.setUsd8PriceOracle(d.usd8PriceOracle);
        _addCoreProtocolInsuredToken(d.defiInsurance, address(d.usd8), d.usd8PriceOracle);
        _addInitialInsuredTokens(d.defiInsurance, addresses);
        _configureSavings(d.registry, d.defiInsurance, d.treasury, d.savingsVault, d.savingsAdapter, d.usd8PriceOracle);

        // Treasury yield strategies: Aave + Morpho, each an ERC4626Strategy over a
        // USDC ERC-4626 vault (constructor reverts unless asset() == USDC). Added to
        // the withdrawal queue in order (index 0 = Aave, consulted first on redeem).
        // Idle USDC stays idle until governance moves it via depositToStrategy.
        d.aaveStrategy =
            address(new ERC4626Strategy(address(d.treasury), d.registry, IERC4626(addresses.aaveUsdcVault)));
        d.morphoStrategy =
            address(new ERC4626Strategy(address(d.treasury), d.registry, IERC4626(addresses.morphoUsdcVault)));
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
        console2.log("=== SingleAssetCoverPool (wstETH) ===");
        console2.log("Implementation:    ", d.poolImpl);
        console2.log("Beacon:            ", d.poolBeacon);
        console2.log("wstETH pool proxy: ", address(d.wstethPool));
        console2.log("");
        console2.log("=== Treasury strategies ===");
        console2.log("Aave (ERC4626):    ", d.aaveStrategy);
        console2.log("Morpho (ERC4626):  ", d.morphoStrategy);
        console2.log("");
        console2.log("=== sUSD8 (Morpho Vault V2) ===");
        console2.log("Bootstrap:          ", d.savingsBootstrap);
        console2.log("Vault/share token:  ", d.savingsVault);
        console2.log("Savings adapter:    ", d.savingsAdapter);
        console2.log("");
        console2.log("=== DefiInsurance ===");
        console2.log("Implementation:    ", d.defiInsuranceImpl);
        console2.log("Proxy:             ", address(d.defiInsurance));
        console2.log("USD8/USD oracle:    ", d.usd8PriceOracle);
        console2.log("Launch tokens:      USD8, sUSD8, sGHO, sUSDS");
        console2.log("");
        console2.log("=== Privileged beta admin (accepted trust assumption) ===");
        console2.log("Address:           ", admin);
    }
}
