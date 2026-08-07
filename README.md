# USD8 Core

USD8 is a USDC-backed stablecoin with integrated DeFi insurance. This repository contains the protocol contracts, deployment scripts, tests, and the Rust settlement runtime.

> **Status:** pre-mainnet. A public Sepolia staging deployment is available; mainnet deployment requires separate review and approval.

**Contents**

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

| Component | Purpose |
|---|---|
| [`Registry`](src/Registry.sol) | Shared roles, pause state, topology, scoring, feeds, and incident configuration. |
| [`USD8`](src/USD8.sol) | ERC-20 stablecoin minted and burned only through Treasury. |
| [`Treasury`](src/Treasury.sol) | Holds USDC reserves, mints/redeems USD8, manages approved strategies, and distributes reserve yield. |
| Morpho Vault V2 (`sUSD8`) | Canonical USD8 savings share token backed by [`USD8SavingsAdapter`](src/adapters/USD8SavingsAdapter.sol). |
| [`SingleAssetCoverPool`](src/SingleAssetCoverPool.sol) | ERC-4626 pool where LP capital earns USD8 rewards and absorbs insured losses. |
| [`DefiInsurance`](src/DefiInsurance.sol) | Insured-token configuration, claims, incident settlement, and payouts. |
| [`ERC4626Strategy`](src/strategies/ERC4626Strategy.sol) | Deploys Treasury USDC into an approved ERC-4626 USDC vault. |

<br><br>

# 2. USD8, Treasury, and savings

## 2.1 Mint and redeem

- Anyone may mint USD8 by depositing USDC at 1:1 value.
- In a healthy state, USD8 redeems for up to 1 USDC per USD8.
- If reserves fall below supply, redemption becomes pro-rata for every holder. This avoids a first-come, full-value bank run.
- Treasury may allocate reserves only to strategies approved by the timelock.

## 2.2 Reserve yield

Treasury counts idle USDC plus approved strategy assets as reserves. Surplus above its configured reserve buffer may be minted as USD8 revenue. A protocol fee is applied, and the remainder is routed to configured receivers such as cover pools or sUSD8.

Strategy admission and swap routes are timelock-controlled. Position tokens cannot be sold through the generic swap entrypoint, and verified USDC output goes directly to Treasury.

## 2.3 Morpho savings (`sUSD8`)

`sUSD8` is an official Morpho Vault V2 share token, not a custom vault. Users deposit USD8 and receive sUSD8. Treasury revenue allocated to the vault is released through the savings adapter's configured rate limit.

USD8 and sUSD8 are listed as insured assets in the deployment configuration, subject to their coverage caps and the normal claim process.

<br><br>

# 3. Insurance score

Insurance score measures block-weighted holdings of configured scored tokens.

- Score is computed off-chain by the TEE from an append-only on-chain rate history, algo is open sourced, results publically verifiable.
- Current accrual rates - 1 score per USD8 per day and 0.1 score per sUSD8 per day.
- Score is non-transferable and does not expire.
- An incident will only count score accummulated up to 7 days before the incident block, preventing last min scoring attack
- Previously spent score is deducted when calculating a claimant's available score.
- Score is consumed only when an eligible claimant accepts a finalized payout.

<br><br>

# 4. Cover pools

Each cover asset has a separate ERC-4626 pool. LPs retain exposure to the deposited asset, earn distributed USD8 rewards, and accept the risk that claims reduce pool principal.

## 4.1 Deposit and rewards

- Deposits are open while no incident freezes the pool.
- USD8 rewards are separate from pool principal and may be claimed without withdrawing shares.
- Each pool may have an asset-denominated soft deposit cap set by an admin or the timelock; zero means uncapped. Reward rates are not guaranteed.
- Each incident may use at most the configured share of active pool assets; the default is 50%.

## 4.2 Exit flow

