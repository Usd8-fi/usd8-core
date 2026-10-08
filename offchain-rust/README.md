# USD8 off-chain Rust runtime

This directory provides a local CLI and **three AWS Lambda executables** for
insurance scores, opening/settlement job orchestration, and worker cleanup.
They share Rust calculation code but have different entrypoints and trust
boundaries. Settlement
reconstructs finalized history, computes payouts, and builds Merkle commitments
and EIP-712 digests; the cloud worker adds enclave-local signing.

## Three Lambdas and the local CLI

| Executable | Entrypoint | Role |
| --- | --- | --- |
| `usd8-score-lambda` | [score-api/src/bin/lambda.rs](score-api/src/bin/lambda.rs) | Public read-only display scores, backed by DynamoDB. |
| `usd8-tee-job-lambda` | [job-api/src/bin/lambda.rs](job-api/src/bin/lambda.rs) | Opening/settlement prechecks, job admission, EC2 launch, polling and result retrieval. |
| `usd8-tee-janitor` | [job-api/src/bin/janitor.rs](job-api/src/bin/janitor.rs) | Scheduled cleanup of expired tagged EC2 workers. |
| `usd8-settlement` | [src/main.rs](src/main.rs) | Local historical score, price-drop and settlement computation; optional Nitro attestation. |

The score and job Lambdas use the HTTP runtime. The janitor consumes native
scheduled Lambda events, not HTTP requests. Their opt-in Cargo features are
`lambda` in [score-api/Cargo.toml](score-api/Cargo.toml), and `lambda` / `janitor`
in [job-api/Cargo.toml](job-api/Cargo.toml), respectively.

```text
HTTP client -> API Gateway -> score Lambda -> DynamoDB display cache
                          -> job Lambda   -> S3 requests/results
                                          -> EC2 parent -> Nitro enclave
Schedule ------------------> janitor Lambda -> terminate expired EC2 workers
Local CLI ---------------------------------> historical Ethereum RPC
```

[`usd8-tee-parent`](job-api/src/bin/parent.rs) and
[`usd8-tee-enclave`](job-api/src/bin/enclave.rs) are **EC2/Nitro worker binaries,
not additional Lambdas**. The parent starts the enclave and handles transport;
the enclave calls the shared library directly, not the CLI subprocess.

### Public score service

The score Lambda supports `GET /score/{chainId}/{account}` and a legacy
`GET /score/{account}` route. API Gateway exposes the routes selected for each
deployment. The service serves an allowlisted network's display snapshot.
Ordinary requests use the final block before the current UTC day and reuse the
DynamoDB snapshot for that day. `?refresh=1` may replace it with a finalized
intraday snapshot after the five-minute successful-refresh cooldown. Replay
leases and a shared work budget bound expensive refresh work.

Display `grossEarnedScore` includes unmatured earnings; `maturedGrossEarnedScore`
and `availableScore` distinguish what can be spent. This is **not the local CLI's
score schema** and is never an authoritative settlement input. See the
[score service README](score-api/README.md) for caching, fields and operations.

### Opening and settlement job service

- `POST /jobs/open`: body `{"insuredToken":"0x..."}`.
- `POST /jobs/settlement`: body `{"incidentId":"7","registry":"0x..."}`.
- Both require an `Idempotency-Key` header. Accepted submissions return HTTP
  `202` and a job ID; poll `GET /jobs/{jobId}` for completion, failure or expiry.
- Published settlement artifacts are addressable through
  `GET /settlements/{chainId}/{registry}/{defiInsurance}/{incidentId}/{root}`.

The server fixes the network, Registry, RPC and worker configuration. Prechecks
and durable admission run before new worker launches. Canonical settlement work
reuses an active attempt or verified completion across caller retry keys;
opening submissions share work for the selected token/reference block.

The [opening advisory cache](job-api/src/open_advisory_cache.rs) is fresh for
60 seconds and retains a snapshot for up to 3,600 seconds. Stale results are
**display-only** and cannot authorize a launch; even fresh qualifying results
are only admission evidence, not an on-chain opening authorization. The enclave
independently rebuilds and checks the opening artifact before signing.

Admission bounds worker starts; API Gateway throttles and Lambda concurrency
are deployment settings, not protocol constants. The janitor is a scheduled
backstop for workers that fail to terminate themselves. For exact release,
IAM/KMS and deployment requirements, use the
[release gates](job-api/deploy/RELEASE-GATES.md), not this overview as a runbook.

## Build the local CLI

Run from `offchain-rust/` with Rust and a native compiler/linker installed.
[Cargo.toml](Cargo.toml) declares Rust 1.92 minimum for the core package; the API
packages require 1.94.1. These examples use the locally tested 1.94.1 toolchain.
No Foundry, JavaScript runtime or AWS account is needed for ordinary local runs.

```bash
cargo +1.94.1 build --locked --release --bin usd8-settlement
target/release/usd8-settlement --help
```

Choose the build target, Registry and RPC for the same Ethereum network. The
CLI targets mainnet by default; `--features sepolia` selects the optional testnet
build. Changing the RPC URL alone does not change the compiled chain.

