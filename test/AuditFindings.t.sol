// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SingleAssetCoverPoolTest} from "./SingleAssetCoverPool.t.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {RegistryManaged} from "../src/RegistryManaged.sol";
import {Registry} from "../src/Registry.sol";
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

/// @dev Vault whose share price is a fixed, high rate (1 share = RATE asset
///      base-units), like an Aave stataUSDC wrapper after years of accrual. A
///      deposit rounds down by up to RATE base-units — far more than a fixed
///      2-wei slack — so it exercises the L-B granularity-scaled tolerance.
contract AppreciatedVault is ERC20, ERC4626 {
    using SafeERC20 for IERC20;

    uint256 public constant RATE = 1000; // asset base-units per share base-unit

    constructor(IERC20 asset_) ERC20("Appreciated", "APR") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        shares = assets / RATE; // floor: a non-multiple deposit loses up to RATE-1 of value
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function convertToAssets(uint256 shares) public pure override returns (uint256) {
        return shares * RATE;
    }
}

/// @dev Vault that skims a 10% deposit fee OUT of the vault: the depositor's
///      position is worth materially less than the assets put in — nonzero
///      shares, short value (M-02).
contract FeeSkimVault is ERC20, ERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 asset_) ERC20("Fee Vault", "FEE") ERC4626(asset_) {}

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        shares = super.deposit(assets, receiver);
        IERC20(asset()).safeTransfer(address(0xFEE), assets / 10); // fee leaves the vault
    }
}

/// @dev Insured token that probes the pool-freeze state when DefiInsurance refunds
///      it (the over-escrow transfer in finalizeClaim) — the H-01 callback surface.
contract FreezeProbeToken is ERC20 {
    Registry public reg;
    address public defi;
    bool public probed;
    bool public frozenDuringRefund;

    constructor(Registry _reg) ERC20("Probe", "PRB") {
        reg = _reg;
    }

    function setDefi(address d) external {
        defi = d;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == defi && defi != address(0)) {
            frozenDuringRefund = reg.payoutIncidentActive();
            probed = true;
        }
        super._update(from, to, value);
    }
}

