// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SingleAssetCoverPoolTest} from "./SingleAssetCoverPool.t.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ZeroShareVault is ERC20, ERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 asset_) ERC20("Bad Vault", "BAD") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function deposit(uint256 assets, address) public override returns (uint256 shares) {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        return 0;
    }
}

contract AuditFindingsTest is SingleAssetCoverPoolTest {
    function test_Audit_SubDurationRewardRejectedInsteadOfStranding() public {
        _stake(alice, 100e6);

        // L-01: a distribution too small to stream (total/duration floors to zero)
        // is rejected outright — nothing enters rewardReserve to strand forever.
        vm.startPrank(admin);
        usd8.mint(admin, 1);
        usd8.approve(address(pool), 1);
        vm.expectRevert(
            abi.encodeWithSelector(SingleAssetCoverPool.RewardRateZero.selector, 1, pool.rewardsDuration())
        );
        pool.receiveProfitDistribution(1);
        vm.stopPrank();
        assertEq(pool.rewardReserve(), 0, "nothing reserved");
    }

    function test_Audit_CorrectionCannotCommitRootBeforeClaimWindowEnds() public {
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        uint256[] memory amounts = _amounts(0);
        bytes32 root = _leaf(1, claimId, bob, amounts);

        // Disputing mid-claim-window is still allowed (a pure defensive halt), but…
        vm.prank(admin);
        defi.disputeIncident();
        uint256[] memory poolPayouts = _pp();

        // …the corrected (payable) root cannot be committed until the claim set is
        // frozen (H-03). Without this guard the root could finalize while claims are
        // still joining/cancelling.
        (, uint64 wEnd,,,,,,,,) = defi.incidents(1);
        assertLe(block.timestamp, wEnd, "still inside the claim window");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowStillOpen.selector, uint256(1)));
        defi.correctSettlement(root, poolPayouts);
    }

    /// @dev Full claim/settle/dispute/correct/finalize state machine in phase order
    ///      (audit test gap 2): every out-of-phase action reverts at each stage, then
    ///      the in-phase action advances the machine.
    function test_Audit_PhaseOrderStateMachine() public {
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        uint256[] memory amounts = _amounts(0);
        bytes32 root = _leaf(1, claimId, bob, amounts);
        uint256[] memory pp = _pp();

        // CLAIM phase: settle and finalize are both out of phase.
        bytes memory sig = _teeSign(1, root, pp); // before expectRevert: helper reads defi.incidents()
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.settleIncident(1, root, pp, TEST_CONFIG_HASH, sig);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(amounts, 0, 50e18, new bytes32[](0));

        // Window closes: join and cancel are now out of phase.
        (, uint64 wEnd,,,,,,,,) = defi.incidents(1);
        vm.warp(wEnd + 1);
        lp1.mint(carol, 10e18);
        vm.startPrank(carol);
        lp1.approve(address(defi), 10e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, lp1, wEnd));
        defi.joinClaim(IERC20(address(lp1)), 10e18, 0, 0, 0, "");
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, lp1, wEnd));
        defi.cancelClaim();

        // SETTLE phase: root lands; finalize still gated by the DISPUTE period.
        _settle(1, root);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(amounts, 0, 50e18, new bytes32[](0));

        // Dispute clears the root; correction (post-window, allowed) restarts a
        // FRESH dispute clock, so finalize is gated again…
        vm.prank(admin);
        defi.disputeIncident();
        vm.prank(admin);
        defi.correctSettlement(root, pp);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(amounts, 0, 50e18, new bytes32[](0));

        // …until the corrected root's DISPUTE period passes; then finalize pays and,
        // as the last claim, retires the incident.
        vm.warp(block.timestamp + defi.DISPUTE_PERIOD() + 1);
        _finalize(claimId, amounts, 0);
        assertEq(defi.activeIncidentId(), 0);
    }

    /// @dev Async ERC-4626 conformance (audit test gap 4): maxRedeem/maxWithdraw
    ///      advertise 0 outside the window, and redeem(maxRedeem) — the supported
    ///      exit — succeeds exactly, after transfers of the excess and after a
    ///      payout loss. (withdraw(maxWithdraw) may revert on ceil rounding after a
    ///      loss — accepted M-07 residual; redeem is the conformant path.)
    function test_Audit_RedeemMaxRedeemConformsAfterTransferAndLoss() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares / 2);

        // Not matured: both views advertise 0 (and redeem(0)>0 impossible).
        assertEq(pool.maxRedeem(alice), 0);
        assertEq(pool.maxWithdraw(alice), 0);

        // Transfer the unlocked excess away, mature the request: views advertise
        // exactly the request, never more than the remaining balance (M-03 lock).
        vm.startPrank(alice);
        pool.transfer(bob, shares - shares / 2);
        vm.warp(block.timestamp + pool.UNSTAKE_COOLDOWN());
        assertEq(pool.maxRedeem(alice), shares / 2);
        assertLe(pool.maxRedeem(alice), pool.balanceOf(alice));

        // A payout loss drops the share price below 1.
        vm.stopPrank();
        vm.prank(address(defi));
        pool.payClaim(carol, 30e6);

        // redeem(maxRedeem) completes exactly at the advertised preview.
        uint256 redeemable = pool.maxRedeem(alice); // before prank: view call would consume it
        uint256 expectedAssets = pool.previewRedeem(redeemable);
        assertEq(pool.maxWithdraw(alice), expectedAssets);
        vm.prank(alice);
        uint256 got = pool.redeem(redeemable, alice, alice);
        assertEq(got, expectedAssets);
        assertEq(usdc.balanceOf(alice), expectedAssets);

        // Consumed request: views return to 0.
        assertEq(pool.maxRedeem(alice), 0);
        assertEq(pool.maxWithdraw(alice), 0);

        // An expired request advertises 0 again (bob never completes his).
        vm.prank(bob);
        pool.requestRedeem(shares - shares / 2);
        vm.warp(block.timestamp + pool.UNSTAKE_COOLDOWN() + pool.UNSTAKE_WINDOW() + 1);
        assertEq(pool.maxRedeem(bob), 0);
        assertEq(pool.maxWithdraw(bob), 0);
    }

    function test_Audit_RequestedSharesAreLockedDuringCooldown() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares / 2);

        // M-03: shares backing a live request can't leave; only the excess can.
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(SingleAssetCoverPool.SharesLockedByRequest.selector, shares / 2));
        pool.transfer(bob, shares / 2 + 1);
        pool.transfer(bob, shares / 2); // exactly the unlocked excess is fine
        vm.stopPrank();

        // Cancel unlocks.
        vm.startPrank(alice);
        pool.cancelRedeemRequest();
        pool.transfer(bob, shares / 2);
        vm.stopPrank();
        assertEq(pool.balanceOf(alice), 0);
    }

    function test_Audit_RequestLockLiftsOnExpiryAndRedeemStillWorks() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares);

        // Locked through cooldown + window…
        vm.warp(block.timestamp + pool.UNSTAKE_COOLDOWN());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SingleAssetCoverPool.SharesLockedByRequest.selector, shares));
        pool.transfer(bob, 1);
        // …and the matured redeem itself passes (request deleted before the burn).
        vm.prank(alice);
        pool.completeRedeem();
        assertEq(pool.balanceOf(alice), 0);

        // Expired request no longer locks.
        uint256 shares2 = _stake(carol, 50e6);
        vm.prank(carol);
        pool.requestRedeem(shares2);
        vm.warp(block.timestamp + pool.UNSTAKE_COOLDOWN() + pool.UNSTAKE_WINDOW() + 1);
        vm.prank(carol);
        pool.transfer(bob, shares2);
        assertEq(pool.balanceOf(bob), shares2);
    }

    function test_Audit_FirstStakerAfterLongEmptyGapEarnsDeferredRewardsOverRemainingDuration() public {
        vm.prank(admin);
        pool.setRewardsDuration(30 days);
        _stake(alice, 100e6);
        _notify(70e18);

        uint256 shares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestRedeem(shares);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        pool.completeRedeem();
        assertEq(pool.totalSupply(), 0);

        vm.warp(block.timestamp + 60 days);
        _stake(carol, 1); // first new stake after stale finish
        vm.prank(carol);
        assertEq(pool.claimReward(), 0, "M-01: nothing to harvest instantly");

        // The ~23 days of unstreamed rewards (70e18 x 23/30) rebased to start at the
        // new stake resume streaming over their full remaining duration.
        vm.warp(block.timestamp + 23 days);
        vm.prank(carol);
        uint256 streamed = pool.claimReward();
        assertApproxEqAbs(streamed, uint256(70e18) * 23 / 30, 1e6, "deferred remainder streams over 23 days");
    }
}

contract AuditStrategyTest is Test {
    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function test_Audit_ZeroShareDepositReverts() public {
        MockERC20 template = new MockERC20("USDC", "USDC", 6);
        vm.etch(MAINNET_USDC, address(template).code);
        MockERC20 usdc = MockERC20(MAINNET_USDC);

        address treasury = address(0xBEEF);
        ZeroShareVault vault = new ZeroShareVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(treasury, vault);

        // M-02: a vault that banks the USDC but mints zero shares must revert the
        // deploy — the reserve loss never commits.
        usdc.mint(address(strategy), 100e6);
        vm.prank(treasury);
        vm.expectRevert(ERC4626Strategy.ZeroSharesMinted.selector);
        strategy.deploy(100e6);
    }
}
