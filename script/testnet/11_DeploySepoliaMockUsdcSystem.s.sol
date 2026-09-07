// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultV2Factory} from "vault-v2/src/interfaces/IVaultV2Factory.sol";
import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";
import {Treasury} from "../../src/Treasury.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";
import {USD8SavingsBootstrap} from "../../src/deployment/USD8SavingsBootstrap.sol";
import {USD8PriceOracle} from "../../src/oracles/USD8PriceOracle.sol";
import {SepoliaTestToken, SepoliaTestVault, SepoliaTestOracle} from "./SepoliaDependencies.sol";

/// @notice Deploys a fresh public Sepolia staging topology from the current source tree.
/// @dev Every first-party USD8 implementation and instance is deployed fresh. Only the timelock,
///      test assets, test vaults, factory, booster and oracle fixtures are reused. Accelerated
///      lifecycle values in this script are Sepolia-only and must never be copied into the
///      production deployment scripts. The existing staging topology is not modified.
contract DeploySepoliaMockUsdcSystemScript is Script {
    using SafeERC20 for IERC20;

    uint256 public constant CHAIN_ID = 11_155_111;
    uint256 public constant EXPECTED_TIMELOCK_DELAY = 30 minutes;
    uint256 public constant MOCK_USDC_INITIAL_SUPPLY = 10_000_000e6;
    uint256 public constant SEED_USDC = 10e6;
    uint256 public constant COVER_POOL_SEED = 0.01 ether;
    uint128 public constant USD8_SCORE_RATE = 138888888888889;
    uint128 public constant SUSD8_SCORE_RATE = 13888888888889;
    uint256 public constant SUSD8_MAX_RATE = 20e16 / uint256(365 days);
    uint256 public constant COVER_POOL_CAP = 1_000 ether;
    bytes32 public constant SUSD8_SALT = keccak256("USD8 Savings Morpho Vault V2 Mock USDC");
    address public constant SEPOLIA_ADMIN = 0x724e8951d39E14CEBcB5fB02638f49A637C97838;
    address public constant MEASURED_TEE_SIGNER = 0x0140Cc1E7a438F2F29F1345348AE5f1aE4F0CB0F;
    bytes32 public constant MEASURED_TEE_PCR = 0x1ccc0b38c13750ed40ef6bb31aa7245f2749b8ef0665dcf7f08ee64171c34f65;
    address public constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;

    struct Reused {
        address timelock;
        address mockUsdc;
        address aaveUsdcVault;
        address morphoUsdcVault;
        address morphoVaultV2Factory;
        address booster;
        address coverAsset;
        address coverAssetUsdOracle;
        address aaveSgho;
        address ghoUsdOracle;
        address skySusds;
        address usdsUsdOracle;
        address usdcUsdOracle;
        address msLoss;
    }

    struct System {
        address usdc;
        address aaveUsdcVault;
        address morphoUsdcVault;
        address registryImplementation;
        Registry registry;
        address usd8Implementation;
        USD8 usd8;
        address treasuryImplementation;
        Treasury treasury;
        address savingsBootstrap;
        address savingsVault;
        address savingsAdapter;
        address coverPoolImplementation;
        address coverPoolBeacon;
        SingleAssetCoverPool pool;
        address defiInsuranceImplementation;
        DefiInsurance insurance;
        address usd8PriceOracle;
        address aaveStrategy;
        address morphoStrategy;
    }

    error SepoliaOnly(uint256 chainId);
    error BroadcasterMismatch(address broadcaster, address expected);
    error MissingCode(bytes32 field, address candidate);
    error InvalidDependency(bytes32 field, address candidate);
    error InsufficientCoverSeed(uint256 available, uint256 required);

    function run() external returns (System memory s) {
        if (block.chainid != CHAIN_ID) revert SepoliaOnly(block.chainid);
        if (msg.sender != SEPOLIA_ADMIN) revert BroadcasterMismatch(msg.sender, SEPOLIA_ADMIN);

        Reused memory reused = _sepoliaReused();
        _validateReused(reused);

        vm.startBroadcast();
        _refreshFeeds(reused);
        s = _deploy(SEPOLIA_ADMIN, reused);
        vm.stopBroadcast();

        _log(s, reused);
    }

    function _sepoliaReused() internal pure returns (Reused memory reused) {
        reused = Reused({
            timelock: 0x158494e7b95c0e5F87e8dB4Ad1Be5c32de99F645,
            mockUsdc: 0x31cD4d9299aC2d55bb8590C9557edd3ff08cF35c,
            aaveUsdcVault: 0xfB82Cf1A712B3d0357132Fd153e33081bEabC1Dd,
            morphoUsdcVault: 0x327aA8c33765bEbf0B13c3DDAc981deF9036b225,
            morphoVaultV2Factory: 0xb3fE2D5f8Af90f194B01db546397058Fcebb85D1,
            booster: 0xC0012770848FCD350AB11906e93ba9fdfDA19f4c,
            coverAsset: 0xdfaf9C1CE55f18AB7850EDd84F2175ce734985fa,
            coverAssetUsdOracle: 0x00E79aFB10A84D153803F00e73900803179D594e,
            aaveSgho: 0x6e5eb99a5923bEA10Eb3990Ec8Da84e70007E668,
            ghoUsdOracle: 0xA1BEA76BD8FB29bcec20Ad6F97e541283Ab82275,
            skySusds: 0x5279e60d104110dB53b9d00a54F323E978be3757,
            usdsUsdOracle: 0x9951918957c4466a223E7E8D00c6a326be61018C,
            usdcUsdOracle: 0x9989a6bB00C1737A9A0175408053a04A6f3eD74b,
            msLoss: 0xD5B2a08F474f77eF29211Ccc59cd65e5fA6734dc
        });
    }

    function _validateReused(Reused memory r) internal view {
        _requireCode("timelock", r.timelock);
        _requireCode("mockUsdc", r.mockUsdc);
        _requireCode("aaveUsdcVault", r.aaveUsdcVault);
        _requireCode("morphoUsdcVault", r.morphoUsdcVault);
        _requireCode("morphoVaultV2Factory", r.morphoVaultV2Factory);
        _requireCode("booster", r.booster);
        _requireCode("coverAsset", r.coverAsset);
        _requireCode("coverAssetUsdOracle", r.coverAssetUsdOracle);
        _requireCode("aaveSgho", r.aaveSgho);
        _requireCode("ghoUsdOracle", r.ghoUsdOracle);
        _requireCode("skySusds", r.skySusds);
        _requireCode("usdsUsdOracle", r.usdsUsdOracle);
        _requireCode("usdcUsdOracle", r.usdcUsdOracle);
        _requireCode("msLoss", r.msLoss);

        TimelockController timelock = TimelockController(payable(r.timelock));
        if (timelock.getMinDelay() != EXPECTED_TIMELOCK_DELAY) revert InvalidDependency("timelock", r.timelock);
        if (!timelock.hasRole(timelock.PROPOSER_ROLE(), SEPOLIA_ADMIN)) {
            revert InvalidDependency("timelockProposer", r.timelock);
        }
        if (!timelock.hasRole(timelock.CANCELLER_ROLE(), SEPOLIA_ADMIN)) {
            revert InvalidDependency("timelockCanceller", r.timelock);
        }
        if (!timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0))) {
            revert InvalidDependency("timelockExecutor", r.timelock);
        }
        if (IERC4626(r.aaveUsdcVault).asset() != r.mockUsdc) {
            revert InvalidDependency("aaveUsdcVaultAsset", r.aaveUsdcVault);
        }
        if (IERC4626(r.morphoUsdcVault).asset() != r.mockUsdc) {
            revert InvalidDependency("morphoUsdcVaultAsset", r.morphoUsdcVault);
        }
        if (IERC20(r.coverAsset).balanceOf(SEPOLIA_ADMIN) < COVER_POOL_SEED) {
            revert InsufficientCoverSeed(IERC20(r.coverAsset).balanceOf(SEPOLIA_ADMIN), COVER_POOL_SEED);
        }

        _validateVault("aaveSgho", r.aaveSgho);
        _validateVault("skySusds", r.skySusds);
        _validateOracle("coverAssetUsdOracle", r.coverAssetUsdOracle);
        _validateOracle("ghoUsdOracle", r.ghoUsdOracle);
        _validateOracle("usdsUsdOracle", r.usdsUsdOracle);
        _validateOracle("usdcUsdOracle", r.usdcUsdOracle);

        (bool factoryOk, bytes memory factoryData) =
            r.morphoVaultV2Factory.staticcall(abi.encodeCall(IVaultV2Factory.isVaultV2, (address(0))));
        if (!factoryOk || factoryData.length != 32 || abi.decode(factoryData, (uint256)) > 1) {
            revert InvalidDependency("morphoVaultV2Factory", r.morphoVaultV2Factory);
        }
    }

    function _requireCode(bytes32 field, address candidate) private view {
        if (candidate.code.length == 0) revert MissingCode(field, candidate);
    }

    function _validateVault(bytes32 field, address vault) private view {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeCall(IERC4626.convertToAssets, (1e18)));
        if (!ok || data.length != 32 || abi.decode(data, (uint256)) == 0) revert InvalidDependency(field, vault);
    }

    function _validateOracle(bytes32 field, address oracle) private view {
        (bool ok, bytes memory data) = oracle.staticcall(abi.encodeCall(SepoliaTestOracle.latestRoundData, ()));
        if (!ok || data.length < 160) revert InvalidDependency(field, oracle);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) revert InvalidDependency(field, oracle);
    }

    function _refreshFeeds(Reused memory r) internal {
        SepoliaTestOracle(r.coverAssetUsdOracle).updateAnswer(4_000e8);
        SepoliaTestOracle(r.ghoUsdOracle).updateAnswer(1e8);
        SepoliaTestOracle(r.usdsUsdOracle).updateAnswer(1e8);
        SepoliaTestOracle(r.usdcUsdOracle).updateAnswer(1e8);
    }

    function _deploy(address admin, Reused memory r) internal returns (System memory s) {
        s.usdc = r.mockUsdc;
        s.aaveUsdcVault = r.aaveUsdcVault;
        s.morphoUsdcVault = r.morphoUsdcVault;

        s.registryImplementation = address(new Registry());
        s.registry = Registry(
            address(new ERC1967Proxy(s.registryImplementation, abi.encodeCall(Registry.initialize, (admin, admin))))
        );
        s.usd8Implementation = address(new USD8());
        s.usd8 = USD8(address(new ERC1967Proxy(s.usd8Implementation, abi.encodeCall(USD8.initialize, (s.registry)))));
        s.registry.setUsd8(address(s.usd8));
        s.treasuryImplementation = address(new Treasury());
        s.treasury = Treasury(
            address(
                new ERC1967Proxy(
                    s.treasuryImplementation, abi.encodeCall(Treasury.initialize, (s.registry, IERC20(s.usdc)))
                )
            )
        );
        s.registry.setTreasury(address(s.treasury));

        USD8SavingsBootstrap bootstrap = new USD8SavingsBootstrap();
        s.savingsBootstrap = address(bootstrap);
        IERC20(s.usdc).safeTransfer(s.savingsBootstrap, SEED_USDC);
        USD8SavingsBootstrap.Deployment memory savings = bootstrap.run(
            USD8SavingsBootstrap.Config({
                vaultFactory: r.morphoVaultV2Factory,
                usd8: s.usd8,
                treasury: s.treasury,
                seedUsdc: SEED_USDC,
                seedSink: SEED_SINK,
                governance: r.timelock,
                maxRate: SUSD8_MAX_RATE,
                salt: SUSD8_SALT
            })
        );
        s.savingsVault = savings.vault;
        s.savingsAdapter = savings.adapter;

        s.coverPoolImplementation = address(new SingleAssetCoverPool());
        s.coverPoolBeacon = address(new UpgradeableBeacon(s.coverPoolImplementation, r.timelock));
        s.pool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    s.coverPoolBeacon,
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (s.registry, IERC20(r.coverAsset), "USD8 Cover Pool wstETH", "USD8-cp-wstETH")
                    )
                )
            )
        );
        IERC20(r.coverAsset).forceApprove(address(s.pool), COVER_POOL_SEED);
        s.pool.deposit(COVER_POOL_SEED, SEED_SINK);
        require(s.pool.balanceOf(SEED_SINK) != 0, "cover pool seed missing");
        s.pool.setDepositCap(COVER_POOL_CAP);
        s.registry.addPool(address(s.pool), r.coverAssetUsdOracle);
        s.registry.setScoredToken(IERC20(address(s.usd8)), USD8_SCORE_RATE);
        s.registry.setBoosterConfig(r.booster, 1, 100);
        s.treasury.setProfitReceiver(address(s.pool), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        s.defiInsuranceImplementation = address(new DefiInsurance());
        s.insurance = DefiInsurance(
            address(
                new ERC1967Proxy(s.defiInsuranceImplementation, abi.encodeCall(DefiInsurance.initialize, (s.registry)))
            )
        );
        s.registry.setDefiInsurance(address(s.insurance));
        s.registry.setTeePcrHash(MEASURED_TEE_PCR);
        s.registry
            .setIncidentOpenPriceConfig(
                Registry.IncidentOpenPriceConfig({twapBlocks: 4, sampleStepBlocks: 2, minimumDropBps: 2_000})
            );
        s.registry
            .setIncidentTimingConfig(Registry.IncidentTimingConfig({phaseWindow: 1 hours, maxReferenceBlockAge: 450}));
        s.insurance.setTeeSigner(MEASURED_TEE_SIGNER, true);
        s.insurance
            .setSettlementParams(
                DefiInsurance.SettlementParams({
                    twapLookbackBlocks: 50_400, minHoldingRequired: 7_200, sampleStepBlocks: 300
                })
            );
        s.usd8PriceOracle = address(new USD8PriceOracle(s.registry, r.usdcUsdOracle));
        s.registry.setUsd8PriceOracle(s.usd8PriceOracle);

        s.insurance
            .editInsuredToken(
                IERC20(address(s.usd8)),
                8000,
                r.usdcUsdOracle,
                address(s.treasury),
                abi.encodeCall(Treasury.usd8ToUsdcRate, ())
            );
        s.insurance
            .editInsuredToken(
                IERC20(r.aaveSgho), 8000, r.ghoUsdOracle, r.aaveSgho, abi.encodeCall(IERC4626.convertToAssets, (1e18))
            );
        s.insurance
            .editInsuredToken(
                IERC20(r.skySusds), 7000, r.usdsUsdOracle, r.skySusds, abi.encodeCall(IERC4626.convertToAssets, (1e18))
            );
        s.insurance
            .editInsuredToken(
                IERC20(r.msLoss), 8000, r.ghoUsdOracle, r.msLoss, abi.encodeCall(IERC4626.convertToAssets, (1e18))
            );
        s.registry.setSavingsVault(s.savingsVault);
        s.registry.setScoredToken(IERC20(s.savingsVault), SUSD8_SCORE_RATE);
        s.insurance
            .editInsuredToken(
                IERC20(s.savingsVault),
                8000,
                s.usd8PriceOracle,
                s.savingsVault,
                abi.encodeCall(IERC4626.convertToAssets, (1e18))
            );
        s.treasury.setProfitReceiver(s.savingsAdapter, 0, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        s.aaveStrategy = address(new ERC4626Strategy(address(s.treasury), s.registry, IERC4626(s.aaveUsdcVault)));
        s.morphoStrategy = address(new ERC4626Strategy(address(s.treasury), s.registry, IERC4626(s.morphoUsdcVault)));
        s.treasury.addStrategy(ERC4626Strategy(s.aaveStrategy), 0);
        s.treasury.addStrategy(ERC4626Strategy(s.morphoStrategy), 1);

        s.registry.setAdmin(admin, true);
        s.registry.setTimelock(r.timelock);
        require(s.registry.timelock() == r.timelock, "timelock handoff failed");
        require(address(s.treasury.USDC()) == s.usdc, "mock USDC binding failed");
    }

    function _log(System memory s, Reused memory r) private pure {
        console2.log("=== SEPOLIA MOCK-USDC STAGING SYSTEM ===");
        console2.log("mockUsdc", s.usdc);
        console2.log("aaveUsdcVault", s.aaveUsdcVault);
        console2.log("morphoUsdcVault", s.morphoUsdcVault);
        console2.log("registryImplementation", s.registryImplementation);
        console2.log("registry", address(s.registry));
        console2.log("usd8Implementation", s.usd8Implementation);
        console2.log("usd8", address(s.usd8));
        console2.log("treasuryImplementation", s.treasuryImplementation);
        console2.log("treasury", address(s.treasury));
        console2.log("savingsBootstrap", s.savingsBootstrap);
        console2.log("savingsVault", s.savingsVault);
        console2.log("savingsAdapter", s.savingsAdapter);
        console2.log("coverPoolImplementation", s.coverPoolImplementation);
        console2.log("coverPoolBeacon", s.coverPoolBeacon);
        console2.log("coverPool", address(s.pool));
        console2.log("defiInsuranceImplementation", s.defiInsuranceImplementation);
        console2.log("defiInsurance", address(s.insurance));
        console2.log("usd8PriceOracle", s.usd8PriceOracle);
        console2.log("aaveStrategy", s.aaveStrategy);
        console2.log("morphoStrategy", s.morphoStrategy);
        console2.log("reusedTimelock", r.timelock);
        console2.log("newContractInstances", uint256(17));
    }
}
