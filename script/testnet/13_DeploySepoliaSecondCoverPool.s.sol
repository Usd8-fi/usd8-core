// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Registry} from "../../src/Registry.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {SepoliaTestToken, SepoliaTestOracle} from "./SepoliaDependencies.sol";

/// @notice Deploys, seeds, caps, and schedules registration of a second Sepolia cover pool.
/// @dev Staging only. The new $1 mock asset is sized near the existing wstETH pool's USD value
///      so the settlement kernel produces observable payouts in both assets. Registration remains
///      timelock-controlled and cannot execute while an incident is active.
contract DeploySepoliaSecondCoverPoolScript is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant CHAIN_ID = 11_155_111;
    uint256 internal constant POOL_SEED = 256_000 ether;
    uint256 internal constant EXPECTED_EXISTING_POOLS = 1;
    int256 internal constant ASSET_USD_PRICE = 1e8;
    bytes32 internal constant ADD_POOL_SALT = keccak256("USD8 Sepolia second cover pool mGHO 2026-08-30");
    address internal constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;
    address internal constant CANONICAL_ASSET = 0xBBd327336D5135E146312dD16F2491C1E6ce8822;
    address internal constant CANONICAL_FEED = 0xDa725125d8ff0588496382427ab65Bc8f8D639Eb;
    address internal constant CANONICAL_POOL = 0x8917f4C377dD0e5Bd4909D8A00B508F38C0f3f4F;

    struct Deployment {
        SepoliaTestToken asset;
        SepoliaTestOracle feed;
        SingleAssetCoverPool pool;
        bytes32 operationId;
    }

    function run() external returns (Deployment memory d) {
        if (block.chainid != CHAIN_ID) revert("Sepolia only");

        address admin = vm.envAddress("SEPOLIA_ADMIN");
        Registry registry = Registry(vm.envAddress("SEPOLIA_REGISTRY"));
        DefiInsurance insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        TimelockController timelock = TimelockController(payable(vm.envAddress("SEPOLIA_TIMELOCK")));
        address beacon = vm.envAddress("SEPOLIA_POOL_BEACON");

        require(msg.sender == admin, "broadcaster/admin mismatch");
        require(address(registry).code.length != 0, "missing registry");
        require(address(insurance).code.length != 0, "missing insurance");
        require(address(timelock).code.length != 0, "missing timelock");
        require(beacon.code.length != 0, "missing pool beacon");
        require(registry.timelock() == address(timelock), "registry timelock mismatch");
        require(insurance.activeIncidentId() == 0, "incident active");
        require(registry.coverPoolsLength() == EXPECTED_EXISTING_POOLS, "unexpected pool topology");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), admin), "missing proposer role");
        _requireCanonicalPlanUnused(admin, timelock, registry);

        vm.startBroadcast();
        d.asset = new SepoliaTestToken("Sepolia Mock GHO Cover Asset", "mGHO-CP", 18, admin, POOL_SEED);
        d.feed = new SepoliaTestOracle(admin, "mGHO-CP / USD", 8, ASSET_USD_PRICE);
        d.pool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    beacon,
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (registry, IERC20(address(d.asset)), "USD8 Cover Pool mGHO", "USD8-cp-mGHO")
                    )
                )
            )
        );
        require(address(d.asset) == CANONICAL_ASSET, "asset address mismatch");
        require(address(d.feed) == CANONICAL_FEED, "feed address mismatch");
        require(address(d.pool) == CANONICAL_POOL, "pool address mismatch");
        IERC20(address(d.asset)).forceApprove(address(d.pool), POOL_SEED);
        d.pool.deposit(POOL_SEED, SEED_SINK);
        d.pool.setDepositCap(POOL_SEED);
        d.operationId = _schedulePoolRegistration(timelock, registry, d.pool, d.feed);
        vm.stopBroadcast();

        _verifyDeployment(d, admin, registry, timelock);
        _log(d, timelock);
    }

    function _requireCanonicalPlanUnused(address admin, TimelockController timelock, Registry registry) private view {
        uint256 nonce = vm.getNonce(admin);
        require(vm.computeCreateAddress(admin, nonce) == CANONICAL_ASSET, "unexpected deployment nonce");
        require(vm.computeCreateAddress(admin, nonce + 1) == CANONICAL_FEED, "unexpected deployment nonce");
        require(vm.computeCreateAddress(admin, nonce + 2) == CANONICAL_POOL, "unexpected deployment nonce");
        require(CANONICAL_ASSET.code.length == 0, "canonical asset already deployed");
        require(CANONICAL_FEED.code.length == 0, "canonical feed already deployed");
        require(CANONICAL_POOL.code.length == 0, "canonical pool already deployed");
        bytes memory payload = abi.encodeCall(Registry.addPool, (CANONICAL_POOL, CANONICAL_FEED));
        bytes32 operationId = timelock.hashOperation(address(registry), 0, payload, bytes32(0), ADD_POOL_SALT);
        require(!timelock.isOperation(operationId), "canonical pool operation already exists");
    }

    function _schedulePoolRegistration(
        TimelockController timelock,
        Registry registry,
        SingleAssetCoverPool pool,
        SepoliaTestOracle feed
    ) private returns (bytes32 operationId) {
        bytes memory payload = abi.encodeCall(Registry.addPool, (address(pool), address(feed)));
        operationId = timelock.hashOperation(address(registry), 0, payload, bytes32(0), ADD_POOL_SALT);
        require(!timelock.isOperation(operationId), "pool operation already exists");
        timelock.schedule(address(registry), 0, payload, bytes32(0), ADD_POOL_SALT, timelock.getMinDelay());
    }

    function _verifyDeployment(Deployment memory d, address admin, Registry registry, TimelockController timelock)
        private
        view
    {
        require(d.asset.admin() == admin, "asset admin mismatch");
        require(d.feed.admin() == admin, "feed admin mismatch");
        require(address(d.pool.asset()) == address(d.asset), "pool asset mismatch");
        require(d.pool.totalAssets() == POOL_SEED, "pool seed mismatch");
        require(d.pool.depositCap() == POOL_SEED, "pool cap mismatch");
        require(d.pool.balanceOf(SEED_SINK) != 0, "seed shares missing");
        require(registry.coverPool(IERC20(address(d.asset))) == address(0), "pool registered before timelock");
        require(timelock.isOperationPending(d.operationId), "pool operation not pending");
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = d.feed.latestRoundData();
        require(
            roundId != 0 && answer == ASSET_USD_PRICE && updatedAt != 0 && answeredInRound == roundId,
            "invalid pool feed"
        );
    }

    function _log(Deployment memory d, TimelockController timelock) private view {
        console2.log("=== SEPOLIA SECOND COVER POOL ===");
        console2.log("asset", address(d.asset));
        console2.log("feed", address(d.feed));
        console2.log("pool", address(d.pool));
        console2.log("poolSeed", POOL_SEED);
        console2.log("readyAt", timelock.getTimestamp(d.operationId));
        console2.log("operationId");
        console2.logBytes32(d.operationId);
    }
}
