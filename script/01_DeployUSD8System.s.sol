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
import {USD8PriceOracle} from "../src/oracles/USD8PriceOracle.sol";
import {DeploymentConfig} from "./config/DeploymentConfig.sol";
import {Create3Deployer} from "./lib/Create3Deployer.sol";
import {USD8DeploymentLabels} from "./lib/USD8DeploymentLabels.sol";

/// @title 01 — Deploy USD8 System
/// @notice First deployment step. Deploys Registry, USD8 (proxy + impl), Treasury (UUPS
///         proxy + impl, launched with NO yield strategies — governance adds them later via
///         Treasury.addStrategy), a wstETH SingleAssetCoverPool behind an UpgradeableBeacon
///         (the capital base), and DefiInsurance (UUPS proxy + impl, the single payout
///         module). USD8 scoring, USD8 insurance and the booster are configured during
///         deployment. sUSD8 is NOT deployed here.
///
/// @dev    NO TIMELOCK IS INSTALLED BY THIS STEP. The broadcasting deployer stays the
///         Registry timelock, a Registry admin and the pool-beacon owner, so further setup
///         (insured tokens, pools, scored tokens, sUSD8...) can be done immediately. While in
///         this state the deployer can upgrade every proxy and the pool beacon WITHOUT DELAY:
///         do not open the system to users or describe it as timelocked until
///         `02_DeployTimelockAndHandOff.s.sol` has run.
///         The configured admin is granted Registry admin here; the deployer is only removed
///         as admin in step 02, and only if it differs from the configured admin.
///         The Registry admin role is explicitly privileged during beta: it can operate
///         pauses, profit routing, strategy allocations, and incident/root controls. This is
///         an accepted trust assumption; migrate it to a monitored Safe before real user volume.
///         Chain-specific addresses are resolved by {DeploymentConfig}; numeric
///         protocol parameters remain constants below.
///         Every contract is created through CreateX CREATE3 with a deployer-guarded,
///         chain-independent salt (see {Create3Deployer} and {USD8DeploymentLabels}), so the
///         same broadcaster gets the same addresses on every chain. Run with --slow.
///
/// ════════════════════════════ HARD RULES ════════════════════════════
/// Operational invariants that are NOT (all) enforced on-chain. Whoever
/// deploys and governs the system MUST uphold these:
///
///  1. DURING BETA, TIMELOCK DELAY (1 day) < CORRECTION_WINDOW (2 days). The governance timelock's
///     minDelay must be strictly less than DefiInsurance.CORRECTION_WINDOW so
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
///     Treasury, DefiInsurance and the pool beacon (all pools upgrade through it).
///     A wrong or
///     typo'd address permanently and unrecoverably loses governance AND
///     upgradeability. NOTE: the pool beacon is Ownable and its ownership is
///     transferred to the timelock in step 02 — a separate handle from the
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
contract DeployUSD8SystemScript is DeploymentConfig, Create3Deployer, USD8DeploymentLabels {
    using SafeERC20 for IERC20;

    error InvalidTreasury(address candidate);
    error InvalidTreasuryBinding(address candidate, address boundUsd8, address boundRegistry);
    error InvalidConfiguredContract(bytes32 field, address candidate);
    error InvalidConfiguredDependency(bytes32 field, address candidate);

    /// @notice Cover-pool seed (wstETH, 18 decimals) minted to the dead seed sink so the pool
    ///         never has zero shares. Accounting-based totalAssets and the 1e3 virtual-share
    ///         offset already block inflation, so only a nonzero amount is required.
    uint256 public constant COVER_POOL_SEED = 0.001 ether;

    /// @notice USD8 insurance-score rate, 1e18-scaled. Set for a 12s-block chain
    ///         (7200 blocks/day) so a whole USD8 accrues approximately 1 score/day.
    uint128 constant USD8_SCORE_RATE = 138888888888889; // 1e18 / 7200  ≈ 1.0/day


    struct InsuredTokenDeploymentConfig {
        address token;
        uint256 maxCoverageBps;
        address underlyingPriceOracle;
        address conversionAddress;
        bytes conversionCallData;
    }

    struct Deployed {
        Registry registry;
        address usd8Impl;
        USD8 usd8;
        address treasuryImpl;
        Treasury treasury;

        address poolImpl;
        address poolBeacon;
        SingleAssetCoverPool wstethPool;
        address defiInsuranceImpl;
        DefiInsurance defiInsurance;
        address usd8PriceOracle;
    }

    function run() external {
        Addresses memory config = _deploymentConfig(block.chainid);

        _validateConfiguredContracts(config);
        _requireCreateX();

        vm.startBroadcast();
        Deployed memory d = _deployAndWire(msg.sender, config);
        _grantConfiguredAdmin(d, msg.sender, config.admin);
        vm.stopBroadcast();

        _logResults(d, msg.sender, config.admin);
    }

    /// @notice Cross-chain address of a CREATE3-deployed USD8 contract, for runbook checks:
    ///         `forge script script/01_DeployUSD8System.s.sol --sig "predictedAddress(address,string)" <deployer> usd8.v1.USD8.proxy`
    function predictedAddress(address deployer, string calldata label) external view returns (address) {
        return _predictCreate3(deployer, label);
    }

    function _validateConfiguredContracts(Addresses memory a) internal view {
        _requireCode("usdc", a.usdc);
        _requireCode("booster", a.booster);
        _requireCode("wsteth", a.wsteth);
        _requireCode("wstethUsdOracle", a.wstethUsdOracle);
        _requireCode("usdcUsdOracle", a.usdcUsdOracle);

        _validateReserve(a.usdc);

        _validateOracle("wstethUsdOracle", a.wstethUsdOracle);
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

    function _coreProtocolInsuredTokenConfig(address usd8, address treasury, address usdcUsdOracle)
        internal
        pure
        returns (InsuredTokenDeploymentConfig memory config)
    {
        config = InsuredTokenDeploymentConfig({
            token: usd8,
            maxCoverageBps: 8000,
            underlyingPriceOracle: usdcUsdOracle,
            conversionAddress: treasury,
            conversionCallData: abi.encodeCall(Treasury.usd8ToUsdcRate, ())
        });
    }

    function _addCoreProtocolInsuredToken(
        DefiInsurance defiInsurance,
        address usd8,
        address treasury,
        address usdcUsdOracle
    ) internal {
        InsuredTokenDeploymentConfig memory config = _coreProtocolInsuredTokenConfig(usd8, treasury, usdcUsdOracle);
        defiInsurance.editInsuredToken(
            IERC20(config.token),
            config.maxCoverageBps,
            config.underlyingPriceOracle,
            config.conversionAddress,
            config.conversionCallData
        );
    }

    function _deployAndWire(address deployer, Addresses memory addresses) internal returns (Deployed memory d) {
        // Central access + pause registry. Deployer is timelock AND initial admin
        // for setup and keeps that interim authority after this script; step 02
        // (02_DeployTimelockAndHandOff) installs the real timelock. Every contract
        // below keeps this as its fixed registry pointer.
        // Registry is UUPS-upgradeable (impl + ERC-1967 proxy), timelock-gated upgrades.
        // maxCoverPoolPayoutBps defaults to 50% in initialize.
        // All creations go through CREATE3 (see {Create3Deployer}); proxies are initialized in
        // their constructor, so no initializer can be front-run between create and init.
        address registryImpl = _create3(deployer, LABEL_REGISTRY_IMPL, type(Registry).creationCode);
        d.registry = Registry(
            _create3(
                deployer,
                LABEL_REGISTRY,
                _proxyInitCode(registryImpl, abi.encodeCall(Registry.initialize, (deployer, deployer)))
            )
        );

        // USD8 impl + ERC-1967 proxy. Treasury authority resolves through Registry;
        // it remains unset until the real Treasury is deployed and validated below.
        d.usd8Impl = _create3(deployer, LABEL_USD8_IMPL, type(USD8).creationCode);
        d.usd8 = USD8(
            _create3(deployer, LABEL_USD8, _proxyInitCode(d.usd8Impl, abi.encodeCall(USD8.initialize, (d.registry))))
        );
        d.registry.setUsd8(address(d.usd8));

        // Treasury impl + ERC-1967 proxy (UUPS, timelock-upgraded in place, M-06).
        d.treasuryImpl = _create3(deployer, LABEL_TREASURY_IMPL, type(Treasury).creationCode);
        d.treasury = Treasury(
            _create3(
                deployer,
                LABEL_TREASURY,
                _proxyInitCode(
                    d.treasuryImpl, abi.encodeCall(Treasury.initialize, (d.registry, IERC20(addresses.usdc)))
                )
            )
        );

        // Point Registry's canonical Treasury at the validated proxy so the seed mint goes
        // through the normal USDC-backed mint path (no unbacked supply).
        _validateTreasuryBinding(d.usd8, d.registry, d.treasury);
        d.registry.setTreasury(address(d.treasury));

        // SingleAssetCoverPool implementation behind a shared UpgradeableBeacon (owner
        // = deployer, handed to the timelock in step 02). One beacon upgrade
        // re-points every pool at once. Launch pool: wstETH, rewarded in USD8.
        d.poolImpl = _create3(deployer, LABEL_POOL_IMPL, type(SingleAssetCoverPool).creationCode);
        d.poolBeacon = _create3(
            deployer,
            LABEL_POOL_BEACON,
            abi.encodePacked(type(UpgradeableBeacon).creationCode, abi.encode(d.poolImpl, deployer))
        );
        IERC20 wsteth = IERC20(addresses.wsteth);

        // Deploy the pool beacon proxy. totalAssets is tracked accounting (not
        // balanceOf), so donations cannot inflate price-per-share.
        d.wstethPool = SingleAssetCoverPool(
            _create3(
                deployer,
                LABEL_WSTETH_POOL,
                abi.encodePacked(
                    type(BeaconProxy).creationCode,
                    abi.encode(
                        d.poolBeacon,
                        abi.encodeCall(
                            SingleAssetCoverPool.initialize,
                            (d.registry, wsteth, "USD8 Cover Pool wstETH", "USD8-cp-wstETH")
                        )
                    )
                )
            )
        );

        wsteth.forceApprove(address(d.wstethPool), COVER_POOL_SEED);
        d.wstethPool.deposit(COVER_POOL_SEED, addresses.seedSink);
        require(d.wstethPool.balanceOf(addresses.seedSink) != 0, "cover pool seed missing");

        d.registry.addPool(address(d.wstethPool), addresses.wstethUsdOracle);

        // USD8 scoring + booster live on the Registry. sUSD8 scoring is added by
        // governance when sUSD8 launches after deployment.
        d.registry.setScoredToken(IERC20(address(d.usd8)), USD8_SCORE_RATE);

        d.registry.setBoosterConfig(addresses.booster, 1, 100);

        // sUSD8 is not deployed at launch, so all recurring Treasury revenue funds cover LPs.
        d.treasury
            .setProfitReceiver(address(d.wstethPool), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        // DefiInsurance — the single insurance product (payout module). Registered on
        // the Registry so it can freeze the system and pay claims out of the pools;
        // the score a claim consumes is emitted as a ScoreSpent event (no ledger).
        // Launch coverage is USD8 only; further insured tokens (sUSD8, sGHO, sUSDS...) are added post-launch.
        d.defiInsuranceImpl = _create3(deployer, LABEL_DEFI_INSURANCE_IMPL, type(DefiInsurance).creationCode);
        d.defiInsurance = DefiInsurance(
            _create3(
                deployer,
                LABEL_DEFI_INSURANCE,
                _proxyInitCode(d.defiInsuranceImpl, abi.encodeCall(DefiInsurance.initialize, (d.registry)))
            )
        );
        d.registry.setDefiInsurance(address(d.defiInsurance));
        require(d.registry.defiInsurance() == address(d.defiInsurance), "Registry/DefiInsurance mismatch");
        require(address(d.defiInsurance.registry()) == address(d.registry), "DefiInsurance/Registry mismatch");
        require(d.registry.assetUsdFeed(wsteth) == addresses.wstethUsdOracle, "wstETH feed mismatch");
        require(d.registry.maxOracleStaleness() != 0, "oracle staleness unset");
        d.usd8PriceOracle = _create3(
            deployer,
            LABEL_USD8_PRICE_ORACLE,
            abi.encodePacked(type(USD8PriceOracle).creationCode, abi.encode(d.registry, addresses.usdcUsdOracle))
        );
        d.registry.setUsd8PriceOracle(d.usd8PriceOracle);
        _addCoreProtocolInsuredToken(d.defiInsurance, address(d.usd8), address(d.treasury), addresses.usdcUsdOracle);

        // Treasury launches with NO yield strategies: all reserve USDC stays idle in the
        // Treasury. Governance adds reviewed ERC-4626 strategies post-deployment via
        // Treasury.addStrategy.
    }

    /// @dev ERC1967Proxy creation code with (implementation, initializer calldata) args.
    function _proxyInitCode(address implementation, bytes memory initData) internal pure returns (bytes memory) {
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initData));
    }

    /// @dev Grants the configured admin on the Registry. The deployer keeps its interim timelock
    ///      and admin authority (and the pool-beacon ownership) until step 02 hands off.
    function _grantConfiguredAdmin(Deployed memory d, address deployer, address admin) internal {
        if (admin != deployer) d.registry.setAdmin(admin, true);
    }

    function _logResults(Deployed memory d, address deployer, address admin) internal pure {
        console2.log("=== Interim governance (until step 02) ===");
        console2.log("Registry timelock:  ", deployer);
        console2.log("Pool beacon owner:  ", deployer);
        console2.log("WARNING: no timelock yet - deployer can upgrade everything without delay");
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
        console2.log("None at launch (governance adds via Treasury.addStrategy)");
        console2.log("");
        console2.log("=== sUSD8 ===");
        console2.log("Not deployed at launch (added post-deployment via governance)");
        console2.log("");
        console2.log("=== DefiInsurance ===");
        console2.log("Implementation:    ", d.defiInsuranceImpl);
        console2.log("Proxy:             ", address(d.defiInsurance));
        console2.log("USD8/USD oracle:    ", d.usd8PriceOracle);
        console2.log("Launch tokens:      USD8");
        console2.log("");
        console2.log("=== Privileged beta admin (accepted trust assumption) ===");
        console2.log("Address:           ", admin);
    }
}
