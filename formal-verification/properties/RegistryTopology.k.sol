// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../../src/Registry.sol";

contract RegistryTopologyToken {}

contract RegistryTopologyPoolModel {
    IERC20 public immutable asset;

    constructor(IERC20 asset_) {
        asset = asset_;
    }
}

contract RegistryTopologyInsuranceModel {
    uint256 public activeIncidentId;
    mapping(IERC20 => bool) public insured;

    function setActiveIncidentId(uint256 incidentId) external {
        activeIncidentId = incidentId;
    }

    function setInsured(IERC20 token, bool value) external {
        insured[token] = value;
    }

    function isInsuredToken(IERC20 token) external view returns (bool) {
        return insured[token];
    }
}

contract RegistryTopologyFeedModel {
    uint8 public feedDecimals = 8;
    uint80 public roundId = 1;
    int256 public answer = 1e8;
    uint256 public updatedAt = 1;
    uint80 public answeredInRound = 1;

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, 0, updatedAt, answeredInRound);
    }

    function set(uint8 decimals_, uint80 roundId_, int256 answer_, uint256 updatedAt_, uint80 answeredInRound_)
        external
    {
        feedDecimals = decimals_;
        roundId = roundId_;
        answer = answer_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }
}

contract RegistryTopologyRevertingFeed {
    function decimals() external pure returns (uint8) {
        revert();
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert();
    }
}

contract RegistryTopologyMalformedFeed {
    function decimals() external pure returns (uint8) {
        assembly {
            mstore(0, 8)
            return(0, 1)
        }
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        assembly {
            return(0, 32)
        }
    }
}

