// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Registry} from "../../src/Registry.sol";
import {USD8PriceOracle} from "../../src/oracles/USD8PriceOracle.sol";

/// @notice Concrete configurable external models used by the oracle properties.
/// @dev [C:CONFIGURABLE_EXTERNAL_MODELS] Stored responses model integration behavior;
///      correctness of arbitrary dependency bytecode is outside these properties.
contract USD8PriceOracleRegistryHarness {
    error RegistryFailure(uint256 marker);

    enum ReturnMode {
        Valid,
        Revert,
        MalformedShort,
        MalformedNonCanonical
    }

    address internal usd8Value;
    address internal treasuryValue;
    ReturnMode public usd8Mode;
    ReturnMode public treasuryMode;

    function setUsd8(address value) external {
        usd8Value = value;
    }

    function setTreasury(address value) external {
        treasuryValue = value;
    }

    function setModes(ReturnMode usd8Mode_, ReturnMode treasuryMode_) external {
        usd8Mode = usd8Mode_;
        treasuryMode = treasuryMode_;
    }

    function usd8() external view returns (address value) {
        ReturnMode mode = usd8Mode;
        if (mode == ReturnMode.Revert) revert RegistryFailure(6);
        value = usd8Value;
        if (mode == ReturnMode.MalformedShort) {
            assembly {
                mstore(0, value)
                return(0, 1)
            }
        }
        if (mode == ReturnMode.MalformedNonCanonical) {
            assembly {
                mstore(0, or(value, shl(160, 1)))
                return(0, 32)
            }
        }
    }

    function treasury() external view returns (address value) {
        ReturnMode mode = treasuryMode;
        if (mode == ReturnMode.Revert) revert RegistryFailure(7);
        value = treasuryValue;
        if (mode == ReturnMode.MalformedShort) {
            assembly {
                mstore(0, value)
                return(0, 1)
            }
        }
        if (mode == ReturnMode.MalformedNonCanonical) {
            assembly {
                mstore(0, or(value, shl(160, 1)))
                return(0, 32)
            }
        }
    }
}

