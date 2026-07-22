# Rust-Only Settlement Runtime Implementation Plan

> **For Hermes:** Execute every task with strict RED→GREEN TDD. Preserve unrelated dirty Solidity, deployment, and TypeScript work. TypeScript remains an oracle during migration but is not a production runtime dependency.

**Goal:** Extend the byte-identical Rust settlement kernel into a complete Rust production runtime that reads finalized Ethereum state, reconstructs inputs, computes or verifies settlements, emits commitments/proofs/EIP-712 digest material, and optionally maintains an authenticated score checkpoint.

**Architecture:** Keep the existing deterministic `allocate` kernel isolated from network and persistence. Add a minimal async JSON-RPC layer (`reqwest`/`tokio`), compile-time ABI types (`alloy-sol-types`/`alloy-primitives`), chain reconstruction modules, a pure production-input resolver, and CLI orchestration. Preserve the existing fixture benchmark entrypoint. Every expensive chain run is anchored beneath `finalized`, rechecks hashes before output, and fails closed on replay inconsistency or unprovable log completeness.

**Tech stack:** Rust 1.91.1; `alloy-primitives`/`alloy-sol-types` 1.6; `reqwest`; `tokio`; `serde`; `hmac`/`sha2`; existing BigUint/Keccak kernel; Foundry artifacts and TypeScript only as differential test authorities.

## Completion status — 2026-07-15

- [x] Tasks 1–9 implemented with Rust tests.
- [x] Mock-RPC production resolver and atomic artifact round-trip pass.
- [x] Rust and TypeScript FFI both drive the Foundry settlement integration.
- [x] Small, matrix, and 1,000-user real-history fixtures have exact parity.
- [x] Rust, TypeScript, Forge, dependency-audit, docs, and hygiene gates pass.
- [x] CI makes Rust FFI primary and retains TypeScript as an independent oracle.
- [ ] External deployment gate: run archive-RPC shadows after nonzero deployed
  Registry, DefiInsurance, and feed addresses are available.
- [ ] External signer gate: exercise KMS/TEE policy and rollback runbook against
  internally verified Rust artifacts.

The two unchecked items require deployed infrastructure, not more settlement
runtime code. TypeScript must remain an oracle until both pass.

---

## Task 1: Production types and cancelled-claim semantics

**Files:** `src/lib.rs`; `tests/production_vectors.rs`.

1. RED: cancelled registrations remain in rolling claim-set hash but are absent from payout rows; live registrations preserve true chain order.
2. GREEN: introduce production event/anchor/config/resolved-input types and `allocate_with_events`, while preserving legacy fixture behavior.
3. RED/GREEN: reject duplicate live users/claims and inconsistent live-event/resolved-claim sets.
4. Run all Rust tests and existing TypeScript parity fixtures.

## Task 2: Rust bootstrap configuration and config commitment

**Files:** create `src/config.rs`; test `tests/config.rs`.

1. RED/GREEN: derive configuration from one Registry address at `openBlock`; reject invalid module binding, unsupported booster policy, zero staleness, and missing feeds.
2. RED/GREEN: reproduce TypeScript `configHash` byte-for-byte, including derived chain state and baked log completeness policy.
3. RED/GREEN: secure RPC selection—dRPC key only to exact trusted HTTPS hosts, never in URL/output, redirects disabled.

## Task 3: Minimal ABI and EIP-712 primitives

**Files:** create `src/abi.rs`, `src/typed_data.rs`; tests `tests/abi.rs`, `tests/typed_data.rs`.

1. RED/GREEN: function selectors and call/return decoding for every DefiInsurance, Registry, pool, ERC-20, ERC-1155, feed, and conversion read.
2. RED/GREEN: decode ClaimRegistered/ClaimCancelled, ERC-20 Transfer, and ERC-1155 TransferSingle/TransferBatch logs.
3. RED/GREEN: reproduce Solidity/TypeScript settlement typed-data digest and pools hash golden vectors.
4. RED/GREEN: compare first-party ABI semantics against current Foundry artifacts.

## Task 4: Async JSON-RPC transport

**Files:** `src/rpc.rs`; `tests/rpc.rs` with local mock HTTP server.

1. RED/GREEN: `eth_chainId`, block, call, code, and logs requests with strict JSON-RPC response/error validation.
2. RED/GREEN: bounded retry policy for transient transport/HTTP errors, explicit timeout, no redirects, stable request IDs, and metrics separating logical calls/HTTP attempts/retries.
3. RED/GREEN: dRPC header safety and credential-redaction tests.
4. RED/GREEN: bounded log ranges, result-cap and recognized range-error bisection, inverted range, single-block fail-closed behavior.

## Task 5: Finalized anchors and historical chain reads

**Files:** create `src/chain.rs`; tests `tests/chain.rs` using in-memory RPC trait fixtures.

