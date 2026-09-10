# Public score Lambda

`usd8-score-lambda` is a read-only, allowlisted score service. It is separate from the attested settlement runtime and never selects a chain, RPC URL, or Registry from an HTTP request.

## Route

```text
GET /score/{chainId}/{account}
```

The Lambda returns `404 {"error":"UNSUPPORTED_CHAIN"}` before any RPC request when `chainId` is not in its startup configuration. DynamoDB checkpoint keys contain `chainId`, Registry, and account.

## Required environment

```text
AWS_REGION=eu-central-1
USD8_SCORE_TABLE=<checkpoint-table>
USD8_ALLOWED_ORIGIN=https://usd8.fi
USD8_SCORE_NETWORKS_JSON=[{"chainId":11155111,"name":"sepolia","registry":"0xe2a18c8327e684f66cb5532a11e7dd4a26776f87","rpcUrl":"https://rpc.sepolia.ethpandaops.io"}]
```

`USD8_SCORE_NETWORKS_JSON` is a server-side allowlist. Each entry must have a unique nonzero `chainId`, nonempty label/RPC URL, and canonical Registry address. Add a mainnet entry only after its Registry is deployed and its RPC endpoint is provisioned. `USD8_SCORE_RPC_URL` and `USD8_REGISTRY` remain the legacy single-Sepolia fallback when the JSON allowlist is absent.

## Score fields

The public display score ordinarily uses a fixed UTC daily snapshot, separate from claim-score replay. On the first ordinary request in a UTC day, the Lambda selects the final block before `00:00:00 UTC` (timestamp at most `23:59:59 UTC` of the preceding day) and replays only from the account's saved checkpoint. It persists that response for the account and returns it unchanged for the rest of the day, subject to the retained [forced-refresh exception](#retained-forced-refresh-exception-orch-04); its HTTP cache expires at the next UTC epoch. The DynamoDB TTL remains a 180-day cleanup policy, not the freshness policy.

`grossEarnedScore` is the visible total accrued through that daily reference block.
`maturedGrossEarnedScore` is accrued only through `scoreCutoffBlock` (`referenceBlock - minHoldingRequired`). `availableScore` is `max(maturedGrossEarnedScore - scoreSpent, 0)`, so recent score remains visible but cannot be spent before it matures. Claim/settlement code must independently replay the authoritative score and must not use this public snapshot.

The same response also includes `snapshotTimestamp`, `grossScorePerSecond`, and
`maturingScorePerSecond` so the frontend can extrapolate Total and Available Score locally
between daily snapshots without polling. Rates use the protocol's twelve-second block target
and are display estimates only. `tokenScores` contains each configured scored-token address,
its `grossEarnedScore`, and its `grossScorePerSecond`; token earned scores include the
negligible integer-rounding remainder so they sum exactly to the account-wide total. Spent and
Available Score remain account-wide.

## Replay admission and deployment requirements (F-03)

Public GET access is unchanged. A current-schema snapshot for the wall-clock UTC day is
served by a strongly consistent DynamoDB read **without RPC or work-budget writes**.
For uncached/stale/eligible forced refreshes, the runtime conditionally updates the
account row before any reference lookup or historical RPC. The key is the existing
trusted `chainId#Registry#account`; `snapshotGeneration` binds the target UTC epoch.
The same row excludes overlapping work even across epoch changes. Acquisition checks
the loaded checkpoint version, increments `generation`, and reserves `leaseUntil`,
`attemptedAt`, and `retryAfter`. Metadata-only rows are valid cold checkpoints.

Checkpoint commit is a **single conditional UpdateItem** on that row: matching lease
generation, matching snapshot generation, and expected checkpoint version are required
atomically with payload replacement. Expiry is checked against the client timestamp
captured at save construction (`leaseUntil > :now`), not DynamoDB's wall clock at commit.
A still-current in-flight write constructed before expiry may complete after expiry or
application timeout, but cannot overwrite a newer generation/version. There is no
lease-read then write TOCTOU and no second replay on a lost CAS; a rejected save's computed
value is not returned as fresh. No DynamoDB transactions, deletes, scan, or separate lease
table are needed.

A failed, cancelled, or budget-denied attempt deliberately keeps its initial reservation
unless an already in-flight save succeeds as described above.
It becomes retryable at `attemptedAt + leaseSeconds + failureCooldownSeconds`, including
when a Lambda dies before recording failure. Successful commit clears the reservation;
the existing five-minute successful forced-refresh cooldown remains. Expiration checks
are conditional expressions, **not DynamoDB TTL timing**. Account metadata uses the
existing 180-day cleanup retention; do not manually delete active rows/reset generations.

Concurrent refreshes return the latest compatible snapshot with `cacheStatus: updating`
and zero cache lifetime, or `503 SCORE_UNAVAILABLE`, `Cache-Control: no-store`, and
`Retry-After: 60` when no snapshot exists. Aggregate denial can return `work-throttled`.
Clients should back off with jitter; 60 seconds is retry guidance, not a promise that a
custom longer cooldown or global window has ended. A lagging finalized head at midnight
returns the old snapshot/updating or retry rather than computing under the wrong epoch.

