// SPDX-License-Identifier: MIT
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {SavingsUSD8} from "../src/SavingsUSD8.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {AaveV3UsdcStrategy} from "../src/strategies/AaveV3UsdcStrategy.sol";
import {MorphoVaultStrategy} from "../src/strategies/MorphoVaultStrategy.sol";

/// @title  Deploy
/// @notice Beta-release deployer: USD8 (proxy + impl), Treasury, SavingsUSD8,
///         and strategies. CoverPool intentionally out of scope.
///
/// @dev    All admin / strategy manager roles land on a single EOA
///         ({DEFAULT_ADMIN}) — fine for beta, MUST be migrated to a Safe +
///         TimelockController before opening to real user volume. Override
///         the admin per-run with the `OVERRIDE_ADMIN` env var (useful for
///         testnet deploys with a different signer).
///
///         Optional env vars:
///           OVERRIDE_ADMIN   — replace the hardcoded {DEFAULT_ADMIN}.
///           MORPHO_VAULT_1   — first MetaMorpho USDC vault address.
///           MORPHO_VAULT_2   — second MetaMorpho USDC vault address.
///
///         Testnet runs (Tenderly Virtual TestNet, a mainnet fork) use
///         the same script unchanged — Aave v3 USDC and Morpho vaults are
///         all present at their mainnet addresses on the fork.
contract DeployScript is Script {
    /// @notice Single EOA used as admin + strategy manager on every contract.
    address constant DEFAULT_ADMIN = 0xB2E999D531D45a9115dA7706adFc651999f3c1F1;

    /// @notice Linear vesting window for SavingsUSD8 profit reports.
    ///         >= 7 days defeats JIT economically.
    uint64 constant SAVINGS_PROFIT_MAX_UNLOCK = 7 days;

    struct Deployed {
        address usd8Impl;
        USD8 usd8;
        Treasury treasury;
        SavingsUSD8 savings;
        AaveV3UsdcStrategy aaveStrat;
        MorphoVaultStrategy morphoStrat1;
        MorphoVaultStrategy morphoStrat2;
    }

    function run() external {
        address admin = vm.envOr("OVERRIDE_ADMIN", DEFAULT_ADMIN);
        address morphoVault1 = vm.envOr("MORPHO_VAULT_1", address(0));
        address morphoVault2 = vm.envOr("MORPHO_VAULT_2", address(0));

        vm.startBroadcast();
        Deployed memory d = _deployAndWire(msg.sender, morphoVault1, morphoVault2);
        _handOffAdmin(d, admin);
        vm.stopBroadcast();

        _logResults(d, admin, morphoVault1, morphoVault2);
    }

    function _deployAndWire(address deployer, address morphoVault1, address morphoVault2)
        internal
        returns (Deployed memory d)
    {
        // USD8 impl + ERC-1967 proxy. Deployer is initial admin AND placeholder
        // treasury so we can wire the real Treasury below.
        USD8 impl = new USD8();
        d.usd8Impl = address(impl);
        d.usd8 = USD8(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(USD8.initialize, (deployer, deployer))))
        );

        // Treasury — deployer is admin + strategy manager for setup.
        d.treasury = new Treasury(d.usd8, deployer, deployer);

        // Flip USD8's mint/burn permission from deployer to Treasury.
        d.usd8.setTreasury(address(d.treasury));

        // SavingsUSD8 — deployer is admin + strategy manager for setup.
        d.savings = new SavingsUSD8(d.usd8, deployer, deployer, SAVINGS_PROFIT_MAX_UNLOCK);

        // Aave v3 USDC strategy at Treasury index 0.
        d.aaveStrat = new AaveV3UsdcStrategy(address(d.treasury));
        d.treasury.addStrategy(IStrategy(address(d.aaveStrat)));

        // Optional MetaMorpho USDC strategies behind Aave.
        if (morphoVault1 != address(0)) {
            d.morphoStrat1 = new MorphoVaultStrategy(address(d.treasury), IERC4626(morphoVault1));
            d.treasury.addStrategy(IStrategy(address(d.morphoStrat1)));
        }
        if (morphoVault2 != address(0)) {
            d.morphoStrat2 = new MorphoVaultStrategy(address(d.treasury), IERC4626(morphoVault2));
            d.treasury.addStrategy(IStrategy(address(d.morphoStrat2)));
        }

        // Approve SavingsUSD8 as a profit-distribution recipient so harvested
        // revenue can be routed to it via Treasury.distributeRevenue.
        d.treasury.addRevenueRecipient(address(d.savings), Treasury.RevenueDistributionMode.ReceiveProfitDistribution);
    }

    function _handOffAdmin(Deployed memory d, address admin) internal {
        // setStrategyManager BEFORE setAdmin: both are onlyAdmin, and once the
        // deployer setAdmin-s away its role it can no longer set the manager.
        d.usd8.setAdmin(admin);

        d.treasury.setStrategyManager(admin);
        d.treasury.setAdmin(admin);

        d.savings.setStrategyManager(admin);
        d.savings.setAdmin(admin);
    }

    function _logResults(Deployed memory d, address admin, address morphoVault1, address morphoVault2)
        internal
        pure
    {
        console2.log("=== USD8 ===");
        console2.log("Implementation:    ", d.usd8Impl);
        console2.log("Proxy:             ", address(d.usd8));
        console2.log("");
        console2.log("=== Treasury ===");
        console2.log("Address:           ", address(d.treasury));
        console2.log("");
        console2.log("=== SavingsUSD8 ===");
        console2.log("Address:           ", address(d.savings));
        console2.log("ProfitMaxUnlock:   ", uint256(SAVINGS_PROFIT_MAX_UNLOCK));
        console2.log("");
        console2.log("=== Strategies ===");
        console2.log("AaveV3UsdcStrategy:", address(d.aaveStrat));
        if (address(d.morphoStrat1) != address(0)) {
            console2.log("MorphoVault (1):   ", address(d.morphoStrat1));
            console2.log("  -> vault:        ", morphoVault1);
        }
        if (address(d.morphoStrat2) != address(0)) {
            console2.log("MorphoVault (2):   ", address(d.morphoStrat2));
            console2.log("  -> vault:        ", morphoVault2);
        }
        console2.log("");
        console2.log("=== Admin (all roles) ===");
        console2.log("Address:           ", admin);
    }
}
