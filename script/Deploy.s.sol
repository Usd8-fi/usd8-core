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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {USD8} from "../src/USD8.sol";
import {Treasury} from "../src/Treasury.sol";
import {SavingsUSD8} from "../src/SavingsUSD8.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {DefiInsurance, ICoverPool} from "../src/DefiInsurance.sol";

/// @title  Deploy
/// @notice Deployer: USD8 (proxy + impl), Treasury, SavingsUSD8, CoverPool (the
///         capital base, seeded with two scored tokens — USD8 and sUSD8), and
///         DefiInsurance (a payout module registered on the pool). Insured
///         tokens, stake assets, and Treasury strategies are left for governance
///         to add after deployment.
///
/// @dev    Both roles (timelock + admin) land on a single EOA
///         ({DEFAULT_ADMIN}) — fine for beta, MUST be migrated to a Safe +
///         TimelockController before opening to real user volume. Override
///         the admin per-run with the OVERRIDE_ADMIN env var (useful for
///         testnet deploys with a different signer).
///
///         Optional env vars:
///           OVERRIDE_ADMIN   — replace the hardcoded {DEFAULT_ADMIN}.
///
/// ════════════════════════════ HARD RULES ════════════════════════════
/// Operational invariants that are NOT (all) enforced on-chain. Whoever
/// deploys and governs the system MUST uphold these:
///
///  1. TIMELOCK DELAY < DISPUTE_PERIOD. The governance timelock's minDelay
///     must be strictly less than DefiInsurance.DISPUTE_PERIOD, so a
///     timelock-initiated voidSettlement can still execute inside the
///     dispute window. Otherwise a bad root cannot be vetoed in time.
///
///  2. SEED EVERY COVER-POOL STAKE ASSET, NEVER WITHDRAWN. When a stake
///     asset is added, the team must stake a permanent amount that is never
///     unstaked, so the asset's earning base stays > 0 forever. This keeps
///     reward emission from ever stranding (the empty-base carry-forward
///     edge never triggers) and prevents the asset from being share-drained
///     to a bricked state.
///
///  3. SWAP PAYOUT MODULES, NEVER LEAVE NONE. The admin may only replace the
///     active payout module via setPayoutModule; never deregister the active
///     module without registering a replacement.
///
///  4. NO DEFIINSURANCE WIRING CHANGES DURING AN ACTIVE INCIDENT. Do not
///     change/upgrade or re-point the DefiInsurance payout module registered
///     on CoverPool while an incident is in flight.
///
///  5. ONE INCIDENT AT A TIME — WAIT OUT FINALIZATION. Do not open a new
///     incident until the prior incident's finalization window has fully
///     closed. Keeps incidents cleanly isolated (the pool is only ever frozen
///     for / paid out of a single incident at once).
///
///  6. setTimelock IS IRREVERSIBLE — TRIPLE-CHECK THE ADDRESS. setTimelock is
///     single-step on every contract, and the timelock holds UUPS upgrade
///     authority (USD8, CoverPool). A wrong or typo'd address permanently and
///     unrecoverably loses governance AND upgradeability for that contract.
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

    /// @notice Already-deployed USD8Booster ERC-1155 collection (mainnet). Wired
    ///         into CoverPool at init as the canonical booster.
    address constant USD8_BOOSTER = 0x6f74Ce39Bb1D75C56E2fe5f349a6A5f51ce6f12d;

    struct Deployed {
        address usd8Impl;
        USD8 usd8;
        Treasury treasury;
        SavingsUSD8 savings;
        address coverPoolImpl;
        CoverPool coverPool;
        DefiInsurance defiInsurance;
    }

    function run() external {
        address admin = vm.envOr("OVERRIDE_ADMIN", DEFAULT_ADMIN);

        vm.startBroadcast();
        Deployed memory d = _deployAndWire(msg.sender);
        _handOffRoles(d, admin);
        vm.stopBroadcast();

        _logResults(d, admin);
    }

    function _deployAndWire(address deployer) internal returns (Deployed memory d) {
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

        // Treasury strategies (Aave / Morpho) are NOT deployed here — governance
        // adds them post-deployment via Treasury.addStrategy.
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

    function _logResults(Deployed memory d, address admin) internal pure {
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
        console2.log("=== Admin (all roles) ===");
        console2.log("Address:           ", admin);
    }
}
