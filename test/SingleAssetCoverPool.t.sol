// SPDX-License-Identifier: BUSL-1.1
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
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {Registry} from "../src/Registry.sol";
import {Managed} from "../src/Managed.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {USD8} from "../src/USD8.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";

contract SingleAssetCoverPoolTest is Test {
    MockERC20 usdc;
    USD8 usd8; // real USD8: reward token
    MockERC20 lp1; // insured token 1
    MockERC20 lp2; // insured token 2
    MockERC1155 booster;
    SingleAssetCoverPool pool; // the single USDC stake pool
    UpgradeableBeacon beacon;
    DefiInsurance defi;
    Registry authority;

    address admin = address(0xA11CE);
    address alice = address(0xBEEF);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    uint64 constant DURATION = 7 days;
    address constant FEED = address(0xFEED); // dummy USD feed (off-chain only, unused on-chain)

    function setUp() public {
        vm.roll(1000); // so openClaimIncident's referenceBlock (block.number - 1) is a valid past block
        usdc = new MockERC20("USDC", "USDC", 6);
        // admin doubles as timelock + admin on the shared Registry in tests.
        authority = new Registry(admin, admin, 8000);
        USD8 usd8Impl = new USD8();
        usd8 = USD8(address(new ERC1967Proxy(address(usd8Impl), abi.encodeCall(USD8.initialize, (authority, admin)))));
        lp1 = new MockERC20("LP1", "LP1", 18);
        lp2 = new MockERC20("LP2", "LP2", 18);
        booster = new MockERC1155();

        // SingleAssetCoverPool impl behind a shared UpgradeableBeacon (owner = admin),
        // matching prod. The launch pool is USDC, rewarded in USD8.
        SingleAssetCoverPool poolImpl = new SingleAssetCoverPool();
        beacon = new UpgradeableBeacon(address(poolImpl), admin);
        pool = _deployPool(IERC20(address(usdc)));

        defi = new DefiInsurance(authority);
        vm.startPrank(admin);
        authority.addPool(IERC20(address(usdc)), address(pool));
        authority.setBoosterNFT(address(booster));
        authority.setPayoutModule(address(defi));
        defi.addInsuredToken(IERC20(address(lp1)), 8000, FEED, address(0), "");
        defi.addInsuredToken(IERC20(address(lp2)), 8000, FEED, address(0), "");
        defi.setTeeSigner(vm.addr(TEE_PK)); // settlement is TEE-signature-gated
        vm.stopPrank();
    }

    // ────────────────────────── helpers ──────────────────────────

    /// @dev Deploy a pool proxy for `asset_` behind the shared beacon, rewarded in
    ///      USD8. The zero-seed just flips the {seeded} gate open (no locked shares,
    ///      no accounting perturbation) to mirror the prod rule that a pool is seeded
    ///      before it is used.
    function _deployPool(IERC20 asset_) internal returns (SingleAssetCoverPool) {
        SingleAssetCoverPool p = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(SingleAssetCoverPool.initialize, (authority, asset_, IERC20(address(usd8))))
                )
            )
        );
        p.seed(0);
        return p;
    }

    function _stake(address who, uint256 amount) internal returns (uint256 sharesMinted) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        sharesMinted = pool.stake(amount);
        vm.stopPrank();
    }

    /// @dev Fund rewards: admin (acting as the Treasury donor) streams `amount` USD8.
    function _notify(uint256 amount) internal {
        vm.startPrank(admin);
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
        claimId = defi.joinClaim(IERC20(address(insuredToken)), amount, 0, 0);
    }

    /// @dev True if the in-flight incident covers token and its claim
    ///      window is still open (i.e. a claim can join without opening).
    function _hasJoinableIncident(address token) internal view returns (bool) {
        uint256 active = defi.activeIncidentId();
        if (active == 0) return false;
        (IERC20 tok, uint64 wEnd,,,,,,) = defi.incidents(active);
        return address(tok) == token && block.timestamp <= wEnd;
    }

    /// @dev OZ double-hashed leaf over (incidentId, claimId, user, amounts, scoreSpent).
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

    /// @dev OZ MerkleProof sorted-pair hash (for building 2-leaf test trees).
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Relay a TEE-signed settlement root for incidentId.
    function _settle(uint256 incidentId, bytes32 root) internal {
        uint256[] memory pp = _pp();
        defi.settleIncident(incidentId, root, pp, _teeSign(incidentId, root, pp));
    }

    /// @dev Payout row for the single-pool [usdc] setup.
    function _amounts(uint256 usdcAmt) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = usdcAmt;
    }

    function _completeUnstakeAfterCooldown(address who, uint128 shares) internal returns (uint256 assetsOut) {
        vm.prank(who);
        pool.requestUnstake(shares);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(who);
        assetsOut = pool.completeUnstake();
    }

    // ════════════════════ Construction & basic config ════════════════════

    function test_ConstructorWiring() public view {
        assertEq(address(pool.rewardToken()), address(usd8));
        assertEq(address(pool.asset()), address(usdc));
        assertEq(authority.timelock(), admin);
        assertTrue(authority.isAdmin(admin));
        assertEq(pool.rewardsDuration(), DURATION);
        assertEq(authority.poolsLength(), 1);
        assertEq(defi.insuredTokenListLength(), 2);
        assertEq(defi.nextClaimId(), 1);
        assertEq(defi.nextIncidentId(), 1);
        assertEq(authority.boosterNFT(), address(booster));
    }

    function test_InitializeRejectsZeroRewardToken() public {
        vm.expectRevert(Managed.ZeroAddress.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(SingleAssetCoverPool.initialize, (authority, IERC20(address(usdc)), IERC20(address(0))))
        );
    }

    function test_ImplementationCannotBeInitialized() public {
        SingleAssetCoverPool impl = new SingleAssetCoverPool();
        vm.expectRevert(); // InvalidInitialization (impl initializers disabled)
        impl.initialize(authority, IERC20(address(usdc)), IERC20(address(usd8)));
    }

    /// @dev Beacon upgrade re-points the proxy at new code while storage is
    ///      preserved; only the beacon owner (timelock) may upgrade.
    function test_BeaconUpgradePreservesStorage() public {
        _stake(alice, 100e6);

        SingleAssetCoverPoolV2 v2 = new SingleAssetCoverPoolV2();

        // Non-owner cannot upgrade the beacon.
        vm.prank(alice);
        vm.expectRevert();
        beacon.upgradeTo(address(v2));

        // Owner (admin) upgrades: every pool sees the new code.
        vm.prank(admin);
        beacon.upgradeTo(address(v2));

        assertEq(SingleAssetCoverPoolV2(address(pool)).version(), 2); // new code
        assertEq(pool.totalShares(), 100e6); // storage intact
        assertEq(pool.userShares(alice), 100e6);
        assertEq(pool.totalAssets(), 100e6);
    }

    // ════════════════════ Pool topology (Registry) ════════════════════

    function test_AddPoolDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Registry.PoolExists.selector, IERC20(address(usdc))));
        authority.addPool(IERC20(address(usdc)), address(pool));
    }

    function test_RemovePool() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        SingleAssetCoverPool daiPool = _deployPool(IERC20(address(dai)));
        vm.startPrank(admin);
        authority.addPool(IERC20(address(dai)), address(daiPool));
        assertEq(authority.poolsLength(), 2);
        authority.removePool(IERC20(address(dai)));
        assertEq(authority.poolsLength(), 1);
        assertEq(authority.poolOf(IERC20(address(dai))), address(0));

        // Removing an unregistered asset reverts.
        vm.expectRevert(abi.encodeWithSelector(Registry.PoolNotFound.selector, IERC20(address(dai))));
        authority.removePool(IERC20(address(dai)));
        vm.stopPrank();
    }

    function test_StakeCreditsAmountReceivedForFeeToken() public {
        MockFeeToken fee = new MockFeeToken(100); // 1% fee on transfer
        SingleAssetCoverPool feePool = _deployPool(IERC20(address(fee)));
        vm.prank(admin);
        authority.addPool(IERC20(address(fee)), address(feePool));

        fee.mint(alice, 100e18);
        vm.startPrank(alice);
        fee.approve(address(feePool), 100e18);
        uint256 shares = feePool.stake(100e18);
        vm.stopPrank();

        // 1% taken in transit -> pool credits the 99e18 it actually received.
        assertEq(feePool.totalAssets(), 99e18);
        assertEq(shares, 99e18); // first stake: 1:1 on the received amount
        assertEq(fee.balanceOf(address(feePool)), 99e18);
    }

    function test_PoolCurationBlockedDuringIncident() public {
        _stake(alice, 100e6);
        _registerClaim(bob, lp1, 50e18); // opens incident -> system frozen

        MockERC20 newAsset = new MockERC20("NEW", "NEW", 18);
        SingleAssetCoverPool newPool = _deployPool(IERC20(address(newAsset)));
        vm.prank(admin);
        vm.expectRevert(Registry.Frozen.selector);
        authority.addPool(IERC20(address(newAsset)), address(newPool));

        // Removal is also blocked while an incident is active.
        vm.prank(admin);
        vm.expectRevert(Registry.Frozen.selector);
        authority.removePool(IERC20(address(usdc)));
    }

    // ════════════════════ Insured token management ════════════════════

    function test_AddInsuredTokenRejectsStakeAsset() public {
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.TokenConflict.selector);
        defi.addInsuredToken(IERC20(address(usdc)), 8000, FEED, address(0), "");
    }

    function test_AddInsuredTokenAcceptsUSD8() public {
        vm.prank(admin);
        defi.addInsuredToken(IERC20(address(usd8)), 8000, FEED, address(0), "");
        assertEq(defi.getInsuredToken(IERC20(address(usd8))).maxCoverageBps, 8000);
    }

    /// @dev End-to-end USD8 self-cover: the TEE attests a backing loss off-chain
    ///      and signs the open; alice then claims. No on-chain trigger/adapter.
    function test_USD8BackingLossTriggersIncident() public {
        vm.startPrank(admin);
        defi.addInsuredToken(IERC20(address(usd8)), 8000, FEED, address(0), "");
        usd8.mint(alice, 100e18);
        vm.stopPrank();
        vm.prank(alice);
        usd8.approve(address(defi), 100e18);

        // Without a TEE attestation there is no live incident, so joins revert.
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NoActiveIncidentToJoin.selector, IERC20(address(usd8))));
        defi.joinClaim(IERC20(address(usd8)), 50e18, 0, 0);

        // The TEE evaluates the backing loss off-chain and signs the open at a
        // pinned pre-incident reference block; anyone relays it.
        uint64 refBlock = uint64(block.number - 1);
        _openSigned(address(usd8), refBlock);
        uint256 id = defi.activeIncidentId();
        (,,,,, uint64 stored,,) = defi.incidents(id);
        assertEq(stored, refBlock);

        vm.prank(alice);
        defi.joinClaim(IERC20(address(usd8)), 50e18, 0, 0);
        // Still listed: delisting is deferred to root submission, not open.
        assertEq(defi.getInsuredToken(IERC20(address(usd8))).maxCoverageBps, 8000);
    }

    function test_AddInsuredTokenDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(DefiInsurance.InsuredTokenAlreadyApproved.selector, IERC20(address(lp1)))
        );
        defi.addInsuredToken(IERC20(address(lp1)), 8000, FEED, address(0), "");
    }

    // ════════════════════ Settlement config ════════════════════

    function test_AddInsuredTokenStoresConfig() public view {
        DefiInsurance.InsuredToken memory it = defi.getInsuredToken(IERC20(address(lp1)));
        assertEq(it.maxCoverageBps, 8000);
        assertEq(it.underlyingPriceOracle, FEED);
        assertEq(it.underlyingConversionAddress, address(0)); // identity
    }

    function test_AddInsuredTokenRejectsBadArgs() public {
        MockERC20 lp3 = new MockERC20("LP3", "LP3", 18);
        vm.startPrank(admin);
        vm.expectRevert(Managed.ZeroAddress.selector); // zero price oracle
        defi.addInsuredToken(IERC20(address(lp3)), 8000, address(0), address(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(DefiInsurance.InvalidMaxCoverageBps.selector, uint256(0), uint256(10_000))
        );
        defi.addInsuredToken(IERC20(address(lp3)), 0, FEED, address(0), "");
        vm.stopPrank();
    }

    function test_ConversionRecipeUpdatable() public {
        // Mutable via setter: repoint lp1's token→underlying recipe in place.
        bytes memory cd = abi.encodeWithSignature("convertToAssets(uint256)", 1e18);
        vm.prank(admin);
        defi.setUnderlyingConversion(IERC20(address(lp1)), address(0x1234), cd);
        DefiInsurance.InsuredToken memory it = defi.getInsuredToken(IERC20(address(lp1)));
        assertEq(it.underlyingConversionAddress, address(0x1234));
        assertEq(it.underlyingConversionCallData, cd);

        // And re-listing sets a fresh recipe.
        vm.startPrank(admin);
        defi.removeInsuredToken(IERC20(address(lp1)));
        defi.addInsuredToken(IERC20(address(lp1)), 8000, FEED, address(0x5678), cd);
        vm.stopPrank();
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).underlyingConversionAddress, address(0x5678));
    }

    function test_ScoredTokenCrud() public {
        vm.startPrank(admin);
        authority.setScoredToken(IERC20(address(usd8)), 5, 100);
        assertEq(authority.scoredTokensLength(), 1);
        Registry.ScoredToken[] memory list = authority.getScoredTokens();
        assertEq(address(list[0].token), address(usd8));
        assertEq(list[0].scorePerTokenPerBlock, 5);
        assertEq(list[0].startBlock, 100);

        // Upsert: setting the same token updates in place (no duplicate row).
        authority.setScoredToken(IERC20(address(usd8)), 7, 200);
        assertEq(authority.scoredTokensLength(), 1);
        assertEq(authority.getScoredTokens()[0].scorePerTokenPerBlock, 7);
        assertEq(authority.getScoredTokens()[0].startBlock, 200);

        authority.removeScoredToken(IERC20(address(usd8)));
        assertEq(authority.scoredTokensLength(), 0);

        // Not found.
        vm.expectRevert(abi.encodeWithSelector(Registry.ScoredTokenNotFound.selector, IERC20(address(usd8))));
        authority.removeScoredToken(IERC20(address(usd8)));
        vm.stopPrank();
    }

    function test_SettlementParamsMutableButScoredTokensFrozenDuringIncident() public {
        _registerClaim(bob, lp1, 50e18); // opens incident

        // settlementParams is safe to retune mid-incident: the live incident is
        // settled against state as of its openBlock, so the change only affects
        // future incidents. No longer reverts IncidentsActive.
        DefiInsurance.SettlementParams memory p =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 1, holdingMarginBlocks: 1, sampleStepBlocks: 1});
        vm.startPrank(admin);
        defi.setSettlementParams(p);

        // Scored-token curation stays frozen (guards live payout accounting).
        vm.expectRevert(Registry.Frozen.selector);
        authority.setScoredToken(IERC20(address(usd8)), 1, 1);
        vm.stopPrank();
    }

    function test_ZeroSampleStepReverts() public {
        DefiInsurance.SettlementParams memory p =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 50, holdingMarginBlocks: 20, sampleStepBlocks: 0});
        vm.prank(admin);
        vm.expectRevert(DefiInsurance.InvalidSettlementParams.selector);
        defi.setSettlementParams(p);
    }

    function test_OpenBlockRecordedForOffchainConfigRecompute() public {
        DefiInsurance.SettlementParams memory p =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 50, holdingMarginBlocks: 20, sampleStepBlocks: 5});
        vm.prank(admin);
        defi.setSettlementParams(p);

        uint64 expectedOpen = uint64(block.number);
        _registerClaim(bob, lp1, 50e18); // opens incident 1

        // The incident records only its open block; off-chain reconstructs the
        // full config (recipe, params, scored-token set) from state as of it.
        (,,,,,, uint64 openBlock,) = defi.incidents(1);
        assertEq(openBlock, expectedOpen);

        // A later retune cannot alter this incident — it is valued against
        // openBlock — so params are freely mutable while it is live.
        DefiInsurance.SettlementParams memory p2 =
            DefiInsurance.SettlementParams({twapLookbackBlocks: 999, holdingMarginBlocks: 1, sampleStepBlocks: 1});
        vm.prank(admin);
        defi.setSettlementParams(p2);
        (uint64 tw,,) = defi.settlementParams();
        assertEq(tw, 999);
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
        uint256 shares = _stake(alice, 100e6);
        assertEq(shares, 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(pool.userShares(alice), 100e6);
    }

    function test_StakeSecondIsProportional() public {
        _stake(alice, 100e6);
        uint256 sharesB = _stake(bob, 50e6);
        assertEq(sharesB, 50e6);
        assertEq(pool.totalShares(), 150e6);
    }

    function test_UnstakeRequestStartsCooldown() public {
        _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestUnstake(100e6);
        (uint256 sh, uint64 reqAt) = pool.unstakeRequests(alice);
        assertEq(sh, 100e6);
        assertEq(reqAt, block.timestamp);
    }

    function test_UnstakeRequestDuplicateReverts() public {
        _stake(alice, 100e6);
        vm.startPrank(alice);
        pool.requestUnstake(50e6);
        vm.expectRevert(SingleAssetCoverPool.UnstakeRequestExists.selector);
        pool.requestUnstake(50e6);
        vm.stopPrank();
    }

    function test_CompleteUnstakeBeforeCooldownReverts() public {
        _stake(alice, 100e6);
        vm.startPrank(alice);
        pool.requestUnstake(100e6);
        vm.expectRevert(SingleAssetCoverPool.CooldownNotElapsed.selector);
        pool.completeUnstake();
        vm.stopPrank();
    }

    function test_CompleteUnstakeAfterCooldownReturnsTokens() public {
        _stake(alice, 100e6);
        uint256 out = _completeUnstakeAfterCooldown(alice, 100e6);
        assertEq(out, 100e6);
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(pool.totalShares(), 0);
    }

    function test_CancelUnstakeRequest() public {
        _stake(alice, 100e6);
        vm.startPrank(alice);
        pool.requestUnstake(100e6);
        pool.cancelUnstakeRequest();
        vm.stopPrank();
        (uint256 sh,) = pool.unstakeRequests(alice);
        assertEq(sh, 0);
    }

    function test_CompleteUnstakeWithinWindowSucceeds() public {
        _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestUnstake(100e6);
        // Cooldown (7d) + 1d: still inside the 2-day completion window.
        vm.warp(block.timestamp + 7 days + 1 days);
        vm.prank(alice);
        assertEq(pool.completeUnstake(), 100e6);
    }

    function test_UnstakeRequestExpiresPastWindowAndCanReRequest() public {
        _stake(alice, 100e6);
        vm.prank(alice);
        pool.requestUnstake(100e6);

        // One second past the cooldown + window: the request has expired.
        vm.warp(block.timestamp + 7 days + 2 days + 1);
        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.UnstakeWindowExpired.selector);
        pool.completeUnstake();

        // A fresh request overwrites the expired one and starts a new cooldown.
        vm.prank(alice);
        pool.requestUnstake(100e6);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        assertEq(pool.completeUnstake(), 100e6);
    }

    function test_CompleteUnstakeBlockedByActiveIncident() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.prank(alice);
        pool.requestUnstake(100e6);

        // Settle so the incident stays active through its dispute/finalize phases
        // (otherwise it would void at the submit deadline = 7d, the cooldown).
        vm.warp(block.timestamp + 4 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(0)));

        // t = 7d+1: cooldown (7d) elapsed but the incident is still active.
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.PoolFrozen.selector);
        pool.completeUnstake();
    }

    // ════════════════════ Rewards (preserved behavior) ════════════════════

    function test_ProfitDistributionRevertsWithNoStakers() public {
        vm.startPrank(admin);
        usd8.mint(admin, 100e18);
        usd8.approve(address(pool), 100e18);
        vm.expectRevert(SingleAssetCoverPool.NoEligibleStakers.selector);
        pool.receiveProfitDistribution(100e18);
        vm.stopPrank();
    }

    function test_RewardAccruesProRata() public {
        _stake(alice, 100e6);
        _stake(bob, 100e6);
        _notify(70e18); // over 7d -> 10 USD8/day across 200 shares
        vm.warp(block.timestamp + DURATION);
        uint256 ea = pool.earned(alice);
        uint256 eb = pool.earned(bob);
        assertApproxEqAbs(ea, 35e18, 1e10);
        assertApproxEqAbs(eb, 35e18, 1e10);
    }

    function test_JITLatecomerOnlyGetsForwardSlice() public {
        _stake(alice, 100e6);
        _notify(70e18);
        vm.warp(block.timestamp + DURATION / 2);
        _stake(bob, 100e6); // joins halfway
        vm.warp(block.timestamp + DURATION / 2);

        uint256 ea = pool.earned(alice);
        uint256 eb = pool.earned(bob);
        // Alice: half stream solo + 1/2 of remaining half.
        // Bob:   only 1/2 of remaining half.
        assertApproxEqAbs(ea, 70e18 / 2 + 70e18 / 4, 1e10);
        assertApproxEqAbs(eb, 70e18 / 4, 1e10);
    }

    function test_PendingUnstakeKeepsEarning() public {
        _stake(alice, 100e6);
        _stake(bob, 100e6);
        _notify(70e18); // 10 USD8/day over 200 shares

        // Day 1: even split.
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(pool.earned(alice), 5e18, 1e10);

        // Alice queues an unstake -> her shares STAY in the earning base.
        vm.prank(alice);
        pool.requestUnstake(100e6);

        // Days 2-3: the 50/50 split is unchanged — alice keeps earning her half
        // the whole time the request is pending (no cooldown penalty).
        vm.warp(block.timestamp + 2 days);
        assertApproxEqAbs(pool.earned(alice), 15e18, 1e10);
        assertApproxEqAbs(pool.earned(bob), 15e18, 1e10);
    }

    function test_CancelUnstakeRequestDoesNotInterruptEarning() public {
        _stake(alice, 100e6);
        _stake(bob, 100e6);
        _notify(70e18);

        vm.prank(alice);
        pool.requestUnstake(100e6);
        vm.warp(block.timestamp + 1 days);
        uint256 midway = pool.earned(alice);
        assertGt(midway, 0); // earned throughout the pending request

        // Cancel is pure bookkeeping now; earning continues uninterrupted.
        vm.prank(alice);
        pool.cancelUnstakeRequest();
        vm.warp(block.timestamp + 1 days);
        assertGt(pool.earned(alice), midway);
    }

    function test_DustDonationDoesNotStretchRewardSchedule() public {
        _stake(alice, 100e6);
        _notify(70e18); // rate set, periodFinish = now + 7 days
        uint128 rate0 = pool.rewardRate();
        uint64 pf0 = pool.periodFinish();

        vm.warp(block.timestamp + 1 days);
        _notify(1); // 1-wei donation mid-stream

        uint128 rate1 = pool.rewardRate();
        uint64 pf1 = pool.periodFinish();
        // Dust must NOT reset periodFinish to a fresh full window.
        assertApproxEqAbs(uint256(pf1), uint256(pf0), 1 hours);
        // Rate barely moves — the funded stream isn't diluted.
        assertApproxEqRel(uint256(rate1), uint256(rate0), 1e15); // within 0.1%
    }

    // ════════════════════ Claim registration ════════════════════

    function test_RegisterClaimOpensIncident() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        assertEq(cid, 1);
        (IERC20 tok, uint64 wEnd, bytes32 root, uint256 unresolved,,,,) = defi.incidents(1);
        assertEq(address(tok), address(lp1));
        assertEq(wEnd, uint64(block.timestamp) + 4 days);
        assertEq(root, bytes32(0));
        assertEq(unresolved, 1);
        assertEq(defi.activeIncidentId(), 1);
        // Still listed at open: delisting is deferred to root submission.
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).maxCoverageBps, 8000);
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
        (,,, uint256 unresolved,,,,) = defi.incidents(1);
        assertEq(unresolved, 2);
        assertEq(defi.nextIncidentId(), 2);
    }

    function test_OpenIncidentUnapprovedTokenReverts() public {
        MockERC20 lp3 = new MockERC20("LP3", "LP3", 18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InsuredTokenNotApproved.selector, IERC20(address(lp3))));
        defi.openClaimIncident(IERC20(address(lp3)), uint64(block.number - 1));
    }

    /// @dev I1: a referenceBlock older than OPEN_MAX_REFERENCE_AGE is rejected, so
    ///      a stale (unrelayed) open attestation effectively expires.
    function test_OpenRejectsStaleReferenceBlock() public {
        vm.roll(1_000_000);
        uint64 maxAge = defi.OPEN_MAX_REFERENCE_AGE();

        uint64 tooOld = uint64(block.number) - maxAge - 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InvalidReferenceBlock.selector, tooOld));
        defi.openClaimIncident(IERC20(address(lp1)), tooOld);

        // Exactly at the boundary is still fresh enough.
        uint64 justOld = uint64(block.number) - maxAge;
        vm.prank(admin);
        assertGt(defi.openClaimIncident(IERC20(address(lp1)), justOld), 0);
    }

    /// @dev I2: a booster amount above uint128 is rejected, so the stored value can
    ///      never diverge from the uint256 emitted in ClaimRegistered.
    function test_JoinRejectsBoosterAmountAboveUint128() public {
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.BoosterAmountTooLarge.selector, tooBig));
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, tooBig);
        vm.stopPrank();
    }

    function test_JoinWithoutOpenIncidentReverts() public {
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NoActiveIncidentToJoin.selector, address(lp1)));
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, 0);
        vm.stopPrank();
    }

    function test_OpenIncidentOnlyAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, bob));
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
        defi.joinClaim(IERC20(address(lp1)), 20e18, 0, 0);
        vm.stopPrank();

        // After cancelling, bob may re-file within the window.
        vm.prank(bob);
        defi.cancelClaim();
        vm.startPrank(bob);
        lp1.approve(address(defi), 20e18);
        uint256 cid2 = defi.joinClaim(IERC20(address(lp1)), 20e18, 0, 0);
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
        defi.joinClaim(IERC20(address(lp1)), 30e18, 0, 0);
        vm.stopPrank();
    }

    function test_RelistedTokenOpensFreshIncident() public {
        uint256 cid1 = _registerClaim(bob, lp1, 50e18);
        // Submit a root: this is what delists lp1 (a confirmed event).
        vm.warp(block.timestamp + 4 days + 1);
        _settle(1, _leaf(1, cid1, bob, _amounts(0)));
        assertEq(defi.getInsuredToken(IERC20(address(lp1))).maxCoverageBps, 0); // delisted at root
        // Let incident 1 fully resolve (dispute + finalize windows elapse).
        vm.warp(block.timestamp + 4 days + 4 days + 1);

        // Delisted by settlement: governance must re-list before a new incident.
        vm.prank(admin);
        defi.addInsuredToken(IERC20(address(lp1)), 8000, FEED, address(0), "");
        uint256 cid = _registerClaim(carol, lp1, 30e18);
        (, uint256 incidentId,,,,) = defi.claims(cid);
        assertEq(incidentId, 2);
        assertEq(defi.activeIncidentId(), 2);
    }

    // ════════════════════ Cancel & withdraw ════════════════════

    function test_CancelClaimDuringWindowRefunds() public {
        _registerClaim(bob, lp1, 50e18);
        vm.prank(bob);
        defi.cancelClaim();
        assertEq(lp1.balanceOf(bob), 50e18);
        (,,, uint256 unresolved,,,,) = defi.incidents(1);
        assertEq(unresolved, 0); // join ++ then cancel -- back to zero
    }

    function test_CancelAfterWindowReverts() public {
        _registerClaim(bob, lp1, 50e18);
        (, uint64 wEnd,,,,,,) = defi.incidents(1);
        vm.warp(wEnd + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimWindowClosed.selector, IERC20(address(lp1)), wEnd));
        defi.cancelClaim();
    }

    function test_CancelByNonClaimantReverts() public {
        _registerClaim(bob, lp1, 50e18); // bob's claim; carol has none
        vm.prank(carol);
        vm.expectRevert(DefiInsurance.NoActiveClaim.selector);
        defi.cancelClaim();
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
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root = _leaf(1, cid, bob, _amounts(40e6));
        _settle(1, root);

        // Bob sleeps through the finalize window.
        vm.warp(block.timestamp + 3 days + 5 days + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(cid, _amounts(40e6), 0, new bytes32[](0));

        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
        assertEq(lp1.balanceOf(bob), 50e18);
        // Payout portion stayed in the pool.
        assertEq(pool.totalAssets(), 100e6);
    }

    // ════════════════════ Settlement (root) ════════════════════

    function test_SettleIncidentAcceptsAdminRoot() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);

        bytes32 root = _leaf(1, cid, bob, _amounts(40e6));
        _settle(1, root);

        (,, bytes32 storedRoot,,,,,) = defi.incidents(1);
        assertEq(storedRoot, root);
        // amounts[] align to the (incident-stable) pool asset list.
        (IERC20[] memory list,) = authority.pools();
        assertEq(list.length, 1);
        assertEq(address(list[0]), address(usdc));
    }

    function test_SettleBeforeWindowEndReverts() public {
        _registerClaim(bob, lp1, 50e18);
        bytes32 root = bytes32(uint256(1));
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root, pp); // precompute: expectRevert binds to the next call
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.settleIncident(1, root, pp, sig);
    }

    function test_SettleAfterCutoffReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 4 days + 1); // past SUBMIT_DEADLINE
        bytes32 root = bytes32(uint256(1));
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root, pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.settleIncident(1, root, pp, sig);
    }

    function test_ResubmitOverwritesRootInWindow() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);
        _settle(1, bytes32(uint256(1)));
        // A corrected root overwrites the standing one while still in the submit
        // window (no separate void step) and resets the dispute clock.
        _settle(1, bytes32(uint256(2)));
        (,, bytes32 root,,,,,) = defi.incidents(1);
        assertEq(root, bytes32(uint256(2)));
    }

    function test_SettleZeroRootReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, bytes32(0), pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NoStandingRoot.selector, uint256(1)));
        defi.settleIncident(1, bytes32(0), pp, sig);
    }

    function test_CloseIncidentByAdmin() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        assertEq(defi.activeIncidentId(), 1);

        // Non-role caller cannot close.
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, alice));
        vm.prank(alice);
        defi.closeIncident();

        // Admin closes: pool unlocks and the claimant recovers escrow immediately.
        vm.prank(admin);
        defi.closeIncident();
        assertEq(defi.activeIncidentId(), 0);
        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
        assertEq(lp1.balanceOf(bob), 50e18);
    }

    /// @dev Regression: a closed (vetoed) incident is terminal — a claimant holding
    ///      a ticket for the vetoed root can NOT finalize after the dispute period.
    function test_FinalizeBlockedAfterClose() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1); // claim window ends
        uint256[] memory amounts = _amounts(50e6);
        _settle(1, _leaf(1, cid, bob, amounts)); // bad root settled

        // Admin vetoes during the dispute period; pool unfreezes.
        vm.prank(admin);
        defi.closeIncident();

        // Past the dispute period, into what would be the finalize window: a proof
        // for the vetoed root must NOT pay out.
        vm.warp(block.timestamp + 4 days + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(cid, amounts, 0, new bytes32[](0));

        // Escrow recovery is the only path after a close.
        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
        assertEq(lp1.balanceOf(bob), 50e18);
        assertEq(pool.totalAssets(), 100e6); // pool untouched
    }

    function test_CloseInactiveIncidentReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 3 days + 1); // voids by submit-deadline timeout
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.NotActiveIncident.selector, uint256(1)));
        defi.closeIncident();
    }

    function test_CloseBlockedOnceFinalizeWindowOpens() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(0)));
        // Close is allowed through the dispute period; once it elapses (finalize
        // window open), the confirmed settlement can no longer be aborted.
        vm.warp(block.timestamp + 4 days + 1); // past rootSubmittedAt + DISPUTE_PERIOD
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentFinalizing.selector, uint256(1)));
        vm.prank(admin);
        defi.closeIncident();
    }

    /// @dev Submitting at the last allowed moment still yields a FULL dispute
    ///      window from submission; once the submit window passes the root is
    ///      locked (no overwrite), but the admin brake {closeIncident} still works.
    function test_LateSubmissionAndCloseBrake() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 3 days); // settle at the submit deadline
        _settle(1, _leaf(1, cid, bob, _amounts(0)));

        // Past the submit deadline: no resubmit/overwrite.
        vm.warp(block.timestamp + 1 days);
        bytes32 root9 = bytes32(uint256(9));
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root9, pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.OutsideSettlementPhase.selector, uint256(1)));
        defi.settleIncident(1, root9, pp, sig);

        // The admin brake still works during the dispute window.
        vm.prank(admin);
        defi.closeIncident();
        assertEq(defi.activeIncidentId(), 0);
    }

    function test_CancelLastClaimKeepsIncidentLive() public {
        _registerClaim(bob, lp1, 50e18); // opened via admin, bob joins
        vm.prank(bob);
        defi.cancelClaim();
        // No auto-close: the incident stays live even when empty. Ending it is an
        // explicit closeIncident (or it runs its course).
        assertEq(defi.activeIncidentId(), 1);
        vm.prank(admin);
        defi.closeIncident();
        assertEq(defi.activeIncidentId(), 0);
    }

    // ════════════════════ TEE-signed settlement ════════════════════

    uint256 constant TEE_PK = 0x7EE;

    /// @dev Per-pool payout caps aligned to the current pool set — the max each pool
    ///      may commit, which always satisfies settleIncident's per-pool cap check.
    function _pp() internal view returns (uint256[] memory pp) {
        (, address[] memory poolAddrs) = authority.pools();
        pp = new uint256[](poolAddrs.length);
        for (uint256 i = 0; i < poolAddrs.length; i++) {
            pp[i] = SingleAssetCoverPool(poolAddrs[i]).maxPayoutPerIncident();
        }
    }

    /// @dev EIP-712 digest for Settlement over the incident's CURRENT on-chain
    ///      unresolved count and committed per-pool payouts — mirrors settleIncident.
    function _settlementDigest(uint256 incidentId, bytes32 root, uint256[] memory pp) internal view returns (bytes32) {
        (,,, uint256 unresolved,,,,) = defi.incidents(incidentId);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("DefiInsurance")),
                keccak256(bytes("1")),
                block.chainid,
                address(defi)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Settlement(uint256 incidentId,bytes32 root,uint256 unresolved,uint256[] poolPayouts)"),
                incidentId,
                root,
                unresolved,
                keccak256(abi.encodePacked(pp))
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _teeSign(uint256 incidentId, bytes32 root, uint256[] memory pp) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEE_PK, _settlementDigest(incidentId, root, pp));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Finalize a single-claim incident as its owner. The incident's root was
    ///      settled as that claim's leaf, so a single leaf's merkle root == the leaf
    ///      and the proof is empty.
    function _finalize(uint256 claimId, uint256[] memory amounts, uint256 scoreSpent) internal {
        (address user,,,,,) = defi.claims(claimId);
        vm.prank(user);
        defi.finalizeClaim(claimId, amounts, scoreSpent, new bytes32[](0));
    }

    /// @dev EIP-712 IncidentOpen signature over (token, referenceBlock,
    ///      nextIncidentId) — mirrors openIncidentSigned.
    function _teeSignOpen(address token, uint64 referenceBlock) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("DefiInsurance")),
                keccak256(bytes("1")),
                block.chainid,
                address(defi)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("IncidentOpen(address insuredToken,uint64 referenceBlock,uint256 incidentId)"),
                token,
                referenceBlock,
                defi.nextIncidentId()
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEE_PK, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Open an incident on token via the TEE-signed path. teeSigner set in setUp.
    function _openSigned(address token, uint64 referenceBlock) internal returns (uint256) {
        return defi.openIncidentSigned(IERC20(token), referenceBlock, _teeSignOpen(token, referenceBlock));
    }

    /// @dev L5: the settlement signer can't be rotated while an incident is live,
    ///      so the authority that was current at open is the one that settles it.
    function test_SetTeeSignerBlockedDuringIncident() public {
        _registerClaim(bob, lp1, 50e18); // opens incident 1

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.IncidentsActive.selector));
        defi.setTeeSigner(vm.addr(0xBEEF));

        // Once the incident voids, rotation is allowed again.
        vm.warp(block.timestamp + 4 days + 3 days + 1); // past claim + submit window
        vm.prank(admin);
        defi.setTeeSigner(vm.addr(0xBEEF));
        assertEq(defi.teeSigner(), vm.addr(0xBEEF));
    }

    function test_SettleIncidentSignedByAnyone() public {
        vm.prank(admin);
        defi.setTeeSigner(vm.addr(TEE_PK));
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);

        bytes32 root = _leaf(1, cid, bob, _amounts(0));
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root, pp);
        vm.prank(carol); // permissionless relay
        defi.settleIncident(1, root, pp, sig);
        (,, bytes32 stored,,,,,) = defi.incidents(1);
        assertEq(stored, root);
    }

    function test_SettleSignedWrongSignerReverts() public {
        vm.prank(admin);
        defi.setTeeSigner(vm.addr(0xBAD));
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);
        bytes32 root = bytes32(uint256(1));
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root, pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.UnauthorizedSettlementSigner.selector, vm.addr(TEE_PK)));
        defi.settleIncident(1, root, pp, sig);
    }

    function test_SettleSignedDisabledWhenSignerUnset() public {
        vm.prank(admin);
        defi.setTeeSigner(address(0)); // disable the signed path
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);
        bytes32 root = bytes32(uint256(1));
        uint256[] memory pp = _pp();
        bytes memory sig = _teeSign(1, root, pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.UnauthorizedSettlementSigner.selector, vm.addr(TEE_PK)));
        defi.settleIncident(1, root, pp, sig);
    }

    /// @dev The signature binds the exact claim set: a root signed before a
    ///      later join (different unresolved count) can never land.
    function test_SettleSignedBindsClaimSet() public {
        vm.prank(admin);
        defi.setTeeSigner(vm.addr(TEE_PK));
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        bytes32 root = _leaf(1, cid, bob, _amounts(0));
        uint256[] memory pp = _pp();
        bytes memory staleSig = _teeSign(1, root, pp); // signed over unresolved == 1

        _registerClaim(carol, lp1, 10e18); // claim set grows
        vm.warp(block.timestamp + 4 days + 1);
        vm.expectPartialRevert(DefiInsurance.UnauthorizedSettlementSigner.selector);
        defi.settleIncident(1, root, pp, staleSig);
    }

    // ════════════════════ Finalize ════════════════════

    function test_FinalizeSingleClaim() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory amounts = _amounts(20e6);
        bytes32 root = _leaf(1, cid, bob, amounts);
        _settle(1, root);

        // Not open during the dispute period.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(cid, amounts, 0, new bytes32[](0));

        vm.warp(block.timestamp + 4 days + 1);
        _finalize(cid, amounts, 0);

        assertEq(usdc.balanceOf(bob), 20e6);
        assertEq(pool.totalAssets(), 80e6);
        // Forfeited insured tokens stay in the contract as unaccounted revenue.
        assertEq(lp1.balanceOf(address(defi)), 50e18);
    }

    function test_FinalizeTwoClaimantsMerkle() public {
        _stake(alice, 300e6);
        uint256 cb = _registerClaim(bob, lp1, 50e18);
        uint256 cc = _registerClaim(carol, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory amountsBob = _amounts(40e6);
        uint256[] memory amountsCarol = _amounts(20e6);
        // Two-leaf merkle tree; each claimant finalizes with the sibling as proof.
        bytes32 leafBob = _leaf(1, cb, bob, amountsBob);
        bytes32 leafCarol = _leaf(1, cc, carol, amountsCarol);
        _settle(1, _hashPair(leafBob, leafCarol));
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
        assertEq(pool.totalAssets(), 240e6);
    }

    /// @dev F1: on an honest root the committed budget == Σ leaf amounts, so the
    ///      per-incident draw-down lands exactly at 0 and BOTH claims finalize — no
    ///      last-finalizer stranding.
    function test_FinalizeBudgetExactSumAllFinalize() public {
        _stake(alice, 300e6); // cap = 240e6
        uint256 cb = _registerClaim(bob, lp1, 50e18);
        uint256 cc = _registerClaim(carol, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory aB = _amounts(40e6);
        uint256[] memory aC = _amounts(40e6);
        bytes32 lB = _leaf(1, cb, bob, aB);
        bytes32 lC = _leaf(1, cc, carol, aC);
        bytes32 root = _hashPair(lB, lC);
        uint256[] memory pp = new uint256[](1);
        pp[0] = 80e6; // == 40 + 40, the exact leaf sum
        defi.settleIncident(1, root, pp, _teeSign(1, root, pp));
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory pB = new bytes32[](1);
        pB[0] = lC;
        vm.prank(bob);
        defi.finalizeClaim(cb, aB, 0, pB);
        bytes32[] memory pC = new bytes32[](1);
        pC[0] = lB;
        vm.prank(carol);
        defi.finalizeClaim(cc, aC, 0, pC);

        assertEq(usdc.balanceOf(bob), 40e6);
        assertEq(usdc.balanceOf(carol), 40e6);
    }

    /// @dev F1: a malformed root whose leaves over-allocate a pool (Σ 80e6 >
    ///      committed 50e6) can't drain past the committed budget — the early claim
    ///      pays, the draw-down hard-caps the pool's total loss at 50e6, and the
    ///      claim that would cross it reverts (recovers escrow, doesn't get paid).
    function test_FinalizeBudgetCapsCumulativePayout() public {
        _stake(alice, 300e6); // cap = 240e6, so 50e6 committed passes settle
        uint256 cb = _registerClaim(bob, lp1, 50e18);
        uint256 cc = _registerClaim(carol, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        uint256[] memory aB = _amounts(40e6);
        uint256[] memory aC = _amounts(40e6);
        bytes32 lB = _leaf(1, cb, bob, aB);
        bytes32 lC = _leaf(1, cc, carol, aC);
        bytes32 root = _hashPair(lB, lC);
        uint256[] memory pp = new uint256[](1);
        pp[0] = 50e6; // committed BELOW the 80e6 leaf sum — a bad root
        defi.settleIncident(1, root, pp, _teeSign(1, root, pp));
        vm.warp(block.timestamp + 4 days + 1);

        bytes32[] memory pB = new bytes32[](1);
        pB[0] = lC;
        vm.prank(bob);
        defi.finalizeClaim(cb, aB, 0, pB); // budget 50e6 -> 10e6

        bytes32[] memory pC = new bytes32[](1);
        pC[0] = lB;
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.PayoutCapExceeded.selector, 0, 40e6, 10e6));
        defi.finalizeClaim(cc, aC, 0, pC); // 40e6 > 10e6 remaining

        assertEq(usdc.balanceOf(bob), 40e6); // early claim paid
        assertEq(usdc.balanceOf(carol), 0); // late claim capped out; recovers escrow later
        assertEq(pool.totalAssets(), 260e6); // pool lost only 40e6, never past the 50e6 budget
    }

    function test_FinalizeWrongAmountsReverts() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(40e6)));
        vm.warp(block.timestamp + 4 days + 1);

        // Root commits to 40e6 (single leaf); finalizing 90e6 fails the merkle check.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.InvalidProof.selector, cid));
        defi.finalizeClaim(cid, _amounts(90e6), 0, new bytes32[](0));
    }

    function test_FinalizeTwiceReverts() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);

        _finalize(cid, amounts, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.ClaimAlreadyResolved.selector, cid));
        defi.finalizeClaim(cid, amounts, 0, new bytes32[](0));
    }

    function test_PayoutExceedingPoolBalanceReverts() public {
        // Root says pay 500 USDC but the pool only holds 100 (cap = 80). An honest
        // root never over-allocates, so this is a corrupt root: the per-incident
        // budget draw-down catches it first and fails the finalize loudly — bob
        // recovers his escrow via withdrawNonFinalizedClaim. (_settle commits
        // poolPayouts = maxPayoutPerIncident() = 80e6 via _pp.)
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(500e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);

        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.PayoutCapExceeded.selector, 0, 500e6, 80e6));
        vm.prank(bob);
        defi.finalizeClaim(cid, amounts, 0, new bytes32[](0));

        // Escrow recoverable once the finalize window lapses.
        vm.warp(block.timestamp + 4 days + 4 days + 1);
        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
        assertEq(lp1.balanceOf(bob), 50e18);
        assertEq(pool.totalAssets(), 100e6); // pool untouched
    }

    function test_StakeBlockedDuringIncidentThenResumes() public {
        _stake(alice, 100e6);
        _registerClaim(bob, lp1, 50e18); // opens incident 1

        usdc.mint(carol, 100e6);
        vm.startPrank(carol);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(SingleAssetCoverPool.PoolFrozen.selector);
        pool.stake(100e6);
        vm.stopPrank();

        // Incident voids after the dispute period -> staking reopens.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(carol);
        pool.stake(100e6);
        assertGt(pool.userShares(carol), 0);
    }

    /// @dev Finalizing the last claim unlocks the pool immediately.
    function test_AllClaimsFinalizedUnlocksPoolEarly() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18); // incident 1, one claim
        vm.warp(block.timestamp + 4 days + 1); // claim window ends
        _settle(1, _leaf(1, cid, bob, _amounts(40e6)));

        vm.warp(block.timestamp + 4 days + 1); // into the finalize window
        _finalize(cid, _amounts(40e6), 0);

        // Last claim finalized: incident inactive well before FINALIZE_WINDOW ends.
        assertFalse(defi.incidentActive());
        usdc.mint(carol, 100e6);
        vm.startPrank(carol);
        usdc.approve(address(pool), 100e6);
        pool.stake(100e6); // no PoolFrozen revert
        vm.stopPrank();
        assertGt(pool.userShares(carol), 0);
    }

    // This test contract acts as a payout module in a few tests; it must answer
    // incidentActive() (false = pool not frozen, so staking stays open).
    function incidentActive() external pure returns (bool) {
        return false;
    }

    function test_PayClaimOnlyByModule() public {
        _stake(alice, 100e6);
        // bob is not the registered payout module.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SingleAssetCoverPool.NotPayoutModule.selector, bob));
        pool.payClaim(address(0xdead), 10e6);
    }

    /// @dev L-d: payClaim to the pool itself is rejected (would silently convert
    ///      staker principal into sweepable surplus).
    function test_PayClaimRejectsPoolAsRecipient() public {
        _stake(alice, 100e6);
        vm.prank(admin);
        authority.setPayoutModule(address(this));
        vm.expectRevert(SingleAssetCoverPool.InvalidRecipient.selector);
        pool.payClaim(address(pool), 10e6);
    }

    /// @dev L-a: pausing DefiInsurance blocks claim intake, but escrow recovery
    ///      (withdrawNonFinalizedClaim) must stay open so a pause can't trap funds.
    function test_DefiPauseBlocksIntakeNotEscrowRecovery() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18); // opens incident 1, bob escrows
        vm.prank(admin);
        authority.setPaused(address(defi), true);

        // Intake blocked.
        lp1.mint(carol, 50e18);
        vm.startPrank(carol);
        lp1.approve(address(defi), 50e18);
        vm.expectRevert(Registry.Paused.selector);
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, 0);
        vm.stopPrank();

        // Void the incident, then recover escrow despite the pause.
        vm.warp(block.timestamp + 4 days + 3 days + 1); // past SUBMIT_DEADLINE → VOID
        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
        assertEq(lp1.balanceOf(bob), 50e18);
    }

    function test_FullyDrainedAssetStaysStakeable() public {
        _stake(alice, 100e6); // 100e6 shares, 1:1

        // Drain usdc to exactly zero via a payout, leaving alice's shares outstanding.
        // This contract becomes the single payout module (incidentActive()==false,
        // so the pool isn't frozen and staking stays open).
        vm.prank(admin);
        authority.setPayoutModule(address(this));
        pool.payClaim(address(0xdead), 100e6);
        assertEq(pool.totalAssets(), 0);
        assertGt(pool.totalShares(), 0);

        // Recapitalization must not revert (would div-by-zero pre-fix). New staker
        // mints received * totalShares and recovers ~everything; dead shares keep <1 wei.
        uint256 minted = _stake(carol, 50e6);
        assertEq(minted, 50e6 * 100e6);

        vm.startPrank(carol);
        pool.requestUnstake(minted);
        vm.warp(block.timestamp + 7 days + 1);
        uint256 out = pool.completeUnstake();
        vm.stopPrank();
        assertEq(out, 50e6 - 1); // ≤1-wei rounding crumb to the dead shares
    }

    /// @dev payClaim can't pay more than the pool holds; the per-incident cap is
    ///      enforced up front at settle (see test_SettleRejectsPayoutAboveCap), not here.
    function test_PayClaimCannotExceedBalance() public {
        _stake(alice, 100e6);
        vm.prank(admin);
        authority.setPayoutModule(address(this));

        vm.expectRevert(abi.encodeWithSelector(SingleAssetCoverPool.PayoutExceedsPoolAssets.selector, 101e6, 100e6));
        pool.payClaim(address(0xdead), 101e6);

        pool.payClaim(address(0xdead), 100e6);
        assertEq(pool.totalAssets(), 0);
    }

    /// @dev maxPayoutPerIncident = balance × Registry.maxPayoutBps / 10_000, and it
    ///      tracks a live bps update.
    function test_MaxPayoutPerIncidentView() public {
        _stake(alice, 100e6); // setUp bps = 8000
        assertEq(pool.maxPayoutPerIncident(), 80e6);
        vm.prank(admin);
        authority.setMaxPayoutBps(5000);
        assertEq(pool.maxPayoutPerIncident(), 50e6);
    }

    /// @dev settleIncident rejects a per-pool committed total above the pool's cap,
    ///      bounding LP loss per incident; at the cap it settles.
    function test_SettleRejectsPayoutAboveCap() public {
        _stake(alice, 100e6); // cap = 80e6 at bps 8000
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 4 days + 1);
        bytes32 root = _leaf(1, cid, bob, _amounts(80e6));

        uint256[] memory pp = new uint256[](1);
        pp[0] = 80e6 + 1;
        bytes memory sig = _teeSign(1, root, pp);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.PayoutCapExceeded.selector, 0, 80e6 + 1, 80e6));
        defi.settleIncident(1, root, pp, sig);

        pp[0] = 80e6;
        sig = _teeSign(1, root, pp);
        defi.settleIncident(1, root, pp, sig);
        (,, bytes32 stored,,,,,) = defi.incidents(1);
        assertEq(stored, root);
    }

    /// @dev The one-time permanent seed locks shares to the burn sink, so the pool
    ///      always has stakers — a profit distribution never reverts
    ///      {NoEligibleStakers} (L3) — and it can't be re-supplied.
    function test_SeedLocksSharesAndEnablesDistribution() public {
        SingleAssetCoverPool p = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize, (authority, IERC20(address(usdc)), IERC20(address(usd8)))
                    )
                )
            )
        );

        usdc.mint(address(this), 100e6);
        usdc.approve(address(p), type(uint256).max);

        p.seed(10e6);
        assertEq(p.totalShares(), 10e6);
        assertEq(p.totalAssets(), 10e6);
        assertEq(p.userShares(address(0xdEaD)), 10e6);
        assertTrue(p.seeded());

        vm.expectRevert(SingleAssetCoverPool.AlreadySeeded.selector);
        p.seed(10e6);

        // Only the locked seed is present, yet distribution streams (no revert).
        vm.startPrank(admin);
        usd8.mint(admin, 5e18);
        usd8.approve(address(p), 5e18);
        p.receiveProfitDistribution(5e18);
        vm.stopPrank();
        assertEq(usd8.balanceOf(address(p)), 5e18);
    }

    /// @dev When the stake asset IS the reward token, {_sweepable} must protect
    ///      staked principal AND committed rewards (their sum), not just one.
    function test_SweepProtectsPrincipalWhenAssetIsRewardToken() public {
        SingleAssetCoverPool p = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize, (authority, IERC20(address(usd8)), IERC20(address(usd8)))
                    )
                )
            )
        );

        p.seed(0); // zero-seed: open the gate, no locked shares

        // 100 principal + 5 committed rewards = 105 accounted; nothing sweepable.
        vm.prank(admin);
        usd8.mint(alice, 100e18);
        vm.startPrank(alice);
        usd8.approve(address(p), 100e18);
        p.stake(100e18);
        vm.stopPrank();

        vm.startPrank(admin);
        usd8.mint(admin, 5e18);
        usd8.approve(address(p), 5e18);
        p.receiveProfitDistribution(5e18);
        vm.expectRevert(abi.encodeWithSelector(Managed.NothingToSweep.selector, address(usd8)));
        p.sweepToken(IERC20(address(usd8)), carol);

        // Only a stray surplus above the 105 accounted is sweepable.
        usd8.mint(address(p), 7e18);
        p.sweepToken(IERC20(address(usd8)), carol);
        vm.stopPrank();
        assertEq(usd8.balanceOf(carol), 7e18);
        assertEq(usd8.balanceOf(address(p)), 105e18);
    }

    function test_AdminSweepsForfeitedInsuredTokens() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);
        _finalize(cid, amounts, 0);

        // Forfeited insured tokens are now unaccounted protocol revenue, sweepable.
        vm.prank(admin);
        defi.sweepToken(IERC20(address(lp1)), carol);
        assertEq(lp1.balanceOf(carol), 50e18);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Managed.NothingToSweep.selector, address(lp1)));
        defi.sweepToken(IERC20(address(lp1)), carol);
    }

    function test_SweepStrayStakeAssetExcessOnly() public {
        _stake(alice, 100e6);
        // Someone blindly transfers 50 USDC to the pool (not staked).
        usdc.mint(address(this), 50e6);
        usdc.transfer(address(pool), 50e6);

        // Staked principal (100) is untouchable; only the 50 stray is swept.
        vm.prank(admin);
        pool.sweepToken(IERC20(address(usdc)), carol);
        assertEq(usdc.balanceOf(carol), 50e6);
        assertEq(pool.totalAssets(), 100e6); // principal intact
    }

    function test_SweepRewardTokenStrayRecoverable() public {
        // No rewards committed -> blindly-sent USD8 is fully recoverable.
        vm.prank(admin);
        usd8.mint(address(this), 10e18);
        usd8.transfer(address(pool), 10e18);
        vm.prank(admin);
        pool.sweepToken(IERC20(address(usd8)), carol);
        assertEq(usd8.balanceOf(carol), 10e18);
    }

    function test_SweepRewardTokenProtectsCommittedReserve() public {
        _stake(alice, 100e6);
        _notify(50e18); // 50 USD8 committed to rewards
        vm.prank(admin);
        usd8.mint(address(this), 10e18);
        usd8.transfer(address(pool), 10e18); // 10 stray on top

        // Only the 10 stray is swept; the 50 reserve is protected.
        vm.prank(admin);
        pool.sweepToken(IERC20(address(usd8)), carol);
        assertEq(usd8.balanceOf(carol), 10e18);
        // Nothing stray left: the committed reserve is not sweepable.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Managed.NothingToSweep.selector, address(usd8)));
        pool.sweepToken(IERC20(address(usd8)), carol);
    }

    function test_SweepBlockedDuringIncidentThenSweepsStray() public {
        _registerClaim(bob, lp1, 50e18); // 50 lp1 escrowed, opens incident
        lp1.mint(address(this), 30e18);
        lp1.transfer(address(defi), 30e18); // 30 lp1 stray

        // Sweeping the incident's token is blocked while it's live (cap is 0).
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Managed.NothingToSweep.selector, address(lp1)));
        defi.sweepToken(IERC20(address(lp1)), carol);

        // Bob's escrow is fully recoverable.
        vm.prank(bob);
        defi.cancelClaim();
        assertEq(lp1.balanceOf(bob), 50e18);

        // Once the incident resolves, only the 30 stray is swept.
        vm.warp(block.timestamp + 4 days + 3 days + 1);
        vm.prank(admin);
        defi.sweepToken(IERC20(address(lp1)), carol);
        assertEq(lp1.balanceOf(carol), 30e18);
    }

    // ════════════════════ Boosters & score ════════════════════

    /// @dev Admin opens an incident on token; user joins committing qty
    ///      units of the canonical booster (id 1).
    function _openWithBooster(address user, MockERC20 token, uint128 amount, uint256 qty)
        internal
        returns (uint256 claimId)
    {
        token.mint(user, amount);
        booster.mint(user, defi.BOOSTER_ID(), qty);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(token)), uint64(block.number - 1));
        vm.startPrank(user);
        token.approve(address(defi), amount);
        booster.setApprovalForAll(address(defi), true);
        claimId = defi.joinClaim(IERC20(address(token)), amount, 0, qty);
        vm.stopPrank();
    }

    function test_BoosterCommittedNotEscrowedOnOpen() public {
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 3);
        // Not escrowed: boosters stay in the claimant's wallet, only recorded.
        assertEq(booster.balanceOf(bob, 1), 3);
        assertEq(booster.balanceOf(address(defi), 1), 0);
        assertEq(defi.getClaimBoosterAmount(cid), 3);
    }

    function test_BoosterBurnedOnFinalize() public {
        _stake(alice, 100e6);
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 3);
        assertEq(booster.totalSupply(1), 3);

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);
        _finalize(cid, amounts, 0);

        assertEq(booster.balanceOf(bob, 1), 0); // burned from the claimant
        assertEq(booster.totalSupply(1), 0); // real burn reduced supply
        assertEq(defi.getClaimBoosterAmount(cid), 0);
    }

    function test_FinalizeRevertsIfBoostersMissing() public {
        _stake(alice, 100e6);
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 3);

        // Bob moves his committed boosters away before finalize; the burn — and
        // thus the whole finalize — reverts. Keeping them is his responsibility.
        vm.prank(bob);
        booster.safeTransferFrom(bob, carol, 1, 3, "");

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);
        vm.prank(bob);
        vm.expectRevert();
        defi.finalizeClaim(cid, amounts, 0, new bytes32[](0));
    }

    /// @dev A claim that spends score emits ScoreSpent on finalize (the ledger is
    ///      now the event log, not on-chain state).
    function test_ScoreSpentEmittedOnFinalize() public {
        _stake(alice, 100e6);
        // Bob joins requesting to spend 500 score (the off-chain caps to his
        // available; here the settlement just attests scoreSpent in the leaf).
        lp1.mint(bob, 50e18);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        uint256 cid = defi.joinClaim(IERC20(address(lp1)), 50e18, 500, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6);
        _settle(1, _leafSpent(1, cid, bob, amounts, 500));
        vm.warp(block.timestamp + 4 days + 1);

        vm.expectEmit(true, true, false, true, address(defi));
        emit DefiInsurance.ScoreSpent(bob, 500, 1);
        vm.prank(bob);
        defi.finalizeClaim(cid, amounts, 500, new bytes32[](0));
    }

    function test_BoosterUntouchedOnCancel() public {
        _openWithBooster(bob, lp1, 50e18, 3);
        vm.prank(bob);
        defi.cancelClaim();
        // Never escrowed, so nothing to return — bob simply kept them throughout.
        assertEq(booster.balanceOf(bob, 1), 3);
    }

    function test_BoosterUntouchedOnWithdraw() public {
        uint256 cid = _openWithBooster(bob, lp1, 50e18, 3);
        // Void: no root through the dispute period.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(bob);
        defi.withdrawNonFinalizedClaim(cid);
        assertEq(booster.balanceOf(bob, 1), 3);
    }

    function test_SetBoosterNFTBlockedDuringIncident() public {
        _registerClaim(bob, lp1, 50e18); // opens an incident -> system frozen
        vm.prank(admin);
        vm.expectRevert(Registry.Frozen.selector);
        authority.setBoosterNFT(address(0xBEEF));

        // Resolves after the dispute period -> setting reopens.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(admin);
        authority.setBoosterNFT(address(0xBEEF));
        assertEq(authority.boosterNFT(), address(0xBEEF));
    }

    function test_BoosterCommitRequiresNftSet() public {
        vm.prank(admin);
        authority.setBoosterNFT(address(0));

        booster.mint(bob, 1, 1);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp1)), uint64(block.number - 1));
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(defi), 50e18);
        booster.setApprovalForAll(address(defi), true);
        vm.expectRevert(DefiInsurance.BoosterNFTUnset.selector);
        defi.joinClaim(IERC20(address(lp1)), 50e18, 0, 1);
        vm.stopPrank();
    }

    // ════════════════════ Loss socialization & staker lock ════════════════════

    function test_LossSocializedAcrossStakers() public {
        _stake(alice, 100e6);
        _stake(carol, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 100e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(80e6);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 4 days + 1);
        _finalize(cid, amounts, 0);

        // 200 -> 120 USDC backing the same shares; both stakers diluted equally.
        vm.warp(block.timestamp + 5 days + 1); // finalize window over, queue clears
        uint256 aliceOut = _completeUnstakeAfterCooldown(alice, 100e6);
        assertEq(aliceOut, 60e6);
    }

    function test_UnstakeBlockedThroughPhasesThenUnblocks() public {
        _stake(alice, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.prank(alice);
        pool.requestUnstake(50e6);

        // During the claim window the 7-day cooldown is the binding gate.
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.CooldownNotElapsed.selector);
        pool.completeUnstake();

        // Settle within the submit window (t = 6d+1; dispute ends 10d+1).
        vm.warp(block.timestamp + 4 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(10e6)));

        // Cooldown (7d) has now elapsed, but the incident is still in its
        // dispute window -> withdrawal stays blocked (t = 8d+1).
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.PoolFrozen.selector);
        pool.completeUnstake();

        // Past the dispute window (t = 10d+2): Bob finalizes -> all claims resolved
        // -> pool unfrozen. But the incident outlasted the request's completion
        // window (7d cooldown + 2d), so the original request has expired.
        vm.warp(block.timestamp + 2 days + 1);
        _finalize(cid, _amounts(10e6), 0);

        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.UnstakeWindowExpired.selector);
        pool.completeUnstake();

        // Alice re-requests and waits a fresh cooldown to exit.
        vm.prank(alice);
        pool.requestUnstake(50e6);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        pool.completeUnstake();
    }

    function test_UnstakeUnblocksAfterVoidIncident() public {
        _stake(alice, 100e6);
        _registerClaim(bob, lp1, 50e18);

        vm.prank(alice);
        pool.requestUnstake(50e6);

        // No root ever submitted: void at windowEnd + submit deadline (t = 9d+1),
        // which also outlasts the request's completion window -> it has expired.
        vm.warp(block.timestamp + 5 days + 4 days + 1);
        vm.prank(alice);
        vm.expectRevert(SingleAssetCoverPool.UnstakeWindowExpired.selector);
        pool.completeUnstake();

        // Pool is unfrozen (void); a fresh request completes after its cooldown.
        vm.prank(alice);
        pool.requestUnstake(50e6);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        pool.completeUnstake();
    }

    function test_UnstakeUnblocksAfterSoleClaimCancelled() public {
        _stake(alice, 100e6);
        _registerClaim(bob, lp1, 50e18);

        vm.prank(alice);
        pool.requestUnstake(50e6);

        // Bob cancels the only claim while the window is open.
        vm.prank(bob);
        defi.cancelClaim();

        // Cooldown (7d) elapsed and the window (5d) has closed with every claim
        // resolved: the incident is inactive WITHOUT waiting out the dispute
        // period (which would end at 8d). t = 7d+1.
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        pool.completeUnstake();
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
        _stake(alice, 200e6);
        uint256 c1 = _registerClaim(bob, lp1, 50e18);

        // Settle + finalize incident 1 fully.
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory a1 = _amounts(40e6);
        _settle(1, _leaf(1, c1, bob, a1));
        vm.warp(block.timestamp + 4 days + 1);
        _finalize(c1, a1, 0);

        // Incident 1 inactive -> a fresh incident can open on lp2 and runs
        // its full settlement window off its own clock.
        uint256 c2 = _registerClaim(carol, lp2, 30e18);
        assertEq(defi.activeIncidentId(), 2);

        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root2 = _leaf(2, c2, carol, _amounts(10e6));
        _settle(2, root2);
        vm.warp(block.timestamp + 4 days + 1);
        _finalize(c2, _amounts(10e6), 0);
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

    // ════════════════════ Roles ════════════════════

    function test_RoleTransfersAndGating() public {
        // Distinct fast admin; timelock keeps config + role assignment.
        address fastAdmin = address(0xFA57);
        vm.prank(admin);
        authority.setAdmin(fastAdmin, true);
        assertTrue(authority.isAdmin(fastAdmin));

        // Fast admin can run reward ops (the emission window) but not curate.
        vm.prank(fastAdmin);
        pool.setRewardsDuration(14 days);
        assertEq(pool.rewardsDuration(), 14 days);

        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, fastAdmin));
        vm.prank(fastAdmin);
        defi.setMaxCoverageBps(IERC20(address(lp1)), 7000);

        // Timelock handover; old timelock loses config access.
        address newTimelock = address(0x71E);
        vm.prank(admin);
        authority.setTimelock(newTimelock);
        assertEq(authority.timelock(), newTimelock);

        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, admin));
        vm.prank(admin);
        authority.setScoredToken(IERC20(address(usd8)), 1, 0);
    }

    function test_CompleteUnstakeLeavesYieldClaimable() public {
        // completeUnstake checkpoints yield but does NOT pay it: claiming is a
        // separate action, and a full exit must not strand the accrued USD8.
        _stake(alice, 100e6);
        _notify(70e18);
        vm.warp(block.timestamp + 7 days + 1); // full window earned

        uint256 aliceShares = pool.userShares(alice);
        vm.startPrank(alice);
        pool.requestUnstake(aliceShares);
        vm.warp(block.timestamp + 7 days + 1);
        pool.completeUnstake();
        assertEq(usd8.balanceOf(alice), 0); // principal only, no auto-claim

        uint256 got = pool.withdrawYield();
        vm.stopPrank();
        assertApproxEqAbs(got, 70e18, 1e7); // still fully claimable after exit
    }

    function test_DeferredEmissionSurvivesEmptyBase() public {
        // Carry-forward regression: if every staker fully exits mid-stream, the
        // undripped emission must defer and re-stream to the next staker rather
        // than strand in rewardReserve.
        vm.prank(admin);
        pool.setRewardsDuration(30 days);
        _stake(alice, 100e6);
        _notify(70e18); // 70 over 30 days

        // Alice exits fully after the 7-day cooldown -> base empties with ~23 days
        // of emission still undripped.
        uint256 aliceShares = pool.userShares(alice);
        vm.prank(alice);
        pool.requestUnstake(aliceShares);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        pool.completeUnstake();

        // Long gap with a zero base, then a new staker arrives (its checkpoint
        // defers the gap), then run past the extended finish.
        vm.warp(block.timestamp + 60 days);
        _stake(carol, 50e6);
        vm.warp(block.timestamp + 60 days);

        vm.prank(alice);
        uint256 aliceGot = pool.withdrawYield();
        vm.prank(carol);
        uint256 carolGot = pool.withdrawYield();
        // Nothing stranded: the full 70 is paid across the two earning intervals.
        assertApproxEqAbs(aliceGot + carolGot, 70e18, 1e13);
    }

    // ════════════════════ Emergency pause ════════════════════

    function test_PauseGatesValueMovingEntrypoints() public {
        _stake(alice, 100e6);
        _notify(70e18);
        vm.warp(block.timestamp + 1 days);
        uint256 aliceShares = pool.userShares(alice);
        vm.prank(alice);
        pool.requestUnstake(aliceShares);
        vm.warp(block.timestamp + 7 days + 1);

        // Pause: admin or timelock may toggle; a non-role caller cannot.
        vm.expectRevert(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, bob));
        vm.prank(bob);
        authority.setPaused(address(pool), true);
        vm.prank(admin);
        authority.setPaused(address(pool), true);
        assertTrue(authority.paused(address(pool)));

        // All value-moving entrypoints revert while paused.
        usdc.mint(carol, 10e6);
        vm.startPrank(carol);
        usdc.approve(address(pool), 10e6);
        vm.expectRevert(Registry.Paused.selector);
        pool.stake(10e6);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(Registry.Paused.selector);
        pool.completeUnstake();
        vm.expectRevert(Registry.Paused.selector);
        pool.withdrawYield();
        vm.stopPrank();

        vm.startPrank(admin);
        usd8.mint(admin, 1e18);
        usd8.approve(address(pool), 1e18);
        vm.expectRevert(Registry.Paused.selector);
        pool.receiveProfitDistribution(1e18);
        vm.stopPrank();
        // payClaim is covered separately in test_PayClaimPausedReverts.
    }

    function test_PayClaimPausedReverts() public {
        _stake(alice, 100e6);
        vm.prank(admin);
        authority.setPayoutModule(address(this));
        vm.prank(admin);
        authority.setPaused(address(pool), true);
        vm.expectRevert(Registry.Paused.selector);
        pool.payClaim(address(0xdead), 10e6);
    }

    function test_UnpauseRestoresFlow() public {
        _stake(alice, 100e6);
        vm.prank(admin);
        authority.setPaused(address(pool), true);
        vm.prank(admin);
        authority.setPaused(address(pool), false);
        assertFalse(authority.paused(address(pool)));
        _stake(bob, 50e6); // works again
        assertGt(pool.userShares(bob), 0);
    }

    function test_DeregisterNeutralizesStuckModule() public {
        StuckModule m = new StuckModule();
        vm.prank(admin);
        authority.setPayoutModule(address(m)); // reports incidentActive() == true
        assertTrue(authority.frozen());

        // Worst case: the module starts reverting in incidentActive() — every
        // freeze-gated function would brick while it stays the module.
        m.setRevertMode(true);
        vm.expectRevert(bytes("dead"));
        authority.frozen();

        // Clearing the module to zero is the emergency brake: setPayoutModule(0)
        // skips the frozen() guard, so the stuck module is fully neutralized.
        vm.prank(admin);
        authority.setPayoutModule(address(0));
        assertFalse(authority.frozen());
        _stake(alice, 100e6); // pool usable again
    }
}

/// @dev A v2 implementation with a version() bump, to prove a beacon upgrade
///      re-points the proxy at new code while preserving storage.
contract SingleAssetCoverPoolV2 is SingleAssetCoverPool {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev A payout module gone wrong: reports an incident forever, and can be
///      switched to reverting outright.
contract StuckModule {
    bool revertMode;

    function setRevertMode(bool r) external {
        revertMode = r;
    }

    function incidentActive() external view returns (bool) {
        if (revertMode) revert("dead");
        return true;
    }
}