1. `requestRedeem` escrows shares immediately. The request cannot be cancelled and stops earning USD8 rewards.
2. Requests mature in three-day batches after a seven-day minimum cooldown, producing a 7–10 day wait under the default configuration.
3. Before settlement, escrowed shares remain exposed to pool losses. If an incident opens first, settlement waits until the incident resolves.
4. Once an exit epoch is settled, its shares are burned and the corresponding assets are reserved.
5. The user calls `completeRedeem`; the reserved claim does not expire.

Anyone may process matured epochs in bounded batches with `settleMaturedExitEpochs(maxEpochs)`.

<br><br>

# 5. DeFi insurance

## 5.1 What is covered

The timelock lists insured tokens and sets for each token:

- a maximum coverage percentage;
- the immediate underlying conversion;
- an underlying/USD oracle; and
- settlement sampling parameters.

Coverage applies to loss in the insured token relative to its immediate underlying. A loss in the underlying itself is not a wrapper claim. For example, a wrapper-to-USDC loss may be covered, but a USDC/USD depeg is not treated as that wrapper's loss.

Only one incident may be active at a time. Opening an incident snapshots its pools, pricing configuration, fee share, TEE identity, and phase duration. It also freezes new pool deposits and settlement of unreserved exits; new exit requests remain available but loss-exposed.

## 5.2 Claim lifecycle

```text
   ┌─────────────────────┐
   │       CLAIM         │  file or cancel claims
   │    phaseWindow      │
   └──────────┬──────────┘
              ▼
   ┌─────────────────────┐
   │       SETTLE        │  anyone relays a TEE-signed root
   │    phaseWindow      │
   └──────────┬──────────┘
              ▼
   ┌─────────────────────┐
   │      CORRECT        │  admin/timelock during beta
   │    phaseWindow      │
   └──────────┬──────────┘
              ▼
   ┌─────────────────────┐
   │      FINALIZE       │  claimant accepts or declines
   │    phaseWindow      │
   └─────────────────────┘
```

The default `phaseWindow` is three days and is snapshotted per incident. Opening starts the claim window; settlement is allowed during the next window. Committing or correcting a nonzero root starts a fresh correction window, and each further correction resets it. Proof finalization opens after the resulting correction deadline, with payout acceptance available for one further window. Timelock timing changes do not alter an active incident.

## 5.3 Filing a claim

The first TEE-signed claim opens the incident; later users join it. Each user may have one live claim and escrows the insured token, configured USD8 bond, and any optional ERC-1155 boosters. During the claim phase, users may cancel and recover all escrow.

The TEE opens only after finalized price samples exceed the configured drop threshold (20% by default). The trusted admin or timelock retains an emergency open route without a TEE signature.

## 5.4 Eligibility and valuation

An eligible claim requires:

- a positive minimum insured-token balance throughout `max(1, referenceBlock - minHoldingRequired)` through `referenceBlock`; and
- a nonzero requested raw-score spend, capped to score accrued through that same cutoff minus cumulative score spent as of `openBlock`.

The eligible amount is the lower of escrow and that minimum historical balance. Settlement values it using:

1. insured token to immediate underlying from the pre-reference TWAP ending at `referenceBlock`;
2. immediate underlying to USD at `windowEnd`, the latest finalized block at or before the claim deadline; and
3. cover-pool accounted balances and pool-asset/USD prices at that same `windowEnd`.

Worker execution time does not choose a valuation anchor.

## 5.5 Payout allocation

The runtime derives a gross incident cap from window-end pool values and the snapshotted per-pool payout limit, then deducts the snapshotted protocol-fee share to obtain the claimant budget. Each claimant receives the lower of:

- the covered-loss cap from eligible value and the token's coverage percentage; and
- a share of the claimant budget proportional to booster-adjusted score.

Unused entitlement and rounding dust remain in the pools; neither is redistributed. Claimant amounts are split across pools by their window-end USD value. On acceptance, each amount is grossed up against pool capital: the claimant receives the stated net amount and the difference goes to the currently configured protocol-fee receiver.

