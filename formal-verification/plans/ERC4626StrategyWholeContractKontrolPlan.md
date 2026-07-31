# ERC4626Strategy whole-contract Kontrol property plan

Status: current-source whole-contract **Forge-green candidate specification**. There are **124 conventional `test_*` formal candidates in 6 `*KontrolTest` classes**. Seven camel-named Foundry integration checks are retained outside the approved 915-definition conventional `test_*` inventory. No Kontrol solver campaign has been run, so none of the 124 candidates is solver evidence. Rebuild this matrix if `ERC4626Strategy.sol`, `StrategyBase.sol`, `SharedBase.sol`, an imported dependency, a harness, or the Kontrol profile changes.

## Pinned input inspected

- Production sources and SHA-256:
  - `src/strategies/ERC4626Strategy.sol`: `7e51d6fe0acbdf3704f6676b54b6ad30b976d89fea673e31435c71ba23cf490c`
  - `src/strategies/StrategyBase.sol`: `91db1df08ca5de9978a2196e05fb60534e6da61d49be7233c23b7f0bbda8c84a`
  - `src/SharedBase.sol`: `a916198847e8340da12555ee1430f8bc6328630435b1cb4dd27b7d7e839b00ce`
  - `foundry.toml`: `076e5778688f7a7e1bbb8496e1b211925ba5882b02aba7542f4676fc5206057d`
- Compiled with `FOUNDRY_PROFILE=kontrol`, Solidity 0.8.28, Cancun, optimizer runs 1.
- Final compiled surface: **12 functions** = 7 view and 5 nonpayable; **6 events**; **21 errors**. There is no receive/fallback, initializer, proxy, upgrade, payable ABI method, dynamic collection, or production loop.
- Canonical sorted compact ABI SHA-256: `070db212ad57d4c52f35f9541fc7851c8cff61bf5cb414d999845e3f0dd5f729`.
- Unlinked creation bytecode: 6,810 bytes, SHA-256 `da8e29052cdb90da6339be323db95de14e58f466fb632334e65f7544e8b5488a`.
- Unlinked deployed bytecode: 5,456 bytes, SHA-256 `92361982b8f185668a4eeeadc37d64abff0f6223474c03a39ba25524310b0fbe`.
- Compiler storage layout is empty because the contract's ordinary values are immutables; the fixed Registry pointer is stored through the inherited ERC-7201 assembly namespace. The inherited reentrancy guard uses transient storage.
- Fixed-bytecode state-selectable models live in `ERC4626StrategyHarness.k.sol` and `ERC4626StrategyAdversarialHarness.k.sol`; scalar current-source closure properties live in `ERC4626StrategyCurrentSourceClosure.k.sol`.

Labels: `[U]` full declared scalar domain; `[B:...]` explicit operational bound; `[C:model]` compositional under a named external model; `[R]` Foundry-only concrete/integration requirement.

## Important concrete-contract facts

1. For this derived contract, `strategyToken == USDC` under the required transaction-stable Treasury model. Consequently the generic base direction `USDC -> strategyToken` always has identical input/output and is rejected. The only successful `swap` family is a distinct, non-position token into USDC, with all output sent to Treasury.
2. `deploy`, `withdraw`, `swap`, and both sweep methods are **not pause-gated**. Pausing this strategy in Registry does not itself block them. This must be characterized and accepted as intent; do not silently add a `whenNotPaused` premise.
3. `deploy` and `withdraw` are not `nonReentrant`; their primary boundary is exact Treasury caller identity. `swap` alone uses `ReentrancyGuardTransient`.
4. `sweepToken` inherits the fail-closed default `_sweepable(...) == 0`; ERC4626Strategy does not override it. Every authorized call with a valid recipient reverts `NothingToSweep(token)`, regardless of token balance. `TokenSwept` is therefore a structural non-emission event for this final bytecode.
5. Current source raises `WithdrawShort` only when `received < requested`; over-delivery succeeds and emits the measured `received`. Earlier plan text describing `received != requested` was stale.
6. The deposit guard checks actual position-value delta, not the vault's returned share count except for `shares != 0`. Its exact accepted condition is `shares > 0`, post-value does not fall below pre-value, arithmetic does not overflow, and `received + convertToAssets(1) + 1 >= amount`.

