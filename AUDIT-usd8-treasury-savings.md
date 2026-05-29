# Security Review — USD8.sol, Treasury.sol, SavingsUSD8.sol

Scope: `usd8core/src/USD8.sol`, `Treasury.sol`, `SavingsUSD8.sol` (+ interfaces). Solidity 0.8.28, OZ v5 (upgradeable for USD8). Reviewed manually for access control, accounting/peg, ERC4626 share math, reentrancy, and privilege design.

Overall the code is well-documented and the obvious traps (reentrancy guards, CEI ordering, peg rounding to the protocol's favor, unvested-profit-kept-idle to avoid `totalAssets` underflow, zero-address checks, `_disableInitializers`) are already handled. The findings below are the things that actually matter.

---

## H-1 — `strategyManager` can drain all idle funds (privilege/trust model)

**Treasury.sol** `addStrategy`, `depositToStrategy`, `removeStrategy`, and **SavingsUSD8.sol** the same functions, are all gated by `onlyStrategyOrAdmin` — i.e. the **strategyManager** role, not just admin.

A strategy fully controls (a) the USDC/USD8 pushed into it via `depositToStrategy` and (b) the value it reports through `totalAssets()`, which `getReserveBalance()` / `_rawAssets()` trust without verification. So a malicious or compromised `strategyManager` can:

1. `addStrategy(S)` where `S` is attacker-controlled and `S.underlying()` returns USDC/USD8 (the only check in `addStrategy`).
2. `depositToStrategy(S, <all idle>)` — funds are `safeTransfer`'d to `S` before `S.deploy()` is even called, so they are gone immediately. `depositToStrategy` is not covered by `reserveSupplyStatusCheck`.
3. Have `S.totalAssets()` keep reporting the balance so `getReserveBalance()` looks healthy until the attacker stops.

Net: the `strategyManager` has the same custody power as `admin` over all deployable reserve. The docs frame `strategyManager` as a narrower "manage strategies" role, which understates the actual blast radius.

Recommendation: either document explicitly that `strategyManager` is fully trusted with custody, or restrict `addStrategy` / `depositToStrategy` to `admin` (a timelock) and leave only `withdrawFromStrategy` to the manager. Consider a whitelist/registry of vetted strategy implementations.

## H-2 / M-1 — First-depositor inflation ("donation") attack on SavingsUSD8

`SavingsUSD8` extends OZ `ERC4626` but does **not** override `_decimalsOffset()` (defaults to 0) and does not seed dead shares at deploy. OZ's +1 virtual offset reduces but does not eliminate the classic attack when the vault is empty or near-empty:

- Attacker mints 1 wei → 1 share, then transfers a large amount of USD8 directly to the vault (allowed — `rescueToken` protects the asset, direct donations are intended to accrue to share price).
- `totalAssets` jumps; a subsequent honest `deposit` of `V < ~totalAssets/2` rounds to **0 shares** and the depositor loses the funds. OZ `_deposit` does not revert on 0 shares, and `sharePriceInvariant` does not catch it (share price *rises*, so the modifier passes).

The `NoDepositors` guard on `receiveProfitDistribution` only blocks the profit path — it does **not** block direct token donations, which is the actual attack vector.

Recommendation: override `_decimalsOffset()` to return ~6 (cheap, strong mitigation), and/or seed a non-trivial initial deposit of dead shares at deployment, and/or add a minimum-shares-out check / revert-on-zero-shares in `deposit`/`mint`.

## L-1 — Single-step admin transfer across all three contracts

`USD8.setAdmin`, `Treasury.setAdmin`, `SavingsUSD8.setAdmin` (and the strategy-manager setters) are single-step with only a zero-address check. A typo'd address with code/no key permanently bricks upgrade authority (USD8), pausing, harvesting, and strategy management. Given `admin` is "expected to be a governance timelock," a fat-finger is the realistic risk.

Recommendation: use a two-step (propose/accept) transfer, e.g. OZ `Ownable2Step` pattern.

## L-2 — `msg.sender` vs `_msgSender()` inconsistency in USD8

`onlyAdmin` uses `msg.sender`; `onlyTreasury` uses `_msgSender()`. No exploit today (no ERC-2771 forwarder is wired), but the inconsistency is a latent footgun if a trusted forwarder is ever added — admin checks would not honor it while treasury checks would. Pick one (`msg.sender` is correct here since meta-tx are not intended).

## L-3 — Unbounded `strategies` / `revenueRecipients` arrays

No on-chain cap. `getReserveBalance()`/`_rawAssets()` are called twice per mint/redeem and loop every strategy with an external call; `_ensureIdle*` and `_findStrategy` also loop. A large list (or one strategy whose `totalAssets()` is gas-heavy or reverts) can make core user flows revert (griefing/DoS). Documented as "admin keeps it <10," but it is admin/manager-enforced only.

Recommendation: enforce a hard cap in `addStrategy`/`addRevenueRecipient`.

---

## Notes / accepted-by-design (verified, not flagging)

- **`totalAssets` underflow** (`_rawAssets() - _unvestedProfit()`): defended. `depositToStrategy` is capped at `maxDeployableToStrategy()` and `_withdraw` keeps `unvested` idle, so `_rawAssets() >= _unvestedProfit()` holds even under strategy loss or force-removal. Correct.
- **Peg rounding** in `redeemUSD8`: `usdcAmount` rounds down, surplus always accrues to the Treasury; `reserveSupplyStatusCheck` confirms surplus/ratio cannot worsen. Correct.
- **Pro-rata distressed redemption**: equal haircut for all redeemers, no first-mover advantage. Correct.
- **`receiveProfitDistribution`** CEI ordering and weighted-average vesting: dust cannot materially extend the schedule; permissionless donation is safe. OK.
- **`distributeRevenue` allowance-delta check**: robustly verifies the receiver pulled exactly `amount` and resets approval to 0. OK.
- **Reentrancy**: all user entry points and fund-moving admin functions are `nonReentrant` (transient guard); strategy `withdraw` callbacks are the only reentry surface and are guarded. OK — assuming strategies are trusted (see H-1).
- **Force `removeStrategy`** orphaning funds / dropping share price: documented danger, admin/manager only (overlaps H-1).

---

### Priority

1. Decide the `strategyManager` trust model (H-1) — biggest real-world exposure.
2. Harden the ERC4626 vault against the inflation attack (H-2) before any TVL.
3. Two-step admin transfers (L-1).

These are findings from manual review only; recommend also running Slither/Foundry invariant + fork tests, and a dedicated review of CoverPool.sol (out of scope here).