All invocations, addresses, chains, and Registries using **the same table** share the
atomic `work-budget#<UTC window number>` counter. Every admitted calculation (not just
cold addresses) consumes a token; errors never refund it. Fixed windows permit up to
`budgetMaxAttempts` starts per window, up to twice that at a boundary, not an exact
rolling-window or concurrent-worker cap. Since the total deadline is below the window,
the default bounds are 10 starts/minute and at most 20 overlapping starts near a boundary.
Tokens cover the initial replay plus its one existing invalid-checkpoint fallback, both
inside the same total deadline. Independent tables have independent budgets. This bounds
historical work, not public HTTP/DynamoDB read or denied-admission traffic; retain API
Gateway throttles and Lambda reserved concurrency as additional operational controls.

Optional operator policy (omission uses exactly these defaults; malformed/unsafe values
fail startup; if supplied, all fields are required):

```text
USD8_SCORE_WORK_POLICY_JSON={"calculationTimeoutMs":20000,"leaseSeconds":30,"failureCooldownSeconds":30,"budgetWindowSeconds":60,"budgetMaxAttempts":10}
```

Validation: timeout 1–25000 ms; lease 1–300 s and at least ceil(timeout/1000)+5 s;
failure cooldown 1–3600 s; window at least the lease and at most 86400 s; attempts 1–1000.
The Tokio total timeout encloses cache reads, admission, all RPC retries/reference lookups,
both replay paths, and commit; it does not reset per chunk or fallback. As with Tokio
timeouts generally, cancellation is cooperative at async yield points; configure the
Lambda platform timeout as the independent hard process backstop. Do not detach replay
tasks. Default deployment: Lambda timeout **25 seconds**, application deadline **20 seconds**,
lease **30 seconds**. For custom policy keep `ceil(app timeout/1000) < Lambda timeout < lease`.
The lease's extra margin protects normal response/clock overhead; Lambda clocks must be
synchronized. Budget entries have a one-day cleanup TTL and are never reset early by code.

**Required rollout, not performed by this change:**

1. Quiesce the old Lambda/alias, including every URL/route that can invoke old code, and
   let all old invocations finish. Old PutItem writers do not know about leases and must
   never overlap the new writer. No checkpoint migration/clear is needed.
2. On `USD8ScoreLambdaRole`, grant `dynamodb:GetItem` and `dynamodb:UpdateItem` on only
   `arn:aws:dynamodb:eu-central-1:919437049909:table/usd8-score-checkpoints-sepolia` using
   `deploy/score-runtime-policy.json`. The final policy removes `PutItem`; no `DeleteItem`
   or `TransactWriteItems` is required. Table partition key remains string `pk`, TTL
   attribute `expiresAt`; existing log permissions are unchanged.
3. Deploy the reviewed Linux binary, set/verify the policy and Lambda timeout, and route
   all traffic exclusively to it. Keep identical policy across all instances sharing the
   table. Changing budget-window length requires quiescence through the longer old/new
   window so mixed revisions cannot create separate effective budgets.
4. Verify IAM, environment, alias/version, timeout, TTL, concurrency and API throttles by
   read-back. Smoke-test concurrent same-account and distinct-account cold traffic, failed
   replay recovery, cache hits, and public retry responses before restoring normal traffic.

### Retained forced-refresh exception (ORCH-04)

Daily reference-block selection and forced-refresh persistence are otherwise unchanged.
**Separate ORCH-04 observation:** `?refresh=1` still updates the same daily row at the
finalized intraday head after successful-refresh cooldown; therefore it can replace the
ordinary daily baseline. This F-03 change does not fix or silently redefine that behavior.
Signing/settlement bulk replay remains independent of this advisory cache.

## Verify

The runtime tests compile on macOS and Linux (no production cfg exclusion). The ignored
DynamoDB tests execute the real AWS SDK conditional operations against a local DynamoDB
emulator, not an in-memory lease abstraction. They are opt-in to prevent accidental AWS
access, and require an explicit loopback endpoint. The runtime tests need no additional
Rust dependency. The reviewed lockfile separately updates `h2` from `0.4.15` to `0.4.16`;
compare the final lockfile diff when reviewing release documentation.

```bash
cargo +1.94.1 test --locked --manifest-path offchain-rust/score-api/Cargo.toml --features lambda,sepolia --all-targets
```

For the local conditional-operation suite, install/run an emulator outside the repository
(in one terminal), then invoke tests in another:

```bash
npm install --prefix /tmp/usd8-f03-dynamodb dynalite@4.0.0
node -e 'require("/tmp/usd8-f03-dynamodb/node_modules/dynalite")({createTableMs:0}).listen(18473,"127.0.0.1")'
```

```bash
USD8_TEST_DYNAMODB_ENDPOINT=http://127.0.0.1:18473 cargo +1.94.1 test --locked --manifest-path offchain-rust/score-api/Cargo.toml --features lambda,sepolia --all-targets -- --include-ignored
cargo +1.94.1 clippy --locked --manifest-path offchain-rust/score-api/Cargo.toml --features lambda,sepolia --all-targets -- -D warnings
cargo +1.94.1 zigbuild --locked --manifest-path offchain-rust/score-api/Cargo.toml --features lambda,sepolia --bin usd8-score-lambda --target x86_64-unknown-linux-gnu
```

The emulator uses only explicit dummy credentials and process/sequence-isolated test tables. It
proves SDK expression/conditional-update behavior locally; it is not a live AWS IAM,
TTL, capacity, deployment, or provider replay-load test. Stop the emulator after testing.
