// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    IReceiveSharesGate,
    ISendSharesGate,
    IReceiveAssetsGate,
    ISendAssetsGate
} from "vault-v2/src/interfaces/IGate.sol";
import {Registry} from "../Registry.sol";

/// @title USD8 Savings Gate
/// @notice Preserves Registry emergency-pause behavior for the immutable Morpho sUSD8 vault.
contract USD8SavingsGate is IReceiveSharesGate, ISendSharesGate, IReceiveAssetsGate, ISendAssetsGate {
    Registry public immutable registry;
    address public immutable vault;

    constructor(Registry _registry, address _vault) {
        registry = _registry;
        vault = _vault;
    }

    function canReceiveShares(address) external view returns (bool) {
        return !registry.paused(vault);
    }

    function canSendShares(address) external view returns (bool) {
        return !registry.paused(vault);
    }

    function canReceiveAssets(address) external view returns (bool) {
        return !registry.paused(vault);
    }

    function canSendAssets(address) external view returns (bool) {
        return !registry.paused(vault);
    }
}
