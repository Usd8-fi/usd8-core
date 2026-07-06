// All chain reads. Plain read-only RPC calls against a public archive node.

import { createPublicClient, http, parseAbi, parseAbiItem, type PublicClient } from "viem";
import { CONFIG } from "./config.js";

export const WAD = 10n ** 18n;
export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

// DefiInsurance surface: incidents, per-token config, global settlement params.
// The per-incident config is NOT snapshot on-chain — it is reconstructed by
// reading these at the incident's openBlock (see {incidentConfigOf}).
export const DEFI_ABI = parseAbi([
  "function incidents(uint256) view returns (address insuredToken, uint64 claimWindowEndTime, bytes32 root, uint256 unresolved, uint64 rootSubmittedAt, uint64 referenceBlock, uint64 openBlock, bool closed)",
  "function getInsuredToken(address) view returns ((uint256 maxCoverageBps, address underlyingPriceOracle, address underlyingConversionAddress, bytes underlyingConversionCallData))",
  "function settlementParams() view returns (uint64 twapLookbackBlocks, uint64 holdingMarginBlocks, uint64 sampleStepBlocks)",
]);

// Registry surface: topology (pool set), scored tokens, booster collection.
export const REGISTRY_ABI = parseAbi([
  "function pools() view returns (address[] assets, address[] poolAddrs)",
  "function poolsLength() view returns (uint256)",
  "function getScoredTokens() view returns ((address token, uint128 scorePerTokenPerBlock, uint64 startBlock)[])",
  "function boosterNFT() view returns (address)",
  "function maxPayoutBps() view returns (uint256)",
]);

// SingleAssetCoverPool surface: per-pool asset + valuation.
export const POOL_ABI = parseAbi([
  "function asset() view returns (address)",
  "function totalAssets() view returns (uint256)",
]);

export const CLAIM_REGISTERED = parseAbiItem(
  "event ClaimRegistered(uint256 indexed claimId, uint256 indexed incidentId, address indexed user, uint128 insuredTokenAmount, uint256 scoreToSpend, uint256 boosterAmount)"
);
export const CLAIM_CANCELLED = parseAbiItem("event ClaimCancelled(uint256 indexed claimId, address indexed user)");
// The spent-score ledger is this event, summed per user (no on-chain state).
export const SCORE_SPENT = parseAbiItem(
  "event ScoreSpent(address indexed user, uint256 amount, uint256 indexed incidentId)"
);
// Payout-module history: enumerates every module ever registered so ScoreSpent
// logs can be summed across all of them.
export const PAYOUT_MODULE_SET = parseAbiItem(
  "event PayoutModuleSet(address indexed oldModule, address indexed newModule)"
);
export const ERC20_TRANSFER = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 value)");
export const ERC1155_TRANSFER_SINGLE = parseAbiItem(
  "event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value)"
);
export const ERC1155_TRANSFER_BATCH = parseAbiItem(
  "event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values)"
);

const FEED_ABI = parseAbi([
  "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
  "function decimals() view returns (uint8)",
]);
const ERC20_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
]);
const ERC1155_ABI = parseAbi(["function balanceOf(address, uint256) view returns (uint256)"]);

// Mirror of the on-chain config, reconstructed off-chain at the incident's openBlock.
export interface SettlementParams {
  twapLookbackBlocks: bigint;
  holdingMarginBlocks: bigint;
  sampleStepBlocks: bigint;
}
export interface ScoredToken {
  token: `0x${string}`;
  scorePerTokenPerBlock: bigint;
  startBlock: bigint;
  decimals: number; // token decimals; scores are normalized to an 18-dec basis before summing (F6)
}
export interface IncidentConfig {
  coverageBps: bigint; // insured token's maxCoverageBps (κ) at openBlock
  underlyingPriceOracle: `0x${string}`;
  underlyingConversionAddress: `0x${string}`;
  underlyingConversionCallData: `0x${string}`;
  params: SettlementParams;
  scoredTokens: ScoredToken[];
}

export function makeClient(rpcUrl: string): PublicClient {
  return createPublicClient({ transport: http(rpcUrl, { retryCount: 5 }) });
}

