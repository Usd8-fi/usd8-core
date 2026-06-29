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
import {MockERC1155} from "./mocks/MockERC1155.sol";

/// Cross-language end-to-end check: drive a real incident on-chain, then use the
/// off-chain TypeScript settlement code (via FFI) to produce the inputHash, the
/// merkle root and the per-claim proofs — and prove they reproduce the on-chain
/// inputHash, settle, and pay each claimant exactly the off-chain amounts.
///
/// Opt-in (keeps the default `forge test` green and FFI-free):
///   cd offchain && npm run build
///   RUN_INTEGRATION=1 forge test --ffi --match-path test/SettlementIntegration.t.sol -vv
contract SettlementIntegrationTest is Test {
    string constant FFI = "offchain/dist/ffi.js";

    MockERC20 usdc; // pool stake asset (payout currency)
    MockERC20 lp; // insured token
    MockERC1155 booster;
    USD8 usd8;
    CoverPool pool;
    DefiInsurance defi;

    address admin = address(0xA11CE);
    address alice = address(0xBEEF); // underwriter
    address bob = address(0xB0B);
    address carol = address(0xCA401);
    address constant FEED = address(0xFEED);

    function setUp() public {
        vm.roll(1000);
        usdc = new MockERC20("USDC", "USDC", 6);
        lp = new MockERC20("LP", "LP", 18);
        booster = new MockERC1155();
        USD8 impl = new USD8();
        usd8 = USD8(address(new ERC1967Proxy(address(impl), abi.encodeCall(USD8.initialize, (admin, admin)))));

        CoverPool pImpl = new CoverPool();
        pool = CoverPool(
            address(
                new ERC1967Proxy(
                    address(pImpl), abi.encodeCall(CoverPool.initialize, (IERC20(address(usd8)), admin, admin, address(booster)))
                )
            )
        );
        defi = new DefiInsurance(ICoverPool(address(pool)), admin, admin);

        vm.startPrank(admin);
        pool.setPayoutModule(address(defi), true);
        pool.addCoverPoolAsset(IERC20(address(usdc)), FEED, 0);
        defi.addInsuredToken(IERC20(address(lp)), 8000, FEED, address(0), "");
        vm.stopPrank();

        // Underwrite the pool with 1,000 USDC.
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.stake(IERC20(address(usdc)), 1000e6);
        vm.stopPrank();
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

        // ── 1) inputHash parity: off-chain replay must match the on-chain chain. ──
        bytes memory hashPayload = abi.encode(
            _u256(cb, cc), // claimIds
            _addr(bob, carol), // users
            _u256(100e18, 100e18), // escrows
            _u256(60, 40), // scoreToSpend
            _empty2(), // boosterIds[][]
            _empty2() // boosterAmounts[][]
        );
        bytes32 ffiInputHash = abi.decode(_ffi("inputhash", hashPayload, ""), (bytes32));
        (,,, bytes32 onchainInputHash,,,,) = defi.incidents(incidentId);
        assertEq(ffiInputHash, onchainInputHash, "inputHash mismatch (TS vs chain)");

        // ── 2) The off-chain settlement: bob gets 90 USDC, carol 60 USDC. ──
        uint256 bobPay = 90e6;
        uint256 carolPay = 60e6;
        uint256[][] memory amounts = new uint256[][](2);
        amounts[0] = _u256(bobPay);
        amounts[1] = _u256(carolPay);
        bytes memory rootPayload = abi.encode(incidentId, _u256(cb, cc), _addr(bob, carol), amounts, _u256(60, 40));

        bytes32 root = abi.decode(_ffi("root", rootPayload, ""), (bytes32));
        bytes32[] memory proofBob = abi.decode(_ffi("proof", rootPayload, vm.toString(cb)), (bytes32[]));
        bytes32[] memory proofCarol = abi.decode(_ffi("proof", rootPayload, vm.toString(cc)), (bytes32[]));

        // ── 3) Settle with the off-chain root, finalize each claim with its proof. ──
        (, uint64 wEnd,,,,,,) = defi.incidents(incidentId);
        vm.warp(wEnd + 1);
        vm.prank(admin);
        defi.settleIncident(incidentId, root);
        vm.warp(block.timestamp + 4 days + 1); // past DISPUTE_PERIOD

        vm.prank(bob);
        defi.finalizeClaim(cb, _u256(bobPay), 60, proofBob);
        vm.prank(carol);
        defi.finalizeClaim(cc, _u256(carolPay), 40, proofCarol);

        // ── Payouts match the off-chain amounts exactly; score recorded. ──
        assertEq(usdc.balanceOf(bob), bobPay, "bob payout != off-chain amount");
        assertEq(usdc.balanceOf(carol), carolPay, "carol payout != off-chain amount");
        assertEq(pool.insuranceScoreSpent(bob), 60);
        assertEq(pool.insuranceScoreSpent(carol), 40);
    }

    // ── helpers ──

    function _join(address who, uint128 amount, uint256 score) internal returns (uint256 claimId) {
        lp.mint(who, amount);
        vm.startPrank(who);
        lp.approve(address(defi), amount);
        claimId = defi.joinClaim(IERC20(address(lp)), amount, score, new uint256[](0), new uint256[](0));
        vm.stopPrank();
    }

    function _ffi(string memory cmd, bytes memory payload, string memory arg) internal returns (bytes memory) {
        uint256 n = bytes(arg).length == 0 ? 4 : 5;
        string[] memory c = new string[](n);
        c[0] = "node";
        c[1] = FFI;
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

    function _empty2() internal pure returns (uint256[][] memory r) {
        r = new uint256[][](2);
        r[0] = new uint256[](0);
        r[1] = new uint256[](0);
    }
}
