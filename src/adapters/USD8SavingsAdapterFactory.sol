// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {USD8SavingsAdapter} from "./USD8SavingsAdapter.sol";

/// @title USD8 Savings Adapter Factory
/// @notice Canonical factory surface for Morpho indexing and deterministic adapter discovery.
contract USD8SavingsAdapterFactory {
    mapping(address parentVault => address) public usd8SavingsAdapter;
    mapping(address account => bool) public isUSD8SavingsAdapter;

    event CreateUSD8SavingsAdapter(address indexed parentVault, address indexed adapter);

    function createUSD8SavingsAdapter(address parentVault) external returns (address) {
        address adapter = address(new USD8SavingsAdapter{salt: bytes32(0)}(parentVault));
        usd8SavingsAdapter[parentVault] = adapter;
        isUSD8SavingsAdapter[adapter] = true;
        emit CreateUSD8SavingsAdapter(parentVault, adapter);
        return adapter;
    }
}