## Final selector / branch / property-family matrix

The selector rows are implemented by the four original property families plus `ERC4626StrategyCurrentSourceClosure.k.sol`; external modes use fixed bytecode with state-selectable behavior. Event/order rows are implemented by `regressions/ERC4626StrategyEvents.t.sol`. Every `test_*` entry is a solver candidate only until an accepted Kontrol report exists.

| Proposed family | Compiled selector | Exact obligations / branches | Event obligation |
|---|---|---|---|
| `ERC4626StrategyConstructionViews.k.sol` | constructor | `[C:treasury,vault,USDC]` Deploy through an external factory and assert exact immutable wiring, Registry namespace, fixed-vault identity, `strategyToken == USDC`, and unlimited vault allowance. Cover Treasury zero/no-code/revert/malformed `USDC()` response, first/second reserve response zero, Registry zero, vault zero, vault `asset()` no-code/revert/malformed, exact asset mismatch, USDC approve false/no-return/revert/zero-first token behavior, and total atomic failure. Do not assume `_treasury==0` reaches `ZeroAddress`: the derived base-argument `USDC()` call is evaluated first; probe and pin the actual low-level revert shape. Require transaction-stable Treasury `USDC()` or explicitly characterize differing first/second responses. Address aliases are listed below. | `RegistryChanged(0,registry)` is the first declared production log before the final USDC approval under silent static-call models and is Kontrol-tractable. Full constructor sequence and exact approval log(s) are `[R]`. |
| `ERC4626StrategyConstructionViews.k.sol` | `89a30271 USDC()`, `747efea1 strategyToken()`, `61d027b3 treasury()`, `fbfa77cf vault()`, `7b103999 registry()`, `6f307dc3 underlying()` | `[U]` Exact immutable/namespace values after successful construction, `underlying == USDC`, `strategyToken == USDC` under the stable-Treasury premise, and repeated reads have no state/log effects. Registry upgrades may change Registry behavior but cannot repoint the stored proxy address. | No log. |
| `ERC4626StrategyValuation.k.sol` | `01e1d114 totalAssets()` | `[U:uint256 shares/assets, shares < max, assets <= max-17][C:vault]` Exact composition `vault.convertToAssets(vault.balanceOf(strategy))` including both zero endpoints and the full-width bounded domain needed to keep model setup plus the independent 17-unit loose-USDC seed overflow-free; no loose-USDC inclusion; external balance/convert revert, no-code, malformed returndata, and arithmetic behavior bubble with observed exact bytes and do not mutate strategy state. Include donation/appreciation/loss-rate states and show that share-count preservation alone does not imply value preservation. | No log. |
| `ERC4626StrategyDeploy.k.sol` | `a5e38751 deploy(uint256)` | `[U]` symbolic outsider distinct from Treasury gets exact `UnauthorizedTreasury(caller)` before any vault call and all balances/allowances/shares remain unchanged. `[B:uint128 state/amount][C:stateful vault,standard USDC]` Treasury success from nonempty position: exact asset/share/position-value/loose-USDC deltas under the standard vault model; zero and positive amount; share-price and rounding states; exact acceptance boundary independently derived as `amount = oneShareValue + 1`, with `received == 0` and `received+tolerance == amount`; one-unit failing boundary; unrelated holder/balance preservation. Cover deposit return zero, positive return with no actual minted balance, exact/short/over value, post-value below pre-value (Panic underflow), `convertToAssets(1)==uint256.max` (Panic), `received+tolerance` overflow, deposit/balance/convert revert or malformed data, insufficient USDC, transferFrom false/no-return/malformed/revert, and atomic rollback of vault/token state and constructor allowance. Explicitly characterize the externally controlled tolerance and the case where a large one-share value permits a correspondingly large shortfall. Prove paused Registry state does not block the Treasury path. | `Deployed(amount)` occurs after exact standard token/vault prefix logs and is `[R]` for exact endpoints, topics, data, payload, and order under pinned Kontrol. No log survives failure. |
| `ERC4626StrategyWithdraw.k.sol` | `2e1a7d4d withdraw(uint256)` | `[U]` outsider exact unauthorized + no external call/state change. `[B:uint128 state/amount][C:stateful vault,standard USDC]` Treasury zero/partial/full withdrawal; Treasury balance increase is at least the requested amount; exact share burn/assets delta under the model; unrelated balances unchanged. Cover insufficient liquidity/shares, vault revert/no-code/malformed return, short and zero delivery, successful over-delivery, Treasury balance decrease during call (Panic underflow), transfer-fee-equivalent short delivery, negative and positive post-balance report/rebase drift, and post-call balanceOf failure. Every failed path asserts exact returndata and rolls back vault share burn, transfers, Treasury/strategy/vault balances, and logs. Positive report drift is characterized honestly: a phantom one-unit over-report can pass while actual delivery is only requested. Prove paused Registry state does not block it. | `Withdrawn(received)` follows exact vault-share/token/vault prefix logs and is `[R]` for exact endpoints, topics, data, measured payload, and order. No log survives failure. |
| `ERC4626StrategySwapAclPairs.k.sol` | `8e1484b9 swap(address,address,uint256,address,address,bytes,uint256)` | `[C:Registry]` Current admin and timelock succeed; fixed outsider gets exact Registry `UnauthorizedAdmin(caller)`; removal/rotation applies immediately; ACL check precedes every local validation. Amount zero, min output zero, and both zero produce `ZeroAmount`. Route approval is keyed to the exact `(target,spender)` and is checked before pair/protection validation. For final ERC4626Strategy bytecode, exhaustively partition pair identities: only `tokenOut==USDC`, `tokenIn!=USDC`, and `tokenIn!=vault` may proceed; same token, `USDC->USDC`, non-USDC output, and reward->vault fail with exact `UnsupportedSwapPair` or `ProtectedSwapAsset` according to source order. Separately cover target and spender equal to USDC or vault, target/spender distinct/aliased, and tokenIn equal to vault. Prove Registry pause does not gate swap. | No strategy log before execution succeeds. |
| `ERC4626StrategySwapExecution.k.sol` | same | `[B:uint128 balances/amounts; fixed encoded route][C:router,tokens,vault]` Approved exact-output success from nonempty prestates: temporary approval is exactly `amountIn`, router may consume at most the modeled amount, allowance ends at zero, preexisting USDC remains in strategy, exact output delta is sent to Treasury, principal share balance is nondecreasing, return value equals measured output, and unrelated balances/allowances remain unchanged. Cover output exactly at min, above min, below min, zero, and output-balance decrease (Panic underflow); router no-code, empty/nonempty revert, malformed route; target/spender split; forceApprove false/malformed/revert and no-return success; input transferFrom false/no-return/malformed/revert; USDT-style zero-first behavior; router consumes none/partial/full input; reset-approval failure; finite and infinite original allowance restoration after a later route failure; principal share decrease/equality/increase; USDC transfer false/no-return/malformed/revert; token balanceOf revert/malformed/drift; and exact rollback for every failure including allowance, router transfers, principal and transient guard. Each return mode is a scalar one-transition candidate. | `TokenSwapped` is after exact approval/router/output/reset/Treasury-transfer prefix logs; exact endpoints, topics, data, occurrence, payload, and order are `[R]`. |
| `ERC4626StrategySwapCallbacks.k.sol` | same | `[C:callback router/Registry]` Execute real Cancun `TSTORE/TLOAD`. An approved router that is itself a live admin/timelock and reenters `swap` must get exact `ReentrancyGuardReentrantCall`, outer behavior following the selected catch/bubble mode, and the guard must be cleared after success and revert. Characterize callbacks to unguarded views/sweeps. Separately model or explicitly assume away a route that calls Treasury and causes Treasury to reenter `deploy`/`withdraw`; those methods have no local guard, and `_isProtectedCallTarget` does not protect `treasury`. Also show protecting target/spender addresses does not stop an approved router from making downstream calls to the vault. Do not claim principal-value safety from the share-count-only `PrincipalDecreased` check. | Callback/router logs make complete order `[R]`; state theorem must not depend on unsupported later-log expectations. |
| `ERC4626StrategySweep.k.sol` | `1163b2b0 sweepETH(address)` | `[U][C:Registry,ETH receiver]` Current admin/timelock success for positive balance and non-self nonzero recipient; exact full-balance transfer and strategy balance zero. Outsider rejection precedes recipient/balance checks; zero recipient, self recipient, zero balance, rejecting receiver, and callback receiver give exact errors and atomic rollback. Include forced ETH because no payable receive/fallback exists. Prove pause does not gate sweep. | With an EOA/silent receiver, exact `ETHSwept(to,amount)` is the first log and Kontrol-tractable. Receiver-callback log order is `[R]`. |
| `ERC4626StrategySweep.k.sol` | `258836fe sweepToken(address,address)` | `[U][C:Registry]` Outsider ACL failure first. For an authorized caller, zero recipient and self recipient errors precede `_sweepable`; every other recipient and every token address (zero, USDC, vault shares, reward, no-code, strategy itself) reverts exact `NothingToSweep(token)` without calling token code or moving balances. Prove donated/mistaken tokens remain stuck in this final contract. Pause does not gate it. | `TokenSwept` is a structural non-emission exclusion for ERC4626Strategy. |

