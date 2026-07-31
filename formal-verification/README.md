# USD8 protocol formal-verification workspace

This workspace contains the approved current-source property snapshot for all nine first-party deployable contracts under `src/`. The properties are executable with Forge and are shaped for a later Kontrol/KEVM campaign. They are **candidate specifications, not completed solver proofs**.

## Approved snapshot

| Metric | Current value |
|---|---:|
| Formal candidate properties | **841** |
| `*KontrolTest` classes | **46** |
| Conventional executable `test_*` definitions | **915** |
| Foundry-only / non-Kontrol definitions | **74** |
| Accepted snapshot-authenticated solver proofs | **0** |

The 841 formal candidates plus 74 Foundry-only/non-Kontrol definitions equal the 915-definition executable inventory. Seven camel-named ERC4626Strategy integration checks are retained outside this conventional `test_*` inventory and are not silently added to either approved count.

### Formal candidates by family

| Family | Candidates |
|---|---:|
| USD8PriceOracle | 33 |
| USD8SavingsAdapter | 50 |
| USD8SavingsBootstrap | 116 |
| SingleAssetCoverPool | 110 |
| ERC4626Strategy | 124 |
| DefiInsurance | 101 |
| Treasury | 165 |
| Registry | 49 |
| USD8 | 93 |
| **Total** | **841** |

These counts were recomputed from `FOUNDRY_PROFILE=kontrol forge test --list --json`, selecting conventional `test_*` methods in classes ending in `KontrolTest`. The complete profile has 915 conventional `test_*` definitions; subtracting the 841 candidates gives 74 Foundry-only/non-Kontrol definitions.

## Pinned build configuration

The resolved `kontrol` Foundry profile is:

- Solidity `0.8.28`
- Cancun EVM schedule
- optimizer enabled
- **optimizer runs `1`**
- tests rooted at `formal-verification/`
- artifacts and cache rooted at `formal-verification/out` and `formal-verification/cache`

The optimizer value is inherited from `[profile.default]`; it is not 200. `FOUNDRY_PROFILE=kontrol forge config --json` is authoritative for the resolved profile.

The local Forge used to refresh this snapshot was `1.7.2-nightly` at commit `6902a96211da7bcc3d9c4d8e97910ac5c9d5d2c6`. The intended proof tool remains Kontrol `v1.0.255`, but no solver was run during this documentation reconciliation.

## Scope and evidence claim

All nine deployables have current Forge-executable candidate families:

- `USD8`
- `Treasury`
- `DefiInsurance`
- `SingleAssetCoverPool`
- `Registry`
- `ERC4626Strategy`
- `USD8PriceOracle`
- `USD8SavingsAdapter`
- `USD8SavingsBootstrap`

`protocol-scope.md` records the current compiled function/event/error matrix and recomputed source, ABI, creation-bytecode, and runtime-bytecode hashes for every deployable.

The accurate claim is:

> The current workspace defines 841 Forge-green formal candidates across all nine deployables, under the documented scalar domains, collection bounds, external models, governance assumptions, and resolved compiler profile. No candidate is solver-proved until a clean Kontrol campaign binds accepted reports to this exact source/build/bytecode snapshot.

A Forge pass demonstrates executable definitions on concrete executions. It does not establish KEVM reachability proof, solver completion, report provenance, or universal correctness.

## Model and governance boundaries

- Successful token accounting assumes the named exact-transfer/non-rebasing models where stated. False-return, revert, malformed-return, no-return, fee, drift, and callback modes are separate modeled partitions, not arbitrary-token proofs.
- Collections and lifecycle traces are bounded as documented by each family, commonly `N <= 3`; no arbitrary-length gas/liveness claim is made.
- Cryptographic primitives, compiler correctness, OpenZeppelin/vendor correctness, Kontrol/KEVM/K, SMT solvers, and the EVM implementation remain trusted dependencies.
- UUPS properties cover authorization, compatibility, rollback, and named reviewed implementations; they cannot prove an arbitrary future implementation safe.
- Registry admin/timelock decisions and approved external modules are governance trust boundaries.
- An approved swap route means the exact `(target, spender)` pair is curated. It does **not** prove arbitrary router calldata, downstream calls, vault behavior, or Treasury-mediated callbacks safe. Strategy value safety therefore remains conditional on the documented router/token/vault models.
- Later-log presence/order and unsupported call-indexed schedules remain Foundry-only where Kontrol v1.0.255 cannot model them soundly.

## Reproduction and campaign boundary

```bash
# Resolve the effective compiler profile.
FOUNDRY_PROFILE=kontrol forge config --json

# Rebuild current artifacts and list the typed inventory; no solver is invoked.
FOUNDRY_PROFILE=kontrol FOUNDRY_DISABLE_NIGHTLY_WARNING=1 forge build
FOUNDRY_PROFILE=kontrol FOUNDRY_DISABLE_NIGHTLY_WARNING=1 forge test --list --json

# Execute the current Forge definitions.
FOUNDRY_PROFILE=kontrol FOUNDRY_DISABLE_NIGHTLY_WARNING=1 forge test

# Fail if compiled candidate signatures differ from the reviewed allowlist.
FOUNDRY_PROFILE=kontrol FOUNDRY_DISABLE_NIGHTLY_WARNING=1 \
  python3 formal-verification/scripts/generate_campaign_manifest.py --check-approved-inventory
```

`run_campaign.sh`, `approved-campaign-inventory.json`, the manifest generator, and report validator are reconciled to this 841-candidate snapshot. Clean XML is schema-level evidence only. Do not publish accepted totals until a fresh runner campaign records exact commands, exit codes, source digest, toolchain and report hashes, regenerates clean XML, and validates that execution record together with source closure, build-info, ABI, creation/runtime bytecode, typed signatures, runner, reports, effective compiler configuration, and toolchain provenance. The solver-proved count remains zero until that validation passes.

## Current validation boundary

This snapshot updates executable properties, regressions, scripts, and metadata to the current `src/` behavior. Forge execution validates those definitions as Solidity tests; it is not a Kontrol solver campaign. No solver was invoked, and the accepted solver-proof count remains 0/841.