/// @notice Registry pool/feed topology properties with a concrete N <= 3 operational bound.
contract RegistryTopologyKontrolTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant OUTSIDER = address(0xBAD);

    Registry internal registry;
    RegistryTopologyInsuranceModel internal insurance;
    RegistryTopologyFeedModel internal feed;
    IERC20 internal assetA;
    IERC20 internal assetB;
    IERC20 internal assetC;
    RegistryTopologyPoolModel internal poolA;
    RegistryTopologyPoolModel internal poolB;
    RegistryTopologyPoolModel internal poolC;

    event AssetUsdFeedSet(IERC20 indexed asset, address indexed oldFeed, address indexed newFeed);
    event MaxOracleStalenessSet(uint64 oldStaleness, uint64 newStaleness);

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
        insurance = new RegistryTopologyInsuranceModel();
        registry.setDefiInsurance(address(insurance));
        feed = new RegistryTopologyFeedModel();
        assetA = IERC20(address(new RegistryTopologyToken()));
        assetB = IERC20(address(new RegistryTopologyToken()));
        assetC = IERC20(address(new RegistryTopologyToken()));
        poolA = new RegistryTopologyPoolModel(assetA);
        poolB = new RegistryTopologyPoolModel(assetB);
        poolC = new RegistryTopologyPoolModel(assetC);
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _callAs(address caller, bytes memory callData) internal returns (bool success, bytes memory returndata) {
        vm.prank(caller);
        return address(registry).call(callData);
    }

    function _addThree() internal {
        registry.addPool(address(poolA), address(feed));
        registry.addPool(address(poolB), address(feed));
        registry.addPool(address(poolC), address(feed));
    }

    function _assertAligned(uint256 index, IERC20 expectedAsset, address expectedPool) internal view {
        assert(registry.coverPoolAssets(index) == expectedAsset);
        assert(registry.coverPool(expectedAsset) == expectedPool);
        assert(registry.assetUsdFeed(expectedAsset) == address(feed));
    }

    function test_setAssetUsdFeedStoresExactlyAndValidatesEveryObservedFeedField() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit AssetUsdFeedSet(assetA, address(0), address(feed));
        registry.setAssetUsdFeed(assetA, address(feed));
        assert(registry.assetUsdFeed(assetA) == address(feed));

        (bool zeroAsset, bytes memory zeroAssetData) =
            address(registry).call(abi.encodeCall(Registry.setAssetUsdFeed, (IERC20(address(0)), address(feed))));
        (bool zeroFeed, bytes memory zeroFeedData) =
            address(registry).call(abi.encodeCall(Registry.setAssetUsdFeed, (assetB, address(0))));
        (bool noCode, bytes memory noCodeData) =
            address(registry).call(abi.encodeCall(Registry.setAssetUsdFeed, (assetB, address(0x1234))));
        assert(!zeroAsset && _selector(zeroAssetData) == Registry.ZeroAddress.selector);
        assert(!zeroFeed && _selector(zeroFeedData) == Registry.ZeroAddress.selector);
        assert(!noCode && _selector(noCodeData) == Registry.InvalidAssetUsdFeed.selector);

        feed.set(78, 1, 1e8, 1, 1);
        (bool decimalsBad, bytes memory decimalsData) =
            address(registry).call(abi.encodeCall(Registry.setAssetUsdFeed, (assetB, address(feed))));
        assert(!decimalsBad && _selector(decimalsData) == Registry.InvalidAssetUsdFeed.selector);
        feed.set(8, 1, 0, 1, 1);
        (bool answerBad, bytes memory answerData) =
            address(registry).call(abi.encodeCall(Registry.setAssetUsdFeed, (assetB, address(feed))));
        assert(!answerBad && _selector(answerData) == Registry.InvalidAssetUsdFeed.selector);
        feed.set(8, 1, 1e8, 0, 1);
        (bool timeBad, bytes memory timeData) =
            address(registry).call(abi.encodeCall(Registry.setAssetUsdFeed, (assetB, address(feed))));
        assert(!timeBad && _selector(timeData) == Registry.InvalidAssetUsdFeed.selector);
        feed.set(8, 2, 1e8, 1, 1);
        (bool roundBad, bytes memory roundData) =
            address(registry).call(abi.encodeCall(Registry.setAssetUsdFeed, (assetB, address(feed))));
        assert(!roundBad && _selector(roundData) == Registry.InvalidAssetUsdFeed.selector);
        assert(registry.assetUsdFeed(assetB) == address(0));
    }

    function test_revertingAndMalformedFeedsFailAtomically() public {
        RegistryTopologyRevertingFeed revertingFeed = new RegistryTopologyRevertingFeed();
        RegistryTopologyMalformedFeed malformedFeed = new RegistryTopologyMalformedFeed();
        (bool reverting, bytes memory revertingData) =
            address(registry).call(abi.encodeCall(Registry.setAssetUsdFeed, (assetA, address(revertingFeed))));
        (bool malformed, bytes memory malformedData) =
            address(registry).call(abi.encodeCall(Registry.setAssetUsdFeed, (assetA, address(malformedFeed))));
        assert(!reverting && _selector(revertingData) == Registry.InvalidAssetUsdFeed.selector);
        assert(!malformed && _selector(malformedData) == Registry.InvalidAssetUsdFeed.selector);
        assert(registry.assetUsdFeed(assetA) == address(0));
    }

    function test_addPoolsStoresAlignedBoundedTopologyAndViewsExactly() public {
        registry.addPool(address(poolA), address(feed));
        registry.addPool(address(poolB), address(feed));
        registry.addPool(address(poolC), address(feed));
        assert(registry.coverPoolsLength() == 3);
        _assertAligned(0, assetA, address(poolA));
        _assertAligned(1, assetB, address(poolB));
        _assertAligned(2, assetC, address(poolC));

        (IERC20[] memory assets, address[] memory pools) = registry.coverPools();
        assert(assets.length == 3 && pools.length == 3);
        assert(assets[0] == assetA && pools[0] == address(poolA));
        assert(assets[1] == assetB && pools[1] == address(poolB));
        assert(assets[2] == assetC && pools[2] == address(poolC));
    }

    function test_addPoolRejectsZeroDuplicateConflictAndUnauthorizedAtomically() public {
        registry.addPool(address(poolA), address(feed));
        (bool duplicate, bytes memory duplicateData) =
            address(registry).call(abi.encodeCall(Registry.addPool, (address(poolA), address(feed))));
        assert(!duplicate && _selector(duplicateData) == Registry.PoolExists.selector);

        RegistryTopologyPoolModel zeroAssetPool = new RegistryTopologyPoolModel(IERC20(address(0)));
        (bool zeroPool, bytes memory zeroPoolData) =
            address(registry).call(abi.encodeCall(Registry.addPool, (address(0), address(feed))));
        (bool zeroFeed, bytes memory zeroFeedData) =
            address(registry).call(abi.encodeCall(Registry.addPool, (address(poolB), address(0))));
        (bool zeroAsset, bytes memory zeroAssetData) =
            address(registry).call(abi.encodeCall(Registry.addPool, (address(zeroAssetPool), address(feed))));
        assert(!zeroPool && _selector(zeroPoolData) == Registry.ZeroAddress.selector);
        assert(!zeroFeed && _selector(zeroFeedData) == Registry.ZeroAddress.selector);
        assert(!zeroAsset && _selector(zeroAssetData) == Registry.ZeroAddress.selector);

        insurance.setInsured(assetB, true);
        (bool conflict, bytes memory conflictData) =
            address(registry).call(abi.encodeCall(Registry.addPool, (address(poolB), address(feed))));
        assert(!conflict && _selector(conflictData) == Registry.TokenConflict.selector);
        (bool unauthorized, bytes memory unauthorizedData) =
            _callAs(ADMIN, abi.encodeCall(Registry.addPool, (address(poolC), address(feed))));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedTimelock.selector);
        assert(registry.coverPoolsLength() == 1);
        _assertAligned(0, assetA, address(poolA));
    }

    function test_removeFirstUsesSwapAndPopAndDeletesOnlyRemovedMappings() public {
        _addThree();
        registry.removePool(address(poolA));
        assert(registry.coverPoolsLength() == 2);
        assert(registry.coverPool(assetA) == address(0));
        assert(registry.assetUsdFeed(assetA) == address(0));
        _assertAligned(0, assetC, address(poolC));
        _assertAligned(1, assetB, address(poolB));
    }

    function test_removeMiddleAndLastPreserveAlignedRemainingTopology() public {
        _addThree();
        registry.removePool(address(poolB));
        assert(registry.coverPoolsLength() == 2);
        _assertAligned(0, assetA, address(poolA));
        _assertAligned(1, assetC, address(poolC));
        registry.removePool(address(poolC));
        assert(registry.coverPoolsLength() == 1);
        _assertAligned(0, assetA, address(poolA));
    }

    function test_removeMissingWrongAddressAndUnauthorizedRollback() public {
        registry.addPool(address(poolA), address(feed));
        RegistryTopologyPoolModel wrongPool = new RegistryTopologyPoolModel(assetA);
        (bool wrong, bytes memory wrongData) =
            address(registry).call(abi.encodeCall(Registry.removePool, (address(wrongPool))));
        assert(!wrong && _selector(wrongData) == Registry.PoolNotFound.selector);
        (bool unauthorized, bytes memory unauthorizedData) =
            _callAs(ADMIN, abi.encodeCall(Registry.removePool, (address(poolA))));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedTimelock.selector);
        assert(registry.coverPoolsLength() == 1);
        _assertAligned(0, assetA, address(poolA));
    }

    function test_oracleStalenessExactZeroAclAndFreezeBehavior() public {
        vm.expectEmit(false, false, false, true, address(registry));
        emit MaxOracleStalenessSet(36 hours, 77);
        registry.setMaxOracleStaleness(77);
        assert(registry.maxOracleStaleness() == 77);
        (bool zero, bytes memory zeroData) =
            address(registry).call(abi.encodeCall(Registry.setMaxOracleStaleness, (uint64(0))));
        assert(!zero && _selector(zeroData) == Registry.InvalidOracleStaleness.selector);
        (bool unauthorized, bytes memory unauthorizedData) =
            _callAs(ADMIN, abi.encodeCall(Registry.setMaxOracleStaleness, (uint64(88))));
        assert(!unauthorized && _selector(unauthorizedData) == Registry.UnauthorizedTimelock.selector);

        insurance.setActiveIncidentId(1);
        (bool frozen, bytes memory frozenData) =
            address(registry).call(abi.encodeCall(Registry.setMaxOracleStaleness, (uint64(99))));
        assert(!frozen && _selector(frozenData) == Registry.Frozen.selector);
        assert(registry.maxOracleStaleness() == 77);
    }

    function test_activeIncidentFreezesPoolAndFeedMutationsAtomically() public {
        registry.addPool(address(poolA), address(feed));
        insurance.setActiveIncidentId(1);
        (bool add, bytes memory addData) =
            address(registry).call(abi.encodeCall(Registry.addPool, (address(poolB), address(feed))));
        (bool remove, bytes memory removeData) =
            address(registry).call(abi.encodeCall(Registry.removePool, (address(poolA))));
        (bool setFeed, bytes memory feedData) =
            address(registry).call(abi.encodeCall(Registry.setAssetUsdFeed, (assetA, address(feed))));
        assert(!add && _selector(addData) == Registry.Frozen.selector);
        assert(!remove && _selector(removeData) == Registry.Frozen.selector);
        assert(!setFeed && _selector(feedData) == Registry.Frozen.selector);
        assert(registry.coverPoolsLength() == 1);
        _assertAligned(0, assetA, address(poolA));
    }
}
