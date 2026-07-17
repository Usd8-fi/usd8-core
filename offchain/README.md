# USD8 — TypeScript settlement differential oracle

> **Migration status:** this Node package is retained only for CI differential
> tests and temporary shadow verification. Production uses the Rust runtime in
> [`../offchain-rust`](../offchain-rust/README.md). Do not deploy this package as
> the signer runtime.

This package independently reproduces the claim-payout **merkle root** and
EIP-712 `Settlement` digest. It remains open-source and deterministic so Rust
outputs can be checked against a separately implemented oracle. Cross-language
scripts, historical results, and migration notes live under
[`rust-comparison/`](rust-comparison/README.md), keeping the Rust package itself
standalone.

There is **no trusted operator and no special hardware**. Everything the
computation needs is read from chain state (the per-incident config,
reconstructed from contract state at the incident's `openBlock`; the on-chain
claim set; pool balances and prices), so **anyone can run it locally** to:

- **`compute`** — reproduce the settlement table, the merkle root, and each
  claimant's merkle proof; and
- **`verify`** — recompute independently and check that the root the admin
  submitted on-chain matches. If it doesn't, the root is wrong and can be
  disputed within the dispute window.

## Install the oracle

Requires Node.js 22.22.3 (the version pinned in CI and package metadata).

```bash
cd offchain
npm ci --include=dev
npm run build      # compiles src/ → dist/
```

## Configure

Edit `src/config.ts` with the deployed addresses and the per-asset USD price
feeds (the chain is locked to Ethereum mainnet — chain id 1 — and is not
configurable):

```ts
export const CONFIG = {
  registry:      "0x…",  // Registry (topology: pools, scored tokens, boosterNFT)
  defiInsurance: "0x…",  // DefiInsurance
  // Pool asset pricing is no longer on-chain: map each registered pool asset
  // (lowercased address) → its Chainlink-style USD feed. Every pool asset needs one.
  assetUsdFeed: { "0xa0b8…eb48": "0x8fff…f6" }, // e.g. USDC → USDC/USD feed
};
```

Set `DRPC_KEY` for a live oracle shadow against dRPC Ethereum. The key is sent in
the `Drpc-Key` HTTP header to dRPC's documented
`https://lb.drpc.org/ogrpc?network=ethereum` endpoint, never embedded in the URL
or printed. dRPC archive access is required because settlement reads historical
state:

```bash
export DRPC_KEY="..."
```

For local recomputation with another archive provider, set `RPC_URL` without a
`DRPC_KEY`. If both are set, the key is sent only when `RPC_URL` uses an exact
trusted dRPC HTTPS host (`lb.drpc.org` or `lb.drpc.live`); every other host is
rejected before any request, and HTTP redirects are disabled so the header cannot
cross origins:

```bash
export RPC_URL="https://..."
unset DRPC_KEY
```

The RPC chain id is verified against Ethereum mainnet (`1`) at startup. Registry,
DefiInsurance, pools, and configured price feeds must contain bytecode at their
pinned historical blocks. Log
queries use bounded ranges, recursively bisect full pages, and now also bisect
explicit timeout/range/result-size errors. HTTP requests have a 30-second timeout;
claimant reads use at most eight concurrent requests. A single-block ambiguity
fails closed.

### Optional authenticated score checkpoint

Raw historical replay remains the default independent verifier. The oracle can
index each scored token's global `Transfer` stream once and advance it at later
finalized reference blocks:

```bash
export SCORE_CHECKPOINT_PATH="/sealed-state/usd8-score-index.json"
# Inject from KMS/TEE secret state. Exactly 32 bytes encoded as 64 hex characters.
export SCORE_CHECKPOINT_HMAC_KEY="..."
```

Both variables are required together. Checkpoints are atomically replaced,
process-locked, HMAC-authenticated, bound to chain id and block hash, and rejected
if token decimals or rate history diverge. The HMAC key is never printed or
persisted. Checkpoint cursors advance monotonically; unset both variables and use
raw mode when verifying an older incident whose reference block precedes the
stored cursor. After a process crash, remove a leftover `.lock` file only after
confirming no indexer process is still running. Keep raw mode for independent
recomputation.

## Run the oracle