## Constructor and address-alias partitions

Use fixed nonzero representatives for Treasury, Registry, USDC, vault, admin, timelock, outsider, router, spender, reward token, and recipient. This is sound only where behavior depends on equality and the named external model. Add explicit partitions for:

- every externally supplied constructor address at zero;
- `vault == USDC` (a hybrid self-asset contract is not explicitly forbidden), `vault == treasury`, `registry == treasury`, and Registry/vault/token aliases that change call behavior;
- first and second Treasury `USDC()` responses equal (production premise), unequal, and either zero;
- admin == timelock, router == spender, tokenIn == target/spender, recipient == strategy, and recipient == zero;
- vault/USDC/Treasury/router contracts with no code, reverting fallback, or malformed returndata.

The deployment/configuration claim should require distinct, code-bearing production Treasury/Registry/USDC/vault addresses and a transaction-stable Treasury reserve response. If alias deployments are intentionally unsupported, prove only their observed rejection where production enforces one; otherwise label them excluded governance misconfiguration, not impossible states.

## External model design

### Treasury reserve model

Concrete helper bytecode implements `USDC()` with exact valid, zero, revert, empty, short, and long returndata modes. The normal model returns the same nonzero token on both constructor static calls. A separate adversarial model documents that gas/call-context-dependent view responses can make `strategyToken` differ from `USDC`; no universal equality claim may omit the stability premise. A callback-capable Treasury/router composition is needed for the unguarded cross-function boundary.

