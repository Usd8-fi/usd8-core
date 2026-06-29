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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {SavingsUSD8} from "../src/SavingsUSD8.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {DefiInsurance, ICoverPool} from "../src/DefiInsurance.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {AaveV3UsdcStrategy} from "../src/strategies/AaveV3UsdcStrategy.sol";
import {MorphoVaultStrategy} from "../src/strategies/MorphoVaultStrategy.sol";

/// @title  Deploy
/// @notice Deployer: USD8 (proxy + impl), Treasury, SavingsUSD8, strategies,
///         CoverPool (the capital base, seeded with two scored tokens — USD8 and
///         sUSD8), and DefiInsurance (a payout module registered on the pool).
///         Insured tokens and stake assets are left for governance.
///
/// @dev    Both roles (timelock + admin) land on a single EOA
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
    /// @notice Single EOA used as timelock + admin on every contract.
    address constant DEFAULT_ADMIN = 0xB2E999D531D45a9115dA7706adFc651999f3c1F1;

    /// @notice USDC seeded into the protocol at deploy. Minted 1:1 into USD8
    ///         and deposited into SavingsUSD8 with the shares burned, so the
    ///         vault can never be emptied to a near-zero supply — the
    ///         first-depositor inflation attack has no foothold. Backed by
    ///         real USDC, so it does NOT dilute the peg.
    ///         Deployer must hold at least this much USDC at run time.
    uint256 constant SEED_USDC = 100e6;

    /// @notice Burn sink for the seed shares. Not `address(0)` — ERC20 `_mint`
    ///         rejects the zero address — but equally unspendable.
    address constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;

    /// @notice scorePerTokenPerBlock for the two scored tokens. Small integers
    ///         (not 1e18-scaled) so cumulative scores stay manageable; sUSD8
    ///         earns 10× plain USD8 to reward staking.
    uint128 constant USD8_SCORE_RATE = 1;
    uint128 constant SUSD8_SCORE_RATE = 10;

    /// @notice Already-deployed USD8Booster ERC-1155 collection (mainnet). Wired
    ///         into CoverPool at init as the canonical booster.
    address constant USD8_BOOSTER = 0x6f74Ce39Bb1D75C56E2fe5f349a6A5f51ce6f12d;

    struct Deployed {
        address usd8Impl;
        USD8 usd8;
        Treasury treasury;
        SavingsUSD8 savings;
        AaveV3UsdcStrategy aaveStrat;
        MorphoVaultStrategy morphoStrat1;
        MorphoVaultStrategy morphoStrat2;
        address coverPoolImpl;
        CoverPool coverPool;
        DefiInsurance defiInsurance;
    }

    function run() external {
        address admin = vm.envOr("OVERRIDE_ADMIN", DEFAULT_ADMIN);
        address morphoVault1 = vm.envOr("MORPHO_VAULT_1", address(0));
        address morphoVault2 = vm.envOr("MORPHO_VAULT_2", address(0));

        vm.startBroadcast();
        Deployed memory d = _deployAndWire(msg.sender, morphoVault1, morphoVault2);
        _handOffRoles(d, admin);
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
        d.usd8 = USD8(address(new ERC1967Proxy(address(impl), abi.encodeCall(USD8.initialize, (deployer, deployer)))));

        // Treasury — deployer holds both roles for setup.
        d.treasury = new Treasury(d.usd8, deployer, deployer);

        // Flip USD8's mint/burn permission to Treasury so the seed mint goes
        // through the normal USDC-backed mint path (no unbacked supply).
        d.usd8.setTreasury(address(d.treasury));

        // SavingsUSD8 — deployer holds both roles for setup.
        d.savings = new SavingsUSD8(d.usd8, deployer, deployer);

        // Seed SavingsUSD8 against the first-depositor inflation attack.
        // Mint USD8 1:1 from real USDC (so the seed is fully backed and the
        // peg is unaffected), deposit it, and burn the shares to SEED_SINK so
        // the vault's supply can never be drained back toward zero.
        IERC20 usdc = d.treasury.USDC();
        usdc.approve(address(d.treasury), SEED_USDC);
        d.treasury.mintUSD8(SEED_USDC);
        uint256 seedUsd8 = SEED_USDC * d.treasury.USDC_TO_USD8_SCALE();
        d.usd8.approve(address(d.savings), seedUsd8);
        d.savings.deposit(seedUsd8, SEED_SINK);

        // CoverPool impl + ERC-1967 proxy — the shared capital base. USD8 is the
        // reward token; the pool holds the insurance-score ledger and the canonical
        // booster collection (the already-deployed {USD8_BOOSTER}). Deployer holds
        // both roles; seed scored tokens.
        CoverPool cpImpl = new CoverPool();
        d.coverPoolImpl = address(cpImpl);
        d.coverPool = CoverPool(
            address(
                new ERC1967Proxy(
                    address(cpImpl),
                    abi.encodeCall(CoverPool.initialize, (IERC20(address(d.usd8)), deployer, deployer, USD8_BOOSTER))
                )
            )
        );

        // Scored tokens: holding sUSD8 earns 10× plain USD8. Scoring starts now.
        uint64 scoreStart = uint64(block.number);
        d.coverPool.addScoredToken(IERC20(address(d.usd8)), USD8_SCORE_RATE, scoreStart);
        d.coverPool.addScoredToken(IERC20(address(d.savings)), SUSD8_SCORE_RATE, scoreStart);

        // DefiInsurance — the first insurance product (a pool payout module).
        // Non-upgradeable, deployed directly. Register it on the pool so it can
        // lock, pay, and spend score. Insured tokens are left for governance to add.
        d.defiInsurance = new DefiInsurance(ICoverPool(address(d.coverPool)), deployer, deployer);
        d.coverPool.setPayoutModule(address(d.defiInsurance), true);

        // Aave v3 USDC strategy at Treasury index 0.
        d.aaveStrat = new AaveV3UsdcStrategy(address(d.treasury));
        d.treasury.addStrategy(IStrategy(address(d.aaveStrat)), type(uint256).max);

        // Optional MetaMorpho USDC strategies behind Aave.
        if (morphoVault1 != address(0)) {
            d.morphoStrat1 = new MorphoVaultStrategy(address(d.treasury), IERC4626(morphoVault1));
            d.treasury.addStrategy(IStrategy(address(d.morphoStrat1)), type(uint256).max);
        }
        if (morphoVault2 != address(0)) {
            d.morphoStrat2 = new MorphoVaultStrategy(address(d.treasury), IERC4626(morphoVault2));
            d.treasury.addStrategy(IStrategy(address(d.morphoStrat2)), type(uint256).max);
        }
    }

    function _handOffRoles(Deployed memory d, address admin) internal {
        // setAdmin BEFORE setTimelock: setAdmin is onlyTimelock, and once the
        // deployer setTimelock-s away its role it can no longer set the admin.
        d.usd8.setTimelock(admin);

        d.treasury.setAdmin(admin);
        d.treasury.setTimelock(admin);

        d.savings.setAdmin(admin);
        d.savings.setTimelock(admin);

        d.coverPool.setAdmin(admin);
        d.coverPool.setTimelock(admin);

        d.defiInsurance.setAdmin(admin);
        d.defiInsurance.setTimelock(admin);
    }

    function _logResults(Deployed memory d, address admin, address morphoVault1, address morphoVault2) internal pure {
        console2.log("=== USD8 ===");
        console2.log("Implementation:    ", d.usd8Impl);
        console2.log("Proxy:             ", address(d.usd8));
        console2.log("");
        console2.log("=== Treasury ===");
        console2.log("Address:           ", address(d.treasury));
        console2.log("");
        console2.log("=== SavingsUSD8 ===");
        console2.log("Address:           ", address(d.savings));
        console2.log("");
        console2.log("=== CoverPool ===");
        console2.log("Implementation:    ", d.coverPoolImpl);
        console2.log("Proxy:             ", address(d.coverPool));
        console2.log("");
        console2.log("=== DefiInsurance ===");
        console2.log("Address:           ", address(d.defiInsurance));
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
