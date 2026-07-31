// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {MockERC1155} from "../../test/mocks/MockERC1155.sol";

contract StaleModuleInsuredToken is ERC20 {
    constructor() ERC20("Insured", "INS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice RED regression: emergency module deregistration must make old claims
///         refund-only; a stale module must not consume claimant assets.
contract DefiInsuranceStaleModuleRegressionTest is Test {
    bytes32 internal constant SETTLEMENT_TYPEHASH = keccak256(
        "Settlement(uint256 incidentId,bytes32 root,uint256 unresolvedClaims,uint256[] poolPayouts,bytes32 pools,bytes32 claimSet,bytes32 teePcrHash)"
    );
    bytes32 internal constant PCR_HASH = keccak256("stale-module-regression-pcr");
    uint256 internal constant TEE_KEY = 0xA11CE;
    uint256 internal constant BOOSTER_ID = 1;

    address internal admin = address(0xA11CE);
    address internal claimant = address(0xB0B);
    Registry internal registry;
    DefiInsurance internal defi;
    StaleModuleInsuredToken internal insured;
    StaleModuleInsuredToken internal bondToken;
    MockERC1155 internal booster;

    function setUp() public {
        vm.roll(1000);
        registry = Registry(
            address(new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (admin, admin))))
        );
        defi = DefiInsurance(
            address(
                new ERC1967Proxy(address(new DefiInsurance()), abi.encodeCall(DefiInsurance.initialize, (registry)))
            )
        );
        insured = new StaleModuleInsuredToken();
        bondToken = new StaleModuleInsuredToken();
        booster = new MockERC1155();

        vm.startPrank(admin);
        registry.setTeePcrHash(PCR_HASH);
        registry.setUsd8(address(bondToken));
        registry.setDefiInsurance(address(defi));
        registry.setBoosterConfig(address(booster), uint64(BOOSTER_ID), 100);
        defi.setTeeSigner(vm.addr(TEE_KEY), true);
        defi.editInsuredToken(IERC20(address(insured)), 8000, address(0xFEED), address(0), "");
        vm.stopPrank();
        bondToken.mint(claimant, 40e18);
        vm.prank(claimant);
        bondToken.approve(address(defi), type(uint256).max);
    }

    function test_staleModuleCannotFinalizeZeroExternalEffectRow() public {
        uint128 escrow = 50e18;
        insured.mint(claimant, escrow);
        vm.prank(claimant);
        insured.approve(address(defi), escrow);

        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(insured)), uint64(block.number - 1));
        vm.prank(claimant);
        uint256 claimId = defi.fileClaim(IERC20(address(insured)), escrow, 0, 0, 0, "");

        uint256[] memory noPayouts = new uint256[](0);
        bytes32 root = _leaf(1, claimId, claimant, noPayouts, 0, 0, escrow);
        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);
        defi.settleIncident(root, noPayouts, _fixtureSettlementSignature(root, noPayouts, claimId, escrow, 0));
        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);

        vm.prank(admin);
        registry.setDefiInsurance(address(0));

        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(DefiInsurance.FinalizeNotOpen.selector, uint256(1)));
        defi.finalizeClaim(claimId, true, noPayouts, 0, 0, escrow, new bytes32[](0));
    }

    function test_deregistrationMakesUnresolvedClaimImmediatelyWithdrawable() public {
        uint128 escrow = 50e18;
        uint256 boosterAmount = 3;
        insured.mint(claimant, escrow);
        booster.mint(claimant, BOOSTER_ID, boosterAmount);
        vm.prank(claimant);
        insured.approve(address(defi), escrow);
        vm.prank(claimant);
        booster.setApprovalForAll(address(defi), true);

        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(insured)), uint64(block.number - 1));
        vm.prank(claimant);
        uint256 claimId = defi.fileClaim(IERC20(address(insured)), escrow, 0, boosterAmount, 0, "");

        vm.prank(admin);
        registry.setDefiInsurance(address(0));

        vm.prank(claimant);
        defi.finalizeClaim(claimId, false, new uint256[](0), 0, 0, 0, new bytes32[](0));

        (,,,,, bool resolved) = defi.claims(claimId);
        (,,,,,, uint256 unresolved,,,) = defi.incidents(1);
        (, uint64 resolvedAt,,,,,,,,) = defi.incidents(1);
        assertTrue(resolved);
        assertEq(unresolved, 0);
        assertEq(insured.balanceOf(claimant), escrow);
        assertEq(booster.balanceOf(claimant, BOOSTER_ID), boosterAmount);
        assertEq(resolvedAt, block.timestamp);
    }

    function test_staleModuleCannotSettle() public {
        uint128 escrow = 50e18;
        insured.mint(claimant, escrow);
        vm.prank(claimant);
        insured.approve(address(defi), escrow);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(insured)), uint64(block.number - 1));
        vm.prank(claimant);
        uint256 claimId = defi.fileClaim(IERC20(address(insured)), escrow, 0, 0, 0, "");

        uint256[] memory noPayouts = new uint256[](0);
        bytes32 root = _leaf(1, claimId, claimant, noPayouts, 0, 0, escrow);
        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);
        bytes memory signature = _fixtureSettlementSignature(root, noPayouts, claimId, escrow, 0);
        vm.prank(admin);
        registry.setDefiInsurance(address(0));

        vm.expectRevert(DefiInsurance.DefiInsuranceNotRegistered.selector);
        defi.settleIncident(root, noPayouts, signature);
    }

    function test_staleModuleCannotCorrectSettlement() public {
        uint128 escrow = 50e18;
        insured.mint(claimant, escrow);
        vm.prank(claimant);
        insured.approve(address(defi), escrow);
        vm.prank(admin);
        defi.openClaimIncident(IERC20(address(insured)), uint64(block.number - 1));
        vm.prank(claimant);
        uint256 claimId = defi.fileClaim(IERC20(address(insured)), escrow, 0, 0, 0, "");

        uint256[] memory noPayouts = new uint256[](0);
        bytes32 root = _leaf(1, claimId, claimant, noPayouts, 0, 0, escrow);
        vm.warp(block.timestamp + defi.incidentPhaseWindow(1) + 1);
        defi.settleIncident(root, noPayouts, _fixtureSettlementSignature(root, noPayouts, claimId, escrow, 0));
        vm.prank(admin);
        registry.setDefiInsurance(address(0));

        vm.prank(admin);
        vm.expectRevert(DefiInsurance.DefiInsuranceNotRegistered.selector);
        defi.adminCorrectSettlement(bytes32(0), noPayouts);
    }

    function _signSettlement(
        bytes32 root,
        uint256[] memory poolPayouts,
        address[] memory expectedPools,
        uint256 expectedUnresolved,
        bytes32 expectedClaimSetHash,
        bytes32 expectedPcrHash
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                SETTLEMENT_TYPEHASH,
                uint256(1),
                root,
                expectedUnresolved,
                keccak256(abi.encodePacked(poolPayouts)),
                keccak256(abi.encodePacked(expectedPools)),
                expectedClaimSetHash,
                expectedPcrHash
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("DefiInsurance"),
                keccak256("1"),
                block.chainid,
                address(defi)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _fixtureSettlementSignature(
        bytes32 root,
        uint256[] memory poolPayouts,
        uint256 claimId,
        uint128 escrow,
        uint256 boosterAmount
    ) internal view returns (bytes memory) {
        bytes32 expectedClaimSetHash =
            keccak256(abi.encode(bytes32(0), claimId, claimant, escrow, uint256(0), boosterAmount));
        return _signSettlement(root, poolPayouts, new address[](0), uint256(1), expectedClaimSetHash, PCR_HASH);
    }

    function _leaf(
        uint256 incidentId,
        uint256 claimId,
        address user,
        uint256[] memory amounts,
        uint256 scoreSpent,
        uint256 boostedScore,
        uint256 eligibleAmount
    ) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(incidentId, claimId, user, amounts, scoreSpent, boostedScore, eligibleAmount))
            )
        );
    }
}
