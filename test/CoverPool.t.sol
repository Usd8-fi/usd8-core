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
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {DefiInsurance, ICoverPool} from "../src/DefiInsurance.sol";
import {USD8} from "../src/USD8.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";

contract CoverPoolTest is Test {
    MockERC20 usdc;
    MockERC20 dai;
    MockERC20 wbtc;
    USD8 usd8; // real USD8: reward token AND insurance-score spend ledger
    MockERC20 lp1; // insured token 1
    MockERC20 lp2; // insured token 2
    MockERC1155 booster;
    CoverPool pool;
    DefiInsurance defi;

    address admin = address(0xA11CE);
    address alice = address(0xBEEF);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    uint64 constant DURATION = 7 days;
    address constant FEED = address(0xFEED); // dummy USD feed (off-chain only, unused on-chain)

    function setUp() public {
        vm.roll(1000); // so openClaimIncident's referenceBlock (block.number - 1) is a valid past block
        usdc = new MockERC20("USDC", "USDC", 6);
        dai = new MockERC20("DAI", "DAI", 18);
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        USD8 usd8Impl = new USD8();
        usd8 = USD8(address(new ERC1967Proxy(address(usd8Impl), abi.encodeCall(USD8.initialize, (admin, admin)))));
        lp1 = new MockERC20("LP1", "LP1", 18);
        lp2 = new MockERC20("LP2", "LP2", 18);
        booster = new MockERC1155();

        // No oracles anywhere: all pricing happens off-chain; the admin submits
        // the settlement root. Deployed behind a UUPS proxy; admin doubles as
        // timelock in tests.
        pool = _deployPool(IERC20(address(usd8)), admin, admin, address(booster));
        defi = _deployDefi(ICoverPool(address(pool)), admin, admin);
        vm.startPrank(admin);
        pool.setPayoutModule(address(defi), true);
        pool.addCoverPoolAsset(IERC20(address(usdc)), FEED, 0);
        pool.addCoverPoolAsset(IERC20(address(dai)), FEED, 0);
        pool.addCoverPoolAsset(IERC20(address(wbtc)), FEED, 0);
        defi.addInsuredToken(IERC20(address(lp1)), 8000, FEED, address(0), "");
        defi.addInsuredToken(IERC20(address(lp2)), 8000, FEED, address(0), "");
        vm.stopPrank();
    }

    // ────────────────────────── helpers ──────────────────────────

    /// @dev Deploy a CoverPool implementation behind a UUPS ERC1967 proxy,
    ///      wiring the booster NFT at init. Reward duration is fixed at 7 days.
    function _deployPool(IERC20 reward, address timelock_, address admin_, address booster_)
        internal
        returns (CoverPool)
    {
        CoverPool impl = new CoverPool();
        bytes memory initData = abi.encodeCall(CoverPool.initialize, (reward, timelock_, admin_, booster_));
        return CoverPool(address(new ERC1967Proxy(address(impl), initData)));
    }

    function _deployDefi(ICoverPool pool_, address timelock_, address admin_) internal returns (DefiInsurance) {
        return new DefiInsurance(pool_, timelock_, admin_);
    }

    function _stake(address who, MockERC20 token, uint256 amount) internal returns (uint256 sharesMinted) {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(pool), amount);
        sharesMinted = pool.stake(IERC20(address(token)), amount);
        vm.stopPrank();
    }

    /// @dev Fund rewards for a single `asset`: give it all the profit weight and
    ///      distribute `amount` (admin acts as the Treasury donor). With every
    ///      other asset's weight at 0, the whole distribution streams to `asset`.
    function _notify(MockERC20 asset, uint256 amount) internal {
        vm.startPrank(admin);
        pool.setCoverPoolAssetWeight(IERC20(address(asset)), 1);
        usd8.mint(admin, amount);
        usd8.approve(address(pool), amount);
        pool.receiveProfitDistribution(amount);
        vm.stopPrank();
    }

    /// @dev Admin opens an incident on the token if none is joinable, then the
    ///      user joins it. Keeps call sites simple.
    function _registerClaim(address user, MockERC20 insuredToken, uint128 amount) internal returns (uint256 claimId) {
        insuredToken.mint(user, amount);
        vm.prank(user);
        insuredToken.approve(address(defi), amount);

        if (!_hasJoinableIncident(address(insuredToken))) {
            vm.prank(admin);
            defi.openClaimIncident(IERC20(address(insuredToken)), uint64(block.number - 1));
        }
        vm.prank(user);
        claimId = defi.joinClaim(IERC20(address(insuredToken)), amount, 0, new uint256[](0), new uint256[](0));
    }

    /// @dev True if the in-flight incident covers `token` and its claim
    ///      window is still open (i.e. a claim can join without opening).
    function _hasJoinableIncident(address token) internal view returns (bool) {
        uint256 active = defi.activeIncidentId();
        if (active == 0) return false;
        (IERC20 tok, uint64 wEnd,,,,,,) = defi.incidents(active);
        return address(tok) == token && block.timestamp <= wEnd;
    }

    /// @dev OZ double-hashed leaf over (incidentId, claimId, user, amounts,
    ///      scoreSpent). `_leaf` is the scoreSpent=0 case; `_leafSpent` sets it.
    function _leaf(uint256 incidentId, uint256 claimId, address user, uint256[] memory amounts)
        internal
        pure
        returns (bytes32)
    {
        return _leafSpent(incidentId, claimId, user, amounts, 0);
    }

    function _leafSpent(uint256 incidentId, uint256 claimId, address user, uint256[] memory amounts, uint256 scoreSpent)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(incidentId, claimId, user, amounts, scoreSpent))));
    }

    /// @dev OZ MerkleProof sorted-pair hash.
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Admin submits the settlement root for `incidentId` (caller must
    ///      have warped past the claim window first).
    function _settle(uint256 incidentId, bytes32 root) internal {
        vm.prank(admin);
        defi.settleIncident(incidentId, root);
    }

    /// @dev Payout row for the 3-asset setup [usdc, dai, wbtc].
    function _amounts(uint256 usdcAmt, uint256 daiAmt, uint256 wbtcAmt) internal pure returns (uint256[] memory a) {
        a = new uint256[](3);
        a[0] = usdcAmt;
        a[1] = daiAmt;
        a[2] = wbtcAmt;
    }

    function _completeUnstakeAfterCooldown(address who, MockERC20 asset, uint128 shares)
        internal
        returns (uint256 assetsOut)
    {
        vm.startPrank(who);
        pool.requestUnstake(IERC20(address(asset)), shares);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(who);
        assetsOut = pool.completeUnstake(IERC20(address(asset)));
    }

    // ════════════════════ Construction & basic config ════════════════════

    function test_ConstructorWiring() public view {
        assertEq(address(pool.usd8()), address(usd8));
        assertEq(pool.timelock(), admin);
        assertEq(pool.admin(), admin);
        assertEq(pool.rewardsDuration(), DURATION);
        assertEq(pool.coverPoolAssetListLength(), 3);
        assertEq(defi.insuredTokenListLength(), 2);
        assertEq(defi.nextClaimId(), 1);
        assertEq(defi.nextIncidentId(), 1);
        assertEq(pool.boosterNFT(), address(booster));
    }

    function test_InitializeRejectsZeroRewardToken() public {
        CoverPool impl = new CoverPool();
        bytes memory initData = abi.encodeCall(CoverPool.initialize, (IERC20(address(0)), admin, admin, address(0)));
        vm.expectRevert(CoverPool.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_ImplementationCannotBeInitialized() public {
        CoverPool impl = new CoverPool();
        vm.expectRevert(); // InvalidInitialization (impl initializers disabled)
        impl.initialize(IERC20(address(usd8)), admin, admin, address(booster));
    }

    function test_UpgradeOnlyTimelock() public {
        CoverPool newImpl = new CoverPool();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.UnauthorizedTimelock.selector, alice));
        pool.upgradeToAndCall(address(newImpl), "");

        // admin == timelock in this suite.
        vm.prank(admin);
        pool.upgradeToAndCall(address(newImpl), "");
    }

    // ════════════════════ Asset management ════════════════════

    function test_AddAssetRejectsRewardToken() public {
        vm.prank(admin);
        vm.expectRevert(CoverPool.TokenConflict.selector);
        pool.addCoverPoolAsset(IERC20(address(usd8)), FEED, 0);
    }

    function test_AddAssetDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.CoverPoolAssetAlreadyApproved.selector, IERC20(address(usdc))));
        pool.addCoverPoolAsset(IERC20(address(usdc)), FEED, 0);
    }

    function test_RemoveAssetWithSharesReverts() public {
        _stake(alice, usdc, 100e6);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.CoverPoolAssetHasShares.selector, IERC20(address(usdc)), 100e6));
        pool.removeCoverPoolAsset(IERC20(address(usdc)));
    }

    function test_RemoveAssetClean() public {
        vm.prank(admin);
        pool.removeCoverPoolAsset(IERC20(address(wbtc)));
        assertEq(pool.coverPoolAssetListLength(), 2);
    }

    function test_StakeCreditsAmountReceivedForFeeToken() public {
        MockFeeToken fee = new MockFeeToken(100); // 1% fee on transfer
        vm.prank(admin);
        pool.addCoverPoolAsset(IERC20(address(fee)), FEED, 0);

        fee.mint(alice, 100e18);
        vm.startPrank(alice);
        fee.approve(address(pool), 100e18);
        uint256 shares = pool.stake(IERC20(address(fee)), 100e18);
        vm.stopPrank();

        // 1% taken in transit -> pool credits the 99e18 it actually received,
        // not the 100e18 requested (else totalAssets would overstate balance).
        assertEq(pool.totalAssets(IERC20(address(fee))), 99e18);
        assertEq(shares, 99e18); // first stake: 1:1 on the received amount
        assertEq(fee.balanceOf(address(pool)), 99e18);
    }

    function test_AssetCurationBlockedDuringIncident() public {
        _stake(alice, usdc, 100e6);
        _registerClaim(bob, lp1, 50e18); // opens incident

        MockERC20 newAsset = new MockERC20("NEW", "NEW", 18);
        vm.prank(admin);
        vm.expectRevert(CoverPool.PoolFrozen.selector);
        pool.addCoverPoolAsset(IERC20(address(newAsset)), FEED, 0);

        // wbtc has zero shares but removal is still blocked while active.
        vm.prank(admin);
        vm.expectRevert(CoverPool.PoolFrozen.selector);
        pool.removeCoverPoolAsset(IERC20(address(wbtc)));
    }

    // ════════════════════ Insured token management ════════════════════

    function test_AddInsuredTokenRejectsStakeAsset() public {
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.TokenConflict.selector);
        defi.addInsuredToken(IERC20(address(usdc)), 8000, FEED, address(0), "");
    }

    function test_AddInsuredTokenRejectsRewardToken() public {
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.TokenConflict.selector);
        defi.addInsuredToken(IERC20(address(usd8)), 8000, FEED, address(0), "");
    }

    function test_AddInsuredTokenDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InsuredTokenAlreadyApproved.selector, IERC20(address(lp1))));
        defi.addInsuredToken(IERC20(address(lp1)), 8000, FEED, address(0), "");
    }

    // ════════════════════ Settlement config ════════════════════

    function test_AddInsuredTokenStoresConfig() public {
        DefiInsurance.InsuredToken memory it = defi.getInsuredToken(IERC20(address(lp1)));
        assertEq(it.maxCoverageBps, 8000);
        assertEq(it.priceOracle, FEED);
        assertEq(it.underlyingConversionAddress, address(0)); // identity
    }

    function test_AddInsuredTokenRejectsBadArgs() public {
        MockERC20 lp3 = new MockERC20("LP3", "LP3", 18);
        vm.startPrank(admin);
        vm.expectRevert(DefiInsurance.ZeroAddress.selector); // zero price oracle
        defi.addInsuredToken(IERC20(address(lp3)), 8000, address(0), address(0), "");
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InvalidMaxCoverageBps.selector, uint256(0), uint256(10_000)));
        defi.addInsuredToken(IERC20(address(lp3)), 0, FEED, address(0), "");
        vm.stopPrank();
    }

    function test_AddAssetRejectsZeroFeed() public {
        MockERC20 t = new MockERC20("T", "T", 18);
        vm.prank(admin);
        vm.expectRevert(CoverPool.ZeroAddress.selector);
        pool.addCoverPoolAsset(IERC20(address(t)), address(0), 0);
    }

    function test_UnderlyingConversionUpdatable() public {
        // Mutable via setter: update lp1's conversion recipe in place.
        vm.prank(admin);
        defi.setUnderlyingConversion(IERC20(address(lp1)), address(0xABCD), hex"1234");
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).underlyingConversionAddress, address(0xABCD));

        // And re-listing sets a fresh recipe.
        vm.startPrank(admin);
        defi.removeInsuredToken(IERC20(address(lp1)));
        defi.addInsuredToken(IERC20(address(lp1)), 8000, FEED, address(0xBEEF), hex"5678");
        vm.stopPrank();
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).underlyingConversionAddress, address(0xBEEF));
    }

    function test_ScoredTokenCrud() public {
        vm.startPrank(admin);
        pool.addScoredToken(IERC20(address(usd8)), 5, 100);
        assertEq(pool.scoredTokensLength(), 1);
        CoverPool.ScoredToken[] memory list = pool.getScoredTokens();
        assertEq(address(list[0].token), address(usd8));
        assertEq(list[0].scorePerTokenPerBlock, 5);
        assertEq(list[0].startBlock, 100);

        // Duplicate reverts.
        vm.expectRevert(abi.encodeWithSelector(CoverPool.ScoredTokenNotFound.selector, IERC20(address(usd8))));
        pool.addScoredToken(IERC20(address(usd8)), 9, 1);

        // Update both rate and start block.
        pool.updateScoredToken(IERC20(address(usd8)), 7, 200);
        assertEq(pool.getScoredTokens()[0].scorePerTokenPerBlock, 7);
        assertEq(pool.getScoredTokens()[0].startBlock, 200);

        pool.removeScoredToken(IERC20(address(usd8)));
        assertEq(pool.scoredTokensLength(), 0);

        // Not found.
        vm.expectRevert(abi.encodeWithSelector(CoverPool.ScoredTokenNotFound.selector, IERC20(address(usd8))));
        pool.updateScoredToken(IERC20(address(usd8)), 1, 1);
        vm.stopPrank();
    }

    function test_ConfigChangesFrozenDuringIncident() public {
        _registerClaim(bob, lp1, 50e18); // opens incident

        DefiInsurance.SettlementParams memory p =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 1, holdingMarginBlocks: 1, sampleStepBlocks: 1});
        vm.startPrank(admin);
        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        defi.setSettlementParams(p);
        vm.expectRevert(CoverPool.PoolFrozen.selector);
        pool.addScoredToken(IERC20(address(usd8)), 1, 1);
        vm.stopPrank();
    }

    function test_ZeroSampleStepReverts() public {
        DefiInsurance.SettlementParams memory p =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 50, holdingMarginBlocks: 20, sampleStepBlocks: 0});
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.InvalidSettlementParams.selector);
        defi.setSettlementParams(p);
    }

    function test_IncidentConfigSnapshotAtOpen() public {
        DefiInsurance.SettlementParams memory p =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 50, holdingMarginBlocks: 20, sampleStepBlocks: 5});
        vm.startPrank(admin);
        defi.setSettlementParams(p);
        pool.addScoredToken(IERC20(address(usd8)), 5, 100);
        vm.stopPrank();

        _registerClaim(bob, lp1, 50e18); // opens incident 1, snapshots config

        DefiInsurance.IncidentConfig memory c = defi.getIncidentConfig(1);
        assertEq(c.maxCoverageBps, 8000);
        assertEq(c.priceOracle, FEED);
        assertEq(c.underlyingConversionAddress, address(0));
        assertEq(c.params.twapLookbackBlocks, 50);
        assertEq(c.params.holdingMarginBlocks, 20);
        // Scored-token set captured too.
        assertEq(c.scoredTokens.length, 1);
        assertEq(address(c.scoredTokens[0].token), address(usd8));
        assertEq(c.scoredTokens[0].scorePerTokenPerBlock, 5);

        // Resolve incident (void), then retune the global params — the
        // incident's snapshot must NOT change.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        DefiInsurance.SettlementParams memory p2 =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 999, holdingMarginBlocks: 1, sampleStepBlocks: 1});
        vm.prank(admin);
        defi.setSettlementParams(p2);
        assertEq(defi.getIncidentConfig(1).params.twapLookbackBlocks, 50); // frozen at open
        (uint64 tw,,) = defi.settlementParams();
        assertEq(tw, 999); // live updated
    }

    function test_AdminCanRemoveInsuredToken() public {
        vm.prank(admin);
        defi.removeInsuredToken(IERC20(address(lp2)));
        assertEq(defi.insuredTokenListLength(), 1);
        uint256 cov = defi.getInsuredToken(IERC20(address(lp2))).maxCoverageBps;
        assertEq(cov, 0); // maxCoverageBps == 0 ⇒ delisted
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
        (uint256 sh, uint64 reqAt) = pool.unstakeRequests(IERC20(address(usdc)), alice);
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
        (uint256 sh,) = pool.unstakeRequests(IERC20(address(usdc)), alice);
        assertEq(sh, 0);
    }

    function test_CompleteUnstakeBlockedByActiveIncident() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.prank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 100e6);

        // Settle so the incident stays active through its dispute/finalize phases
        // (otherwise it would void at the submit deadline = 7d, the cooldown).
        vm.warp(block.timestamp + 4 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(0, 0, 0)));

        // t = 7d+1: cooldown (7d) elapsed but the incident is still active.
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        vm.expectRevert(CoverPool.PoolFrozen.selector);
        pool.completeUnstake(IERC20(address(usdc)));
    }

    // ════════════════════ Rewards (preserved behavior) ════════════════════

    function test_ProfitDistributionRevertsWithNoStakers() public {
        vm.startPrank(admin);
        pool.setCoverPoolAssetWeight(IERC20(address(usdc)), 1);
        usd8.mint(admin, 100e18);
        usd8.approve(address(pool), 100e18);
        vm.expectRevert(CoverPool.NoEligibleStakers.selector);
        pool.receiveProfitDistribution(100e18);
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

    function test_PendingUnstakeStopsEarning() public {
        _stake(alice, usdc, 100e6);
        _stake(bob, usdc, 100e6);
        _notify(usdc, 70e18); // 10 USD8/day over 200 shares

        // Day 1: even split.
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(pool.earned(IERC20(address(usdc)), alice), 5e18, 1e10);

        // Alice queues an unstake -> her shares leave the earning base.
        vm.prank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 100e6);
        uint256 aliceAtRequest = pool.earned(IERC20(address(usdc)), alice);

        // Days 2-3: Alice accrues nothing more; Bob now earns the full rate.
        vm.warp(block.timestamp + 2 days);
        assertEq(pool.earned(IERC20(address(usdc)), alice), aliceAtRequest);
        // Bob: 5 (day1, half) + 20 (days2-3, solo at 10/day) = 25.
        assertApproxEqAbs(pool.earned(IERC20(address(usdc)), bob), 25e18, 1e10);
    }

    function test_RewardCarriesForwardWhenEarningBaseEmpties() public {
        _stake(alice, usdc, 100e6);
        _notify(usdc, 70e18); // 70 USD8 over 7 days = 10/day, alice solo

        vm.warp(block.timestamp + 1 days); // day 1: alice earns ~10

        // Alice queues her full position -> the asset's earning base is now 0.
        vm.prank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 100e6);

        // 3 days pass with zero earning base. Pre-fix this emission was stranded
        // in rewardReserve forever; now it must be carried forward.
        vm.warp(block.timestamp + 3 days);

        vm.prank(alice);
        pool.cancelUnstakeRequest(IERC20(address(usdc))); // base returns; gap deferred

        // Warp well past the (extended) stream end so everything pays out.
        vm.warp(block.timestamp + 14 days);

        // Alice is the only staker across the whole stream, so she must ultimately
        // receive the entire 70 USD8 — the 3 zero-base days were re-streamed, not lost.
        vm.prank(alice);
        uint256 got = pool.withdrawYield(IERC20(address(usdc)));
        assertApproxEqAbs(got, 70e18, 1e12);
    }

    function test_CancelUnstakeResumesEarning() public {
        _stake(alice, usdc, 100e6);
        _stake(bob, usdc, 100e6);
        _notify(usdc, 70e18);

        vm.prank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 100e6);
        vm.warp(block.timestamp + 1 days);
        uint256 frozen = pool.earned(IERC20(address(usdc)), alice);

        // Cancel -> Alice rejoins the earning base.
        vm.prank(alice);
        pool.cancelUnstakeRequest(IERC20(address(usdc)));
        vm.warp(block.timestamp + 1 days);
        assertGt(pool.earned(IERC20(address(usdc)), alice), frozen);
    }

    function test_ProfitDistributionRevertsWhenAllUnstaking() public {
        _stake(alice, usdc, 100e6);
        vm.prank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 100e6);

        vm.startPrank(admin);
        pool.setCoverPoolAssetWeight(IERC20(address(usdc)), 1);
        usd8.mint(admin, 10e18);
        usd8.approve(address(pool), 10e18);
        vm.expectRevert(CoverPool.NoEligibleStakers.selector);
        pool.receiveProfitDistribution(10e18);
        vm.stopPrank();
    }

    function test_ProfitDistributionSplitsByWeight() public {
        _stake(alice, usdc, 100e6);
        _stake(bob, dai, 100e18);
        vm.startPrank(admin);
        pool.setCoverPoolAssetWeight(IERC20(address(usdc)), 1);
        pool.setCoverPoolAssetWeight(IERC20(address(dai)), 3); // dai earns 3×
        usd8.mint(admin, 80e18);
        usd8.approve(address(pool), 80e18);
        pool.receiveProfitDistribution(80e18);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION);
        // 1:3 split of 80 → usdc 20, dai 60.
        assertApproxEqAbs(pool.earned(IERC20(address(usdc)), alice), 20e18, 1e10);
        assertApproxEqAbs(pool.earned(IERC20(address(dai)), bob), 60e18, 1e10);
    }

    function test_ProfitDistributionRedistributesNoStakerShare() public {
        _stake(alice, usdc, 100e6); // usdc staked; dai weighted but no stakers
        vm.startPrank(admin);
        pool.setCoverPoolAssetWeight(IERC20(address(usdc)), 1);
        pool.setCoverPoolAssetWeight(IERC20(address(dai)), 3);
        usd8.mint(admin, 80e18);
        usd8.approve(address(pool), 80e18);
        pool.receiveProfitDistribution(80e18);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION);
        // dai has no stakers → its weight is excluded; usdc receives the full 80.
        assertApproxEqAbs(pool.earned(IERC20(address(usdc)), alice), 80e18, 1e10);
    }

    // ════════════════════ Claim registration ════════════════════

    function test_RegisterClaimOpensIncidentAndDelists( // auto-delist on open
    )
        public
    {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        assertEq(cid, 1);
        (IERC20 tok, uint64 wEnd, bytes32 root,, uint256 claimCount,,,) = defi.incidents(1);
        assertEq(address(tok), address(lp1));
        assertEq(wEnd, uint64(block.timestamp) + 4 days);
        assertEq(root, bytes32(0));
        assertEq(claimCount, 1);
        assertEq(defi.activeIncidentId(), 1);
        uint256 covAfter = defi.getInsuredToken(IERC20(address(lp1))).maxCoverageBps;
        assertEq(covAfter, 0); // auto-delisted at open
        assertEq(lp1.balanceOf(address(defi)), 50e18);
    }

    function test_FirstClaimIdIsOne() public {
        assertEq(defi.nextClaimId(), 1); // starts at 1
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        assertEq(cid, 1); // first claim id is 1, NOT 2
        (address user,,,,,) = defi.claims(1);
        assertEq(user, bob); // record stored at claims[1]
        (address u2,,,,,) = defi.claims(2);
        assertEq(u2, address(0)); // claims[2] is empty
        assertEq(defi.nextClaimId(), 2); // now points at 2 for the next claim
    }

    function test_SecondClaimSameTokenJoinsIncident() public {
        _registerClaim(bob, lp1, 50e18);
        _registerClaim(carol, lp1, 30e18);
        (,,,, uint256 claimCount,,,) = defi.incidents(1);
        assertEq(claimCount, 2);
        assertEq(defi.nextIncidentId(), 2);
    }

    function test_OpenIncidentUnapprovedTokenReverts() public {
        MockERC20 lp3 = new MockERC20("LP3", "LP3", 18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InsuredTokenNotApproved.selector, IERC20(address(lp3))));
        defi.openClaimIncident(IERC20(address(lp3)), uint64(block.number - 1));
    }

    function test_RegisterClaimWithoutOpenIncidentReverts() public {
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NoOpenIncident.selector, IERC20(address(lp1))));
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, new uint256[](0), new uint256[](0));
        vm.stopPrank();
    }

    function test_OpenIncidentOnlyAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.UnauthorizedAdmin.selector, bob));
        vm.prank(bob);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
    }

    function test_OneClaimPerAccountPerIncident() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18); // opens incident 1, bob joins

        // A second claim by bob in the same incident reverts.
        lp1.mint(bob, 20e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 20e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.DuplicateClaim.selector, uint256(1)));
        defi.joinClaim(IERC20(address(lp1)), 20e18, 0, new uint256[](0), new uint256[](0));
        vm.stopPrank();

        // After cancelling, bob may re-file within the window.
        vm.prank(bob);
        defi.cancelClaim(cid);
        vm.startPrank(bob);
        lp1.approve(address(defi), 20e18);
        uint256 cid2 = defi.joinClaim(IERC20(address(lp1)), 20e18, 0, new uint256[](0), new uint256[](0));
        vm.stopPrank();
        assertGt(cid2, cid);
    }

    function test_ClaimAfterWindowReverts() public {
        _registerClaim(bob, lp1, 50e18);
        (, uint64 wEnd,,,,,,) = defi.incidents(1);
        vm.warp(wEnd + 1);

        lp1.mint(carol, 30e18);
        vm.startPrank(carol);
        lp1.approve(address(defi), 30e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, IERC20(address(lp1)), wEnd));
        defi.joinClaim(IERC20(address(lp1)), 30e18, 0, new uint256[](0), new uint256[](0));
        vm.stopPrank();
    }

    function test_RelistedTokenOpensFreshIncident() public {
        _registerClaim(bob, lp1, 50e18);
        // Resolve incident 1 by void: no root, dispute period passes.
        vm.warp(block.timestamp + 5 days + 4 days + 1);

        vm.prank(admin);
        defi.addInsuredToken(IERC20(address(lp1)), 8000, FEED, address(0), "");
        uint256 cid = _registerClaim(carol, lp1, 30e18);
        (, uint256 incidentId,,,,) = defi.claims(cid);
        assertEq(incidentId, 2);
        assertEq(defi.activeIncidentId(), 2);
    }

    // ════════════════════ Cancel & withdraw ════════════════════

    function test_CancelClaimDuringWindowRefunds() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.prank(bob);
        defi.cancelClaim(cid);
        assertEq(lp1.balanceOf(bob), 50e18);
        (,,,,, uint256 resolvedCount,,) = defi.incidents(1);
        assertEq(resolvedCount, 1);
    }

    function test_CancelAfterWindowReverts() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        (, uint64 wEnd,,,,,,) = defi.incidents(1);
        vm.warp(wEnd + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, IERC20(address(lp1)), wEnd));
        defi.cancelClaim(cid);
    }

    function test_CancelByNonOwnerReverts() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.UnauthorizedClaim.selector, cid));
        defi.cancelClaim(cid);
    }

    function test_WithdrawClaimAfterVoidIncident() public {
        // No root ever submitted -> incident void at windowEnd + 3d.
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimNotWithdrawable.selector, cid));
        defi.withdrawNonFinalizedClaim(cid);

        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
        assertEq(lp1.balanceOf(bob), 50e18);
    }

    function test_WithdrawClaimAfterFinalizeWindowExpires() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root = _leaf(1, cid, bob, _amounts(40e6, 0, 0));
        _settle(1, root);

        // Bob sleeps through the finalize window.
        vm.warp(block.timestamp + 3 days + 5 days + 1);
        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(cid, _amounts(40e6, 0, 0), 0, noProof);

        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
        assertEq(lp1.balanceOf(bob), 50e18);
        // Payout portion stayed in the pool.
        assertEq(pool.totalAssets(IERC20(address(usdc))), 100e6);
    }

    // ════════════════════ Settlement (root) ════════════════════

    function test_SettleIncidentAcceptsAdminRoot() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);

        bytes32 root = _leaf(1, cid, bob, _amounts(40e6, 0, 0));
        _settle(1, root);

        (,, bytes32 storedRoot,,,,,) = defi.incidents(1);
        assertEq(storedRoot, root);
        // amounts[] align to the (incident-stable) stake-asset list.
        IERC20[] memory list = pool.getCoverPoolAssetList();
        assertEq(list.length, 3);
        assertEq(address(list[0]), address(usdc));
    }

    function test_SettleOnlyAdmin() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.UnauthorizedAdmin.selector, bob));
        vm.prank(bob);
        defi.settleIncident(1, bytes32(uint256(1)));
    }

    function test_SettleBeforeWindowEndReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.settleIncident(1, bytes32(uint256(1)));
    }

    function test_SettleAfterCutoffReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 4 days + 1); // past SUBMIT_DEADLINE
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.settleIncident(1, bytes32(uint256(1)));
    }

    function test_SettleTwiceReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);
        _settle(1, bytes32(uint256(1)));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.RootAlreadySet.selector, uint256(1)));
        defi.settleIncident(1, bytes32(uint256(2)));
    }

    function test_VoidSettlementAndResubmit() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);
        _settle(1, bytes32(uint256(1)));

        // Non-role caller cannot void.
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.UnauthorizedAdmin.selector, alice));
        vm.prank(alice);
        defi.voidSettlement(1);

        // Fast brake: admin voids instantly.
        vm.prank(admin);
        defi.voidSettlement(1);
        (,, bytes32 root,,,,,) = defi.incidents(1);
        assertEq(root, bytes32(0));

        // Corrected root resubmitted within the submit deadline.
        _settle(1, bytes32(uint256(2)));
        (,, root,,,,,) = defi.incidents(1);
        assertEq(root, bytes32(uint256(2)));
    }

    function test_VoidWithoutRootReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NoStandingRoot.selector, uint256(1)));
        defi.voidSettlement(1);
    }

    function test_RootImmutableAfterDisputePeriod() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);
        _settle(1, bytes32(uint256(1)));
        vm.warp(block.timestamp + 4 days + 1); // past the 4-day dispute window
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.voidSettlement(1);
    }

    /// @dev Submitting at the last allowed moment still yields a FULL dispute
    ///      window measured from submission — it cannot be compressed.
    function test_DisputeWindowFixedFromLateSubmission() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        // Settle at the submit deadline (windowEnd + 3d).
        vm.warp(block.timestamp + 4 days + 3 days);
        _settle(1, _leaf(1, cid, bob, _amounts(0, 0, 0)));

        // Three days into the (4-day) dispute window: voiding is still allowed.
        vm.warp(block.timestamp + 3 days);
        vm.prank(admin);
        defi.voidSettlement(1);

        // Past the submit deadline, a void leaves the incident permanently
        // void — no resubmission is possible.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.settleIncident(1, bytes32(uint256(9)));
    }

    // ════════════════════ Finalize ════════════════════

    function test_FinalizeSingleClaimMultiAsset() public {
        _stake(alice, usdc, 100e6);
        _stake(alice, dai, 100e18);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory amounts = _amounts(20e6, 20e18, 0);
        bytes32 root = _leaf(1, cid, bob, amounts);
        _settle(1, root);

        // Not open during the dispute period.
        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(cid, amounts, 0, noProof);

        vm.warp(block.timestamp + 4 days + 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, amounts, 0, noProof);

        assertEq(usdc.balanceOf(bob), 20e6);
        assertEq(dai.balanceOf(bob), 20e18);
        assertEq(pool.totalAssets(IERC20(address(usdc))), 80e6);
        assertEq(pool.totalAssets(IERC20(address(dai))), 80e18);
        // Forfeited insured tokens stay in the contract as unaccounted revenue.
        assertEq(lp1.balanceOf(address(defi)), 50e18);
    }

    function test_FinalizeTwoClaimantsMerkle() public {
        _stake(alice, usdc, 300e6);
        uint256 cb = _registerClaim(bob, lp1, 50e18);
        uint256 cc = _registerClaim(carol, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory amountsBob = _amounts(40e6, 0, 0);
        uint256[] memory amountsCarol = _amounts(20e6, 0, 0);
        bytes32 leafBob = _leaf(1, cb, bob, amountsBob);
        bytes32 leafCarol = _leaf(1, cc, carol, amountsCarol);
        bytes32 root = _hashPair(leafBob, leafCarol);
        _settle(1, root);
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory proofBob = new bytes32[](1);
        proofBob[0] = leafCarol;
        vm.prank(bob);
        defi.finalizeClaim(cb, amountsBob, 0, proofBob);

        bytes32[] memory proofCarol = new bytes32[](1);
        proofCarol[0] = leafBob;
        vm.prank(carol);
        defi.finalizeClaim(cc, amountsCarol, 0, proofCarol);

        assertEq(usdc.balanceOf(bob), 40e6);
        assertEq(usdc.balanceOf(carol), 20e6);
        assertEq(pool.totalAssets(IERC20(address(usdc))), 240e6);
    }

    function test_FinalizeWrongAmountsReverts() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(40e6, 0, 0)));
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InvalidProof.selector, cid));
        defi.finalizeClaim(cid, _amounts(90e6, 0, 0), 0, noProof);
    }

    function test_FinalizeTwiceReverts() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6, 0, 0);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        defi.finalizeClaim(cid, amounts, 0, noProof);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimAlreadyResolved.selector, cid));
        defi.finalizeClaim(cid, amounts, 0, noProof);
    }

    function test_PayoutClampedToPoolBalance() public {
        // Root says pay 500 USDC but the pool only holds 100 -> bob gets 100,
        // never more. Staking is frozen during the incident, so the balance
        // can't have grown past what the settlement computed against.
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(500e6, 0, 0);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        defi.finalizeClaim(cid, amounts, 0, noProof);
        assertEq(usdc.balanceOf(bob), 100e6);
        assertEq(pool.totalAssets(IERC20(address(usdc))), 0);
    }

    function test_StakeBlockedDuringIncidentThenResumes() public {
        _stake(alice, usdc, 100e6);
        _registerClaim(bob, lp1, 50e18); // opens incident 1

        usdc.mint(carol, 100e6);
        vm.startPrank(carol);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(CoverPool.PoolFrozen.selector);
        pool.stake(IERC20(address(usdc)), 100e6);
        vm.stopPrank();

        // Incident voids after the dispute period -> staking reopens.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(carol);
        pool.stake(IERC20(address(usdc)), 100e6);
        assertGt(pool.userShares(IERC20(address(usdc)), carol), 0);
    }

    // This test contract acts as a payout module; it must answer incidentActive()
    // (false = pool not frozen, so staking stays open after the drained payout).
    function incidentActive() external pure returns (bool) {
        return false;
    }

    function test_PayClaimOnlyByActiveModule() public {
        _stake(alice, usdc, 100e6);
        // bob is a registered payout module but never acquired the lock.
        vm.prank(admin);
        pool.setPayoutModule(bob, true);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10e6;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.NotActivePayoutModule.selector, bob));
        pool.payClaim(address(0xdead), amounts, 0);
    }

    function test_FullyDrainedAssetStaysStakeable() public {
        _stake(alice, usdc, 100e6); // 100e6 shares, 1:1

        // Drain usdc to exactly zero via a payout, leaving alice's shares outstanding.
        vm.prank(admin);
        pool.setPayoutModule(address(this), true);
        pool.lockPool(); // become the active payout module (required by payClaim)
        uint256[] memory amounts = new uint256[](3); // [usdc, dai, wbtc]
        amounts[0] = 100e6;
        pool.payClaim(address(0xdead), amounts, 0);
        assertEq(pool.totalAssets(IERC20(address(usdc))), 0);
        assertGt(pool.totalShares(IERC20(address(usdc))), 0);

        // Recapitalization must not revert (would div-by-zero pre-fix). New staker
        // mints received * totalShares and recovers ~everything; dead shares keep <1 wei.
        uint256 minted = _stake(carol, usdc, 50e6);
        assertEq(minted, 50e6 * 100e6);

        vm.startPrank(carol);
        pool.requestUnstake(IERC20(address(usdc)), minted);
        vm.warp(block.timestamp + 7 days + 1);
        uint256 out = pool.completeUnstake(IERC20(address(usdc)));
        vm.stopPrank();
        assertEq(out, 50e6 - 1); // ≤1-wei rounding crumb to the dead shares
    }

    function test_AdminSweepsForfeitedInsuredTokens() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6, 0, 0);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);
        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        defi.finalizeClaim(cid, amounts, 0, noProof);

        // Forfeited insured tokens are now unaccounted protocol revenue, sweepable.
        vm.prank(admin);
        defi.sweepInsuredToken(IERC20(address(lp1)), carol, 50e18);
        assertEq(lp1.balanceOf(carol), 50e18);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NotSweepable.selector, 1, 0));
        defi.sweepInsuredToken(IERC20(address(lp1)), carol, 1);
    }

    function test_SweepStrayStakeAssetExcessOnly() public {
        _stake(alice, usdc, 100e6);
        // Someone blindly transfers 50 USDC to the pool (not staked).
        usdc.mint(address(this), 50e6);
        usdc.transfer(address(pool), 50e6);

        // Staked principal (100) is untouchable; only the 50 stray is sweepable.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.NotSweepable.selector, 51e6, 50e6));
        pool.sweep(IERC20(address(usdc)), carol, 51e6);

        vm.prank(admin);
        pool.sweep(IERC20(address(usdc)), carol, 50e6);
        assertEq(usdc.balanceOf(carol), 50e6);
        assertEq(pool.totalAssets(IERC20(address(usdc))), 100e6); // principal intact
    }

    function test_SweepRewardTokenStrayRecoverable() public {
        // No rewards committed -> blindly-sent USD8 is fully recoverable.
        vm.prank(admin);
        usd8.mint(address(this), 10e18);
        usd8.transfer(address(pool), 10e18);
        vm.prank(admin);
        pool.sweep(IERC20(address(usd8)), carol, 10e18);
        assertEq(usd8.balanceOf(carol), 10e18);
    }

    function test_SweepRewardTokenProtectsCommittedReserve() public {
        _stake(alice, usdc, 100e6);
        _notify(usdc, 50e18); // 50 USD8 committed to rewards
        vm.prank(admin);
        usd8.mint(address(this), 10e18);
        usd8.transfer(address(pool), 10e18); // 10 stray on top

        // Only the 10 stray is sweepable; the 50 reserve is protected.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.NotSweepable.selector, 11e18, 10e18));
        pool.sweep(IERC20(address(usd8)), carol, 11e18);

        vm.prank(admin);
        pool.sweep(IERC20(address(usd8)), carol, 10e18);
        assertEq(usd8.balanceOf(carol), 10e18);
    }

    function test_SweepProtectsLiveClaimEscrow() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18); // 50 lp1 escrowed, opens incident
        lp1.mint(address(this), 30e18);
        lp1.transfer(address(defi), 30e18); // 30 lp1 stray

        // The 50 escrow is protected by accounting; only the 30 stray is sweepable.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NotSweepable.selector, 31e18, 30e18));
        defi.sweepInsuredToken(IERC20(address(lp1)), carol, 31e18);

        vm.prank(admin);
        defi.sweepInsuredToken(IERC20(address(lp1)), carol, 30e18);
        assertEq(lp1.balanceOf(carol), 30e18);

        // Bob's escrow is still fully recoverable.
        vm.prank(bob);
        defi.cancelClaim(cid);
        assertEq(lp1.balanceOf(bob), 50e18);
    }

    // ════════════════════ Boosters & score epoch ════════════════════

    /// @dev Admin opens an incident on `token`; `user` joins committing `qty`
    ///      units of booster `id`.
    function _openWithBooster(address user, MockERC20 token, uint128 amount, uint256 id, uint256 qty)
        internal
        returns (uint256 claimId)
    {
        token.mint(user, amount);
        booster.mint(user, id, qty);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(token)), uint64(block.number - 1));
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = id;
        amounts[0] = qty;
        vm.startPrank(user);
        token.approve(address(defi), amount);
        booster.setApprovalForAll(address(defi), true);
        claimId = defi.joinClaim(IERC20(address(token)), amount, 0, ids, amounts);
        vm.stopPrank();
    }

    function test_BoosterEscrowedOnOpen() public {
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 1, 3);
        assertEq(booster.balanceOf(address(defi), 1), 3);
        (uint256[] memory ids, uint256[] memory amounts) = defi.getClaimBoosters(cid);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);
        assertEq(amounts[0], 3);
    }

    function test_BoosterBurnedOnFinalize() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 1, 3);
        assertEq(booster.totalSupply(1), 3);

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6, 0, 0);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, amounts, 0, new bytes32[](0));

        assertEq(booster.balanceOf(address(defi), 1), 0);
        assertEq(booster.totalSupply(1), 0); // real burn reduced supply
        (uint256[] memory ids,) = defi.getClaimBoosters(cid);
        assertEq(ids.length, 0);
    }

    /// @dev A claim that spends score records it to the USD8 ledger on finalize.
    function test_ScoreSpentRecordedToLedgerOnFinalize() public {
        _stake(alice, usdc, 100e6);
        // Bob joins requesting to spend 500 score (the off-chain caps to his
        // available; here the settlement just attests scoreSpent in the leaf).
        lp1.mint(bob, 50e18);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        uint256 cid = defi.joinClaim(IERC20(address(lp1)), 50e18, 500, new uint256[](0), new uint256[](0));
        vm.stopPrank();

        assertEq(pool.insuranceScoreSpent(bob), 0);

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6, 0, 0);
        _settle(1, _leafSpent(1, cid, bob, amounts, 500));
        vm.warp(block.timestamp + 4 days + 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, amounts, 500, new bytes32[](0));

        // The spent score is now recorded in the shared ledger.
        assertEq(pool.insuranceScoreSpent(bob), 500);
    }

    function test_BoosterReturnedOnCancel() public {
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 1, 3);
        vm.prank(bob);
        defi.cancelClaim(cid);
        assertEq(booster.balanceOf(bob, 1), 3);
        (uint256[] memory ids,) = defi.getClaimBoosters(cid);
        assertEq(ids.length, 0);
    }

    function test_BoosterReturnedOnWithdraw() public {
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 1, 3);
        // Void: no root through the dispute period.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
        assertEq(booster.balanceOf(bob, 1), 3);
    }

    function test_SetBoosterNFTBlockedDuringIncident() public {
        _registerClaim(bob, lp1, 50e18); // opens an incident -> pool frozen
        vm.prank(admin);
        vm.expectRevert(CoverPool.PoolFrozen.selector);
        pool.setBoosterNFT(address(0xBEEF));

        // Resolves after the dispute period -> setting reopens.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(admin);
        pool.setBoosterNFT(address(0xBEEF));
        assertEq(pool.boosterNFT(), address(0xBEEF));
    }

    function test_BoosterReturnUsesSnapshotAfterCollectionChange() public {
        // bob escrows 3 of booster id 1 from the original collection.
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 1, 3);

        // Incident voids (no root past the submit deadline) -> pool unfreezes.
        vm.warp(block.timestamp + 5 days + 4 days + 1);

        // Governance repoints the pool's booster collection to a fresh one.
        MockERC1155 boosterB = new MockERC1155();
        vm.prank(admin);
        pool.setBoosterNFT(address(boosterB));

        // Withdraw returns bob's boosters from the ORIGINAL collection (snapshot),
        // not the new one (which holds nothing) — no revert, no stranding.
        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
        assertEq(booster.balanceOf(bob, 1), 3);
    }

    function test_BoosterCommitRequiresNftSet() public {
        vm.prank(admin);
        pool.setBoosterNFT(address(0));

        booster.mint(bob, 1, 1);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 1;
        amounts[0] = 1;
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        booster.setApprovalForAll(address(defi), true);
        vm.expectRevert(DefiInsurance.BoosterNFTUnset.selector);
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, ids, amounts);
        vm.stopPrank();
    }

    function test_BoosterArityMismatchReverts() public {
        booster.mint(bob, 1, 1);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256[] memory amounts = new uint256[](2); // length mismatch
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        booster.setApprovalForAll(address(defi), true);
        vm.expectRevert(DefiInsurance.BoosterArityMismatch.selector);
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, ids, amounts);
        vm.stopPrank();
    }

    // ════════════════════ Loss socialization & staker lock ════════════════════

    function test_LossSocializedAcrossStakers() public {
        _stake(alice, usdc, 100e6);
        _stake(carol, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 100e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(80e6, 0, 0);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);
        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        defi.finalizeClaim(cid, amounts, 0, noProof);

        // 200 -> 120 USDC backing the same shares; both stakers diluted equally.
        vm.warp(block.timestamp + 5 days + 1); // finalize window over, queue clears
        uint256 aliceOut = _completeUnstakeAfterCooldown(alice, usdc, 100e6);
        assertEq(aliceOut, 60e6);
    }

    function test_UnstakeBlockedThroughPhasesThenUnblocks() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.startPrank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 50e6);
        vm.stopPrank();

        // During the claim window the 7-day cooldown is the binding gate.
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vm.expectRevert(CoverPool.CooldownNotElapsed.selector);
        pool.completeUnstake(IERC20(address(usdc)));

        // Settle within the submit window (t = 6d+1; dispute ends 10d+1).
        vm.warp(block.timestamp + 4 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(10e6, 0, 0)));

        // Cooldown (7d) has now elapsed, but the incident is still in its
        // dispute window -> withdrawal stays blocked (t = 8d+1).
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vm.expectRevert(CoverPool.PoolFrozen.selector);
        pool.completeUnstake(IERC20(address(usdc)));

        // Past the dispute window (t = 10d+2): Bob finalizes -> all claims
        // resolved -> unblocked immediately.
        vm.warp(block.timestamp + 2 days + 1);
        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        defi.finalizeClaim(cid, _amounts(10e6, 0, 0), 0, noProof);
        vm.prank(alice);
        pool.completeUnstake(IERC20(address(usdc)));
    }

    function test_UnstakeUnblocksAfterVoidIncident() public {
        _stake(alice, usdc, 100e6);
        _registerClaim(bob, lp1, 50e18);

        vm.startPrank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 50e6);
        vm.stopPrank();

        // No root ever submitted: void at windowEnd + dispute period.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(alice);
        pool.completeUnstake(IERC20(address(usdc)));
    }

    function test_UnstakeUnblocksAfterSoleClaimCancelled() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.prank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 50e6);

        // Bob cancels the only claim while the window is open.
        vm.prank(bob);
        defi.cancelClaim(cid);

        // Cooldown (7d) elapsed and the window (5d) has closed with every claim
        // resolved: the incident is inactive WITHOUT waiting out the dispute
        // period (which would end at 8d). t = 7d+1.
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        pool.completeUnstake(IERC20(address(usdc)));
    }

    // ════════════════════ One incident at a time ════════════════════

    function test_SecondIncidentBlockedWhileFirstActive() public {
        _registerClaim(bob, lp1, 50e18);
        assertEq(defi.activeIncidentId(), 1);

        // Opening a second incident is rejected while the first is in flight,
        // even by the admin on a different insured token.
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.IncidentsActive.selector);
        defi.openClaimIncident(IERC20(address(lp2)), uint64(block.number - 1));
    }

    function test_NewIncidentOpensAfterPriorResolves() public {
        _stake(alice, usdc, 200e6);
        uint256 c1 = _registerClaim(bob, lp1, 50e18);

        // Settle + finalize incident 1 fully.
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory a1 = _amounts(40e6, 0, 0);
        _settle(1, _leaf(1, c1, bob, a1));
        vm.warp(block.timestamp + 4 days + 1);
        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        defi.finalizeClaim(c1, a1, 0, noProof);

        // Incident 1 inactive -> a fresh incident can open on lp2 and runs
        // its full settlement window off its own clock.
        uint256 c2 = _registerClaim(carol, lp2, 30e18);
        assertEq(defi.activeIncidentId(), 2);

        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root2 = _leaf(2, c2, carol, _amounts(10e6, 0, 0));
        _settle(2, root2);
        vm.warp(block.timestamp + 4 days + 1);
        vm.prank(carol);
        defi.finalizeClaim(c2, _amounts(10e6, 0, 0), 0, noProof);
        assertEq(usdc.balanceOf(carol), 10e6);
    }

    function test_NewIncidentOpensAfterPriorVoids() public {
        _registerClaim(bob, lp1, 50e18);
        // No root submitted: incident 1 voids at windowEnd + dispute period.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        // Now a new incident may open.
        uint256 c2 = _registerClaim(carol, lp2, 30e18);
        assertEq(defi.activeIncidentId(), 2);
        assertEq(c2, 2);
    }

    // ════════════════════ Ownership ════════════════════

    function test_RoleTransfersAndGating() public {
        // Distinct fast admin; timelock keeps config + role assignment.
        address fastAdmin = address(0xFA57);
        vm.prank(admin);
        pool.setAdmin(fastAdmin);
        assertEq(pool.admin(), fastAdmin);

        // Fast admin can run reward ops (the emission window) but not curate.
        vm.prank(fastAdmin);
        pool.setRewardsDuration(14 days);
        assertEq(pool.rewardsDuration(), 14 days);

        vm.expectRevert(abi.encodeWithSelector(CoverPool.UnauthorizedTimelock.selector, fastAdmin));
        vm.prank(fastAdmin);
        defi.setMaxCoverageBps(IERC20(address(lp1)), 7000);

        // Pool timelock handover; old timelock loses pool config access.
        address newTimelock = address(0x71E);
        vm.prank(admin);
        pool.setTimelock(newTimelock);
        assertEq(pool.timelock(), newTimelock);

        vm.expectRevert(abi.encodeWithSelector(CoverPool.UnauthorizedTimelock.selector, admin));
        vm.prank(admin);
        pool.addScoredToken(IERC20(address(usd8)), 1, 0);
    }
}