contract USD8PriceOracleFeedHarness {
    error FeedFailure(uint256 marker);

    uint8 public feedDecimals;
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    bool public revertDecimals;
    bool public revertLatest;

    function setDecimals(uint8 value) external {
        feedDecimals = value;
    }

    function setRound(uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
        external
    {
        roundId = roundId_;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function setFailures(bool decimalsFailure, bool latestFailure) external {
        revertDecimals = decimalsFailure;
        revertLatest = latestFailure;
    }

    function decimals() external view returns (uint8) {
        if (revertDecimals) revert FeedFailure(1);
        return feedDecimals;
    }

    function description() external pure returns (string memory) {
        return "MODEL FEED";
    }

    function version() external pure returns (uint256) {
        return 77;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (revertLatest) revert FeedFailure(2);
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    /// @dev Deliberately unusable: production must read latestRoundData.
    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert FeedFailure(3);
    }
}

contract USD8PriceOracleSupplyHarness {
    error SupplyFailure(uint256 marker);

    uint256 internal supply;
    bool public shouldRevert;

    function setSupply(uint256 value) external {
        supply = value;
    }

    function setRevert(bool value) external {
        shouldRevert = value;
    }

    function totalSupply() external view returns (uint256) {
        if (shouldRevert) revert SupplyFailure(4);
        return supply;
    }
}

contract USD8PriceOracleTreasuryHarness {
    error TreasuryFailure(uint256 marker);

    uint256 internal reserve;
    bool public shouldRevert;

    function setReserve(uint256 value) external {
        reserve = value;
    }

    function setRevert(bool value) external {
        shouldRevert = value;
    }

    function getReserveBalance() external view returns (uint256) {
        if (shouldRevert) revert TreasuryFailure(5);
        return reserve;
    }
}

/// @dev ABI-decode failures below are intentionally modeled both as short bytes and
///      canonical-width words whose values violate a narrow return type.
contract USD8PriceOracleMalformedFeed {
    function decimals() external pure returns (uint8) {
        assembly {
            mstore(0, 8)
            return(0, 1)
        }
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        assembly {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

contract USD8PriceOracleNonCanonicalFeed {
    function decimals() external pure returns (uint8) {
        assembly {
            mstore(0, 256)
            return(0, 32)
        }
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        assembly {
            mstore(0, shl(80, 1))
            mstore(32, 1)
            mstore(64, 2)
            mstore(96, 3)
            mstore(128, 4)
            return(0, 160)
        }
    }
}

contract USD8PriceOracleNonCanonicalAnsweredInRoundFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        assembly {
            mstore(0, 1)
            mstore(32, 100000000)
            mstore(64, 2)
            mstore(96, 3)
            mstore(128, shl(80, 1))
            return(0, 160)
        }
    }
}

contract USD8PriceOracleMalformedSupply {
    function totalSupply() external pure returns (uint256) {
        assembly {
            mstore(0, 1)
            return(0, 1)
        }
    }
}

contract USD8PriceOracleMalformedTreasury {
    function getReserveBalance() external pure returns (uint256) {
        assembly {
            mstore(0, 1)
            return(0, 1)
        }
    }
}

contract USD8PriceOracleFactory {
    function deploy(Registry registry, address feed) external returns (USD8PriceOracle) {
        return new USD8PriceOracle(registry, feed);
    }
}

abstract contract USD8PriceOracleKontrolBase is Test {
    uint256 internal constant SCALE = 1e12;

    USD8PriceOracleRegistryHarness internal registryModel;
    USD8PriceOracleFeedHarness internal feed;
    USD8PriceOracleSupplyHarness internal usd8;
    USD8PriceOracleTreasuryHarness internal treasury;
    USD8PriceOracle internal oracle;

    function setUp() public virtual {
        registryModel = new USD8PriceOracleRegistryHarness();
        feed = new USD8PriceOracleFeedHarness();
        usd8 = new USD8PriceOracleSupplyHarness();
        treasury = new USD8PriceOracleTreasuryHarness();
        registryModel.setUsd8(address(usd8));
        registryModel.setTreasury(address(treasury));
        feed.setDecimals(8);
        feed.setRound(42, 100_000_000, 100, 200, 42);
        oracle = new USD8PriceOracle(Registry(address(registryModel)), address(feed));
    }

    function _sameBytes(bytes memory actual, bytes memory expected) internal pure returns (bool) {
        return actual.length == expected.length && keccak256(actual) == keccak256(expected);
    }

    function _latestCall() internal view returns (bool success, bytes memory returndata) {
        return address(oracle).staticcall(abi.encodeCall(USD8PriceOracle.latestRoundData, ()));
    }

    function _getRoundCall(uint80 requestedRound) internal view returns (bool success, bytes memory returndata) {
        return address(oracle).staticcall(abi.encodeCall(USD8PriceOracle.getRoundData, (requestedRound)));
    }

    function _latestCall(USD8PriceOracle target) internal view returns (bool success, bytes memory returndata) {
        return address(target).staticcall(abi.encodeCall(USD8PriceOracle.latestRoundData, ()));
    }

    function _getRoundCall(USD8PriceOracle target, uint80 requestedRound)
        internal
        view
        returns (bool success, bytes memory returndata)
    {
        return address(target).staticcall(abi.encodeCall(USD8PriceOracle.getRoundData, (requestedRound)));
    }

    function _decimalsCall(USD8PriceOracle target) internal view returns (bool success, bytes memory returndata) {
        return address(target).staticcall(abi.encodeCall(USD8PriceOracle.decimals, ()));
    }

    function _deployCall(Registry registry, address feedAddress)
        internal
        returns (bool success, bytes memory returndata)
    {
        USD8PriceOracleFactory factory = new USD8PriceOracleFactory();
        return address(factory).call(abi.encodeCall(factory.deploy, (registry, feedAddress)));
    }
}
