# SingleAssetCoverPool ABI event and reachable-error closure

Status: current-source **Forge-green candidate closure** with **110 conventional `test_*` formal candidates in 7 `*KontrolTest` classes** and 16 conventional Foundry-only ordered-trace definitions. Accepted solver evidence is **0/110**. This documentation reconciliation made no `src/`, property, regression, script, or solver changes.

Source boundary: current `src/SingleAssetCoverPool.sol` plus the ABI produced by
`FOUNDRY_PROFILE=kontrol forge inspect SingleAssetCoverPool abi --json`.
The compiled surface contains **17 events** and **42 errors**.

## Event matrix

Kontrol v1.0.255 can soundly use `expectEmit` only for the first transaction-wide
log. A token `Transfer`, pool-share `Transfer`, or proxy-constructor `Upgraded`
therefore moves a later application log into a dedicated ordered Foundry
regression. Each Foundry-only row is a distinct obligation, not complementary
formal evidence.

| ABI event | Production path and exact order | Classification | Evidence |
|---|---|---|---|
| `Approval(owner,spender,value)` | `approve`: pool `Approval` is first; `permit`: exact `Approval` after independent domain/signature construction | Kontrol + Foundry path trace | `SingleAssetCoverPoolEventsKontrolTest.test_approveEmitsExactApproval`; `test_permitEmitsExactApproval` |
| `ClaimPaid(to,amount)` | `payClaim`: asset `Transfer` -> pool `ClaimPaid` | Foundry-only ordered | `test_payClaimOrdersAssetTransferThenExactClaimPaid` |
| `Deposit(sender,owner,assets,shares)` | `deposit`/`mint`: asset `Transfer` -> share `Transfer(0,owner,shares)` -> pool `Deposit`; mint uses distinct sender/receiver | Foundry-only ordered | `test_depositOrdersAssetTransferShareTransferThenDeposit`; `test_mintWithDistinctSenderReceiverOrdersExactTrace` |
| `DepositCapSet(newCap)` | `setDepositCap`: first log | Kontrol | `test_setDepositCapEmitsExactCap` |
| `EIP712DomainChanged()` | Vendored `EIP712Upgradeable` declares the event but has no emitting path | Structural non-emission | Excluded after vendor-source inspection |
| `ETHSwept(to,amount)` | `sweepETH`: first log after value transfer | Kontrol | `test_sweepETHEmitsExactRecipientAndAmount` |
| `ExitClaimed(user,receiver,shares,assets)` | explicit and auto-settling `completeRedeem`: optional burn/settlement prefix -> asset `Transfer` -> exact claim; nonfinal floor and final dust-drain paths are distinct | Foundry-only ordered | `test_completeRedeemOrdersAssetTransferThenExactClaim`; `test_completeRedeemAutoSettlementHasExactBurnSettlementTransferClaimPrefix`; `test_nonFinalAndDustDrainingExitClaimsHaveDistinctExactTraces` |
| `ExitEpochSettled(exitEpoch,shares,assets)` | settlement: each share burn precedes its settlement; single, multi-epoch, request-auto-settlement, and completion-auto-settlement prefixes | Foundry-only ordered | `test_settlementOrdersBurnThenExactEpochSettlement`; `test_multiEpochSettlementOrdersEachBurnBeforeItsExactSettlement`; both auto-settlement prefix tests |
| `Initialized(version)` | deployment: proxy `Upgraded` -> pool `RegistryChanged` -> pool `Initialized(1)` | Foundry-only ordered | `test_initializeDeploymentOrdersProxyUpgradeRegistryAndInitialized` |
| `RedeemRequested(user,shares)` | `requestRedeem`: optional matured-epoch burn/settlement prefix -> share `Transfer(user,pool,shares)` -> request | Foundry-only ordered | `test_requestRedeemOrdersEscrowTransferThenRequest`; `test_requestRedeemAutoSettlementHasExactBurnSettlementTransferRequestPrefix` |
| `RegistryChanged(old,new)` | separate initializer call on a real uninitialized proxy: first application log | Kontrol | `test_initializeEmitsRegistryChangedFirst` |
| `RewardClaimed(user,amount)` | `claimReward`: USD8 `Transfer` -> pool `RewardClaimed` | Foundry-only ordered | `test_rewardClaimOrdersTokenTransferThenExactClaim` |
| `RewardNotified(amount,newRate,newPeriodFinish)` | initial and overlapping distribution: USD8 `Transfer` -> exact pool schedule log | Foundry-only ordered | `test_rewardNotificationOrdersTokenTransferThenExactSchedule`; `test_overlappingRewardNotificationOrdersExactTransferAndBlendedSchedule` |
| `RewardsDurationSet(old,new)` | `setRewardsDuration`: first log | Kontrol | `test_setRewardsDurationEmitsOldThenNewDuration` |
| `TokenSwept(token,to,amount)` | token `Transfer` -> pool `TokenSwept` | Foundry-only ordered | `test_sweepTokenOrdersTokenTransferThenExactSweep` |
| `Transfer(from,to,value)` | share `transfer`: pool `Transfer` is first; mint/burn/escrow variants are included in ordered regressions | Kontrol | `test_transferEmitsExactTransfer` |
| `Withdraw(sender,receiver,owner,assets,shares)` | No path: `withdraw` and `redeem` are overridden synchronously and always revert before inherited `_withdraw` | Structural non-emission | Excluded; disabled exits proved in `SingleAssetCoverPoolERC4626.k.sol` |

