// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/src/interfaces/IVaultV2Factory.sol";
import {Registry} from "../Registry.sol";
import {USD8} from "../USD8.sol";
import {Treasury} from "../Treasury.sol";
import {USD8SavingsAdapterFactory} from "../adapters/USD8SavingsAdapterFactory.sol";
import {USD8SavingsGate} from "./USD8SavingsGate.sol";

/// @title USD8 Savings Bootstrap
/// @notice One-shot atomic deployment, configuration and dead-share seeding of canonical Morpho Vault V2 sUSD8.
contract USD8SavingsBootstrap {
    using SafeERC20 for IERC20;

    struct Deployment {
        address bootstrap;
        address vault;
        address adapter;
        address adapterFactory;
        address gate;
    }

    struct Config {
        address vaultFactory;
        Registry registry;
        USD8 usd8;
        Treasury treasury;
        uint256 seedUsdc;
        address seedSink;
        address governance;
        uint256 maxRate;
        bytes32 salt;
    }

    address public immutable owner;
    bool public executed;

    error NotOwner();
    error AlreadyExecuted();
    error InvalidAddress();
    error InvalidFactory();
    error ConfigurationCallFailed(bytes data);

    constructor() {
        owner = msg.sender;
    }

    function run(Config calldata config) external returns (Deployment memory d) {
        if (msg.sender != owner) revert NotOwner();
        if (executed) revert AlreadyExecuted();
        if (
            config.vaultFactory == address(0) || address(config.registry) == address(0)
                || address(config.usd8) == address(0) || address(config.treasury) == address(0)
                || config.seedSink == address(0) || config.governance == address(0)
        ) revert InvalidAddress();
        if (config.vaultFactory.code.length == 0) revert InvalidFactory();
        executed = true;
        d.bootstrap = address(this);

        IVaultV2Factory factory = IVaultV2Factory(config.vaultFactory);
        d.vault = factory.createVaultV2(address(this), address(config.usd8), config.salt);
        if (!factory.isVaultV2(d.vault)) revert InvalidFactory();
        IVaultV2 vault = IVaultV2(d.vault);

        vault.setName("Savings USD8");
        vault.setSymbol("sUSD8");
        vault.setCurator(address(this));

        USD8SavingsAdapterFactory adapterFactory = new USD8SavingsAdapterFactory();
        d.adapterFactory = address(adapterFactory);
        d.adapter = adapterFactory.createUSD8SavingsAdapter(d.vault);
        d.gate = address(new USD8SavingsGate(config.registry, d.vault));

        _execute(vault, abi.encodeCall(IVaultV2.setIsAllocator, (address(this), true)));
        _execute(vault, abi.encodeCall(IVaultV2.addAdapter, (d.adapter)));

        bytes memory idData = abi.encode("this", d.adapter);
        _execute(vault, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        _execute(vault, abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        _execute(vault, abi.encodeCall(IVaultV2.setReceiveSharesGate, (d.gate)));
        _execute(vault, abi.encodeCall(IVaultV2.setSendSharesGate, (d.gate)));
        _execute(vault, abi.encodeCall(IVaultV2.setReceiveAssetsGate, (d.gate)));
        _execute(vault, abi.encodeCall(IVaultV2.setSendAssetsGate, (d.gate)));

        vault.setMaxRate(config.maxRate);
        vault.setLiquidityAdapterAndData(d.adapter, "");

        IERC20 usdc = IERC20(address(config.treasury.USDC()));
        usdc.forceApprove(address(config.treasury), config.seedUsdc);
        config.treasury.mintUSD8(config.seedUsdc);
        uint256 seedUsd8 = config.seedUsdc * config.treasury.USDC_TO_USD8_SCALE();
        IERC20(address(config.usd8)).forceApprove(d.vault, seedUsd8);
        vault.deposit(seedUsd8, config.seedSink);

        _execute(vault, abi.encodeCall(IVaultV2.setIsAllocator, (config.governance, true)));
        _execute(vault, abi.encodeCall(IVaultV2.setIsAllocator, (address(this), false)));
        vault.setCurator(config.governance);
        vault.setOwner(config.governance);
    }

    function _execute(IVaultV2 vault, bytes memory data) internal {
        vault.submit(data);
        (bool success,) = address(vault).call(data);
        if (!success) revert ConfigurationCallFailed(data);
    }
}
