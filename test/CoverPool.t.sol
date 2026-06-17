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
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract CoverPoolTest is Test {
    MockERC20 usdc;
    MockERC20 dai;
    MockERC20 wbtc;
    MockERC20 usd8;
    MockERC20 lp1; // insured token 1
    MockERC20 lp2; // insured token 2
    CoverPool pool;

    address admin = address(0xA11CE);
    address alice = address(0xBEEF);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    uint256 signerPk = 0xA11CE5169;
    address signer;

    uint64 constant DURATION = 7 days;

    // EIP-712 plumbing — must match the contract.
    bytes32 constant SETTLEMENT_TYPEHASH = keccak256("Settlement(uint256 incidentId,bytes32 root,bytes32 inputHash)");
    bytes32 constant OPEN_INCIDENT_TYPEHASH =
        keccak256("OpenIncident(address insuredToken,uint256 incidentId,uint64 deadline)");

    function setUp() public {
        signer = vm.addr(signerPk);

        usdc = new MockERC20("USDC", "USDC", 6);
        dai = new MockERC20("DAI", "DAI", 18);
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        usd8 = new MockERC20("USD8 mock", "USD8", 18);
        lp1 = new MockERC20("LP1", "LP1", 18);
        lp2 = new MockERC20("LP2", "LP2", 18);

        // No oracles anywhere: all pricing happens inside the TEE; the
        // contract only verifies the settlement root signature. Deployed
        // behind a UUPS proxy; admin doubles as timelock in tests.
        pool = _deployPool(IERC20(address(usd8)), admin, admin, DURATION);
        vm.startPrank(admin);
        pool.addAsset(IERC20(address(usdc)));
        pool.addAsset(IERC20(address(dai)));
        pool.addAsset(IERC20(address(wbtc)));
        pool.addInsuredToken(IERC20(address(lp1)), 8000);
        pool.addInsuredToken(IERC20(address(lp2)), 8000);
        pool.setTeeSigner(signer);
        vm.stopPrank();
    }

    // ────────────────────────── helpers ──────────────────────────

    /// @dev Deploy a CoverPool implementation behind a UUPS ERC1967 proxy.
    function _deployPool(IERC20 reward, address timelock_, address admin_, uint64 duration)
        internal
        returns (CoverPool)
    {
        CoverPool impl = new CoverPool();
        bytes memory initData = abi.encodeCall(CoverPool.initialize, (reward, timelock_, admin_, duration));
        return CoverPool(address(new ERC1967Proxy(address(impl), initData)));
    }

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

    /// @dev Open the incident with a TEE attestation if none is joinable for
    ///      the token, otherwise join signature-free. Keeps call sites simple.
    function _registerClaim(address user, MockERC20 insuredToken, uint128 amount) internal returns (uint256 claimId) {
        insuredToken.mint(user, amount);
        vm.prank(user);
        insuredToken.approve(address(pool), amount);

        if (_hasJoinableIncident(address(insuredToken))) {
            vm.prank(user);
            claimId = pool.registerClaim(IERC20(address(insuredToken)), amount);
        } else {
            uint64 deadline = uint64(block.timestamp + 1 days);
            bytes memory sig = _signOpen(address(insuredToken), pool.nextIncidentId(), deadline, signerPk);
            vm.prank(user);
            claimId = pool.openIncident(IERC20(address(insuredToken)), amount, deadline, sig);
        }
    }

    /// @dev True if the in-flight incident covers `token` and its claim
    ///      window is still open (i.e. a claim can join without opening).
    function _hasJoinableIncident(address token) internal view returns (bool) {
        uint256 active = pool.activeIncidentId();
        if (active == 0) return false;
        (IERC20 tok, uint64 wEnd,,,,) = pool.incidents(active);
        return address(tok) == token && block.timestamp <= wEnd;
    }

    /// @dev Sign an {OpenIncident} attestation as the TEE signer.
    function _signOpen(address token, uint256 incidentId, uint64 deadline, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(OPEN_INCIDENT_TYPEHASH, token, incidentId, deadline));
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signSettlement(uint256 incidentId, bytes32 root, uint256 pk) internal view returns (bytes memory) {
        (,,, bytes32 inputHash,,) = pool.incidents(incidentId);
        bytes32 structHash = keccak256(abi.encode(SETTLEMENT_TYPEHASH, incidentId, root, inputHash));
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev OZ standard double-hashed leaf over (incidentId, claimId, user,
    ///      amounts), amounts aligned to the incident's frozen asset list.
    function _leaf(uint256 incidentId, uint256 claimId, address user, uint256[] memory amounts)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(incidentId, claimId, user, amounts))));
    }

    /// @dev OZ MerkleProof sorted-pair hash.
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Submit a TEE-signed root for `incidentId` (caller must have
    ///      warped past the claim window first).
    function _settle(uint256 incidentId, bytes32 root) internal {
        pool.settleIncident(incidentId, root, _signSettlement(incidentId, root, signerPk));
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
        assertEq(address(pool.rewardToken()), address(usd8));
        assertEq(pool.timelock(), admin);
        assertEq(pool.admin(), admin);
        assertEq(pool.rewardsDuration(), DURATION);
        assertEq(pool.teeSigner(), signer);
        assertEq(pool.assetListLength(), 3);
        assertEq(pool.insuredTokenListLength(), 2);
        assertEq(pool.nextClaimId(), 1);
        assertEq(pool.nextIncidentId(), 1);
    }

    function test_InitializeRejectsZeroRewardToken() public {
        CoverPool impl = new CoverPool();
        bytes memory initData = abi.encodeCall(CoverPool.initialize, (IERC20(address(0)), admin, admin, DURATION));
        vm.expectRevert(CoverPool.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_InitializeRejectsZeroDuration() public {
        CoverPool impl = new CoverPool();
        bytes memory initData = abi.encodeCall(CoverPool.initialize, (IERC20(address(usd8)), admin, admin, 0));
        vm.expectRevert(CoverPool.InvalidRewardsDuration.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_ImplementationCannotBeInitialized() public {
        CoverPool impl = new CoverPool();
        vm.expectRevert(); // InvalidInitialization (impl initializers disabled)
        impl.initialize(IERC20(address(usd8)), admin, admin, DURATION);
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
        pool.addAsset(IERC20(address(usd8)));
    }

    function test_AddAssetRejectsInsuredToken() public {
        vm.prank(admin);
        vm.expectRevert(CoverPool.TokenConflict.selector);
        pool.addAsset(IERC20(address(lp1)));
    }

    function test_AddAssetDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.AssetAlreadyApproved.selector, IERC20(address(usdc))));
        pool.addAsset(IERC20(address(usdc)));
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

    // ════════════════════ Insured token management ════════════════════

    function test_AddInsuredTokenRejectsStakeAsset() public {
        vm.prank(admin);
        vm.expectRevert(CoverPool.TokenConflict.selector);
        pool.addInsuredToken(IERC20(address(usdc)), 8000);
    }

    function test_AddInsuredTokenRejectsRewardToken() public {
        vm.prank(admin);
        vm.expectRevert(CoverPool.TokenConflict.selector);
        pool.addInsuredToken(IERC20(address(usd8)), 8000);
    }

    function test_AddInsuredTokenDuplicateReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.InsuredTokenAlreadyApproved.selector, IERC20(address(lp1))));
        pool.addInsuredToken(IERC20(address(lp1)), 8000);
    }

    function test_AdminCanRemoveInsuredToken() public {
        vm.prank(admin);
        pool.removeInsuredToken(IERC20(address(lp2)));
        assertEq(pool.insuredTokenListLength(), 1);
        assertFalse(pool.insuredTokenApproved(IERC20(address(lp2))));
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
        _registerClaim(bob, lp1, 50e18);

        vm.prank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 100e6);
        vm.warp(block.timestamp + 7 days + 1);

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

    function test_NotifyRewardRevertsWhenAllUnstaking() public {
        _stake(alice, usdc, 100e6);
        vm.prank(alice);
        pool.requestUnstake(IERC20(address(usdc)), 100e6);

        usd8.mint(admin, 10e18);
        vm.startPrank(admin);
        usd8.approve(address(pool), 10e18);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.NoStakersForAsset.selector, IERC20(address(usdc))));
        pool.notifyReward(IERC20(address(usdc)), 10e18);
        vm.stopPrank();
    }

    // ════════════════════ Claim registration ════════════════════

    function test_RegisterClaimOpensIncidentAndDelists(// auto-delist on open
    ) public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        assertEq(cid, 1);
        (IERC20 tok, uint64 wEnd, bytes32 root,, uint256 claimCount,) = pool.incidents(1);
        assertEq(address(tok), address(lp1));
        assertEq(wEnd, uint64(block.timestamp) + 5 days);
        assertEq(root, bytes32(0));
        assertEq(claimCount, 1);
        assertEq(pool.activeIncidentId(), 1);
        assertFalse(pool.insuredTokenApproved(IERC20(address(lp1))));
        assertEq(lp1.balanceOf(address(pool)), 50e18);
    }

    function test_SecondClaimSameTokenJoinsIncident() public {
        _registerClaim(bob, lp1, 50e18);
        _registerClaim(carol, lp1, 30e18);
        (,,,, uint256 claimCount,) = pool.incidents(1);
        assertEq(claimCount, 2);
        assertEq(pool.nextIncidentId(), 2);
    }

    function test_OpenIncidentUnapprovedTokenReverts() public {
        MockERC20 lp3 = new MockERC20("LP3", "LP3", 18);
        lp3.mint(bob, 1e18);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _signOpen(address(lp3), pool.nextIncidentId(), deadline, signerPk);
        vm.startPrank(bob);
        lp3.approve(address(pool), 1e18);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.InsuredTokenNotApproved.selector, IERC20(address(lp3))));
        pool.openIncident(IERC20(address(lp3)), 1e18, deadline, sig);
        vm.stopPrank();
    }

    function test_RegisterClaimWithoutOpenIncidentReverts() public {
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(pool), 50e18);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.NoOpenIncident.selector, IERC20(address(lp1))));
        pool.registerClaim(IERC20(address(lp1)), 50e18);
        vm.stopPrank();
    }

    function test_OpenIncidentRejectsInvalidSignature() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory badSig = _signOpen(address(lp1), pool.nextIncidentId(), deadline, 0xBAD);
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(pool), 50e18);
        vm.expectRevert(CoverPool.InvalidSignature.selector);
        pool.openIncident(IERC20(address(lp1)), 50e18, deadline, badSig);
        vm.stopPrank();
    }

    function test_OpenIncidentRejectsExpiredAttestation() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _signOpen(address(lp1), pool.nextIncidentId(), deadline, signerPk);
        vm.warp(block.timestamp + 2 days); // past deadline
        lp1.mint(bob, 50e18);
        vm.startPrank(bob);
        lp1.approve(address(pool), 50e18);
        vm.expectRevert(CoverPool.OpenAttestationExpired.selector);
        pool.openIncident(IERC20(address(lp1)), 50e18, deadline, sig);
        vm.stopPrank();
    }

    function test_OpenAttestationCannotBeReplayed() public {
        // Deadline far enough out to survive the void warp below.
        uint64 deadline = uint64(block.timestamp + 30 days);
        bytes memory sig = _signOpen(address(lp1), 1, deadline, signerPk); // binds incidentId 1
        lp1.mint(bob, 100e18);
        vm.startPrank(bob);
        lp1.approve(address(pool), 100e18);
        pool.openIncident(IERC20(address(lp1)), 50e18, deadline, sig); // opens incident 1
        vm.stopPrank();

        // Void incident 1 and re-list lp1 so the one-at-a-time gate is clear.
        vm.warp(block.timestamp + 5 days + 3 days + 1);
        vm.prank(admin);
        pool.addInsuredToken(IERC20(address(lp1)), 8000);

        // The same attestation now resolves against incidentId 2 -> bad sig.
        vm.startPrank(bob);
        vm.expectRevert(CoverPool.InvalidSignature.selector);
        pool.openIncident(IERC20(address(lp1)), 50e18, deadline, sig);
        vm.stopPrank();
    }

    function test_ClaimAfterWindowReverts() public {
        _registerClaim(bob, lp1, 50e18);
        (, uint64 wEnd,,,,) = pool.incidents(1);
        vm.warp(wEnd + 1);

        lp1.mint(carol, 30e18);
        vm.startPrank(carol);
        lp1.approve(address(pool), 30e18);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.ClaimWindowClosed.selector, IERC20(address(lp1)), wEnd));
        pool.registerClaim(IERC20(address(lp1)), 30e18);
        vm.stopPrank();
    }

    function test_RelistedTokenOpensFreshIncident() public {
        _registerClaim(bob, lp1, 50e18);
        // Resolve incident 1 by void: no root, dispute period passes.
        vm.warp(block.timestamp + 5 days + 3 days + 1);

        vm.prank(admin);
        pool.addInsuredToken(IERC20(address(lp1)), 8000);
        uint256 cid = _registerClaim(carol, lp1, 30e18);
        (, uint256 incidentId,,,) = pool.claims(cid);
        assertEq(incidentId, 2);
        assertEq(pool.activeIncidentId(), 2);
    }

    // ════════════════════ Cancel & withdraw ════════════════════

    function test_CancelClaimDuringWindowRefunds() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.prank(bob);
        pool.cancelRegisteredClaim(cid);
        assertEq(lp1.balanceOf(bob), 50e18);
        (,,,,, uint256 resolvedCount) = pool.incidents(1);
        assertEq(resolvedCount, 1);
    }

    function test_CancelAfterWindowReverts() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        (, uint64 wEnd,,,,) = pool.incidents(1);
        vm.warp(wEnd + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.ClaimWindowClosed.selector, IERC20(address(lp1)), wEnd));
        pool.cancelRegisteredClaim(cid);
    }

    function test_CancelByNonOwnerReverts() public {
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.UnauthorizedClaim.selector, cid));
        pool.cancelRegisteredClaim(cid);
    }

    function test_WithdrawClaimAfterVoidIncident() public {
        // No root ever submitted -> incident void at windowEnd + 3d.
        uint256 cid = _registerClaim(bob, lp1, 50e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.ClaimNotWithdrawable.selector, cid));
        pool.withdrawNonFinalizedClaim(cid);

        vm.warp(block.timestamp + 5 days + 3 days + 1);
        vm.prank(bob);
        pool.withdrawNonFinalizedClaim(cid);
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
        vm.expectRevert(abi.encodeWithSelector(CoverPool.FinalizeNotOpen.selector, uint256(1)));
        pool.finalizeClaim(cid, _amounts(40e6, 0, 0), noProof);

        vm.prank(bob);
        pool.withdrawNonFinalizedClaim(cid);
        assertEq(lp1.balanceOf(bob), 50e18);
        // Payout portion stayed in the pool.
        assertEq(pool.totalAssets(IERC20(address(usdc))), 100e6);
    }

    // ════════════════════ Settlement (root) ════════════════════

    function test_SettleIncidentAcceptsSignedRoot() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);

        bytes32 root = _leaf(1, cid, bob, _amounts(40e6, 0, 0));
        _settle(1, root);

        (,, bytes32 storedRoot,,,) = pool.incidents(1);
        assertEq(storedRoot, root);
        // Stake-asset list frozen at settle for amounts[] alignment.
        IERC20[] memory frozen = pool.getIncidentAssets(1);
        assertEq(frozen.length, 3);
        assertEq(address(frozen[0]), address(usdc));
    }

    function test_SettleBeforeWindowEndReverts() public {
        _registerClaim(bob, lp1, 50e18);
        bytes32 root = bytes32(uint256(1));
        bytes memory sig = _signSettlement(1, root, signerPk);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.OutsideSettlementPhase.selector, uint256(1)));
        pool.settleIncident(1, root, sig);
    }

    function test_SettleAfterCutoffReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 2 days + 1);
        bytes32 root = bytes32(uint256(1));
        bytes memory sig = _signSettlement(1, root, signerPk);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.OutsideSettlementPhase.selector, uint256(1)));
        pool.settleIncident(1, root, sig);
    }

    function test_SettleWrongSignerReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root = bytes32(uint256(1));
        bytes memory sig = _signSettlement(1, root, 0xDEAD);
        vm.expectRevert(CoverPool.InvalidSignature.selector);
        pool.settleIncident(1, root, sig);
    }

    function test_SettleTwiceReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, bytes32(uint256(1)));
        bytes memory sig2 = _signSettlement(1, bytes32(uint256(2)), signerPk);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.RootAlreadySet.selector, uint256(1)));
        pool.settleIncident(1, bytes32(uint256(2)), sig2);
    }

    function test_VoidSettlementAndResubmit() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, bytes32(uint256(1)));

        // Non-role caller cannot void.
        vm.expectRevert(abi.encodeWithSelector(CoverPool.UnauthorizedAdmin.selector, alice));
        vm.prank(alice);
        pool.voidSettlement(1);

        // Fast brake: admin voids instantly.
        vm.prank(admin);
        pool.voidSettlement(1);
        (,, bytes32 root,,,) = pool.incidents(1);
        assertEq(root, bytes32(0));

        // Corrected root resubmitted within the cutoff.
        _settle(1, bytes32(uint256(2)));
        (,, root,,,) = pool.incidents(1);
        assertEq(root, bytes32(uint256(2)));
    }

    function test_SettleStaleInputHashReverts() public {
        // Signature computed over the table BEFORE carol joined must not
        // verify — the settlement is bound to the exact final claimant set.
        _registerClaim(bob, lp1, 50e18);
        (,,, bytes32 staleHash,,) = pool.incidents(1);
        _registerClaim(carol, lp1, 30e18);

        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root = bytes32(uint256(1));
        bytes32 structHash = keccak256(abi.encode(SETTLEMENT_TYPEHASH, uint256(1), root, staleHash));
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        vm.expectRevert(CoverPool.InvalidSignature.selector);
        pool.settleIncident(1, root, abi.encodePacked(r, s, v));
    }

    function test_VoidWithoutRootReverts() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.NoStandingRoot.selector, uint256(1)));
        pool.voidSettlement(1);
    }

    function test_RootImmutableAfterDisputePeriod() public {
        _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, bytes32(uint256(1)));
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.OutsideSettlementPhase.selector, uint256(1)));
        pool.voidSettlement(1);
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
        vm.expectRevert(abi.encodeWithSelector(CoverPool.FinalizeNotOpen.selector, uint256(1)));
        pool.finalizeClaim(cid, amounts, noProof);

        vm.warp(block.timestamp + 3 days);
        vm.prank(bob);
        pool.finalizeClaim(cid, amounts, noProof);

        assertEq(usdc.balanceOf(bob), 20e6);
        assertEq(dai.balanceOf(bob), 20e18);
        assertEq(pool.totalAssets(IERC20(address(usdc))), 80e6);
        assertEq(pool.totalAssets(IERC20(address(dai))), 80e18);
        assertEq(pool.forfeitedInsuredTokens(IERC20(address(lp1))), 50e18);
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
        vm.warp(block.timestamp + 3 days);

        bytes32[] memory proofBob = new bytes32[](1);
        proofBob[0] = leafCarol;
        vm.prank(bob);
        pool.finalizeClaim(cb, amountsBob, proofBob);

        bytes32[] memory proofCarol = new bytes32[](1);
        proofCarol[0] = leafBob;
        vm.prank(carol);
        pool.finalizeClaim(cc, amountsCarol, proofCarol);

        assertEq(usdc.balanceOf(bob), 40e6);
        assertEq(usdc.balanceOf(carol), 20e6);
        assertEq(pool.totalAssets(IERC20(address(usdc))), 240e6);
    }

    function test_FinalizeWrongAmountsReverts() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(40e6, 0, 0)));
        vm.warp(block.timestamp + 3 days);

        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.InvalidProof.selector, cid));
        pool.finalizeClaim(cid, _amounts(90e6, 0, 0), noProof);
    }

    function test_FinalizeTwiceReverts() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6, 0, 0);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 3 days);

        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        pool.finalizeClaim(cid, amounts, noProof);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.ClaimAlreadyResolved.selector, cid));
        pool.finalizeClaim(cid, amounts, noProof);
    }

    function test_PayoutClampedToPoolBalance() public {
        // Root says pay 500 USDC but the pool only holds 100 -> bob gets 100,
        // never more. Staking is frozen during the incident, so the balance
        // can't have grown past what the TEE computed against.
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(500e6, 0, 0);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 3 days);

        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        pool.finalizeClaim(cid, amounts, noProof);
        assertEq(usdc.balanceOf(bob), 100e6);
        assertEq(pool.totalAssets(IERC20(address(usdc))), 0);
    }

    function test_StakeBlockedDuringIncidentThenResumes() public {
        _stake(alice, usdc, 100e6);
        _registerClaim(bob, lp1, 50e18); // opens incident 1

        usdc.mint(carol, 100e6);
        vm.startPrank(carol);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(CoverPool.IncidentsActive.selector);
        pool.stake(IERC20(address(usdc)), 100e6);
        vm.stopPrank();

        // Incident voids after the dispute period -> staking reopens.
        vm.warp(block.timestamp + 5 days + 3 days + 1);
        vm.prank(carol);
        pool.stake(IERC20(address(usdc)), 100e6);
        assertGt(pool.userShares(IERC20(address(usdc)), carol), 0);
    }

    function test_AdminSweepsForfeitedInsuredTokens() public {
        _stake(alice, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 50e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(40e6, 0, 0);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 3 days);
        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        pool.finalizeClaim(cid, amounts, noProof);

        vm.prank(admin);
        pool.sweepInsuredToken(IERC20(address(lp1)), carol, 50e18);
        assertEq(lp1.balanceOf(carol), 50e18);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CoverPool.InsufficientForfeited.selector, 1, 0));
        pool.sweepInsuredToken(IERC20(address(lp1)), carol, 1);
    }

    // ════════════════════ Loss socialization & staker lock ════════════════════

    function test_LossSocializedAcrossStakers() public {
        _stake(alice, usdc, 100e6);
        _stake(carol, usdc, 100e6);
        uint256 cid = _registerClaim(bob, lp1, 100e18);
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory amounts = _amounts(80e6, 0, 0);
        _settle(1, _leaf(1, cid, bob, amounts));
        vm.warp(block.timestamp + 3 days);
        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        pool.finalizeClaim(cid, amounts, noProof);

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

        // Settle within the submit window (t = 5d+1).
        vm.warp(block.timestamp + 3 days + 1);
        _settle(1, _leaf(1, cid, bob, _amounts(10e6, 0, 0)));

        // Cooldown (7d) has now elapsed, but the incident is still in its
        // dispute/finalize phases -> withdrawal stays blocked (t = 8d+1).
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        vm.expectRevert(CoverPool.IncidentsActive.selector);
        pool.completeUnstake(IERC20(address(usdc)));

        // Bob finalizes -> all claims resolved -> unblocked immediately.
        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        pool.finalizeClaim(cid, _amounts(10e6, 0, 0), noProof);
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
        vm.warp(block.timestamp + 5 days + 3 days + 1);
        vm.prank(alice);
        pool.completeUnstake(IERC20(address(usdc)));
    }

    // ════════════════════ One incident at a time ════════════════════

    function test_SecondIncidentBlockedWhileFirstActive() public {
        _registerClaim(bob, lp1, 50e18);
        assertEq(pool.activeIncidentId(), 1);

        // Opening a second incident is rejected while the first is in flight,
        // even with a valid attestation on a different insured token.
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _signOpen(address(lp2), pool.nextIncidentId(), deadline, signerPk);
        lp2.mint(carol, 30e18);
        vm.startPrank(carol);
        lp2.approve(address(pool), 30e18);
        vm.expectRevert(CoverPool.IncidentsActive.selector);
        pool.openIncident(IERC20(address(lp2)), 30e18, deadline, sig);
        vm.stopPrank();
    }

    function test_NewIncidentOpensAfterPriorResolves() public {
        _stake(alice, usdc, 200e6);
        uint256 c1 = _registerClaim(bob, lp1, 50e18);

        // Settle + finalize incident 1 fully.
        vm.warp(block.timestamp + 5 days + 1);
        uint256[] memory a1 = _amounts(40e6, 0, 0);
        _settle(1, _leaf(1, c1, bob, a1));
        vm.warp(block.timestamp + 3 days);
        bytes32[] memory noProof = new bytes32[](0);
        vm.prank(bob);
        pool.finalizeClaim(c1, a1, noProof);

        // Incident 1 inactive -> a fresh incident can open on lp2 and runs
        // its full settlement window off its own clock.
        uint256 c2 = _registerClaim(carol, lp2, 30e18);
        assertEq(pool.activeIncidentId(), 2);

        vm.warp(block.timestamp + 5 days + 1);
        bytes32 root2 = _leaf(2, c2, carol, _amounts(10e6, 0, 0));
        _settle(2, root2);
        vm.warp(block.timestamp + 3 days);
        vm.prank(carol);
        pool.finalizeClaim(c2, _amounts(10e6, 0, 0), noProof);
        assertEq(usdc.balanceOf(carol), 10e6);
    }

    function test_NewIncidentOpensAfterPriorVoids() public {
        _registerClaim(bob, lp1, 50e18);
        // No root submitted: incident 1 voids at windowEnd + dispute period.
        vm.warp(block.timestamp + 5 days + 3 days + 1);
        // Now a new incident may open.
        uint256 c2 = _registerClaim(carol, lp2, 30e18);
        assertEq(pool.activeIncidentId(), 2);
        assertEq(c2, 2);
    }

    // ════════════════════ Ownership ════════════════════

    function test_RoleTransfersAndGating() public {
        // Distinct fast admin; timelock keeps config + role assignment.
        address fastAdmin = address(0xFA57);
        vm.prank(admin);
        pool.setAdmin(fastAdmin);
        assertEq(pool.admin(), fastAdmin);

        // Fast admin can run reward ops but not curate insured tokens.
        usd8.mint(fastAdmin, 1e18);
        _stake(alice, usdc, 100e6);
        vm.startPrank(fastAdmin);
        usd8.approve(address(pool), 1e18);
        pool.notifyReward(IERC20(address(usdc)), 1e18);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(CoverPool.UnauthorizedTimelock.selector, fastAdmin));
        vm.prank(fastAdmin);
        pool.setCoverageBps(IERC20(address(lp1)), 7000);

        // Timelock handover; old timelock loses config access.
        address newTimelock = address(0x71E);
        vm.prank(admin);
        pool.setTimelock(newTimelock);
        assertEq(pool.timelock(), newTimelock);

        vm.expectRevert(abi.encodeWithSelector(CoverPool.UnauthorizedTimelock.selector, admin));
        vm.prank(admin);
        pool.setCoverageBps(IERC20(address(lp1)), 7000);
    }
}