/** One register-or-cancel event, in true chain order. */
export interface InputEvent {
  kind: "register" | "cancel";
  claimId: bigint;
  user: `0x${string}`;
  amount: bigint; // register only (escrow actually received)
  scoreToSpend: bigint; // register only — requested insurance score to spend
  boosterAmount: bigint; // register only — units of the canonical booster committed
  blockNumber: bigint;
  logIndex: number;
}

function orderLogs<T extends { blockNumber: bigint; logIndex: number }>(a: T, b: T): number {
  return a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber);
}

/**
 * The incident's register/cancel events in chronological (block, logIndex)
 * order. Note ClaimCancelled is not indexed by incidentId, so cancels are
 * matched to this incident by claimId membership.
 */
export async function readInputEvents(
  client: PublicClient,
  incidentId: bigint,
  fromBlock: bigint,
  toBlock: bigint
): Promise<InputEvent[]> {
  const regs = await client.getLogs({
    address: CONFIG.defiInsurance,
    event: CLAIM_REGISTERED,
    args: { incidentId },
    fromBlock,
    toBlock,
  });
  const claimIds = new Set(regs.map((r) => r.args.claimId!));
  const cancels = await client.getLogs({
    address: CONFIG.defiInsurance,
    event: CLAIM_CANCELLED,
    fromBlock,
    toBlock,
  });

  const events: InputEvent[] = [
    ...regs.map((r) => ({
      kind: "register" as const,
      claimId: r.args.claimId!,
      user: r.args.user!,
      amount: r.args.insuredTokenAmount!,
      scoreToSpend: r.args.scoreToSpend!,
      boosterAmount: r.args.boosterAmount ?? 0n,
      blockNumber: r.blockNumber!,
      logIndex: r.logIndex!,
    })),
    ...cancels
      .filter((c) => claimIds.has(c.args.claimId!))
      .map((c) => ({
        kind: "cancel" as const,
        claimId: c.args.claimId!,
        user: c.args.user!,
        amount: 0n,
        scoreToSpend: 0n,
        boosterAmount: 0n,
        blockNumber: c.blockNumber!,
        logIndex: c.logIndex!,
      })),
  ];
  return events.sort(orderLogs);
}

/**
 * Reconstruct the per-incident settlement config from contract state as of the
 * incident's openBlock (nothing is snapshot on-chain). History is immutable, so
 * a later governance retune can never alter an in-flight or settled incident.
 */
export async function incidentConfigOf(
  client: PublicClient,
  insuredToken: `0x${string}`,
  openBlock: bigint
): Promise<IncidentConfig> {
  const it = (await client.readContract({
    address: CONFIG.defiInsurance,
    abi: DEFI_ABI,
    functionName: "getInsuredToken",
    args: [insuredToken],
    blockNumber: openBlock,
  })) as { maxCoverageBps: bigint; underlyingPriceOracle: `0x${string}`; underlyingConversionAddress: `0x${string}`; underlyingConversionCallData: `0x${string}` };

  const [twapLookbackBlocks, holdingMarginBlocks, sampleStepBlocks] = (await client.readContract({
    address: CONFIG.defiInsurance,
    abi: DEFI_ABI,
    functionName: "settlementParams",
    blockNumber: openBlock,
  })) as readonly [bigint, bigint, bigint];

  const rawScored = (await client.readContract({
    address: CONFIG.registry,
    abi: REGISTRY_ABI,
    functionName: "getScoredTokens",
    blockNumber: openBlock,
  })) as { token: `0x${string}`; scorePerTokenPerBlock: bigint; startBlock: bigint }[];
  // Enrich each scored token with its decimals so earnedScoreOf can normalize
  // every token's balance integral to a common 18-dec basis before summing (F6):
  // otherwise a non-18-dec scored token's score would be mis-scaled relative to
  // the others when they're added together.
  const scoredTokens: ScoredToken[] = [];
  for (const st of rawScored) {
    scoredTokens.push({ ...st, decimals: await decimalsOf(client, st.token) });
  }

  return {
    coverageBps: it.maxCoverageBps,
    underlyingPriceOracle: it.underlyingPriceOracle,
    underlyingConversionAddress: it.underlyingConversionAddress,
    underlyingConversionCallData: it.underlyingConversionCallData,
    params: { twapLookbackBlocks, holdingMarginBlocks, sampleStepBlocks },
    scoredTokens,
  };
}