**Event totals:** **6 Kontrol**, **9 Foundry-only**, **2 structural
non-emission exclusions** = **17 ABI events**.

Path-sensitive executable accounting is separate from the ABI-event-name matrix:
**6 first-log Kontrol obligations + 16 Foundry transaction-trace obligations**.
Several traces close distinct paths for the same ABI event and therefore do not
change the 17-event ABI union.

`Upgraded(address)` is intentionally not counted as a pool ABI event: the current
pool does not inherit UUPS and its compiled ABI does not contain `Upgraded` or
`upgradeToAndCall`. The real `ERC1967Proxy` constructor nevertheless emits
`Upgraded` first, and the initialization-order regression asserts that deployment
infrastructure log explicitly.

## Error matrix

“Reachable” means a current external production path can reach the error under
its stated model boundary. Generic vendor errors are obligations only when such
a path exists. Exact argument payloads newly closed by
`SingleAssetCoverPoolErrors.k.sol` include contract-specific, ERC20, permit,
SafeCast, SafeERC20, and reentrancy paths.

| ABI error | Reachability / path | Classification and evidence |
|---|---|---|
| `CooldownNotElapsed(uint64)` | early `completeRedeem` | Reachable formal; exact epoch payload in `test_contractSpecificArgumentErrorsCarryExactPayloads` |
| `ECDSAInvalidSignature()` | permit with invalid `v/r/s` | Reachable formal; `test_reachablePermitErrorsAreExactAndRollbackNonce` |
| `ECDSAInvalidSignatureLength(uint256)` | pool exposes only fixed `v,r,s` permit, never bytes-signature recovery | Structurally unreachable vendor error |
| `ECDSAInvalidSignatureS(bytes32)` | permit with high-`s` signature | Reachable formal; exact `s` payload |
| `ERC20InsufficientAllowance(address,uint256,uint256)` | finite `transferFrom` allowance shortfall | Reachable formal; exact spender/current/needed payload |
| `ERC20InsufficientBalance(address,uint256,uint256)` | share transfer above balance | Reachable formal; exact sender/balance/needed payload |
| `ERC20InvalidApprover(address)` | `transferFrom(address(0),...,0)` reaches `_approve` during allowance spending | Reachable formal; exact zero approver payload |
| `ERC20InvalidReceiver(address)` | share transfer to zero | Reachable formal; exact zero receiver payload |
| `ERC20InvalidSender(address)` | normal transfer sender is nonzero; zero `from` in `transferFrom` reaches `ERC20InvalidApprover` first | Structurally unreachable under current external paths |
| `ERC20InvalidSpender(address)` | approve zero spender | Reachable formal; exact zero spender payload |
| `ERC2612ExpiredSignature(uint256)` | expired permit | Reachable formal; exact deadline and nonce rollback |
| `ERC2612InvalidSigner(address,address)` | valid signature from wrong key or replay | Reachable formal; exact signer/owner and rollback |
| `ERC4626ExceededMaxDeposit(address,uint256,uint256)` | pause, incident freeze, or finite cap makes `maxDeposit` smaller | Reachable formal; exact standard error in `test_pauseAndIncidentFreezeMakeMaximaZeroAndBlockDepositMint` |
| `ERC4626ExceededMaxMint(address,uint256,uint256)` | pause, incident freeze, or finite cap makes `maxMint` smaller | Reachable formal; exact standard error in the same property |
| `ERC4626ExceededMaxRedeem(address,uint256,uint256)` | public `redeem` is overridden and always returns `RedeemNotSupported` | Structurally unreachable inherited error |
| `ERC4626ExceededMaxWithdraw(address,uint256,uint256)` | public `withdraw` is overridden and always returns `WithdrawNotSupported` | Structurally unreachable inherited error |
| `EthTransferFailed()` | ETH sweep receiver rejects value | Reachable formal; `test_ethSweepSuccessAndAllFailureBranchesAreAtomic` |
| `FeeOnTransferUnsupported()` | asset delivers less than nominal deposit | Reachable formal; `test_feeOnTransferAssetDepositRevertsAllAccounting` |
| `InsufficientShares(uint256,uint256)` | exit request above caller shares | Reachable formal; exact requested/available payload |
| `InvalidAccountNonce(address,uint256)` | pool has no checked-nonce external path; permit uses `_useNonce` | Structurally unreachable vendor error |
| `InvalidInitialization()` | implementation initialization and proxy reinitialization | Reachable formal; `test_directImplementationAndProxyReinitializationAreLocked`. A distinct exact `ZeroAddress()` witness proves that a nonzero Registry with `usd8()==0` rolls back its failed initializer flag and every binding, then succeeds after `setUsd8`. |
| `InvalidRecipient()` | pool share recipient, exit receiver, or claim recipient is the pool/invalid | Reachable formal across ERC4626/exit/payout properties |
| `InvalidRewardsDuration()` | zero or above maximum duration | Reachable formal; exact no-arg error and rollback |
| `InvalidSweepRecipient(address)` | sweep to pool itself | Reachable formal; exact recipient payload |
| `NoEligibleStakers()` | reward notification with no earning shares | Reachable formal; notification rollback property |
| `NoUnstakeRequest()` | complete without a receipt | Reachable formal; exit failure property |
| `NotBetaMode()` | `_requireBetaMode` is inherited but no pool external function calls it; pool is not UUPS | Structurally unreachable inherited error |
| `NotDefiInsurance(address)` | direct payout call by non-module | Reachable formal; exact caller payload |
| `NotInitializing()` | only internal initializer helpers carry this guard and no external helper is exposed | Structurally unreachable inherited error |
| `NothingToSweep(address)` | no token/ETH surplus | Reachable formal; exact token payload and sweep properties |
| `PayoutExceedsPoolAssets(uint256,uint256)` | claim above active accounted assets | Reachable formal; exact requested/available payload |
| `PoolFrozen()` | explicit incident gate on settlement or unsettled matured completion | Reachable formal; incident/exit properties. Deposit/mint do **not** use this error. |
| `RedeemNotSupported()` | every synchronous `redeem` call | Reachable formal; disabled-exit property |
| `ReentrancyGuardReentrantCall()` | malicious token callback reenters guarded deposit, `completeRedeem`, `payClaim`, `claimReward`, or reward distribution | Reachable formal under adversarial-token boundary; exact four-byte callback returndata and complete one-time outer deltas. `sweepToken` is deliberately unguarded and has the distinct exact post-transfer `NothingToSweep(token)` callback witness documented below. |
| `RewardRateTooHigh()` | blended rate exceeds `uint128` | Reachable formal; exact rollback property |
| `RewardRateZero(uint256,uint256)` | positive distribution rounds rate to zero | Reachable formal; exact total/duration payload |
| `SafeCastOverflowedUintDowncast(uint8,uint256)` | rounded exit epoch exceeds `uint64` | Reachable formal; exact `(64,value)` payload |
| `SafeERC20FailedOperation(address)` | asset/reward/sweep token returns false | Reachable formal under adversarial-token boundary; exact token payload and rollback |
| `UnstakeRequestExists()` | second live exit request | Reachable formal; request rollback property |
| `WithdrawNotSupported()` | every synchronous `withdraw` call | Reachable formal; disabled-exit property |
| `ZeroAddress()` | zero asset/registry binding or zero sweep recipient | Reachable formal; initializer and sweep properties |
| `ZeroAmount()` | zero exit request or zero reward notification | Reachable formal; request/notification properties |

