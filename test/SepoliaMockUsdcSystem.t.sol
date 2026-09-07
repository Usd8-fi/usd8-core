// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2Factory} from "vault-v2/src/VaultV2Factory.sol";
import {Registry} from "../src/Registry.sol";
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {SepoliaTestToken, SepoliaTestVault, SepoliaTestOracle} from "../script/testnet/SepoliaDependencies.sol";
import {DeploySepoliaMockUsdcSystemScript} from "../script/testnet/11_DeploySepoliaMockUsdcSystem.s.sol";

contract DeploySepoliaMockUsdcSystemHarness is DeploySepoliaMockUsdcSystemScript {
    function deployForTest(address admin, Reused memory reused) external returns (System memory) {
        return _deploy(admin, reused);
    }
}

contract SepoliaMockUsdcSystemTest is Test {
    DeploySepoliaMockUsdcSystemHarness internal harness;
    TimelockController internal timelock;
    DeploySepoliaMockUsdcSystemScript.Reused internal reused;

    function setUp() public {
        harness = new DeploySepoliaMockUsdcSystemHarness();
        address admin = address(harness);

        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(30 minutes, proposers, executors, address(0));

        SepoliaTestToken coverAsset = new SepoliaTestToken("Sepolia Mock wstETH", "mwstETH", 18, admin, 1_000e18);
        SepoliaTestOracle coverFeed = new SepoliaTestOracle(admin, "mwstETH / USD", 8, 4_000e8);

        SepoliaTestToken gho = new SepoliaTestToken("Sepolia Mock GHO", "mGHO", 18, admin, 0);
        SepoliaTestVault sgho = new SepoliaTestVault(IERC20(address(gho)), "Sepolia Mock Savings GHO", "msGHO");
        SepoliaTestOracle ghoFeed = new SepoliaTestOracle(admin, "mGHO / USD", 8, 1e8);

        SepoliaTestToken usds = new SepoliaTestToken("Sepolia Mock USDS", "mUSDS", 18, admin, 0);
        SepoliaTestVault susds = new SepoliaTestVault(IERC20(address(usds)), "Sepolia Mock Savings USDS", "msUSDS");
        SepoliaTestOracle usdsFeed = new SepoliaTestOracle(admin, "mUSDS / USD", 8, 1e8);
        SepoliaTestOracle usdcFeed = new SepoliaTestOracle(admin, "mUSDC / USD", 8, 1e8);
        SepoliaTestToken mockUsdc =
            new SepoliaTestToken("Sepolia Mock USDC", "mUSDC", 6, admin, harness.MOCK_USDC_INITIAL_SUPPLY());
        SepoliaTestVault aaveUsdcVault =
            new SepoliaTestVault(IERC20(address(mockUsdc)), "Sepolia Mock Aave USDC", "maUSDC");
        SepoliaTestVault morphoUsdcVault =
            new SepoliaTestVault(IERC20(address(mockUsdc)), "Sepolia Mock Morpho USDC", "mmUSDC");
        reused = DeploySepoliaMockUsdcSystemScript.Reused({
            timelock: address(timelock),
            mockUsdc: address(mockUsdc),
            aaveUsdcVault: address(aaveUsdcVault),
            morphoUsdcVault: address(morphoUsdcVault),
            morphoVaultV2Factory: address(new VaultV2Factory()),
            booster: address(0xC0012770848FCD350AB11906e93ba9fdfDA19f4c),
            coverAsset: address(coverAsset),
            coverAssetUsdOracle: address(coverFeed),
            aaveSgho: address(sgho),
            ghoUsdOracle: address(ghoFeed),
            skySusds: address(susds),
            usdsUsdOracle: address(usdsFeed),
            usdcUsdOracle: address(usdcFeed),
            msLoss: address(sgho)
        });
    }

    /// forge-config: default.isolate = true
    function test_DeploysCurrentSourceStackBoundToOwnedMockUsdc() public {
        address admin = address(harness);
        DeploySepoliaMockUsdcSystemScript.System memory s = harness.deployForTest(admin, reused);
        IERC20 usdc = IERC20(s.usdc);

        assertEq(IERC20Metadata(s.usdc).name(), "Sepolia Mock USDC");
        assertEq(IERC20Metadata(s.usdc).symbol(), "mUSDC");
        assertEq(IERC20Metadata(s.usdc).decimals(), 6);
        assertEq(SepoliaTestToken(s.usdc).admin(), admin);
        assertEq(usdc.balanceOf(admin), harness.MOCK_USDC_INITIAL_SUPPLY() - harness.SEED_USDC());
        assertEq(IERC4626(s.aaveUsdcVault).asset(), s.usdc);
        assertEq(IERC4626(s.morphoUsdcVault).asset(), s.usdc);

        assertEq(address(s.treasury.USDC()), s.usdc);
        assertEq(s.registry.usd8(), address(s.usd8));
        assertEq(s.registry.treasury(), address(s.treasury));
        assertEq(s.registry.defiInsurance(), address(s.insurance));
        assertEq(s.registry.savingsVault(), s.savingsVault);
        assertEq(s.registry.usd8PriceOracle(), s.usd8PriceOracle);
        assertEq(s.registry.timelock(), address(timelock));
        assertTrue(s.registry.isAdmin(admin));
        assertEq(UpgradeableBeacon(s.coverPoolBeacon).owner(), address(timelock));
        assertEq(UpgradeableBeacon(s.coverPoolBeacon).implementation(), s.coverPoolImplementation);
        assertEq(s.pool.depositCap(), harness.COVER_POOL_CAP());
        assertEq(s.registry.teePcrHash(), harness.MEASURED_TEE_PCR());
        assertTrue(s.insurance.isTeeSigner(harness.MEASURED_TEE_SIGNER()));

        Registry.IncidentTimingConfig memory incidentTiming = s.registry.incidentTimingConfig();
        Registry.IncidentOpenPriceConfig memory openPrice = s.registry.incidentOpenPriceConfig();
        assertEq(incidentTiming.phaseWindow, 1 hours);
        assertEq(incidentTiming.maxReferenceBlockAge, 450);
        assertEq(openPrice.twapBlocks, 4);
        assertEq(openPrice.sampleStepBlocks, 2);
        assertEq(openPrice.minimumDropBps, 2_000);

        assertEq(ERC4626Strategy(s.aaveStrategy).underlying(), s.usdc);
        assertEq(address(ERC4626Strategy(s.aaveStrategy).vault()), s.aaveUsdcVault);
        assertEq(ERC4626Strategy(s.morphoStrategy).underlying(), s.usdc);
        assertEq(address(ERC4626Strategy(s.morphoStrategy).vault()), s.morphoUsdcVault);
        assertEq(IVaultV2(s.savingsVault).asset(), address(s.usd8));
        assertEq(IVaultV2(s.savingsVault).owner(), address(timelock));
        assertEq(s.pool.asset(), reused.coverAsset);
        assertEq(address(s.pool.registry()), address(s.registry));

        address[17] memory instances = [
            s.registryImplementation,
            address(s.registry),
            s.usd8Implementation,
            address(s.usd8),
            s.treasuryImplementation,
            address(s.treasury),
            s.savingsBootstrap,
            s.savingsVault,
            s.savingsAdapter,
            s.coverPoolImplementation,
            s.coverPoolBeacon,
            address(s.pool),
            s.defiInsuranceImplementation,
            address(s.insurance),
            s.usd8PriceOracle,
            s.aaveStrategy,
            s.morphoStrategy
        ];
        for (uint256 i; i < instances.length; ++i) {
            assertGt(instances[i].code.length, 0);
        }
    }

    function test_SepoliaDeploymentFailsClosedOnMainnet() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeploySepoliaMockUsdcSystemScript.SepoliaOnly.selector, 1));
        harness.run();
    }

    function test_ProductionDefaultsRemainCanonical() public {
        Registry registryImplementation = new Registry();
        Registry registry = Registry(
            address(
                new ERC1967Proxy(
                    address(registryImplementation), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        DefiInsurance insuranceImplementation = new DefiInsurance();
        DefiInsurance insurance = DefiInsurance(
            address(
                new ERC1967Proxy(address(insuranceImplementation), abi.encodeCall(DefiInsurance.initialize, (registry)))
            )
        );

        Registry.IncidentTimingConfig memory incidentTiming = registry.incidentTimingConfig();
        Registry.ExitTimingConfig memory exitTiming = registry.exitTimingConfig();
        Registry.IncidentOpenPriceConfig memory openPrice = registry.incidentOpenPriceConfig();
        (uint64 twapLookbackBlocks, uint64 minHoldingRequired, uint64 settlementSampleStepBlocks) =
            insurance.settlementParams();

        assertEq(incidentTiming.phaseWindow, 3 days);
        assertEq(incidentTiming.maxReferenceBlockAge, 43_200);
        assertEq(exitTiming.unstakeCooldown, 7 days);
        assertEq(exitTiming.exitBatchInterval, 3 days);
        assertEq(openPrice.twapBlocks, 7_200);
        assertEq(openPrice.sampleStepBlocks, 300);
        assertEq(openPrice.minimumDropBps, 2_000);
        assertEq(twapLookbackBlocks, 50_400);
        assertEq(minHoldingRequired, 50_400);
        assertEq(settlementSampleStepBlocks, 300);
    }

    /// forge-config: default.isolate = true
    function test_MockUsdcSupportsTreasuryMintAndExactRedeem() public {
        address admin = address(harness);
        DeploySepoliaMockUsdcSystemScript.System memory s = harness.deployForTest(admin, reused);
        IERC20 usdc = IERC20(s.usdc);

        uint256 balanceBefore = usdc.balanceOf(admin);
        vm.startPrank(admin);
        usdc.approve(address(s.treasury), 1e6);
        s.treasury.mintUSD8(1e6);
        assertEq(s.usd8.balanceOf(admin), 1e18);
        assertEq(usdc.balanceOf(admin), balanceBefore - 1e6);

        s.treasury.redeemUSD8(1e18, 1e6);
        vm.stopPrank();

        assertEq(s.usd8.balanceOf(admin), 0);
        assertEq(usdc.balanceOf(admin), balanceBefore);
    }
}
