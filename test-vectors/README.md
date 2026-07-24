# Golden claim-result vectors

`golden-claim-results.json` is an independent correctness oracle for the off-chain settlement kernels.

The expected values are manually derived from the protocol formulas documented in each vector. They must **not** be generated or updated from either the TypeScript or Rust implementation. A behavior change requires reviewing the derivation first and explicitly approving any expected-value change.

Both implementations consume the same inputs and are separately compared with the fixed expected eligibility, loss, earned/raw/boosted score, per-claim payout, per-pool asset amount, and total pool payout. Merkle hashes are intentionally excluded here: implementation parity and ABI tests cover encoding, while these vectors establish economic correctness without treating either implementation as the oracle.
