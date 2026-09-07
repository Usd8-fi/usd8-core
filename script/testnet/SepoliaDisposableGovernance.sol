// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Registry} from "../../src/Registry.sol";

/// @notice Exact calldata and topology binding for destructive all-routes governance lanes.
/// @dev The canonical all-routes Registry and insurance module are rejected unconditionally.
library SepoliaDisposableGovernance {
    enum Action {
        U21Deregister,
        U21Restore,
        U25EndBeta
    }

    address internal constant CANONICAL_ALL_ROUTES_REGISTRY = 0xB34D92cd05005DF36050370433819597a9BaC693;
    address internal constant CANONICAL_ALL_ROUTES_INSURANCE = 0x4E346CcD0a46D51ebaE6810d653791982968d502;

    error CanonicalTopology();
    error InvalidTopology();

    function requireDisposable(address registry, address insurance) internal pure {
        if (registry == address(0) || insurance == address(0) || registry == insurance) revert InvalidTopology();
        if (registry == CANONICAL_ALL_ROUTES_REGISTRY || insurance == CANONICAL_ALL_ROUTES_INSURANCE) {
            revert CanonicalTopology();
        }
    }

    function payload(Action action, address insurance) internal pure returns (bytes memory) {
        if (action == Action.U21Deregister) return abi.encodeCall(Registry.setDefiInsurance, (address(0)));
        if (action == Action.U21Restore) return abi.encodeCall(Registry.setDefiInsurance, (insurance));
        return abi.encodeCall(Registry.endBetaMode, ());
    }

    function salt(Action action, address registry, address insurance) internal pure returns (bytes32) {
        return keccak256(abi.encode("USD8 Sepolia disposable governance v1", action, registry, insurance));
    }
}