/** The registered (assets, pools) topology as of `blockNumber`. Payout rows
 *  align to this list; it is frozen while the incident is active. */
export async function poolsAt(
  client: PublicClient,
  blockNumber: bigint
): Promise<{ assets: `0x${string}`[]; poolAddrs: `0x${string}`[] }> {
  const [assets, poolAddrs] = (await client.readContract({
    address: CONFIG.registry,
    abi: REGISTRY_ABI,
    functionName: "pools",
    blockNumber,
  })) as readonly [`0x${string}`[], `0x${string}`[]];
  return { assets: [...assets], poolAddrs: [...poolAddrs] };
}

/** A pool's staked-asset balance (totalAssets) at `blockNumber`. */
export async function poolTotalAssetsAt(client: PublicClient, pool: `0x${string}`, blockNumber: bigint): Promise<bigint> {
  return (await client.readContract({
    address: pool,
    abi: POOL_ABI,
    functionName: "totalAssets",
    blockNumber,
  })) as bigint;
}

/** The canonical booster ERC-1155 collection as of `blockNumber` (0 if unset). */
export async function boosterNftAt(client: PublicClient, blockNumber: bigint): Promise<`0x${string}`> {
  return (await client.readContract({
    address: CONFIG.registry,
    abi: REGISTRY_ABI,
    functionName: "boosterNFT",
    blockNumber,
  })) as `0x${string}`;
}

/** The universal per-incident payout cap (bps) as of `blockNumber`. */
export async function maxPayoutBpsAt(client: PublicClient, blockNumber: bigint): Promise<bigint> {
  return (await client.readContract({
    address: CONFIG.registry,
    abi: REGISTRY_ABI,
    functionName: "maxPayoutBps",
    blockNumber,
  })) as bigint;
}

/**
 * Insurance score already spent per user, from the ScoreSpent event ledger.
 * Sums ScoreSpent logs across EVERY payout module ever registered (enumerated
 * from the Registry's PayoutModuleSet events), pinned to blocks strictly before
 * `openBlock`.
 *
 * INTENTIONAL asymmetry with earnedScoreOf, which anchors at the earlier
 * `referenceBlock` (do not "align" them): earned is capped pre-incident so score
 * can't be farmed during the claim window, but spent must subtract EVERY prior
 * commitment up to the open. Anchoring spent at referenceBlock instead would miss
 * score a user burned in (referenceBlock, openBlock] — e.g. on a prior incident
 * that finalized in that gap — and let them re-claim it (double-spend). All prior
 * incidents resolve before openBlock (one-at-a-time), so openBlock−1 captures them.
 */
export async function spentScoreByUser(client: PublicClient, openBlock: bigint): Promise<Map<string, bigint>> {
  const spent = new Map<string, bigint>();
  if (openBlock === 0n) return spent;
  const toBlock = openBlock - 1n;

  const sets = await client.getLogs({ address: CONFIG.registry, event: PAYOUT_MODULE_SET, fromBlock: 0n, toBlock });
  const modules = new Map<string, `0x${string}`>();
  for (const s of sets) {
    const m = s.args.newModule as `0x${string}`;
    if (m && m !== ZERO_ADDRESS) modules.set(m.toLowerCase(), m);
  }

  for (const mod of modules.values()) {
    const logs = await client.getLogs({ address: mod, event: SCORE_SPENT, fromBlock: 0n, toBlock });
    for (const l of logs) {
      const u = (l.args.user as string).toLowerCase();
      spent.set(u, (spent.get(u) ?? 0n) + (l.args.amount as bigint));
    }
  }
  return spent;
}

/**
 * First block whose timestamp is ≥ `ts` (binary search). All settlement reads
 * anchor on deterministic blocks (openBlock, window-end) so the computation is
 * reproducible by anyone at any later time.
 */
export async function blockAtTimestamp(client: PublicClient, ts: bigint): Promise<bigint> {
  let lo = 1n;
  let hi = await client.getBlockNumber();
  if ((await client.getBlock({ blockNumber: hi })).timestamp < ts) {
    throw new Error(`timestamp ${ts} is in the future`);
  }
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    const t = (await client.getBlock({ blockNumber: mid })).timestamp;
    if (t < ts) lo = mid + 1n;
    else hi = mid;
  }
  return lo;
}

