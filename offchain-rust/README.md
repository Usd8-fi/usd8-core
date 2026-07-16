# USD8 Rust settlement runtime

Rust is the production settlement path. It performs finalized Ethereum reads,
event replay, historical eligibility and score reconstruction, pool/oracle
valuation, allocation, commitments, OpenZeppelin-compatible Merkle proofs, and
EIP-712 digest construction without invoking Node or TypeScript. The old
fixture-only kernel mode remains for deterministic benchmarks. TypeScript is a
temporary independent CI oracle, not a Rust runtime dependency.

All settlement arithmetic uses `BigUint` intermediates and checks values before
ABI encoding as `uint256`. JSON integers are canonical decimal strings.

## Build and quality gate

```bash
cd offchain-rust
cargo fmt --check
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo test --locked
cargo build --release --locked
cargo audit --deny warnings
```

`cargo audit` ignores three unmaintained-only RustSec notices in
`.cargo/audit.toml`: one unreachable optional Alloy lock dependency and two
compile-time dependencies of the latest Alloy release. Vulnerabilities remain
denied. Remove the exceptions when Alloy removes those dependencies.

## Production configuration

Copy `config/example.json`, then replace every example address with the deployed
address for the selected chain. The exact, unknown-field-denying schema is:

- `version`: currently `4.5.0`;
- `chainId`, deployed `registry`, and deployed `defiInsurance`;
- decimal strings `boosterId` (`1`) and `boosterBoostBps` (`100`);
- `assetUsdFeed`: lowercase pool-asset address keys to nonzero Chainlink-style
  feed addresses, covering every active pool asset;
- positive decimal string `maxOracleStaleness`, `maxLogRange` in `1..=2048`,
  and `logResultCap` in `1..=10000`.

The runtime hashes the canonical configuration and binds `configHash` into the
settlement digest. It rejects zero/duplicate contracts, unsupported policy
versions, noncanonical feed keys, missing feeds, wrong chain ID, or contracts
without historical bytecode. `config/example.json` contains placeholders and
must not be used for a production settlement.

## Compute and verify

Use an archive-capable RPC with historical `eth_call`, `eth_getCode`,
`eth_getLogs`, and `finalized` block support:

```bash
export ETH_RPC_URL='https://trusted-rpc.example'

target/release/usd8-settlement compute 7 \
  --config config/mainnet.json \
  --raw-score \
  --output artifacts/incident-7.json

target/release/usd8-settlement verify 7 \
  --config config/mainnet.json \
  --raw-score
```

`--rpc-url` overrides `ETH_RPC_URL`. `--output` uses a same-directory temporary
file, `fsync`, atomic rename, directory `fsync`, byte-for-byte read-back, and
JSON read-back. Its parent directory must already exist. Without `--output`, the
artifact is written to stdout. Config, checkpoint, checkpoint-lock, and output
paths are resolved before RPC work and rejected if any writable paths alias.
`compute` includes each proof; `verify` omits
proofs and compares the reproduced root with the latest on-chain root.

Optional flags are `--timeout-ms <1..=120000>`, `--no-drpc-key`,
`--checkpoint <path>`, `--checkpoint-key-env <name>`, and `--raw-score`.
Checkpoint and raw modes are mutually exclusive. The default checkpoint key
variable is `SCORE_CHECKPOINT_KEY`; `SCORE_CHECKPOINT_PATH` supplies a default
path when neither score-mode flag is present.

Exit codes are stable:

- `0`: compute succeeded, or verify matched;
- `1`: verify mismatch or fatal chain/config/I/O/invariant failure;
- `2`: malformed command-line usage.

The artifact includes schema/config versions and hash, all four block anchors,
RPC/log metrics, score-source provenance, claim-set and settlement-input
commitments, ordered pools and payouts, root/on-chain root/match flag, EIP-712
digest, canonical score input rows, payout rows, and optional proofs. Before any
output, Rust independently recomputes the claim-set hash, input hash, Merkle
root/proofs, per-pool row totals, and settlement digest.

## Authenticated score checkpoint

Raw mode replays score-token history for every requested user. Checkpoint mode
streams each token's global `Transfer` history once and persists authenticated
state:

