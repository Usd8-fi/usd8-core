# Registry whole-contract Kontrol property plan

Status: current-source **Forge-green candidate specification** with **49 conventional `test_*` formal candidates in 5 `*KontrolTest` classes**. Accepted solver evidence is **0/49**. No `src/` change or solver run was part of this documentation reconciliation.

## Pinned current input

- `src/Registry.sol` SHA-256: `bcdfdc1a0c07d1a2c5b18aa46946cfda097420c334ef3c16d522016571a52ae5`
- `foundry.toml` SHA-256: `076e5778688f7a7e1bbb8496e1b211925ba5882b02aba7542f4676fc5206057d`
- Artifact: `formal-verification/out/Registry.sol/Registry.json`
- Resolved profile: Solidity 0.8.28, Cancun, optimizer enabled, optimizer runs **1**
- Compiled surface: **61 functions** = 35 view, 25 nonpayable, 1 payable; **25 events**; **33 errors**
- Canonical compact ABI SHA-256: `27cd38dae90cf604c8be65a9693b80ebe6882901a6951212601548c79962905f`
- Creation bytecode: 14,826 bytes; SHA-256 `3b3ac27e374d0349abc7ab8c774ef237195a9171313c0a3b0c68f32d7fa21491`
- Runtime bytecode: 14,577 bytes; SHA-256 `512c00acabf3cf4aba6086c0c700d489d5822fbd703c479de7620a61e86b4ae1`

The source, ABI, and bytecode values above were recomputed from the current working tree and refreshed artifact. The earlier 58-function deployment snapshot belongs to historical Sepolia provenance and is not the current formal candidate.

## Executable candidate families

| Class | Candidates | Principal scope |
|---|---:|---|
| `RegistryAccessKontrolTest` | 10 | initialization, timelock/admin authorization, canonical pointers, routes, pause/beta controls, exact first-log behavior |
| `RegistryModuleScoringKontrolTest` | 12 | module freeze/replacement, score accounting, history behavior, exact errors and rollback |
| `RegistryTimingKontrolTest` | 9 | effective defaults, timing/price/protocol-fee policy domains, ACL, exact events/errors, rollback |
| `RegistryTopologyKontrolTest` | 9 | pool/feed topology, validation order, collection behavior, add/remove rollback |
| `RegistryUpgradeKontrolTest` | 9 | UUPS context, beta/timelock gates, compatibility, payable paths, rollback, named preservation |
| **Total** | **49** | **Forge-green candidates; 0 solver-proved** |

## Compiled ABI closure matrix

| Surface | Count | Current assignment |
|---|---:|---|
| Functions | 61 | Assigned across access, module/scoring, timing, topology, and upgrade families |
| Events | 25 | First-log paths assigned to candidate families; later/multi-log ordering remains Foundry-only |
| Errors | 33 | Reachable branches require exact bytes/rollback; inherited no-path branches require source-backed exclusion |

### Event union (25)

`AdminSet`, `AssetUsdFeedSet`, `BetaModeEnded`, `BoosterNFTSet`, `DefiInsuranceSet`, `ExitTimingConfigSet`, `IncidentOpenPriceConfigSet`, `IncidentTimingConfigSet`, `Initialized`, `MaxCoverPoolPayoutBpsSet`, `MaxOracleStalenessSet`, `PausedSet`, `PoolAdded`, `PoolRemoved`, `ProtocolFeeConfigSet`, `SavingsVaultSet`, `ScoreSpentRecorded`, `ScoredTokenSet`, `SwapRouteSet`, `TeePcrHashSet`, `TimelockChanged`, `TreasurySet`, `Upgraded`, `Usd8PriceOracleSet`, and `Usd8Set`.

Pinned Kontrol v1.0.255 can soundly use `expectEmit` only for the first transaction-wide log. Initializer suffixes, multi-target pause logs, `PoolAdded`/`PoolRemoved` after `AssetUsdFeedSet`, and delegate-initializer suffixes are Foundry-only ordering requirements where an earlier log cannot be skipped.

### Error closure rule (33)

The compiled error union is current only when regenerated from the artifact. A candidate may count an error as reachable only with a production external path, exact returndata length/content, and nondegenerate atomic rollback. Vendor errors with no path, or errors preempted by an earlier guard/decode failure, require an exact source-backed structural/preemption reason; ABI declaration alone is not reachability.

`RegistryTimingKontrolTest` explicitly assigns the added `MAX_PROTOCOL_FEE_BPS()`, `protocolFeeConfig()`, and `setProtocolFeeConfig(...)` selectors plus `ProtocolFeeConfigSet` and `InvalidProtocolFeeBps`: defaults, exact successful storage/event bytes, zero receiver, both independent BPS upper bounds, unauthorized caller, and rollback are executable in the existing 9-candidate family.

## Assumptions and model boundaries

1. **Insurance model:** fixed helper bytecode covers zero/nonzero incident id, insured-token true/false, revert, malformed return, and no-code. Static views do not model arbitrary callback mutation.
2. **Pool model:** fixed helper bytecode covers exact asset, zero, revert, malformed return, and no-code. Removal requires exact pool-address membership, not only asset equality.
3. **Feed model:** fixed state-selectable behavior covers decimals and `latestRoundData` shape/positivity/round relations. This establishes integration validation, not economic oracle correctness.
4. **UUPS models:** no-code, non-UUPS, wrong UUID, named compatible V2, payable/nonpayable initializer, and reverting initializer. Preservation claims apply only to the named reviewed V2.
5. **Collections:** pool lists, scored-token histories, and pause batches are bounded as stated by the executable properties, commonly `N <= 3`. No unbounded gas/liveness theorem is claimed.
6. **Address representatives:** fixed nonzero representatives plus explicit zero, alias, role-overlap, and rotation partitions are used where behavior depends only on equality/mapping keys.
7. **Environment:** scoring timeline properties assume realistic `block.number <= type(uint64).max`; arithmetic overflow paths remain separate exact candidates.
8. **Governance:** current timelock/admin powers and approved topology are trusted boundaries. A compromised authorized upgrade can replace behavior outside the named-model theorem.

## Current behavior decisions preserved by the candidates

- Repeated `endBetaMode()` calls currently succeed and emit while beta mode is already false.
- Beta-mode upgrades remain possible during an active incident because the current upgrade path is not freeze-gated.
- Canonical pointer and route setters are not incident-freeze-gated unless the source explicitly applies that guard.

These are current-bytecode characterizations, not recommendations. Changing them requires explicit approval and would invalidate the snapshot.

## Acceptance gate for a future solver campaign

1. Re-hash `Registry.sol`, imports, `foundry.toml`, ABI, creation bytecode, and runtime bytecode.
2. Recompute the exact 61-function/25-event/33-error matrix and 49 typed candidate signatures.
3. Run the independent Cancun transient-storage environment gate.
4. Smoke one exact signature from each of the five families, then produce clean family reports.
5. Require zero failed, pending, stuck, timed-out, or admitted branches and keep Foundry-only ordering separate.
6. Bind report bytes, commands, tool versions, source/build/ABI/bytecode hashes, and exact signatures in a regenerated campaign manifest.

Until those steps complete, the honest status remains **49 Forge-green candidates and 0 solver-proved properties**.
