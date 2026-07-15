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
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../src/Registry.sol";
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {USD8SavingsBootstrap} from "../src/deployment/USD8SavingsBootstrap.sol";
import {SingleAssetCoverPool} from "../src/SingleAssetCoverPool.sol";
import {DefiInsurance} from "../src/DefiInsurance.sol";
import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title  Deploy
/// @notice Deployer: Registry, USD8 (proxy + impl), Treasury (UUPS proxy + impl,
///         with two USDC yield strategies — Aave + Morpho), an official Morpho
///         Vault V2 savings share token (symbol `sUSD8`) with a custom idle/profit adapter,
///         a wstETH SingleAssetCoverPool
///         behind an UpgradeableBeacon (the capital base), and DefiInsurance (the
///         single payout module). Scored tokens (USD8, sUSD8) and the booster are
///         set on the Registry. Insured tokens and extra pools are left for
///         governance to add after deployment.
///
/// @dev    Governance split: the timelock role is a real OZ TimelockController
///         (minDelay {TIMELOCK_MIN_DELAY}; sole proposer/canceller
///         {DEFAULT_ADMIN}; open execution; self-administered — admin param
///         address(0), so delay/role changes go through its own delayed
///         proposals). The Registry admin role stays with {DEFAULT_ADMIN} during
///         beta and is explicitly privileged: it can operate pauses, profit routing,
///         strategy allocations, and incident/root controls. This is an accepted
///         trust assumption; migrate it to a monitored Safe before real user volume.
///         All deploy parameters
///         (admin, vault addresses, rates) are hardcoded constants below —
///         edit them in-place for a different network/signer.
///
/// ════════════════════════════ HARD RULES ════════════════════════════
/// Operational invariants that are NOT (all) enforced on-chain. Whoever
/// deploys and governs the system MUST uphold these:
///
///  1. TIMELOCK DELAY < DISPUTE_PERIOD. The governance timelock's minDelay
///     must be strictly less than DefiInsurance.DISPUTE_PERIOD, so a
///     timelock-initiated disputeIncident/closeIncident can still execute
///     inside the dispute window. (Admin can act with no delay regardless;
///     this covers the timelock-only route.) Otherwise a bad root cannot be
///     disputed in time.
///
///  2. KEEP A PAYOUT MODULE SET IN NORMAL OPS. The timelock replaces the module
///     via {Registry.setDefiInsurance}. Clearing it to zero is reserved as the
///     emergency brake for a module stuck reporting an incident — outside that,
///     never leave the slot empty.
///
///  3. NO DEFIINSURANCE WIRING CHANGES DURING AN ACTIVE INCIDENT. Do not
///     change/upgrade or re-point the DefiInsurance payout module registered
///     while an incident is in flight.
///
///  4. ONE INCIDENT AT A TIME — WAIT OUT FINALIZATION. Do not open a new
///     incident until the prior incident's finalization window has fully
///     closed. Keeps incidents cleanly isolated (the pool is only ever frozen
///     for / paid out of a single incident at once).
///
///  5. setTimelock IS IRREVERSIBLE — TRIPLE-CHECK THE ADDRESS. setTimelock is
///     single-step, and the timelock holds upgrade authority for Registry, USD8,
///     Treasury, and owns the immutable Morpho sUSD8 vault plus the pool beacon (all pools
///     upgrade through it). A wrong or
///     typo'd address permanently and unrecoverably loses governance AND
///     upgradeability. NOTE: the pool beacon is Ownable and its ownership is
///     transferred to the timelock in _handOffRoles — a separate handle from the
///     Registry timelock, so rotate BOTH on any governance migration.
///     Before calling, verify the new timelock is a live, correctly-owned
///     address/contract — on every contract. (admin is recoverable by the
///     timelock; the timelock itself is not.)
///
///  6. PRIVILEGED BETA ROLES ARE TRUSTED. DEFAULT_ADMIN proposes/cancels timelock
///     operations and retains immediate operational powers. Monitor every action,
///     use a Safe before meaningful TVL, and permanently end beta shortcuts when
///     governance is ready. Do not describe this role as deny-only.
/// ═════════════════════════════════════════════════════════════════════
contract DeployScript is Script {
    error WrongChainId(uint256 actual, uint256 expected);

    uint256 public constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    /// @notice Savings receives no launch revenue while dead seed shares dominate
    ///         supply. Governance may raise this after meaningful organic TVL exists.
    uint256 public constant INITIAL_SAVINGS_PROFIT_WEIGHT = 0;

    /// @notice Privileged beta governance EOA: Registry admin and the
    ///         TimelockController's sole proposer/canceller. Accepted trust assumption;
    ///         migrate to a monitored Safe before meaningful TVL.
    address constant DEFAULT_ADMIN = 0xB2E999D531D45a9115dA7706adFc651999f3c1F1;

    /// @notice TimelockController minDelay. MUST stay strictly under
    ///         DefiInsurance.DISPUTE_PERIOD (2 days) — HARD RULE 1 — including
    ///         any future updateDelay proposal.
    uint256 constant TIMELOCK_MIN_DELAY = 24 hours;

    /// @notice USDC seeded into the protocol at deploy. Minted 1:1 into USD8
    ///         and deposited into the Morpho Vault V2 sUSD8 vault with the shares burned, so the
    ///         vault can never be emptied to a near-zero supply — the
    ///         first-depositor inflation attack has no foothold. Backed by
    ///         real USDC, so it does NOT dilute the peg.
    ///         Deployer must hold at least this much USDC at run time.
    uint256 constant SEED_USDC = 100e6;

    /// @notice Burn sink for the seed shares. Not address(0) — ERC20 _mint
    ///         rejects the zero address — but equally unspendable.
    address constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;

    /// @notice Insurance-score rate for the two scored tokens, 1e18-scaled
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

    /// @notice ERC-4626 USDC vaults for the two launch Treasury strategies (Aave +
    ///         Morpho). Each reports asset() == USDC (checked on mainnet), which the
    ///         ERC4626Strategy constructor also enforces.
    ///           - AAVE_USDC_VAULT   = stataEthUSDC (Aave v3 static aUSDC ERC-4626 wrapper).
    ///           - MORPHO_USDC_VAULT = steakUSDC (Steakhouse USDC MetaMorpho vault).
    ///         Re-confirm liquidity/curation before large allocations; the queue
    ///         order (Aave first) also matters for redeem-path liquidity.
    address constant AAVE_USDC_VAULT = 0x73edDFa87C71ADdC275c2b9890f5c3a8480bC9E6;
    address constant MORPHO_USDC_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    /// @notice Canonical Ethereum Morpho Vault V2 factory.
    address constant MORPHO_VAULT_V2_FACTORY = 0xA1D94F746dEfa1928926b84fB2596c06926C0405;

    /// @notice Maximum positive sUSD8 share-price growth: 20% simple annual rate, WAD per second.
    uint256 constant SUSD8_MAX_RATE = 20e16 / uint256(365 days);
    bytes32 constant SUSD8_SALT = keccak256("USD8 Savings Morpho Vault V2");

    struct Deployed {
        TimelockController timelock;
        Registry registry;
        address usd8Impl;
        USD8 usd8;
        address treasuryImpl;
        Treasury treasury;
        IVaultV2 savings;
        address savingsAdapter;
        address savingsGate;
        address poolImpl;
        address poolBeacon;
        SingleAssetCoverPool wstethPool;
        address aaveStrategy;
        address morphoStrategy;
        DefiInsurance defiInsurance;
    }

    function run() external {
        if (block.chainid != ETHEREUM_MAINNET_CHAIN_ID) {
            revert WrongChainId(block.chainid, ETHEREUM_MAINNET_CHAIN_ID);
        }
        vm.startBroadcast();
        Deployed memory d = _deployAndWire(msg.sender);
        _handOffRoles(d, msg.sender, DEFAULT_ADMIN);
        vm.stopBroadcast();

        _logResults(d, DEFAULT_ADMIN);
    }

    function _deployAndWire(address deployer) internal returns (Deployed memory d) {
        // Governance timelock (OZ TimelockController). DEFAULT_ADMIN is the sole
        // proposer (and thereby canceller); executors = [address(0)] opens
        // execution to anyone once the delay has elapsed (the delay is the
        // security, execution is mechanical); admin = address(0) so the timelock
        // self-administers — it always holds DEFAULT_ADMIN_ROLE on itself, so
        // updateDelay / role changes go through its own delayed proposals.
        address[] memory proposers = new address[](1);
        proposers[0] = DEFAULT_ADMIN;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        d.timelock = new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, address(0));

        // Central access + pause registry. Deployer is timelock AND initial admin
        // for setup; roles are handed to governance on the Registry in
        // _handOffRoles. Every contract below keeps this as its fixed registry
        // pointer.
        // Registry is UUPS-upgradeable (impl + ERC-1967 proxy), timelock-gated upgrades.
        // maxCoverPoolPayoutBps defaults to 50% in initialize.
        d.registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (deployer, deployer)))
            )
        );

        // USD8 impl + ERC-1967 proxy. The locked implementation is the inert
        // placeholder treasury while we wire the real Treasury below — never the
        // broadcaster EOA, so a partial multi-transaction broadcast cannot leave
        // an externally controlled account with mint/burn authority.
        USD8 impl = new USD8();
        d.usd8Impl = address(impl);
        d.usd8 = USD8(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(USD8.initialize, (d.registry, address(impl)))))
        );

        // Treasury impl + ERC-1967 proxy (UUPS, timelock-upgraded in place, M-06).
        // Fresh-deployment path only: this does not migrate a funded legacy
        // constructor Treasury's reserve, strategies, or receiver configuration.
        Treasury treasuryImpl = new Treasury();
        d.treasuryImpl = address(treasuryImpl);
        d.treasury = Treasury(
            address(new ERC1967Proxy(address(treasuryImpl), abi.encodeCall(Treasury.initialize, (d.usd8, d.registry))))
        );

        // Flip USD8's mint/burn permission to Treasury so the seed mint goes
        // through the normal USDC-backed mint path (no unbacked supply).
        d.usd8.setTreasury(address(d.treasury));

        // Canonical Morpho Vault V2 sUSD8, custom idle/profit adapter, Registry pause gates,
        // and dead-share seed are created/configured atomically. The bootstrap owns the
        // fresh vault only during this transaction, then hands owner/curator/allocator
        // roles to the TimelockController. Seed USD8 is minted 1:1 from real USDC.
        USD8SavingsBootstrap savingsBootstrap = new USD8SavingsBootstrap();
        require(d.treasury.USDC().transfer(address(savingsBootstrap), SEED_USDC), "sUSD8 seed transfer failed");
        USD8SavingsBootstrap.Deployment memory savingsDeployment = savingsBootstrap.run(
            USD8SavingsBootstrap.Config({
                vaultFactory: MORPHO_VAULT_V2_FACTORY,
                registry: d.registry,
                usd8: d.usd8,
                treasury: d.treasury,
                seedUsdc: SEED_USDC,
                seedSink: SEED_SINK,
                governance: address(d.timelock),
                maxRate: SUSD8_MAX_RATE,
                salt: SUSD8_SALT
            })
        );
        d.savings = IVaultV2(savingsDeployment.vault);
        d.savingsAdapter = savingsDeployment.adapter;
        d.savingsGate = savingsDeployment.gate;
        assert(d.usd8.treasuryLocked());

        // SingleAssetCoverPool implementation behind a shared UpgradeableBeacon (owner
        // = deployer, handed to the timelock in _handOffRoles). One beacon upgrade
        // re-points every pool at once. Launch pool: wstETH, rewarded in USD8.
        SingleAssetCoverPool poolImpl = new SingleAssetCoverPool();
        d.poolImpl = address(poolImpl);
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(poolImpl), deployer);
        d.poolBeacon = address(beacon);
        IERC20 wsteth = IERC20(WSTETH);

        // Deploy the pool beacon proxy. No seed step: totalAssets is tracked accounting
        // (not balanceOf), so donations can't inflate price-per-share, and per-share
        // value only ever falls (on payout) — the first-depositor inflation attack has
        // no foothold. The OZ-style +1 virtual offset in stake/completeUnstake covers
        // the total-loss edge without locking capital. The pool is live on init.
        d.wstethPool = SingleAssetCoverPool(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (d.registry, wsteth, IERC20(address(d.usd8)), "USD8 wstETH Cover", "cpwstETH")
                    )
                )
            )
        );

        d.registry.addPool(address(d.wstethPool));

        // Scored tokens + booster live on the Registry. USD8 earns 10× sUSD8
        // (approximately 1.0 vs 0.1 score per whole token per day). Scoring starts
        // now; these first setScoredToken calls create the canonical onchain rate
        // histories that the offchain settlement computation reads at openBlock.
        d.registry.setScoredToken(IERC20(address(d.usd8)), USD8_SCORE_RATE);
        d.registry.setScoredToken(IERC20(address(d.savings)), SUSD8_SCORE_RATE);
        d.registry.setBoosterNFT(USD8_BOOSTER);

        // Register Morpho savings at zero launch weight: the irrecoverable seed
        // shares must not own pre-TVL Treasury revenue. Governance can re-weight
        // the adapter after meaningful organic deposits dilute the seed fraction.
        // The adapter mode is preconfigured correctly for that later activation.
        d.treasury
            .setProfitReceiver(
                d.savingsAdapter,
                INITIAL_SAVINGS_PROFIT_WEIGHT,
                Treasury.RevenueDistributionMode.ReceiveProfitDistribution
            );
        // Until savings is activated, all recurring Treasury revenue funds cover LPs.
        d.treasury
            .setProfitReceiver(address(d.wstethPool), 1, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        // DefiInsurance — the single insurance product (payout module). Registered on
        // the Registry so it can freeze the system and pay claims out of the pools;
        // the score a claim consumes is emitted as a ScoreSpent event (no ledger).
        // Insured tokens (incl. USD8 itself, once a token→underlying valuation recipe
        // is chosen) are left for governance via addInsuredToken, and the TEE
        // open-signer via setTeeSigner.
        d.defiInsurance = new DefiInsurance(d.registry);
        d.registry.setDefiInsurance(address(d.defiInsurance));

        // Treasury yield strategies: Aave + Morpho, each an ERC4626Strategy over a
        // USDC ERC-4626 vault (constructor reverts unless asset() == USDC). Added to
        // the withdrawal queue in order (index 0 = Aave, consulted first on redeem).
        // Idle USDC stays idle until governance moves it via depositToStrategy.
        d.aaveStrategy = address(new ERC4626Strategy(address(d.treasury), IERC4626(AAVE_USDC_VAULT)));
        d.morphoStrategy = address(new ERC4626Strategy(address(d.treasury), IERC4626(MORPHO_USDC_VAULT)));
        d.treasury.addStrategy(ERC4626Strategy(d.aaveStrategy), 0);
        d.treasury.addStrategy(ERC4626Strategy(d.morphoStrategy), 1);
    }

    function _handOffRoles(Deployed memory d, address deployer, address admin) internal {
        // The pool beacon is Ownable (holds upgrade authority for every pool) —
        // it belongs to the TIMELOCK (all upgrades are delayed), transferred
        // before dropping deployer roles.
        UpgradeableBeacon(d.poolBeacon).transferOwnership(address(d.timelock));

        // All access roles live on the single Registry. Hand off there once: grant
        // the governance admin, drop the deployer's bootstrap admin, then transfer
        // the timelock LAST (after which the deployer can no longer touch it). Skip
        // the drop when deployer == admin — else the two calls cancel out and the
        // system launches with an EMPTY admin set. setTimelock is IRREVERSIBLE
        // (HARD RULE 5): d.timelock is a contract this script just constructed
        // with known-good roles, which is exactly the verification that rule asks for.
        d.registry.setAdmin(admin, true);
        if (deployer != admin) d.registry.setAdmin(deployer, false);
        d.registry.setTimelock(address(d.timelock));
    }

    function _logResults(Deployed memory d, address admin) internal pure {
        console2.log("=== TimelockController ===");
        console2.log("Address:           ", address(d.timelock));
        console2.log("minDelay:          ", TIMELOCK_MIN_DELAY);
        console2.log("Proposer/canceller:", admin);
        console2.log("Executor:           open (anyone after delay)");
        console2.log("");
        console2.log("=== Registry ===");
        console2.log("Address:           ", address(d.registry));
        console2.log("");
        console2.log("=== USD8 ===");
        console2.log("Implementation:    ", d.usd8Impl);
        console2.log("Proxy:             ", address(d.usd8));
        console2.log("");
        console2.log("=== Treasury ===");
        console2.log("Implementation:    ", d.treasuryImpl);
        console2.log("Proxy:             ", address(d.treasury));
        console2.log("");
        console2.log("=== Morpho Vault V2 savings (share symbol sUSD8) ===");
        console2.log("Canonical factory: ", MORPHO_VAULT_V2_FACTORY);
        console2.log("Vault/share token: ", address(d.savings));
        console2.log("Savings adapter:   ", d.savingsAdapter);
        console2.log("Registry pause gate:", d.savingsGate);
        console2.log("maxRate (WAD/sec): ", SUSD8_MAX_RATE);
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
        console2.log("=== Privileged beta admin (accepted trust assumption) ===");
        console2.log("Address:           ", admin);
    }
}
