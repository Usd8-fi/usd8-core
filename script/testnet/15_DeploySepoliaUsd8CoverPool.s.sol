// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Registry} from "../../src/Registry.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {Treasury} from "../../src/Treasury.sol";
import {SepoliaTestOracle} from "./SepoliaDependencies.sol";

interface IUSD8PriceOracleDeployment {
    function REGISTRY() external view returns (Registry);
    function USDC_USD_FEED() external view returns (address);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Deploys, permanently seeds, and schedules the USD8-denominated Sepolia Cover Pool.
/// @dev Testnet only. The pool intentionally uses USD8 as both its ERC-4626 asset and reward token.
contract DeploySepoliaUsd8CoverPoolScript is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant CHAIN_ID = 11_155_111;
    uint256 internal constant EXPECTED_EXISTING_POOLS = 1;
    uint256 internal constant SEED_USDC = 1e6;
    uint256 internal constant SEED_USD8 = 1 ether;
    int256 internal constant USDC_USD_PRICE = 1e8;

    address internal constant ADMIN = 0x724e8951d39E14CEBcB5fB02638f49A637C97838;
    Registry internal constant REGISTRY = Registry(0xB34D92cd05005DF36050370433819597a9BaC693);
    DefiInsurance internal constant INSURANCE = DefiInsurance(0x4E346CcD0a46D51ebaE6810d653791982968d502);
    TimelockController internal constant TIMELOCK =
        TimelockController(payable(0x158494e7b95c0e5F87e8dB4Ad1Be5c32de99F645));
    UpgradeableBeacon internal constant POOL_BEACON = UpgradeableBeacon(0xe935806dC8B8C7b52E98dfA864A10E4bd9688e00);
    IERC20 internal constant USDC = IERC20(0x31cD4d9299aC2d55bb8590C9557edd3ff08cF35c);
    IERC20 internal constant USD8 = IERC20(0xa5B32853235619B5e9AF364A40c0c6386Dbd6055);
    Treasury internal constant TREASURY = Treasury(0x2a722eD12982623DFF64Dc0AdBA40e734A5f59C3);
    IUSD8PriceOracleDeployment internal constant USD8_ORACLE =
        IUSD8PriceOracleDeployment(0xf4AeDC595912cE5951c3a0AfDD8a61ebb07a8634);
    SepoliaTestOracle internal constant USDC_USD_FEED = SepoliaTestOracle(0x9989a6bB00C1737A9A0175408053a04A6f3eD74b);

    address internal constant EXPECTED_POOL = 0x6388c3826902F7D7812E632D0B63ea44D9C1e5Cf;
    address internal constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant ADD_POOL_SALT = keccak256("USD8 Sepolia USD8 cover pool 2026-09-14");

    struct Deployment {
        SingleAssetCoverPool pool;
        bytes32 operationId;
    }