```bash
export SCORE_CHECKPOINT_PATH="$PWD/state/mainnet-score.json"
export SCORE_CHECKPOINT_KEY="$(openssl rand -base64 48)"

target/release/usd8-settlement compute 7 \
  --config config/mainnet.json \
  --checkpoint "$SCORE_CHECKPOINT_PATH" \
  --output artifacts/incident-7.json
```

The integrity key must contain at least 32 bytes and must remain outside the
repository. Generate it once, store it in the deployment secret manager, and
reuse it for every advance of that checkpoint. The checkpoint is HMAC-SHA256
authenticated, written through a mode-0600 temporary file, atomically renamed,
and protected by an exclusive `.lock` file. Checkpoint reads and writes have a
hard 128 MiB limit; reads are capped before JSON parsing, and both temporary and
final bytes are read back before commit returns. Secret key bytes are redacted
from runtime debug formatting. The lock is held from checkpoint
load through score endpoint reconciliation, latest-state read, final anchor
recheck, and internal artifact verification. The advanced state is committed
only after those checks succeed; computation or verification failure leaves the
previous checkpoint unchanged. A filesystem error reported after atomic rename
may leave the new authenticated checkpoint in place; inspect and authenticate
that file before recovery rather than assuming the old state survived. It binds
chain ID, token decimals, cursor block/hash, account
integrals, and the append-only rate-history prefix. It rejects authentication
failure, chain mismatch, rollback, reorg, retroactive rate edits, negative
replay balance, or endpoint `balanceOf` mismatch.

Recovery is fail-closed: never edit a checkpoint. Preserve a rejected file for
forensics, choose a fresh path, and rebuild from chain history with the same
integrity key or a deliberately rotated key. Remove a stale `.lock` only after
confirming no runtime process owns the checkpoint. Keep raw mode available as
an independent differential check.

## RPC credential boundary

`DRPC_KEY` is sent only as a sensitive `drpc-key` header to the exact trusted dRPC
HTTPS hosts accepted by `HttpRpc`; redirects are disabled and the key is never
placed in URLs or artifacts. For any other RPC, use `--no-drpc-key` so an
accidentally inherited `DRPC_KEY` cannot be attached. Keys and checkpoint
integrity material must be supplied through environment variables, never CLI
arguments or committed files.

Every HTTP response body is streamed through a hard 16 MiB cap before one JSON
parse; oversized `Content-Length` and chunked bodies fail closed. Body
timeout/reset errors are retried inside the bounded request retry policy. Each
initial log chunk has a five-minute deadline and hard logical-request,
transport-attempt, and bisection budgets. Generic transport timeouts and bare
HTTP 408 responses are never treated as range-limit signals; only explicit
provider range/result-size errors or the local response cap can trigger
bisection. Returned logs must match the exact requested range, address, and
topics, declare `removed: false`, contain at most four topics, and have unique
`(blockNumber, logIndex)` positions.

## Trust and finality model

The runtime fails closed unless it can:

1. anchor the incident under the finalized head and locate the last block at or
   before the claim-window deadline;
2. prove provisional and finalized incident anchors agree;
3. reconstruct registered/cancelled claims in chain order and match on-chain
   claim-set hash plus unresolved count at the exact window boundary;
4. reconcile ERC-20/ERC-1155 replay endpoints with historical contract views;
5. obtain complete logs through bounded ranges, explicit range/result-size
   bisection, and silent-result-cap bisection, failing on an unsplittable single
   block or any request/deadline budget exhaustion;
6. validate oracle answers, timestamps, decimals, conversion returns, pool
   topology, historical balances, and score-spent values at pinned blocks;
7. read the latest submitted root after expensive work, then re-read every
   anchor hash as the final RPC operation before output.

Tokens whose balances cannot be reconstructed from standard Transfer semantics
(for example hidden rebases) fail endpoint reconciliation. The runtime does not
release KMS keys, sign transactions, submit roots, or implement Nitro `vsock`;
the signing boundary must accept only an internally verified Rust artifact and
must independently enforce signer policy.

## TypeScript deletion criteria

Code-side removal readiness is enforced in CI:

- Rust formatting, Clippy, full tests, release build, and RustSec audit pass;
- ABI selectors/topics and EIP-712 vectors match Solidity;
- small, edge-matrix, and 1,000-user real-history fixtures match TypeScript
  byte-for-byte;