Set the deployment's **Registry proxy** and an archive-capable RPC, then set
`USER_ADDRESS`, `INSURED_TOKEN` and `INCIDENT_ID` to the values you want to query:

```bash
export USD8_REGISTRY='0xYOUR_REGISTRY_PROXY_ADDRESS'
export ETH_RPC_URL='https://YOUR_ARCHIVE_RPC_ENDPOINT'
```

The provider must support historical calls/code, complete logs and `finalized`
blocks. Local runs need no signing key or operator credentials; the RPC provider
may have its own access requirements. `--no-drpc-key` prevents an inherited dRPC
key from being attached. Approved dRPC endpoints can instead use `DRPC_KEY` from
the environment; never put secrets in command arguments or committed files.

## Four common CLI operations

### Historical insurance score for a wallet

```bash
target/release/usd8-settlement compute_insurance_score "$USER_ADDRESS" \
  --registry "$USD8_REGISTRY" --rpc-url "$ETH_RPC_URL" --no-drpc-key
```

Pins a finalized reference block and replays history to the holding-maturation
cutoff. In this CLI result, `grossEarnedScore` means **matured gross score at the
cutoff**, not total earnings including unmatured score. `scoreSpent` is read at
the reference block; `availableScore = max(grossEarnedScore - scoreSpent, 0)`.
Amounts are exact decimal integer strings in 18-decimal score units. Reference
and cutoff block hashes are returned and rechecked; replay errors are not zero
balances. See [src/score.rs](src/score.rs).

### Price-drop and opening-eligibility precheck

```bash
target/release/usd8-settlement detect_price_drop "$INSURED_TOKEN" \
  --registry "$USD8_REGISTRY" --rpc-url "$ETH_RPC_URL" --no-drpc-key
```

Runs the shared [opening precheck](src/incident_open.rs), returning the selected
reference/observation blocks and baseline/distress conversion-ratio TWAPs.
A missing qualifying drop, ineligible state or failed history read is an error.
This advisory query does not start Nitro, sign, open an incident or guarantee
that eligibility will still hold later.

### Local settlement replication

```bash
target/release/usd8-settlement compute_settlement "$INCIDENT_ID" \
  --registry "$USD8_REGISTRY" --rpc-url "$ETH_RPC_URL" --no-drpc-key \
  --raw-score --output settlement.json
```

After the claim window closes and required blocks finalize, reconstructs claims,
eligibility, scores and payouts, returning the root, digest and per-claim proofs.
It does not download or compare a separate TEE result. The shared engine still
rejects a mismatch with a nonzero standing on-chain root and verifies its own
artifact commitments before output. Success alone does not prove a root has
been published. Use the matching source release, chain, Registry and module
when reproducing an existing result; incident IDs are module-local.

`--raw-score` replays per claimant; `--bulk-score` performs fresh shared replay
and is used by production enclave jobs. Neither uses a saved score checkpoint.

### Attest inside an already-running Nitro enclave

```bash
target/release/usd8-settlement compute_settlement_tee "$INCIDENT_ID" \
  --registry "$USD8_REGISTRY" --rpc-url "$ETH_RPC_URL" --bulk-score \
  --output settlement-attested.json
```

Requires a Linux build with `--features nitro`, a running Nitro enclave and
`DRPC_KEY` for the approved dRPC endpoint. It computes and internally verifies
the settlement, omits per-claim proofs, and requests fresh NSM attestation bound
to the digest. Measured PCR0–2 must match the incident's stored commitment.
It **does not launch a worker, release a signer key or make an ECDSA signature**.
Those are separate cloud-worker responsibilities.

The fifth public command, `pcr-hash <PCR0> <PCR1> <PCR2>`, computes the measurement
commitment from three 48-byte PCR hex values. See `--help` for the public surface.
JSON goes to stdout unless `--output` is supplied; its parent directory must
exist. Exit codes are `0` for success, `1` for runtime failure and `2` for usage
errors. Score and price-drop queries never persist score checkpoints.

## Security boundaries and checks

- Internal [artifact verification](src/artifact.rs) remains mandatory. Removing
  an old public command does not remove commitment, proof or invariant checks.
- RPC history completeness remains a trust assumption despite reconciliation
  and finality checks. An independent archive provider strengthens replication.
- The untrusted parent must never receive plaintext signer material. The measured
  enclave obtains it through attestation-bound KMS decryption and signs in RAM.
- Local replication, a download hash and `apiVerified:false` are not full remote
  attestation verification. Consumers still need signature/authorized-signer,
  AWS certificate-chain, freshness, PCR and digest-binding checks; contract
  acceptance checks remain separate. Privileged contract emergency paths are
  outside the permissionless job API's guarantees.

Basic host tests (not a Linux/Nitro release or deployment proof):

```bash
cargo +1.94.1 test --locked
cargo +1.94.1 test --locked --manifest-path job-api/Cargo.toml
cargo +1.94.1 test --locked --manifest-path score-api/Cargo.toml
```

Optional `usd8-ffi` and `usd8-kernel` test tools are default-off behind
`ffi-tools` and `kernel-tools` in [Cargo.toml](Cargo.toml); see
[fixture provenance](fixtures/README.md). They are not production CLI modes.
