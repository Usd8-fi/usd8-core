# USD8 Core

USD8 is a stable coin offering free defi insurance to users. This repo contains the contracts for USD8 protocol. The system is under active development, currently no bounties are offered, do not submit vulnerability reports.


## Contents

- [Protocol overview](#protocol-overview)
- [USD8 and Treasury](#usd8-and-treasury)
- [Insurance score](#insurance-score)
- [Cover pools](#cover-pools)
- [Defi insurance](#defi-insurance)
- [Governance and trust assumptions](#governance-and-trust-assumptions)
- [Repository layout](#repository-layout)
- [Getting started](#getting-started)
- [Security](#security)
- [License](#license)

<br/><br/><br/><br/>

# Protocol overview

```
          ┌───────────┐
          │   Users   │
          └───────────┘
                ▲                      ┌────────────────┐
  1.Mint/Redeem │                      │  USD8 Savings  │
    USD8<->USDC │                 ┌───►│  Morpho Vault  │
                │                 │    └────────────────┘
                ▼                 │
  ┌───────────────────────────┐   │
  │                           │   │
  │       USD8 Treasury       │   │    ┌───────────────┐
  │          IN USDC          │   ├───►│  USD8 Cover   │                  4.File claim
  │                           │   │    │    Pool 1     ├───┐                get payout
  └────────────┬──────────────┘   │    └───────────────┘   │  ┌───────────┐
               │                  │                        │  │   Defi    │        ┌───────────┐
               │                  │                        ├──┤ Insurance │◄──────►│   Users   │
2. Deploy USDC │                  │    ┌───────────────┐   │  │           │        └───────────┘
               │                  ├───►│   USD8 Cover  │   │  └───────────┘
               ▼                  │    │     Pool 2    ├───┘
     ┌────────────────────┐       │    └───────────────┘
     │   Yield Strategy   ├───────┘
     └────────────────────┘   3. Profit Distribution
```

| Component | Role |
|---|---|
| [`Registry`](src/Registry.sol) | UUPS access-control, pause, topology, pool, payout-module, scored-token, booster, and incident-freeze hub. |
| [`USD8`](src/USD8.sol) | UUPS ERC-20 stablecoin. Only its timelock-configured Treasury may mint or burn it. |
| [`Treasury`](src/Treasury.sol) | Mints USD8 against USDC, manages the USDC reserve and approved strategies, harvests surplus, and routes USD8 revenue. |
| Morpho Vault V2 savings | Official Morpho Vault V2 share token with symbol `sUSD8`, backed by [`USD8SavingsAdapter`](src/adapters/USD8SavingsAdapter.sol). There is no custom sUSD8 vault contract. |
| [`SingleAssetCoverPool`](src/SingleAssetCoverPool.sol) | One ERC-4626 staking pool per cover asset. Stakers earn USD8 rewards and accept claim-loss risk. |
| [`DefiInsurance`](src/DefiInsurance.sol) | Insured-token configuration, claimant escrow, incident lifecycle, TEE-signed settlement, disputes, and claim payouts. |
| [`ERC4626Strategy`](src/strategies/ERC4626Strategy.sol) | Adapter for deploying Treasury USDC into an approved ERC-4626 USDC vault. One adapter is used per vault. |
<br/><br/><br/><br/>


# USD8 and Treasury

```

        ┌───────────┐
        │   Users   │
        └───────────┘
              │                           ┌────────────────┐
              │ 1.Mint/Redeem             │  USD8 Savings  │
              │   USD8<->USDC       ┌────►│  Morpho Vault  │
              │                     │     └────────────────┘
              ▼                     │
┌───────────────────────────┐       │
│                           │       │
│       USD8 Treasury       │       │     ┌───────────────┐
│           (USDC)          │       ├────►│  USD8 Cover   │
│                           │       │     │    Pool 1     │
└────────────┬──────────────┘       │     └───────────────┘
             │                      │
             │                      │
             │  2. Deploy USDC      │     ┌───────────────┐
             │                      ├────►│   USD8 Cover  │
             ▼                      │     │     Pool 2    │
   ┌────────────────────┐           │     └───────────────┘
   │   Yield Strategies ├───────────┘
   └────────────────────┘   3. Profit Distribution


```

## Mint and Redeem USD8
- anyone can mint and redeem USD8 with USDC 1 to 1
- in extreme cases, if the treasury do not have enough backings(which should not happen), everyone takes a hair cut. No bank run by design
- USD8 is insured by the Cover Pools, so any loss can be covered



## Reserve yield
- yield strategies must be approved by Timelock so admin can't steal
- yield is in USD8 and distributed to Morpho Savings sUSD8 and all High yield Cover Pools, admin decides the distribution proportion



## Morpho savings sUSD8
- A simple savings vault, user deposit USD8, get sUSD8 which comes with a APY
- using Morpho vault V2 instead of building our own
- sUSD8 is insured by the Cover Pools, so any loss can be covered.


## Insurance score
- scores are cumulative block weighted token balance
- currently two tokens accrue score: about 1 per day for USD8 and 0.1 per day for sUSD8
- the more user hold these tokens, the more score will accrue.
- scores are not transferrable and does not expire
<br/><br/><br/><br/>

# Cover pools
4626 vaults with high APY yield but high risk to cover losses

## Deposit and withdraw
- anyone can deposit while no claim incident is active
- exit is share-denominated: `requestRedeem` escrows the requested shares immediately, stops their USD8 rewards, and cannot be cancelled
- requests mature in three-day batches after a seven-day minimum cooldown, so the wait is 7–10 days; once settled, the shares are burned and their asset value is reserved for `completeRedeem` with no expiry
- anyone can call `settleMaturedExitEpochs(maxEpochs)` repeatedly to process ended epochs in caller-sized batches
- if an incident opens before the request matures, the exit is held until the incident resolves and receives the same loss as the other pool capital
- if the request matures before an incident opens, its assets are reserved before the incident snapshot and remain claimable during that incident


```text
    deposit
       │
       ▼
 ┌──────────────┐
 │  Cover Pool  │──── claim yield ───▶ USD8
 └──────┬───────┘
        │ withdraw
        ▼
 ┌───────────────────┐
 │ escrowed exit     │  still absorbing losses
 │ 7–10d exit wait   │
 └─────────┬─────────┘
           ▼
 incident opened before exit epoch?
      │                     │
     no                    yes
      │                     │
      │            wait till incident ends
      │                     │
      └──────────┬──────────┘
                 │
                 ▼
        complete withdraw
```

## High APY
- Cover Pool receive a high payout from the treasury yield
- yield is in USD8, not compounded, thus not covering any loss. Claim anytime.

## Payouts and limits
- Cover pools will payout to Defi insurance as requested
- each incident can only drain up to `maxCoverPoolPayoutBps`(currently 50%)

<br/><br/><br/><br/>

# Defi insurance

## Insured tokens
- added by time lock, no last minute change attacks
- each insured token has a `maxCoverageBps` as max payout cap for this token, decided by admin. e.g. 80% meaning payout capped at 80% USD value before incidence
- insured token payout is based on its underlying token. e.g. insured aUSDC depegs, payout will be in underlying USDC, paid in cover pool asset(e.g. wstETh).
- if the underlying depegs instead of the insured token, user will get value based on depegged underlying, not worth it.

## Claim lifecycle
```text
         File Claim (requires TEE sig)
             │
             ▼
   ┌─────────────────────┐
   │   CLAIM WINDOW 5d   │  anyone can file or
   │    pools frozen     │    cancel claim
   └─────────────────────┘
        │             │
    no claims    with claims
        │             ▼
        │   ┌─────────────────────┐
        │   │  SUBMISSION ≤ 3d    │  Anyone can submit TEE-signed Merkle root
        │   └─────────────────────┘
        │        │           │
        │      no root      root submitted
        │        │           ▼
        │        │   ┌─────────────────────┐
        │        │   │    DISPUTE 2d       │
        │        │   └─────────────────────┘
        │        │      │              │
        │        │   accepted       disputed (admin only during beta)
        │        │      │              ▼
        │        │      │    ┌───────────────────┐
        │        │      │    │ CORRECTION ≤ 3d   │
        │        │      │    └───────────────────┘
        │        │      │       │             │
        │        │      │   corrected     no correction
        │        │      │       │             │
        │        │      │       └─▶ fresh     │
        │        │      │          dispute    │
        │        │      ▼                     │
        │        │   ┌─────────────────────┐  │
        │        │   │    FINALIZE 4d      │  │
        │        │   │ prove and withdraw  │  │
        │        │   └─────────────────────┘  │
        │        │      │              │      │
        │        │  all finalized   deadline  │
        ▼        ▼      ▼              ▼      ▼
   ┌─────────────────────────────────────────────┐
   │              UNFREEZE Cover Pools           │
   │             next incident may open          │
   └─────────────────────────────────────────────┘
```
- any one with insured token can file a claim by escrow their insured token, first claimer needs to get TEE signed attestation price has dropped 20% around given block. This freezes Cover Pool deposits and settlement of exits that were not already reserved; new exit requests remain loss-exposed.
- claim for this token will be open for 5 days allows others to file claim, after no further claims allowed this insured token
- anyone can submit TEE signed payout root. TEE computes claimers insurance score and their eligible payouts using [payout allocation](#payout-allocation). This algorithm is open sourced, anyone can run locally and check their results. This will also delist the insured token.
- after root is submitted, admin can check and correct the root if incorrect (privilege during beta)
- after that users have 4 days to finalize their claim payout. Miss this means no payout. Unfinalized claim insured tokens can be withdrawn.
- Cover Pool unfreezes for withdraws
- Only one incident can be active at a time


## Boosters
- NFTs that gives a 1% boost to users insurance score
- can be used when filing a claim


## Eligibility and valuation

Settlement reconstructs each live claim from `ClaimRegistered` and `ClaimCancelled` events. A claimant's eligible amount is:

```text
eligibleAmount = min(
  escrowReceived,
  minimum insured-token balance over the pre-incident holding window
)
```

The token-to-underlying TWAP ends at the pre-incident `referenceBlock`. The underlying/USD oracle is pinned to the claim-window-end block. Excess escrow above `eligibleAmount` is refunded during finalization.


## Payout allocation

Payouts use capped water-filling with geometric weights based on covered claim cap in USD and booster-adjusted payout score. Raw score accounting remains separate.

For each claim:

```text
C_i = floor(preIncidentEligibleValueUsd * coverageBps / 10_000)
R_i = min(requestedRawScore, rawUnspentScore)
S_i = floor(R_i * (10_000 + boosterAmountUsed_i * boosterBoostBps) / 10_000)
W_i = floor(sqrt(C_i * S_i))
B   = floor(totalCoverPoolUsd * maxCoverPoolPayoutBps / 10_000)
P_i = min(C_i, lambda * W_i)
sum(P_i) <= B
```

Only `R_i` is recorded as spent in the Registry. `S_i` is committed in the Merkle leaf and used only for payout allocation. `C_i` is the claim's absolute coverage cap. The square root gives covered need and boosted score equal multiplicative influence with diminishing returns. Zero covered need or zero boosted score produces zero weight.

A deterministic capped water-filling calculation selects `lambda`. Claims that reach their cap are removed first; the remaining budget is redistributed by weight. Integer dust remains in the pools. Each payout is then split across the snapshotted cover pools in proportion to their USD value while respecting each pool's incident cap.

The settlement code builds one Merkle root over the exact claim set and payout rows. Any authorized TEE signer may sign it, anyone may submit it, and anyone may independently reproduce it. The Rust production runtime and operations are documented in [`offchain-rust/README.md`](offchain-rust/README.md); [`offchain/README.md`](offchain/README.md) documents the temporary TypeScript differential oracle.

<br/><br/><br/><br/>

# Governance and trust assumptions

- Registry admin and timelock roles are privileged by design during beta. They control upgrades, topology, strategy admission and allocation, profit routing, pauses, insured-token parameters, and incident/root operations.
- Beta mode can be ended permanently; after that, settlement correction is timelock-only.
- Any authorized TEE signer can open or sign a settlement. Compromise of one signer is bounded by the dispute window, pool payout caps, and governance close/correction powers.
- All TEE algorithms are open sourced, user can verify their insurance score, payout amount independently.


## Repository layout

```text
src/
  Registry.sol                  shared access, pause, topology, and score state
  USD8.sol                      stablecoin
  Treasury.sol                  reserve, strategies, mint/redeem, and revenue
  SingleAssetCoverPool.sol      one-asset staking and claim-loss pool
  DefiInsurance.sol             insured tokens, incidents, escrow, and payouts
  adapters/USD8SavingsAdapter.sol
  strategies/ERC4626Strategy.sol

offchain-rust/
  src/                          production settlement runtime and FFI
  README.md                     operations, trust model, and recovery

offchain/                       TypeScript CI/shadow oracle; not production
  src/compute.ts                independent settlement oracle
  src/chain.ts                  independent pinned-read oracle

script/
  01_DeployTimelock.s.sol       step 1: governance timelock
  02_DeployUSD8System.s.sol     step 2: mainnet system and initial wiring
test/                           Foundry tests
offchain/test/                  Vitest settlement tests
```

## Getting started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)
- Rust 1.91.1 for the production settlement runtime
- Node.js 22.22.3 and npm only for differential-oracle tests

### Install and build

```bash
git clone https://github.com/Usd8-fi/usd8-core.git
cd usd8-core
forge install
forge build

cd offchain-rust
cargo build --release --locked

# Optional: build the TypeScript differential oracle.
cd ../offchain
npm ci --include=dev
npm run build
```

### Mainnet deployment order

```bash
# Keep the Etherscan key in the ignored local .env or shell environment.
source .env

# 1. Deploy and verify the standalone governance timelock.
forge script script/01_DeployTimelock.s.sol:DeployTimelockScript \
  --rpc-url "$ETH_RPC_URL" --broadcast --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"

# Copy the verified address printed by step 1.
export TIMELOCK_ADDRESS=0x...

# 2. Deploy, wire, and verify the USD8 system.
forge script script/02_DeployUSD8System.s.sol:DeployUSD8SystemScript \
  --rpc-url "$ETH_RPC_URL" --broadcast --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

If broadcast succeeds but verification is interrupted, rerun the corresponding command with `--resume --verify`; do not broadcast a new deployment. Step 2 validates that the timelock address contains contract code and checks its 24-hour delay, proposer/canceller, open executor, and self-admin role before broadcasting. The deploying account must also hold the configured USDC seed amount.

### Test

```bash
# Solidity
forge test

# Rust production runtime
cd offchain-rust
cargo test --locked
cargo build --release --locked

# TypeScript differential oracle
cd ../offchain
npm test

# Both contract-integration lanes
npm run build
cd ..
RUN_INTEGRATION=1 USE_RUST_FFI=1 forge test --offline --ffi --match-path test/SettlementIntegration.t.sol -vv
RUN_INTEGRATION=1 USE_RUST_FFI=0 forge test --offline --ffi --match-path test/SettlementIntegration.t.sol -vv
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

Each contract has a `@custom:security-contact rick@usd8.fi` NatSpec tag. Security reports will go to [rick@usd8.fi](mailto:rick@usd8.fi) once public reporting opens.

## License

Business Source License 1.1 (BUSL-1.1). See [LICENSE](LICENSE). The code is source-available: you may audit, modify, test, and make non-production use of it freely, but production or commercial use requires a commercial license from the Licensor until the **Change Date (2030-07-01)**. Each version converts to the **MIT License** on its Change Date.
