// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Registry} from "../../src/Registry.sol";
import {USD8PriceOracle} from "../../src/oracles/USD8PriceOracle.sol";
import {
    USD8PriceOracleFeedHarness,
    USD8PriceOracleKontrolBase,
    USD8PriceOracleMalformedFeed,
    USD8PriceOracleMalformedSupply,
    USD8PriceOracleMalformedTreasury,
    USD8PriceOracleNonCanonicalAnsweredInRoundFeed,
    USD8PriceOracleNonCanonicalFeed,
    USD8PriceOracleRegistryHarness,
    USD8PriceOracleSupplyHarness,
    USD8PriceOracleTreasuryHarness
} from "./USD8PriceOracleHarness.k.sol";

/// @notice Forge-executable specifications for the USD8/USD composite oracle.
/// @dev [T:MULDIV] Full-width expected values use OpenZeppelin Math.mulDiv, while
///      separate threshold and quotient/remainder properties independently constrain
///      branch selection and rounding. Forge-green is not a solver-proof claim.
contract USD8PriceOracleKontrolTest is USD8PriceOracleKontrolBase {
    function test_constructorRejectsZeroRegistryAndFeedWithExactError() public {
        (bool zeroRegistry, bytes memory zeroRegistryData) = _deployCall(Registry(address(0)), address(feed));
        (bool zeroFeed, bytes memory zeroFeedData) = _deployCall(Registry(address(registryModel)), address(0));
        bytes memory expected = abi.encodeWithSelector(USD8PriceOracle.ZeroAddress.selector);
        assert(!zeroRegistry && _sameBytes(zeroRegistryData, expected));
        assert(!zeroFeed && _sameBytes(zeroFeedData, expected));
    }

    function test_constructorRejectsZeroRegistryBindingsInReadOrderWithExactError() public {
        USD8PriceOracleRegistryHarness candidate = new USD8PriceOracleRegistryHarness();
        candidate.setTreasury(address(treasury));
        (bool zeroUsd8, bytes memory zeroUsd8Data) = _deployCall(Registry(address(candidate)), address(feed));
        bytes memory expected = abi.encodeWithSelector(USD8PriceOracle.ZeroAddress.selector);
        assert(!zeroUsd8 && _sameBytes(zeroUsd8Data, expected));

        candidate.setUsd8(address(usd8));
        candidate.setTreasury(address(0));
        (bool zeroTreasury, bytes memory zeroTreasuryData) = _deployCall(Registry(address(candidate)), address(feed));
        assert(!zeroTreasury && _sameBytes(zeroTreasuryData, expected));
    }

    function test_constructorNoCodeRegistryReturnsExactEmptyBytes() public {
        (bool success, bytes memory data) = _deployCall(Registry(address(0xBEEF)), address(feed));
        assert(!success && data.length == 0);
    }

    function test_constructorRegistryUsd8RevertIsExactAndPrecedesTreasuryRead() public {
        USD8PriceOracleRegistryHarness candidate = new USD8PriceOracleRegistryHarness();
        candidate.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.Revert, USD8PriceOracleRegistryHarness.ReturnMode.Revert
        );
        (bool success, bytes memory data) = _deployCall(Registry(address(candidate)), address(feed));
        bytes memory expected =
            abi.encodeWithSelector(USD8PriceOracleRegistryHarness.RegistryFailure.selector, uint256(6));
        assert(!success && _sameBytes(data, expected));
    }

    function test_constructorRegistryTreasuryRevertIsExactAfterValidUsd8() public {
        USD8PriceOracleRegistryHarness candidate = new USD8PriceOracleRegistryHarness();
        candidate.setUsd8(address(usd8));
        candidate.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.Valid, USD8PriceOracleRegistryHarness.ReturnMode.Revert
        );
        (bool success, bytes memory data) = _deployCall(Registry(address(candidate)), address(feed));
        bytes memory expected =
            abi.encodeWithSelector(USD8PriceOracleRegistryHarness.RegistryFailure.selector, uint256(7));
        assert(!success && _sameBytes(data, expected));
    }

    function test_constructorRegistryMalformedBindingsReturnEmptyAndPreserveReadOrder() public {
        USD8PriceOracleRegistryHarness candidate = new USD8PriceOracleRegistryHarness();
        candidate.setUsd8(address(usd8));
        candidate.setTreasury(address(treasury));
        candidate.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.MalformedShort, USD8PriceOracleRegistryHarness.ReturnMode.Revert
        );
        (bool shortUsd8, bytes memory shortUsd8Data) = _deployCall(Registry(address(candidate)), address(feed));
        assert(!shortUsd8 && shortUsd8Data.length == 0);

        candidate.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.Valid, USD8PriceOracleRegistryHarness.ReturnMode.MalformedShort
        );
        (bool shortTreasury, bytes memory shortTreasuryData) = _deployCall(Registry(address(candidate)), address(feed));
        assert(!shortTreasury && shortTreasuryData.length == 0);

        candidate.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.MalformedNonCanonical,
            USD8PriceOracleRegistryHarness.ReturnMode.Revert
        );
        (bool narrowUsd8, bytes memory narrowUsd8Data) = _deployCall(Registry(address(candidate)), address(feed));
        assert(!narrowUsd8 && narrowUsd8Data.length == 0);

        candidate.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.Valid,
            USD8PriceOracleRegistryHarness.ReturnMode.MalformedNonCanonical
        );
        (bool narrowTreasury, bytes memory narrowTreasuryData) =
            _deployCall(Registry(address(candidate)), address(feed));
        assert(!narrowTreasury && narrowTreasuryData.length == 0);
    }

    function test_immutablesConstantsAndMetadataAreExact() public view {
        assert(address(oracle.REGISTRY()) == address(registryModel));
        assert(address(oracle.USDC_USD_FEED()) == address(feed));
        assert(oracle.USDC_TO_USD8_SCALE() == SCALE);
        assert(keccak256(bytes(oracle.description())) == keccak256(bytes("USD8 / USD")));
        assert(oracle.version() == 1);
        assert(oracle.decimals() == 8);
    }

    function test_decimalsForwardsCurrentFeedValueExactly(uint8 decimals_) public {
        feed.setDecimals(decimals_);
        assert(oracle.decimals() == decimals_);
    }

    function test_descriptionAndVersionDoNotDependOnBrokenExternals() public {
        feed.setFailures(true, true);
        registryModel.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.Revert, USD8PriceOracleRegistryHarness.ReturnMode.Revert
        );
        assert(keccak256(bytes(oracle.description())) == keccak256(bytes("USD8 / USD")));
        assert(oracle.version() == 1);
    }

    function test_latestRoundDataPreservesAllRoundMetadata(
        uint80 roundId,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) public {
        feed.setRound(roundId, 100_000_000, startedAt, updatedAt, answeredInRound);
        usd8.setSupply(4 * SCALE);
        treasury.setReserve(1);
        (uint80 actualRound, int256 answer, uint256 actualStarted, uint256 actualUpdated, uint80 actualAnswered) =
            oracle.latestRoundData();
        assert(actualRound == roundId && answer == 25_000_000);
        assert(actualStarted == startedAt && actualUpdated == updatedAt && actualAnswered == answeredInRound);
    }

    function test_getRoundDataSuccessfulReturndataExactlyMatchesLatestAndNeverCallsHistorical(uint80 roundId) public {
        feed.setRound(roundId, 99_999_999, 17, 23, roundId);
        usd8.setSupply(3 * SCALE);
        treasury.setReserve(3);
        (bool latestSuccess, bytes memory latestData) = _latestCall();
        (bool getSuccess, bytes memory getData) = _getRoundCall(roundId);
        assert(latestSuccess && getSuccess && _sameBytes(getData, latestData));
    }

    function test_unsupportedRoundGuardPrecedesUsd8AndTreasuryReadsWithExactFailureWitnesses(
        uint80 currentRound,
        uint80 requestedRound
    ) public {
        vm.assume(requestedRound != currentRound);
        feed.setRound(currentRound, 100_000_000, 11, 12, currentRound);
        bytes memory expected =
            abi.encodeWithSelector(USD8PriceOracle.HistoricalRoundUnsupported.selector, requestedRound);

        // A healthy feed answer makes the poisoned supply the next downstream failure
        // if the unsupported-round guard is ever moved after backing application.
        usd8.setRevert(true);
        treasury.setRevert(false);
        treasury.setReserve(1);
        (bool beforeSupply, bytes memory beforeSupplyData) = _getRoundCall(requestedRound);
        assert(!beforeSupply && _sameBytes(beforeSupplyData, expected));

        // With supply valid, the poisoned Treasury is independently the next failure.
        usd8.setRevert(false);
        usd8.setSupply(SCALE);
        treasury.setRevert(true);
        (bool beforeTreasury, bytes memory beforeTreasuryData) = _getRoundCall(requestedRound);
        assert(!beforeTreasury && _sameBytes(beforeTreasuryData, expected));
    }

    function test_invalidAnswerFullInt256DomainIsExactForLatestAndGetRound(int256 invalid) public {
        vm.assume(invalid <= 0);
        feed.setRound(1, invalid, 0, 0, 1);
        usd8.setRevert(true);
        treasury.setRevert(true);
        bytes memory expected = abi.encodeWithSelector(USD8PriceOracle.InvalidOracleAnswer.selector, invalid);
        (bool latestSuccess, bytes memory latestData) = _latestCall();
        (bool getSuccess, bytes memory getData) = _getRoundCall(1);
        assert(!latestSuccess && _sameBytes(latestData, expected));
        assert(!getSuccess && _sameBytes(getData, expected));
    }

    function test_zeroSupplyExactFourBytesPrecedesTreasuryForLatestAndGetRound() public {
        usd8.setSupply(0);
        treasury.setRevert(true);
        bytes memory expected = abi.encodeWithSelector(USD8PriceOracle.NoUsd8Supply.selector);
        (bool latestSuccess, bytes memory latestData) = _latestCall();
        (bool getSuccess, bytes memory getData) = _getRoundCall(42);
        assert(expected.length == 4);
        assert(!latestSuccess && _sameBytes(latestData, expected));
        assert(!getSuccess && _sameBytes(getData, expected));
    }

    /// @dev [SMOKE:EXACT_SIGNATURE_REQUIRED] Exact-signature solver smoke required for
    ///      test_fullWidthValidDomainArithmeticIsExactAndPanicFree(uint256,uint256,int256).
    function test_fullWidthValidDomainArithmeticIsExactAndPanicFree(uint256 supply, uint256 reserve, int256 answer)
        public
    {
        vm.assume(supply > 0 && answer > 0);
        uint256 ceilReserve = ((supply - 1) / SCALE) + 1;
        uint256 effectiveCollateral = reserve >= ceilReserve ? supply : reserve * SCALE;
        uint256 expectedAnswer = Math.mulDiv(uint256(answer), effectiveCollateral, supply);
        usd8.setSupply(supply);
        treasury.setReserve(reserve);
        feed.setRound(9, answer, 3, 4, 9);

        (bool latestSuccess, bytes memory latestData) = _latestCall();
        (bool getSuccess, bytes memory getData) = _getRoundCall(9);
        assert(latestSuccess && getSuccess && _sameBytes(getData, latestData));
        (uint80 actualRound, int256 actualAnswer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            abi.decode(latestData, (uint80, int256, uint256, uint256, uint80));
        assert(actualRound == 9 && startedAt == 3 && updatedAt == 4 && answeredInRound == 9);
        assert(actualAnswer == int256(expectedAnswer));
    }

    function test_fullCollateralAtIndependentCeilBoundaryHasExactRoundViewParity(uint128 supplySeed, uint64 answerSeed)
        public
    {
        uint256 supply = uint256(supplySeed) + 1;
        uint256 positiveAnswer = uint256(answerSeed) + 1;
        uint256 ceilReserve = ((supply - 1) / SCALE) + 1;
        usd8.setSupply(supply);
        treasury.setReserve(ceilReserve);
        feed.setRound(1, int256(positiveAnswer), 0, 0, 1);
        (bool latestSuccess, bytes memory latestData) = _latestCall();
        (bool getSuccess, bytes memory getData) = _getRoundCall(1);
        assert(latestSuccess && getSuccess && _sameBytes(getData, latestData));
        (, int256 actual,,,) = abi.decode(latestData, (uint80, int256, uint256, uint256, uint80));
        assert(uint256(actual) == positiveAnswer);
    }

    function test_oneBelowCeilBoundaryHasExactDistressedRoundViewParity(uint128 supplySeed, uint64 answerSeed) public {
        uint256 supply = uint256(supplySeed) + SCALE + 1;
        uint256 positiveAnswer = uint256(answerSeed) + 1;
        uint256 reserve = ((supply - 1) / SCALE);
        uint256 effectiveCollateral = reserve * SCALE;
        uint256 expected = (positiveAnswer * effectiveCollateral) / supply;
        assert(effectiveCollateral < supply);
        usd8.setSupply(supply);
        treasury.setReserve(reserve);
        feed.setRound(1, int256(positiveAnswer), 0, 0, 1);
        (bool latestSuccess, bytes memory latestData) = _latestCall();
        (bool getSuccess, bytes memory getData) = _getRoundCall(1);
        assert(latestSuccess && getSuccess && _sameBytes(getData, latestData));
        (, int256 actual,,,) = abi.decode(latestData, (uint80, int256, uint256, uint256, uint80));
        assert(uint256(actual) == expected && uint256(actual) < positiveAnswer);
    }

    function test_zeroReserveReturnsExactZeroForLatestAndGetRound(uint256 supply, int256 answer) public {
        vm.assume(supply > 0 && answer > 0);
        usd8.setSupply(supply);
        treasury.setReserve(0);
        feed.setRound(1, answer, 0, 0, 1);
        (bool latestSuccess, bytes memory latestData) = _latestCall();
        (bool getSuccess, bytes memory getData) = _getRoundCall(1);
        assert(latestSuccess && getSuccess && _sameBytes(getData, latestData));
        (, int256 actual,,,) = abi.decode(latestData, (uint80, int256, uint256, uint256, uint80));
        assert(actual == 0);
    }

    function test_undercollateralizedArithmeticSatisfiesIndependentFloorIdentity(
        uint64 reserveSeed,
        uint128 extraLiability,
        uint64 answerSeed
    ) public {
        uint256 reserve = uint256(reserveSeed);
        uint256 effectiveCollateral = reserve * SCALE;
        uint256 supply = effectiveCollateral + uint256(extraLiability) + 1;
        uint256 positiveAnswer = uint256(answerSeed) + 1;
        uint256 numerator = positiveAnswer * effectiveCollateral;
        usd8.setSupply(supply);
        treasury.setReserve(reserve);
        feed.setRound(1, int256(positiveAnswer), 0, 0, 1);
        (, int256 signedResult,,,) = oracle.latestRoundData();
        uint256 result = uint256(signedResult);
        assert(result * supply <= numerator);
        assert(numerator - (result * supply) < supply);
    }

    function test_reserveScalingIsLinearBeforeFlooring(uint32 reserveSeed, uint64 answerSeed) public {
        uint256 reserve = uint256(reserveSeed) + 1;
        uint256 positiveAnswer = (uint256(answerSeed) + 1) * 2;
        uint256 supply = (2 * reserve * SCALE) + 1;
        usd8.setSupply(supply);
        feed.setRound(1, int256(positiveAnswer), 0, 0, 1);
        treasury.setReserve(reserve);
        (, int256 oneReserveAnswer,,,) = oracle.latestRoundData();
        treasury.setReserve(2 * reserve);
        (, int256 twoReserveAnswer,,,) = oracle.latestRoundData();
        assert(uint256(twoReserveAnswer) >= 2 * uint256(oneReserveAnswer));
        assert(uint256(twoReserveAnswer) <= (2 * uint256(oneReserveAnswer)) + 1);
    }

    function test_safeCastErrorsAndArithmeticPanicsAreUnreachable() public {
        // SafeCastOverflowedIntToUint(int256) is unreachable: InvalidOracleAnswer
        // preempts the complete non-positive int256 domain, including int256.min.
        feed.setRound(1, type(int256).min, 0, 0, 1);
        (bool invalidSuccess, bytes memory invalidData) = _latestCall();
        bytes memory invalidExpected =
            abi.encodeWithSelector(USD8PriceOracle.InvalidOracleAnswer.selector, type(int256).min);
        assert(!invalidSuccess && _sameBytes(invalidData, invalidExpected));

        // Math.mulDiv's result is <= the positive feed answer <= int256.max, so
        // SafeCastOverflowedUintToInt(uint256) is unreachable. The distressed
        // multiplication is evaluated only when reserve < ceilDiv(supply, SCALE),
        // which implies reserve * SCALE < supply and excludes Panic(0x11).
        usd8.setSupply(type(uint256).max);
        treasury.setReserve(type(uint256).max);
        feed.setRound(1, type(int256).max, 0, 0, 1);
        (, int256 healthy,,,) = oracle.latestRoundData();
        assert(healthy == type(int256).max);
        treasury.setReserve(((type(uint256).max - 1) / SCALE));
        (, int256 distressed,,,) = oracle.latestRoundData();
        assert(distressed >= 0 && distressed < type(int256).max);
    }

    function test_registryUsd8PointerIsReadDynamically() public {
        USD8PriceOracleSupplyHarness replacement = new USD8PriceOracleSupplyHarness();
        usd8.setSupply(10 * SCALE);
        treasury.setReserve(10);
        (, int256 initial,,,) = oracle.latestRoundData();
        replacement.setSupply(20 * SCALE);
        registryModel.setUsd8(address(replacement));
        (, int256 afterRotation,,,) = oracle.latestRoundData();
        assert(initial == 100_000_000 && afterRotation == 50_000_000);
    }

    function test_registryTreasuryPointerIsReadDynamically() public {
        USD8PriceOracleTreasuryHarness replacement = new USD8PriceOracleTreasuryHarness();
        usd8.setSupply(20 * SCALE);
        treasury.setReserve(10);
        replacement.setReserve(20);
        (, int256 initial,,,) = oracle.latestRoundData();
        registryModel.setTreasury(address(replacement));
        (, int256 afterRotation,,,) = oracle.latestRoundData();
        assert(initial == 50_000_000 && afterRotation == 100_000_000);
    }

    function test_feedFailurePayloadsAreExactForDecimalsLatestAndGetRound() public {
        feed.setFailures(true, true);
        (bool decimalsSuccess, bytes memory decimalsData) = _decimalsCall(oracle);
        (bool latestSuccess, bytes memory latestData) = _latestCall();
        (bool getSuccess, bytes memory getData) = _getRoundCall(42);
        bytes memory decimalsExpected =
            abi.encodeWithSelector(USD8PriceOracleFeedHarness.FeedFailure.selector, uint256(1));
        bytes memory roundExpected = abi.encodeWithSelector(USD8PriceOracleFeedHarness.FeedFailure.selector, uint256(2));
        assert(!decimalsSuccess && _sameBytes(decimalsData, decimalsExpected));
        assert(!latestSuccess && _sameBytes(latestData, roundExpected));
        assert(!getSuccess && _sameBytes(getData, roundExpected));
    }

    function test_supplyAndTreasuryFailurePayloadsAreExactForLatestAndGetRound() public {
        usd8.setSupply(SCALE);
        treasury.setReserve(1);
        usd8.setRevert(true);
        bytes memory supplyExpected =
            abi.encodeWithSelector(USD8PriceOracleSupplyHarness.SupplyFailure.selector, uint256(4));
        (bool latestSupplySuccess, bytes memory latestSupplyData) = _latestCall();
        (bool getSupplySuccess, bytes memory getSupplyData) = _getRoundCall(42);
        assert(!latestSupplySuccess && _sameBytes(latestSupplyData, supplyExpected));
        assert(!getSupplySuccess && _sameBytes(getSupplyData, supplyExpected));

        usd8.setRevert(false);
        treasury.setRevert(true);
        bytes memory treasuryExpected =
            abi.encodeWithSelector(USD8PriceOracleTreasuryHarness.TreasuryFailure.selector, uint256(5));
        (bool latestTreasurySuccess, bytes memory latestTreasuryData) = _latestCall();
        (bool getTreasurySuccess, bytes memory getTreasuryData) = _getRoundCall(42);
        assert(!latestTreasurySuccess && _sameBytes(latestTreasuryData, treasuryExpected));
        assert(!getTreasurySuccess && _sameBytes(getTreasuryData, treasuryExpected));
    }

    function test_runtimeRegistryRevertsAreExactForLatestAndGetRound() public {
        registryModel.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.Revert, USD8PriceOracleRegistryHarness.ReturnMode.Valid
        );
        bytes memory usd8Expected =
            abi.encodeWithSelector(USD8PriceOracleRegistryHarness.RegistryFailure.selector, uint256(6));
        (bool latestUsd8Success, bytes memory latestUsd8Data) = _latestCall();
        (bool getUsd8Success, bytes memory getUsd8Data) = _getRoundCall(42);
        assert(!latestUsd8Success && _sameBytes(latestUsd8Data, usd8Expected));
        assert(!getUsd8Success && _sameBytes(getUsd8Data, usd8Expected));

        registryModel.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.Valid, USD8PriceOracleRegistryHarness.ReturnMode.Revert
        );
        usd8.setSupply(SCALE);
        bytes memory treasuryExpected =
            abi.encodeWithSelector(USD8PriceOracleRegistryHarness.RegistryFailure.selector, uint256(7));
        (bool latestTreasurySuccess, bytes memory latestTreasuryData) = _latestCall();
        (bool getTreasurySuccess, bytes memory getTreasuryData) = _getRoundCall(42);
        assert(!latestTreasurySuccess && _sameBytes(latestTreasuryData, treasuryExpected));
        assert(!getTreasurySuccess && _sameBytes(getTreasuryData, treasuryExpected));
    }

    function test_malformedFeedShortResponsesReturnExactEmptyBytes() public {
        USD8PriceOracle malformedOracle =
            new USD8PriceOracle(Registry(address(registryModel)), address(new USD8PriceOracleMalformedFeed()));
        (bool decimalsSuccess, bytes memory decimalsData) = _decimalsCall(malformedOracle);
        (bool latestSuccess, bytes memory latestData) = _latestCall(malformedOracle);
        (bool getSuccess, bytes memory getData) = _getRoundCall(malformedOracle, 0);
        assert(!decimalsSuccess && decimalsData.length == 0);
        assert(!latestSuccess && latestData.length == 0);
        assert(!getSuccess && getData.length == 0);
    }

    function test_malformedCanonicalWidthNarrowFeedReturnsExactEmptyBytes() public {
        USD8PriceOracle malformedOracle =
            new USD8PriceOracle(Registry(address(registryModel)), address(new USD8PriceOracleNonCanonicalFeed()));
        (bool decimalsSuccess, bytes memory decimalsData) = _decimalsCall(malformedOracle);
        (bool latestSuccess, bytes memory latestData) = _latestCall(malformedOracle);
        (bool getSuccess, bytes memory getData) = _getRoundCall(malformedOracle, 0);
        assert(!decimalsSuccess && decimalsData.length == 0);
        assert(!latestSuccess && latestData.length == 0);
        assert(!getSuccess && getData.length == 0);
    }

    function test_nonCanonicalAnsweredInRoundReturnsExactEmptyBytesForBothRoundViews() public {
        USD8PriceOracle malformedOracle = new USD8PriceOracle(
            Registry(address(registryModel)), address(new USD8PriceOracleNonCanonicalAnsweredInRoundFeed())
        );
        (bool latestSuccess, bytes memory latestData) = _latestCall(malformedOracle);
        (bool getSuccess, bytes memory getData) = _getRoundCall(malformedOracle, 1);
        assert(!latestSuccess && latestData.length == 0);
        assert(!getSuccess && getData.length == 0);
    }

    function test_malformedSupplyAndTreasuryReturnExactEmptyBytesForBothRoundViews() public {
        registryModel.setUsd8(address(new USD8PriceOracleMalformedSupply()));
        (bool latestSupplySuccess, bytes memory latestSupplyData) = _latestCall();
        (bool getSupplySuccess, bytes memory getSupplyData) = _getRoundCall(42);
        assert(!latestSupplySuccess && latestSupplyData.length == 0);
        assert(!getSupplySuccess && getSupplyData.length == 0);

        registryModel.setUsd8(address(usd8));
        usd8.setSupply(SCALE);
        registryModel.setTreasury(address(new USD8PriceOracleMalformedTreasury()));
        (bool latestTreasurySuccess, bytes memory latestTreasuryData) = _latestCall();
        (bool getTreasurySuccess, bytes memory getTreasuryData) = _getRoundCall(42);
        assert(!latestTreasurySuccess && latestTreasuryData.length == 0);
        assert(!getTreasurySuccess && getTreasuryData.length == 0);
    }

    function test_runtimeMalformedRegistryPointersReturnExactEmptyBytes() public {
        registryModel.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.MalformedNonCanonical,
            USD8PriceOracleRegistryHarness.ReturnMode.Valid
        );
        (bool latestUsd8Success, bytes memory latestUsd8Data) = _latestCall();
        (bool getUsd8Success, bytes memory getUsd8Data) = _getRoundCall(42);
        assert(!latestUsd8Success && latestUsd8Data.length == 0);
        assert(!getUsd8Success && getUsd8Data.length == 0);

        registryModel.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.MalformedShort, USD8PriceOracleRegistryHarness.ReturnMode.Valid
        );
        (bool latestShortUsd8Success, bytes memory latestShortUsd8Data) = _latestCall();
        (bool getShortUsd8Success, bytes memory getShortUsd8Data) = _getRoundCall(42);
        assert(!latestShortUsd8Success && latestShortUsd8Data.length == 0);
        assert(!getShortUsd8Success && getShortUsd8Data.length == 0);

        registryModel.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.Valid, USD8PriceOracleRegistryHarness.ReturnMode.MalformedShort
        );
        usd8.setSupply(SCALE);
        (bool latestTreasurySuccess, bytes memory latestTreasuryData) = _latestCall();
        (bool getTreasurySuccess, bytes memory getTreasuryData) = _getRoundCall(42);
        assert(!latestTreasurySuccess && latestTreasuryData.length == 0);
        assert(!getTreasurySuccess && getTreasuryData.length == 0);

        registryModel.setModes(
            USD8PriceOracleRegistryHarness.ReturnMode.Valid,
            USD8PriceOracleRegistryHarness.ReturnMode.MalformedNonCanonical
        );
        (bool latestNarrowTreasurySuccess, bytes memory latestNarrowTreasuryData) = _latestCall();
        (bool getNarrowTreasurySuccess, bytes memory getNarrowTreasuryData) = _getRoundCall(42);
        assert(!latestNarrowTreasurySuccess && latestNarrowTreasuryData.length == 0);
        assert(!getNarrowTreasurySuccess && getNarrowTreasuryData.length == 0);
    }

    function test_noCodeDynamicPointersReturnExactEmptyBytesForBothRoundViews() public {
        registryModel.setUsd8(address(0xCAFE));
        (bool latestSupplySuccess, bytes memory latestSupplyData) = _latestCall();
        (bool getSupplySuccess, bytes memory getSupplyData) = _getRoundCall(42);
        assert(!latestSupplySuccess && latestSupplyData.length == 0);
        assert(!getSupplySuccess && getSupplyData.length == 0);

        registryModel.setUsd8(address(usd8));
        usd8.setSupply(SCALE);
        registryModel.setTreasury(address(0xD00D));
        (bool latestTreasurySuccess, bytes memory latestTreasuryData) = _latestCall();
        (bool getTreasurySuccess, bytes memory getTreasuryData) = _getRoundCall(42);
        assert(!latestTreasurySuccess && latestTreasuryData.length == 0);
        assert(!getTreasurySuccess && getTreasuryData.length == 0);
    }

    function test_getRoundDataMalformedAndNoCodeFeedReturnEmptyBytes() public {
        USD8PriceOracle noCodeOracle = new USD8PriceOracle(Registry(address(registryModel)), address(0xFEE1));
        assert(address(noCodeOracle.USDC_USD_FEED()) == address(0xFEE1));
        (bool decimalsSuccess, bytes memory decimalsData) = _decimalsCall(noCodeOracle);
        (bool latestSuccess, bytes memory latestData) = _latestCall(noCodeOracle);
        (bool getSuccess, bytes memory getData) = _getRoundCall(noCodeOracle, 42);
        assert(!decimalsSuccess && decimalsData.length == 0);
        assert(!latestSuccess && latestData.length == 0);
        assert(!getSuccess && getData.length == 0);
    }
}
