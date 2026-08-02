// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Registry} from "../src/Registry.sol";
import {DeploySepoliaFastE2ESystemScript} from "../script/testnet/06_DeploySepoliaFastE2ESystem.s.sol";
import {SepoliaTestToken, SepoliaTestUsdFeed} from "../script/testnet/SepoliaLossFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";

contract FastE2EDeploymentHarness is DeploySepoliaFastE2ESystemScript {
    function deployForTest(address usdc, address coverAsset, address coverFeed, address usdcFeed, address booster)
        external
        returns (System memory)
    {
        return _deploy(address(this), usdc, coverAsset, coverFeed, usdcFeed, booster);
    }
}

contract SepoliaExpandedE2EFixtureTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant USER = address(0xB0B);

    function testFastSystemDeploymentPermanentlyConfiguresOnePercentBooster() external {
        FastE2EDeploymentHarness harness = new FastE2EDeploymentHarness();
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        MockERC20 coverAsset = new MockERC20("Mock wstETH", "mwstETH", 18);
        SepoliaTestUsdFeed coverFeed = new SepoliaTestUsdFeed(2_000e8, 8, address(harness));
        SepoliaTestUsdFeed usdcFeed = new SepoliaTestUsdFeed(1e8, 8, address(harness));
        MockERC1155 booster = new MockERC1155();
        coverAsset.mint(address(harness), 0.01 ether);

        DeploySepoliaFastE2ESystemScript.System memory system = harness.deployForTest(
            address(usdc), address(coverAsset), address(coverFeed), address(usdcFeed), address(booster)
        );

        (address collection, uint64 tokenId, uint16 boostBps) = Registry(address(system.registry)).boosterConfig();
        assertEq(collection, address(booster));
        assertEq(tokenId, 1);
        assertEq(boostBps, 100);
    }

    function testTestTokenRestrictsMintingToAdmin() external {
        SepoliaTestToken token = new SepoliaTestToken("Mock GHO", "mGHO", ADMIN);

        vm.prank(ADMIN);
        token.mint(USER, 25 ether);
        assertEq(token.balanceOf(USER), 25 ether);

        vm.expectRevert(SepoliaTestToken.Unauthorized.selector);
        vm.prank(USER);
        token.mint(USER, 1 ether);
    }

    function testUsdFeedPublishesFreshChainlinkCompatibleRounds() external {
        vm.warp(1_800_000_000);
        SepoliaTestUsdFeed feed = new SepoliaTestUsdFeed(2_000e8, 8, ADMIN);

        assertEq(feed.decimals(), 8);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, 2_000e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, roundId);

        vm.warp(block.timestamp + 10);
        vm.prank(ADMIN);
        feed.setAnswer(1_999e8);
        (roundId, answer, startedAt, updatedAt, answeredInRound) = feed.latestRoundData();
        assertEq(roundId, 2);
        assertEq(answer, 1_999e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, roundId);
    }

    function testUsdFeedRejectsInvalidConfigurationAndUnauthorizedUpdates() external {
        vm.expectRevert(SepoliaTestUsdFeed.InvalidAnswer.selector);
        new SepoliaTestUsdFeed(0, 8, ADMIN);

        vm.expectRevert(SepoliaTestUsdFeed.InvalidDecimals.selector);
        new SepoliaTestUsdFeed(1e8, 19, ADMIN);

        SepoliaTestUsdFeed feed = new SepoliaTestUsdFeed(1e8, 8, ADMIN);
        vm.expectRevert(SepoliaTestUsdFeed.Unauthorized.selector);
        vm.prank(USER);
        feed.setAnswer(2e8);
    }
}
