# USD8 and Treasury Kontrol proofs

These properties execute the production `USD8`, `Treasury`, `Registry`, and `SharedBase` bytecode through real `ERC1967Proxy` instances under Kontrol/KEVM.

## Pinned environment

- Kontrol: `v1.0.255`
- Solidity: `0.8.28`
- Foundry: `1.7.2-nightly` (`6902a96211da7bcc3d9c4d8e97910ac5c9d5d2c6`)
- EVM schedule: Cancun (`TLOAD`/`TSTORE` required)
- Optimizer runs: `200`
- Foundry profile: `kontrol`

## Scope and claim

The suite contains **255 behavioral properties**:

- **92 USD8 properties** covering initialization and identity, ERC-20 transfers and allowances, Treasury-authorized mint/burn, EIP-2612 permit integration, inherited sweeps, UUPS authorization/compatibility/rollback, named-upgrade state preservation, and emitted logs.
- **163 Treasury properties** covering initialization and views, mint/redeem economics, ACL and pause behavior, protected sweeps, UUPS behavior, strategy curation and flows, reserve valuation, bounded liquidity walks, receiver curation, harvest/distribution, adversarial reserve/strategy/receiver behavior, and emitted logs.
- `TransientStorageSmoke.t.sol` separately proves that Cancun transient storage is active in the selected KEVM schedule.

The accurate claim is:

> Every USD8 and Treasury public transition is covered under the scalar domains, collection bounds, external-contract models, trusted-governance assumptions, pinned bytecode, and Cancun KEVM semantics documented below.

This is not an unconditional proof of arbitrary external contracts, arbitrary future upgrades, cryptographic primitives, compiler correctness, KEVM correctness, or unbounded arrays.

## Property groups

### USD8

- `USD8ERC20.k.sol` — initialization, metadata, transfer/approval/`transferFrom`, aliasing, finite/max allowance, and atomic error paths.
- `USD8Token.k.sol` — symbolic current-Treasury mint/burn authority, exact deltas, endpoint failures, overflow, zero amounts, and authority rotation.
- `USD8Permit.k.sol` — EIP-712 domain, permit field binding, deadlines, replay, nonce isolation/progression, allowance overwrite, and `permit -> transferFrom`.
- `USD8Sweep.k.sol` — ETH/token authorization, self-recipient rejection, standard/no-return/false/revert/malformed token classes, and rollback.
- `USD8Upgrade.k.sol` — UUPS context, beta/timelock gates, candidate compatibility, payable initialization, rollback, and named-V2 preservation.
- `USD8Events.k.sol` — exact emitters, topics, data, and relevant ordering for production-emitted initialization, ERC-20, sweep, permit, and upgrade logs.

The inherited ABI declares `EIP712DomainChanged()`, but the vendored OpenZeppelin implementation contains no path that emits it. It is therefore classified as a structurally non-emitting inherited event, not a missing runtime transition.

### Treasury

- `Treasury.k.sol` and `TreasuryReserveAdversarial.k.sol` — healthy/distressed mint/redeem accounting, rounding, allowance behavior, slippage, reserve tolerance, hostile reserve-transfer classes, callbacks, and nested rollback.
- `TreasuryInitUpgrade.k.sol` — initializer validation, fixed/dynamic topology, getters, full representative-state UUPS rejection/preservation, payable initialization, and rollback.
- `TreasuryAclPause.k.sol` and `TreasurySweep.k.sol` — symbolic authorization, role rotation, pause matrix, protected assets, self-recipient rejection, ETH callbacks, and sweep rollback.
- `TreasuryStrategySet.k.sol` and `TreasuryStrategyFlows.k.sol` — bounded strategy ordering/membership, allocation/withdrawal, reserve sums, short/reverting behavior, and transient reentrancy guards.
- `TreasuryLiquidityWalk.k.sol` — bounded queue order, exact/short/reverting/over-delivery, distressed pulls, exhaustion rollback, and call-indexed valuation drift/failure.
- `TreasuryReceiverSet.k.sol`, `TreasuryHarvestDirect.k.sol`, and `TreasuryHarvestHooks.k.sol` — bounded receiver configuration, buffer arithmetic, weighted rounding/dust, direct/hook delivery, allowance cleanup, callback behavior, and transaction-wide rollback.
- `TreasuryEvents.k.sol` — exact production event emitters, topics, data, and relevant ordering.

