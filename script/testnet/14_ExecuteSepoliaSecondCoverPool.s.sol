// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../../src/Registry.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";

/// @notice Executes the timelocked registration of the second Sepolia cover pool.
/// @dev Staging only. Environment inputs must match the canonical deployment plan.
contract ExecuteSepoliaSecondCoverPoolScript is Script {
    uint256 internal constant CHAIN_ID = 11_155_111;
    uint256 internal constant EXPECTED_EXISTING_POOLS = 1;
    uint256 internal constant EXPECTED_FINAL_POOLS = 2;
    bytes32 internal constant ADD_POOL_SALT = keccak256("USD8 Sepolia second cover pool mGHO 2026-08-30");
    IERC20 internal constant EXISTING_ASSET = IERC20(0xdfaf9C1CE55f18AB7850EDd84F2175ce734985fa);
    address internal constant EXISTING_FEED = 0x00E79aFB10A84D153803F00e73900803179D594e;
    address internal constant EXISTING_POOL = 0x55cb69271da9937d0Cb3c548409FD3f77586dF79;
    address internal constant CANONICAL_ASSET = 0xBBd327336D5135E146312dD16F2491C1E6ce8822;
    address internal constant CANONICAL_FEED = 0xDa725125d8ff0588496382427ab65Bc8f8D639Eb;
    address internal constant CANONICAL_POOL = 0x8917f4C377dD0e5Bd4909D8A00B508F38C0f3f4F;

    function run() external returns (bytes32 operationId) {
        if (block.chainid != CHAIN_ID) revert("Sepolia only");

        address admin = vm.envAddress("SEPOLIA_ADMIN");
        Registry registry = Registry(vm.envAddress("SEPOLIA_REGISTRY"));
        DefiInsurance insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        TimelockController timelock = TimelockController(payable(vm.envAddress("SEPOLIA_TIMELOCK")));
        SingleAssetCoverPool pool = SingleAssetCoverPool(vm.envAddress("SEPOLIA_SECOND_COVER_POOL"));
        IERC20 asset = IERC20(vm.envAddress("SEPOLIA_SECOND_COVER_ASSET"));
        address feed = vm.envAddress("SEPOLIA_SECOND_COVER_FEED");

        require(msg.sender == admin, "broadcaster/admin mismatch");
        require(address(registry).code.length != 0, "missing registry");
        require(address(insurance).code.length != 0, "missing insurance");
        require(address(timelock).code.length != 0, "missing timelock");
        require(address(pool).code.length != 0, "missing pool");
        require(address(asset).code.length != 0, "missing asset");
        require(feed.code.length != 0, "missing feed");
        require(address(pool) == CANONICAL_POOL, "noncanonical pool");
        require(address(asset) == CANONICAL_ASSET, "noncanonical asset");
        require(feed == CANONICAL_FEED, "noncanonical feed");
        require(registry.timelock() == address(timelock), "registry timelock mismatch");
        require(insurance.activeIncidentId() == 0, "incident active");
        require(registry.coverPoolsLength() == EXPECTED_EXISTING_POOLS, "unexpected pool topology");
        require(address(pool.asset()) == address(asset), "pool asset mismatch");
        require(registry.coverPool(asset) == address(0), "pool already registered");
        require(registry.assetUsdFeed(asset) == address(0), "feed already registered");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "executor role is not open");
        (IERC20[] memory existingAssets, address[] memory existingPools) = registry.coverPools();
        require(existingAssets.length == EXPECTED_EXISTING_POOLS, "existing asset count mismatch");
        require(existingPools.length == EXPECTED_EXISTING_POOLS, "existing pool count mismatch");
        require(existingAssets[0] == EXISTING_ASSET, "existing asset order mismatch");
        require(existingPools[0] == EXISTING_POOL, "existing pool order mismatch");
        require(registry.coverPool(EXISTING_ASSET) == EXISTING_POOL, "existing pool mapping mismatch");
        require(registry.assetUsdFeed(EXISTING_ASSET) == EXISTING_FEED, "existing feed mapping mismatch");

        bytes memory payload = abi.encodeCall(Registry.addPool, (address(pool), feed));
        operationId = timelock.hashOperation(address(registry), 0, payload, bytes32(0), ADD_POOL_SALT);
        require(timelock.isOperationReady(operationId), "pool operation not ready");

        vm.startBroadcast();
        timelock.execute(address(registry), 0, payload, bytes32(0), ADD_POOL_SALT);
        vm.stopBroadcast();

        require(timelock.isOperationDone(operationId), "pool operation not done");
        require(registry.coverPoolsLength() == EXPECTED_FINAL_POOLS, "pool count mismatch");
        require(registry.coverPool(asset) == address(pool), "pool registry mismatch");
        require(registry.assetUsdFeed(asset) == feed, "pool feed mismatch");

        (IERC20[] memory assets, address[] memory pools) = registry.coverPools();
        require(assets.length == EXPECTED_FINAL_POOLS, "final asset count mismatch");
        require(pools.length == EXPECTED_FINAL_POOLS, "final pool count mismatch");
        require(assets[0] == EXISTING_ASSET, "first asset changed");
        require(pools[0] == EXISTING_POOL, "first pool changed");
        require(registry.coverPool(EXISTING_ASSET) == EXISTING_POOL, "first pool mapping changed");
        require(registry.assetUsdFeed(EXISTING_ASSET) == EXISTING_FEED, "first feed mapping changed");
        require(address(assets[1]) == address(asset), "second asset order mismatch");
        require(pools[1] == address(pool), "second pool order mismatch");

        console2.log("Executed Sepolia second cover-pool registration");
        console2.log("asset", address(asset));
        console2.log("feed", feed);
        console2.log("pool", address(pool));
        console2.logBytes32(operationId);
    }
}
