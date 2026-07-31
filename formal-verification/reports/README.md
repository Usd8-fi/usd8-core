# Verification report status

Pinned candidate environment: intended Kontrol `v1.0.255`, Solidity `0.8.28`, Forge `1.7.2-nightly` (`6902a96211da7bcc3d9c4d8e97910ac5c9d5d2c6`), Cancun, optimizer enabled, resolved optimizer runs **1**.

## Current accounting

| Family | `*KontrolTest` classes | Forge-green formal candidates | Accepted solver proofs |
|---|---:|---:|---:|
| USD8PriceOracle | 1 | 33 | 0 |
| USD8SavingsAdapter | 2 | 50 | 0 |
| USD8SavingsBootstrap | 1 | 116 | 0 |
| SingleAssetCoverPool | 7 | 110 | 0 |
| ERC4626Strategy | 6 | 124 | 0 |
| DefiInsurance | 6 | 101 | 0 |
| Treasury | 12 | 165 | 0 |
| Registry | 5 | 49 | 0 |
| USD8 | 6 | 93 | 0 |
| **Total** | **46** | **841** | **0** |

The complete conventional profile inventory contains **915 `test_*` definitions**. The difference between 915 and 841 is **74 Foundry-only/non-Kontrol definitions**. Seven camel-named ERC4626Strategy integration checks are outside this approved conventional inventory.

## Evidence status

No accepted XML set, campaign manifest, or report checksum set authenticates the approved 841-candidate snapshot. Historical and diagnostic XML files may be useful for debugging, but they are not accepted proof evidence for the hash-bound source and bytecode.

Accordingly:

- 841 is a count of executable formal **definitions**, not solver passes;
- Forge-green means the definitions execute successfully under Foundry, not that KEVM discharged every symbolic path;
- the accepted solver-proved count is **0**;
- old report totals such as 432/453 are superseded and must not be combined with this inventory;
- post-hoc hashing of artifacts beside historical XML would not bind those proofs to this snapshot.

The current `run_campaign.sh`, manifest generator, durable inventory, and report validator are reconciled to the approved 841-candidate/46-class snapshot. Historical XML remains untrusted: a real campaign first removes stale root reports, runs all current groups, records every exact proof/Forge command, exit code, source digest, toolchain and report hash, then accepts results only when that execution record, exact typed signatures, source closure, ABI, creation/runtime bytecode, effective compiler configuration, and rich manifest validation all pass. Clean XML alone is schema-level evidence, not authenticated solver provenance.

## Family definitions

Counts below are conventional `test_*` methods in current `*KontrolTest` classes.

### USD8PriceOracle — 33 candidates

- `USD8PriceOracleKontrolTest`: 33

### USD8SavingsAdapter — 50 candidates

- `USD8SavingsAdapterCoreKontrolTest`: 35
- `USD8SavingsAdapterProfitKontrolTest`: 15

### USD8SavingsBootstrap — 116 candidates

- `USD8SavingsBootstrapKontrolTest`: 116

### SingleAssetCoverPool — 110 candidates

- `SingleAssetCoverPoolERC4626KontrolTest`: 21
- `SingleAssetCoverPoolErrorsKontrolTest`: 43
- `SingleAssetCoverPoolEventsKontrolTest`: 6
- `SingleAssetCoverPoolExitKontrolTest`: 15
- `SingleAssetCoverPoolPayoutKontrolTest`: 5
- `SingleAssetCoverPoolRewardsKontrolTest`: 12
- `SingleAssetCoverPoolSweepKontrolTest`: 8

### ERC4626Strategy — 124 candidates

- `ERC4626StrategyConstructionViewsKontrolTest`: 7
- `ERC4626StrategyDeployWithdrawKontrolTest`: 10
- `ERC4626StrategyExternalModesKontrolTest`: 42
- `ERC4626StrategySwapKontrolTest`: 21
- `ERC4626StrategySwapModesKontrolTest`: 31
- `ERC4626StrategySweepKontrolTest`: 13

### DefiInsurance — 101 candidates

- `DefiInsuranceAdminKontrolTest`: 13
- `DefiInsuranceClaimLifecycleKontrolTest`: 23
- `DefiInsuranceConfigKontrolTest`: 18
- `DefiInsuranceEventsKontrolTest`: 10
- `DefiInsuranceFinalizationKontrolTest`: 17
- `DefiInsuranceSettlementKontrolTest`: 20

### Treasury — 165 candidates

- `TreasuryKontrolTest`: 12
- `TreasuryAclPauseKontrolTest`: 15
- `TreasuryEventsKontrolTest`: 7
- `TreasuryHarvestDirectKontrolTest`: 16
- `TreasuryHarvestHooksKontrolTest`: 12
- `TreasuryInitUpgradeKontrolTest`: 24
- `TreasuryLiquidityWalkKontrolTest`: 17
- `TreasuryReceiverSetKontrolTest`: 11
- `TreasuryReserveAdversarialKontrolTest`: 11
- `TreasuryStrategyFlowsKontrolTest`: 14
- `TreasuryStrategySetKontrolTest`: 13
- `TreasurySweepKontrolTest`: 13

### Registry — 49 candidates

- `RegistryAccessKontrolTest`: 10
- `RegistryModuleScoringKontrolTest`: 12
- `RegistryTimingKontrolTest`: 9
- `RegistryTopologyKontrolTest`: 9
- `RegistryUpgradeKontrolTest`: 9

### USD8 — 93 candidates

- `USD8ERC20KontrolTest`: 22
- `USD8EventsKontrolTest`: 9
- `USD8PermitKontrolTest`: 19
- `USD8SweepKontrolTest`: 16
- `USD8TokenKontrolTest`: 12
- `USD8UpgradeKontrolTest`: 15

## Required future campaign evidence

A solver campaign may move the accepted count above zero only after it:

1. freezes production sources, property sources, imports, `foundry.toml`, and toolchain;
2. resolves and records optimizer runs 1 and Cancun from `FOUNDRY_PROFILE=kontrol forge config --json`;
3. rebuilds all nine production artifacts and the exact 841-signature inventory;
4. passes the independent Cancun `TLOAD`/`TSTORE` environment gate;
5. emits clean exact-signature reports with no failed, pending, stuck, timed-out, or admitted branches;
6. separates the 74 Foundry-only/non-Kontrol definitions from solver evidence;
7. regenerates a manifest that authenticates source, imports, build-info, ABI, creation/runtime bytecode, runner bytes, accepted report bytes, checksums, commands, schedule, and exit codes; and
8. validates all totals against the current compiled inventory rather than stale allowlists.

## Current executable documentation gates

```bash
FOUNDRY_PROFILE=kontrol forge config --json
FOUNDRY_PROFILE=kontrol FOUNDRY_DISABLE_NIGHTLY_WARNING=1 forge build
FOUNDRY_PROFILE=kontrol FOUNDRY_DISABLE_NIGHTLY_WARNING=1 forge test --list --json
FOUNDRY_DISABLE_NIGHTLY_WARNING=1 forge fmt --check
git diff --check
```

The approved inventory and executable harness metadata are current for this source snapshot. No Kontrol solver campaign was invoked, so accepted solver proof evidence remains 0/841.
