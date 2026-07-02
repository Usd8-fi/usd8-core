# USD8 Core

Stablecoin protocol contracts for [usd8.fi](https://usd8.fi).

Please note this repo is under development, codebase is expected to change often, there are no bug bounties, do not report bugs for now.

## Release scope

Ships the core stablecoin stack:

- [`USD8`](src/USD8.sol) — UUPS-upgradeable ERC20 stablecoin. Mint/burn restricted to a configured Treasury.
- [`Treasury`](src/Treasury.sol) — Wraps mainnet USDC into USD8 at a fixed 1:1 peg. Holds the reserve, manages approved yield strategies, and routes harvested protocol revenue.
- [`SavingsUSD8`](src/SavingsUSD8.sol) — ERC4626 savings vault for USD8 with linear profit vesting (JIT-resistant) and strategy-based yield deployment.
- [`CoverPool`](src/CoverPool.sol) — multi-asset, high-yield pool whose deposits may be drawn upon to cover losses from covered DeFi protocols. Depositors earn premium yield in exchange for accepting loss-coverage risk.
- Strategies in [`src/strategies/`](src/strategies/):
  - [`AaveV3UsdcStrategy`](src/strategies/AaveV3UsdcStrategy.sol) — primary USDC strategy targeting Aave v3.
  - [`MorphoVaultStrategy`](src/strategies/MorphoVaultStrategy.sol) — generic ERC4626 adapter for MetaMorpho/Morpho Blue vaults; deploy one instance per vault.

## Architecture overview

```
                  ┌──────────┐
                  │   USD8   │
                  └──────────┘
                       ▲
                       │ mint and burn
                       │
┌──────────────────────────────────────────┐
│                                          │
│                 Treasury                 │
│                                          │
└──────────────────────────────────────────┘
        │                          │
        │ deploy/withdraw          │ profit distribution
        │                          ├─────────────────────┐
        ▼                          ▼                     ▼
┌─────────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐
│                     │   │                     │   │                     │
│ External strategies │   │     Savings USD8    │   │      CoverPool      │
│                     │   │                     │   │                     │
└─────────────────────┘   └─────────────────────┘   └─────────────────────┘
```

Profit distribution is admin-routed to an allowlist of approved recipients via [`Treasury.distributeRevenue`](src/Treasury.sol); SavingsUSD8 and CoverPool are the approved recipients. Treasury and SavingsUSD8 share an `IStrategy` interface but maintain independent strategy queues. Strategy at `strategies[0]` is the first source consulted on redeems.

## CoverPool flows

Stakers deposit any approved asset and earn USD8 yield in exchange for accepting loss-coverage risk. Claimants escrow a covered protocol's token; after a TEE-signed settlement they redeem a payout drawn pro-rata from the pool. One incident is processed at a time; the TEE gates incident opening and signs the settlement root, and payouts are bounded on-chain by the live pool balance.

### Staking

```
        stake(asset)   — reverts while an incident is active
                   │
                   ▼
        ┌─────────────────────┐
        │        STAKED       │──▶ withdrawYield(asset) ──▶ USD8
        │     earning USD8    │
        └─────────────────────┘
                   │
                   │  requestUnstake: start 7d cooldown, shares stop earning
                   │  (cancelUnstakeRequest reverses it, resumes earning)
                   ▼
        ┌─────────────────────┐
        │       COOLING       │  shares still absorb claim payouts
        │     not earning     │
        └─────────────────────┘
                   │
                   │  completeUnstake: after 7d AND no active incident
                   ▼
        assets out (live price/share) + auto-yield
```

### Claiming (incident lifecycle, days from open)

```
  openIncident(token, amt, TEE-sig) at t=0 — escrow first claim, freeze pool, then:

  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
  │ CLAIM WINDOW │──▶│    SETTLE    │──▶│   DISPUTE    │──▶│   FINALIZE   │
  │     0-5d     │   │     5-7d     │   │     5-8d     │   │    8-13d     │
  │ registerClaim│   │ settle root  │   │ voidSettle   │   │ finalizeClaim│
  │   joins      │   │  (TEE sig)   │   │  (admin)     │   │ payout ≤pool │
  └──────────────┘   └──────────────┘   └──────────────┘   └──────────────┘
```

Exits:
- `cancelRegisteredClaim()` during the claim window → escrow refunded.
- No root by 7d, or `voidSettlement` by 8d → incident **VOID** (no payout).
- VOID, or finalize window missed → `withdrawNonFinalizedClaim()` recovers escrow, anytime.

Timing constants: `CLAIM_WINDOW 5d`, then settle `(5d, 7d]` (`ROOT_SUBMIT_CUTOFF 2d`), `voidSettlement` until `8d` (`DISPUTE_PERIOD 3d`), finalize `(8d, 13d]` (`FINALIZE_WINDOW 5d`).

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
