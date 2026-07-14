# USD8 Core

Stablecoin protocol contracts for [usd8.fi](https://usd8.fi).

Please note this repo is under development, codebase is expected to change often, there are no bug bounties, do not report bugs for now.

## Release scope

Ships the core stablecoin stack:

- [`Registry`](src/Registry.sol) — non-upgradeable access + pause + topology hub. Holds the timelock/admin roles, per-contract pause flags, the pool set, the single payout module, the incident-freeze flag, the insurance-score token set, and the booster collection. Every core contract inherits [`Managed`](src/Managed.sol) and defers to it.
- [`USD8`](src/USD8.sol) — UUPS-upgradeable ERC20 stablecoin. Mint/burn restricted to a configured Treasury.
- [`Treasury`](src/Treasury.sol) — Wraps mainnet USDC into USD8 at a fixed 1:1 peg. Holds the reserve, manages approved yield strategies, and (via `harvestAndDistribute`) harvests surplus and routes it to weighted profit receivers.
- [`SavingsUSD8`](src/SavingsUSD8.sol) — UUPS-upgradeable ERC4626 savings vault for USD8. Pure linear profit vesting (JIT-resistant); it holds deposits idle and receives yield from Treasury distributions (no strategy stack).
- [`SingleAssetCoverPool`](src/SingleAssetCoverPool.sol) — single-asset staking pool (one per stake asset, behind a shared beacon) whose deposits may be drawn upon to cover losses from covered DeFi protocols. Stakers earn USD8 yield in exchange for loss-coverage risk. Multi-asset coverage is replication: deploy another pool per asset.
- [`DefiInsurance`](src/DefiInsurance.sol) — the single payout module: insured-token registry, incident lifecycle, claimant escrow, and TEE-signed settlement; pays claims out of the registered pools.
- [`ERC4626Strategy`](src/strategies/ERC4626Strategy.sol) — `IStrategy` adapter that deploys Treasury USDC into any ERC-4626 USDC vault (Aave v3 static aUSDC, MetaMorpho, …); one instance per vault.

## Architecture overview

```
                  ┌──────────┐
                  │   User   │
                  └──────────┘
                       ▲
                       │ Mint/Redeem USDC<>USD8
                       │
┌──────────────────────────────────────────┐
│                                          │
│                 USD8 Treasury            │
│                                          │
└──────────────────────────────────────────┘
        │                          │
        │ deploy                   │ profit distribution
        │                          ├─────────────────────┐
        ▼                          ▼                     ▼
┌─────────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐
│                     │   │                     │   │                     │
│ External strategies │   │     Savings USD8    │   │ SingleAssetCoverPool│
│                     │   │                     │   │      (per asset)    │
└─────────────────────┘   └─────────────────────┘   └─────────────────────┘
```

Profit distribution is weight-routed to registered receivers via [`Treasury.harvestAndDistribute`](src/Treasury.sol) (or the ad-hoc `distributeRevenue`); SavingsUSD8 and each cover pool are receivers. Only the Treasury has a strategy queue now (SavingsUSD8 holds deposits idle); the strategy at `strategies[0]` is the first source consulted on redeems.

## Cover pool flows

Stakers deposit the pool's asset and earn USD8 yield in exchange for accepting loss-coverage risk. Claimants escrow a covered protocol's token; after a TEE-signed settlement each redeems a payout via a per-claim TEE ticket, drawn from the registered pools. One incident is processed at a time; the TEE gates incident opening and signs the settlement root (the dispute anchor), and payouts are bounded on-chain by each pool's live balance.

### Staking

```
        stake(amount)  — reverts while an incident is active
                   │
                   ▼
        ┌─────────────────────┐
        │        STAKED       │──▶ withdrawYield() ──▶ USD8
        │     earning USD8    │
        └─────────────────────┘
                   │
                   │  requestUnstake: start 7d cooldown
                   │  (cancelUnstakeRequest just clears the request)
                   ▼
        ┌─────────────────────┐
        │       COOLING       │  shares still earn AND still absorb payouts
        │    still earning    │
        └─────────────────────┘
                   │
                   │  completeUnstake: within [7d, 7d+2d] AND no active incident
                   │  (miss the 2d window → request expires, re-request)
                   ▼
        assets out (live price/share) + auto-yield
```

### Claiming (incident lifecycle, days from open)

```
  openIncidentSigned(token, refBlock, TEE-sig) at t=0 — freeze system (no claim yet), then:

  ┌──────────────┐   ┌──────────────--┐   ┌──────────────┐   ┌──────────────┐
  │ CLAIM WINDOW │──▶│    SUBMIT      │──▶│   DISPUTE    │──▶│   FINALIZE   │
  │     0-4d     │   │    4d-≤7d      │   │  from root+4d│   │  next 4d     │
  │ joinClaim /  │   │ settleIncident │   │ closeIncident│   │ finalizeClaim│
  │ cancelClaim  │   │ root (TEE sig) │   │  veto (admin)│   │ (TEE ticket) │
  └──────────────┘   └──────────────--┘   └──────────────┘   └──────────────┘
```

Exits:
- `cancelClaim()` during the claim window → escrow refunded.
- No root by claim-window-end + `SUBMIT_DEADLINE` → incident **VOID** (no payout).
- VOID, admin `closeIncident`, or finalize window missed → `withdrawNonFinalizedClaim()` recovers escrow, anytime after.

Timing constants: `CLAIM_WINDOW 4d`, then `settleIncident` within `SUBMIT_DEADLINE 3d` of window-end (root overwritable in that window), `DISPUTE_PERIOD 4d` from root submission (`closeIncident` veto), then `FINALIZE_WINDOW 4d`. Per-claim payout is authorized by a TEE-signed ticket bound to the root; the pool unlocks the instant the last claim finalizes.

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