1. RED/GREEN: last block at/before deadline bounded by finalized head.
2. RED/GREEN: reference/open/window/finalized anchors and post-compute hash recheck.
3. RED/GREEN: provisional incident immutable fields must match finalized-state incident.
4. RED/GREEN: historical bytecode checks, incident config/rate histories, pool topology, pool balances, feeds, decimals, score-spent reads.
5. RED/GREEN: strict oracle round validity and conversion return validation.

## Task 6: Event replay, eligibility, booster, and raw score

**Files:** `src/chain.rs`, `src/checkpoint.rs`; `tests/history.rs`, `tests/score.rs`.

1. RED/GREEN: event ordering and cancellation membership; claim-set hash/unresolved reconciliation at exact window-end state.
2. RED/GREEN: ERC-20 self-transfer netting, continuous minimum balance, token-block integral, and endpoint balance reconciliation.
3. RED/GREEN: ERC-1155 single/batch/self-transfer minimum holding with endpoint reconciliation.
4. RED/GREEN: exact rate segments, decimal normalization, skipped zero/non-overlap segments, and one final cross-token WAD division.
5. RED/GREEN: bounded concurrent spent-score reads with deduplication and metrics.

## Task 7: Full Rust settlement resolver and verifier

**Files:** `src/engine.rs`, `src/artifact.rs`; `tests/engine.rs`.

1. RED/GREEN: reconstruct complete settlement input from a canned but ABI-realistic JSON-RPC transcript.
2. RED/GREEN: TWAP, oracle, pools, claims, eligibility, scores, boosters, allocation, hashes, root, and every proof match frozen TypeScript authority output.
3. RED/GREEN: re-read the latest submitted root after expensive work, then make
   the anchor hash assertion the final RPC operation before output.
4. RED/GREEN: `verify` returns mismatch status when chain root differs and match status only on exact equality.
5. RED/GREEN: internally verify every proof, pool totals, row uniqueness, and commitment recomputation before output.

## Task 8: Authenticated persistent score checkpoint

**Files:** `src/checkpoint.rs`; `tests/score.rs`.

1. RED/GREEN: port schema, deterministic serialization, HMAC-SHA256 authentication, constant-time verification, mode-0600 temporary write, atomic rename, and exclusive lock.
2. RED/GREEN: bind chain ID, token decimals, cursor block/hash, and append-only rate prefix; reject tamper/reorg/rollback/retroactive rate insertion.
3. RED/GREEN: preserve active raw integral across checkpoint boundaries and >18-decimal normalization; final divide once across all tokens.
4. RED/GREEN: stream global Transfer chunks rather than retaining full history; reconcile each queried claimant endpoint.
5. Differential-check all existing TypeScript checkpoint matrices.

## Task 9: Production CLI and Rust FFI

**Files:** `src/main.rs`, `src/ffi.rs`, `Cargo.toml`; `tests/cli.rs`, `tests/ffi.rs`.

1. Preserve legacy `usd8-settlement <fixture> [iterations] [warmup]` benchmark mode.
2. Add `compute <incidentId> --registry <address>` and `verify <incidentId> --registry <address>` using `ETH_RPC_URL`/`DRPC_KEY` and optional checkpoint environment.
3. Add atomic `--output` artifact writing and stdout mode; never print secrets.
4. Add Rust FFI `root`, `proof`, `digest`, and `claimset` commands with ABI-compatible stdout for Foundry.
5. RED/GREEN exact CLI exit codes: usage 2, mismatch 1, fatal 1, success 0.

## Task 10: Integration, CI, documentation, and removal-readiness

**Files:** update `offchain-rust/README.md`; carefully update `.github/workflows/test.yml` and `test/SettlementIntegration.t.sol` only after rereading their live dirty state; retain TypeScript differential jobs during migration.

1. Wire Foundry FFI integration to Rust binary and prove real contract leaf/root/digest/claim-set parity.
2. Run Rust-only mock-RPC compute and verify end-to-end.
3. Run existing TypeScript build/tests and TS↔Rust differential fixtures to prove no semantic drift.
4. Run `cargo fmt`, Clippy `-D warnings`, all tests, release build, `cargo audit`, Forge build/tests/FFI, and diff/secret hygiene.
5. Document exact config, commands, output schema, finality/reorg model, checkpoint operations, remaining deployment-address prerequisite, and criteria for deleting TypeScript runtime.
6. Retain TypeScript only as CI oracle until shadow settlements pass; production Rust must have no Node dependency.

## Completion criteria

- Rust `compute` and `verify` perform every current TypeScript production read and fail-closed validation.
- Rust outputs exact rows, commitments, root, and proofs and exposes the exact EIP-712 digest.
- Cancelled claims and real chain event order are represented correctly.
- Raw and checkpoint score paths agree on golden matrices.
- Foundry integration no longer needs Node for FFI.
- No RPC/HMAC credential enters repository artifacts or logs.
- Existing dirty non-Rust business-logic files are preserved.
- Mainnet live run is blocked explicitly until nonzero deployed Registry/DefiInsurance/feed addresses are supplied; full mock-RPC and Foundry integration pass meanwhile.