- mock-RPC resolver, raw/checkpoint matrices, and atomic artifact checks pass;
- Foundry root/proof/digest/claim-set integration uses Rust by default;
- TypeScript remains a separately executed oracle lane.

Delete the TypeScript runtime only after deployed nonzero Registry,
DefiInsurance, and feed addresses exist; archive-RPC Rust `compute`/`verify`
shadow runs match independent TypeScript runs for production-shaped incidents;
and the KMS/TEE signer plus rollback runbook have been exercised against Rust
artifacts. Until then, TypeScript may be removed from production images but must
remain in CI as the independent oracle. No live/archive run can be claimed from
`config/example.json`.

## Fixture kernel

```bash
target/release/usd8-settlement kernel fixtures/small.json
# Backward compatible:
target/release/usd8-settlement fixtures/small.json
```

Fixture output contains decimal-string rows and pool payouts, `claimSetHash`,
`settlementInputHash`, Merkle root, and all proofs keyed by claim ID.

## Differential parity

The TypeScript harness invokes the real existing `settle()` and `proofsFor()`
with a deterministic in-memory chain client. It does not duplicate production
allocation or Merkle logic.

```bash
node bench/compare.mjs fixtures/small.json
node bench/compare.mjs fixtures/matrix.json

node bench/generate-fixture.mjs 10000 /tmp/usd8-rust-10000.json
node bench/compare.mjs /tmp/usd8-rust-10000.json
```

Validated byte-for-byte at 2, 3, 100, 1,000, and 10,000 claims. Compared fields:
all row values, every pool payout, claim-set hash, settlement-input hash, root,
and every proof.

## Real USDC/USDT history cohort

A second 1,000-claim fixture uses real Ethereum balance history rather than
injected score scalars:

- finalized interval: block `24886575` (2026-04-15 17:01:11 UTC) through
  `25539412` (2026-07-15 17:01:11 UTC), 652,837 blocks;
- USDC (`0xA0b8…eB48`) proxies USD8 at launch rate
  `138888888888889` (approximately 1 score per whole token per 7,200 blocks);
- USDT (`0xdAC1…1ec7`) proxies sUSD8 at rate `13888888888889`
  (approximately 0.1 score per whole token per 7,200 blocks);
- candidate discovery sampled 91 evenly spaced finalized blocks: 18,095
  Transfer logs and 17,341 active addresses;
- addresses were SHA-256-seed ranked, then restricted to 1,000 addresses with
  `eth_getCode(endBlock) == 0x`;
- complete incoming and outgoing USDC/USDT histories were fetched for every
  selected address across the full interval: 717,665 unique USDC logs and
  1,187,480 unique USDT logs;
- all 2,000 replay endpoints matched archive `balanceOf(endBlock)`. Any provider
  timeout/result cap is block-bisected, then topic-OR-bisected at one block; an
  unsplittable query fails closed.

Score math exactly mirrors `earnedScoreOf`: initialize with
`balanceOf(startBlock)`, integrate Transfer-replayed balance over blocks, scale
6 decimals to 18, multiply each proxy rate, sum both numerators, then divide by
`1e18` once. Of 1,000 real active addresses, 966 earned positive three-month
score and 34 earned zero (for example, same-block/no-duration activity).

Claims remain synthetic: deterministic $100–$10,000 loss amounts, zero prior
score spend, zero booster, and `minHeld == escrowAmount`. Candidate discovery is
a reproducible 91-block sample of the global user population; it is **not** a
claim that every globally active USDC/USDT address was enumerated. Histories for
the selected cohort are complete and end-state checked.

```bash
DRPC_KEY="..." python3 bench/collect_real_history.py \
  --start-block 24886575 --end-block 25539412 \
  --cohort-size 1000 --samples 91 --base-range 1000 --workers 3 \
  --history-output real-usdc-usdt-history-2026-04-15_2026-07-15.json \
  --fixture-output fixtures/real-usdc-usdt-1000.json

node bench/compare.mjs fixtures/real-usdc-usdt-1000.json
node bench/run-bench.mjs fixtures/real-usdc-usdt-1000.json 10 7 3
node bench/cold-start.mjs fixtures/real-usdc-usdt-1000.json 7
```

