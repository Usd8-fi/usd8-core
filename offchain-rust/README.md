# USD8 Rust settlement runtime

Rust is the complete production settlement path. It performs finalized Ethereum
reads, event replay, historical eligibility and score reconstruction, pool/oracle
valuation, allocation, commitments, OpenZeppelin-compatible Merkle proofs, and
EIP-712 digest construction. The package builds, tests, and runs independently
with only the pinned Cargo dependency graph. The fixture kernel remains available
for deterministic replay and public verification.

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

`cargo audit` ignores four unmaintained-only RustSec notices in
`.cargo/audit.toml`: one Linux-only dependency of AWS NSM API 0.4.0, one
unreachable optional Alloy lock dependency, and two compile-time dependencies
of the latest Alloy release. Vulnerabilities remain denied. Remove the NSM
exception when the pinned toolchain can use NSM API 0.5.x; remove the others
when Alloy removes those dependencies.

## Production configuration

Copy `config/example.json`, then replace every example address with the deployed
address for the selected chain. The exact, unknown-field-denying schema is:

- `version`: currently `4.8.0`;
- `chainId`, deployed `registry`, and deployed `defiInsurance`;
- decimal strings `boosterId` (`1`) and `boosterBoostBps` (`100`);
- `assetUsdFeed`: lowercase pool-asset address keys to nonzero Chainlink-style
  feed addresses, covering every active pool asset;
- positive decimal string `maxOracleStaleness`, `maxLogRange` in `1..=2048`,
  and `logResultCap` in `1..=10000`.

The runtime records the canonical `configHash` in the artifact; it is not part
of the on-chain settlement digest. It rejects zero/duplicate contracts, unsupported policy
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

# Inside the Nitro Enclave; fails unless local PCR0-2 match the incident snapshot.
target/release/usd8-settlement attested-compute 7 \
  --config config/mainnet.json \
  --raw-score \
  --output artifacts/incident-7-attested.json
```

`--rpc-url` overrides `ETH_RPC_URL`. `--output` uses a same-directory temporary
file, `fsync`, atomic rename, directory `fsync`, byte-for-byte read-back, and
JSON read-back. Its parent directory must already exist. Without `--output`, the
artifact is written to stdout. Config, checkpoint, checkpoint-lock, and output
paths are resolved before RPC work and rejected if any writable paths alias.
`compute` includes each proof; `verify` omits proofs and compares the reproduced
root with the latest on-chain root. `attested-compute` additionally requests a fresh nonce-bound NSM attestation,
binds the 32-byte EIP-712 settlement digest into the attestation `user_data`,
parses locked SHA-384 PCR0/PCR1/PCR2, and
requires this canonical commitment to equal DefiInsurance's incident-open snapshot:

```text
keccak256("USD8_TEE_PCR0_2_V1" || PCR0 || PCR1 || PCR2)
```

It fails outside a Nitro Enclave or on any mismatch. Its artifact includes the
raw COSE attestation document, `nitroAttestedDigest`, and measured commitment for
independent AWS certificate-chain, signature, nonce, `user_data`, and PCR validation.

Optional flags are `--timeout-ms <1..=120000>`, `--no-drpc-key`,
`--checkpoint <path>`, `--checkpoint-key-env <name>`, and `--raw-score`.
Checkpoint and raw modes are mutually exclusive. The default checkpoint key
variable is `SCORE_CHECKPOINT_KEY`; `SCORE_CHECKPOINT_PATH` supplies a default
path when neither score-mode flag is present.

Exit codes are stable:

- `0`: compute succeeded, or verify matched;
- `1`: verify mismatch or fatal chain/config/I/O/invariant failure;
- `2`: malformed command-line usage.

The artifact includes schema/config versions and hash, `teePcrHash`, all four block anchors,
RPC/log metrics, score-source provenance, claim-set and settlement-input
commitments, ordered pools and payouts, root/on-chain root/match flag, EIP-712
digest, canonical score input rows, payout rows, and optional proofs. Before any
output, Rust independently recomputes the claim-set hash, input hash, Merkle
root/proofs, per-pool row totals, and settlement digest. Each payout leaf commits
`scoreSpent` (raw score recorded in the Registry), `boosterAmountUsed` (the
historically eligible committed units), and `boostedScore` (the booster-adjusted
value used only for allocation). The contract caps the used units to the claim's
commitment and recomputes the boosted score before finalizing.

Booster holding eligibility is block-boundary based: it starts from the
end-of-block state of the filing block and continues through `windowEnd`.

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
must independently enforce signer policy. Production signing must consume only
`attested-compute` output; plain `compute` remains available for public replay.

## Standalone package guarantee

`offchain-rust` is self-contained:

- production commands invoke only the Rust binary;
- `Cargo.toml` has no path dependency outside this directory;
- Rust tests and fixtures run from a standalone copy of this directory;
- no JavaScript runtime, package manager, generated distribution, or sibling
  implementation is required to build, test, compute, verify, or attest.

The repository may run external differential checks elsewhere, but those checks
consume the Rust binary as a black box and are not part of this package.

## Fixture kernel

```bash
target/release/usd8-settlement kernel fixtures/small.json
# Backward compatible:
target/release/usd8-settlement fixtures/small.json
```

Fixture output contains decimal-string rows and pool payouts, `claimSetHash`,
`settlementInputHash`, Merkle root, and all proofs keyed by claim ID.

## Real-history fixture

`fixtures/real-usdc-usdt-1000.json` is a frozen 1,000-claim workload derived from
complete selected-account USDC/USDT transfer histories over Ethereum blocks
`24886575..25539412`. Every selected account's reconstructed end balance was
checked against archive `balanceOf` state. Claims and loss amounts are synthetic;
the selected balance histories and score integrals are real-derived.

To regenerate the dataset with the standalone Python collector:

```bash
DRPC_KEY="..." python3 bench/collect_real_history.py \
  --start-block 24886575 --end-block 25539412 \
  --cohort-size 1000 --samples 91 --base-range 1000 --workers 3 \
  --history-output real-usdc-usdt-history-2026-04-15_2026-07-15.json \
  --fixture-output fixtures/real-usdc-usdt-1000.json
```

The collector sends `DRPC_KEY` only to the exact `https://lb.drpc.org` or
`https://lb.drpc.live` host on port 443 and refuses redirects.
