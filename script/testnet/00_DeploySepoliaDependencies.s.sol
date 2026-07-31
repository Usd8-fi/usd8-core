// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2, Script} from "forge-std/Script.sol";
import {SepoliaDependencies} from "./SepoliaDependencies.sol";

/// @notice Deploys the staging-only dependencies consumed by the USD8 Sepolia deployment.
/// @dev Production contracts under src/ are intentionally untouched. The broadcaster must
///      equal SEPOLIA_ADMIN so mock assets are minted to the account that seeds the system.
contract DeploySepoliaDependenciesScript is Script {
    function run() external returns (SepoliaDependencies dependencies) {
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        address usdc = vm.envAddress("SEPOLIA_USDC");
        require(msg.sender == admin, "broadcaster/admin mismatch");

        vm.startBroadcast();
        dependencies = new SepoliaDependencies(admin, usdc);
        vm.stopBroadcast();

        console2.log("=== 00 Sepolia staging dependencies ===");
        console2.log("Dependencies:       ", address(dependencies));
        console2.log("coverAsset:         ", dependencies.coverAsset());
        console2.log("coverAssetUsdOracle:", dependencies.coverAssetUsdOracle());
        console2.log("aaveUsdcVault:      ", dependencies.aaveUsdcVault());
        console2.log("morphoUsdcVault:    ", dependencies.morphoUsdcVault());
        console2.log("gho:                 ", dependencies.gho());
        console2.log("aaveSgho:            ", dependencies.aaveSgho());
        console2.log("ghoUsdOracle:        ", dependencies.ghoUsdOracle());
        console2.log("usds:                ", dependencies.usds());
        console2.log("skySusds:            ", dependencies.skySusds());
        console2.log("usdsUsdOracle:       ", dependencies.usdsUsdOracle());
        console2.log("usdcUsdOracle:       ", dependencies.usdcUsdOracle());
    }
}
