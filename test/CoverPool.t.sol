// SPDX-License-Identifier: MIT
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {IUsdOracle} from "../src/IUsdOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev USD-1e18 per token base unit. So 1 USDC ($1, 6 decimals)
///      -> pricePerBaseUnit = 1e18 / 1e6 = 1e12; lp1 ($1, 18 decimals)
///      -> pricePerBaseUnit = 1.
contract MockUsdOracle is IUsdOracle {
    uint256 public pricePerBaseUnit;

    constructor(uint256 _pricePerBaseUnit) {
        pricePerBaseUnit = _pricePerBaseUnit;
    }

    function setPrice(uint256 newPrice) external {
        pricePerBaseUnit = newPrice;
    }

    function getUsdValue(uint256 amount) external view override returns (uint256) {
        return amount * pricePerBaseUnit;
    }
}

contract CoverPoolTest is Test {
    MockERC20 usdc;
    MockERC20 dai;
    MockERC20 wbtc;
    MockERC20 usd8;
    MockERC20 lp1; // cover token 1
    MockERC20 lp2; // cover token 2
    CoverPool pool;

    address admin = address(0xA11CE);
    address alice = address(0xBEEF);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    uint256 signerPk = 0xA11CE5169;
    address signer;

    uint64 constant DURATION = 7 days;

    // EIP-712 plumbing — must match the contract.
    bytes32 constant CLAIM_TYPEHASH =
        keccak256("Claim(address user,address coverToken,uint128 coverTokenAmount,uint256 score,uint256 nonce)");

    MockUsdOracle usdcOracle;
    MockUsdOracle daiOracle;
    MockUsdOracle wbtcOracle;
    MockUsdOracle lp1Oracle;
    MockUsdOracle lp2Oracle;

    function setUp() public {
        signer = vm.addr(signerPk);

        usdc = new MockERC20("USDC", "USDC", 6);
        dai = new MockERC20("DAI", "DAI", 18);
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        usd8 = new MockERC20("USD8 mock", "USD8", 18);
        lp1 = new MockERC20("LP1", "LP1", 18);
        lp2 = new MockERC20("LP2", "LP2", 18);

        // 1 USDC = $1; 1 DAI = $1; 1 WBTC = $100k; 1 LP1 = $1; 1 LP2 = $1.
        usdcOracle = new MockUsdOracle(1e12); // 1e18 / 1e6 -> $1 per whole USDC
        daiOracle = new MockUsdOracle(1); // 1e18 / 1e18 -> $1 per whole DAI
        wbtcOracle = new MockUsdOracle(1e15); // 100_000 * 1e18 / 1e8 = 1e15 (i.e., $100k per BTC)
        lp1Oracle = new MockUsdOracle(1);
        lp2Oracle = new MockUsdOracle(1);

        pool = new CoverPool(IERC20(address(usd8)), admin, DURATION);
        vm.startPrank(admin);
        pool.addAsset(IERC20(address(usdc)), usdcOracle);
        pool.addAsset(IERC20(address(dai)), daiOracle);
        pool.addAsset(IERC20(address(wbtc)), wbtcOracle);
        pool.addCoverToken(IERC20(address(lp1)), lp1Oracle);
        pool.addCoverToken(IERC20(address(lp2)), lp2Oracle);
        pool.setClaimSigner(signer);
        vm.stopPrank();
    }

    // ────────────────────────── helpers ──────────────────────────

    function _stake(address who, MockERC20 token, uint256 amount) internal returns (uint256 sharesMinted) {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(pool), amount);
        sharesMinted = pool.stake(IERC20(address(token)), amount);
        vm.stopPrank();
    }

    function _notify(MockERC20 asset, uint256 amount) internal {
        usd8.mint(admin, amount);
        vm.startPrank(admin);
        usd8.approve(address(pool), amount);
        pool.notifyReward(IERC20(address(asset)), amount);
        vm.stopPrank();
    }

    function _domainSeparator() internal view returns (bytes32) {
        // OZ EIP712: hashed name + hashed version + chainId + verifyingContract.
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("USD8 CoverPool")),
                keccak256(bytes("1")),
                block.chainid,
                address(pool)
            )
        );
    }

    function _signClaim(address user, IERC20 coverToken, uint128 amount, uint256 score, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, user, address(coverToken), amount, score, nonce));
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _registerClaim(address user, MockERC20 coverToken, uint128 amount, uint256 score)
        internal
        returns (uint256 claimId)
    {
        coverToken.mint(user, amount);
        uint256 nonce = pool.claimNonces(user);
        bytes memory sig = _signClaim(user, IERC20(address(coverToken)), amount, score, nonce);
        vm.startPrank(user);
        coverToken.approve(address(pool), amount);
        claimId = pool.registerClaim(IERC20(address(coverToken)), amount, score, sig);
        vm.stopPrank();
    }

    function _completeUnstakeAfterCooldown(address who, MockERC20 asset, uint128 shares)
        internal
        returns (uint256 assetsOut)
    {
        vm.startPrank(who);
        pool.requestUnstake(IERC20(address(asset)), shares);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(who);
        assetsOut = pool.completeUnstake(IERC20(address(asset)));
    }

    // ════════════════════ Construction & basic config ════════════════════

    function test_ConstructorWiring() public view {
        assertEq(address(pool.rewardToken()), address(usd8));
        assertEq(pool.owner(), admin);
        assertEq(pool.rewardsDuration(), DURATION);
        assertEq(pool.claimSigner(), signer);
        assertEq(pool.assetListLength(), 3);
        assertEq(pool.coverTokenListLength(), 2);
        assertEq(pool.nextClaimId(), 1);
        assertEq(pool.nextIncidentId(), 1);
    }

    function test_ConstructorRejectsZeroRewardToken() public {
        vm.expectRevert(CoverPool.ZeroAddress.selector);
        new CoverPool(IERC20(address(0)), admin, DURATION);
    }

    function test_ConstructorRejectsZeroDuration() public {
        vm.expectRevert(CoverPool.InvalidRewardsDuration.selector);
        new CoverPool(IERC20(address(usd8)), admin, 0);
    }

    // ════════════════════ Asset management ════════════════════

    function test_AddAssetRejectsRewardToken() public {
        vm.prank(admin);
        vm.expectRevert(CoverPool.TokenConflict.selector);
        pool.addAsset(IERC20(address(usd8)), usdcOracle);
    }

    function test_AddAssetRejectsCoverToken() public {
        vm.prank(admin);
        vm.expectRevert(CoverPool.TokenConflict.selector);
        pool.addAsset(IERC20(address(lp1)), usdcOracle);
    }

    function test_AddAssetDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.AssetAlreadyApproved.selector, IERC20(address(usdc))));
        pool.addAsset(IERC20(address(usdc)), usdcOracle);
    }

    function test_AddAssetRejectsZeroOracle() public {
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.OracleUnset.selector, IERC20(address(weth))));
        pool.addAsset(IERC20(address(weth)), IUsdOracle(address(0)));
    }

    function test_RemoveAssetWithSharesReverts() public {
        _stake(alice, usdc, 100e6);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.AssetHasShares.selector, IERC20(address(usdc)), 100e6));
        pool.removeAsset(IERC20(address(usdc)));
    }

    function test_RemoveAssetClean() public {
        vm.prank(admin);
        pool.removeAsset(IERC20(address(wbtc)));
        assertEq(pool.assetListLength(), 2);
    }

    // ════════════════════ Cover token management ════════════════════

    function test_AddCoverTokenRejectsStakeAsset() public {
        vm.prank(admin);
        vm.expectRevert(CoverPool.TokenConflict.selector);
        pool.addCoverToken(IERC20(address(usdc)), lp1Oracle);
    }

    function test_AddCoverTokenRejectsRewardToken() public {
        vm.prank(admin);
        vm.expectRevert(CoverPool.TokenConflict.selector);
        pool.addCoverToken(IERC20(address(usd8)), lp1Oracle);
    }

    function test_AddCoverTokenDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.CoverTokenAlreadyApproved.selector, IERC20(address(lp1))));
        pool.addCoverToken(IERC20(address(lp1)), lp1Oracle);
    }

    function test_AddCoverTokenRejectsZeroOracle() public {
        MockERC20 lp3 = new MockERC20("LP3", "LP3", 18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.OracleUnset.selector, IERC20(address(lp3))));
        pool.addCoverToken(IERC20(address(lp3)), IUsdOracle(address(0)));
    }

    function test_AdminCanRemoveCoverToken() public {
        vm.prank(admin);
        pool.removeCoverToken(IERC20(address(lp2)));
        assertEq(pool.coverTokenListLength(), 1);
        assertFalse(pool.coverTokenApproved(IERC20(address(lp2))));
    }

    // ════════════════════ Share-based stake/unstake ════════════════════

    function test_FirstStakeIsOneToOne() public {
        uint256 shares = _stake(alice, usdc, 100e6);
        assertEq(shares, 100e6);
        assertEq(pool.totalShares(IERC20(address(usdc))), 100e6);
        assertEq(pool.totalAssets(IERC20(address(usdc))), 100e6);
        assertEq(pool.userShares(IERC20(address(usdc)), alice), 100e6);
    }

    function test_StakeAfterDonationDilutesNewShares() public {
        _stake(alice, usdc, 100e6);
        // Inflate the pool's totalAssets externally — simulated via mint
        // to pool? No — totalAssets is internal accounting. So instead
        // we test post-claim dilution via a claim payout in a separate
        // test; here just confirm 2nd stake is proportional.
        uint256 sharesB = _stake(bob, usdc, 50e6);
        assertEq(sharesB, 50e6);
        assertEq(pool.totalShares(IERC20(address(usdc))), 150e6);
    }

    function test_UnstakeRequestStartsCooldown() public {
        _stake(alice, usdc, 100e6);
        vm.prank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 100e6);
        (uint128 sh, uint64 reqAt) = pool.unstakeRequests(IERC20(address(usdc)), alice);
        assertEq(sh, 100e6);
        assertEq(reqAt, block.timestamp);
    }

    function test_UnstakeRequestDuplicateReverts() public {
        _stake(alice, usdc, 100e6);
        vm.startPrank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 50e6);
        vm.expectRevert(CoverPool.UnstakeRequestExists.selector);
        pool.requestUnstake(IERC20(address(usdc)), 50e6);
        vm.stopPrank();
    }

    function test_CompleteUnstakeBeforeCooldownReverts() public {
        _stake(alice, usdc, 100e6);
        vm.startPrank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 100e6);
        vm.expectRevert(CoverPool.CooldownNotElapsed.selector);
        pool.completeUnstake(IERC20(address(usdc)));
        vm.stopPrank();
    }

    function test_CompleteUnstakeAfterCooldownReturnsTokens() public {
        _stake(alice, usdc, 100e6);
        uint256 out = _completeUnstakeAfterCooldown(alice, usdc, 100e6);
        assertEq(out, 100e6);
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(pool.totalShares(IERC20(address(usdc))), 0);
    }

    function test_CancelUnstakeRequest() public {
        _stake(alice, usdc, 100e6);
        vm.startPrank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 100e6);
        pool.cancelUnstakeRequest(IERC20(address(usdc)));
        vm.stopPrank();
        (uint128 sh,) = pool.unstakeRequests(IERC20(address(usdc)), alice);
        assertEq(sh, 0);
    }

    function test_CompleteUnstakeBlockedByActiveIncident() public {
        _stake(alice, usdc, 100e6);
        _registerClaim(bob, lp1, 50e18, 1000);

        vm.prank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 100e6);
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(alice);
        vm.expectRevert(CoverPool.IncidentsActive.selector);
        pool.completeUnstake(IERC20(address(usdc)));
    }

    // ════════════════════ Rewards (preserved behavior) ════════════════════

    function test_NotifyRewardRequiresStakers() public {
        usd8.mint(admin, 100e18);
        vm.startPrank(admin);
        usd8.approve(address(pool), 100e18);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.NoStakersForAsset.selector, IERC20(address(usdc))));
        pool.notifyReward(IERC20(address(usdc)), 100e18);
        vm.stopPrank();
    }

    function test_RewardAccruesProRata() public {
        _stake(alice, usdc, 100e6);
        _stake(bob, usdc, 100e6);
        _notify(usdc, 70e18); // over 7d -> 10 USD8/day across 200 shares
        vm.warp(block.timestamp + DURATION);
        uint256 ea = pool.earned(IERC20(address(usdc)), alice);
        uint256 eb = pool.earned(IERC20(address(usdc)), bob);
        assertApproxEqAbs(ea, 35e18, 1e10);
        assertApproxEqAbs(eb, 35e18, 1e10);
    }

    function test_RewardDoesNotLeakAcrossAssets() public {
        _stake(alice, usdc, 100e6);
        _stake(bob, dai, 100e18);
        _notify(usdc, 70e18);
        vm.warp(block.timestamp + DURATION);
        assertGt(pool.earned(IERC20(address(usdc)), alice), 0);
        assertEq(pool.earned(IERC20(address(dai)), bob), 0);
    }

    function test_JITLatecomerOnlyGetsForwardSlice() public {
        _stake(alice, usdc, 100e6);
        _notify(usdc, 70e18);
        vm.warp(block.timestamp + DURATION / 2);
        _stake(bob, usdc, 100e6); // joins halfway
        vm.warp(block.timestamp + DURATION / 2);

        uint256 ea = pool.earned(IERC20(address(usdc)), alice);
        uint256 eb = pool.earned(IERC20(address(usdc)), bob);
        // Alice: half stream solo + 1/2 of remaining half.
        // Bob:   only 1/2 of remaining half.
        assertApproxEqAbs(ea, 70e18 / 2 + 70e18 / 4, 1e10);
        assertApproxEqAbs(eb, 70e18 / 4, 1e10);
    }

    // ════════════════════ Claim registration ════════════════════

    function test_RegisterClaimOpensIncident() public {
        _stake(alice, usdc, 100e6);
        uint256 claimId = _registerClaim(bob, lp1, 50e18, 1000);
        assertEq(claimId, 1);
        assertEq(pool.nextClaimId(), 2);
        assertEq(pool.openIncidentByToken(IERC20(address(lp1))), 1);
        // Cover token auto-delisted after incident open.
        assertFalse(pool.coverTokenApproved(IERC20(address(lp1))));
        assertEq(pool.coverTokenListLength(), 1);
    }

    function test_RegisterClaimReplayReverts() public {
        lp1.mint(bob, 50e18);
        bytes memory sig = _signClaim(bob, IERC20(address(lp1)), 50e18, 1000, 0);
        vm.startPrank(bob);
        lp1.approve(address(pool), 50e18);
        pool.registerClaim(IERC20(address(lp1)), 50e18, 1000, sig);
        vm.expectRevert(CoverPool.InvalidSignature.selector); // nonce bumped
        pool.registerClaim(IERC20(address(lp1)), 50e18, 1000, sig);
        vm.stopPrank();
    }

    function test_RegisterClaimWrongSignerReverts() public {
        lp1.mint(bob, 50e18);
        // sign with a different key.
        uint256 wrongPk = 0xDEAD;
        bytes32 structHash =
            keccak256(abi.encode(CLAIM_TYPEHASH, bob, address(lp1), uint128(50e18), uint256(1000), uint256(0)));
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.startPrank(bob);
        lp1.approve(address(pool), 50e18);
        vm.expectRevert(CoverPool.InvalidSignature.selector);
        pool.registerClaim(IERC20(address(lp1)), 50e18, 1000, sig);
        vm.stopPrank();
    }

    function test_SecondClaimSameTokenJoinsIncident() public {
        _stake(alice, usdc, 100e6);
        _registerClaim(bob, lp1, 50e18, 1000);
        _registerClaim(carol, lp1, 30e18, 500);
        (,,, uint256 totalScore, uint256 claimCount,,,) = pool.incidents(1);
        assertEq(totalScore, 1500);
        assertEq(claimCount, 2);
    }

    function test_ClaimAfterWindowReverts() public {
        _stake(alice, usdc, 100e6);
        _registerClaim(bob, lp1, 50e18, 1000);
        vm.warp(block.timestamp + 10 days + 1);

        lp1.mint(carol, 30e18);
        bytes memory sig = _signClaim(carol, IERC20(address(lp1)), 30e18, 500, 0);
        vm.startPrank(carol);
        lp1.approve(address(pool), 30e18);
        (,, uint64 wEnd,,,,,) = pool.incidents(1);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.ClaimWindowClosed.selector, IERC20(address(lp1)), wEnd));
        pool.registerClaim(IERC20(address(lp1)), 30e18, 500, sig);
        vm.stopPrank();
    }

    // ════════════════════ Cancel claim ════════════════════

    function test_CancelClaimBeforeSnapshotReturnsTokensAndAdjustsScore() public {
        _stake(alice, usdc, 100e6);
        _registerClaim(bob, lp1, 50e18, 1000);
        _registerClaim(carol, lp1, 30e18, 500);

        vm.prank(bob);
        pool.cancelClaim(1);
        assertEq(lp1.balanceOf(bob), 50e18);
        (,,, uint256 totalScore,, uint256 resolved,,) = pool.incidents(1);
        assertEq(totalScore, 500);
        assertEq(resolved, 1);
    }

    function test_CancelAfterFinalizeReverts() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18, 1000);
        vm.warp(block.timestamp + 10 days + 1);
        pool.snapshotIncident(1);
        vm.prank(bob);
        pool.finalizeClaim(cid);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.ClaimAlreadyResolved.selector, cid));
        pool.cancelClaim(cid);
    }

    function test_CancelByNonOwnerReverts() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18, 1000);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.UnauthorizedClaim.selector, cid));
        pool.cancelClaim(cid);
    }

    // ════════════════════ Snapshot & finalize ════════════════════

    function test_SnapshotBeforeWindowEndReverts() public {
        _stake(alice, usdc, 100e6);
        _registerClaim(bob, lp1, 50e18, 1000);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.WindowNotElapsed.selector, uint256(1)));
        pool.snapshotIncident(1);
    }

    function test_FinalizeSplitsAcrossAssetsProRata() public {
        // Pool: 100 USDC + 100 DAI = $200. Bob claims with 50e18 LP1 ($50
        // loss); 80% cap = $40. Sole claimant, raw share = $200, cap binds
        // -> payoutUsd = $40, split pro-rata: 20 USDC + 20 DAI.
        _stake(alice, usdc, 100e6);
        _stake(alice, dai, 100e18);
        uint256 cid = _registerClaim(bob, lp1, 50e18, 1000);
        vm.warp(block.timestamp + 10 days + 1);
        pool.snapshotIncident(1);

        vm.prank(bob);
        pool.finalizeClaim(cid);

        assertEq(usdc.balanceOf(bob), 20e6);
        assertEq(dai.balanceOf(bob), 20e18);
        assertEq(pool.totalAssets(IERC20(address(usdc))), 80e6);
        assertEq(pool.totalAssets(IERC20(address(dai))), 80e18);
    }

    function test_FinalizeCapDoesNotBindWhenRawShareSmaller() public {
        // Pool: 10 USDC = $10. Bob claims 50e18 LP1 ($50 loss); 80% cap =
        // $40. Sole claimant, raw share = $10 < cap -> payoutUsd = $10.
        // Bob drains the pool.
        _stake(alice, usdc, 10e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18, 1000);
        vm.warp(block.timestamp + 10 days + 1);
        pool.snapshotIncident(1);
        vm.prank(bob);
        pool.finalizeClaim(cid);
        assertEq(usdc.balanceOf(bob), 10e6);
        assertEq(pool.totalAssets(IERC20(address(usdc))), 0);
    }

    function test_FinalizeSplitsBetweenClaimantsByScore() public {
        // Pool: 300 USDC = $300. Each claim: 50e18 LP1 ($50 loss, cap $40).
        // Bob score 2000, carol score 1000, total 3000.
        // Bob raw share = 2000/3000 × $300 = $200; cap = $40 -> $40 USDC.
        // Carol raw share = 1000/3000 × $300 = $100; cap = $40 -> $40 USDC.
        _stake(alice, usdc, 300e6);
        uint256 cb = _registerClaim(bob, lp1, 50e18, 2000);
        uint256 cc = _registerClaim(carol, lp1, 50e18, 1000);

        vm.warp(block.timestamp + 10 days + 1);
        pool.snapshotIncident(1);
        vm.prank(bob);
        pool.finalizeClaim(cb);
        vm.prank(carol);
        pool.finalizeClaim(cc);

        assertEq(usdc.balanceOf(bob), 40e6);
        assertEq(usdc.balanceOf(carol), 40e6);
    }

    function test_FinalizeUncappedSplitsByScore() public {
        // Pool: 30 USDC = $30. Cap doesn't bind (loss $50 -> cap $40, but
        // raw share for each smaller than cap). Bob score 2000, carol 1000.
        // Bob: 2/3 × $30 = $20 = 20 USDC. Carol: 1/3 × $30 = $10 = 10 USDC.
        _stake(alice, usdc, 30e6);
        uint256 cb = _registerClaim(bob, lp1, 50e18, 2000);
        uint256 cc = _registerClaim(carol, lp1, 50e18, 1000);

        vm.warp(block.timestamp + 10 days + 1);
        pool.snapshotIncident(1);
        vm.prank(bob);
        pool.finalizeClaim(cb);
        vm.prank(carol);
        pool.finalizeClaim(cc);

        assertEq(usdc.balanceOf(bob), 20e6);
        assertEq(usdc.balanceOf(carol), 10e6);
    }

    function test_FinalizedClaimForfeitsCoverTokens() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18, 1000);
        vm.warp(block.timestamp + 10 days + 1);
        pool.snapshotIncident(1);
        vm.prank(bob);
        pool.finalizeClaim(cid);

        assertEq(lp1.balanceOf(bob), 0);
        assertEq(pool.forfeitedCoverTokens(IERC20(address(lp1))), 50e18);
    }

    function test_AdminSweepsForfeitedCoverTokens() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18, 1000);
        vm.warp(block.timestamp + 10 days + 1);
        pool.snapshotIncident(1);
        vm.prank(bob);
        pool.finalizeClaim(cid);

        vm.prank(admin);
        pool.sweepCoverToken(IERC20(address(lp1)), admin, 50e18);
        assertEq(lp1.balanceOf(admin), 50e18);
        assertEq(pool.forfeitedCoverTokens(IERC20(address(lp1))), 0);
    }

    function test_SweepBeyondForfeitedReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.InsufficientForfeited.selector, 1, 0));
        pool.sweepCoverToken(IERC20(address(lp1)), admin, 1);
    }

    // ════════════════════ Loss socialization ════════════════════

    function test_LossSocializedAcrossStakers() public {
        // Alice and Bob each stake 100 USDC -> pool = 200 USDC = $200.
        // Carol claim 50e18 LP1 ($50 loss, cap $40). Sole claimant, raw
        // share = $200, cap binds -> Carol gets $40 = 40 USDC.
        // Pool after: 160 USDC, totalShares = 200e6.
        // Alice unstakes her 100 shares -> 100/200 × 160 = 80 USDC.
        // Bob unstakes his 100 shares -> same 80 USDC. Equal loss share.
        _stake(alice, usdc, 100e6);
        _stake(bob, usdc, 100e6);
        uint256 cid = _registerClaim(carol, lp1, 50e18, 1000);
        vm.warp(block.timestamp + 10 days + 1);
        pool.snapshotIncident(1);
        vm.prank(carol);
        pool.finalizeClaim(cid);
        assertEq(usdc.balanceOf(carol), 40e6);

        uint256 outA = _completeUnstakeAfterCooldown(alice, usdc, 100e6);
        uint256 outB = _completeUnstakeAfterCooldown(bob, usdc, 100e6);
        assertEq(outA, 80e6);
        assertEq(outB, 80e6);
    }

    function test_StakeAfterClaimGetsMoreSharesPerUnit() public {
        // Pool: 100 USDC, totalShares 100e6. Bob takes $40 (cap-bound).
        // Pool after: 60 USDC, totalShares 100e6. pricePerShare = 0.6.
        // Carol stakes 30 USDC -> 30e6 × 100e6 / 60e6 = 50e6 shares.
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18, 1000);
        vm.warp(block.timestamp + 10 days + 1);
        pool.snapshotIncident(1);
        vm.prank(bob);
        pool.finalizeClaim(cid);

        uint256 carolShares = _stake(carol, usdc, 30e6);
        assertEq(carolShares, 50e6);
        assertEq(pool.totalShares(IERC20(address(usdc))), 150e6);
        assertEq(pool.totalAssets(IERC20(address(usdc))), 90e6);
    }

    // ════════════════════ Serial finalization ════════════════════

    function test_SecondIncidentBlockedUntilFirstResolves() public {
        // Pool: 200 USDC = $200. Bob's lp1 claim: 50e18 ($50 loss, cap $40).
        // Carol's lp2 claim: 30e18 ($30 loss, cap $24).
        _stake(alice, usdc, 200e6);
        uint256 c1 = _registerClaim(bob, lp1, 50e18, 1000);
        uint256 c2 = _registerClaim(carol, lp2, 30e18, 1000);

        vm.warp(block.timestamp + 10 days + 1);

        // Snapshot must be for queue head first.
        vm.expectRevert(abi.encodeWithSelector(CoverPool.NotQueueHead.selector, uint256(2)));
        pool.snapshotIncident(2);

        pool.snapshotIncident(1);
        vm.prank(bob);
        pool.finalizeClaim(c1);
        assertEq(usdc.balanceOf(bob), 40e6); // cap-bound

        // Pool now has 160 USDC = $160. Carol cap = $24.
        pool.snapshotIncident(2);
        vm.prank(carol);
        pool.finalizeClaim(c2);
        assertEq(usdc.balanceOf(carol), 24e6); // cap-bound
    }

    function test_QueueAutoAdvancesAfterResolution() public {
        _stake(alice, usdc, 100e6);
        uint256 c1 = _registerClaim(bob, lp1, 50e18, 1000);
        vm.warp(block.timestamp + 10 days + 1);
        pool.snapshotIncident(1);
        vm.prank(bob);
        pool.finalizeClaim(c1);

        assertEq(pool.queueHead(), 1);
        assertFalse(pool.hasActiveIncidents());
    }

    // ════════════════════ Ownership ════════════════════

    function test_RenounceOwnershipDisabled() public {
        vm.prank(admin);
        vm.expectRevert(CoverPool.RenounceOwnershipDisabled.selector);
        pool.renounceOwnership();
    }
}
