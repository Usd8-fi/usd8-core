// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../../src/Registry.sol";

contract RegistryEventToken {}

contract RegistryEventFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, 0, 1, 1);
    }
}

contract RegistryEventPool {
    IERC20 public immutable asset;

    constructor(IERC20 asset_) {
        asset = asset_;
    }
}

/// @notice Foundry-only multi-log presence/order obligations unsupported by Kontrol v1.0.255.
contract RegistryEventOrderingForgeTest is Test {
    bytes32 internal constant UPGRADED = keccak256("Upgraded(address)");
    bytes32 internal constant TIMELOCK_CHANGED = keccak256("TimelockChanged(address,address)");
    bytes32 internal constant ADMIN_SET = keccak256("AdminSet(address,bool)");
    bytes32 internal constant MAX_PAYOUT_SET = keccak256("MaxCoverPoolPayoutBpsSet(uint256,uint256)");
    bytes32 internal constant MAX_STALENESS_SET = keccak256("MaxOracleStalenessSet(uint64,uint64)");
    bytes32 internal constant INITIALIZED = keccak256("Initialized(uint64)");
    bytes32 internal constant ASSET_FEED_SET = keccak256("AssetUsdFeedSet(address,address,address)");
    bytes32 internal constant POOL_ADDED = keccak256("PoolAdded(address,address)");
    bytes32 internal constant POOL_REMOVED = keccak256("PoolRemoved(address)");
    bytes32 internal constant PAUSED_SET = keccak256("PausedSet(address,bool)");

    function _topic(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function test_initializerEmitsExactProxyAndApplicationLogOrder() public {
        address timelock = address(0x1111);
        address admin = address(0x2222);
        Registry implementation = new Registry();
        vm.recordLogs();
        Registry proxy = Registry(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(Registry.initialize, (timelock, admin))))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 6);
        for (uint256 i = 0; i < logs.length; i++) {
            assertEq(logs[i].emitter, address(proxy));
        }

        assertEq(logs[0].topics[0], UPGRADED);
        assertEq(logs[0].topics[1], _topic(address(implementation)));
        assertEq(logs[1].topics[0], TIMELOCK_CHANGED);
        assertEq(logs[1].topics[1], _topic(address(0)));
        assertEq(logs[1].topics[2], _topic(timelock));
        assertEq(logs[2].topics[0], ADMIN_SET);
        assertEq(logs[2].topics[1], _topic(admin));
        assertEq(abi.decode(logs[2].data, (bool)), true);
        assertEq(logs[3].topics[0], MAX_PAYOUT_SET);
        (uint256 oldBps, uint256 newBps) = abi.decode(logs[3].data, (uint256, uint256));
        assertEq(oldBps, 0);
        assertEq(newBps, 5000);
        assertEq(logs[4].topics[0], MAX_STALENESS_SET);
        (uint64 oldStaleness, uint64 newStaleness) = abi.decode(logs[4].data, (uint64, uint64));
        assertEq(oldStaleness, 0);
        assertEq(newStaleness, 36 hours);
        assertEq(logs[5].topics[0], INITIALIZED);
        assertEq(abi.decode(logs[5].data, (uint64)), 1);
    }

    function test_addAndRemovePoolEmitExactTwoLogOrder() public {
        Registry registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        IERC20 asset = IERC20(address(new RegistryEventToken()));
        RegistryEventFeed feed = new RegistryEventFeed();
        RegistryEventPool pool = new RegistryEventPool(asset);

        vm.recordLogs();
        registry.addPool(address(pool), address(feed));
        Vm.Log[] memory addLogs = vm.getRecordedLogs();
        assertEq(addLogs.length, 2);
        assertEq(addLogs[0].emitter, address(registry));
        assertEq(addLogs[0].topics[0], ASSET_FEED_SET);
        assertEq(addLogs[0].topics[1], _topic(address(asset)));
        assertEq(addLogs[0].topics[2], _topic(address(0)));
        assertEq(addLogs[0].topics[3], _topic(address(feed)));
        assertEq(addLogs[1].emitter, address(registry));
        assertEq(addLogs[1].topics[0], POOL_ADDED);
        assertEq(addLogs[1].topics[1], _topic(address(asset)));
        assertEq(addLogs[1].topics[2], _topic(address(pool)));

        vm.recordLogs();
        registry.removePool(address(pool));
        Vm.Log[] memory removeLogs = vm.getRecordedLogs();
        assertEq(removeLogs.length, 2);
        assertEq(removeLogs[0].emitter, address(registry));
        assertEq(removeLogs[0].topics[0], ASSET_FEED_SET);
        assertEq(removeLogs[0].topics[1], _topic(address(asset)));
        assertEq(removeLogs[0].topics[2], _topic(address(feed)));
        assertEq(removeLogs[0].topics[3], _topic(address(0)));
        assertEq(removeLogs[1].emitter, address(registry));
        assertEq(removeLogs[1].topics[0], POOL_REMOVED);
        assertEq(removeLogs[1].topics[1], _topic(address(asset)));
    }

    function test_pauseBatchEmitsOneOrderedLogPerElementIncludingDuplicates() public {
        Registry registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        address[] memory targets = new address[](3);
        targets[0] = address(0xA);
        targets[1] = address(0xB);
        targets[2] = address(0xA);
        vm.recordLogs();
        registry.setPausedBatch(targets, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        for (uint256 i = 0; i < logs.length; i++) {
            assertEq(logs[i].emitter, address(registry));
            assertEq(logs[i].topics[0], PAUSED_SET);
            assertEq(logs[i].topics[1], _topic(targets[i]));
            assertEq(abi.decode(logs[i].data, (bool)), true);
        }
    }
}
