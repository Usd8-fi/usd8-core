// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

/// @title USD8 Deployment Configuration
/// @notice Central source for every chain-specific address consumed by the
///         timelock and full-system deployment scripts.
/// @dev Ethereum mainnet uses reviewed release constants. Sepolia uses Circle's
///      canonical test USDC, the mainnet governance admin, and explicit environment values for USD8's
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
        address booster;
        address wsteth;
        address wstethUsdOracle;
        address usdcUsdOracle;
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
        a.admin = 0xB2E999D531D45a9115dA7706adFc651999f3c1F1;
        a.usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        a.seedSink = 0x000000000000000000000000000000000000dEaD;
        a.booster = 0x6f74Ce39Bb1D75C56E2fe5f349a6A5f51ce6f12d;
        a.wsteth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        a.wstethUsdOracle = 0x164b276057258d81941e97B0a900D4C7B358bCe0;
        a.usdcUsdOracle = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    }

    function _sepoliaConfig() private view returns (Addresses memory a) {
        a.admin = 0xB2E999D531D45a9115dA7706adFc651999f3c1F1;
        a.usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        a.seedSink = 0x000000000000000000000000000000000000dEaD;
        a.booster = 0xC0012770848FCD350AB11906e93ba9fdfDA19f4c;
        a.wsteth = vm.envAddress("SEPOLIA_COVER_ASSET");
        a.wstethUsdOracle = vm.envAddress("SEPOLIA_COVER_ASSET_USD_ORACLE");
        a.usdcUsdOracle = vm.envAddress("SEPOLIA_USDC_USD_ORACLE");
    }

    function _validateAddresses(uint256 chainId, Addresses memory a) internal pure {
        _requireAddress(chainId, a.admin, "admin");
        _requireAddress(chainId, a.usdc, "usdc");
        _requireAddress(chainId, a.seedSink, "seedSink");
        _requireAddress(chainId, a.booster, "booster");
        _requireAddress(chainId, a.wsteth, "wsteth");
        _requireAddress(chainId, a.wstethUsdOracle, "wstethUsdOracle");
        _requireAddress(chainId, a.usdcUsdOracle, "usdcUsdOracle");
    }

    function _requireAddress(uint256 chainId, address value, bytes32 field) private pure {
        if (value == address(0)) revert MissingAddress(chainId, field);
    }
}