/**
 * Insured-token → underlying ratio at `blockNumber`, via the per-token recipe:
 * staticcall(conversionAddress, conversionCallData) → WAD-normalized underlying
 * per 1e18 token. `address(0)` ⇒ identity (the token IS the underlying), 1e18.
 */
export async function ratioAt(
  client: PublicClient,
  conversionAddress: `0x${string}`,
  conversionCallData: `0x${string}`,
  blockNumber: bigint
): Promise<bigint> {
  if (conversionAddress === ZERO_ADDRESS) return WAD;
  const res = await client.call({ to: conversionAddress, data: conversionCallData, blockNumber });
  return BigInt(res.data ?? "0x0");
}

/**
 * USD price from a Chainlink-style oracle at `blockNumber`, normalized to 1e18.
 * Reads the oracle's own `decimals()` and pins the block so the value is
 * reproducible.
 */
export async function priceUsd1e18(client: PublicClient, oracle: `0x${string}`, blockNumber: bigint): Promise<bigint> {
  const [, answer] = (await client.readContract({
    address: oracle,
    abi: FEED_ABI,
    functionName: "latestRoundData",
    blockNumber,
  })) as [bigint, bigint, bigint, bigint, bigint];
  if (answer <= 0n) throw new Error(`oracle ${oracle} returned non-positive price`);
  const dec = (await client.readContract({
    address: oracle,
    abi: FEED_ABI,
    functionName: "decimals",
    blockNumber,
  })) as number;
  return BigInt(answer) * 10n ** (18n - BigInt(dec));
}

export async function decimalsOf(client: PublicClient, token: `0x${string}`): Promise<number> {
  return (await client.readContract({ address: token, abi: ERC20_ABI, functionName: "decimals" })) as number;
}

export async function balanceOfAt(
  client: PublicClient,
  token: `0x${string}`,
  who: `0x${string}`,
  blockNumber: bigint
): Promise<bigint> {
  return (await client.readContract({
    address: token,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: [who],
    blockNumber,
  })) as bigint;
}

/**
 * Merge outflow (from == who) and inflow (to == who) Transfer logs into net
 * balance deltas, summed per unique (blockNumber, logIndex), then sorted. Netting
 * by log id is what makes SELF-transfers correct: a `Transfer(who, who, V)` log is
 * returned by BOTH the `from` and `to` queries (same block+logIndex), so its −V
 * and +V land on the same key and cancel to zero — a self-transfer never changed
 * the balance. Without this the −V leg would be applied first and dip the running
 * min spuriously (F5). Normal transfers appear in only one query, so they pass
 * through as a single signed delta.
 */
function netByLog(outs: any[], ins: any[]): { blockNumber: bigint; logIndex: number; delta: bigint }[] {
  const byKey = new Map<string, { blockNumber: bigint; logIndex: number; delta: bigint }>();
  const add = (l: any, delta: bigint) => {
    const key = `${l.blockNumber}:${l.logIndex}`;
    const cur = byKey.get(key);
    if (cur) cur.delta += delta;
    else byKey.set(key, { blockNumber: l.blockNumber as bigint, logIndex: l.logIndex as number, delta });
  };
  for (const l of outs) add(l, -(l.args.value as bigint));
  for (const l of ins) add(l, l.args.value as bigint);
  return [...byKey.values()].sort((a, b) =>
    a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber)
  );
}

/**
 * Minimum balance of `who` in `token` over [fromBlock, toBlock], computed
 * exactly: start from balanceOf(fromBlock) and replay Transfer events. The min
 * over the window is what the holder provably kept the whole time, which also
 * makes cross-claimant dedupe automatic.
 */
export async function minBalanceOver(
  client: PublicClient,
  token: `0x${string}`,
  who: `0x${string}`,
  fromBlock: bigint,
  toBlock: bigint
): Promise<bigint> {
  let bal = await balanceOfAt(client, token, who, fromBlock);
  let min = bal;
  const outs = await client.getLogs({ address: token, event: ERC20_TRANSFER, args: { from: who }, fromBlock: fromBlock + 1n, toBlock });
  const ins = await client.getLogs({ address: token, event: ERC20_TRANSFER, args: { to: who }, fromBlock: fromBlock + 1n, toBlock });
  for (const e of netByLog(outs, ins)) {
    bal += e.delta;
    if (bal < min) min = bal;
  }
  return min;
}

