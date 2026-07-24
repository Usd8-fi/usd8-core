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

`cargo audit` ignores four unmaintained-only RustSec notices plus
RUSTSEC-2023-0071, for which no fixed RSA release exists. The RSA exception is
limited to an ephemeral per-request key that performs one KMS-recipient OAEP
decrypt, so it cannot expose the repeated adaptive timing oracle required by
Marvin. Remove it when upstream publishes a fixed stable release; remove the
other exceptions when their pinned dependencies no longer require them.

## Production bootstrap

There is no settlement JSON configuration. Supply one fixed Registry proxy
address through `--registry` or `USD8_REGISTRY`. At the incident `openBlock`, the
runtime derives and validates both directions of the Registry/DefiInsurance
binding, booster policy, pool topology, every pool-asset USD feed, and the global
oracle-staleness limit. The default build is fixed to Ethereum mainnet; the
`sepolia` feature fixes it to chain ID `11155111` for staging.

`MAX_LOG_RANGE = 1000` and `LOG_RESULT_CAP = 1000` are compiled into the measured
runtime because they describe approved RPC behavior rather than protocol state.
The derived state and baked limits are committed in the artifact `configHash`.
Missing feeds, zero policy, unsupported booster policy, wrong chain, wiring
mismatch, or missing historical bytecode fail closed. Version 5 applies only to
incidents opened after these Registry selectors and values exist; rollout must
have no active incident and configure every active pool feed before reopening.

The Registry-only CLI intentionally resolves the currently registered
DefiInsurance. Governance must not rotate that module until all incidents it
owns are closed and their artifacts are archived; reproducing an older rotated
module requires its archived artifact/runtime rather than bare incident ID,
because incident IDs are module-local.

## Compute and verify

Use an archive-capable RPC with historical `eth_call`, `eth_getCode`,
`eth_getLogs`, and `finalized` block support. The attested production release is
pinned to an approved provider verified not to silently cap below the baked
1,000-result threshold; otherwise completeness cannot be inferred from a short
page:

```bash
export ETH_RPC_URL='https://trusted-rpc.example'
export USD8_REGISTRY='0x…'

target/release/usd8-settlement compute 7 \
  --registry "$USD8_REGISTRY" \
  --raw-score \
  --output artifacts/incident-7.json

target/release/usd8-settlement verify 7 \
  --registry "$USD8_REGISTRY" \
  --raw-score

# Inside the Nitro Enclave; fails unless local PCR0-2 match the incident snapshot.
target/release/usd8-settlement attested-compute 7 \
  --registry "$USD8_REGISTRY" \
  --bulk-score \
  --output artifacts/incident-7-attested.json
```

`--rpc-url` overrides `ETH_RPC_URL`. `--output` uses a same-directory temporary
file, `fsync`, atomic rename, directory `fsync`, byte-for-byte read-back, and
JSON read-back. Its parent directory must already exist. Without `--output`, the
artifact is written to stdout. Checkpoint, checkpoint-lock, and output paths are resolved before RPC work and
rejected if writable paths alias.
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

Optional flags are `--timeout-ms <1..=120000>`, `--no-drpc-key` (compute/verify
only), `--checkpoint <path>`, `--checkpoint-key-env <name>`, `--bulk-score`, and
`--raw-score`.
`attested-compute` requires `DRPC_KEY`, which also restricts the URL to the exact
approved dRPC HTTPS hosts.
Raw, bulk, and checkpoint modes are pairwise exclusive. The default checkpoint key
variable is `SCORE_CHECKPOINT_KEY`; `SCORE_CHECKPOINT_PATH` supplies a default
path when neither score-mode flag is present.

Exit codes are stable:

- `0`: compute succeeded, or verify matched;
- `1`: verify mismatch or fatal chain/config/I/O/invariant failure;
- `2`: malformed command-line usage.

The artifact includes schema/config versions, hash, and the full derived
Registry/module/feed/staleness bootstrap preimage anchored at `openBlock`, plus
`teePcrHash`, all four block anchors,
RPC/log metrics, score-source provenance, claim-set and settlement-input
commitments, ordered pools and payouts, root/on-chain root/match flag, EIP-712
digest, canonical score input rows, payout rows, and optional proofs. Before any
output, Rust independently recomputes the claim-set hash, input hash, Merkle
root/proofs, per-pool row totals, and settlement digest. Each payout leaf commits
`scoreSpent` (raw score recorded in the Registry) and `boostedScore` (the
booster-adjusted value used only for allocation). The contract recomputes the
boosted score from the claim's escrowed booster amount before finalizing.

Boosters are escrowed by `joinClaim`; settlement therefore uses the committed
amount directly without replaying ERC-1155 balance history.

