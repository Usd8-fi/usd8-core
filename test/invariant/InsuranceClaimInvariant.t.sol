// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Registry} from "../../src/Registry.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract InsuranceInvariantFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

contract InsuranceClaimHandler is Test {
    DefiInsurance public defi;
    MockERC20 public insuredToken;
    MockERC20 public bondToken;
    uint256 public incidentId;

    address[5] public actors;
    mapping(address actor => uint256 amount) public ghostEscrow;
    uint256 public ghostTotalEscrow;
    uint256 public ghostUnresolved;
    uint256 public ghostClaimsCreated;
    bytes32 public ghostClaimSetHash;

    constructor(DefiInsurance defi_, MockERC20 insuredToken_, MockERC20 bondToken_, uint256 incidentId_) {
        defi = defi_;
        insuredToken = insuredToken_;
        bondToken = bondToken_;
        incidentId = incidentId_;
        actors = [address(0xA11), address(0xB0B), address(0xCA1), address(0xD00D), address(0xE11)];
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function join(uint256 actorSeed, uint128 amount, uint256 scoreToSpend) external {
        address actor = _actor(actorSeed);
        if (defi.claimIdByIncidentAndUser(incidentId, actor) != 0) return;
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(incidentId);
        if (block.timestamp > claimDeadline) return;

        amount = uint128(bound(uint256(amount), 1e18, 1e24));
        scoreToSpend = bound(scoreToSpend, 0, 1e36);
        insuredToken.mint(actor, amount);
        bondToken.mint(actor, defi.claimBondAmount());

        vm.startPrank(actor);
        insuredToken.approve(address(defi), amount);
        bondToken.approve(address(defi), defi.claimBondAmount());
        uint256 claimId = defi.fileClaim(IERC20(address(insuredToken)), amount, scoreToSpend, 0, 0, "");
        vm.stopPrank();

        (address claimant, uint256 claimIncident, uint128 escrow,,, bool resolved) = defi.claims(claimId);
        assertEq(claimant, actor, "claimant");
        assertEq(claimIncident, incidentId, "claim incident");
        assertEq(escrow, amount, "claim escrow");
        assertFalse(resolved, "new claim resolved");

        ghostEscrow[actor] = amount;
        ghostTotalEscrow += amount;
        ghostUnresolved += 1;
        ghostClaimsCreated += 1;
        ghostClaimSetHash = keccak256(abi.encode(ghostClaimSetHash, claimId, actor, amount, scoreToSpend, uint256(0)));
    }

    function cancel(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 claimId = defi.claimIdByIncidentAndUser(incidentId, actor);
        if (claimId == 0) return;
        (,,,, uint64 claimDeadline,,,,,) = defi.incidents(incidentId);
        if (block.timestamp > claimDeadline) return;

        uint256 amount = ghostEscrow[actor];
        uint256 balanceBefore = insuredToken.balanceOf(actor);
        vm.prank(actor);
        defi.cancelClaim();

        (,,,,, bool resolved) = defi.claims(claimId);
        assertTrue(resolved, "cancelled claim unresolved");
        assertEq(defi.claimIdByIncidentAndUser(incidentId, actor), 0, "cancelled claim id not cleared");
        assertEq(insuredToken.balanceOf(actor), balanceBefore + amount, "escrow not returned");

        delete ghostEscrow[actor];
        ghostTotalEscrow -= amount;
        ghostUnresolved -= 1;
        ghostClaimSetHash = keccak256(abi.encode(ghostClaimSetHash, claimId));
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 9 days);
        vm.warp(block.timestamp + secs);
    }

    function withdrawExpired(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 claimId = defi.claimIdByIncidentAndUser(incidentId, actor);
        if (claimId == 0) return;
        (,,,,, bool resolved) = defi.claims(claimId);
        if (resolved) return;
        (,,,, uint64 phaseDeadline,,,,,) = defi.incidents(incidentId);
        uint256 settlementDeadline = uint256(phaseDeadline) + defi.incidentPhaseWindow(incidentId);
        if (block.timestamp <= settlementDeadline) return;

        uint256 amount = ghostEscrow[actor];
        uint256 balanceBefore = insuredToken.balanceOf(actor);
        vm.prank(actor);
        defi.finalizeClaim(claimId, false, new uint256[](0), 0, 0, 0, new bytes32[](0));

        (,,,,, resolved) = defi.claims(claimId);
        assertTrue(resolved, "withdrawn claim unresolved");
        assertEq(insuredToken.balanceOf(actor), balanceBefore + amount, "expired escrow not returned");

        delete ghostEscrow[actor];
        ghostTotalEscrow -= amount;
        ghostUnresolved -= 1;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

contract InsuranceClaimInvariantTest is StdInvariant, Test {
    address internal constant ADMIN = address(0xA11CE);

    Registry internal registry;
    DefiInsurance internal defi;
    MockERC20 internal insuredToken;
    MockERC20 internal bondToken;
    InsuranceClaimHandler internal handler;
    uint256 internal incidentId;

    function setUp() public {
        vm.roll(1000);
        insuredToken = new MockERC20("Insured LP", "iLP", 18);
        bondToken = new MockERC20("USD8", "USD8", 18);
        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (ADMIN, ADMIN))))
        );
        defi = DefiInsurance(
            address(
                new ERC1967Proxy(address(new DefiInsurance()), abi.encodeCall(DefiInsurance.initialize, (registry)))
            )
        );

        address feed = address(new InsuranceInvariantFeed());
        vm.startPrank(ADMIN);
        registry.setUsd8(address(bondToken));
        registry.setDefiInsurance(address(defi));
        defi.editInsuredToken(IERC20(address(insuredToken)), 8000, feed, address(0), "");
        incidentId = defi.openClaimIncident(IERC20(address(insuredToken)), uint64(block.number - 1));
        vm.stopPrank();

        handler = new InsuranceClaimHandler(defi, insuredToken, bondToken, incidentId);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = InsuranceClaimHandler.join.selector;
        selectors[1] = InsuranceClaimHandler.cancel.selector;
        selectors[2] = InsuranceClaimHandler.warp.selector;
        selectors[3] = InsuranceClaimHandler.withdrawExpired.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_unresolvedMatchesLiveClaims() public view {
        (,,,,,, uint256 unresolved,,,) = defi.incidents(incidentId);
        assertEq(unresolved, handler.ghostUnresolved(), "unresolved count");
    }

    function invariant_escrowAccountingMatchesLiveClaims() public view {
        uint256 escrow = defi.escrowedInsuredTokens(IERC20(address(insuredToken)));
        assertEq(escrow, handler.ghostTotalEscrow(), "escrow accounting");
        assertEq(insuredToken.balanceOf(address(defi)), escrow, "escrow token balance mismatch");
    }

    function invariant_claimIdsAreGapless() public view {
        assertEq(defi.nextClaimId(), handler.ghostClaimsCreated() + 1, "claim id gap");
    }

    function invariant_claimSetCommitmentMatchesReplay() public view {
        (,,,,,,, bytes32 claimSetHash,,) = defi.incidents(incidentId);
        assertEq(claimSetHash, handler.ghostClaimSetHash(), "claim-set commitment mismatch");
    }

    function invariant_expiredVoidUnfreezesPools() public view {
        (,,,, uint64 phaseDeadline, bytes32 root,,,,) = defi.incidents(incidentId);
        uint256 settlementDeadline = uint256(phaseDeadline) + defi.incidentPhaseWindow(incidentId);
        if (root == bytes32(0) && block.timestamp > settlementDeadline) {
            assertEq(defi.activeIncidentId(), 0, "expired void remains active");
            assertFalse(registry.payoutIncidentActive(), "expired void keeps pools frozen");
        }
    }

    function invariant_activeIncidentMatchesIndependentPhaseModel() public view {
        (,,,, uint64 phaseDeadline, bytes32 root, uint256 unresolved,,,) = defi.incidents(incidentId);

        uint256 expected;
        if (block.timestamp <= phaseDeadline) {
            expected = incidentId;
        } else if (unresolved != 0) {
            uint256 terminalDeadline = uint256(phaseDeadline) + defi.incidentPhaseWindow(incidentId);
            if (block.timestamp <= terminalDeadline) {
                expected = incidentId;
            }
        }

        assertEq(defi.activeIncidentId(), expected, "active incident phase mismatch");
        assertEq(registry.payoutIncidentActive(), expected != 0, "registry freeze phase mismatch");
    }

    function invariant_activeClaimIndexIsConsistent() public view {
        for (uint256 i = 0; i < 5; i++) {
            address actor = handler.actorAt(i);
            uint256 expectedEscrow = handler.ghostEscrow(actor);
            uint256 claimId = defi.claimIdByIncidentAndUser(incidentId, actor);
            if (expectedEscrow == 0) {
                if (claimId != 0) {
                    (,,,,, bool resolved) = defi.claims(claimId);
                    assertTrue(resolved, "historical claim remains unresolved");
                }
            } else {
                assertNotEq(claimId, 0, "missing active claim id");
                (address claimant, uint256 claimIncident, uint128 amount,,, bool resolved) = defi.claims(claimId);
                assertEq(claimant, actor, "active claimant");
                assertEq(claimIncident, incidentId, "active incident");
                assertEq(amount, expectedEscrow, "active escrow");
                assertFalse(resolved, "active claim resolved");
            }
        }
    }
}
