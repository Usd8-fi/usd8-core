# Dependency audit exceptions

The operator explicitly approved these maintenance-warning exceptions during F-01–F-07 remediation:

| Advisory | Package | Reason |
|---|---|---|
| RUSTSEC-2021-0127 | serde_cbor 0.11.2 | Retain official AWS NSM SDK 0.5.2, whose latest inspected release still requires this unmaintained serializer. This is a maintenance notice, not a reported vulnerability. Explicitly accepted by the operator after the additional notice was exposed. |
| RUSTSEC-2024-0388 | derivative 2.2.0 | Unmaintained proc-macro; advisory lists no patched version. Retained where required by the resolved graph. |
| RUSTSEC-2024-0436 | paste 1.0.15 | Unmaintained macro crate; advisory lists no patched version. Retained where required by the resolved graph. |

No vulnerability advisory, other maintenance warning, or yanked package is exempted. Review these exceptions whenever dependencies change; remove an exception when upstream migration eliminates its package. Acceptance of maintenance risk is not proof of dependency security.

## Fixed dependencies—not audit exceptions

- Job-api and score-api use h2 0.4.16.
- Yanked chacha20 0.10.1 lock entries were updated to 0.10.2.
- RUSTSEC-2026-0253: S3 SDK 1.144.0 and Smithy HTTP client 1.4.0 permit patched lru 0.18.2.
- RUSTSEC-2026-0173: Alloy primitives/sol-types 1.7.2 and its macro family remove proc-macro-error2 in favor of proc-macro-error3. ABI, typed-data, and golden payout vectors remain regression gates.
- RUSTSEC-2023-0071: RustCrypto rsa was removed from job-api, including test resolution. Maintained aws-lc-rs 1.17.3 supplies fresh RSA2048 recipient keys and OAEP-SHA256/MGF1-SHA256 decryption. SPKI encoding, strict CMS parsing, empty OAEP label, AES key size, and zeroizing error/success buffers are covered by compatibility tests. Live Nitro verification is a separate release obligation.

## Controlled four-graph gate

From the repository root:

```sh
python3 offchain-rust/job-api/deploy/audit-dependencies.py
```

CI and release build/quality gates invoke this helper. It audits core, job-api, score-api, and score-core lockfiles independently, continues after an audit failure, and returns nonzero if any graph fails. Each invocation uses:

```sh
cargo +1.94.1 audit --deny warnings --ignore RUSTSEC-2021-0127 --ignore RUSTSEC-2024-0388 --ignore RUSTSEC-2024-0436 --file /absolute/path/to/Cargo.lock
```

There are no target filters, stale-database allowances, skipped yanked checks, or additional ignores. The absolute lockfile path selects the graph without regenerating it. Audits run in a private temporary working directory with `.cargo/audit.toml` containing `[advisories]` and `ignore = []`.

### Why isolate the working directory?

cargo-audit 0.22.2 does not support `--config`. Its [configuration loader](https://github.com/rustsec/rustsec/blob/cargo-audit/v0.22.2/cargo-audit/src/commands.rs#L52-L81) selects one file: `./.cargo/audit.toml` if present, otherwise `$CARGO_HOME/audit.toml` (normally `~/.cargo/audit.toml`). It does not search parent project directories or merge local and global files. However, [CLI ignores are appended to the selected configuration's ignores](https://github.com/rustsec/rustsec/blob/cargo-audit/v0.22.2/cargo-audit/src/commands/audit.rs#L217-L224), so CLI flags alone do not constrain ambient exceptions.

The helper's empty local configuration prevents global fallback without changing credentials, caches, Cargo home, or any global file. Checked-in core/job-api configs also contain only the three approved IDs. Use the helper rather than direct score-api/score-core audit commands, which could otherwise fall back to global configuration.

Python 3.9-compatible regression tests reject extra or duplicated advisory IDs, additional filtering configuration, and malicious ambient ignores. They verify exact subprocess arguments, all four graph invocations, failure propagation, and CI/release helper wiring.

## Retained upstream maintenance obligation

Track an official NSM release that removes serde_cbor. Before adopting it, verify NSM request/response compatibility, the exact Linux enclave build, and live attestation/decryption. Do not replace the official SDK with an unreviewed fork merely to silence the maintenance notice.

Sources: [serde_cbor advisory](https://rustsec.org/advisories/RUSTSEC-2021-0127.html), [NSM 0.5.2 dependencies](https://docs.rs/crate/aws-nitro-enclaves-nsm-api/0.5.2), [RSA advisory](https://rustsec.org/advisories/RUSTSEC-2023-0071.html), [proc-macro-error2 advisory](https://rustsec.org/advisories/RUSTSEC-2026-0173.html).
