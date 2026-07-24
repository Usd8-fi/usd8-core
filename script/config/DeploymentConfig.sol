// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

/// @title USD8 Deployment Configuration
/// @notice Central source for every chain-specific address consumed by the
///         timelock and full-system deployment scripts.
/// @dev Ethereum mainnet uses reviewed release constants. Sepolia uses Circle's
///      canonical test USDC and requires explicit environment values for USD8's
///      own/test dependency deployments because those addresses are not canonical.
abstract contract DeploymentConfig is Script {
    uint256 internal constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    uint256 internal constant ETHEREUM_SEPOLIA_CHAIN_ID = 11_155_111;

    error UnsupportedChain(uint256 chainId);
    error MissingAddress(uint256 chainId, bytes32 field);

    struct Addresses {
        address admin;
        address usdc;
        address seedSink;
        address morphoVaultV2Factory;
        address booster;
        address coverAsset;
        address coverAssetUsdOracle;
        address aaveUsdcVault;
        address morphoUsdcVault;
        address aaveSgho;
        address ghoUsdOracle;
        address skySusds;
        address usdsUsdOracle;
        address usdcUsdOracle;
    }

    function _governanceAdmin(uint256 chainId) internal view returns (address admin) {
        if (chainId == ETHEREUM_MAINNET_CHAIN_ID) {
            admin = 0xB2E999D531D45a9115dA7706adFc651999f3c1F1;
        } else if (chainId == ETHEREUM_SEPOLIA_CHAIN_ID) {
            admin = vm.envAddress("SEPOLIA_ADMIN");
        } else {
            revert UnsupportedChain(chainId);
        }
        _requireAddress(chainId, admin, "admin");
    }

    function _deploymentConfig(uint256 chainId) internal view returns (Addresses memory a) {
        if (chainId == ETHEREUM_MAINNET_CHAIN_ID) {
            a = _mainnetConfig();
        } else if (chainId == ETHEREUM_SEPOLIA_CHAIN_ID) {
            a = _sepoliaConfig();
        } else {
            revert UnsupportedChain(chainId);
        }
        _validateAddresses(chainId, a);
    }

    function _mainnetConfig() private view returns (Addresses memory a) {
        a.admin = _governanceAdmin(ETHEREUM_MAINNET_CHAIN_ID);
        a.usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        a.seedSink = 0x000000000000000000000000000000000000dEaD;
        a.morphoVaultV2Factory = 0xA1D94F746dEfa1928926b84fB2596c06926C0405;
        a.booster = 0x6f74Ce39Bb1D75C56E2fe5f349a6A5f51ce6f12d;
        a.coverAsset = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        a.coverAssetUsdOracle = 0x164b276057258d81941e97B0a900D4C7B358bCe0;
        // Must be re-reviewed/replaced before a live mainnet launch.
        a.aaveUsdcVault = 0x73edDFa87C71ADdC275c2b9890f5c3a8480bC9E6;
        a.morphoUsdcVault = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
        a.aaveSgho = 0xE1753F2e00940cC31213dd92013cF019DFE4ca1d;
        a.ghoUsdOracle = 0xff221Bf2E61B62182210b3d42dE7f77da5b5b41F;
        a.skySusds = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
        a.usdsUsdOracle = 0x592700e4FcDd674dC54d2681DED3B63f54F63f9A;
        a.usdcUsdOracle = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    }

    function _sepoliaConfig() private view returns (Addresses memory a) {
        a.admin = _governanceAdmin(ETHEREUM_SEPOLIA_CHAIN_ID);
        a.usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        a.seedSink = 0x000000000000000000000000000000000000dEaD;
        a.morphoVaultV2Factory = 0xb3fE2D5f8Af90f194B01db546397058Fcebb85D1;
        a.booster = 0xC0012770848FCD350AB11906e93ba9fdfDA19f4c;
        a.coverAsset = vm.envAddress("SEPOLIA_COVER_ASSET");
        a.coverAssetUsdOracle = vm.envAddress("SEPOLIA_COVER_ASSET_USD_ORACLE");
        a.aaveUsdcVault = vm.envAddress("SEPOLIA_AAVE_USDC_VAULT");
        a.morphoUsdcVault = vm.envAddress("SEPOLIA_MORPHO_USDC_VAULT");
        a.aaveSgho = vm.envAddress("SEPOLIA_AAVE_SGHO");
        a.ghoUsdOracle = vm.envAddress("SEPOLIA_GHO_USD_ORACLE");
        a.skySusds = vm.envAddress("SEPOLIA_SKY_SUSDS");
        a.usdsUsdOracle = vm.envAddress("SEPOLIA_USDS_USD_ORACLE");
        a.usdcUsdOracle = vm.envAddress("SEPOLIA_USDC_USD_ORACLE");
    }

    function _validateAddresses(uint256 chainId, Addresses memory a) internal pure {
        _requireAddress(chainId, a.admin, "admin");
        _requireAddress(chainId, a.usdc, "usdc");
        _requireAddress(chainId, a.seedSink, "seedSink");
        _requireAddress(chainId, a.morphoVaultV2Factory, "morphoVaultV2Factory");
        _requireAddress(chainId, a.booster, "booster");
        _requireAddress(chainId, a.coverAsset, "coverAsset");
        _requireAddress(chainId, a.coverAssetUsdOracle, "coverAssetUsdOracle");
        _requireAddress(chainId, a.aaveUsdcVault, "aaveUsdcVault");
        _requireAddress(chainId, a.morphoUsdcVault, "morphoUsdcVault");
        _requireAddress(chainId, a.aaveSgho, "aaveSgho");
        _requireAddress(chainId, a.ghoUsdOracle, "ghoUsdOracle");
        _requireAddress(chainId, a.skySusds, "skySusds");
        _requireAddress(chainId, a.usdsUsdOracle, "usdsUsdOracle");
        _requireAddress(chainId, a.usdcUsdOracle, "usdcUsdOracle");
    }

    function _requireAddress(uint256 chainId, address value, bytes32 field) private pure {
        if (value == address(0)) revert MissingAddress(chainId, field);
    }
}