## Ephemeral bulk score replay

`--bulk-score` performs one fresh global `Transfer` replay per active scored
token while retaining account state only for the deduplicated users of live
claims. History is processed and dropped in bounded block-range slices, and each
retained token/user balance is reconciled against historical `balanceOf` before
settlement continues. The artifact records `ephemeral-bulk-rpc` provenance,
block/hash, indexed token/transfer counts, and the deduplicated tracked-account
count.

Production `job-api` enclave settlement uses this mode. Every job starts from
chain history inside enclave memory; it has no checkpoint path, HMAC key, lock,
file, parent-provided state, or commit step. Raw mode remains the slower,
independent per-user differential implementation. Checkpoint mode remains an
operator optimization, but a checkpoint supplied by the untrusted parent crosses
the enclave trust boundary even when accompanied by an HMAC key and is therefore
not used by production enclave jobs.

## Authenticated score checkpoint

Raw mode replays score-token history for every requested user. Checkpoint mode
streams each token's global `Transfer` history once and persists authenticated
state:

```bash
export SCORE_CHECKPOINT_PATH="$PWD/state/mainnet-score.json"
export SCORE_CHECKPOINT_KEY="$(openssl rand -base64 48)"

target/release/usd8-settlement compute 7 \
  --registry "$USD8_REGISTRY" \
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
4. reconcile ERC-20 replay endpoints with historical contract views;
5. obtain complete logs through bounded ranges, explicit range/result-size
   bisection, and silent-result-cap bisection, failing on an unsplittable single
   block or any request/deadline budget exhaustion;
6. validate oracle answers, timestamps, decimals, conversion returns, pool
   topology, historical balances, and score-spent values at pinned blocks;
7. read the latest submitted root after expensive work, then re-read every
   anchor hash as the final RPC operation before output.

Tokens whose balances cannot be reconstructed from standard Transfer semantics
(for example hidden rebases) fail endpoint reconciliation. The standalone
runtime does not release keys or sign. The separate measured `job-api` enclave
worker accepts only internally verified `attested-compute` or `attested-open`
output, obtains the signer through attestation-bound KMS recipient decryption,
and signs inside enclave RAM. Plain `compute` remains available for public replay.

## On-demand TEE job API

`job-api/` is a separate Rust package for the public control plane. It keeps AWS
SDK and Lambda dependencies outside the measured `usd8-settlement` dependency
graph:

```bash
cd offchain-rust/job-api
cargo test --locked
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo build --release --locked --features lambda --bin usd8-tee-job-lambda
```

Release inputs are mandatory and strictly validated. Build into a new directory;
the build never mutates checked-in policy templates:

```bash
NETWORK=sepolia REGISTRY=0x... EXPECTED_SIGNER=0x... \
  OUT_DIR=releases/build-<id> deploy/build-release.sh
```

This compiles both the settlement chain ID and dRPC network into the measured
binaries. Use `NETWORK=ethereum` explicitly for mainnet. A caller cannot select
the network.

`job-api/rust-toolchain.toml` pins its independently tested Lambda toolchain.
For deployment, produce a Linux Lambda artifact rather than uploading a macOS
binary:

```bash
cargo lambda build --release --x86-64 --features lambda \
  --bin usd8-tee-job-lambda
```

The deployed flow is intentionally small:

```text
POST /jobs/settlement -> Rust Lambda -> S3 request -> one Nitro-enabled EC2
POST /jobs/open       -> Rust Lambda -> S3 request -> one Nitro-enabled EC2
GET /jobs/<jobId> <- Rust Lambda <- S3 terminal envelope <- enclave
```

There is no idle EC2. Lambda returns `202 Accepted` with a job ID; clients poll
until the status is `completed`, `failed`, or `expired`. The same Lambda Function URL handles
both routes:

```http
POST /jobs/settlement
Idempotency-Key: client-generated-unique-value
Content-Type: application/json

{"incidentId":"7","registry":"0x1111111111111111111111111111111111111111"}
```

`POST /jobs` remains a compatibility alias for `POST /jobs/settlement`.
Incident opening uses a separate typed route on the same Function URL:

```http
POST /jobs/open
Idempotency-Key: client-generated-unique-value
Content-Type: application/json

