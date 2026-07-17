# Rust comparison archive

This directory belongs to the temporary TypeScript differential oracle. It contains cross-language parity scripts, historical benchmark results, and migration plans. It is deliberately outside `offchain-rust` so the Rust package remains standalone.

From the repository root:

```bash
cd offchain
npm ci --include=dev
npm run build

cd ../offchain-rust
cargo build --release --locked

cd ../offchain
node rust-comparison/bench/compare.mjs ../offchain-rust/fixtures/small.json
node rust-comparison/bench/compare.mjs ../offchain-rust/fixtures/matrix.json
node rust-comparison/bench/compare.mjs ../offchain-rust/fixtures/real-usdc-usdt-1000.json
```

Deleting the `offchain` directory later removes this comparison archive without affecting any Rust build, test, fixture replay, RPC computation, verification, or attestation command.
