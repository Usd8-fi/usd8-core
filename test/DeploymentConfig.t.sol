// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploymentConfig} from "../script/config/DeploymentConfig.sol";

contract DeploymentConfigHarness is DeploymentConfig {
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
    address internal constant SEPOLIA_BOOSTER = 0xC0012770848FCD350AB11906e93ba9fdfDA19f4c;

    function setUp() public {
        config = new DeploymentConfigHarness();
    }

    function test_MainnetSelectsCanonicalAddresses() public view {
        DeploymentConfig.Addresses memory a = config.load(1);

        assertEq(a.admin, MAINNET_ADMIN);
        assertEq(a.usdc, MAINNET_USDC);
        assertEq(a.booster, 0x6f74Ce39Bb1D75C56E2fe5f349a6A5f51ce6f12d);
        assertEq(a.wsteth, 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        assertEq(a.wstethUsdOracle, 0x164b276057258d81941e97B0a900D4C7B358bCe0);
        assertEq(a.usdcUsdOracle, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        assertEq(a.seedSink, 0x000000000000000000000000000000000000dEaD);
    }

    function test_SepoliaSelectsOfficialUsdcAndConfiguredDependencies() public {
        address wsteth = makeAddr("sepolia cover asset");
        address coverOracle = makeAddr("sepolia cover oracle");
        address usdcOracle = makeAddr("sepolia USDC oracle");

        vm.setEnv("SEPOLIA_COVER_ASSET", vm.toString(wsteth));
        vm.setEnv("SEPOLIA_COVER_ASSET_USD_ORACLE", vm.toString(coverOracle));
        vm.setEnv("SEPOLIA_USDC_USD_ORACLE", vm.toString(usdcOracle));

        DeploymentConfig.Addresses memory a = config.load(11_155_111);

        assertEq(a.admin, MAINNET_ADMIN);
        assertEq(a.usdc, SEPOLIA_USDC);
        assertEq(a.booster, SEPOLIA_BOOSTER);
        assertEq(a.wsteth, wsteth);
        assertEq(a.wstethUsdOracle, coverOracle);
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
            booster: address(1),
            wsteth: address(1),
            wstethUsdOracle: address(0),
            usdcUsdOracle: address(1)
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentConfig.MissingAddress.selector, uint256(11_155_111), bytes32("wstethUsdOracle")
            )
        );
        config.validate(11_155_111, a);
    }
}
