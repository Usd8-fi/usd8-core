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
import {Registry} from "../src/Registry.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {USD8} from "../src/USD8.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";

/// Cross-language end-to-end check: drive a real incident on-chain, then use the
/// Rust settlement runtime (via FFI) to produce the merkle root and per-claim
/// proofs — and prove they settle and pay each claimant exactly those amounts.
///
/// Opt-in (keeps the default forge test green and FFI-free):
///   cargo build --release --locked --manifest-path offchain-rust/Cargo.toml
///   RUN_INTEGRATION=1 forge test --offline --ffi --match-path test/SettlementIntegration.t.sol -vv
contract SettlementIntegrationTest is Test {
    string constant RUST_FFI = "offchain-rust/target/release/usd8-settlement";

    MockERC20 usdc; // pool stake asset (payout currency)
    MockERC20 lp; // insured token
    MockERC1155 booster;
    USD8 usd8;
    SingleAssetCoverPool pool;
    DefiInsurance defi;
    Registry registry;

    address admin = address(0xA11CE);
    address alice = address(0xBEEF); // underwriter
    address bob = address(0xB0B);
    address carol = address(0xCA401);
    address constant FEED = address(0xFEED);
    uint256 constant TEE_PK = 0x7EE;
    bytes32 constant TEE_PCR_HASH = keccak256("integration-PCR0-PCR1-PCR2");

    struct ScarcityFixture {
        address[] users;
        uint256[] claimIds;
        uint256[][] amounts;
        uint256[] scores;
        uint256[] eligibles;
        bytes rootPayload;
    }

    function setUp() public {
        vm.roll(1000);
        vm.etch(FEED, hex"00");
        vm.mockCall(FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(
            FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(1e8), uint256(1), uint256(1), uint80(1))
        );
        usdc = new MockERC20("USDC", "USDC", 6);
        lp = new MockERC20("LP", "LP", 18);
        booster = new MockERC1155();
        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (admin, admin))))
        );
        USD8 impl = new USD8();
        usd8 = USD8(address(new ERC1967Proxy(address(impl), abi.encodeCall(USD8.initialize, (registry)))));
        vm.startPrank(admin);
        registry.setUsd8(address(usd8));
        registry.setTreasury(admin);
        vm.stopPrank();

        SingleAssetCoverPool pImpl = new SingleAssetCoverPool();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(pImpl), admin);
        pool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(SingleAssetCoverPool.initialize, (registry, IERC20(address(usdc)), "Cover", "cp"))
                )
            )
        );

        defi = DefiInsurance(
            address(
                new ERC1967Proxy(address(new DefiInsurance()), abi.encodeCall(DefiInsurance.initialize, (registry)))
            )
        );

        vm.startPrank(admin);
        registry.setTeePcrHash(TEE_PCR_HASH);
        registry.addPool(address(pool), FEED);
        registry.setDefiInsurance(address(defi));
        defi.editInsuredToken(IERC20(address(lp)), 8000, FEED, address(0), "");
        defi.setTeeSigner(vm.addr(TEE_PK), true);
        vm.stopPrank();

        // Underwrite the pool with 1,000 USDC.
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.deposit(1000e6, alice);
        vm.stopPrank();
    }

    /// @dev Per-pool payout caps aligned to the current pool set (always ≥ the
    ///      integration payouts, which are well under the cap).
    function _pp() internal view returns (uint256[] memory pp) {
        (, address[] memory poolAddrs) = registry.coverPools();
        pp = new uint256[](poolAddrs.length);
        for (uint256 i = 0; i < poolAddrs.length; i++) {
            pp[i] = SingleAssetCoverPool(poolAddrs[i]).maxPayoutPerIncident();
        }
    }

    /// @dev Sign a settlement root as the TEE, binding the incident's current
    ///      on-chain unresolved count, claim-set hash, and committed per-pool
    ///      payouts (mirrors settleIncident).
    function _teeSign(uint256 incidentId, bytes32 root, uint256[] memory pp) internal view returns (bytes memory) {
        (,,,,,, uint256 unresolved, bytes32 claimSetHash,,) = defi.incidents(incidentId);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("DefiInsurance")),
                keccak256(bytes("1")),
                block.chainid,
                address(defi)
            )
        );
        (, address[] memory poolAddrs) = registry.coverPools();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Settlement(uint256 incidentId,bytes32 root,uint256 unresolvedClaims,uint256[] poolPayouts,bytes32 pools,bytes32 claimSet,bytes32 teePcrHash)"
                ),
                incidentId,
                root,
                unresolved,
                keccak256(abi.encodePacked(pp)),
                keccak256(abi.encodePacked(poolAddrs)),
                claimSetHash,
                TEE_PCR_HASH
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEE_PK, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Relay a TEE-signed root (keeps the caller's stack shallow).
    function _settle(uint256 incidentId, bytes32 root) internal {
        uint256[] memory pp = _pp();
        defi.settleIncident(root, pp, _teeSign(incidentId, root, pp));
    }

    function test_OffchainRootAndProofsDriveCorrectPayout() public {
        if (!vm.envOr("RUN_INTEGRATION", false)) {
            vm.skip(true);
            return;
        }

        // ── Open incident + two claims (bob then carol). ──
        vm.prank(admin);
        uint256 incidentId = defi.openClaimIncident(IERC20(address(lp)), uint64(block.number - 1));

        uint256 cb = _join(bob, 100e18, 60); // escrow 100 LP, requests 60 score
        uint256 cc = _join(carol, 100e18, 40);

        // ── The off-chain settlement: bob gets 90 USDC, carol 60 USDC. ──
        uint256 bobPay = 90e6;
        uint256 carolPay = 60e6;
        uint256[][] memory amounts = new uint256[][](2);
        amounts[0] = _u256(bobPay);
        amounts[1] = _u256(carolPay);
        // eligibles: each claim's escrow (bob and carol each escrowed 100 LP).
        bytes memory rootPayload = abi.encode(
            incidentId,
            _u256(cb, cc),
            _addr(bob, carol),
            amounts,
            _u256(60, 40), // raw score spent
            _u256(60, 40), // boosted payout score (no boosters in this fixture)
            _u256(100e18, 100e18)
        );

        bytes32 root = abi.decode(_ffi("root", rootPayload, ""), (bytes32));
        bytes32[] memory proofBob = abi.decode(_ffi("proof", rootPayload, vm.toString(cb)), (bytes32[]));
        bytes32[] memory proofCarol = abi.decode(_ffi("proof", rootPayload, vm.toString(cc)), (bytes32[]));

        // ── 3) Settle with the off-chain root, finalize each claim with its proof. ──
        (,,,, uint64 wEnd,,,,,) = defi.incidents(incidentId);
        vm.warp(wEnd + 1);
        _settle(incidentId, root);
        vm.warp(block.timestamp + registry.incidentTimingConfig().phaseWindow + 1); // past CORRECTION_WINDOW

        vm.prank(bob);
        defi.finalizeClaim(cb, true, _u256(bobPay), 60, 60, 100e18, proofBob);
        vm.prank(carol);
        defi.finalizeClaim(cc, true, _u256(carolPay), 40, 40, 100e18, proofCarol);

        // ── Payouts match the off-chain amounts and only raw score is recorded. ──
        assertEq(usdc.balanceOf(bob), bobPay, "bob payout != off-chain amount");
        assertEq(usdc.balanceOf(carol), carolPay, "carol payout != off-chain amount");
        assertEq(registry.scoreSpent(bob), 60);
        assertEq(registry.scoreSpent(carol), 40);
    }

    function test_UnderfundedManyClaimantsMatchLocalOracleAndBondOutcomes() public {
        if (!vm.envOr("RUN_INTEGRATION", false)) {
            vm.skip(true);
            return;
        }

        vm.prank(admin);
        uint256 incidentId = defi.openClaimIncident(IERC20(address(lp)), uint64(block.number - 1));
        ScarcityFixture memory f = _scarcityFixture(incidentId);
        address observer = address(0x3000);
        assertEq(defi.claimIdByIncidentAndUser(incidentId, observer), 0, "non-filer unexpectedly registered");

        bytes32 root = abi.decode(_ffi("root", f.rootPayload, ""), (bytes32));
        uint256 grossBudget;
        for (uint256 i = 0; i < 10; i++) {
            grossBudget += f.amounts[i][0] * 10_000 / 8_000;
        }
        assertEq(grossBudget, 499_999_990, "local gross-budget oracle changed");

        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(incidentId);
        vm.warp(claimDeadline + 1);
        uint256[] memory poolBudget = _u256(grossBudget);
        defi.settleIncident(root, poolBudget, _teeSign(incidentId, root, poolBudget));
        vm.warp(block.timestamp + defi.incidentPhaseWindow(incidentId) + 1);

        (uint256 acceptedGross, uint256 acceptedNet) = _acceptScarcityClaims(f);
        _resolveIneligibleScarcityClaim(f, observer);

        (,,,, uint64 correctionDeadline,,,,,) = defi.incidents(incidentId);
        vm.warp(uint256(correctionDeadline) + defi.incidentPhaseWindow(incidentId) + 1);
        _resolveNoShowScarcityClaim(f);

        assertEq(pool.totalAssets(), 1_000e6 - acceptedGross, "pool draw != accepted gross payouts");
        assertEq(usdc.balanceOf(admin), acceptedGross - acceptedNet, "protocol fee mismatch");
        assertEq(defi.incidentPoolBudget(incidentId)[0], grossBudget - acceptedGross, "unused offer redistributed");
        (,,,,,, uint256 unresolved,,,) = defi.incidents(incidentId);
        assertEq(unresolved, 0, "claims remain unresolved");
    }

    /// @dev Golden-vector check: the selected FFI EIP-712 settlement digest must
    ///      equal the contract's _hashTypedDataV4 digest byte-for-byte, over 0/1/N
    ///      pools. Covers the whole digest — domain separator, typehash,
    ///      poolPayouts array encoding, and the `pools` packed-address hash — not
    ///      just the Merkle root. `solc` is the authority; Rust must reproduce it.
    function test_OffchainDigestMatchesOnchain() public {
        if (!vm.envOr("RUN_INTEGRATION", false)) {
            vm.skip(true);
            return;
        }

        for (uint256 n = 0; n <= 3; n++) {
            address[] memory poolAddrs = new address[](n);
            uint256[] memory pp = new uint256[](n);
            for (uint256 i = 0; i < n; i++) {
                poolAddrs[i] = address(uint160(0xC0FFEE + i));
                pp[i] = (i + 1) * 1e6;
            }
            uint256 incidentId = 7;
            bytes32 root = keccak256(abi.encodePacked("root", n));
            uint256 unresolved = 3;
            bytes32 claimSet = keccak256(abi.encodePacked("claims", n));

            bytes memory payload = abi.encode(
                block.chainid, address(defi), incidentId, root, unresolved, pp, poolAddrs, claimSet, TEE_PCR_HASH
            );
            bytes32 offchain = abi.decode(_ffi("digest", payload, ""), (bytes32));
            bytes32 onchain = _settlementDigest(incidentId, root, unresolved, pp, poolAddrs, claimSet);
            assertEq(offchain, onchain, "EIP-712 settlement digest mismatch (Rust != solc)");
        }
    }

    /// @dev Cross-language check of the claim-set accumulator: replay the
    ///      same join/cancel sequence off-chain and require it to reproduce the
    ///      contract's {Incident.claimSetHash} exactly.
    function test_OffchainClaimSetReplayMatchesOnchain() public {
        if (!vm.envOr("RUN_INTEGRATION", false)) {
            vm.skip(true);
            return;
        }

        vm.prank(admin);
        uint256 incidentId = defi.openClaimIncident(IERC20(address(lp)), uint64(block.number - 1));
        uint256 cb = _join(bob, 100e18, 60);
        uint256 cc = _join(carol, 50e18, 40);
        vm.prank(carol);
        defi.cancelClaim(); // exercise the cancel path of the accumulator

        uint8[] memory kinds = new uint8[](3); // 0 = register, 1 = cancel
        kinds[2] = 1;
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (cb, cc, cc);
        address[] memory users = _addr(bob, carol);
        address[] memory users3 = new address[](3);
        (users3[0], users3[1], users3[2]) = (users[0], users[1], users[1]);
        uint256[] memory escrows = new uint256[](3);
        (escrows[0], escrows[1]) = (100e18, 50e18);
        uint256[] memory scores = new uint256[](3);
        (scores[0], scores[1]) = (60, 40);
        uint256[] memory boosters = new uint256[](3);

        bytes memory payload = abi.encode(kinds, ids, users3, escrows, scores, boosters);
        bytes32 offchain = abi.decode(_ffi("claimset", payload, ""), (bytes32));
        (,,,,,,, bytes32 onchain,,) = defi.incidents(incidentId);
        assertEq(offchain, onchain, "claim-set accumulator mismatch (offchain replay != contract)");
    }

    /// @dev Reconstruct the contract's EIP-712 settlement digest (mirrors
    ///      {DefiInsurance.settleIncident} / _hashTypedDataV4) for arbitrary inputs.
    function _settlementDigest(
        uint256 incidentId,
        bytes32 root,
        uint256 unresolved,
        uint256[] memory pp,
        address[] memory poolAddrs,
        bytes32 claimSet
    ) internal view returns (bytes32) {
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
                keccak256(
                    "Settlement(uint256 incidentId,bytes32 root,uint256 unresolvedClaims,uint256[] poolPayouts,bytes32 pools,bytes32 claimSet,bytes32 teePcrHash)"
                ),
                incidentId,
                root,
                unresolved,
                keccak256(abi.encodePacked(pp)),
                keccak256(abi.encodePacked(poolAddrs)),
                claimSet,
                TEE_PCR_HASH
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    // ── helpers ──

    function _join(address who, uint128 amount, uint256 score) internal returns (uint256 claimId) {
        lp.mint(who, amount);
        vm.prank(admin);
        usd8.mint(who, 10e18);
        vm.startPrank(who);
        lp.approve(address(defi), amount);
        usd8.approve(address(defi), 10e18);
        claimId = defi.fileClaim(IERC20(address(lp)), amount, score, 0, 0, "");
        vm.stopPrank();
    }

    function _scarcityFixture(uint256 incidentId) internal returns (ScarcityFixture memory f) {
        f.users = new address[](11);
        f.claimIds = new uint256[](11);
        f.amounts = new uint256[][](11);
        f.scores = new uint256[](11);
        f.eligibles = new uint256[](11);

        for (uint256 i = 0; i < 10; i++) {
            f.users[i] = address(uint160(0x1000 + i));
            f.scores[i] = (i + 1) * 10;
            f.eligibles[i] = (50 + i * 10) * 1e18;
            f.claimIds[i] = _join(f.users[i], uint128(f.eligibles[i]), f.scores[i]);
            f.amounts[i] = _u256(400e6 * f.scores[i] / 550);
            assertLt(f.amounts[i][0], f.eligibles[i] * 8_000 / 10_000 / 1e12, "claim hit coverage cap");
        }

        f.users[10] = address(0x2000);
        f.claimIds[10] = _join(f.users[10], 150e18, 1_000);
        f.amounts[10] = _u256(0);
        f.rootPayload = abi.encode(incidentId, f.claimIds, f.users, f.amounts, f.scores, f.scores, f.eligibles);
    }

    function _acceptScarcityClaims(ScarcityFixture memory f)
        internal
        returns (uint256 acceptedGross, uint256 acceptedNet)
    {
        for (uint256 i = 0; i < 10; i++) {
            if (i == 8) continue;
            bytes32[] memory proof = abi.decode(_ffi("proof", f.rootPayload, vm.toString(f.claimIds[i])), (bytes32[]));
            vm.prank(f.users[i]);
            defi.finalizeClaim(f.claimIds[i], true, f.amounts[i], f.scores[i], f.scores[i], f.eligibles[i], proof);
            assertEq(usdc.balanceOf(f.users[i]), f.amounts[i][0], "actual payout != local oracle");
            assertEq(registry.scoreSpent(f.users[i]), f.scores[i], "actual score spend != local oracle");
            acceptedNet += f.amounts[i][0];
            acceptedGross += f.amounts[i][0] * 10_000 / 8_000;
        }
    }

    function _resolveIneligibleScarcityClaim(ScarcityFixture memory f, address resolver) internal {
        uint256 treasuryBondBefore = usd8.balanceOf(admin);
        bytes32[] memory proof = abi.decode(_ffi("proof", f.rootPayload, vm.toString(f.claimIds[10])), (bytes32[]));
        vm.prank(resolver);
        defi.finalizeClaim(f.claimIds[10], false, f.amounts[10], 0, 0, 0, proof);
        assertEq(lp.balanceOf(f.users[10]), 150e18, "ineligible escrow not returned");
        assertEq(usd8.balanceOf(f.users[10]), 0, "ineligible bond incorrectly refunded");
        assertEq(usd8.balanceOf(admin), treasuryBondBefore + defi.claimBondAmount(), "bond not forfeited");
        assertEq(registry.scoreSpent(f.users[10]), 0, "ineligible score consumed");
    }

    function _resolveNoShowScarcityClaim(ScarcityFixture memory f) internal {
        bytes32[] memory proof = abi.decode(_ffi("proof", f.rootPayload, vm.toString(f.claimIds[8])), (bytes32[]));
        vm.prank(f.users[8]);
        defi.finalizeClaim(f.claimIds[8], false, f.amounts[8], f.scores[8], f.scores[8], f.eligibles[8], proof);
        assertEq(usdc.balanceOf(f.users[8]), 0, "expired offer paid");
        assertEq(lp.balanceOf(f.users[8]), f.eligibles[8], "eligible no-show escrow not returned");
        assertEq(usd8.balanceOf(f.users[8]), defi.claimBondAmount(), "eligible no-show bond not refunded");
        assertEq(registry.scoreSpent(f.users[8]), 0, "declined score consumed");
    }

    function _ffi(string memory cmd, bytes memory payload, string memory arg) internal returns (bytes memory) {
        uint256 n = bytes(arg).length == 0 ? 4 : 5;
        string[] memory c = new string[](n);
        c[0] = RUST_FFI;
        c[1] = "ffi";
        c[2] = cmd;
        c[3] = vm.toString(payload);
        if (n == 5) c[4] = arg;
        return vm.ffi(c);
    }

    function _u256(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _u256(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _addr(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }
}
