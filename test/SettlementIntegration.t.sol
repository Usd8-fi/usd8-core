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
/// off-chain TypeScript settlement code (via FFI) to produce the merkle root and
/// per-claim proofs — and prove they settle and pay each claimant exactly the
/// off-chain amounts.
///
/// Opt-in (keeps the default forge test green and FFI-free):
///   cd offchain && npm run build
///   RUN_INTEGRATION=1 forge test --ffi --match-path test/SettlementIntegration.t.sol -vv
contract SettlementIntegrationTest is Test {
    string constant FFI = "offchain/dist/ffi.js";

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

    function setUp() public {
        vm.roll(1000);
        usdc = new MockERC20("USDC", "USDC", 6);
        lp = new MockERC20("LP", "LP", 18);
        booster = new MockERC1155();
        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (admin, admin))))
        );
        USD8 impl = new USD8();
        usd8 = USD8(address(new ERC1967Proxy(address(impl), abi.encodeCall(USD8.initialize, (registry, admin)))));

        SingleAssetCoverPool pImpl = new SingleAssetCoverPool();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(pImpl), admin);
        pool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (registry, IERC20(address(usdc)), IERC20(address(usd8)), "Cover", "cp")
                    )
                )
            )
        );

        defi = new DefiInsurance(registry);

        vm.startPrank(admin);
        registry.addPool(address(pool));
        registry.setDefiInsurance(address(defi));
        defi.addInsuredToken(IERC20(address(lp)), 8000, FEED, address(0), "");
        defi.setTeeSigner(vm.addr(TEE_PK));
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
    ///      on-chain unresolved count and committed per-pool payouts (mirrors settleIncident).
    function _teeSign(uint256 incidentId, bytes32 root, uint256[] memory pp) internal view returns (bytes memory) {
        (,,, uint256 unresolved,,,,,) = defi.incidents(incidentId);
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
                    "Settlement(uint256 incidentId,bytes32 root,uint256 unresolved,uint256[] poolPayouts,bytes32 pools)"
                ),
                incidentId,
                root,
                unresolved,
                keccak256(abi.encodePacked(pp)),
                keccak256(abi.encodePacked(poolAddrs))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEE_PK, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Relay a TEE-signed root (keeps the caller's stack shallow).
    function _settle(uint256 incidentId, bytes32 root) internal {
        uint256[] memory pp = _pp();
        defi.settleIncident(incidentId, root, pp, _teeSign(incidentId, root, pp));
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
        bytes memory rootPayload =
            abi.encode(incidentId, _u256(cb, cc), _addr(bob, carol), amounts, _u256(60, 40), _u256(100e18, 100e18));

        bytes32 root = abi.decode(_ffi("root", rootPayload, ""), (bytes32));
        bytes32[] memory proofBob = abi.decode(_ffi("proof", rootPayload, vm.toString(cb)), (bytes32[]));
        bytes32[] memory proofCarol = abi.decode(_ffi("proof", rootPayload, vm.toString(cc)), (bytes32[]));

        // ── 3) Settle with the off-chain root, finalize each claim with its proof. ──
        (, uint64 wEnd,,,,,,,) = defi.incidents(incidentId);
        vm.warp(wEnd + 1);
        _settle(incidentId, root);
        vm.warp(block.timestamp + defi.DISPUTE_PERIOD() + 1); // past DISPUTE_PERIOD

        vm.prank(bob);
        defi.finalizeClaim(_u256(bobPay), 60, 100e18, proofBob);
        vm.prank(carol);
        defi.finalizeClaim(_u256(carolPay), 40, 100e18, proofCarol);

        // ── Payouts match the off-chain amounts exactly. Spent score is now an
        //    event (ScoreSpent), not on-chain state, so it isn't asserted here. ──
        assertEq(usdc.balanceOf(bob), bobPay, "bob payout != off-chain amount");
        assertEq(usdc.balanceOf(carol), carolPay, "carol payout != off-chain amount");
    }

    // ── helpers ──

    function _join(address who, uint128 amount, uint256 score) internal returns (uint256 claimId) {
        lp.mint(who, amount);
        vm.startPrank(who);
        lp.approve(address(defi), amount);
        claimId = defi.joinClaim(IERC20(address(lp)), amount, score, 0, 0, "");
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
}
