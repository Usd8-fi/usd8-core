// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SepoliaLossToken, SepoliaLossVault} from "./SepoliaLossFixture.sol";
import {SepoliaBatchSeeder} from "./SepoliaBatchSeeder.sol";

/// @notice Deploys disposable, agent-administered contracts for the Sepolia loss E2E.
/// @dev Testnet only. Listing the vault as insured is intentionally a separate timelock action.
contract DeploySepoliaLossFixtureScript is Script {
    function run() external returns (SepoliaLossToken token, SepoliaLossVault vault, SepoliaBatchSeeder seeder) {
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        require(msg.sender == admin, "broadcaster/admin mismatch");

        vm.startBroadcast();
        token = new SepoliaLossToken(admin);
        vault = new SepoliaLossVault(IERC20(address(token)), admin);
        seeder = new SepoliaBatchSeeder();
        vm.stopBroadcast();

        console2.log("=== Sepolia loss E2E fixture (TESTNET ONLY) ===");
        console2.log("mLOSS:", address(token));
        console2.log("msLOSS:", address(vault));
        console2.log("seeder:", address(seeder));
    }
}