## Assumptions and bounds

- Successful reserve-domain quantities generally use `uint64`; successful USD8 amounts and state seeds generally use `uint128`. Rejected-before-arithmetic paths retain full-width values where tractable.
- Strategy and receiver execution is exhaustive for **`N <= 3`**. Production currently has no on-chain collection cap, so no arbitrary-length or gas-liveness claim is made.
- The canonical USDC model is a six-decimal, non-rebasing, no-fee exact-transfer ERC-20. Separate adversarial models cover revert, false return, bounded short transfer, malformed behavior, and one callback attempt; they do not represent arbitrary token bytecode.
- Approved strategies are a trusted-governance boundary. Production does not enforce `strategy.underlying() == USDC`; the suite explicitly characterizes this. Honest-strategy claims assume accurate USDC-denominated valuation and exact-or-revert withdrawal, while separate models cover short, reverting, drifting, lying, and illiquid behavior.
- Profit receivers are curated. Exact-pull, no-pull, partial, revert, direct, hook, and callback modes are modeled. A trusted admin/timelock receiver can mutate configuration and is characterized separately; arbitrary governance-authorized behavior cannot be constrained meaningfully because that authority can reconfigure or upgrade the system.
- UUPS proofs establish authorization, compatibility checks, rollback, and preservation for named reviewed implementations. They cannot prove safety of an arbitrary timelock-selected future implementation.
- Permit proofs execute production digest, deadline, nonce, recovery, and allowance logic. secp256k1 unforgeability, `ecrecover` correctness, Keccak collision resistance, and private-key secrecy remain cryptographic assumptions. Fixed-key malformed/changed-field cases are concrete cryptographic regressions, not universal cryptographic proofs.
- Registry role, pause, topology, and beta behavior use the production Registry proxy. A malicious pre-sunset Registry upgrade or compromised governance remains outside the USD8/Treasury theorem.
- OpenZeppelin, Solidity, Kontrol, KEVM, K, SMT solvers, and the EVM implementation are trusted dependencies rather than independently verified by this suite.

## Reproduction

```bash
source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
export PATH="$HOME/.nix-profile/bin:$PATH"

# One-time install after Nix is configured.
kup install kontrol --version v1.0.255

FOUNDRY_PROFILE=kontrol kontrol build --foundry-project-root . --regen

FOUNDRY_PROFILE=kontrol kontrol prove \
  --foundry-project-root . \
  --match-test 'KontrolTransientStorageSmokeTest.testTransientStorageRoundTrip()' \
  --schedule CANCUN --reinit

FOUNDRY_PROFILE=kontrol kontrol prove \
  --foundry-project-root . \
  --match-test 'USD8ERC20KontrolTest.test_.*' \
  --match-test 'USD8PermitKontrolTest.test_.*' \
  --match-test 'USD8SweepKontrolTest.test_.*' \
  --match-test 'USD8UpgradeKontrolTest.test_.*' \
  --match-test 'USD8TokenKontrolTest.test_.*' \
  --match-test 'USD8EventsKontrolTest.test_.*' \
  --schedule CANCUN --reinit --workers 10 \
  --max-iterations 50000 --xml-test-report \
  --xml-test-report-name usd8-complete-kontrol.xml

FOUNDRY_PROFILE=kontrol kontrol prove \
  --foundry-project-root . \
  --match-test 'Treasury.*KontrolTest.test_.*' \
  --schedule CANCUN --reinit --workers 10 \
  --max-iterations 50000 --xml-test-report \
  --xml-test-report-name treasury-complete-kontrol.xml
```

A property counts only when Kontrol exits successfully and the selected signature appears as passed with zero failed, pending, stuck, timed-out, or admitted branches. Foundry unit/fuzz/invariant tests are complementary evidence, not substitutes for the formal proofs.