Boosters increase allocation weight under a permanent Registry configuration, but only raw score is spent. If an eligible claimant accepts, eligible insured-token escrow and boosters are consumed; excess escrow and the USD8 bond are returned. On a proof-backed decline, all insured-token escrow and boosters are returned; eligible claimants recover the bond, while ineligible claimants forfeit it to Treasury.

After payout expiry, proof-backed decline remains available but payout acceptance does not. If no usable root exists, the incident is voided, or the module is inactive, claimants recover escrow, boosters, and bond through the no-settlement path once it opens.

Settlement artifacts, Merkle leaves, pricing anchors, TEE attestation, RPC completeness rules, and reproduction commands are documented in [`offchain-rust/README.md`](offchain-rust/README.md).

<br><br>

# 6. Timelock and trust

USD8 currently relies on its timelock and defined admin roles, which are trusted by design.

- The timelock controls upgrades, strategy and swap-route approval, insured-token configuration, settlement parameters, TEE signers, and permanent beta termination.
- Admins retain immediate operational powers including pauses, reserve operations, and profit routing. During beta, an admin or the timelock may also correct settlement roots.
- Any authorized TEE signer can authorize an incident open or sign a settlement root. Results are independently reproducible from the open-source Rust runtime.
- Pool, token, strategy, oracle, and profit-routing configuration must be reviewed operationally; the contracts do not attempt to defend against every trusted-role misconfiguration.

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
- Rust 1.92.0 for the settlement runtime
- Rust 1.94.1 for the Lambda packages

## 8.2 Install and build

```bash
git clone https://github.com/Usd8-fi/usd8-core.git
cd usd8-core
forge install
forge build

cd offchain-rust
cargo +1.92.0 build --release --locked
```

## 8.3 Test

```bash
# Solidity
forge test

# Deep Foundry fuzz/invariant profile
FOUNDRY_PROFILE=deep forge test --summary

# Rust settlement runtime
cd offchain-rust
cargo +1.92.0 test --locked
cargo +1.92.0 clippy --locked --all-targets --all-features -- -D warnings

# Solidity ↔ Rust integration
cd ..
RUN_INTEGRATION=1 forge test --offline --ffi \
  --match-path test/SettlementIntegration.t.sol -vv
```

## 8.4 Deploy

Deployment scripts select mainnet (`1`) or Sepolia (`11155111`) from `block.chainid`. Mainnet addresses are in [`script/config/DeploymentConfig.sol`](script/config/DeploymentConfig.sol); Sepolia requires explicit test dependencies.

```bash
source .env

# Set only after reviewing the configured launch strategy and vault.
# The configured mainnet Aave vault must be re-reviewed or replaced before launch.
export AAVE_STRATEGY_REVIEWED=true

# 1. Deploy the timelock
forge script script/01_DeployTimelock.s.sol:DeployTimelockScript \
  --rpc-url "$RPC_URL" --broadcast --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"

# Copy the address printed by step 1
export TIMELOCK_ADDRESS=0x...

# 2. Deploy the protocol using the verified timelock
forge script script/02_DeployUSD8System.s.sol:DeployUSD8SystemScript \
  --sig "run(address)" "$TIMELOCK_ADDRESS" \
  --rpc-url "$RPC_URL" --broadcast --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Step 2 deploys and wires the complete system, seeds the canonical sUSD8 vault with 10 USDC, seeds the cover pool with `0.01 ether` (`10^16` base units) of the configured cover asset, and hands control to the timelock. The broadcaster must hold at least 10 USDC, the cover-pool seed amount of the configured cover asset, and enough native ETH for gas. See [`script/README.md`](script/README.md) for configuration, safety checks, verification, and recovery.

<br><br>

# 9. Security

Security contact: [rick@usd8.fi](mailto:rick@usd8.fi).

Formal-verification scope and evidence are in [`formal-verification/`](formal-verification/).

<br><br>

# 10. License

Business Source License 1.1 (BUSL-1.1). See [LICENSE](LICENSE). Production or commercial use requires a commercial license until the Change Date (`2030-07-01`); each version converts to the MIT License on its Change Date.