```bash
# Verify the admin's submitted root for incident 1 (the common case):
npm run verify 1
#   → prints the recomputed table + root, the on-chain root, and MATCH / MISMATCH.
#     Exit code 0 on match, 1 on mismatch.

# Reproduce the full settlement, including per-claim merkle proofs:
npm run compute 1
```

`compute` prints, per claim, the exact `(amounts, scoreSpent, boosterAmountUsed, boostedScore, eligibleAmount, proof)` a
claimant passes to `DefiInsurance.finalizeClaim`. It also publishes the
canonical, address-sorted `(user, grossEarnedScore)` rows and their
`settlementInputHash` as reproducibility metadata; it is not included in the
TEE's EIP-712 signature. Output also records finalized reference/open/window
block hashes; score-source metadata; logical RPC requests; HTTP attempts,
responses, and retries; log bisections/errors/peak concurrency/elapsed time; and
spent-score read count/concurrency/elapsed time.

Each insured token also carries a non-zero `minClaimAmount` in token base
units. The contract enforces it against the escrow actually received before a
claim enters the event stream, so the off-chain settler never needs to filter
sub-minimum claims. This is an economic anti-spam bound, not a hard claimant-
count cap; production thresholds should be selected from token value/decimals
and maximum-load tests.

## What it computes (all from chain state)

1. **Rebuild the claimant table** by replaying `ClaimRegistered` /
   `ClaimCancelled` events in true chain order. The live-claim count is bound
   into the TEE settlement signature (`Incident.unresolved`), pinning the exact
   set that was scored.
2. **Pre-incident value**: TWAP the insured token→underlying ratio over a
   window ending at the incident's `referenceBlock`, times the underlying's
   USD price at the window-end block.
3. **Per claim**: the continuous **minimum balance** of the insured token held
   over `[referenceBlock − holdingMargin, referenceBlock]`, capped at the escrow
   → `eligibleAmount` → `lossUsd`. The holding window is entirely pre-incident:
   it proves prior exposure and ignores transfers after `referenceBlock`.
   `joinClaim` escrows the submitted amount later; finalization forfeits only the
   eligible portion and refunds any excess escrow. Loss remains priced at the
   pre-incident `referenceBlock`.
4. **Score**: each holder's gross earned insurance score **as of `referenceBlock`**
   (token·block integral of the scored tokens), minus cumulative raw spent score read
   from `Registry.scoreSpent` at the end of `openBlock`. The requested raw amount is
   capped to that unspent balance → `scoreSpent`; only this value is recorded on-chain.
   `boosterAmountUsed` is the committed amount capped at the claimant's minimum
   booster balance from end-of-`joinBlock` through `windowEnd`; it multiplies `scoreSpent` into
   a separate `boostedScore`. This is one input to the
   geometric allocation weight, not the sole payout weight. Pinning to
   `referenceBlock` stops anyone farming fresh score during the claim window.
5. **Covered need**: `claimCapUsd = floor(κ × lossUsd)`. This is both an input
   to allocation and the absolute maximum that claim can receive.
6. **Capped geometric allocation**: calculate
   `weight = floor(sqrt(claimCapUsd × boostedScore))`, then solve
   `payoutUsd = min(claimCapUsd, lambda × weight)` against the incident LP-loss
   budget using deterministic water-filling. Split each payout per pool pro-rata
   to the pool mix aligned to `Registry.pools()` at `openBlock`.
7. **Merkle root**: OZ `StandardMerkleTree` over
   `(incidentId, claimId, user, amounts, scoreSpent, boosterAmountUsed, boostedScore, eligibleAmount)`.
   `finalizeClaim` verifies the proof, caps `boosterAmountUsed` to the committed
   amount, and recomputes `boostedScore` exactly on-chain.

### Capped geometric allocation

The allocation intentionally combines two quantities with different units:
covered need (`C`) and score chosen for this incident (`S`). Only relative
weights matter, so their absolute unit scales cancel apart from integer flooring:

```text
C_i = floor(lossUsd_i * coverageBps / 10_000)
R_i = min(requestedRawScore_i, rawUnspentScore_i)
S_i = floor(R_i * boosterMultiplier_i)
W_i = floor(sqrt(C_i * S_i))
B   = floor(poolUsd * maxCoverPoolPayoutBps / 10_000)
P_i = min(C_i, lambda * W_i)
```

