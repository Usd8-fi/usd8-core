# DefiInsurance ABI event and exact-error closure

Status: current-source **Forge-green candidate closure** with **101 conventional `test_*` formal candidates in 6 `*KontrolTest` classes**, plus 16 conventional non-Kontrol regressions. Accepted solver evidence is **0/101**. This documentation reconciliation made no `src/`, property, regression, script, or solver changes.

This matrix is source-checked against `src/DefiInsurance.sol`, inherited OpenZeppelin/`SharedBase` sources, and the compiled `DefiInsurance` ABI. The ABI contains **22 events**: **10 Kontrol first-log obligations**, **11 Foundry-only later-log event-name obligations**, and **1 structural non-emission exclusion**. Path-sensitive Foundry regressions contain 12 event-order definitions because some ABI event names require more than one materially distinct transaction trace.

Kontrol v1.0.255 cannot advance `expectEmit` past an earlier unmatched log. Foundry-only rows therefore queue the complete transaction-wide prefix and exact target event. All expectations pin the emitter, every indexed topic, and all unindexed data.

## Event matrix (22)

| ABI event | Source path and exact transaction order | Classification | Evidence |
|---|---|---|---|
| `RegistryChanged(oldRegistry,newRegistry)` | Separate proxy `initialize`: first log, payload `(0, registry)` | Kontrol | `DefiInsuranceEventsKontrolTest.test_initializeEmitsRegistryChanged` |
| `Initialized(version)` | Separate proxy `initialize`: `RegistryChanged` -> `Initialized(1)` | Foundry-only ordered | `test_initializeEmitsRegistryChangedThenInitialized` |
| `InsuredTokenAdded(insuredToken)` | New `editInsuredToken`: first of four configuration logs | Kontrol | `test_newInsuredTokenEmitsAddedFirst` |
| `MaxCoverageBpsSet(insuredToken,maxCoverageBps)` | Existing-token `editInsuredToken`: first log | Kontrol | `test_existingInsuredTokenUpdateEmitsExactCoverageFirst` |
| `UnderlyingPriceOracleSet(insuredToken,oracle)` | New `editInsuredToken`: `InsuredTokenAdded` -> `MaxCoverageBpsSet` -> `UnderlyingPriceOracleSet` | Foundry-only ordered | `test_newTokenConfigurationEmitsExactFourLogOrder` |
| `UnderlyingConversionSet(insuredToken,address,data)` | New `editInsuredToken`: fourth configuration log | Foundry-only ordered | `test_newTokenConfigurationEmitsExactFourLogOrder` |
| `InsuredTokenRemoved(insuredToken)` | Direct delist: first log | Kontrol | `test_delistEmitsExactInsuredTokenRemoved` |
| `SettlementParamsSet(params)` | `setSettlementParams`: first log; full tuple data checked | Kontrol | `test_settlementParamsEmitsExactTuple` |
| `IncidentOpened(incidentId,insuredToken,claimDeadline,protocolFeeShareBps)` | Admin open with no pools: first log; includes the incident's fee-rate snapshot | Kontrol | `test_adminOpenEmitsExactIncidentTokenAndDeadline` |
| `IncidentSettled(incidentId,root,teePcrHash)` | `settleIncident`: `InsuredTokenRemoved` -> `IncidentSettled` | Foundry-only ordered | `test_settlementEmitsDelistBeforeExactSettlement` |
| `IncidentCorrected(incidentId,root)` | Nonzero correction after initial settlement/delist: first log | Kontrol | `test_nonzeroCorrectionEmitsExactReplacementRoot` |
| `ClaimRegistered(claimId,incidentId,user,escrow,score,booster)` | First `fileClaim`: `IncidentOpened` -> insured-token `Transfer` -> bond `Transfer` -> `ClaimRegistered`; nonzero booster join additionally pins the ERC-1155 prefix | Foundry-only ordered | `DefiInsuranceEventOrderingForgeTest.test_firstFileClaimEmitsOpenTransfersThenExactRegistration`, `DefiInsuranceEventOrderingForgeTest.test_nonzeroBoosterTransferPrefixesExactClaimRegisteredPayload` |
| `ClaimFinalized(claimId,user)` | Accepted exact-eligibility row: booster burn (when nonzero) -> bond `Transfer` -> claimant payout-token `Transfer` -> pool `ClaimPaid` -> fee payout-token `Transfer` -> pool `ClaimPaid` -> `ProtocolFeePaid` -> `ScoreSpent` -> Registry `ScoreSpentRecorded` -> `ClaimFinalized` | Foundry-only ordered | `DefiInsuranceEventOrderingForgeTest.test_acceptedFinalizationEmitsBondScoreRegistryThenFinalized`, `DefiInsuranceEventOrderingForgeTest.test_nonzeroBoosterBurnAndPayoutTokenPoolPrefixesAreExact` |
| `ProtocolFeePaid(incidentId,pool,receiver,amount)` | Nonzero-fee accepted finalization: claimant payout -> fee payout -> `ProtocolFeePaid`; exact snapshotted gross budget and live receiver are asserted | Foundry-only ordered | `DefiInsuranceEventOrderingForgeTest.test_nonzeroBoosterBurnAndPayoutTokenPoolPrefixesAreExact` |
| `ClaimCancelled(claimId,user)` | `cancelClaim`: bond `Transfer` -> insured-token `Transfer` -> `ClaimCancelled` | Foundry-only ordered | `test_cancelEmitsBondAndInsuredTransfersBeforeCancellation` |
| `ClaimDeclined(claimId,user,eligible)` | Decline: insured-token `Transfer` -> bond `Transfer` -> `ClaimDeclined`; both `eligible=true/false` payloads checked | Foundry-only ordered | `test_eligibleDeclineEmitsRefundsThenExactEligibleFlag`, `test_ineligibleDeclineForfeitsBondThenEmitsFalseFlag` |
| `TeeSignerSet(signer,authorized)` | `setTeeSigner`: first log | Kontrol | `test_teeSignerEmitsExactSignerAndAuthorization` |
| `ScoreSpent(user,amount,incidentId)` | Accepted finalization after bond transfer; followed by Registry accounting log | Foundry-only ordered | `test_acceptedFinalizationEmitsBondScoreRegistryThenFinalized` |
| `ETHSwept(to,amount)` | Successful `sweepETH`: first log when recipient emits none | Kontrol | `test_sweepETHEmitsExactRecipientAndAmount` |
| `TokenSwept(token,to,amount)` | Successful `sweepToken`: token `Transfer` -> `TokenSwept` | Foundry-only ordered | `test_sweepTokenEmitsTransferThenExactTokenSwept` |
| `Upgraded(implementation)` | Compatible `upgradeToAndCall` with empty data: first log | Kontrol | `test_compatibleUpgradeEmitsExactImplementation` |
| `EIP712DomainChanged()` | Declared by inherited `IERC5267`; current vendored `EIP712Upgradeable` has no emitting path | Structural non-emission exclusion | Source classification; no fabricated runtime property |