**Error totals:** **35 reachable/formal**, **0 Foundry-only**, **7 structural
unreachable exclusions** = **42 ABI errors**.

The incident deposit/mint branch is pinned to the inherited standard
`ERC4626ExceededMaxDeposit(receiver,assets,0)` and
`ERC4626ExceededMaxMint(receiver,shares,0)` errors. There is no stale
`PoolFrozen` expectation for either entrypoint.

## Current executable families and assumptions

The repaired pool workspace contains **110 Kontrol-shaped scalar properties** and
**16 Foundry-only ordered trace obligations**:

| Family | Count | Principal closure |
|---|---:|---|
| ERC20 / ERC4626 / permit | 21 | independent OZ floor/ceil formulas, exact finite caps, all zero/pool receiver cross-products, all five nonzero three-role `transferFrom` partitions, finite/max allowances, insufficient-balance rollback, independent EIP-712/EIP-5267 and proxy binding |
| Reachable errors / external tokens | 43 | exact ABI bytes and lengths, implementation/proxy initializer locks, zero-USD8 Registry failure plus retryability, and 28 independently solver-selectable scalar token-mode obligations: false, revert, malformed, and no-return success for deposit, mint, complete redeem, claim payout, reward distribution, reward claim, and token sweep, with complete rollback or one-time deltas and callback witnesses |
| First-log events | 6 | Kontrol-supported first application logs |
| Exit queue | 15 | bounded `uint64` accounting, FIFO/multi-epoch/nonfinal/final-dust settlement and reserve conservation |
| Payout | 5 | authority, cap and active-accounting deltas |
| Rewards | 12 | overlap, transfers, zero-earner deferred window, later depositor, settlement and reserve conservation |
| Sweep | 8 | active + withdrawal + reward reserve protection, including same-token additive accounting |
| Ordered traces | 16 | path-specific transaction-wide log prefixes and payloads |

