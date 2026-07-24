// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SepoliaDependencies, SepoliaTestToken, SepoliaTestOracle} from "../script/testnet/SepoliaDependencies.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract SepoliaDependenciesTest is Test {
    address internal admin = makeAddr("sepolia admin");
    MockERC20 internal usdc;
    SepoliaDependencies internal dependencies;

    function setUp() public {
        usdc = new MockERC20("Circle Test USDC", "USDC", 6);
        dependencies = new SepoliaDependencies(admin, address(usdc));
    }

    function test_DeploysCompleteCompatibleDependencySet() public view {
        assertEq(dependencies.admin(), admin);
        assertEq(dependencies.usdc(), address(usdc));

        assertEq(IERC4626(dependencies.aaveUsdcVault()).asset(), address(usdc));
        assertEq(IERC4626(dependencies.morphoUsdcVault()).asset(), address(usdc));
        assertEq(IERC4626(dependencies.aaveSgho()).convertToAssets(1e18), 1e18);
        assertEq(IERC4626(dependencies.skySusds()).convertToAssets(1e18), 1e18);

        assertEq(IERC20Metadata(dependencies.coverAsset()).decimals(), 18);
        assertEq(IERC20(dependencies.coverAsset()).balanceOf(admin), 1_000e18);
        assertEq(IERC20(dependencies.gho()).balanceOf(admin), 1_000_000e18);
        assertEq(IERC20(dependencies.usds()).balanceOf(admin), 1_000_000e18);

        _assertPositiveFeed(dependencies.coverAssetUsdOracle(), 4_000e8);
        _assertPositiveFeed(dependencies.ghoUsdOracle(), 1e8);
        _assertPositiveFeed(dependencies.usdsUsdOracle(), 1e8);
        _assertPositiveFeed(dependencies.usdcUsdOracle(), 1e8);
    }

    function test_AdminCanMintTestAssetsAndUpdateFeeds() public {
        SepoliaTestToken coverAsset = SepoliaTestToken(dependencies.coverAsset());
        SepoliaTestOracle coverFeed = SepoliaTestOracle(dependencies.coverAssetUsdOracle());

        vm.startPrank(admin);
        coverAsset.mint(address(this), 2e18);
        coverFeed.updateAnswer(3_500e8);
        vm.stopPrank();

        assertEq(coverAsset.balanceOf(address(this)), 2e18);
        _assertPositiveFeed(address(coverFeed), 3_500e8);
    }

    function test_NonAdminCannotMintOrUpdateFeeds() public {
        SepoliaTestToken coverAsset = SepoliaTestToken(dependencies.coverAsset());
        SepoliaTestOracle coverFeed = SepoliaTestOracle(dependencies.coverAssetUsdOracle());

        vm.expectRevert(SepoliaTestToken.Unauthorized.selector);
        coverAsset.mint(address(this), 1);

        vm.expectRevert(SepoliaTestOracle.Unauthorized.selector);
        coverFeed.updateAnswer(1);
    }

    function test_RejectsZeroAdminOrUsdc() public {
        vm.expectRevert(SepoliaDependencies.ZeroAddress.selector);
        new SepoliaDependencies(address(0), address(usdc));

        vm.expectRevert(SepoliaDependencies.ZeroAddress.selector);
        new SepoliaDependencies(admin, address(0));
    }

    function _assertPositiveFeed(address feed, int256 expectedAnswer) private view {
        assertEq(SepoliaTestOracle(feed).decimals(), 8);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            SepoliaTestOracle(feed).latestRoundData();
        assertEq(answer, expectedAnswer);
        assertGt(updatedAt, 0);
        assertGe(answeredInRound, roundId);
    }
}
