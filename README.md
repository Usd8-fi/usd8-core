# USD8 Core

USD8 is a stable coin offering free defi insurance to users. This repo contains the contracts for USD8 protocol.


## Contents

- [Protocol overview](#protocol-overview)
- [USD8 and Treasury](#usd8-and-treasury)
  - [Mint and Redeem USD8](#mint-and-redeem-usd8)
  - [Reserve yield](#reserve-yield)
  - [Morpho savings sUSD8](#morpho-savings-susd8)
  - [Insurance score](#insurance-score)
- [Cover pools](#cover-pools)
  - [Deposit and withdraw](#deposit-and-withdraw)
  - [High APY](#high-apy)
  - [Payouts and limits](#payouts-and-limits)
- [Defi insurance](#defi-insurance)
  - [Insured tokens](#insured-tokens)
  - [Claim lifecycle](#claim-lifecycle)
  - [Boosters](#boosters)
  - [Eligibility](#finalize-claim-eligibility)
  - [Insured token valuation](#insured-token-valuation)
  - [Payout allocation](#payout-allocation)
    - [Why score-proportional entitlement](#why-score-proportional-entitlement)
- [Governance and trust assumptions](#governance-and-trust-assumptions)
  - [Beta mode and permanent disablement of upgradeability](#beta-mode-and-permanent-disablement-of-upgradeability)
  - [Repository layout](#repository-layout)
  - [Codebase structure](#codebase-structure)
- [Getting started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Install and build](#install-and-build)
  - [Deployment order](#deployment-order)
  - [Test](#test)
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
| [`Registry`](src/Registry.sol) | Beta-only UUPS access-control, pause, topology, pool/feed, oracle-staleness, payout-module, scored-token, booster, and incident-freeze hub. |
| [`USD8`](src/USD8.sol) | Beta-only UUPS ERC-20 stablecoin. Only its timelock-configured Treasury may mint or burn it. |
| [`Treasury`](src/Treasury.sol) | Beta-only UUPS reserve module that mints USD8 against USDC, manages approved strategies, harvests surplus, and routes USD8 revenue. |
| Morpho Vault V2 savings | Official Morpho Vault V2 share token with symbol `sUSD8`, backed by [`USD8SavingsAdapter`](src/adapters/USD8SavingsAdapter.sol). There is no custom sUSD8 vault contract. |
| [`SingleAssetCoverPool`](src/SingleAssetCoverPool.sol) | One ERC-4626 staking pool per cover asset. Stakers earn USD8 rewards and accept claim-loss risk. |
| [`DefiInsurance`](src/DefiInsurance.sol) | Beta-only UUPS insured-token configuration, claimant escrow, incident lifecycle, TEE-signed settlement, admin correction, and claim payouts. |
| [`StrategyBase`](src/strategies/StrategyBase.sol) | Shared strategy swap boundary. Each strategy declares its deployment token. Approved routes may swap USDC into that token, or any non-position token back to USDC; USDC output goes directly to Treasury. |
| [`ERC4626Strategy`](src/strategies/ERC4626Strategy.sol) | `StrategyBase` adapter for deploying Treasury USDC into an approved ERC-4626 USDC vault. Its deployment token is USDC, so only non-position-token → USDC swaps are available. |
<br/><br/><br/><br/>


# USD8 and Treasury



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
 │  Cover Pool  │────► claim yield in USD8
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
- Cover Pool size is capped according to USD8 supply, thus the APY can be high
- yield is in USD8, not compounded and not exposing to any loss. Claim anytime.

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
   ┌─────────────────────┐
   │       CLAIM         │  anyone can claim, first one
   │         3d          │  requires TEE sig
   └─────────────────────┘
             │
             ▼
   ┌─────────────────────┐
   │       SETTLE        │  anyone can settle
   │         3d          │  with TEE sig
   └─────────────────────┘
             │
             ▼
   ┌─────────────────────┐
   │  CORRECT SETTLEMENT │  admin or timelock
   │         3d          │  during beta
   └─────────────────────┘
             │
             ▼
   ┌─────────────────────┐
   │      FINALIZE       │  claimers withdraw
   │         3d          │  payout & bond
   └─────────────────────┘
```

Each incident snapshots one `phaseWindow` when it opens; the current deployment uses 3 days. `phaseDeadline` starts as the claim deadline. With no root, settlement is allowed after that deadline through `phaseDeadline + phaseWindow`. A committed or corrected nonzero root replaces `phaseDeadline` with `block.timestamp + phaseWindow`, making it the correction deadline; proof-backed finalization then runs through one further `phaseWindow`. A later Registry timing update cannot change an existing incident.

- anyone may request an incident-open authorization for an insured token. The TEE discovers and signs `referenceBlock`; the first claimant submits it atomically through `fileClaim(..., artifact.referenceBlock, signature)`. Later claimants use the same function with `referenceBlock = 0` and an empty signature. The TEE reads `Registry.incidentOpenPriceConfig`, samples the configured token→immediate-underlying conversion at symmetric non-overlapping blocks before and after the selected block, requires the complete post-reference window finalized, and signs only when the exact post-window sum is strictly more than `minimumDropBps` (default 20%) below the baseline sum. Every insured-token config supplies the conversion address and calldata; USD8 uses `Treasury.usd8ToUsdcRate()` for its capped pro-rata USD8→USDC redemption rate. No insured-token/USD price enters eligibility. The signature binds the price policy and conversion recipe, so governance changes invalidate outstanding authorizations. Opening freezes Cover Pool deposits and settlement of exits that were not already reserved; new exit requests remain loss-exposed.
- claims remain open for the incident's snapshotted phase window (3 days at deployment), after which no further claims are accepted
- anyone can settle with a TEE-signed payout root. The TEE computes claimants' insurance scores and eligible payouts using [payout allocation](#payout-allocation). This algorithm is open source; anyone can run it locally and check the results. Settlement also delists the insured token.
- after settlement, an admin or the timelock can check and correct the root if incorrect (privilege during beta)
- after correction closes, users have one snapshotted phase window to finalize payout. After payout expiry they can still resolve a proof-backed decline or recover escrow through the no-root/void path, but cannot collect an expired payout.
- Cover Pool unfreezes for withdraws
- Only one incident can be active at a time

## File a claim

All claimants use one entrypoint:

`fileClaim(insuredToken, amount, scoreToSpend, boosterAmount, referenceBlock, signature)`

The first claimant copies `referenceBlock` and `signature` from the verified TEE artifact;
`fileClaim` validates them, calls `_openIncident`, and escrows the claim atomically.
Later claimants pass `referenceBlock = 0` and an empty signature. The trusted
admin/timelock emergency route may still call `openClaimIncident(...)` without a TEE signature.

The TEE authorization requires the insured-token/immediate-underlying TWAP ratio
to drop strictly more than the configured threshold. A claim must escrow a nonzero amount of the insured token.


## Finalize claim eligibility
Only claimants meeting the following conditions are eligible for compensation:
- have held the insured token >= 7 days. Excess escrow is refunded during finalization.
- account has USD8 insurance score > 0


## Insured token valuation
There are 3 conversions during a payout.

1. insured token -> underlying token : TWAP price over past 7 days from incident block at every 300 blocks(1 hour).
2. underlying token -> USD: archive-read oracle price at the incident's snapshotted valuation block
3. USD -> cover pool assets: archive-read pool-asset/USD price at the same settlement snapshot


## Payout allocation

Each claimant receives a strict share of the incident payout budget proportional to booster-adjusted score spent. The final payout is the lower of that score entitlement and the covered-loss cap; unused entitlement remains in the cover pools and is not redistributed.

For each claim:

```text
C_i = floor(preIncidentEligibleValueUsd * coverageBps / 10_000)
R_i = min(requestedRawScore, rawUnspentScore)
S_i = floor(R_i * (10_000 + boosterAmount_i * boosterBoostBps) / 10_000)
B   = floor(totalCoverPoolUsd * maxCoverPoolPayoutBps / 10_000)
T   = sum(S_j for all live claims)
E_i = floor(B * S_i / T)
P_i = min(C_i, E_i)
sum(P_i) <= B
```

Only `R_i` is recorded as spent in the Registry. `S_i` is committed in the Merkle leaf and used only for payout allocation. `C_i` is the claim's absolute coverage cap.

## Boosters
- The Registry atomically configures the ERC-1155 collection, token ID, and boost BPS exactly once; the policy has no update path.
- Boosters escrowed when filing a claim increase insurance score according to that permanent policy, so incidents do not snapshot booster configuration.


### Why score-proportional entitlement

Score alone determines each claimant's share of available cover capital: a claimant with 50% of total boosted score receives 50% of the incident budget as entitlement. Loss value cannot compensate for low score; it only caps how much of that entitlement may be collected. A sole claimant with nonzero score receives 100% of the budget entitlement, still bounded by the covered-loss cap.

Entitlement left unused because a claim reaches its covered-loss cap is not redistributed. Unused entitlement and integer-division dust remain in the pools. Each payout is split across the snapshotted cover pools in proportion to their USD value while respecting each pool's incident cap.

The settlement code builds one Merkle root over the exact claim set and payout rows. Any authorized TEE signer may sign it, anyone may settle it, and anyone may independently reproduce it. The Rust production runtime and operations are documented in [`offchain-rust/README.md`](offchain-rust/README.md).

<br/><br/><br/><br/>

# Governance and trust assumptions

- Registry admin and timelock roles are privileged by design. They control upgrades, topology, settlement price feeds and staleness policy, strategy admission and allocation, profit routing, pauses, insured-token parameters, and incident/root operations.
- The timelock alone approves strategy swap target/spender pairs. Admins and the timelock may execute fresh routes. Each strategy permits only USDC → its declared deployment token or any non-position token → USDC; verified USDC output goes directly to Treasury and position tokens cannot be sold through this entrypoint.
- Any authorized TEE signer can open or sign a settlement. Compromise of one signer is bounded by the correction window, pool payout caps, and governance close/correction powers.
- All TEE algorithms are open sourced, user can verify their insurance score, payout amount independently.

## Beta mode and permanent disablement of upgradeability

USD8 launches with Registry `betaMode` enabled. It is a narrow, temporary safety boundary around two classes of critical action:

- UUPS upgrades to Registry, USD8, Treasury, and DefiInsurance require the timelock and are permitted only while beta mode is active.
- `adminCorrectSettlement` lets an admin or the timelock replace or void a standing settlement root during its correction window. It remains subject to the normal incident phase checks and per-pool payout caps.

The timelock can call `endBetaMode()` only while no incident is active. There is no function to re-enable beta mode, so this permanently disables all four UUPS upgrade paths and the direct settlement-correction shortcut for both admins and the timelock. Ordinary governance powers such as parameter changes, topology management, pauses, and strategy controls are not removed.

Cover pools use a separate Ownable beacon and are not controlled by Registry beta mode. The timelock can renounce beacon ownership separately after beta.


## Repository layout

```text
src/
  Registry.sol                  shared access, pause, topology, and score state
  USD8.sol                      stablecoin
  Treasury.sol                  reserve, strategies, mint/redeem, and revenue
  SingleAssetCoverPool.sol      one-asset staking and claim-loss pool
  DefiInsurance.sol             insured tokens, incidents, escrow, and payouts
  adapters/USD8SavingsAdapter.sol
  strategies/StrategyBase.sol
  strategies/ERC4626Strategy.sol

offchain-rust/
  src/                          production settlement runtime and FFI
  README.md                     operations, trust model, and recovery

script/
  01_DeployTimelock.s.sol       step 1: governance timelock
  02_DeployUSD8System.s.sol     step 2: complete mainnet system, including sUSD8
test/                           Foundry tests
```
## Codebase structure

```
                  ┌────────────────┐
                  │                │
                  │    Registry    │
                  │                │
                  └────────────────┘
                           ▲
                           │  Lookups
┌──────────────────────────┴─────────────────────────┐
│                                             Shared │
│                                             Base   │
│                                                    │
│      ┌────────────────┐         ┌───────────┐      │
│      │                │  Mint   │           │      │
│      │    Treasury    ├────────►│   Usd8    │      │
│      │                │  Burn   │           │      │
│      └────────────────┘         └───────────┘      │
│                                                    │
│                              ┌──────────────────┐  │
│                              │                  │  │
│                              │   Cover Pool 1   │  │
│  ┌───────────────┐        ┌─►│                  │  │
│  │               │        │  └──────────────────┘  │
│  │      Defi     ├────────┤                        │
│  │   Insurance   │ Payout │  ┌──────────────────┐  │
│  │               │requests│  │                  │  │
│  └───────────────┘        └─►│   Cover Pool 2   │  │
│                              │                  │  │
│                              └──────────────────┘  │
│                                                    │
└────────────────────────────────────────────────────┘
```
<br/><br/><br/><br/>
# Getting started

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)
- Rust 1.92.0 for the production settlement runtime

## Install and build

```bash
git clone https://github.com/Usd8-fi/usd8-core.git
cd usd8-core
forge install
forge build

cd offchain-rust
cargo build --release --locked
```

## Deployment order

The scripts select Ethereum mainnet (`1`) or Sepolia (`11155111`) from
`block.chainid`. Mainnet addresses are committed in
[`script/config/DeploymentConfig.sol`](script/config/DeploymentConfig.sol).
Sepolia fixes only canonical test USDC and requires explicit test-dependency
addresses; see [`script/README.md`](script/README.md).

```bash
# Keep the Etherscan key in the ignored local .env or shell environment.
source .env

# Set only after independently reviewing the configured Aave launch strategy.
export AAVE_STRATEGY_REVIEWED=true

# 1. Deploy and verify the standalone governance timelock.
forge script script/01_DeployTimelock.s.sol:DeployTimelockScript \
  --rpc-url "$RPC_URL" --broadcast --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"

# Copy the verified address printed by step 1.
TIMELOCK_ADDRESS=0x...

# 2. Deploy, wire, and verify the complete USD8 system, including canonical
# sUSD8 deployment, configuration and its backed 10-USDC dead-share seed.
# The broadcaster must hold at least 10 USDC before running this command.
forge script script/02_DeployUSD8System.s.sol:DeployUSD8SystemScript \
  --sig "run(address)" "$TIMELOCK_ADDRESS" \
  --rpc-url "$RPC_URL" --broadcast --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Step 2 configures sUSD8 while the broadcaster still holds temporary bootstrap
authority, then transfers Registry and vault governance to the verified timelock.
sUSD8 scoring therefore starts during genesis without a 24-hour activation wait.

If broadcast succeeds but verification is interrupted, rerun the corresponding command with `--resume --verify`; do not broadcast a new deployment. Step 2 validates that the timelock address contains contract code and checks its 24-hour delay, proposer/canceller, open executor, and self-admin role before broadcasting.

## Test

```bash
# Solidity
forge test

# Fast local invariant smoke tests
forge test --match-contract ".*InvariantTest" --summary

# Deep Foundry campaign (10,000 stateless cases; 1,000 x 1,000 stateful calls)
FOUNDRY_PROFILE=deep forge test --match-test "testFuzz_.*" -vvv
FOUNDRY_PROFILE=deep forge test --match-contract ".*InvariantTest" -vvv

# Coverage-guided Echidna campaigns (Echidna 2.3.2 + Foundry 1.5.1)
echidna . --contract TreasuryInvariantTest --config echidna.yaml
echidna . --contract SingleAssetCoverPoolInvariantTest --config echidna.yaml
echidna . --contract InsuranceClaimInvariantTest --config echidna.yaml

# Rust production runtime
cd offchain-rust
cargo test --locked
cargo build --release --locked

# Solidity ↔ Rust contract integration
cd ..
RUN_INTEGRATION=1 forge test --offline --ffi --match-path test/SettlementIntegration.t.sol -vv
```


## Security

Each contract has a `@custom:security-contact rick@usd8.fi` NatSpec tag. Security reports will go to [rick@usd8.fi](mailto:rick@usd8.fi) once public reporting opens.

## License

Business Source License 1.1 (BUSL-1.1). See [LICENSE](LICENSE). The code is source-available: you may audit, modify, test, and make non-production use of it freely, but production or commercial use requires a commercial license from the Licensor until the **Change Date (2030-07-01)**. Each version converts to the **MIT License** on its Change Date.
