// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploymentConfig} from "../script/config/DeploymentConfig.sol";

contract DeploymentConfigHarness is DeploymentConfig {
    function governanceAdmin(uint256 chainId) external view returns (address) {
        return _governanceAdmin(chainId);
    }

    function load(uint256 chainId) external view returns (Addresses memory) {
        return _deploymentConfig(chainId);
    }

    function validate(uint256 chainId, Addresses memory addresses) external pure {
        _validateAddresses(chainId, addresses);
    }
}

contract DeploymentConfigTest is Test {
    DeploymentConfigHarness internal config;

    address internal constant MAINNET_ADMIN = 0xB2E999D531D45a9115dA7706adFc651999f3c1F1;
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant SEPOLIA_MORPHO_FACTORY = 0xb3fE2D5f8Af90f194B01db546397058Fcebb85D1;
    address internal constant SEPOLIA_BOOSTER = 0xC0012770848FCD350AB11906e93ba9fdfDA19f4c;

    function setUp() public {
        config = new DeploymentConfigHarness();
    }

    function test_MainnetSelectsCanonicalAddresses() public view {
        DeploymentConfig.Addresses memory a = config.load(1);

        assertEq(a.admin, MAINNET_ADMIN);
        assertEq(a.usdc, MAINNET_USDC);
        assertEq(a.morphoVaultV2Factory, 0xA1D94F746dEfa1928926b84fB2596c06926C0405);
        assertEq(a.booster, 0x6f74Ce39Bb1D75C56E2fe5f349a6A5f51ce6f12d);
        assertEq(a.coverAsset, 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        assertEq(a.coverAssetUsdOracle, 0x164b276057258d81941e97B0a900D4C7B358bCe0);
        assertEq(a.aaveUsdcVault, 0x73edDFa87C71ADdC275c2b9890f5c3a8480bC9E6);
        assertEq(a.morphoUsdcVault, 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB);
        assertEq(a.aaveSgho, 0xE1753F2e00940cC31213dd92013cF019DFE4ca1d);
        assertEq(a.ghoUsdOracle, 0xff221Bf2E61B62182210b3d42dE7f77da5b5b41F);
        assertEq(a.skySusds, 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
        assertEq(a.usdsUsdOracle, 0x592700e4FcDd674dC54d2681DED3B63f54F63f9A);
        assertEq(a.usdcUsdOracle, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        assertEq(a.seedSink, 0x000000000000000000000000000000000000dEaD);
    }

    function test_SepoliaGovernanceAdminLoadsIndependently() public {
        address admin = makeAddr("sepolia admin");
        vm.setEnv("SEPOLIA_ADMIN", vm.toString(admin));

        assertEq(config.governanceAdmin(11_155_111), admin);
    }

    function test_SepoliaSelectsOfficialUsdcAndConfiguredDependencies() public {
        address admin = makeAddr("sepolia admin");

        address coverAsset = makeAddr("sepolia cover asset");
        address coverOracle = makeAddr("sepolia cover oracle");
        address aaveVault = makeAddr("sepolia Aave vault");
        address morphoVault = makeAddr("sepolia Morpho vault");
        address sgho = makeAddr("sepolia sGHO");
        address ghoOracle = makeAddr("sepolia GHO oracle");
        address susds = makeAddr("sepolia sUSDS");
        address usdsOracle = makeAddr("sepolia USDS oracle");
        address usdcOracle = makeAddr("sepolia USDC oracle");

        vm.setEnv("SEPOLIA_ADMIN", vm.toString(admin));

        vm.setEnv("SEPOLIA_COVER_ASSET", vm.toString(coverAsset));
        vm.setEnv("SEPOLIA_COVER_ASSET_USD_ORACLE", vm.toString(coverOracle));
        vm.setEnv("SEPOLIA_AAVE_USDC_VAULT", vm.toString(aaveVault));
        vm.setEnv("SEPOLIA_MORPHO_USDC_VAULT", vm.toString(morphoVault));
        vm.setEnv("SEPOLIA_AAVE_SGHO", vm.toString(sgho));
        vm.setEnv("SEPOLIA_GHO_USD_ORACLE", vm.toString(ghoOracle));
        vm.setEnv("SEPOLIA_SKY_SUSDS", vm.toString(susds));
        vm.setEnv("SEPOLIA_USDS_USD_ORACLE", vm.toString(usdsOracle));
        vm.setEnv("SEPOLIA_USDC_USD_ORACLE", vm.toString(usdcOracle));

        DeploymentConfig.Addresses memory a = config.load(11_155_111);

        assertEq(a.admin, admin);
        assertEq(a.usdc, SEPOLIA_USDC);
        assertEq(a.morphoVaultV2Factory, SEPOLIA_MORPHO_FACTORY);
        assertEq(a.booster, SEPOLIA_BOOSTER);
        assertEq(a.coverAsset, coverAsset);
        assertEq(a.coverAssetUsdOracle, coverOracle);
        assertEq(a.aaveUsdcVault, aaveVault);
        assertEq(a.morphoUsdcVault, morphoVault);
        assertEq(a.aaveSgho, sgho);
        assertEq(a.ghoUsdOracle, ghoOracle);
        assertEq(a.skySusds, susds);
        assertEq(a.usdsUsdOracle, usdsOracle);
        assertEq(a.usdcUsdOracle, usdcOracle);
        assertEq(a.seedSink, 0x000000000000000000000000000000000000dEaD);
    }

    function test_UnsupportedChainReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeploymentConfig.UnsupportedChain.selector, uint256(31_337)));
        config.load(31_337);
    }

    function test_SepoliaRejectsZeroConfiguredAddress() public {
        DeploymentConfig.Addresses memory a = DeploymentConfig.Addresses({
            admin: address(1),
            usdc: address(1),
            seedSink: address(1),
            morphoVaultV2Factory: address(1),
            booster: address(1),
            coverAsset: address(1),
            coverAssetUsdOracle: address(0),
            aaveUsdcVault: address(1),
            morphoUsdcVault: address(1),
            aaveSgho: address(1),
            ghoUsdOracle: address(1),
            skySusds: address(1),
            usdsUsdOracle: address(1),
            usdcUsdOracle: address(1)
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfig.MissingAddress.selector, uint256(11_155_111), bytes32("coverAssetUsdOracle")
            )
        );
        config.validate(11_155_111, a);
    }
}