    function run() external returns (Deployment memory d) {
        if (block.chainid != CHAIN_ID) revert("Sepolia only");
        require(msg.sender == ADMIN, "broadcaster/admin mismatch");
        _verifyPreState();

        vm.startBroadcast();
        d.pool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(POOL_BEACON),
                    abi.encodeCall(SingleAssetCoverPool.initialize, (REGISTRY, USD8, "USD8 Cover Pool", "USD8-cp-USD8"))
                )
            )
        );
        require(address(d.pool) == EXPECTED_POOL, "pool address mismatch");

        USDC.forceApprove(address(TREASURY), SEED_USDC);
        TREASURY.mintUSD8(SEED_USDC);
        USD8.forceApprove(address(d.pool), SEED_USD8);
        d.pool.deposit(SEED_USD8, SEED_SINK);

        // Refresh the test-only base feed without changing its $1.00 answer so the
        // composite USD8 oracle remains valid through timelock execution and testing.
        USDC_USD_FEED.updateAnswer(USDC_USD_PRICE);
        d.operationId = _schedulePoolRegistration(d.pool);
        vm.stopBroadcast();

        _verifyScheduledState(d);
        _log(d);
    }

    function _verifyPreState() private view {
        require(address(REGISTRY).code.length != 0, "missing registry");
        require(address(INSURANCE).code.length != 0, "missing insurance");
        require(address(TIMELOCK).code.length != 0, "missing timelock");
        require(address(POOL_BEACON).code.length != 0, "missing pool beacon");
        require(address(USD8_ORACLE).code.length != 0, "missing USD8 oracle");
        require(REGISTRY.timelock() == address(TIMELOCK), "registry timelock mismatch");
        require(REGISTRY.usd8() == address(USD8), "registry USD8 mismatch");
        require(REGISTRY.treasury() == address(TREASURY), "registry Treasury mismatch");
        require(REGISTRY.usd8PriceOracle() == address(USD8_ORACLE), "registry USD8 oracle mismatch");
        require(address(USD8_ORACLE.REGISTRY()) == address(REGISTRY), "oracle Registry mismatch");
        require(USD8_ORACLE.USDC_USD_FEED() == address(USDC_USD_FEED), "oracle feed mismatch");
        require(POOL_BEACON.owner() == address(TIMELOCK), "pool beacon owner mismatch");
        require(INSURANCE.activeIncidentId() == 0, "incident active");
        require(REGISTRY.coverPoolsLength() == EXPECTED_EXISTING_POOLS, "unexpected pool topology");
        require(REGISTRY.coverPool(USD8) == address(0), "USD8 pool already registered");
        require(REGISTRY.assetUsdFeed(USD8) == address(0), "USD8 feed already registered");
        require(TIMELOCK.hasRole(TIMELOCK.PROPOSER_ROLE(), ADMIN), "missing proposer role");
        require(USDC.balanceOf(ADMIN) >= SEED_USDC, "insufficient seed USDC");
        require(USD8.balanceOf(ADMIN) == 0, "unexpected preexisting USD8");
        require(vm.getNonce(ADMIN) == 893, "unexpected deployment nonce");
        require(vm.computeCreateAddress(ADMIN, 893) == EXPECTED_POOL, "unexpected pool address");
        require(EXPECTED_POOL.code.length == 0, "expected pool address already used");

        bytes memory payload = abi.encodeCall(Registry.addPool, (EXPECTED_POOL, address(USD8_ORACLE)));
        bytes32 operationId = TIMELOCK.hashOperation(address(REGISTRY), 0, payload, bytes32(0), ADD_POOL_SALT);
        require(!TIMELOCK.isOperation(operationId), "pool operation already exists");
    }

    function _schedulePoolRegistration(SingleAssetCoverPool pool) private returns (bytes32 operationId) {
        bytes memory payload = abi.encodeCall(Registry.addPool, (address(pool), address(USD8_ORACLE)));
        operationId = TIMELOCK.hashOperation(address(REGISTRY), 0, payload, bytes32(0), ADD_POOL_SALT);
        TIMELOCK.schedule(address(REGISTRY), 0, payload, bytes32(0), ADD_POOL_SALT, TIMELOCK.getMinDelay());
    }

    function _verifyScheduledState(Deployment memory d) private view {
        require(address(d.pool.asset()) == address(USD8), "pool asset mismatch");
        require(address(d.pool.usd8()) == address(USD8), "pool reward mismatch");
        require(keccak256(bytes(d.pool.name())) == keccak256("USD8 Cover Pool"), "pool name mismatch");
        require(keccak256(bytes(d.pool.symbol())) == keccak256("USD8-cp-USD8"), "pool symbol mismatch");
        require(d.pool.decimals() == 21, "pool share decimals mismatch");
        require(d.pool.totalAssets() == SEED_USD8, "pool seed mismatch");
        require(d.pool.depositCap() == 0, "pool should be uncapped");
        require(d.pool.balanceOf(SEED_SINK) != 0, "seed shares missing");
        require(USD8.balanceOf(ADMIN) == 0, "temporary USD8 remains");
        require(USDC.allowance(ADMIN, address(TREASURY)) == 0, "USDC allowance remains");
        require(USD8.allowance(ADMIN, address(d.pool)) == 0, "USD8 allowance remains");
        require(REGISTRY.coverPool(USD8) == address(0), "pool registered before timelock");
        require(TIMELOCK.isOperationPending(d.operationId), "pool operation not pending");
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = USD8_ORACLE.latestRoundData();
        require(roundId != 0 && answer > 0 && updatedAt != 0 && answeredInRound == roundId, "invalid USD8 oracle");
    }

    function _log(Deployment memory d) private view {
        console2.log("=== SEPOLIA USD8 COVER POOL ===");
        console2.log("pool", address(d.pool));
        console2.log("asset", address(USD8));
        console2.log("feed", address(USD8_ORACLE));
        console2.log("seedAssets", SEED_USD8);
        console2.log("readyAt", TIMELOCK.getTimestamp(d.operationId));
        console2.log("operationId");
        console2.logBytes32(d.operationId);
    }
}