### Registry model

Prefer the Forge-covered production Registry proxy for representative ACL/rotation tests; otherwise use a concrete summary implementing exact `requireAdminOrTimelock(caller)` and `approvedSwapRoute(target,spender)` behavior, including revert/malformed/no-code modes. Model current timelock, finite admin set, outsider, role overlap, immediate removal/rotation, exact route pair, and paused state. Do not summarize the Strategy transition itself.

### Standard USDC and generic input-token models

The standard successful model has exact, non-rebasing balances; exact allowance semantics; standard/no-return success variants; no transfer fees; and no ERC-777/1363 callbacks. Adversarial modes cover false return, revert with/without data, malformed returndata, no code, USDT-style zero-before-nonzero approval, balance decreases/drift, fee/over-transfer, and callback. Keep constructor vault allowance and operational router allowance independent. Successful accounting claims are compositional under exact-transfer/no-rebase behavior.

### Stateful ERC-4626 vault model

Use concrete, fixed helper bytecode with state variables for total modeled assets, total shares, strategy shares, and liquidity. Avoid symbolic constructor bytecode. Implement real `balanceOf`, `convertToAssets`, `deposit`, and `withdraw` behavior so call results depend on observable state rather than unsupported call-indexed `mockCalls`.

Required modes:

1. conforming zero/nonzero initial state with floor deposit and ceil withdrawal rounding;
2. appreciated/donated and loss states;
3. exact, zero, short, and lying deposit return/share mint;
4. deposit fee/value shortfall and share-granularity equality endpoint;
5. exact, under-, and over-delivery withdrawal; insufficient liquidity/shares;
6. revert, empty/short/malformed returndata, no code;
7. balance/valuation drift between precheck, deposit/withdraw, postcheck, and tolerance call;
8. callback/bubbled-callback variants and arbitrary external logs.

