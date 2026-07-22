//! Compile-time Solidity ABI authority for every chain read/event consumed by the
//! Rust settler. Selector/topic tests pin these declarations to current contracts.

use alloy_sol_types::sol;

sol! {
    interface IDefiInsurance {
        struct InsuredToken {
            uint256 maxCoverageBps;
            address underlyingPriceOracle;
            address underlyingConversionAddress;
            bytes underlyingConversionCallData;
            uint128 minClaimAmount;
        }

        function incidents(uint256 incidentId) external view returns (
            address insuredToken,
            uint64 claimWindowEndTime,
            bytes32 root,
            uint256 unresolved,
            uint64 rootSubmittedAt,
            uint64 referenceBlock,
            uint64 openBlock,
            uint8 status,
            uint64 disputedAt,
            bytes32 claimSetHash
        );
        function incidentTeePcrHash(uint256 incidentId) external view returns (bytes32);
        function getInsuredToken(address token) external view returns (InsuredToken memory);
        function settlementParams() external view returns (
            uint64 twapLookbackBlocks,
            uint64 holdingMarginBlocks,
            uint64 sampleStepBlocks
        );
        function registry() external view returns (address);
        function BOOSTER_ID() external view returns (uint256);
        function BOOSTER_BOOST_BPS() external view returns (uint256);

        event ClaimRegistered(
            uint256 indexed claimId,
            uint256 indexed incidentId,
            address indexed user,
            uint128 insuredTokenAmount,
            uint256 scoreToSpend,
            uint256 boosterAmount
        );
        event ClaimCancelled(uint256 indexed claimId, address indexed user);
    }

    interface IRegistry {
        struct RatePoint {
            uint64 fromBlock;
            uint128 rate;
        }

        function coverPools() external view returns (address[] memory assets, address[] memory poolAddrs);
        function coverPoolsLength() external view returns (uint256);
        function getScoredTokens() external view returns (address[] memory);
        function getScoredRateHistory(address token) external view returns (RatePoint[] memory);
        function boosterNFT() external view returns (address);
        function maxCoverPoolPayoutBps() external view returns (uint256);
        function scoreSpent(address account) external view returns (uint256);
        function defiInsurance() external view returns (address);
        function assetUsdFeed(address asset) external view returns (address);
        function maxOracleStaleness() external view returns (uint64);
    }

    interface ISingleAssetCoverPool {
        function asset() external view returns (address);
        function totalAssets() external view returns (uint256);
    }

    interface IAggregatorV3 {
        function latestRoundData() external view returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
        function decimals() external view returns (uint8);
    }

    interface IERC20 {
        function balanceOf(address account) external view returns (uint256);
        function decimals() external view returns (uint8);
        event Transfer(address indexed from, address indexed to, uint256 value);
    }

    interface IERC1155 {
        function balanceOf(address account, uint256 id) external view returns (uint256);
        event TransferSingle(
            address indexed operator,
            address indexed from,
            address indexed to,
            uint256 id,
            uint256 value
        );
        event TransferBatch(
            address indexed operator,
            address indexed from,
            address indexed to,
            uint256[] ids,
            uint256[] values
        );
    }
}
