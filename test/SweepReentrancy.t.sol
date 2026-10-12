// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Registry} from "../src/Registry.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {USD8} from "../src/USD8.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";

/// @dev Contract claimant with admin authority. On the booster-return hook fired
///      during its own `cancelClaim`, it re-enters `sweepToken` and tries to take
///      the insured tokens still escrowed for other claimants.
contract SweepingClaimant is ERC1155Holder {
    DefiInsurance immutable defi;
    IERC20 immutable token;
    bool public armed;
    bool public swallow;
    bytes public lastRevert;

    constructor(DefiInsurance defi_, IERC20 token_) {
        defi = defi_;
        token = token_;
    }

    function arm(bool swallow_) external {
        armed = true;
        swallow = swallow_;
    }

    function file(uint128 amount, uint256 score, uint256 boosters, MockERC1155 booster, IERC20 usd8)
        external
        returns (uint256)
    {
        token.approve(address(defi), amount);
        usd8.approve(address(defi), type(uint256).max);
        booster.setApprovalForAll(address(defi), true);
        return defi.fileClaim(token, amount, score, boosters, 0, "");
    }

    function cancel() external {
        defi.cancelClaim();
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public override returns (bytes4) {
        if (armed) {
            armed = false;
            if (swallow) {
                try defi.sweepToken(token, address(this)) {}
                catch (bytes memory reason) {
                    lastRevert = reason;
                }
            } else {
                defi.sweepToken(token, address(this));
            }
        }
        return this.onERC1155Received.selector;
    }
}

/// @title M-01 regression: admin claimant must not sweep other claimants' escrow
///        by re-entering `sweepToken` from the ERC-1155 booster-return hook.
contract SweepReentrancyTest is Test {
    MockERC20 usdc;
    MockERC20 lp;
    MockERC1155 booster;
    USD8 usd8;
    SingleAssetCoverPool pool;
    DefiInsurance defi;
    Registry registry;
    SweepingClaimant mallory;

    address admin = address(0xA11CE);
    address alice = address(0xBEEF);
    address underwriter = address(0x0DD);
    address constant FEED = address(0xFEED);
    uint256 constant TEE_PK = 0x7EE;

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
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        vm.startPrank(admin);
        registry.setUsd8(address(usd8));
        registry.setTreasury(admin);
        vm.stopPrank();

        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new SingleAssetCoverPool()), admin);
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
        mallory = new SweepingClaimant(defi, IERC20(address(lp)));

        vm.startPrank(admin);
        registry.setTeePcrHash(keccak256("pcr"));
        registry.addPool(address(pool), FEED);
        registry.setDefiInsurance(address(defi));
        defi.editInsuredToken(IERC20(address(lp)), 8000, FEED, address(0), "");
        defi.setTeeSigner(vm.addr(TEE_PK), true);
        registry.setBoosterConfig(address(booster), 1, 100);
        registry.setAdmin(address(mallory), true); // the attacker is an admin
        vm.stopPrank();

        usdc.mint(underwriter, 1000e6);
        vm.startPrank(underwriter);
        usdc.approve(address(pool), 1000e6);
        pool.deposit(1000e6, underwriter);
        vm.stopPrank();

        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(lp)), uint64(block.number - 1));

        _join(alice, 100e18, 60, 0);
        _joinMallory(100e18, 40, 1);
    }

    /// @dev The re-entrant sweep reverts on the guard and the revert bubbles out
    ///      of the booster return, so the whole cancellation fails closed.
    function test_ReentrantSweepFromBoosterHookReverts() public {
        mallory.arm(false);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        mallory.cancel();
        assertEq(lp.balanceOf(address(defi)), 200e18, "escrow must be untouched");
    }

    /// @dev Even when the attacker swallows the inner revert, nothing is swept
    ///      and every other claimant's refund remains whole.
    function test_SwallowedReentrantSweepTakesNothing() public {
        mallory.arm(true);
        mallory.cancel();

        assertEq(
            bytes4(mallory.lastRevert()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            "inner sweep must be blocked by the guard"
        );
        assertEq(lp.balanceOf(address(mallory)), 100e18, "only Mallory's own refund");
        assertEq(lp.balanceOf(address(defi)), 100e18, "Alice's escrow still held");
        assertEq(defi.escrowedInsuredTokens(IERC20(address(lp))), 100e18, "accounting matches balance");

        vm.prank(alice);
        defi.cancelClaim();
        assertEq(lp.balanceOf(alice), 100e18, "Alice refunded in full");
        assertEq(lp.balanceOf(address(defi)), 0);
    }

    /// @dev Outside any in-flight operation the admin sweep still works, but only
    ///      for true surplus above live escrow.
    function test_SweepOnlyReturnsSurplusAboveEscrow() public {
        lp.mint(address(defi), 5e18); // stray tokens
        vm.prank(admin);
        defi.sweepToken(IERC20(address(lp)), admin);
        assertEq(lp.balanceOf(admin), 5e18);
        assertEq(lp.balanceOf(address(defi)), 200e18);
    }

    function _join(address who, uint128 amount, uint256 score, uint256 boosters) internal {
        lp.mint(who, amount);
        booster.mint(who, 1, boosters);
        vm.prank(admin);
        usd8.mint(who, 10e18);
        vm.startPrank(who);
        lp.approve(address(defi), amount);
        usd8.approve(address(defi), 10e18);
        booster.setApprovalForAll(address(defi), true);
        defi.fileClaim(IERC20(address(lp)), amount, score, boosters, 0, "");
        vm.stopPrank();
    }

    function _joinMallory(uint128 amount, uint256 score, uint256 boosters) internal {
        lp.mint(address(mallory), amount);
        booster.mint(address(mallory), 1, boosters);
        vm.prank(admin);
        usd8.mint(address(mallory), 10e18);
        mallory.file(amount, score, boosters, booster, IERC20(address(usd8)));
    }
}
