// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";

contract USD8TokenHandler is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    Registry public immutable registry;
    USD8 public immutable usd8;
    address public immutable timelock;
    address public immutable treasuryA;
    address public immutable treasuryB;

    uint256[3] internal actorKeys = [uint256(0xA11CE), uint256(0xB0B), uint256(0xCAFE)];
    address[3] internal actors;

    uint256[3] public ghostBalances;
    uint256[3][3] public ghostAllowances;
    uint256[3] public ghostNonces;
    uint256 public ghostSupply;
    address public ghostTreasury;

    uint256 public successfulMints;
    uint256 public successfulBurns;
    uint256 public successfulTransfers;
    uint256 public successfulTransferFroms;
    uint256 public successfulPermits;
    uint256 public successfulTreasuryRotations;

    constructor(Registry registry_, USD8 usd8_, address timelock_, address treasuryA_, address treasuryB_) {
        registry = registry_;
        usd8 = usd8_;
        timelock = timelock_;
        treasuryA = treasuryA_;
        treasuryB = treasuryB_;
        ghostTreasury = treasuryA_;
        for (uint256 i = 0; i < 3; i++) {
            actors[i] = vm.addr(actorKeys[i]);
        }
    }

    function mint(uint256 actorSeed, uint256 amountSeed) external {
        uint256 i = bound(actorSeed, 0, 2);
        uint256 amount = bound(amountSeed, 0, 1e30);
        vm.prank(ghostTreasury);
        usd8.mint(actors[i], amount);
        ghostBalances[i] += amount;
        ghostSupply += amount;
        successfulMints++;
    }

    function burn(uint256 actorSeed, uint256 amountSeed) external {
        uint256 i = bound(actorSeed, 0, 2);
        uint256 amount = bound(amountSeed, 0, ghostBalances[i]);
        vm.prank(ghostTreasury);
        usd8.burn(actors[i], amount);
        ghostBalances[i] -= amount;
        ghostSupply -= amount;
        successfulBurns++;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 from = bound(fromSeed, 0, 2);
        uint256 to = bound(toSeed, 0, 2);
        uint256 amount = bound(amountSeed, 0, ghostBalances[from]);
        vm.prank(actors[from]);
        assertTrue(usd8.transfer(actors[to], amount));
        if (from != to) {
            ghostBalances[from] -= amount;
            ghostBalances[to] += amount;
        }
        successfulTransfers++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        uint256 owner = bound(ownerSeed, 0, 2);
        uint256 spender = bound(spenderSeed, 0, 2);
        uint256 amount = amountSeed % 5 == 0 ? type(uint256).max : bound(amountSeed, 0, 1e30);
        vm.prank(actors[owner]);
        assertTrue(usd8.approve(actors[spender], amount));
        ghostAllowances[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 owner = bound(ownerSeed, 0, 2);
        uint256 spender = bound(spenderSeed, 0, 2);
        uint256 to = bound(toSeed, 0, 2);
        uint256 allowance_ = ghostAllowances[owner][spender];
        uint256 available = ghostBalances[owner] < allowance_ ? ghostBalances[owner] : allowance_;
        uint256 amount = bound(amountSeed, 0, available);

        vm.prank(actors[spender]);
        assertTrue(usd8.transferFrom(actors[owner], actors[to], amount));
        if (owner != to) {
            ghostBalances[owner] -= amount;
            ghostBalances[to] += amount;
        }
        if (allowance_ != type(uint256).max) ghostAllowances[owner][spender] -= amount;
        successfulTransferFroms++;
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 valueSeed) external {
        uint256 owner = bound(ownerSeed, 0, 2);
        uint256 spender = bound(spenderSeed, 0, 2);
        uint256 value = valueSeed % 5 == 0 ? type(uint256).max : bound(valueSeed, 0, 1e30);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, actors[owner], actors[spender], value, ghostNonces[owner], deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usd8.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKeys[owner], digest);
        usd8.permit(actors[owner], actors[spender], value, deadline, v, r, s);
        ghostAllowances[owner][spender] = value;
        ghostNonces[owner]++;
        successfulPermits++;
    }

    function rotateTreasury(bool useSecond) external {
        address next = useSecond ? treasuryB : treasuryA;
        vm.prank(timelock);
        registry.setTreasury(next);
        ghostTreasury = next;
        successfulTreasuryRotations++;
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }
}

contract USD8TokenInvariantTest is StdInvariant, Test {
    Registry registry;
    USD8 usd8;
    USD8TokenHandler handler;

    address constant TIMELOCK = address(0xD00D);
    address constant TREASURY_A = address(0xAAA1);
    address constant TREASURY_B = address(0xBBB2);

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (TIMELOCK, TIMELOCK)))
            )
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        vm.startPrank(TIMELOCK);
        registry.setUsd8(address(usd8));
        registry.setTreasury(TREASURY_A);
        vm.stopPrank();

        handler = new USD8TokenHandler(registry, usd8, TIMELOCK, TREASURY_A, TREASURY_B);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = USD8TokenHandler.mint.selector;
        selectors[1] = USD8TokenHandler.burn.selector;
        selectors[2] = USD8TokenHandler.transfer.selector;
        selectors[3] = USD8TokenHandler.approve.selector;
        selectors[4] = USD8TokenHandler.transferFrom.selector;
        selectors[5] = USD8TokenHandler.permit.selector;
        selectors[6] = USD8TokenHandler.rotateTreasury.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_ProductiveTokenBranchesAreReachable() public {
        handler.mint(0, 1_000e18);
        handler.transfer(0, 1, 100e18);
        handler.approve(1, 2, 50e18);
        handler.transferFrom(1, 2, 0, 25e18);
        handler.permit(0, 1, 10e18);
        handler.rotateTreasury(true);
        handler.burn(0, 1e18);

        assertGt(handler.successfulMints(), 0);
        assertGt(handler.successfulTransfers(), 0);
        assertGt(handler.successfulTransferFroms(), 0);
        assertGt(handler.successfulPermits(), 0);
        assertGt(handler.successfulTreasuryRotations(), 0);
        assertGt(handler.successfulBurns(), 0);
    }

    function invariant_supplyEqualsIndependentGhost() public view {
        assertEq(usd8.totalSupply(), handler.ghostSupply(), "supply ghost drift");
    }

    function invariant_allSupplyBelongsToKnownActors() public view {
        uint256 sum;
        for (uint256 i = 0; i < 3; i++) {
            uint256 actual = usd8.balanceOf(handler.actor(i));
            assertEq(actual, handler.ghostBalances(i), "actor balance drift");
            sum += actual;
        }
        assertEq(sum, usd8.totalSupply(), "known actor balance sum");
    }

    function invariant_allowancesMatchIndependentGhost() public view {
        for (uint256 owner = 0; owner < 3; owner++) {
            for (uint256 spender = 0; spender < 3; spender++) {
                assertEq(
                    usd8.allowance(handler.actor(owner), handler.actor(spender)),
                    handler.ghostAllowances(owner, spender),
                    "allowance drift"
                );
            }
        }
    }

    function invariant_permitNoncesMatchIndependentGhost() public view {
        for (uint256 i = 0; i < 3; i++) {
            assertEq(usd8.nonces(handler.actor(i)), handler.ghostNonces(i), "permit nonce drift");
        }
    }

    function invariant_treasuryAuthorityTracksRegistry() public view {
        assertEq(registry.treasury(), handler.ghostTreasury());
        assertEq(usd8.treasury(), handler.ghostTreasury());
    }

    function invariant_tokenContractNeverCustodiesSupply() public view {
        assertEq(usd8.balanceOf(address(usd8)), 0);
    }
}
