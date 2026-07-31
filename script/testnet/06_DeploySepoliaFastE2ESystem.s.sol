// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";
import {Treasury} from "../../src/Treasury.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";

/// @notice Deploys an isolated, disposable Sepolia system for the mLOSS E2E only.
/// @dev Reuses mock USDC, mock wstETH and their feeds; never points the canonical system at this stack.
contract DeploySepoliaFastE2ESystemScript is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant TIMELOCK_DELAY = 30 minutes;
    uint64 internal constant INCIDENT_PHASE_WINDOW = 30 minutes;
    uint64 internal constant MAX_REFERENCE_BLOCK_AGE = 43_200;
    uint128 internal constant USD8_SCORE_RATE = 138888888888889;
    uint256 internal constant POOL_SEED = 0.01 ether;
    address internal constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;

    struct System {
        TimelockController timelock;
        Registry registry;
        USD8 usd8;
        Treasury treasury;
        DefiInsurance insurance;
        UpgradeableBeacon beacon;
        SingleAssetCoverPool pool;
    }

    function run() external returns (System memory s) {
        require(block.chainid == 11_155_111, "Sepolia only");
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        address usdc = vm.envAddress("SEPOLIA_USDC");
        address coverAsset = vm.envAddress("SEPOLIA_COVER_ASSET");
        address coverAssetUsdOracle = vm.envAddress("SEPOLIA_COVER_ASSET_USD_ORACLE");
        address usdcUsdOracle = vm.envAddress("SEPOLIA_USDC_USD_ORACLE");
        require(msg.sender == admin, "broadcaster/admin mismatch");
        require(usdc.code.length != 0 && coverAsset.code.length != 0, "missing mock asset");
        require(coverAssetUsdOracle.code.length != 0 && usdcUsdOracle.code.length != 0, "missing mock feed");

        vm.startBroadcast();
        s = _deploy(admin, usdc, coverAsset, coverAssetUsdOracle, usdcUsdOracle);
        vm.stopBroadcast();
        _log(s);
    }

    function _deploy(
        address admin,
        address usdc,
        address coverAsset,
        address coverAssetUsdOracle,
        address usdcUsdOracle
    ) private returns (System memory s) {
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        s.timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));

        s.registry = Registry(address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (admin, admin)))));
        s.usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (s.registry)))));
        s.registry.setUsd8(address(s.usd8));
        s.treasury = Treasury(
            address(new ERC1967Proxy(address(new Treasury()), abi.encodeCall(Treasury.initialize, (s.registry, IERC20(usdc)))))
        );
        s.registry.setTreasury(address(s.treasury));

        SingleAssetCoverPool poolImpl = new SingleAssetCoverPool();
        s.beacon = new UpgradeableBeacon(address(poolImpl), admin);
        s.pool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(s.beacon),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (s.registry, IERC20(coverAsset), "USD8 Fast E2E Cover Pool", "USD8-cp-test-wstETH")
                    )
                )
            )
        );
        IERC20(coverAsset).forceApprove(address(s.pool), POOL_SEED);
        s.pool.deposit(POOL_SEED, SEED_SINK);
        require(s.pool.balanceOf(SEED_SINK) != 0, "cover seed missing");
        s.registry.addPool(address(s.pool), coverAssetUsdOracle);
        s.registry.setScoredToken(IERC20(address(s.usd8)), USD8_SCORE_RATE);

        s.insurance = DefiInsurance(
            address(new ERC1967Proxy(address(new DefiInsurance()), abi.encodeCall(DefiInsurance.initialize, (s.registry))))
        );
        s.registry.setDefiInsurance(address(s.insurance));
        s.registry.setIncidentTimingConfig(
            Registry.IncidentTimingConfig({phaseWindow: INCIDENT_PHASE_WINDOW, maxReferenceBlockAge: MAX_REFERENCE_BLOCK_AGE})
        );
        s.insurance.editInsuredToken(
            IERC20(address(s.usd8)), 8000, usdcUsdOracle, address(s.treasury), abi.encodeCall(Treasury.usd8ToUsdcRate, ())
        );
        // Temporary E2E-only signer. A later fast-timelock operation revokes it after resolution.
        s.insurance.setTeeSigner(admin, true);

        s.beacon.transferOwnership(address(s.timelock));
        s.registry.setTimelock(address(s.timelock));
        require(s.registry.timelock() == address(s.timelock), "timelock handoff failed");
        require(s.timelock.getMinDelay() == TIMELOCK_DELAY, "timelock delay mismatch");
    }

    function _log(System memory s) private view {
        console2.log("=== ISOLATED SEPOLIA FAST E2E SYSTEM ===");
        console2.log("timelock", address(s.timelock));
        console2.log("registry", address(s.registry));
        console2.log("usd8", address(s.usd8));
        console2.log("treasury", address(s.treasury));
        console2.log("insurance", address(s.insurance));
        console2.log("poolBeacon", address(s.beacon));
        console2.log("coverPool", address(s.pool));
        console2.log("timelockDelay", TIMELOCK_DELAY);
        console2.log("incidentPhaseWindow", INCIDENT_PHASE_WINDOW);
    }
}