The breaking allocator change introduced `CONFIG_VERSION = "4.0.0"`.
Per-insured-token minimum claims use `4.1.0`; strict oracle-round validation uses
`4.2.0`; replay-consistency checks use `4.3.0`; finalized anchors and authenticated
score checkpoints use `4.4.0`; booster-policy commitments use `4.5.0`. The version is part of
`configHash`; the minimal settlement digest and artifact-only config/input hashes use `4.6.0`;
separate raw and boosted settlement scores use `4.7.0`; committed booster usage
and on-chain boost arithmetic validation use `4.8.0`.

The square root gives need and score equal influence in log space and diminishing
returns to accumulated score. Four times the spent score gives twice the weight.
A zero cap or zero score gives zero weight. Splitting `C` and `S` proportionally
across identities preserves aggregate weight before rounding.

To determine `lambda` without floating point or input-order dependence,
`compute.ts` sorts positive-weight claims by `C_i / W_i`. It compares ratios by
exact bigint cross-products and uses `claimId` only to break exact ties. Starting
with the full budget and weight, a claim is saturated when:

```text
remainingBudget * W_i >= C_i * remainingWeight
```

A saturated claim receives `C_i`; its cap and weight are removed, and computation
continues. Once the lowest remaining ratio does not saturate, all remaining
claims receive their pro-rata weighted amount. Division dust stays in the pools.
This is `O(n log n)` and produces one settlement root—there is no extra claimant
step. Finalization remains optional; a declined fixed-root offer is not
redistributed after settlement.

The root README contains the policy rationale and worked example.

Gross score uses `RpcScoreSource` by default. `CheckpointScoreSource` produces
the same numerator arithmetic from a persistent global Transfer index, including
one final WAD division across all tokens and no extra decimal rounding at
checkpoint boundaries. Both feed the same `ScoreSource` interface, payout math,
and canonical artifact input rows.

All tunable parameters (coverage κ, TWAP/holding windows, the conversion recipe,
the underlying oracle, the scored-token set) are read from contract state at the
incident's `openBlock`, not hard-coded here — so two people running this at
different times get the identical root. Only the per-asset pool-valuation feeds
(`assetUsdFeed`) live in `config.ts`.

### Oracle validity at the pinned block

Every Chainlink-style price read fails closed unless the round has a positive
answer and satisfies:

```text
0 < startedAt <= updatedAt <= pinnedBlock.timestamp
answeredInRound >= roundId
pinnedBlock.timestamp - updatedAt <= MAX_ORACLE_STALENESS
```

The feed address, feed implementation/class, decimals, and heartbeat must still
be validated before activation. `MAX_ORACLE_STALENESS` is recorded in
`configHash`; an invalid or stale round produces no settlement root rather than
silently pricing a claim from an impossible or outdated timestamp.

## Tests

Two layers:

```bash
# 1. Unit + ABI-parity tests — settlement math, RPC/index safety,
#    merkle encoding, and handwritten ABI semantics. Fast and no live RPC,
#    but ABI parity needs fresh Foundry artifacts.
cd .. && forge build
cd offchain && npm test

# 2. Cross-language integration — Rust is primary; this package is the explicit
#    independent oracle lane. Both must drive the same contract outcomes:
npm run build
cd ..
RUN_INTEGRATION=1 USE_RUST_FFI=1 forge test --offline --ffi --match-path test/SettlementIntegration.t.sol -vv
RUN_INTEGRATION=1 USE_RUST_FFI=0 forge test --offline --ffi --match-path test/SettlementIntegration.t.sol -vv
```

The integration test is skipped by a plain `forge test` (no `--ffi`, no env), so
it never breaks the default Solidity suite.

## Layout

```
src/config.ts    contract addresses + per-asset USD feeds (the only thing to edit; chain locked to mainnet)
src/chain.ts     read-only RPC helpers (events, prices, balances, config)
src/compute.ts   the settlement algorithm (pure, given the chain reads)
src/score.ts     ScoreSource abstraction + Phase-1 raw-RPC implementation
src/checkpointScore.ts authenticated persistent global Transfer score index
src/runtime.ts   bounded claimant reads + checkpoint environment parsing
src/abiParity.ts semantic parity check against Foundry artifacts
src/ffi.ts       FFI bridge used by the Foundry integration test
src/main.ts      the compute / verify CLI
test/            Vitest unit tests
```
