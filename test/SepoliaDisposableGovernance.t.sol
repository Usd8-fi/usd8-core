// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Registry} from "../src/Registry.sol";
import {SepoliaDisposableGovernance} from "../script/testnet/SepoliaDisposableGovernance.sol";

contract SepoliaDisposableGovernanceHarness {
    function payload(SepoliaDisposableGovernance.Action action, address insurance)
        external
        pure
        returns (bytes memory)
    {
        return SepoliaDisposableGovernance.payload(action, insurance);
    }

    function salt(SepoliaDisposableGovernance.Action action, address registry, address insurance)
        external
        pure
        returns (bytes32)
    {
        return SepoliaDisposableGovernance.salt(action, registry, insurance);
    }

    function requireDisposable(address registry, address insurance) external pure {
        SepoliaDisposableGovernance.requireDisposable(registry, insurance);
    }
}

contract SepoliaDisposableGovernanceTest is Test {
    address internal constant CANONICAL_REGISTRY = 0xB34D92cd05005DF36050370433819597a9BaC693;
    address internal constant CANONICAL_INSURANCE = 0x4E346CcD0a46D51ebaE6810d653791982968d502;

    SepoliaDisposableGovernanceHarness internal harness;

    function setUp() public {
        harness = new SepoliaDisposableGovernanceHarness();
    }

    function test_U21DeregisterPayloadClearsOnlyTheDisposableRegistryModule() public view {
        assertEq(
            harness.payload(SepoliaDisposableGovernance.Action.U21Deregister, address(0x2222)),
            abi.encodeCall(Registry.setDefiInsurance, (address(0)))
        );
    }

    function test_U21RestorePayloadRestoresTheExactDisposableModule() public view {
        address insurance = address(0x2222);
        assertEq(
            harness.payload(SepoliaDisposableGovernance.Action.U21Restore, insurance),
            abi.encodeCall(Registry.setDefiInsurance, (insurance))
        );
    }

    function test_U25PayloadEndsBetaWithoutAnUnrelatedCall() public view {
        assertEq(
            harness.payload(SepoliaDisposableGovernance.Action.U25EndBeta, address(0x2222)),
            abi.encodeCall(Registry.endBetaMode, ())
        );
    }

    function test_SaltsBindActionAndExactTopology() public view {
        address registry = address(0x1111);
        address insurance = address(0x2222);
        bytes32 deregister = harness.salt(SepoliaDisposableGovernance.Action.U21Deregister, registry, insurance);

        assertEq(
            deregister,
            keccak256(
                abi.encode(
                    "USD8 Sepolia disposable governance v1",
                    SepoliaDisposableGovernance.Action.U21Deregister,
                    registry,
                    insurance
                )
            )
        );
        assertTrue(deregister != harness.salt(SepoliaDisposableGovernance.Action.U21Restore, registry, insurance));
        assertTrue(
            deregister != harness.salt(SepoliaDisposableGovernance.Action.U21Deregister, address(0x3333), insurance)
        );
    }

    function test_RejectsCanonicalAllRoutesTopology() public {
        vm.expectRevert(SepoliaDisposableGovernance.CanonicalTopology.selector);
        harness.requireDisposable(CANONICAL_REGISTRY, address(0x2222));

        vm.expectRevert(SepoliaDisposableGovernance.CanonicalTopology.selector);
        harness.requireDisposable(address(0x1111), CANONICAL_INSURANCE);
    }

    function test_RejectsZeroOrAliasedTopologyAddresses() public {
        vm.expectRevert(SepoliaDisposableGovernance.InvalidTopology.selector);
        harness.requireDisposable(address(0), address(0x2222));

        vm.expectRevert(SepoliaDisposableGovernance.InvalidTopology.selector);
        harness.requireDisposable(address(0x1111), address(0));

        vm.expectRevert(SepoliaDisposableGovernance.InvalidTopology.selector);
        harness.requireDisposable(address(0x1111), address(0x1111));
    }
}
