# Golden claim-result vectors

## Fixture provenance

- `small.json` and `matrix.json` are **synthetic** runnable kernel inputs.
- `golden-claim-results.json` is a **synthetic, manually derived** economic oracle.
- `real-usdc-usdt-wsteth-300-6m.json` has mixed provenance: its selected-account history is real-derived; its claim amounts and pool balance are synthetic. See `provenance/` for integrity records.

`golden-claim-results.json` is an independent correctness oracle for the Rust off-chain settlement kernel.

The expected values are manually derived from the protocol formulas documented in each vector. They must **not** be generated or updated from the Rust implementation. A behavior change requires reviewing the derivation first and explicitly approving any expected-value change.

The Rust implementation is compared with the fixed expected eligibility, loss, earned/raw/boosted score, per-claim payout, per-pool asset amount, and total pool payout. Merkle hashes are intentionally excluded here: Solidity/Rust FFI tests cover encoding, while these vectors establish economic correctness without treating the implementation as the oracle.
