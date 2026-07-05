// SPDX-License-Identifier: BUSL-1.1
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
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../src/Registry.sol";
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {SavingsUSD8} from "../src/SavingsUSD8.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title  Deploy
/// @notice Deployer: Registry, USD8 (proxy + impl), Treasury (with two USDC yield
///         strategies — Aave + Morpho), SavingsUSD8, a wstETH SingleAssetCoverPool
///         behind an UpgradeableBeacon (the capital base), and DefiInsurance (the
///         single payout module). Scored tokens (USD8, sUSD8) and the booster are
///         set on the Registry. Insured tokens and extra pools are left for
///         governance to add after deployment.
///
/// @dev    Both roles (timelock + admin) land on a single EOA
///         ({DEFAULT_ADMIN}) — fine for beta, MUST be migrated to a Safe +
///         TimelockController before opening to real user volume. Override
///         the admin per-run with the OVERRIDE_ADMIN env var (useful for
///         testnet deploys with a different signer).
///
///         Optional env vars:
///           OVERRIDE_ADMIN     — replace the hardcoded {DEFAULT_ADMIN}.
///           AAVE_USDC_VAULT    — the Aave ERC-4626 USDC vault (else {AAVE_USDC_VAULT}).
///           MORPHO_USDC_VAULT  — the Morpho ERC-4626 USDC vault (else {MORPHO_USDC_VAULT}).
///
/// ════════════════════════════ HARD RULES ════════════════════════════
/// Operational invariants that are NOT (all) enforced on-chain. Whoever
/// deploys and governs the system MUST uphold these:
///
///  1. TIMELOCK DELAY < DISPUTE_PERIOD. The governance timelock's minDelay
///     must be strictly less than DefiInsurance.DISPUTE_PERIOD, so a
///     timelock-initiated closeIncident can still execute inside the
///     dispute window. Otherwise a bad root cannot be vetoed in time.
///
///  2. SEED EVERY COVER POOL, NEVER WITHDRAWN. When a pool is registered, the
///     team must stake a permanent amount that is never unstaked, so the pool's
///     earning base stays > 0 forever. This keeps reward emission from ever
///     stranding (the empty-pool carry-forward edge never triggers) and prevents
///     the pool from being share-drained to a bricked state.
///
///  3. KEEP A PAYOUT MODULE SET IN NORMAL OPS. The timelock replaces the module
///     via {Registry.setPayoutModule}. Clearing it to zero is reserved as the
///     emergency brake for a module stuck reporting an incident — outside that,
///     never leave the slot empty.
///
///  4. NO DEFIINSURANCE WIRING CHANGES DURING AN ACTIVE INCIDENT. Do not
///     change/upgrade or re-point the DefiInsurance payout module registered
///     while an incident is in flight.
///
///  5. ONE INCIDENT AT A TIME — WAIT OUT FINALIZATION. Do not open a new
///     incident until the prior incident's finalization window has fully
///     closed. Keeps incidents cleanly isolated (the pool is only ever frozen
///     for / paid out of a single incident at once).
///
///  6. setTimelock IS IRREVERSIBLE — TRIPLE-CHECK THE ADDRESS. setTimelock is
///     single-step, and the timelock holds upgrade authority for USD8 + SavingsUSD8
///     (UUPS) and owns the pool beacon (all pools upgrade through it). A wrong or
///     typo'd address permanently and unrecoverably loses governance AND
///     upgradeability. NOTE: the pool beacon is Ownable and its ownership is
///     transferred to the timelock in _handOffRoles — a separate handle from the
///     Registry timelock, so rotate BOTH on any governance migration.
///     Before calling, verify the new timelock is a live, correctly-owned
///     address/contract — on every contract. (admin is recoverable by the
///     timelock; the timelock itself is not.)
/// ═════════════════════════════════════════════════════════════════════
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

    /// @notice Burn sink for the seed shares. Not address(0) — ERC20 _mint
    ///         rejects the zero address — but equally unspendable.
    address constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;

    /// @notice scorePerTokenPerBlock for the two scored tokens, 1e18-scaled
    ///         (1e18 ⇒ 1.0 score/token/block). Set for a 12s-block chain
    ///         (7200 blocks/day) so a whole token accrues, per day: USD8 → 1.0
    ///         (1e18/7200), sUSD8 → 0.1 (1e18/72000). Frontend shows rate ×
    ///         7200 / 1e18.
    uint128 constant USD8_SCORE_RATE = 138888888888889; // 1e18 / 7200  ≈ 1.0/day
    uint128 constant SUSD8_SCORE_RATE = 13888888888889; // 1e18 / 72000 ≈ 0.1/day

    /// @notice Already-deployed USD8Booster ERC-1155 collection (mainnet). Set on
    ///         the Registry as the canonical booster.
    address constant USD8_BOOSTER = 0x6f74Ce39Bb1D75C56E2fe5f349a6A5f51ce6f12d;

    /// @notice Launch cover-pool stake asset: wstETH (mainnet). Underwriters stake
    ///         wstETH to underwrite coverage; rewarded in USD8.
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice Permanent seed for the wstETH cover pool, doubling as its
    ///         {SingleAssetCoverPool.minResidual}: payouts may never drain the pool
    ///         below this, and the matching seed shares are burned to an
    ///         uncontrollable sink so totalShares stays > 0 for good. Keeps the pool
    ///         non-brickable (empty-pool recap branch unreachable) and profit
    ///         distribution from ever hitting NoEligibleStakers. Deployer must hold
    ///         at least this much wstETH at run time (~0.01 wstETH).
    uint256 constant WSTETH_SEED = 0.01e18;

    /// @notice ERC-4626 USDC vaults for the two launch Treasury strategies (Aave +
    ///         Morpho). Each reports asset() == USDC (checked on mainnet), which the
    ///         ERC4626Strategy constructor also enforces. Override per-run via env
    ///         (AAVE_USDC_VAULT / MORPHO_USDC_VAULT).
    ///           - AAVE_USDC_VAULT   = stataEthUSDC (Aave v3 static aUSDC ERC-4626 wrapper).
    ///           - MORPHO_USDC_VAULT = steakUSDC (Steakhouse USDC MetaMorpho vault).
    ///         Re-confirm liquidity/curation before large allocations; the queue
    ///         order (Aave first) also matters for redeem-path liquidity.
    address constant AAVE_USDC_VAULT = 0x73edDFa87C71ADdC275c2b9890f5c3a8480bC9E6;
    address constant MORPHO_USDC_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    struct Deployed {
        Registry authority;
        address usd8Impl;
        USD8 usd8;
        Treasury treasury;
        address savingsImpl;
        SavingsUSD8 savings;
        address poolImpl;
        address poolBeacon;
        SingleAssetCoverPool wstethPool;
        address aaveStrategy;
        address morphoStrategy;
        DefiInsurance defiInsurance;
    }

    function run() external {
        address admin = vm.envOr("OVERRIDE_ADMIN", DEFAULT_ADMIN);

        vm.startBroadcast();
        Deployed memory d = _deployAndWire(msg.sender);
        _handOffRoles(d, msg.sender, admin);
        vm.stopBroadcast();

        _logResults(d, admin);
    }

    function _deployAndWire(address deployer) internal returns (Deployed memory d) {
        // Central access + pause registry. Deployer is timelock AND initial admin
        // for setup; roles are handed to governance on the Registry in
        // _handOffRoles. Every contract below takes this as an immutable.
        d.authority = new Registry(deployer, deployer);

        // USD8 impl + ERC-1967 proxy. Deployer is placeholder treasury so we can
        // wire the real Treasury below.
        USD8 impl = new USD8();
        d.usd8Impl = address(impl);
        d.usd8 =
            USD8(address(new ERC1967Proxy(address(impl), abi.encodeCall(USD8.initialize, (d.authority, deployer)))));

        // Treasury.
        d.treasury = new Treasury(d.usd8, d.authority);

        // Flip USD8's mint/burn permission to Treasury so the seed mint goes
        // through the normal USDC-backed mint path (no unbacked supply).
        d.usd8.setTreasury(address(d.treasury));

        // SavingsUSD8 impl + ERC-1967 proxy (UUPS).
        SavingsUSD8 savingsImpl = new SavingsUSD8();
        d.savingsImpl = address(savingsImpl);
        d.savings = SavingsUSD8(
            address(
                new ERC1967Proxy(address(savingsImpl), abi.encodeCall(SavingsUSD8.initialize, (d.authority, d.usd8)))
            )
        );

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

        // SingleAssetCoverPool implementation behind a shared UpgradeableBeacon (owner
        // = deployer, handed to the timelock in _handOffRoles). One beacon upgrade
        // re-points every pool at once. Launch pool: wstETH, rewarded in USD8.
        SingleAssetCoverPool poolImpl = new SingleAssetCoverPool();
        d.poolImpl = address(poolImpl);
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(poolImpl), deployer);
        d.poolBeacon = address(beacon);
        IERC20 wsteth = IERC20(WSTETH);
        d.wstethPool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize, (d.authority, wsteth, IERC20(address(d.usd8)), WSTETH_SEED)
                    )
                )
            )
        );

        // Permanent seed — MUST run here, immediately after the pool is created and
        // before it is exposed (registered, given a profit route, or opened to
        // stakers, all below). stake() reverts NotSeeded until this executes, so the
        // pool is inert until seeded; seeding now locks WSTETH_SEED of wstETH in
        // (shares burned to an uncontrollable sink) so the pool can never be fully
        // drained or emptied of stakers. Deployer must hold the wstETH; see {WSTETH_SEED}.
        wsteth.approve(address(d.wstethPool), WSTETH_SEED);
        d.wstethPool.seed(WSTETH_SEED);

        d.authority.addPool(wsteth, address(d.wstethPool));

        // Scored tokens + booster live on the Registry. sUSD8 earns 10× plain USD8;
        // scoring starts now.
        uint64 scoreStart = uint64(block.number);
        d.authority.setScoredToken(IERC20(address(d.usd8)), USD8_SCORE_RATE, scoreStart);
        d.authority.setScoredToken(IERC20(address(d.savings)), SUSD8_SCORE_RATE, scoreStart);
        d.authority.setBoosterNFT(USD8_BOOSTER);

        // Route Treasury profit to the pool (vesting-aware receiver).
        d.treasury
            .setProfitReceiver(address(d.wstethPool), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        // DefiInsurance — the single insurance product (payout module). Registered on
        // the Registry so it can freeze the system and pay claims out of the pools;
        // the score a claim consumes is emitted as a ScoreSpent event (no ledger).
        // Insured tokens (incl. USD8 itself, once a token→underlying valuation recipe
        // is chosen) are left for governance via addInsuredToken, and the TEE
        // open-signer via setTeeSigner.
        d.defiInsurance = new DefiInsurance(d.authority);
        d.authority.setPayoutModule(address(d.defiInsurance));

        // Treasury yield strategies: Aave + Morpho, each an ERC4626Strategy over a
        // USDC ERC-4626 vault (constructor reverts unless asset() == USDC). Added to
        // the withdrawal queue in order (index 0 = Aave, consulted first on redeem).
        // Idle USDC stays idle until governance moves it via depositToStrategy.
        address aaveVault = vm.envOr("AAVE_USDC_VAULT", AAVE_USDC_VAULT);
        address morphoVault = vm.envOr("MORPHO_USDC_VAULT", MORPHO_USDC_VAULT);
        d.aaveStrategy = address(new ERC4626Strategy(address(d.treasury), IERC4626(aaveVault)));
        d.morphoStrategy = address(new ERC4626Strategy(address(d.treasury), IERC4626(morphoVault)));
        d.treasury.addStrategy(ERC4626Strategy(d.aaveStrategy), 0);
        d.treasury.addStrategy(ERC4626Strategy(d.morphoStrategy), 1);
    }

    function _handOffRoles(Deployed memory d, address deployer, address admin) internal {
        // The pool beacon is Ownable (holds upgrade authority for every pool) —
        // transfer it to governance before dropping deployer roles.
        UpgradeableBeacon(d.poolBeacon).transferOwnership(admin);

        // All access roles live on the single Registry. Hand off there once: grant
        // the governance admin, drop the deployer's bootstrap admin, then transfer
        // the timelock LAST (after which the deployer can no longer touch it).
        d.authority.setAdmin(admin, true);
        d.authority.setAdmin(deployer, false);
        d.authority.setTimelock(admin);
    }

    function _logResults(Deployed memory d, address admin) internal pure {
        console2.log("=== Registry ===");
        console2.log("Address:           ", address(d.authority));
        console2.log("");
        console2.log("=== USD8 ===");
        console2.log("Implementation:    ", d.usd8Impl);
        console2.log("Proxy:             ", address(d.usd8));
        console2.log("");
        console2.log("=== Treasury ===");
        console2.log("Address:           ", address(d.treasury));
        console2.log("");
        console2.log("=== SavingsUSD8 ===");
        console2.log("Implementation:    ", d.savingsImpl);
        console2.log("Proxy:             ", address(d.savings));
        console2.log("");
        console2.log("=== SingleAssetCoverPool (wstETH) ===");
        console2.log("Implementation:    ", d.poolImpl);
        console2.log("Beacon:            ", d.poolBeacon);
        console2.log("wstETH pool proxy: ", address(d.wstethPool));
        console2.log("");
        console2.log("=== Treasury strategies ===");
        console2.log("Aave (ERC4626):    ", d.aaveStrategy);
        console2.log("Morpho (ERC4626):  ", d.morphoStrategy);
        console2.log("");
        console2.log("=== DefiInsurance ===");
        console2.log("Address:           ", address(d.defiInsurance));
        console2.log("");
        console2.log("=== Admin (all roles) ===");
        console2.log("Address:           ", admin);
    }
}