{"insuredToken":"0x2222222222222222222222222222222222222222","referenceBlock":"1234567"}
```

The enclave reads `nextIncidentId`, Registry/DefiInsurance bindings, token
approval, active-incident state, chain ID, signer authorization, and the current
PCR commitment at one pinned Sepolia block before signing `IncidentOpen`.

```json
{"accepted":true,"jobId":"<64 lowercase hex characters>"}
```

```http
GET /jobs/<jobId>
```

```json
{"jobId":"<jobId>","status":"completed","apiVerified":false,"payload":{}}
```

Settlement accepts only `incidentId` and `registry`; incident opening accepts
only `insuredToken` and `referenceBlock`, with Registry injected from Lambda's
fixed configuration. Unknown fields, numeric rather than canonical
decimal-string IDs, leading zeroes, out-of-range integers, zero/malformed
addresses, and any requested Registry other than the configured one are
rejected before an AWS write. Users cannot supply an RPC URL, AMI,
instance type, subnet, security group, IAM profile, user data, command, S3 key,
or EIF path.

### Idempotency and S3 layout

The 32-byte job ID is:

```text
opaque = HMAC-SHA256(jobSecret,
    "USD8_TEE_JOB_V2\\0" || idempotencyKey || "\\0" || canonicalRequest)[0:16]
