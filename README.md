# USD8 Core

USD8 is a USDC-backed stablecoin with integrated DeFi insurance. This repository contains the protocol contracts, deployment scripts, tests, and the Rust settlement runtime.

> [!TIP]
> To locally run and verify USD8 results like insurance scores and TEE settlement, [go here](offchain-rust/README.md#start-here-run-locally-and-verify-a-tee-settlement).

- [1. Protocol overview](#1-protocol-overview)
- [2. USD8, Treasury, and savings](#2-usd8-treasury-and-savings)
- [3. Insurance score](#3-insurance-score)
- [4. Cover pools](#4-cover-pools)
- [5. DeFi insurance](#5-defi-insurance)
- [6. Timelock and trust](#6-timelock-and-trust)
- [7. Repository layout](#7-repository-layout)
- [8. Build, test, and deploy](#8-build-test-and-deploy)
- [9. Security](#9-security)
- [10. License](#10-license)

# 1. Protocol overview

```text
         ┌───────────┐                     ┌──────────────┐
         │   Users   │                     │  Cover Pool  │
         └───────────┘                     │      LPs     │
               ▲                           └──────┬───────┘
 1.Mint/Redeem │                                  │
   USD8<->USDC │                      3.Deposit   │
               │                        for yield │                            4.File claim
               ▼                                  ▼                              get payout
      ┌──────────────────┐                 ┌──────────────┐    ┌───────────┐
      │                  │                 │  USD8 Cover  │    │   DeFi    │     ┌─────────┐
      │  USD8 Treasury   ├────────────────►│    Pools     ├────┤ Insurance │◄─── │  Users  │
      │                  │  2.             └──────────────┘    └───────────┘     └─────────┘
      └──────────────────┘  Yield
                            Distribution
```


| Component | Description |
|---|---|
| **USD8** | Simple ERC-20 token. Only Treasury can mint/redeem. |
| **Treasury** | Mints and redeems USD8 for users, receives USDC, deploys it into external yield strategies, and distributes yield across components. |
| **Cover Pools** | High-yield ERC-4626 vaults, each holding a specific token such as wstETH. Anyone can deposit. Assets may be used to cover insurance claims. |
| **DeFi Insurance** | Handles insurance claim logic and has access to funds in Cover Pools. |

<br><br>

# 2. USD8, Treasury, and savings

- Anyone can mint and redeem USD8 1:1 with USDC.
- Treasury may allocate USDC reserves to strategies approved by the timelock.
- Treasury counts idle USDC plus approved strategy assets as reserves. Surplus above its configured reserve buffer may be minted as USD8 revenue, which is routed to configured receivers such as Cover Pools or sUSD8.
- Savings USD8 `sUSD8` is a Morpho Vault. Users deposit USD8 and receive sUSD8. Treasury distributes revenue to this vault. 

> [!CAUTION]
> If USD8 reserves ever fall below supply in an unlikely event, redemption becomes pro-rata for every holder. This avoids a first-come, full-value bank run.

<br><br>

# 3. Insurance score

Insurance score measures block-weighted holdings of configured scored tokens.

- Score is computed off-chain from an append-only on-chain rate history, and the TEE recomputes it at settlement. The algorithm is open source and results are publicly verifiable.
- Score is non-transferable and does not expire.
- An incident only counts score accumulated up to 7 days before its reference block, preventing last-minute score farming.
- Previously spent score is deducted when calculating a claimant's available score.
- Score is consumed only when an eligible claimant accepts a finalized payout.

> [!NOTE]
> Currently only 2 tokens are accruing insurance scores - 1 score per USD8 per day and 0.1 score per sUSD8 per day. However more tokens might be added in the future.

<br><br>

# 4. Cover pools
Cover Pools are high yield ERC-4626 vaults anyone can deposit in. Each Cover Pool contains a specific asset. LPs retain exposure to the deposited asset, earn distributed USD8 rewards, and accept the risk that claims reduce pool principal.

## 4.1 Deposit and rewards

- Deposits are open if no claims are active
- Rewards are paid in USD8, separate from pool principal and thus not exposed to claims. Rewards may be claimed without withdrawing principal.
- Each pool has a cap, no deposit is allowed if pool is full.
- Each incident can use at most 50% of a pool's principal.

## 4.2 Exit flow

1. **Request.** Call `requestRedeem`. Your shares are locked at once and stop earning rewards. You can't cancel, and you can only have one request open at a time.
2. **Wait.** Exits are processed in batches every 3 days, after a minimum 7-day wait. In total that's 7–10 days.
3. **Still at risk while waiting.** Until your exit is processed, your shares can still lose value if the pool pays a claim. If an incident starts after your wait is already over, your exit is processed first and isn't affected. If your wait isn't over yet, your exit is delayed until the incident ends.
4. **Processed.** Your shares are burned and the assets you're owed are set aside for you.
5. **Withdraw.** Call `completeRedeem` to receive your assets. There's no deadline, and you can withdraw even during an incident.

Anyone can trigger processing of finished batches with `settleMaturedExitEpochs(maxEpochs)`. This is paused during incidents.


<br><br>

# 5. DeFi insurance

## 5.1 What is covered

Governance (the timelock) chooses which tokens are insured. For each token it sets:

- the maximum percentage of a loss that can be covered;
- what the token is a wrapper of (its "underlying"), and how to convert between them;
- a price feed for the underlying in USD.

Settlement price sampling (time windows and sampling interval) is set globally, not per token.

> [!IMPORTANT]
> Only the wrapper's own loss is covered. If a token drops in value against what it wraps, that's covered. If the underlying itself drops, it isn't. For example, if a USDC vault token loses value against USDC, that's covered. If USDC itself depegs from $1, that isn't a loss of the vault token.

One incident at a time. When an incident opens, its settings are locked for its whole lifetime: which pools pay, pricing, protocol fee, TEE identity and phase lengths. While it's open:

- no one can deposit into cover pools;
- exits that weren't already processed are paused;
- new exit requests are still allowed, but they share any losses.

## 5.2 Claim lifecycle

An incident moves through four phases. Each lasts 3 days by default.

```text
   ┌─────────────────────┐
   │      1. CLAIM       │  users file claims, escrow insured tokens
   └──────────┬──────────┘
              ▼
   ┌─────────────────────┐
   │      2. SETTLE      │  anyone submits the TEE's signed result
   └──────────┬──────────┘
              ▼
   ┌─────────────────────┐
   │      3. CORRECT     │  admin can fix the result (beta only)
   └──────────┬──────────┘
              ▼
   ┌─────────────────────┐
   │     4. FINALIZE     │  each claimant accepts or declines
   └─────────────────────┘
```

- Each new or corrected result restarts the 3-day correction window.
- After that window closes, claimants can accept or decline their payout.


## 5.3 Filing a claim

The first claim opens the incident, and everyone else joins it. The TEE only signs off on opening once the token has dropped by more than a set threshold (20% by default). 

### When an incident can open

The TEE compares the token's price against its underlying in the **24 hours before** a candidate block with the **24 hours after** it:

```text
  token price vs underlying
        │
   1.00 ┤ ●──●──●──●──●──●──●──●
        │                       ╲
   0.80 ┤ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─╲─ ─ ─ ─ ─ ─ ─ ─ ─ ─   80% of "before" average
        │                         ╲
   0.70 ┤                          ●──●──●──●──●──●──●──●
        │
        └─────────────────────────┬─────────────────────────▶ blocks
          ◀──── 24h BEFORE ──────▶│◀────── 24h AFTER ──────▶
             average = 1.00       │       average = 0.70
                                  │
                           reference block

  0.70 < 0.80  →  more than a 20% drop  →  incident can open
```

How the check works:

1. **Candidate blocks.** Every 300 blocks (about hourly) within the last ~6 days (43,200 blocks) is a possible reference block.
2. **Before average.** Read the price every 300 blocks over the 24 hours (7,200 blocks) before the candidate, and average it.
3. **After average.** Do the same for the 24 hours after it. All of these blocks must already be finalized, so an incident can open no earlier than about 24 hours after the drop.
4. **The drop test.** The candidate qualifies if the after average is **more than 20% below** the before average.
5. **Which block is used.** If several candidates qualify, the TEE uses the first candidate of the most recent drop. That block becomes the incident's **reference block**, which the holding window, score cutoff and pre-drop price are all measured from.

Averaging a full day on each side means a brief wick or a single manipulated block can't open an incident.

The contract also requires that:

- the token is currently listed for insurance;
- no other incident is active;
- the reference block is in the past and at most 43,200 blocks (~6 days) old.

To file, you lock up:

- the insured tokens you're claiming for;
- 10 USD8 bond;
- optionally, booster NFTs to increase your share of the payout.

You can have one claim at a time. During the claim phase, you can cancel and get everything back.

> [!IMPORTANT]
> You will lose your bond if the incident is settled and the result shows your claim was ineligible, meaning:
>
> - you didn't hold the insured token **continuously** through the ~7-day window before the reference block (your lowest balance in that window was zero); or
> - you had **no usable insurance score** at the cutoff (score earned by then, minus score already spent, was zero).
>
> Once your claim is shown to be ineligible, anyone can close it, and the bond goes to the Treasury. Accepting or declining doesn't change this.
>
> You **always get your bond back** if:
>
> - you cancel during the claim phase;
> - you were eligible, whether you accept or decline, and even after the payout window closes; or
> - the incident fails (no valid result, cancelled by governance, or the insurance module is switched off).
>
> Your insured tokens and boosters are always returned, except the eligible portion that's kept when you accept a payout. Only the bond is at risk.

## 5.4 Who is eligible, and how losses are valued

To be eligible, you must have:

- **held the insured token continuously** for about 7 days before the incident's reference block, the last block before the price drop;
- **insurance score** earned by that same cutoff, minus any score you've already spent.

Only the smaller of what you locked up and the lowest balance you held during those 7 days counts.

Your loss is priced using:

1. the token's price against its underlying **just before the drop**: its average value over the 7 days before the reference block;
2. the underlying's USD price **at the end of the claim phase**; and
3. the value of the cover pools at that same moment.

> [!NOTE]
> **How the pre-drop price is calculated**
>
> 1. Start about 7 days before the reference block (`twapLookbackBlocks`, 50,400 blocks by default).
> 2. Every 300 blocks (about once an hour, `sampleStepBlocks`), read how much of the underlying one insured token is worth.
> 3. Keep going up to and including the reference block, about 169 readings in total.
> 4. Take the simple average of those readings.
>
> This average is the token's "normal" value, and losses are measured from it. Using a week of hourly readings stops a brief spike or a single manipulated block from inflating or shrinking claims.
>
> *Example:* a vault share is worth about 1.05 USDC all week, then collapses after the reference block. The average is about 1.05, so each share's loss is measured from 1.05.

Prices come from these fixed points in time, not from when the settlement job happens to run.

## 5.5 How payouts are calculated

1. **Total budget.** Each pool can pay up to a set percentage of its value. The protocol fee is taken out of that, and the rest is the budget for claimants.
2. **Your payout** is the smaller of:
   - **your covered loss**: your eligible loss × the token's coverage percentage; and
   - **your share of the budget**, in proportion to your score, with boosters adding weight.
3. **Unused money stays in the pools.** If someone gets less than their share, the difference isn't handed out to others.
4. **Which pools pay.** Your payout is split across pools by their value. When you accept, you get the full stated amount, and the protocol fee is paid on top of it from the pools.

```text
   ┌──────────────────────────────────────────┐
   │  For each eligible claimant, pay the     │
   │  SMALLER of:                             │
   │   A. covered loss                        │
   │      (eligible loss × coverage %)        │
   │   B. score share of the claimant budget  │
   │                                          │
   └────────────────────┬─────────────────────┘
                        ▼
   ┌──────────────────────────────────────────┐
   │  Split each payout across pools          │
   │  by pool value                           │
   └────────────────────┬─────────────────────┘
                        ▼
              ┌─────────────────┐
              │     Outcome     │
              └────────┬────────┘
          ┌────────────┼────────────┐
          ▼            ▼            ▼
   ┌────────────┐ ┌────────────┐ ┌────────────────┐
   │   ACCEPT   │ │  DECLINE   │ │ INCIDENT FAILS │
   ├────────────┤ ├────────────┤ ├────────────────┤
   │ get payout │ │ get tokens │ │ everyone gets  │
   │ fee paid   │ │ + boosters │ │ tokens,        │
   │ on top     │ │ back       │ │ boosters and   │
   │ bond back  │ │ bond back  │ │ bond back      │
   │ score      │ │ if eligible│ │                │
   │ spent      │ │ else to    │ │                │
   │            │ │ Treasury   │ │                │
   └────────────┘ └────────────┘ └────────────────┘
```

**If you accept:**
- your eligible insured tokens and boosters are kept;
- any extra tokens and your USD8 bond are returned; and
- only your raw score is spent. Boosters add weight but aren't spent as score.

**If you decline:**
- all your insured tokens and boosters are returned; and
- your bond is returned if you were eligible, or goes to the Treasury if you weren't.


If you miss the payout window, you can no longer accept, but you can still decline and get your items back. If the incident fails, every claimant gets back their tokens, boosters and bond.

Technical details, including settlement files, proofs, pricing, TEE attestation and how to reproduce a result, are in [`offchain-rust/README.md`](offchain-rust/README.md).
<br/><br/>

# 6. Timelock and trust

USD8 currently relies on its timelock and defined admin roles, which are trusted by design.

- The timelock controls upgrades, strategy approval, insured-token configuration, settlement parameters, TEE signers, and permanent beta termination.
- Admins retain immediate operational powers including pauses, reserve operations, and profit routing. During beta, an admin or the timelock may also correct settlement roots.
- Any authorized TEE signer can authorize an incident open or sign a settlement root. Results are independently reproducible from the open-source Rust runtime.


## 6.1 Beta mode

While Registry beta mode is active, timelock-authorized UUPS upgrades are available for Registry, USD8, Treasury, and DefiInsurance. Admin or timelock may also correct or void a settlement root during its correction window.

`endBetaMode()` is irreversible and may run only with no active incident. It permanently disables those four UUPS upgrade paths and direct settlement correction. Other timelock and admin powers remain. The design is to end beta mode once the system works well and is fine tuned.

Cover pools use a separate Ownable beacon. Its ownership must be renounced separately to make pool implementations immutable.

<br><br>

# 7. Repository layout

```text
src/                              production Solidity contracts
offchain-rust/                    settlement, score, and TEE runtime
formal-verification/              formal candidates and evidence
script/                           deployment and testnet scripts
test/                             Foundry tests
```

<br><br>

# 8. Build, test, and deploy

## 8.1 Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Rust 1.94.1 (tested toolchain for local verification and the Lambda packages)

## 8.2 Install and build

```bash
git clone https://github.com/Usd8-fi/usd8-core.git
cd usd8-core
forge install
forge build

cd offchain-rust
cargo +1.94.1 build --release --locked
```

## 8.3 Test

```bash
# Solidity
forge test

# Deep Foundry fuzz/invariant profile
FOUNDRY_PROFILE=deep forge test --summary

# Rust settlement runtime
cd offchain-rust
cargo +1.94.1 test --locked
cargo +1.94.1 clippy --locked --all-targets --all-features -- -D warnings

# Solidity ↔ Rust integration
# The test tool is excluded from default builds.
cargo +1.94.1 build --release --locked --features ffi-tools --bin usd8-ffi
cd ..
RUN_INTEGRATION=1 forge test --offline --ffi \
  --match-path test/SettlementIntegration.t.sol -vv
```

## 8.4 Deploy

Deployment scripts select mainnet (`1`) or Sepolia (`11155111`) from `block.chainid`. Mainnet addresses are in [`script/config/DeploymentConfig.sol`](script/config/DeploymentConfig.sol); Sepolia requires explicit test dependencies.

```bash
source .env

# Set ONLY after the configured mainnet Aave strategy and vault have been
# re-reviewed (or replaced). Do not set this by default.
# export AAVE_STRATEGY_REVIEWED=true

# 1. Deploy the timelock
forge script script/01_DeployTimelock.s.sol:DeployTimelockScript \
  --rpc-url "$RPC_URL" --broadcast --slow --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"

# Copy the address printed by step 1
export TIMELOCK_ADDRESS=0x...

# 2. Deploy the protocol using the verified timelock
forge script script/02_DeployUSD8System.s.sol:DeployUSD8SystemScript \
  --sig "run(address)" "$TIMELOCK_ADDRESS" \
  --rpc-url "$RPC_URL" --broadcast --slow --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Step 2 deploys and wires the complete system, seeds the canonical sUSD8 vault with 10 USDC, seeds the cover pool with `0.01 ether` (`10^16` base units) of the configured cover asset, and hands control to the timelock. The broadcaster must hold at least 10 USDC, the cover-pool seed amount of the configured cover asset, and enough native ETH for gas. See [`script/README.md`](script/README.md) for configuration, safety checks, verification, and recovery.

<br><br>

# 9. Security

Security contact: [rick@usd8.fi](mailto:rick@usd8.fi).

Formal-verification work is in [`formal-verification/`](formal-verification/); it is being updated for the current release.

<br><br>

# 10. License

Business Source License 1.1 (BUSL-1.1). See [LICENSE](LICENSE). Production or commercial use requires a commercial license until the Change Date (`2030-07-01`); each version converts to the MIT License on its Change Date.
