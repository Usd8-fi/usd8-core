// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SingleAssetCoverPoolTest} from "./SingleAssetCoverPool.t.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ZeroShareVault is ERC20, ERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 asset_) ERC20("Bad Vault", "BAD") ERC4626(asset_) {}

    function deposit(uint256 assets, address) public override returns (uint256 shares) {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        return 0;
    }
}

contract AuditFindingsTest is SingleAssetCoverPoolTest {
    function test_Audit_TinyRewardBecomesPermanentlyReservedDust() public {
        _stake(alice, 100e6);
        _notify(1);

        assertEq(pool.rewardRate(), 0, "sub-duration reward floors rate to zero");
        assertEq(pool.rewardReserve(), 1, "dust is nevertheless reserved");

        vm.warp(block.timestamp + pool.rewardsDuration() + 1);
        vm.prank(alice);
        assertEq(pool.claimReward(), 0, "dust never becomes claimable");

        vm.prank(admin);
        vm.expectRevert();
        pool.sweepToken(IERC20(address(usd8)), admin);
        assertEq(usd8.balanceOf(address(pool)), 1, "reserved dust is stranded");
    }
}

contract AuditStrategyTest is Test {
    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function test_Audit_ZeroShareDepositBurnsTreasuryReserve() public {
        MockERC20 template = new MockERC20("USDC", "USDC", 6);
        vm.etch(MAINNET_USDC, address(template).code);
        MockERC20 usdc = MockERC20(MAINNET_USDC);

        address treasury = address(0xBEEF);
        ZeroShareVault vault = new ZeroShareVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(treasury, vault);

        usdc.mint(address(strategy), 100e6);
        vm.prank(treasury);
        strategy.deploy(100e6);

        assertEq(usdc.balanceOf(address(strategy)), 0);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(vault.balanceOf(address(strategy)), 0, "adapter accepted zero shares");
        assertEq(strategy.totalAssets(), 0, "Treasury reserve instantly loses the deposit");
    }
}
