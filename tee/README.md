# USD8 CoverPool — TEE settlement engine

Computes a CoverPool incident's settlement table off-chain and signs the
merkle root the contract pays against. **The same binary is the signer and
the public verifier** — that equivalence is the trust model: anyone runs
`verify` during the dispute window and confirms a published root matches an
independent recompute from chain history.

## Modes

```
RPC_URL=<archive-node>  node dist/main.js verify <incidentId>   # recompute, no key
SIGNER_KEY=0x...        node dist/main.js settle <incidentId>   # recompute + sign
                        node dist/main.js keygen                # in-enclave key
```

`verify` needs no key and prints the full table + root. `settle` additionally
EIP-712-signs `Settlement(incidentId, root, inputHash)` with the enclave key.

## What it computes (all recomputable from chain)

1. Rebuild the claimant table from `ClaimRegistered`/`ClaimCancelled` events,
   then **assert** its `inputHash` equals the value the contract stored — a
   reordered or partial table is rejected before anything is signed.
2. Detect incident block **B**: the pre-cliff edge where the token's ratio vs
   its underlying dropped ≥ θ within δ (no valid cliff → throw, do NOT sign;
   that is the on-chain void path).
3. Per claim: continuous **min-balance** of the insured token since `B −
   margin` (this also dedupes across claimants for free), valued at the
   pre-incident **TWAP ratio × underlying USD**; USD8 history **score** =
   time-weighted USD8 balance.
4. `payoutUsd = min(score/Σscore × poolUsd, κ × lossUsd)`, split per stake
   asset pro-rata to the pool mix, in CoverPool's `assetList` order.
5. OZ `StandardMerkleTree` over `(incidentId, claimId, user, amounts)` — the
   exact leaf encoding `finalizeClaim` verifies.

## Parameters

All θ / W / δ / margin / score-lookback live in `src/config.ts`, baked into
the enclave image. The Nitro **PCR0 measurement therefore commits to the
parameters** — change any value and the attested measurement changes,
publicly. Combined with the on-chain `inputHash` (claimant table) and EIP-712
domain (contract + chain), nothing about a settlement is unbound.

## AWS Nitro notes

- No network in the enclave; reach an archive node via the parent's
  vsock→TCP proxy. TLS terminates inside, so the parent is a liveness
  dependency only — and CoverPool already survives a missing signer via
  `voidSettlement` + `withdrawClaim`.
- `keygen` once inside the enclave; the secp256k1 key stays in enclave
  memory, its address goes in the attestation document. Set CoverPool's
  `claimSigner` to that address (timelock).
- Build is pinned (`Dockerfile` digests are placeholders — fill before
  release) so independent rebuilds reproduce PCR0.

## Status

Reference implementation. Before production: fill real addresses/digests in
`config.ts` and `Dockerfile`, pin `package-lock.json`, add per-token unit
tests against fork data, and parallelise the per-claim chain reads.
