// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Registry} from "../../src/Registry.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {SepoliaTestToken, SepoliaTestUsdFeed} from "./SepoliaLossFixture.sol";

/// @notice Deploys and schedules a reusable 10-claimant, three-pool Sepolia E2E fixture.
/// @dev Staging only. The three pools pay distinct assets and use independently valued USD feeds.
contract DeploySepoliaExpandedE2EFixtureScript is Script {
    using SafeERC20 for IERC20;

    bytes32 internal constant SETUP_SALT = keccak256("USD8 expanded 10 claimant 3 pool E2E setup 2026-07-31");
    uint256 internal constant POOL_SEED = 0.01 ether;
    int256 internal constant USD_PRICE = 1e8;
    int256 internal constant WSTETH_USD_PRICE = 2_000e8;
    uint8 internal constant FEED_DECIMALS = 8;
    uint256 internal constant SETUP_CALLS = 4;
    address internal constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;

    struct Fixture {
        SepoliaTestToken gho;
        SepoliaTestToken usds;
        SepoliaTestUsdFeed insuredFeed;
        SepoliaTestUsdFeed wstethFeed;
        SepoliaTestUsdFeed ghoFeed;
        SepoliaTestUsdFeed usdsFeed;
        SingleAssetCoverPool ghoPool;
        SingleAssetCoverPool usdsPool;
        bytes32 setupOperation;
    }

    function run() external returns (Fixture memory f) {
        require(block.chainid == 11_155_111, "Sepolia only");
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        Registry registry = Registry(vm.envAddress("SEPOLIA_REGISTRY"));
        DefiInsurance insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        TimelockController timelock = TimelockController(payable(vm.envAddress("SEPOLIA_TIMELOCK")));
        address beacon = vm.envAddress("SEPOLIA_POOL_BEACON");
        IERC20 existingCoverAsset = IERC20(vm.envAddress("SEPOLIA_COVER_ASSET"));
        address existingPool = vm.envAddress("SEPOLIA_COVER_POOL");
        IERC20 lossVault = IERC20(vm.envAddress("SEPOLIA_LOSS_VAULT"));

        require(msg.sender == admin, "broadcaster/admin mismatch");
        require(address(registry).code.length != 0 && address(insurance).code.length != 0, "missing system");
        require(beacon.code.length != 0 && address(existingCoverAsset).code.length != 0, "missing pool dependency");
        require(registry.coverPool(existingCoverAsset) == existingPool, "wrong existing pool");
        require(insurance.activeIncidentId() == 0, "incident active");

        vm.startBroadcast();
        f = _deploy(admin, registry, beacon);
        _seed(f, admin);
        f.setupOperation = _scheduleSetup(timelock, registry, insurance, existingCoverAsset, lossVault, f);
        vm.stopBroadcast();

        _verifyDeployed(f, admin);
        _log(f);
    }

    function _deploy(address admin, Registry registry, address beacon) private returns (Fixture memory f) {
        f.gho = new SepoliaTestToken("Sepolia Mock GHO", "mGHO", admin);
        f.usds = new SepoliaTestToken("Sepolia Mock USDS", "mUSDS", admin);
        f.insuredFeed = new SepoliaTestUsdFeed(USD_PRICE, FEED_DECIMALS, admin);
        f.wstethFeed = new SepoliaTestUsdFeed(WSTETH_USD_PRICE, FEED_DECIMALS, admin);
        f.ghoFeed = new SepoliaTestUsdFeed(USD_PRICE, FEED_DECIMALS, admin);
        f.usdsFeed = new SepoliaTestUsdFeed(USD_PRICE, FEED_DECIMALS, admin);
        f.ghoPool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    beacon,
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (registry, IERC20(address(f.gho)), "USD8 Sepolia GHO Cover Pool", "USD8-cp-mGHO")
                    )
                )
            )
        );
        f.usdsPool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    beacon,
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (registry, IERC20(address(f.usds)), "USD8 Sepolia USDS Cover Pool", "USD8-cp-mUSDS")
                    )
                )
            )
        );
    }

    function _seed(Fixture memory f, address admin) private {
        f.gho.mint(admin, POOL_SEED);
        f.usds.mint(admin, POOL_SEED);
        IERC20(address(f.gho)).forceApprove(address(f.ghoPool), POOL_SEED);
        IERC20(address(f.usds)).forceApprove(address(f.usdsPool), POOL_SEED);
        f.ghoPool.deposit(POOL_SEED, SEED_SINK);
        f.usdsPool.deposit(POOL_SEED, SEED_SINK);
        require(f.ghoPool.balanceOf(SEED_SINK) != 0, "GHO seed missing");
        require(f.usdsPool.balanceOf(SEED_SINK) != 0, "USDS seed missing");
    }

    function _scheduleSetup(
        TimelockController timelock,
        Registry registry,
        DefiInsurance insurance,
        IERC20 existingCoverAsset,
        IERC20 lossVault,
        Fixture memory f
    ) private returns (bytes32 operation) {
        address[] memory targets = new address[](SETUP_CALLS);
        uint256[] memory values = new uint256[](SETUP_CALLS);
        bytes[] memory payloads = new bytes[](SETUP_CALLS);
        targets[0] = address(registry);
        payloads[0] = abi.encodeCall(Registry.setAssetUsdFeed, (existingCoverAsset, address(f.wstethFeed)));
        targets[1] = address(registry);
        payloads[1] = abi.encodeCall(Registry.addPool, (address(f.ghoPool), address(f.ghoFeed)));
        targets[2] = address(registry);
        payloads[2] = abi.encodeCall(Registry.addPool, (address(f.usdsPool), address(f.usdsFeed)));
        targets[3] = address(insurance);
        payloads[3] = abi.encodeCall(
            DefiInsurance.editInsuredToken,
            (
                lossVault,
                8000,
                address(f.insuredFeed),
                address(lossVault),
                abi.encodeCall(IERC4626.convertToAssets, (1e18))
            )
        );
        operation = _schedule(timelock, targets, values, payloads);
    }

    function _schedule(
        TimelockController timelock,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads
    ) private returns (bytes32 operation) {
        operation = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), SETUP_SALT);
        require(!timelock.isOperation(operation), "setup operation exists");
        uint256 delay = timelock.getMinDelay();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SETUP_SALT, delay);
    }

    function _verifyDeployed(Fixture memory f, address admin) private view {
        require(f.gho.admin() == admin && f.usds.admin() == admin, "token admin mismatch");
        require(f.insuredFeed.admin() == admin && f.wstethFeed.admin() == admin, "feed admin mismatch");
        require(address(f.ghoPool.asset()) == address(f.gho), "GHO pool asset mismatch");
        require(address(f.usdsPool.asset()) == address(f.usds), "USDS pool asset mismatch");
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = f.insuredFeed.latestRoundData();
        require(
            roundId != 0 && answer == USD_PRICE && updatedAt != 0 && answeredInRound == roundId, "invalid insured feed"
        );
    }

    function _log(Fixture memory f) private pure {
        console2.log("=== EXPANDED SEPOLIA E2E FIXTURE ===");
        console2.log("mGHO", address(f.gho));
        console2.log("mUSDS", address(f.usds));
        console2.log("insuredUsdFeed", address(f.insuredFeed));
        console2.log("wstETHUsdFeed", address(f.wstethFeed));
        console2.log("ghoUsdFeed", address(f.ghoFeed));
        console2.log("usdsUsdFeed", address(f.usdsFeed));
        console2.log("ghoPool", address(f.ghoPool));
        console2.log("usdsPool", address(f.usdsPool));
        console2.log("setupOperation");
        console2.logBytes32(f.setupOperation);
    }
}
