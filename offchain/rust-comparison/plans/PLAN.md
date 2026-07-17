# Rust Settlement Kernel Comparison Plan

**Goal:** Build an independent Rust implementation of USD8's deterministic off-chain settlement kernel and benchmark it fairly against the current TypeScript authority.

**Scope:** Resolved claim inputs → eligibility/loss/score math → capped geometric allocation → pool split → rolling claim-set hash → canonical input hash → OZ StandardMerkleTree-compatible root/proofs. RPC acquisition, finality lookup, and persistent checkpoint I/O remain outside this CPU benchmark.

**Acceptance gates:**

1. Rust tests begin from TypeScript golden vectors and fail before implementation.
2. Rust and TypeScript consume the same frozen fixture and emit byte-identical rows, pool payouts, claim-set hash, input hash, root, and every proof.
3. Benchmark separates warm in-process compute, cold CLI startup, peak RSS, and artifact/runtime size.
4. Existing TypeScript, FFI, and Forge tests remain green.
5. Current TypeScript production source is not refactored for the benchmark.

**Implementation order:**

1. Golden-vector tests for allocation, hashes, Merkle/proofs, and duplicate rejection.
2. BigUint-based arithmetic and exact ABI/Keccak helpers.
3. OZ-compatible complete binary tree and bulk proofs.
4. JSON CLI and shared deterministic fixture generator.
5. Differential parity runner and benchmark harness.
6. Release build, measurements, regression checks, and verdict.