Bounds and trust boundary: successful symbolic asset seeds are at most `uint128`
and the new multi-party settlement identity uses `uint64` deposits; queue examples
are bounded to three epochs/users. The pool-local modeful token has fixed bytecode and models standard, false,
reverting, one-byte malformed and legacy no-return responses. Each token response
for `deposit`, `mint`, `completeRedeem`, `payClaim`, `claimReward`, reward
distribution, and `sweepToken` is an independently selectable scalar property;
no `test_*` candidate sequences multiple response modes. Failure properties pin
both exact returndata length and content plus complete accounting, allowance,
share, and token rollback. Each no-return success property pins the corresponding
one-time state and balance deltas.

Callbacks into each guarded transition prove exact four-byte nested
`ReentrancyGuardReentrantCall()` returndata and one-time outer deltas. The
inherited `sweepToken` path is structurally **not** guarded: the callback token
updates balances before invoking its callback, and the callback is granted a
real Registry admin role, so a same-token nested sweep reaches exact
`NothingToSweep(token)` (full 36-byte payload) against the post-transfer zero
surplus. The outer sweep still transfers exactly once. OpenZeppelin
ERC20/ERC4626/EIP712 code, Keccak, ECDSA recovery, the compiler, Foundry and KEVM
remain trusted. No solver campaign was run and campaign-wide
manifest/accounting was intentionally not updated in this repair.