contract AuditFindingsTest is SingleAssetCoverPoolTest {
    function test_Audit_LastClaimStaysFrozenThroughRefund() public {
        // H-01: finalizing the FINAL unresolved claim must keep the incident active
        // (pool frozen) through the over-escrow refund, so a callback in the insured
        // token can't re-enter completeRedeem and exit at the pre-loss share price.
        FreezeProbeToken tok = new FreezeProbeToken(registry);
        tok.setDefi(address(defi));
        vm.prank(admin);
        defi.addInsuredToken(IERC20(address(tok)), 8000, MIN_CLAIM, FEED, address(0), "");

        _stake(alice, 100e6); // pool capital to pay from

        uint128 escrow = 100e18;
        tok.mint(bob, escrow);
        vm.prank(bob);
        tok.approve(address(defi), escrow);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(tok)), uint64(block.number - 1));
        vm.prank(bob);
        uint256 claimId = defi.joinClaim(IERC20(address(tok)), escrow, 0, 0, 0, "");

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(20e6);
        uint256 eligible = 60e18; // < escrow → 40e18 refund fires the probe
        _settle(1, _leafSpent(1, claimId, bob, amounts, 0, eligible));
        vm.warp(block.timestamp + defi.DISPUTE_PERIOD() + 1);

        vm.prank(bob);
        defi.finalizeClaim(amounts, 0, eligible, new bytes32[](0));

        assertTrue(tok.probed(), "refund fired the probe");
        assertTrue(tok.frozenDuringRefund(), "H-01: incident still frozen during the last claim's refund");
        assertEq(defi.activeIncidentId(), 0, "incident retired only after finalize completes");
    }

    function test_Audit_SubDurationRewardRejectedInsteadOfStranding() public {
        _stake(alice, 100e6);

        // L-01: a distribution too small to stream (total/duration floors to zero)
        // is rejected outright — nothing enters rewardReserve to strand forever.
        vm.startPrank(admin);
        usd8.mint(admin, 1);
        usd8.approve(address(pool), 1);
        vm.expectRevert(abi.encodeWithSelector(SingleAssetCoverPool.RewardRateZero.selector, 1, pool.rewardsDuration()));
        pool.receiveProfitDistribution(1);
        vm.stopPrank();
        assertEq(pool.rewardReserve(), 0, "nothing reserved");
    }

    /// @dev L-A: dispute may only target a STANDING SETTLED root. A pre-settlement
    ///      dispute reverts NoStandingRoot, so it can't stamp disputedAt early (which
    ///      would let CORRECTION_WINDOW auto-void a valid incident) or move the
    ///      incident to Disputed while its claim window is still open. The
    ///      pre-settlement emergency stop is closeIncident.
    function test_Audit_DisputeRequiresStandingRoot() public {
        _registerClaim(bob, lp1, 50e18);
        (, uint64 wEnd,,,,,,,,) = defi.incidents(1);
        assertLe(block.timestamp, wEnd, "still inside the claim window, no root settled");

        // No standing root → dispute rejected.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NoStandingRoot.selector, uint256(1)));
        defi.disputeIncident();

        // closeIncident IS the pre-settlement stop: it voids and unfreezes.
        vm.prank(admin);
        defi.closeIncident();
        assertEq(defi.activeIncidentId(), 0, "closed incident is no longer active");
    }

    /// @dev L-A: once settled, dispute works normally (root standing, within the
    ///      DISPUTE window) — the standing-root gate doesn't break the real flow.
    function test_Audit_DisputeWorksOnceSettled() public {
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1); // claim window closed
        _settle(1, _leaf(1, claimId, bob, _amounts(0)));

        vm.prank(admin);
        defi.disputeIncident();
        (,, bytes32 root,,,,, DefiInsurance.Status status,,) = defi.incidents(1);
        assertEq(root, bytes32(0), "bad root cleared");
        assertTrue(status == DefiInsurance.Status.Disputed, "status Disputed");
    }

    /// @dev Beta mode: admin corrects a bad TEE root in ONE call (no separate
    ///      dispute, no timelock); the corrected root runs its own fresh DISPUTE
    ///      window, then finalizes and pays the corrected amount.
    function test_Audit_AdminCorrectSettlementInBeta() public {
        assertTrue(registry.betaMode(), "launches in beta");
        _stake(alice, 100e6); // underwrite so payouts have capital
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, claimId, bob, _amounts(50e6))); // bad root (overpays)

        // Admin fixes it directly, in beta — one call. Precompute leaf/pp (their
        // external reads would otherwise consume the prank).
        uint256[] memory good = _amounts(20e6);
        bytes32 corrRoot = _leaf(1, claimId, bob, good);
        uint256[] memory pp = _pp();
        vm.prank(admin);
        defi.adminCorrectSettlement(corrRoot, pp);

        // Fresh DISPUTE window on the corrected root, then pay the corrected amount.
        vm.warp(block.timestamp + defi.DISPUTE_PERIOD() + 1);
        _finalize(claimId, good, 0);
        assertEq(usdc.balanceOf(bob), 20e6, "paid the admin-corrected amount");
    }

    /// @dev Once the timelock ends beta, the admin shortcut is gone — one-way.
    function test_Audit_AdminCorrectSettlementRejectedAfterBeta() public {
        uint256 claimId = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, claimId, bob, _amounts(0)));

        vm.prank(admin); // admin == timelock in this harness
        registry.endBetaMode();
        assertFalse(registry.betaMode());

        bytes32 corrRoot = _leaf(1, claimId, bob, _amounts(0));
        uint256[] memory pp = _pp();
        vm.prank(admin);
        vm.expectRevert(RegistryManaged.NotBetaMode.selector);
        defi.adminCorrectSettlement(corrRoot, pp);
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
        bytes memory sig = _teeSign(1, root, pp, TEST_SETTLEMENT_INPUT_HASH); // before expectRevert: helper reads incidents
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.settleIncident(1, root, pp, TEST_CONFIG_HASH, TEST_SETTLEMENT_INPUT_HASH, sig);
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

    /// @dev Async ERC-4626 conformance (audit test gap 4 / M-07): redeem is the
    ///      single exit door — redeem(maxRedeem) succeeds exactly, after transfers
    ///      of the excess and after a payout loss. The asset door is disabled
    ///      outright: withdraw() always reverts and maxWithdraw() is always 0, so
    ///      no advertised amount can ever revert.
    function test_Audit_RedeemMaxRedeemConformsAfterTransferAndLoss() public {
        uint256 shares = _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestRedeem(shares / 2);

        // Asset-denominated exit is unsupported, in every state.
        assertEq(pool.maxWithdraw(alice), 0);
        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.WithdrawNotSupported.selector);
        pool.withdraw(1e6, alice, alice);

        // Not matured: the share door advertises 0 too.
        assertEq(pool.maxRedeem(alice), 0);

        // Transfer the unlocked excess away, mature the request: maxRedeem
        // advertises exactly the request, never more than the remaining balance
        // (M-03 lock).
        vm.startPrank(alice);
        pool.transfer(bob, shares - shares / 2);
        vm.warp(block.timestamp + pool.UNSTAKE_COOLDOWN());
        assertEq(pool.maxRedeem(alice), shares / 2);
        assertLe(pool.maxRedeem(alice), pool.balanceOf(alice));

        // A payout loss drops the share price below 1.
        vm.stopPrank();
        vm.prank(address(defi));
        pool.payClaim(carol, 30e6);

        // redeem(maxRedeem) completes exactly at the advertised preview even at a
        // fractional share price.
        uint256 redeemable = pool.maxRedeem(alice); // before prank: view call would consume it
        uint256 expectedAssets = pool.previewRedeem(redeemable);
        vm.prank(alice);
        uint256 got = pool.redeem(redeemable, alice, alice);
        assertEq(got, expectedAssets);
        assertEq(usdc.balanceOf(alice), expectedAssets);

        // Consumed request: the share door returns to 0.
        assertEq(pool.maxRedeem(alice), 0);

        // An expired request advertises 0 again (bob never completes his).
        vm.prank(bob);
        pool.requestRedeem(shares - shares / 2);
        vm.warp(block.timestamp + pool.UNSTAKE_COOLDOWN() + pool.UNSTAKE_WINDOW() + 1);
        assertEq(pool.maxRedeem(bob), 0);
    }

    function test_Audit_RewardsDurationBounded() public {
        // L-F: 0 and anything past the 1-year cap are rejected; the cap itself is ok.
        uint64 maxDur = pool.MAX_REWARDS_DURATION(); // read before prank/expectRevert
        vm.startPrank(admin);
        vm.expectRevert(SingleAssetCoverPool.InvalidRewardsDuration.selector);
        pool.setRewardsDuration(0);
        vm.expectRevert(SingleAssetCoverPool.InvalidRewardsDuration.selector);
        pool.setRewardsDuration(maxDur + 1);
        pool.setRewardsDuration(maxDur); // exactly the cap is fine
        vm.stopPrank();
        assertEq(pool.rewardsDuration(), maxDur);
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

    function test_Audit_AppreciatedVaultDepositDoesNotFalselyRevert() public {
        MockERC20 template = new MockERC20("USDC", "USDC", 6);
        vm.etch(MAINNET_USDC, address(template).code);
        MockERC20 usdc = MockERC20(MAINNET_USDC);

        address treasury = address(0xBEEF);
        AppreciatedVault vault = new AppreciatedVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(treasury, vault);

        // Deposit a non-multiple of RATE (1000): shares floor loses 7 base-units of
        // value — more than the old fixed 2-wei tolerance would allow, so this would
        // have wrongly reverted. The L-B granularity-scaled tolerance accepts it.
        uint256 amount = 100_000_000 + 7;
        usdc.mint(address(strategy), amount);
        vm.prank(treasury);
        strategy.deploy(amount); // must NOT revert
        assertEq(strategy.totalAssets(), 100_000_000, "position value = floor(amount/RATE)*RATE");
    }

    function test_Audit_ValueShortDepositReverts() public {
        MockERC20 template = new MockERC20("USDC", "USDC", 6);
        vm.etch(MAINNET_USDC, address(template).code);
        MockERC20 usdc = MockERC20(MAINNET_USDC);

        address treasury = address(0xBEEF);
        FeeSkimVault vault = new FeeSkimVault(IERC20(MAINNET_USDC));
        ERC4626Strategy strategy = new ERC4626Strategy(treasury, vault);

        // M-02: nonzero shares whose value is materially short of the deposit
        // (fee-skimming / donation-manipulated vault) must also revert.
        usdc.mint(address(strategy), 100e6);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Strategy.DepositValueShort.selector, 100e6, 90e6));
        strategy.deploy(100e6);
    }
}