/**
 * Minimum ERC-1155 balance of `who` for `id` over [fromBlock, toBlock], by
 * replaying TransferSingle/TransferBatch — the same continuous-holding rule the
 * insured-token eligibility uses, applied to the booster. This is the cap on the
 * boost a claim can apply: the claimant must have held the committed boosters
 * continuously from filing through window-end (they are burned at finalize).
 */
export async function minErc1155BalanceOver(
  client: PublicClient,
  collection: `0x${string}`,
  who: `0x${string}`,
  id: bigint,
  fromBlock: bigint,
  toBlock: bigint
): Promise<bigint> {
  let bal = (await client.readContract({
    address: collection,
    abi: ERC1155_ABI,
    functionName: "balanceOf",
    args: [who, id],
    blockNumber: fromBlock,
  })) as bigint;
  let min = bal;
  if (toBlock <= fromBlock) return min;

  // Net by (blockNumber, logIndex) so a self-transfer (from == to == who), which
  // the from- and to-queries both return as the same log, cancels to zero (F5).
  const byKey = new Map<string, { blockNumber: bigint; logIndex: number; delta: bigint }>();
  const from = fromBlock + 1n;

  const push = (l: any, delta: bigint) => {
    const key = `${l.blockNumber}:${l.logIndex}`;
    const cur = byKey.get(key);
    if (cur) cur.delta += delta;
    else byKey.set(key, { blockNumber: l.blockNumber as bigint, logIndex: l.logIndex as number, delta });
  };

  const outSingle = await client.getLogs({ address: collection, event: ERC1155_TRANSFER_SINGLE, args: { from: who }, fromBlock: from, toBlock });
  const inSingle = await client.getLogs({ address: collection, event: ERC1155_TRANSFER_SINGLE, args: { to: who }, fromBlock: from, toBlock });
  for (const l of outSingle) if ((l.args.id as bigint) === id) push(l, -(l.args.value as bigint));
  for (const l of inSingle) if ((l.args.id as bigint) === id) push(l, l.args.value as bigint);

  const outBatch = await client.getLogs({ address: collection, event: ERC1155_TRANSFER_BATCH, args: { from: who }, fromBlock: from, toBlock });
  const inBatch = await client.getLogs({ address: collection, event: ERC1155_TRANSFER_BATCH, args: { to: who }, fromBlock: from, toBlock });
  const batchDelta = (l: any): bigint => {
    const ids = l.args.ids as bigint[];
    const vals = l.args.values as bigint[];
    let v = 0n;
    for (let j = 0; j < ids.length; j++) if (ids[j] === id) v += vals[j];
    return v;
  };
  for (const l of outBatch) push(l, -batchDelta(l));
  for (const l of inBatch) push(l, batchDelta(l));

  const events = [...byKey.values()].sort((a, b) =>
    a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber)
  );
  for (const e of events) {
    bal += e.delta;
    if (bal < min) min = bal;
  }
  return min;
}

/**
 * Cumulative token·block integral of `who`'s `token` balance over [fromBlock,
 * toBlock] — `Σ balance × blockDuration`. The USD8 insurance-score primitive: a
 * NON-expiring accumulator (not a time-weighted average), event-replayed.
 */
export async function tokenBlockIntegral(
  client: PublicClient,
  token: `0x${string}`,
  who: `0x${string}`,
  fromBlock: bigint,
  toBlock: bigint
): Promise<bigint> {
  if (toBlock <= fromBlock) return 0n;
  let bal = await balanceOfAt(client, token, who, fromBlock);
  const outs = await client.getLogs({ address: token, event: ERC20_TRANSFER, args: { from: who }, fromBlock: fromBlock + 1n, toBlock });
  const ins = await client.getLogs({ address: token, event: ERC20_TRANSFER, args: { to: who }, fromBlock: fromBlock + 1n, toBlock });
  let acc = 0n;
  let cursor = fromBlock;
  for (const e of netByLog(outs, ins)) {
    acc += bal * (e.blockNumber - cursor);
    cursor = e.blockNumber;
    bal += e.delta;
  }
  acc += bal * (toBlock - cursor);
  return acc;
}