commitment = SHA256("USD8_TEE_REQUEST_V1\\0" || canonicalRequest)[0:16]
jobId = hex(opaque || commitment)
```

The HMAC secret is a random deployment secret of at least 32 bytes, supplied to
Lambda as base64. The opaque half keeps job IDs unguessable and binds a caller
retry to the same canonical request. Before RPC or KMS access, the enclave
recomputes the public commitment half from the canonical request, so an
untrusted parent cannot substitute another request under the original job ID.
S3 conditionally creates the request with
`If-None-Match: *`; byte-different collisions fail closed. Every EC2 launch uses
the same 64-character job ID as `RunInstances.ClientToken`, so retrying after a
Lambda timeout cannot create another instance.

```text
requests/<jobId>.json    immutable request plus createdAt/expiresAt
terminal/<jobId>.json    immutable completed-or-failed envelope
```

The worker conditionally creates the single terminal key, so success and failure
cannot race across separate objects. Lambda requires terminal schema version 1,
matching job ID, a `completed` or `failed` discriminator, and an object payload.
Stored-request schema version 2 records the fixed creation time and hard expiry.
If no terminal exists after that deadline, polling returns `expired`; retrying the
same deterministic job does not relaunch it. A caller that intentionally needs a
new computation after expiry must use a new idempotency key. A completed or failed
terminal suppresses relaunch even if its request object must be recreated.
It caps reads at 16 MiB and never returns raw AWS errors. Terminals up to 5 MiB
remain inline. Larger terminals return a five-minute presigned S3 `download`
containing the URL, exact byte length, and SHA-256 of the complete immutable
terminal object. Clients download that object, verify its byte hash, then verify
the signature and attestation before use. Responses remain
`apiVerified:false`: Lambda performs structural validation only.

### Lambda configuration

Required environment variables:

```text
USD8_REGISTRY
USD8_JOB_BUCKET
USD8_JOB_HMAC_KEY_B64
USD8_TEE_AMI_ID
USD8_TEE_INSTANCE_TYPE
USD8_TEE_INSTANCE_PROFILE
USD8_TEE_SUBNET_ID
USD8_TEE_SECURITY_GROUP_ID
AWS_REGION
```

`USD8_TEE_MAX_AGE_SECONDS` is optional and defaults to `1800`; configure the
same value on the API and janitor Lambdas. It must be between 300 and 86,400.

Use a Function URL with `AWS_IAM` authorization for beta. Do **not** expose it
with `NONE` authorization: an unauthenticated caller could otherwise create unbounded EC2
cost. Permissionless production access needs an economic anti-abuse mechanism
(on-chain authorization/bond/payment) or an API layer with enforceable quotas.
Set Lambda reserved concurrency and EC2 service quotas as secondary blast-radius
limits. Treat jobs/results as non-confidential shared beta data unless caller
identity is added to the HMAC preimage and authorization checks; IAM invocation
alone does not create per-tenant ownership.

Enforce separate policies. Lambda needs only:

- conditional `s3:PutObject` under `requests/` and `s3:GetObject` under
  `requests/` plus `terminal/`; it must not write terminal state;
- `ec2:RunInstances` restricted to the approved AMI, subnet, security group,
  instance profile and instance type;
- `iam:PassRole` for only the TEE instance role;
- tag-on-create permission requiring `Project=USD8-TEE`.

The janitor uses a distinct execution role with only its own logs,
`ec2:DescribeInstances`, and tag-conditioned `ec2:TerminateInstances`. It has no
S3, launch, tagging, or pass-role permission. Finalization therefore requires
both `LAMBDA_ROLE`/`LAMBDA_POLICY_NAME` and
`JANITOR_ROLE`/`JANITOR_POLICY_NAME`; the live verifier rejects shared roles.

The instance role may read only its request and immutable release artifacts and
conditionally write only `terminal/`. Bucket policy must deny overwrites and
deny Lambda writes to `terminal/`. These are deployment requirements; this Rust
package cannot enforce an AWS account policy by itself.

The launcher always requests one instance, enables Nitro Enclaves, assigns a
public IP for KMS/archive-RPC egress, requires IMDSv2, sets metadata hop limit 1,
disables instance tags in metadata, and configures instance-initiated shutdown
to **terminate**. The reviewed AMI must
have an encrypted root mapping with `DeleteOnTermination=true`; verify that
mapping during release because the launcher does not override the AMI root
device. The security group must have no inbound rules. The enclave itself can
reach only the fixed parent vsock proxies for KMS and the build-pinned dRPC host
(`lb.drpc.org` on mainnet or `lb.drpc.live` on Sepolia); it cannot
use the parent network directly. A private subnet with S3/KMS endpoints and a
controlled RPC egress proxy may replace the public IP later, but is not required
for the minimal deployment.

### Immutable AMI/EIF contract

`USD8_TEE_AMI_ID` must identify a prebuilt encrypted AMI; Lambda does not build
code at request time. The AMI contains the versioned EIF, its SHA-256 manifest,
Nitro allocator configuration, parent runner, `nitro-cli`, and a disabled
`usd8-tee-job.service`. User data contains only validated `jobId`, bucket and
region values in `/run/usd8/job.env`, then starts that fixed service. It contains
no shell command, URL, credentials or EIF path supplied by the caller.

Fail the release before updating Lambda unless the exact AMI is private,
available, encrypted, and delete-on-termination:

```bash
AWS_REGION=eu-central-1 job-api/deploy/verify-ami.sh "$USD8_TEE_AMI_ID"
```

For each release:

1. build `usd8-settlement` from `Cargo.lock` on the pinned Linux toolchain;
2. build a non-debug EIF and record its SHA-256 plus PCR0/PCR1/PCR2;
3. test the exact EIF on temporary Nitro hardware;
4. bake the exact EIF and parent runner into an encrypted AMI;
5. run `deploy/finalize-release.sh <build-dir> <final-dir>` with explicit AMI,
   Lambda, KMS and IAM inputs; it binds all artifacts, policies and expected AWS
   configuration into one read-only manifest;
6. update KMS, IAM, Lambda and the on-chain PCR commitment only from that final
   bundle;
7. run `deploy/verify-release.py <final-dir>/release-manifest.json --live` and
   fail the deployment unless the live AMI, Lambda code/configuration, Function
   URL authorization, KMS policy and IAM policies exactly match the manifest.

Rebuild only when measured code or dependencies change. AMI snapshot and private
S3 artifact storage remain while all compute is terminated.

### Enclave and signing boundary

The parent EC2 is untrusted orchestration. It may fetch the immutable request and
EIF, start the enclave, proxy allowlisted network traffic, upload the returned
envelope, and shut down. It must not receive plaintext signer material or decide
what digest is signed.

Inside the enclave, the production worker must:

1. run `attested-compute` against the configured Registry and approved archive
   provider;
2. independently verify the complete artifact and PCR snapshot;
3. ask KMS to decrypt the persisted secp256k1 signer ciphertext using a Nitro
   attestation recipient;
4. sign only the verified EIP-712 settlement digest;
5. zeroize the private key and return artifact, signature, signer address and
   attestation as one terminal envelope.

KMS `Decrypt` must be granted only to the EC2 instance role **with**
`kms:RecipientAttestation:ImageSha384` or PCR conditions for the reviewed EIF.
The parent role must not have ordinary plaintext `kms:Decrypt`. The stable signer
address is derived from the KMS-wrapped key and must match the Registry signer.

The Rust `job-api` implements the Lambda/S3/EC2 control plane, one-shot parent,
bounded vsock protocol, fixed KMS/RPC proxies, Nitro NSM recipient attestation,
KMS decryption, enclave-local settlement verification and secp256k1 signing.
`job-api/deploy/` contains the pinned EIF build, AMI service, measured KMS policy
and least-privilege role policies. A release is accepted only after the exact
EIF measurements, signer address and AMI are deployed and independently checked.

### Termination and recovery

The AMI service uploads one bounded redacted terminal envelope on success or
failure and powers off through systemd success/failure actions.
`instance-initiated-shutdown-behavior=terminate` removes the instance; the reviewed AMI root mapping must remove its
volume as described above. Deploy the included `usd8-tee-janitor` Lambda on a schedule to terminate tagged
instances older than the hard job deadline; self-termination alone cannot cover
kernel panic, AWS control-plane failure or a wedged parent. S3 lifecycle rules should expire
terminal envelopes after 30 days and requests after 31 days, so a later-created
terminal cannot outlive the immutable request that identifies it.

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