The collector sends `DRPC_KEY` only to the exact `https://lb.drpc.org` or
`https://lb.drpc.live` host on port 443 and refuses redirects. `--rpc-url`
selects an endpoint on those trusted hosts; it cannot redirect the credential
to an arbitrary archive provider.

Real-cohort result on the same Apple M4 host:

| Mode | TypeScript | Rust | Rust speedup |
|---|---:|---:|---:|
| Warm | 513.369 ms | 4.600 ms | 111.6x |
| Cold | 589.670 ms | 11.316 ms | 52.1x |

Peak RSS: TypeScript 108.219 MiB; Rust 6.594 MiB. Complete output parity passed
with root `0x4216cbef89ae8ea2a7b5231d10fb00d68e9a624e71af40ceada40896c54f1eb4`.
Raw provenance, per-user aggregates, checksums, samples, and caveats are in
`real-usdc-usdt-history-2026-04-15_2026-07-15.json` and
`benchmark-real-history-2026-07-15.json`.

## Benchmark methodology

Warm benchmark:

- parses and normalizes the fixture before timing;
- performs warm-up iterations inside each measured process, preserving V8 JIT
  state;
- times allocation, hashes, root, and all proof generation;
- excludes JSON serialization and process startup;
- reports median nanoseconds per iteration;
- checks complete output parity during every benchmark.

```bash
node bench/run-bench.mjs /tmp/usd8-rust-100.json 50 7 10
node bench/run-bench.mjs /tmp/usd8-rust-1000.json 10 7 3
node bench/run-bench.mjs /tmp/usd8-rust-10000.json 3 5 1
```

Cold benchmark includes process startup, fixture parsing, one computation, and
JSON serialization:

```bash
node bench/cold-start.mjs fixtures/small.json 11
node bench/cold-start.mjs /tmp/usd8-rust-100.json 11
node bench/cold-start.mjs /tmp/usd8-rust-1000.json 7
```

### Local result

Apple M4, 10 logical CPUs, 24 GiB RAM, macOS 26.5.2; Node 22.22.3;
Rust 1.91.1 release profile with thin LTO.

| Claims | TypeScript warm | Rust warm | Rust speedup |
|---:|---:|---:|---:|
| 100 | 48.056 ms | 0.292 ms | 164.8x |
| 1,000 | 511.958 ms | 3.426 ms | 149.4x |
| 10,000 | 5,542.554 ms | 41.231 ms | 134.4x |

| Claims | TypeScript cold | Rust cold | Rust speedup |
|---:|---:|---:|---:|
| 2 | 121.102 ms | 2.204 ms | 54.9x |
| 100 | 169.072 ms | 2.990 ms | 56.6x |
| 1,000 | 586.434 ms | 9.429 ms | 62.2x |

Peak RSS from `/usr/bin/time -l`:

| Claims | TypeScript | Rust |
|---:|---:|---:|
| 2 | 74.312 MiB | 1.781 MiB |
| 10,000 | 218.688 MiB | 55.219 MiB |

The measured kernel-only release binary was **622,272 bytes (607.688 KiB)**.
That historical footprint predates the production RPC, ABI, checkpoint, and
orchestration dependencies and must not be presented as the current runtime
binary size. The current production macOS arm64 release is **4,347,712 bytes
(4.146 MiB)**. On the same machine, Node was 107.685 MiB and a clean
production-only `node_modules` tree was 110.984 MiB; container/EIF compression
and Linux linkage will differ.

Raw medians, samples, environment, roots, RSS bytes, and artifact sizes are in
`benchmark-results-2026-07-15.json`.

## Interpretation

Rust is clearly worthwhile for the enclave compute kernel: much lower CPU,
cold-start latency, resident memory, and runtime footprint. The measured
speedup is an implementation/runtime comparison, not a language-only synthetic
microbenchmark: TypeScript uses the current asynchronous `settle()` path while
Rust receives equivalent resolved inputs. Real end-to-end incident time can
still be dominated by RPC and checkpoint advancement.

The production runtime now performs provenance reconstruction itself. Keep
TypeScript as an independent verifier until the deletion criteria above pass.
KMS signing and `vsock` remain separate trust-boundary work; repeat footprint
and end-to-end measurements inside the target Nitro EIF before deployment.
