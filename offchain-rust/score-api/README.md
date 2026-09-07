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

`USD8_SCORE_NETWORKS_JSON` is a server-side allowlist. Each entry must have a unique nonzero `chainId`, nonempty label/RPC URL, and canonical Registry address. Add a mainnet entry only after its Registry is deployed and its RPC endpoint is provisioned. `USD8_SCORE_RPC_URL` and `USD8_REGISTRY` are no longer read by this Lambda.

## Score fields

The public display score is a fixed UTC daily snapshot, separate from claim-score replay. On the first request in a UTC day, the Lambda selects the final block before `00:00:00 UTC` (timestamp at most `23:59:59 UTC` of the preceding day) and replays only from the account's saved checkpoint. It persists that response for the account and returns it unchanged for the rest of the day; its HTTP cache expires at the next UTC epoch. The DynamoDB TTL remains a 180-day cleanup policy, not the freshness policy.

`grossEarnedScore` is the visible total accrued through that daily reference block.
`maturedGrossEarnedScore` is accrued only through `scoreCutoffBlock` (`referenceBlock - minHoldingRequired`). `availableScore` is `max(maturedGrossEarnedScore - scoreSpent, 0)`, so recent score remains visible but cannot be spent before it matures. Claim/settlement code must independently replay the authoritative score and must not use this public snapshot.

The same response also includes `snapshotTimestamp`, `grossScorePerSecond`, and
`maturingScorePerSecond` so the frontend can extrapolate Total and Available Score locally
between daily snapshots without polling. Rates use the protocol's twelve-second block target
and are display estimates only. `tokenScores` contains each configured scored-token address,
its `grossEarnedScore`, and its `grossScorePerSecond`; token earned scores include the
negligible integer-rounding remainder so they sum exactly to the account-wide total. Spent and
Available Score remain account-wide.

## Verify

```bash
cargo +1.94.1 test --manifest-path offchain-rust/score-api/Cargo.toml --features lambda,sepolia --all-targets
```
