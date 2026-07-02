# USD8 — off-chain settlement computation

When a covered DeFi incident is opened, this computation produces the
claim-payout **merkle root**. In production it runs inside a TEE whose key
signs the result (EIP-712 `Settlement`, see `settlementTypedData` in
`compute.ts`), so anyone can submit it on-chain
(`DefiInsurance.settleIncidentSigned`); the admin/timelock path
(`settleIncident`) remains as a fallback. The tool is fully open-source and
deterministic.

There is **no trusted operator and no special hardware**. Everything the
computation needs is read from chain state (the per-incident config snapshot,
the claimant-table commitment `Incident.inputHash`, pool balances and prices),
so **anyone can run it locally** to:

- **`compute`** — reproduce the settlement table, the merkle root, and each
  claimant's merkle proof; and
- **`verify`** — recompute independently and check that the root the admin
  submitted on-chain matches. If it doesn't, the root is wrong and can be
  disputed (`voidSettlement`) within the dispute window.

## Install

Requires Node.js 20+.

```bash
cd offchain
npm install
npm run build      # compiles src/ → dist/
```

## Configure

Edit `src/config.ts` with the deployed proxy addresses (the chain is locked to
Ethereum mainnet — chain id 1 — and is not configurable):

```ts
export const CONFIG = {
  coverPool:     "0x…",  // CoverPool proxy
  defiInsurance: "0x…",  // DefiInsurance
};
```

Set `RPC_URL` to any **archive** node for mainnet (archive is required — the
tool reads historical state at the incident's window-end block; its chain id is
verified against 1 at startup):

```bash
export RPC_URL="https://…"
```

## Run

```bash
# Verify the admin's submitted root for incident 1 (the common case):
npm run verify 1
#   → prints the recomputed table + root, the on-chain root, and MATCH / MISMATCH.
#     Exit code 0 on match, 1 on mismatch.

# Reproduce the full settlement, including per-claim merkle proofs:
npm run compute 1
```

`compute` prints, per claim, the exact `(amounts, scoreSpent, proof)` a
claimant passes to `DefiInsurance.finalizeClaim`.

## What it computes (all from chain state)

1. **Rebuild the claimant table** by replaying `ClaimRegistered` /
   `ClaimCancelled` events in true chain order, then **assert** its
   `inputHash` equals the value the contract stored — a reordered or partial
   table is rejected before anything else runs.
2. **Pre-incident value**: TWAP the insured token→underlying ratio over a
   window ending at the incident's `referenceBlock`, times the underlying's
   USD price at the window-end block.
3. **Per claim**: the continuous **minimum balance** of the insured token held
   over `[referenceBlock − holdingMargin, joinBlock − 1]` (which also dedupes
   across claimants), capped at the escrow → eligible amount → `lossUsd`. The
   window runs up to the block *before* the claim's `joinClaim` (which escrows
   the token out of the wallet), so the escrow itself never reduces it, yet the
   claimant must have held continuously from before the incident right up to
   filing. The loss is still **priced** at the pre-incident `referenceBlock`.
4. **Score**: each holder's earned insurance score **as of `referenceBlock`**
   (token·block integral of the scored tokens, plus committed boosters), minus
   already-spent score from the pool ledger (also at `referenceBlock`), capped to
   what the claim requested → `scoreSpent` (the payout weight). Pinning to
   `referenceBlock` stops anyone farming fresh score during the claim window.
5. **Payout**: `min(scoreShare × poolUsd, κ × lossUsd)`, split per stake asset
   pro-rata to the pool mix, in CoverPool's asset-list order.
6. **Merkle root**: OZ `StandardMerkleTree` over
   `(incidentId, claimId, user, amounts, scoreSpent)` — the exact leaf
   encoding `finalizeClaim` verifies.

All tunable parameters (coverage κ, TWAP/holding windows, the rate adapter,
the price oracle, the scored-token set) are read per-incident from the
on-chain snapshot, not hard-coded here — so two people running this at
different times get the identical root.

## Tests

Two layers:

```bash
# 1. Unit tests — the settlement algorithm (payout math, score/booster, merkle
#    encoding, inputHash) over stubbed chain reads. Fast, no RPC.
npm test

# 2. Cross-language integration — drives a real incident in Foundry, then uses
#    THIS package (via FFI) to produce the inputHash / root / proofs and proves
#    they reproduce the on-chain inputHash, settle, and pay each claimant exactly
#    the off-chain amounts. Requires the build artifacts and is opt-in:
npm run build
cd .. && RUN_INTEGRATION=1 forge test --ffi --match-path test/SettlementIntegration.t.sol -vv
```

The integration test is skipped by a plain `forge test` (no `--ffi`, no env), so
it never breaks the default Solidity suite.

## Layout

```
src/config.ts    contract addresses (the only thing to edit; chain locked to mainnet)
src/chain.ts     read-only RPC helpers (events, prices, balances, config)
src/compute.ts   the settlement algorithm (pure, given the chain reads)
src/ffi.ts       FFI bridge used by the Foundry integration test
src/main.ts      the compute / verify CLI
test/            Vitest unit tests
```
