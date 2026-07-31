// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Treasury} from "../../src/Treasury.sol";
import {SepoliaLossToken} from "./SepoliaLossFixture.sol";
import {SepoliaBatchSeeder} from "./SepoliaBatchSeeder.sol";

/// @notice Seeds disposable E2E actors before any mLOSS incident exists.
/// @dev Testnet only. USD8 transfers begin real score history before the future reference block.
contract SeedSepoliaLossE2EScript is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant ETH_PER_ACTOR = 0.003 ether;
    uint256 internal constant USD8_MINT_USDC = 4e6;
    uint256 internal constant USD8_PER_CLAIMANT = 1e18;
    uint256 internal constant MLOSS_PER_CLAIMANT = 10e18;
    uint256 internal constant COVER_PER_LP = 1e18;

    function run() external {
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        address[] memory actors = new address[](5);
        actors[0] = vm.envAddress("SEPOLIA_LP1");
        actors[1] = vm.envAddress("SEPOLIA_LP2");
        actors[2] = vm.envAddress("SEPOLIA_CLAIMANT1");
        actors[3] = vm.envAddress("SEPOLIA_CLAIMANT2");
        actors[4] = vm.envAddress("SEPOLIA_KEEPER");
        require(msg.sender == admin, "broadcaster/admin mismatch");

        IERC20 usdc = IERC20(vm.envAddress("SEPOLIA_USDC"));
        IERC20 usd8 = IERC20(vm.envAddress("SEPOLIA_USD8"));
        IERC20 cover = IERC20(vm.envAddress("SEPOLIA_COVER_ASSET"));
        Treasury treasury = Treasury(vm.envAddress("SEPOLIA_TREASURY"));
        SepoliaLossToken lossToken = SepoliaLossToken(vm.envAddress("SEPOLIA_LOSS_TOKEN"));
        SepoliaBatchSeeder seeder = SepoliaBatchSeeder(vm.envAddress("SEPOLIA_BATCH_SEEDER"));

        vm.startBroadcast();
        seeder.distributeEther{value: actors.length * ETH_PER_ACTOR}(actors, ETH_PER_ACTOR);
        usdc.forceApprove(address(treasury), USD8_MINT_USDC);
        treasury.mintUSD8(USD8_MINT_USDC);
        usd8.safeTransfer(actors[2], USD8_PER_CLAIMANT);
        usd8.safeTransfer(actors[3], USD8_PER_CLAIMANT);
        lossToken.mint(actors[2], MLOSS_PER_CLAIMANT);
        lossToken.mint(actors[3], MLOSS_PER_CLAIMANT);
        cover.safeTransfer(actors[0], COVER_PER_LP);
        cover.safeTransfer(actors[1], COVER_PER_LP);
        vm.stopBroadcast();

        console2.log("=== Sepolia mLOSS E2E seed (TESTNET ONLY) ===");
        console2.log("actors:", actors.length);
        console2.log("ethPerActor:", ETH_PER_ACTOR);
        console2.log("usd8PerClaimant:", USD8_PER_CLAIMANT);
        console2.log("mLossPerClaimant:", MLOSS_PER_CLAIMANT);
        console2.log("coverPerLp:", COVER_PER_LP);
    }
}
