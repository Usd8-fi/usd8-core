// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title USD8 CREATE3 deployment labels
/// @notice Shared by both deployment steps so step 02 can locate step-01 contracts from the
///         deployer address alone.
/// @dev Every contract is deployed through CreateX CREATE3 with a deployer-guarded salt
///      derived from these labels (see {Create3Deployer}). The same deployer + label gives
///      the same address on every chain. NEVER rename or reuse a label for a different
///      contract; bump the version suffix for an intentional fresh deployment.
abstract contract USD8DeploymentLabels {
    string internal constant LABEL_TIMELOCK = "usd8.v1.TimelockController";
    string internal constant LABEL_REGISTRY_IMPL = "usd8.v1.Registry.impl";
    string internal constant LABEL_REGISTRY = "usd8.v1.Registry.proxy";
    string internal constant LABEL_USD8_IMPL = "usd8.v1.USD8.impl";
    string internal constant LABEL_USD8 = "usd8.v1.USD8.proxy";
    string internal constant LABEL_TREASURY_IMPL = "usd8.v1.Treasury.impl";
    string internal constant LABEL_TREASURY = "usd8.v1.Treasury.proxy";
    string internal constant LABEL_POOL_IMPL = "usd8.v1.SingleAssetCoverPool.impl";
    string internal constant LABEL_POOL_BEACON = "usd8.v1.SingleAssetCoverPool.beacon";
    string internal constant LABEL_WSTETH_POOL = "usd8.v1.SingleAssetCoverPool.wstETH";
    string internal constant LABEL_DEFI_INSURANCE_IMPL = "usd8.v1.DefiInsurance.impl";
    string internal constant LABEL_DEFI_INSURANCE = "usd8.v1.DefiInsurance.proxy";
    string internal constant LABEL_USD8_PRICE_ORACLE = "usd8.v1.USD8PriceOracle";
}