`setClaimBondAmount(uint128)` deliberately emits **no event** and accepts the full `uint128` domain, including zero. `DefiInsuranceConfigKontrolTest.test_claimBondAmountTimelockControlsFullUint128Domain(uint128,uint128)` preserves the domain, while `DefiInsuranceEventOrderingForgeTest.test_claimBondSetterEmitsNoLogsForZeroOrNonzero()` records and asserts the exact zero-log trace.

## Executable selector and error evidence

`defi-insurance-abi-closure.json` maps every one of the **38 compiled function signatures** to an exact compiled `Contract::test_signature(types)` identity plus required assertions. The validator isolated-compiles each cited DefiInsurance formal source and rejects any evidence name absent from the resulting test ABI.

The same manifest closes all **47 compiled custom errors** as **44 reachable**, **1 preempted**, and **2 structural**. Reachable rows require `test`, `returndata: complete`, exact `returndata_length` (`4` for every zero-argument error, canonical ABI otherwise), and nonempty rollback fields. Exclusions require an exact source path and reason. `AddressEmptyCode(address)` is preempted because the UUPS `proxiableUUID` staticcall to a no-code candidate fails with empty returndata before Address/ERC1967 code validation; `FailedCall()` and `NotInitializing()` have no DefiInsurance/SharedBase production call site.

Residual exact witnesses include:

