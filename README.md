# USD8 Core

Stablecoin protocol contracts for [usd8.fi](https://usd8.fi).

Please note this repo is under development, codebase is expected to change often, there are no bug bounties, do not report bugs for now.

## Release scope

### Beta release (current)

The beta release ships the core stablecoin stack:

- [`USD8`](src/USD8.sol) — UUPS-upgradeable ERC20 stablecoin. Mint/burn restricted to a configured Treasury.
- [`Treasury`](src/Treasury.sol) — Wraps mainnet USDC into USD8 at a fixed 1:1 peg. Holds the reserve, manages approved yield strategies, and routes harvested protocol revenue.
- [`SavingsUSD8`](src/SavingsUSD8.sol) — ERC4626 savings vault for USD8 with linear profit vesting (JIT-resistant) and strategy-based yield deployment.
- Strategies in [`src/strategies/`](src/strategies/):
  - [`AaveV3UsdcStrategy`](src/strategies/AaveV3UsdcStrategy.sol) — primary USDC strategy targeting Aave v3.
  - [`MorphoVaultStrategy`](src/strategies/MorphoVaultStrategy.sol) — generic ERC4626 adapter for MetaMorpho/Morpho Blue vaults; deploy one instance per vault.

### Later release

- [`CoverPool`](src/CoverPool.sol) — multi-asset, high-yield pool whose deposits may be drawn upon to cover losses from covered DeFi protocols. Depositors earn premium yield in exchange for accepting loss-coverage risk. **Out of scope for the beta.** It compiles alongside the rest of the codebase but is not part of the audit, deploy, or test scope for this release. Tests excluded via `--no-match-path` (see below). Targeted for a later release.

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

Profit distribution is admin-routed to an allowlist of approved recipients via [`Treasury.distributeRevenue`](src/Treasury.sol). SavingsUSD8 is the primary recipient at beta; CoverPool joins in a later release. Treasury and SavingsUSD8 share an `IStrategy` interface but maintain independent strategy queues. Strategy at `strategies[0]` is the first source consulted on redeems.

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

Beta release tests (excludes CoverPool):

```bash
forge test --no-match-path "test/CoverPool.t.sol"
```

Full test suite (once CoverPool returns to scope):

```bash
forge test
```

Verbose output:

```bash
forge test --no-match-path "test/CoverPool.t.sol" -vv
```

### Format

```bash
forge fmt
```

### Coverage

```bash
forge coverage --no-match-path "test/CoverPool.t.sol"
```

## Security

Each contract has a `@custom:security-contact rick@usd8.fi` natspec tag. Reports go to [rick@usd8.fi](mailto:rick@usd8.fi).

## License

MIT
