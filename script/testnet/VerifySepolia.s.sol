// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";
import {Treasury} from "../../src/Treasury.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";

interface IOwnableView {
    function owner() external view returns (address);
}

interface IUpgradeableBeaconView {
    function implementation() external view returns (address);
}

/// @notice Verifies a fresh USD8 Sepolia staging deployment from explicit environment addresses.
contract VerifySepolia is Script {
    uint256 private constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 private constant TIMELOCK_DELAY = 24 hours;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Deployment {
        address admin;
        address usdc;
        address booster;
        address seedSink;
        address coverAsset;
        address coverOracle;
        address aaveVault;
        address morphoVault;
        address sgho;
        address ghoOracle;
        address susds;
        address usdsOracle;
        address usdcOracle;
        address timelock;
        address registry;
        address registryImplementation;
        address usd8;
        address usd8Implementation;
        address treasury;
        address treasuryImplementation;
        address coverPool;
        address coverPoolBeacon;
        address coverPoolImplementation;
        address aaveStrategy;
        address morphoStrategy;
        address savingsVault;
        address defiInsurance;
        address defiInsuranceImplementation;
        address usd8PriceOracle;
    }

    function run() external view {
        require(block.chainid == SEPOLIA_CHAIN_ID, "wrong chain");
        Deployment memory d = _deployment();
        _verifyDependencies(d);
        _verifyTimelock(d);
        _verifyRegistry(d);
        _verifyAssetsAndStrategies(d);
        _verifyInsurance(d);

        console2.log("USD8 Sepolia deployment verified");
        console2.log("Timelock:", d.timelock);
        console2.log("Registry:", d.registry);
        console2.log("USD8:", d.usd8);
        console2.log("Treasury:", d.treasury);
        console2.log("sUSD8:", d.savingsVault);
        console2.log("DefiInsurance:", d.defiInsurance);
    }

    function _deployment() private view returns (Deployment memory d) {
        d.admin = vm.envAddress("SEPOLIA_ADMIN");
        d.usdc = vm.envAddress("SEPOLIA_USDC");
        d.booster = vm.envAddress("SEPOLIA_BOOSTER");
        d.seedSink = vm.envOr("SEPOLIA_SEED_SINK", address(0xdead));
        d.coverAsset = vm.envAddress("SEPOLIA_COVER_ASSET");
        d.coverOracle = vm.envAddress("SEPOLIA_COVER_ASSET_USD_ORACLE");
        d.aaveVault = vm.envAddress("SEPOLIA_AAVE_USDC_VAULT");
        d.morphoVault = vm.envAddress("SEPOLIA_MORPHO_USDC_VAULT");
        d.sgho = vm.envAddress("SEPOLIA_AAVE_SGHO");
        d.ghoOracle = vm.envAddress("SEPOLIA_GHO_USD_ORACLE");
        d.susds = vm.envAddress("SEPOLIA_SKY_SUSDS");
        d.usdsOracle = vm.envAddress("SEPOLIA_USDS_USD_ORACLE");
        d.usdcOracle = vm.envAddress("SEPOLIA_USDC_USD_ORACLE");
        d.timelock = vm.envAddress("SEPOLIA_TIMELOCK");
        d.registry = vm.envAddress("SEPOLIA_REGISTRY");
        d.registryImplementation = vm.envAddress("SEPOLIA_REGISTRY_IMPLEMENTATION");
        d.usd8 = vm.envAddress("SEPOLIA_USD8");
        d.usd8Implementation = vm.envAddress("SEPOLIA_USD8_IMPLEMENTATION");
        d.treasury = vm.envAddress("SEPOLIA_TREASURY");
        d.treasuryImplementation = vm.envAddress("SEPOLIA_TREASURY_IMPLEMENTATION");
        d.coverPool = vm.envAddress("SEPOLIA_COVER_POOL");
        d.coverPoolBeacon = vm.envAddress("SEPOLIA_COVER_POOL_BEACON");
        d.coverPoolImplementation = vm.envAddress("SEPOLIA_COVER_POOL_IMPLEMENTATION");
        d.aaveStrategy = vm.envAddress("SEPOLIA_AAVE_STRATEGY");
        d.morphoStrategy = vm.envAddress("SEPOLIA_MORPHO_STRATEGY");
        d.savingsVault = vm.envAddress("SEPOLIA_SAVINGS_VAULT");
        d.defiInsurance = vm.envAddress("SEPOLIA_DEFI_INSURANCE");
        d.defiInsuranceImplementation = vm.envAddress("SEPOLIA_DEFI_INSURANCE_IMPLEMENTATION");
        d.usd8PriceOracle = vm.envAddress("SEPOLIA_USD8_PRICE_ORACLE");
    }

    function _verifyDependencies(Deployment memory d) private view {
        _requireCode(d.usdc);
        _requireCode(d.booster);
        _requireCode(d.coverAsset);
        _requireCode(d.coverOracle);
        _requireCode(d.aaveVault);
        _requireCode(d.morphoVault);
        _requireCode(d.sgho);
        _requireCode(d.ghoOracle);
        _requireCode(d.susds);
        _requireCode(d.usdsOracle);
        _requireCode(d.usdcOracle);
        require(IERC4626(d.aaveVault).asset() == d.usdc, "wrong Aave mock asset");
        require(IERC4626(d.morphoVault).asset() == d.usdc, "wrong Morpho mock asset");
        require(IERC4626(d.sgho).convertToAssets(1e18) != 0, "bad sGHO conversion");
        require(IERC4626(d.susds).convertToAssets(1e18) != 0, "bad sUSDS conversion");
        _requirePositiveOracle(d.coverOracle);
        _requirePositiveOracle(d.ghoOracle);
        _requirePositiveOracle(d.usdsOracle);
        _requirePositiveOracle(d.usdcOracle);
    }

    function _verifyTimelock(Deployment memory d) private view {
        TimelockController timelock = TimelockController(payable(d.timelock));
        require(timelock.getMinDelay() == TIMELOCK_DELAY, "wrong timelock delay");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), d.admin), "missing proposer");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), d.admin), "missing canceller");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "executor not open");
        require(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), d.timelock), "timelock not self-admin");
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), d.admin), "external timelock admin");
    }

    function _verifyRegistry(Deployment memory d) private view {
        Registry registry = Registry(d.registry);
        require(registry.timelock() == d.timelock, "wrong Registry timelock");
        require(registry.isAdmin(d.admin), "missing beta admin");
        require(registry.usd8() == d.usd8, "wrong canonical USD8");
        require(registry.treasury() == d.treasury, "wrong canonical Treasury");
        require(registry.savingsVault() == d.savingsVault, "wrong canonical savings vault");
        require(registry.defiInsurance() == d.defiInsurance, "wrong payout module");
        require(registry.usd8PriceOracle() == d.usd8PriceOracle, "wrong USD8 oracle");
        require(_implementation(d.registry) == d.registryImplementation, "wrong Registry implementation");

        (address boosterCollection, uint64 boosterId, uint16 boosterBoostBps) = registry.boosterConfig();
        require(boosterCollection == d.booster && boosterId == 1 && boosterBoostBps == 100, "wrong booster");

        Registry.IncidentTimingConfig memory incidentTiming = registry.incidentTimingConfig();
        require(
            incidentTiming.phaseWindow == 3 days && incidentTiming.maxReferenceBlockAge == 43_200,
            "wrong incident timing"
        );
        Registry.ExitTimingConfig memory exitTiming = registry.exitTimingConfig();
        require(exitTiming.unstakeCooldown == 7 days && exitTiming.exitBatchInterval == 3 days, "wrong exit timing");
        Registry.IncidentOpenPriceConfig memory openPrice = registry.incidentOpenPriceConfig();
        require(
            openPrice.twapBlocks == 7_200 && openPrice.sampleStepBlocks == 300 && openPrice.minimumDropBps == 2_000,
            "wrong incident-open price policy"
        );

        (IERC20[] memory assets, address[] memory pools) = registry.coverPools();
        require(assets.length == 1 && address(assets[0]) == d.coverAsset, "wrong cover asset");
        require(pools.length == 1 && pools[0] == d.coverPool, "wrong cover pool");
    }

    function _verifyAssetsAndStrategies(Deployment memory d) private view {
        USD8 usd8 = USD8(d.usd8);
        Treasury treasury = Treasury(d.treasury);
        SingleAssetCoverPool pool = SingleAssetCoverPool(d.coverPool);
        require(_implementation(d.usd8) == d.usd8Implementation, "wrong USD8 implementation");
        require(_implementation(d.treasury) == d.treasuryImplementation, "wrong Treasury implementation");
        require(usd8.treasury() == d.treasury, "USD8 Treasury mismatch");
        require(address(treasury.USDC()) == d.usdc, "wrong reserve asset");
        require(treasury.strategies(0) == ERC4626Strategy(d.aaveStrategy), "wrong strategy zero");
        require(treasury.strategies(1) == ERC4626Strategy(d.morphoStrategy), "wrong strategy one");
        require(address(ERC4626Strategy(d.aaveStrategy).vault()) == d.aaveVault, "wrong Aave strategy vault");
        require(address(ERC4626Strategy(d.morphoStrategy).vault()) == d.morphoVault, "wrong Morpho strategy vault");
        require(address(pool.asset()) == d.coverAsset, "pool asset mismatch");
        require(pool.balanceOf(d.seedSink) != 0 && pool.totalAssets() >= 0.01 ether, "cover seed missing");
        require(IOwnableView(d.coverPoolBeacon).owner() == d.timelock, "wrong beacon owner");
        require(
            IUpgradeableBeaconView(d.coverPoolBeacon).implementation() == d.coverPoolImplementation,
            "wrong cover-pool implementation"
        );

        IERC4626 savings = IERC4626(d.savingsVault);
        require(savings.asset() == d.usd8, "wrong savings asset");
        require(savings.totalSupply() >= 10e18, "savings seed supply missing");
        require(IERC20(d.savingsVault).balanceOf(d.seedSink) == 10e18, "wrong savings seed balance");
        require(IERC20(d.usdc).balanceOf(d.treasury) == 10e6, "wrong backing seed");
    }

    function _verifyInsurance(Deployment memory d) private view {
        DefiInsurance insurance = DefiInsurance(d.defiInsurance);
        require(_implementation(d.defiInsurance) == d.defiInsuranceImplementation, "wrong insurance implementation");
        require(insurance.isInsuredToken(IERC20(d.usd8)), "USD8 not insured");
        require(insurance.isInsuredToken(IERC20(d.savingsVault)), "sUSD8 not insured");
        require(insurance.isInsuredToken(IERC20(d.sgho)), "sGHO not insured");
        require(insurance.isInsuredToken(IERC20(d.susds)), "sUSDS not insured");
        require(insurance.activeIncidentId() == 0, "incident unexpectedly active");
    }

    function _requireCode(address candidate) private view {
        require(candidate.code.length != 0, "configured address has no code");
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _requirePositiveOracle(address oracle) private view {
        (bool ok, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(ok && data.length >= 160, "invalid oracle response");
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        require(answer > 0 && updatedAt != 0 && answeredInRound >= roundId, "invalid oracle round");
    }
}