The normal theorem assumes transaction-stable conversion semantics except for the modeled deposit/withdraw state transition. A bounded model cannot establish correctness against arbitrary ERC-4626 implementations, fees, rebases, delayed withdrawals, or dishonest views.

### Router model

Use a concrete named swap function and fixed ABI-encoded route. Modes: exact/low/zero/over output, no input consumption, partial/full input consumption, revert empty/nonempty, output balance depletion, vault-share decrease/equality/increase, approval-reset interference, arbitrary log, reentrant swap, and Treasury-mediated `deploy`/`withdraw` callback. Route approval proves only target/spender curation; it is not a semantic guarantee about arbitrary calldata or downstream calls.

### ETH receiver model

EOA/silent receiver, accepting contract, rejecting contract, log-emitting receiver, and callback receiver. Callback trace depth is one for formal properties; longer arbitrary behavior remains outside the bounded model.

## Arithmetic, trace, and environment bounds

1. Keep authorization and zero/prevalidation rejection paths full-width `[U]` because no arithmetic is reached.
2. Use `uint128` for successful token balances, shares, assets, amounts, output, and independent nonempty seeds. State explicit sum constraints so model setup and expected deltas cannot overflow. Keep separate full-width properties for each production underflow/overflow branch.
3. Bound conversion-model numerators/denominators so its own arithmetic cannot overflow; this is a model bound, not a production cap. Exercise `convertToAssets(1)` at 0, 1, representative large values, and `uint256.max` in dedicated properties.
4. Use a fixed ABI-encoded router call for symbolic accounting properties. Bound arbitrary malformed route bytes to a small explicit length only for regression/dispatch cases; do not describe this as proof over arbitrary aggregator calldata semantics.
5. One-transition properties are the primary proof unit. Add only bounded lifecycle traces of at most three productive steps: deploy -> donation/loss -> partial/full withdraw, and swap success -> swap failure -> retry, to prove allowance/guard cleanup.
6. No collection/loop bound is needed in production bytecode. External helper implementations must also avoid unbounded loops.
7. Use fixed address representatives plus the explicit alias partitions above; preserve symbolic callers only where callback code/balance matters.
8. Pin Cancun and retain the independent transient-storage smoke proof. A Forge pass does not replace the `TLOAD/TSTORE` Kontrol environment gate.
9. Pinned Kontrol's single `expectEmit` model proves only a first transaction-wide log. Later strategy events remain Foundry-only as listed below.

## Event and order closure (compiled ABI: 6/6)

| Compiled event | Emitting path | Engine / exact requirement |
|---|---|---|
| `RegistryChanged(address,address)` | successful constructor `_setRegistry` | Kontrol can prove exact first log `RegistryChanged(0,registry)` under silent Treasury calls. `[R]` verifies complete constructor sequence and emitter. |
| `Deployed(uint256)` | successful `deploy` | `[R]` exact emitter/data, occurrence after all standard vault deposit logs, and absence on all reverted deposits. It is a later log under a conforming ERC-4626/token model. |
| `Withdrawn(uint256)` | successful `withdraw` | `[R]` exact emitter/data (`received >= requested`), occurrence after vault withdrawal logs, and absence on revert. |
| `TokenSwapped(address,address,address,uint256,uint256)` | successful `swap` | `[R]` exact indexed tokenIn/tokenOut/target, data amountIn/measured amountOut, occurrence after input approval/router/output/reset/Treasury-transfer logs, and absence on revert. |
| `ETHSwept(address,uint256)` | successful `sweepETH` | Kontrol first-log theorem for EOA/silent receiver. `[R]` verifies receiver-log-before-ETHSwept order for a log-emitting receiver and exact callback behavior. |
| `TokenSwept(address,address,uint256)` | none in final ERC4626Strategy bytecode | Structural non-emission exclusion because inherited `_sweepable` always returns zero. Do not fabricate a success/event property. |

Dedicated Foundry-only order regressions must count these distinct obligations rather than being called “complementary” to state proofs:

1. **Constructor order (standard token):** exact `RegistryChanged(0,registry)` precedes exact USDC `Approval(strategy,vault,max)`. No USDT zero-first fallback sequence is claimed because constructor setup starts from zero allowance.
2. **Standard deposit order:** USDC `Transfer(strategy,vault,assets)`, vault-share `Transfer(0,strategy,shares)`, vault `Deposit(strategy,strategy,assets,shares)`, then strategy `Deployed(assets)`.
3. **Standard withdrawal order:** vault-share `Transfer(strategy,0,shares)`, USDC `Transfer(vault,treasury,assets)`, vault `Withdraw(strategy,treasury,strategy,assets,shares)`, then strategy `Withdrawn(assets)`.
4. **Standard swap order:** exact temporary input-token approval, input `Transfer(strategy,router,amountIn)`, output `Transfer(0,strategy,amountOut)`, exact router log data, exact reset approval, USDC `Transfer(strategy,treasury,amountOut)`, then strategy `TokenSwapped(...)`, with every emitter, indexed endpoint, amount, and data word asserted.
   Router-internal arbitrary logs must not be abstracted into a universal fixed order claim.
5. **ETH receiver order:** a receiver fallback log occurs before `ETHSwept`; the EOA/silent-receiver first-log theorem is a separate Kontrol obligation.

These are model-specific integration orders, not universal ERC-20/ERC-4626 requirements. Exact strategy-event occurrence/payload remains required even if an external implementation emits a different prefix.

## Compiled-error closure

- Directly reachable and requiring exact selector/payload properties: `DepositValueShort`, `EthTransferFailed`, `InsufficientSwapOutput`, `InvalidSweepRecipient`, `NothingToSweep`, `PrincipalDecreased`, `ProtectedSwapAsset`, `ReentrancyGuardReentrantCall`, `SwapRouteNotApproved`, `UnauthorizedTreasury`, `UnsupportedSwapPair`, `VaultAssetMismatch`, `WithdrawShort`, `ZeroAddress`, `ZeroAmount`, and `ZeroSharesMinted`.
- External-library branches requiring explicit models: `AddressEmptyCode` and `FailedCall` from router dispatch; `SafeERC20FailedOperation` from token operations. External revert data may also bubble unchanged and must be characterized separately.
- Structural exclusions in this final bytecode: `InsufficientBalance` from `Address.functionCallWithValue` is unreachable because swap always calls with zero value; `NotBetaMode` is inherited ABI metadata with no beta-only entrypoint. Do not invent runtime properties for them.
- Arithmetic panic branches are not listed as custom ABI errors but are obligations: deploy post-value underflow, tolerance `+1` overflow, received-plus-tolerance overflow, withdraw Treasury-balance underflow, and swap output-balance underflow.

## Current executable evidence and remaining proof status

Executed with `FOUNDRY_PROFILE=kontrol` and exact `FOUNDRY_TEST` isolation:

- Formal-candidate families: **124/124 passed** = Construction/views 7, deploy/withdraw 10, swap 21, sweep 13, and current-source external/swap modes 73.
- Out-of-inventory integration checks: **7/7 passed** = constructor order, deploy order, standard withdrawal order, overdelivery measured withdrawal order, swap order, ETH receiver order, and failed symbolic token-sweep no-log behavior. These camel-named checks are not included in the approved 915 conventional `test_*` definitions or the 74-definition non-Kontrol difference.
- TDD evidence: a deliberate wrong share-balance assertion in the positive-return/no-shares exact-boundary property failed at runtime, then the corrected assertion passed.
- Solver evidence: **0/124**. No solver, XML report, campaign manifest, or transient-storage proof was run in this task.

The machine-readable closure inventory is `plans/ERC4626StrategyAbiMatrix.json`: **2 formal-first-log + 3 Foundry-later-log + 1 structural event = 6**, and **19 reachable/external/preempted + 2 structural errors = 21**. Validate name-union equality against the compiled ABI with:

```bash
python3 - <<'PY'
import json
artifact=json.load(open('formal-verification/out/ERC4626Strategy.sol/ERC4626Strategy.json'))['abi']
matrix=json.load(open('formal-verification/plans/ERC4626StrategyAbiMatrix.json'))
for kind,key in [('event','events'),('error','errors')]:
    abi={x['name'] for x in artifact if x['type']==kind}
    planned={x['signature'].split('(')[0] for x in matrix[key]}
    assert abi == planned, (kind, sorted(abi-planned), sorted(planned-abi))
print('ABI matrix exact: 6 events / 21 errors')
PY
```