- ECDSA invalid length, high-`s`, and invalid-`v`/zero-recovery, with exact full returndata and unchanged root/budget/listing: `DefiInsuranceSettlementKontrolTest.test_settlementEcdsaInvalidLengthInvalidSAndInvalidVAreExactAndAtomic()`.
- `ERC1967InvalidImplementation(address)`, `ERC1967NonPayable()`, and `UUPSUnsupportedProxiableUUID(bytes32)`, with implementation-slot/value rollback: the three named DefiInsuranceAdmin upgrade tests in the JSON matrix.
- `SafeERC20FailedOperation(address)` with exact token argument and balances unchanged: `DefiInsuranceAdminKontrolTest.test_falseRevertingAndMalformedTokenSweepsRollbackAtomically(uint64)`.
- Exact `AlreadySettled`, `ClaimWindowClosed`, `SettlementPoolMismatch`, `PayoutCapExceeded`, and `SafeCastOverflowedUintDowncast(128,value)` bytes with branch-specific rollback, as cited by their manifest rows.
- Independent settlement binding for root and budget, plus a production cancellation/re-file mutation that changes the claim-set commitment while keeping unresolved count, pools, PCR, root input, and payout vector constant: `test_settlementSignatureSeparatelyBindsRootAndBudgetWithFullRecoveredBytes()` and `test_settlementRejectsClaimSetOnlyMutationWithFullRecoveredBytes()`.
- The named V2 upgrade fixture now preserves nonempty conversion bytes, settled historical state, and a second expired-but-unresolved claim with live nonzero insured-token escrow, claim bond, and booster liability, then proves post-upgrade recovery.

## Remaining exact-error closure

| Branch / callback class | Exact result and atomicity evidence |
|---|---|
| Cancel with no active claim | Exact `NoActiveClaim()` and unchanged incident/claim counters: `test_cancelWithoutActiveClaimRevertsExactlyAndPreservesCounters` |
| Later join carrying either nonzero open reference or nonempty signature | Exact `UnexpectedOpenAttestation()` for both partitions; claim count, unresolved count, claim-set hash, and balances unchanged: `test_laterJoinRejectsUnexpectedOpenAttestationExactlyAndAtomically` |
| Deregistered module, first-claim/open partition | Exact `DefiInsuranceNotRegistered()` before malformed open-attestation handling; no incident snapshot/counter writes: `test_deregisteredModuleRejectsFirstClaimBeforeOpenAttestationPartition` |
| Deregistered module, later-join partition | Exact `DefiInsuranceNotRegistered()` and no escrow/state writes: `test_deregisteredModuleCannotAcceptClaimJoinOrEscrow` |
| Insured ERC20 callback during `fileClaim` | Nested call returns exact `ReentrancyGuardReentrantCall()`; outer claim completes once with exact escrow: `test_insuredTokenCallbackCannotReenterFileClaimAndOuterJoinIsExact` |
| Insured ERC20 callback during cancellation refund | Nested cancellation returns exact transient-guard selector; outer cancellation completes once and releases escrow: `test_refundTokenCallbackCannotReenterCancelAndOuterCancelCompletes` |
| Cover-pool callback during `payClaim` | Nested finalization returns exact transient-guard selector; outer payout, budget debit, and resolution complete once: `test_poolPaymentCallbackCannotReenterFinalizationAndOuterPayoutCompletes` |

## Current candidate family accounting

| Class | Candidates |
|---|---:|
| `DefiInsuranceAdminKontrolTest` | 13 |
| `DefiInsuranceClaimLifecycleKontrolTest` | 23 |
| `DefiInsuranceConfigKontrolTest` | 18 |
| `DefiInsuranceEventsKontrolTest` | 10 |
| `DefiInsuranceFinalizationKontrolTest` | 17 |
| `DefiInsuranceSettlementKontrolTest` | 20 |
| **Total** | **101** |

All 101 are Forge-green candidate definitions. None is accepted as solver-proved until clean exact-signature reports are authenticated against the current source, ABI, and bytecode snapshot.

Generic OpenZeppelin/vendor errors are not forced through artificial production paths. Existing exact protocol-error properties remain authoritative for the rest of the reachable branch surface.
