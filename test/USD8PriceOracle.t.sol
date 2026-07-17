// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {USD8PriceOracle} from "../src/oracles/USD8PriceOracle.sol";
import {Registry} from "../src/Registry.sol";

contract OracleMockERC20 is ERC20 {
    constructor() ERC20("USD8", "USD8") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract OracleMockTreasury {
    // ABI intentionally mirrors Treasury.usd8().
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable usd8;
    uint256 public reserve;

    constructor(IERC20 usd8_) {
        usd8 = usd8_;
    }

    function setReserve(uint256 reserve_) external {
        reserve = reserve_;
    }

    function getReserveBalance() external view returns (uint256) {
        return reserve;
    }
}

contract OracleMockAggregator {
    int256 public answer = 99_900_000;
    uint80 public roundId = 42;
    uint256 public startedAt = 100;
    uint256 public updatedAt = 200;
    uint80 public answeredInRound = 42;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "USDC / USD";
    }

    function version() external pure returns (uint256) {
        return 4;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function getRoundData(uint80 requestedRoundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (requestedRoundId, answer, startedAt, updatedAt, requestedRoundId);
    }
}

contract USD8PriceOracleTest is Test {
    OracleMockERC20 internal usd8;
    OracleMockTreasury internal treasury;
    OracleMockAggregator internal usdcUsd;
    Registry internal registry;
    USD8PriceOracle internal oracle;

    function setUp() public {
        usd8 = new OracleMockERC20();
        treasury = new OracleMockTreasury(usd8);
        usdcUsd = new OracleMockAggregator();
        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(treasury));
        oracle = new USD8PriceOracle(registry, address(usdcUsd));
    }

    function test_MetadataIdentifiesUsd8UsdFeed() public view {
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.description(), "USD8 / USD");
        assertEq(oracle.version(), 1);
    }

    function test_HealthyAndSurplusBackingUseUsdcUsdPrice() public {
        usd8.mint(address(this), 100e18);

        treasury.setReserve(100e6);
        (, int256 healthyAnswer,,,) = oracle.latestRoundData();
        assertEq(healthyAnswer, 99_900_000);

        treasury.setReserve(125e6);
        (, int256 surplusAnswer,,,) = oracle.latestRoundData();
        assertEq(surplusAnswer, 99_900_000);
    }

    function test_UsesCurrentRegistryTreasury() public {
        usd8.mint(address(this), 100e18);
        treasury.setReserve(100e6);

        OracleMockTreasury replacement = new OracleMockTreasury(usd8);
        replacement.setReserve(25e6);
        registry.setTreasury(address(replacement));

        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, 24_975_000);
    }

    function test_DistressMultipliesUsdcPriceByRedemptionRatio() public {
        usd8.mint(address(this), 100e18);
        treasury.setReserve(40e6);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        assertEq(answer, 39_960_000);
        assertEq(roundId, 42);
        assertEq(startedAt, 100);
        assertEq(updatedAt, 200);
        assertEq(answeredInRound, 42);
    }

    function test_GetRoundDataSupportsOnlyCurrentCompositeRound() public {
        usd8.mint(address(this), 100e18);
        treasury.setReserve(50e6);

        (uint80 roundId, int256 answer,,, uint80 answeredInRound) = oracle.getRoundData(42);
        assertEq(roundId, 42);
        assertEq(answer, 49_950_000);
        assertEq(answeredInRound, 42);

        vm.expectRevert(abi.encodeWithSelector(USD8PriceOracle.HistoricalRoundUnsupported.selector, uint80(7)));
        oracle.getRoundData(7);
    }

    function testFuzz_MatchesTreasuryRedemptionRatio(uint128 supplySeed, uint128 reserveSeed) public {
        uint256 supply = bound(uint256(supplySeed), 1, type(uint128).max);
        uint256 reserve = uint256(reserveSeed);
        usd8.mint(address(this), supply);
        treasury.setReserve(reserve);

        (, int256 answer,,,) = oracle.latestRoundData();
        uint256 reserveInUsd8 = reserve * 1e12;
        uint256 effectiveCollateral = reserveInUsd8 < supply ? reserveInUsd8 : supply;
        uint256 expected = Math.mulDiv(99_900_000, effectiveCollateral, supply);
        assertEq(uint256(answer), expected);
    }

    function test_NonAlignedSupplyAndOneUnitReserveBoundary() public {
        usd8.mint(address(this), 1e18 + 1);

        treasury.setReserve(1e6);
        (, int256 oneWeiShort,,,) = oracle.latestRoundData();
        assertEq(uint256(oneWeiShort), Math.mulDiv(99_900_000, 1e18, 1e18 + 1));

        treasury.setReserve(1e6 + 1);
        (, int256 fullyBacked,,,) = oracle.latestRoundData();
        assertEq(fullyBacked, 99_900_000);
    }

    function test_NearUint256SupplyDoesNotOverflow() public {
        uint256 supply = type(uint256).max;
        usd8.mint(address(this), supply);
        uint256 fullBackingReserve = Math.ceilDiv(supply, 1e12);

        treasury.setReserve(fullBackingReserve - 1);
        (, int256 distressed,,,) = oracle.latestRoundData();
        assertLt(distressed, 99_900_000);

        treasury.setReserve(fullBackingReserve);
        (, int256 fullyBacked,,,) = oracle.latestRoundData();
        assertEq(fullyBacked, 99_900_000);
    }

    function test_RevertsWhenUsd8SupplyIsZero() public {
        vm.expectRevert(USD8PriceOracle.NoUsd8Supply.selector);
        oracle.latestRoundData();
    }

    function test_RevertsForInvalidUsdcOracleAnswer() public {
        usd8.mint(address(this), 100e18);
        treasury.setReserve(100e6);
        usdcUsd.setAnswer(0);

        vm.expectRevert(abi.encodeWithSelector(USD8PriceOracle.InvalidOracleAnswer.selector, int256(0)));
        oracle.latestRoundData();
    }
}
