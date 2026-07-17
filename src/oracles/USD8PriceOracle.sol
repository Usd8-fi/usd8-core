// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Registry} from "../Registry.sol";

interface IUSD8TreasuryOracle {
    function getReserveBalance() external view returns (uint256);
}

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title USD8 / USD Price Oracle
/// @notice AggregatorV3-compatible composite oracle calculated as:
///         Chainlink USDC/USD × min(Treasury USDC reserves / USD8 supply, 1).
/// @dev USD8 is redeemable against six-decimal USDC reserves. Calls made against
///      an archive block naturally use the historical Treasury implementation,
///      reserve state, USD8 supply, and then-current Chainlink round.
///      Round IDs and timestamps belong to the underlying Chainlink USDC/USD feed;
///      the composite answer can change within one Chainlink round as reserves or
///      USD8 supply change. Historical consumers must therefore call
///      latestRoundData() at the desired archive block, not replay old round IDs.
///      Availability deliberately inherits Treasury.getReserveBalance(): a reverting
///      approved strategy makes this oracle fail closed at that state/block.
contract USD8PriceOracle is IAggregatorV3 {
    uint256 public constant USDC_TO_USD8_SCALE = 1e12;

    Registry public immutable REGISTRY;
    IAggregatorV3 public immutable USDC_USD_FEED;

    error ZeroAddress();
    error NoUsd8Supply();
    error InvalidOracleAnswer(int256 answer);
    error HistoricalRoundUnsupported(uint80 requestedRoundId);

    constructor(Registry registry, address usdcUsdFeed) {
        if (address(registry) == address(0) || usdcUsdFeed == address(0)) revert ZeroAddress();
        if (registry.usd8() == address(0) || registry.treasury() == address(0)) revert ZeroAddress();

        REGISTRY = registry;
        USDC_USD_FEED = IAggregatorV3(usdcUsdFeed);
    }

    function decimals() external view returns (uint8) {
        return USDC_USD_FEED.decimals();
    }

    function description() external pure returns (string memory) {
        return "USD8 / USD";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    /// @dev A historical USDC round cannot be paired with its historical USD8
    ///      backing inside a present-state call. Consumers needing historical USD8
    ///      prices must call latestRoundData() against the corresponding archive block.
    function getRoundData(uint80 requestedRoundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = USDC_USD_FEED.latestRoundData();
        if (requestedRoundId != roundId) revert HistoricalRoundUnsupported(requestedRoundId);
        answer = _applyBackingRatio(answer);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = USDC_USD_FEED.latestRoundData();
        answer = _applyBackingRatio(answer);
    }

    function _applyBackingRatio(int256 usdcUsdAnswer) internal view returns (int256) {
        if (usdcUsdAnswer <= 0) revert InvalidOracleAnswer(usdcUsdAnswer);

        uint256 supply = IERC20(REGISTRY.usd8()).totalSupply();
        if (supply == 0) revert NoUsd8Supply();

        uint256 reserve = IUSD8TreasuryOracle(REGISTRY.treasury()).getReserveBalance();
        uint256 effectiveCollateral;
        if (reserve >= Math.ceilDiv(supply, USDC_TO_USD8_SCALE)) {
            effectiveCollateral = supply;
        } else {
            effectiveCollateral = reserve * USDC_TO_USD8_SCALE;
        }

        return SafeCast.toInt256(Math.mulDiv(SafeCast.toUint256(usdcUsdAnswer), effectiveCollateral, supply));
    }
}