### Published assumptions / characterizations

1. Successful token accounting assumes exact, non-rebasing ERC-20 behavior; false, no-return, malformed, revert, and USDT zero-first schedules are separate fixed-bytecode partitions.
2. Successful vault accounting assumes the named synchronous ERC-4626 model. Fee/rebase/drift, dishonest return values, balance decreases, and malformed/reverting calls are characterized as separate partitions, not asserted away.
3. Treasury `USDC()` is assumed transaction-stable on successful construction. Fixed response modes cover zero/revert/empty/short/noncanonical data; call-index-dependent differing valid responses remain a governance/external-view stability boundary because `STATICCALL` cannot mutate an occurrence counter.
4. Route approval is only `(target,spender)` curation. It does not prevent a distinct router from calling the vault or Treasury, nor Treasury-mediated callbacks into unguarded deploy/withdraw. The executable properties demonstrate deploy success, withdrawal rollback through `PrincipalDecreased`, and ETH-sweep callback reachability.
5. Swap protects share count, not share value. A route can leave shares unchanged while destroying vault assets; that value-loss characterization is executable and GREEN.
6. Token sweeping is permanently fail-closed in this final bytecode. `TokenSwept` is structurally non-emitting; exact no-log behavior is Foundry-only while the token address and exact `NothingToSweep(token)` payload are symbolic formal candidates.
7. Successful multi-value arithmetic candidates use `uint128` values where noted. `totalAssets` separately uses `uint256` inputs including zero with `shares < max` and `assets <= max-17`, the minimal model-setup bounds that avoid virtual-share and loose-seed overflow. Dedicated underflow/overflow properties exercise the full-width panic endpoints.
8. Callback traces are bounded to one nested callback. Arbitrary recursive external behavior is outside the model.

## Tractable implementation and acceptance order

1. Re-hash the three production sources and imported dependency set; rebuild with `FOUNDRY_PROFILE=kontrol`; re-diff the 12-selector/6-event/21-error inventory and bytecode hashes.
2. Implement `ConstructionViews` and `Valuation`, then `Deploy`, `Withdraw`, `SwapAclPairs`, `SwapExecution`, `SwapCallbacks`, and `Sweep`. Constructor/token/vault return modes and malformed/revert schedules are split into scalar one-transition candidates; only the explicitly bounded cleanup lifecycles remain multi-transition.
3. Add separate Foundry event-order regressions for the five `[R]` requirements; keep their class/path out of Kontrol selection. Count `TokenSwept` as a structural exclusion, not a regression or formal pass.
4. For every family, run a deliberate behavioral RED mutant/counterexample, then isolated Forge GREEN under `FOUNDRY_PROFILE=kontrol FOUNDRY_TEST=<exact file>`. A compiler failure is not RED evidence.
5. Resolve the requirements/model decisions before solver launch: pause semantics, permanently fail-closed token sweeping, stable Treasury reserve response/distinct deployment addresses, exact-transfer/no-rebase token premise, vault stability/fee premise, and approved-router/downstream-callback trust.
6. Freeze production and property inputs. Run the independent Cancun transient-storage smoke proof, then one representative constructor/external model/event/callback signature before broad families. Use exact compiled signatures and separate clean XML reports.
7. Closure requires 12/12 selectors assigned, constructor assigned, 6/6 compiled events assigned, 21/21 compiled errors reachable-or-excluded, every arithmetic panic branch assigned, zero failed/pending/timed-out/admitted selected proofs, separate Foundry-only requirement counts, and source/ABI/bytecode/tool/report provenance bound to one immutable snapshot.

Honest final claim:

> All ERC4626Strategy public transitions and constructor branches are covered under the published scalar domains, trace bounds, external Treasury/Registry/ERC-20/ERC-4626/router/receiver summaries, trusted route-governance assumptions, pinned compiler/Kontrol versions, and Cancun schedule; complete later-log presence/order remains Foundry-only where listed.
