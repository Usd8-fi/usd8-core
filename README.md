# USD8 Core

Stablecoin protocol contracts for [usd8.fi](https://usd8.fi).

Please note this repo is under development, codebase is expected to change often, there are no bug bounties, do not report bugs for now.

> **Deployment note:** the Treasury UUPS conversion and USD8's permanent Treasury lock are a fresh-deployment path.
> They do not migrate reserve assets, strategy state, receiver configuration, or historical issuance state from legacy deployments.

## Release scope

Ships the core stablecoin stack:

- [`Registry`](src/Registry.sol) — UUPS-upgradeable access + pause + topology hub. Holds the timelock/admin roles, per-contract pause flags, the pool set, the single payout module, the incident-freeze flag, the insurance-score token set, and the booster collection. Every other core contract inherits [`RegistryManaged`](src/RegistryManaged.sol) and defers to it.
- [`USD8`](src/USD8.sol) — UUPS-upgradeable ERC20 stablecoin. Mint/burn restricted to a configured Treasury.
- [`Treasury`](src/Treasury.sol) — UUPS-upgradeable, fixed-address reserve anchor. Wraps mainnet USDC into USD8 at a fixed 1:1 peg, manages approved yield strategies, and (via `harvestAndDistribute`) harvests surplus and routes it to weighted profit receivers.
- **USD8 savings** — canonical Morpho Vault V2 share token (symbol `sUSD8`; there is no custom sUSD8 vault contract) backed by [`USD8SavingsAdapter`](src/adapters/USD8SavingsAdapter.sol). Deposits remain idle in the adapter; Treasury profit enters through an accounting hook and Morpho `maxRate` smooths share-price growth. Registry-backed gates preserve emergency pause behavior.
- [`SingleAssetCoverPool`](src/SingleAssetCoverPool.sol) — single-asset staking pool (one per stake asset, behind a shared beacon) whose deposits may be drawn upon to cover losses from covered DeFi protocols. Stakers earn USD8 yield in exchange for loss-coverage risk. Multi-asset coverage is replication: deploy another pool per asset.
- [`DefiInsurance`](src/DefiInsurance.sol) — the single payout module: insured-token registry, incident lifecycle, claimant escrow, and TEE-signed settlement; pays claims out of the registered pools.
- [`ERC4626Strategy`](src/strategies/ERC4626Strategy.sol) — `IStrategy` adapter that deploys Treasury USDC into any ERC-4626 USDC vault (Aave v3 static aUSDC, MetaMorpho, …); one instance per vault.

## Architecture overview

```

        ┌───────────┐
        │   Users   │
        └───────────┘
              ▲                                     ┌────────────────┐
              │ 1.Mint/Redeem                       │  USD8 Savings  │
              │   USD8<->USDC           ┌──────────►│  Morpho Vault  │
              │                         │           └────────────────┘
              ▼                         │
┌───────────────────────────┐           │
│                           │           │
│       USD8 Treasury       │           │           ┌───────────────┐
│           (USDC)          │           ├──────────►│  USD8 Cover   │
│                           │           │           │    Pool 1     │
└────────────┬──────────────┘           │           └───────────────┘
             │                          │
             │                          │
             │  2. Deploy               │           ┌───────────────┐
             │                          ├──────────►│   USD8 Cover  │
             ▼                          │           │     Pool 2    │
   ┌────────────────────┐               │           └───────────────┘
   │   Yield Strategies ├───────────────┘
   └────────────────────┘   3. Profit Distribution


```

Profit distribution is weight-routed to registered receivers via [`Treasury.harvestAndDistribute`](src/Treasury.sol) (or the ad-hoc `distributeRevenue`). The Morpho savings adapter is registered with **zero launch weight**, so dead seed shares receive no pre-TVL Treasury revenue; governance may activate it after meaningful organic deposits dilute the seed fraction. Until then, recurring revenue goes to the cover pool. Only Treasury has a strategy queue. Savings deposits remain idle in the adapter, while its `realAssets()` reports principal plus realized Treasury donations to Morpho Vault V2.

## Deployment and trust assumptions

- `Deploy.s.sol` is hard-locked to Ethereum mainnet (`block.chainid == 1`) before broadcasting because its dependency addresses are mainnet-specific.
- The Registry admin and timelock are privileged by design during beta. They control upgrades, topology, strategy allocation, profit routing, pauses, and incident/root operations. This is an accepted trust assumption, not a deny-only role; migrate the admin/proposer to a monitored Safe before meaningful TVL.
- Morpho seed shares remain permanently burned to prevent first-depositor inflation. Savings profit weight stays zero until governance confirms meaningful organic TVL, then monitors `deadShares / totalSupply` when activating revenue.

## Cover pool flows

Stakers deposit the pool's asset and earn USD8 yield in exchange for accepting loss-coverage risk. Claimants escrow a covered protocol's token; after the TEE signs one settlement root, each claimant may prove their allocation against that root and draw from the registered pools. One incident is processed at a time. While it is active, every cover pool is frozen: new stakes and completed exits are blocked, pending exit shares keep earning and absorbing losses, and a second incident cannot open.

### Staking and incident-delayed exits

```
 deposit / mint (only while no incident is active)
                         │
                         ▼
                ┌──────────────────┐
                │      STAKED      │
                │ earning high APY │──── claimReward ───▶ USD8
                │ absorbing losses │
                └──────────────────┘
                         │ requestRedeem
                         ▼
                ┌──────────────────┐
                │  7-DAY COOLDOWN  │
                │ still earning APY│
                └──────────────────┘
                         │
                         ▼
                  incident active?
                    │          │
                   no         yes
                    │          │
                    ▼          ▼
       ┌──────────────────┐   ┌──────────────────┐
       │ 2-DAY EXIT WINDOW│   │ WAIT FOR INCIDENT│
       └──────────────────┘   │      TO END      │
                    │         │ still earning APY│
                    │         └──────────────────┘
                    │                   │ incident ends
                    │                   ▼
                    │         ┌──────────────────┐
                    │         │ FRESH 2-DAY EXIT │
                    │         └──────────────────┘
                    │                   │
                    └─────────┬─────────┘
                              │ completeRedeem
                              ▼
                         assets out
```

After the seven-day cooldown, an active incident sends the request into the waiting branch. When the incident ends, the staker receives a fresh two-day exit window. If an incident opens during an existing exit window, redemption is likewise blocked until it ends. Missing an available exit window means filing a new request and waiting seven days again. `cancelRedeemRequest()` remains available throughout.

### Claiming and pool-freeze routes

```
 First signed joinClaim
 or admin fallback open
             │
             ▼
   ┌─────────────────────┐
   │   CLAIM WINDOW 5d   │  Anyone can join
   │    pools frozen     │  or cancel claims
   └─────────────────────┘
        │             │
   no live claims   live claims
        │             ▼
        │   ┌─────────────────────┐
        │   │  SUBMISSION ≤ 3d    │
        │   └─────────────────────┘
        │        │           │
        │      no root      root submitted
        │        │           ▼
        │        │   ┌─────────────────────┐
        │        │   │    DISPUTE 2d       │
        │        │   └─────────────────────┘
        │        │      │              │
        │        │   no dispute     disputed
        │        │      │              ▼
        │        │      │    ┌───────────────────┐
        │        │      │    │ CORRECTION ≤ 3d   │
        │        │      │    └───────────────────┘
        │        │      │       │              │
        │        │      │   corrected      no correction
        │        │      │       │              │
        │        │      │       └──▶ fresh     │
        │        │      │          dispute     │
        │        │      ▼                      │
        │        │   ┌─────────────────────┐   │
        │        │   │    FINALIZE 4d      │   │
        │        │   │ claim Merkle payout │   │
        │        │   └─────────────────────┘   │
        │        │      │              │       │
        │        │  all finalized   window ends│
        ▼        ▼      ▼              ▼       ▼
   ┌─────────────────────────────────────────────┐
   │                  UNFREEZE                   │
   │             next incident may open          │
   └─────────────────────────────────────────────┘
```

- No live claims at claim-window end: unfreeze; no settlement needed.
- No root by submission deadline: void and unfreeze.
- Disputed root: pools remain frozen during correction. Corrected root gets a fresh dispute period; no correction means void.
- Finalization: last claim can unfreeze early. If some or nobody finalizes, the four-day deadline unfreezes and unclaimed allocation stays in pools.
- `closeIncident()` can terminate before finalization. Unresolved claimants recover escrow with `withdrawNonFinalizedClaim()` after close, void, correction timeout, or finalization expiry.

Timing constants: claim `5d`, submission `3d`, dispute `2d`, correction `3d`, finalization `4d`. Only one incident can be active.

### Minimum claim escrow

Every insured-token listing has its own non-zero `minClaimAmount`, denominated in that token's base units. `joinClaim` checks the balance delta actually received by `DefiInsurance`, not only the requested transfer amount. The timelock can retune the threshold with `setMinClaimAmount` only while no incident is active.

This setting belongs to the insured token rather than an individual cover pool: a claim targets one insured-token incident and draws from the incident's snapshotted pool set. The threshold makes claimant-table spam capital-intensive, but does not impose a mathematical claim-count ceiling. Governance should choose a meaningful amount from token value/decimals and maximum-load settlement tests, not use a nominal one-unit default.

## Claim allocation: capped geometric weighting

### Decision

Settlement uses both a claimant's covered economic need and the insurance score they choose to spend. Treating raw score as the sole proportional weight lets a high-score claim with a negligible payout cap dilute meaningful claims before its own payout is clipped. Treating claim size as the sole weight would ignore long-term participation. Capped geometric weighting gives both inputs equal multiplicative influence while preserving hard claim and pool limits.

For each live claim `i`:

```text
C_i = floor(lossUsd_i * coverageBps / 10_000)       # maximum covered payout
S_i = min(requestedScore_i, boostedUnspentScore_i)  # score chosen and available to spend
W_i = floor(sqrt(C_i * S_i))                        # allocation weight
B   = floor(poolUsd * maxCoverPoolPayoutBps / 10_000)
```

The target allocation is:

```text
P_i = min(C_i, lambda * W_i)
sum(P_i) <= B
```

`lambda` is the common clearing rate selected by deterministic capped water-filling. Integer divisions round down; resulting dust remains in the cover pools. The breaking payout-rule change introduced off-chain `CONFIG_VERSION = "4.0.0"`; per-insured-token minimum claims advanced it to `4.1.0`, and strict pinned-block oracle round validation advances it to `4.2.0`. The version is part of `configHash`, so builds with different settlement acceptance rules cannot share the same configuration commitment.

`C_i` is not the raw submitted token amount. It is derived from `eligibleAmount`—the escrow capped by the claimant's qualifying pre-incident holding—valued in USD and multiplied by the configured coverage percentage.

### Why geometric weighting

- **Need and participation both matter:** equal scores with different covered losses produce different weights; equal covered losses with different scores also produce different weights.
- **Diminishing score dominance:** multiplying score by four multiplies weight by two, rather than four. This matters because score is a cumulative token-block quantity and can be numerically much larger than a token balance.
- **Unit-scale independence:** globally changing the denomination of all caps or all scores multiplies every weight by the same constant, leaving payout ratios unchanged apart from integer flooring.
- **Zero-value resistance:** `C_i = 0` or `S_i = 0` gives `W_i = 0`; unusable score cannot dilute valid claims.
- **Proportional split neutrality:** splitting both `C` and `S` proportionally across `k` identities preserves aggregate pre-rounding weight because `k * sqrt((C/k) * (S/k)) = sqrt(C * S)`.
- **Hard solvency bounds:** no payout exceeds its covered-loss cap, and aggregate payout never exceeds the incident's LP-loss budget.

### Deterministic water-filling

The implementation never chooses an arbitrary claimant to recompute first:

1. Remove zero-cap and zero-weight claims from allocation.
2. Sort remaining claims by ascending `C_i / W_i`, comparing exact bigint cross-products (`C_a * W_b` versus `C_b * W_a`) rather than floating-point division. Break exact ties by `claimId`.
3. Track `remainingBudget` and `remainingWeight`.
4. The lowest-ratio remaining claim is saturated when `remainingBudget * W_i >= C_i * remainingWeight`. Assign its cap, subtract its cap and weight, and continue.
5. Once the lowest-ratio claim does not saturate, no later claim can saturate. Allocate the remaining budget pro-rata by weight and stop.
6. Leave division dust in the pools; never award dust based on input or transaction order.

Example with an `$80` incident budget:

| Claim | Covered cap `C` | Score spent `S` | Weight `sqrt(C*S)` | Final payout |
|---|---:|---:|---:|---:|
| A | $10 | 90 | 30 | $10 |
| B | $36 | 100 | 60 | $30 |
| C | $64 | 100 | 80 | $40 |

A's initial weighted share exceeds `$10`, so A is capped first. Its unused share is redistributed across B and C in their `60:80` weight ratio. This arithmetic runs once inside the existing off-chain settlement computation and produces one root.

Claim finalization remains optional. The claimant still files, sees the final offer, and may finalize or decline based on payout, score, booster, and gas economics. There is no additional claimant confirmation. Because the root is fixed, an offer declined after settlement is not redistributed; eliminating that residual no-show capacity would require another allocation phase and is deliberately outside this design.

## Getting started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)

### Setup

```bash
git clone <repo-url>
cd usd8core
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test
```

Verbose output:

```bash
forge test -vv
```

### Format

```bash
forge fmt
```

### Coverage

```bash
forge coverage
```

## Security

Each contract has a `@custom:security-contact rick@usd8.fi` natspec tag. Reports go to [rick@usd8.fi](mailto:rick@usd8.fi).

## License

Business Source License 1.1 (BUSL-1.1). See [LICENSE](LICENSE). The code is
source-available: you may audit, modify, test, and make non-production use of it
freely, but production/commercial use requires a commercial license from the
Licensor until the **Change Date (2030-07-01)**, on which each version converts
to the **MIT** license.
