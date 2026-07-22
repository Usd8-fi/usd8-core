// All chain reads. Plain read-only RPC calls against a public archive node.

import {
  createPublicClient,
  decodeAbiParameters,
  http,
  parseAbi,
  parseAbiItem,
  type PublicClient,
} from "viem";
import { CONFIG, DEFAULT_RPC_TIMEOUT_MS, MAX_LOG_RANGE, LOG_RESULT_CAP } from "./config.js";

export const WAD = 10n ** 18n;
export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

// DefiInsurance surface: incidents, per-token config, global settlement params.
// The per-incident config is NOT snapshot on-chain — it is reconstructed by
// reading these at the incident's openBlock (see {incidentConfigOf}).
export const DEFI_ABI = parseAbi([
  "function incidents(uint256) view returns (address insuredToken, uint64 claimWindowEndTime, bytes32 root, uint256 unresolved, uint64 rootSubmittedAt, uint64 referenceBlock, uint64 openBlock, uint8 status, uint64 disputedAt, bytes32 claimSetHash)",
  "function incidentTeePcrHash(uint256 incidentId) view returns (bytes32)",
  "function getInsuredToken(address) view returns ((uint256 maxCoverageBps, address underlyingPriceOracle, address underlyingConversionAddress, bytes underlyingConversionCallData, uint128 minClaimAmount))",
  "function settlementParams() view returns (uint64 twapLookbackBlocks, uint64 holdingMarginBlocks, uint64 sampleStepBlocks)",
  "function registry() view returns (address)",
  "function BOOSTER_ID() view returns (uint256)",
  "function BOOSTER_BOOST_BPS() view returns (uint256)",
]);

// Registry surface: topology (pool set), scored tokens, booster collection.
export const REGISTRY_ABI = parseAbi([
  "function coverPools() view returns (address[] assets, address[] poolAddrs)",
  "function coverPoolsLength() view returns (uint256)",
  "function getScoredTokens() view returns (address[])",
  "function getScoredRateHistory(address token) view returns ((uint64 fromBlock, uint128 rate)[])",
  "function boosterNFT() view returns (address)",
  "function maxCoverPoolPayoutBps() view returns (uint256)",
  "function scoreSpent(address) view returns (uint256)",
  "function defiInsurance() view returns (address)",
  "function assetUsdFeed(address asset) view returns (address)",
  "function maxOracleStaleness() view returns (uint64)",
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
/** One rate segment of a scored token: `rate` applies from `fromBlock` until the
 *  next segment's fromBlock (or referenceBlock). Mirrors Registry.RatePoint. */
export interface RatePoint {
  fromBlock: bigint;
  rate: bigint; // score per whole token per block, 1e18-scaled; 0 = off from here
}
export interface ScoredToken {
  token: `0x${string}`;
  rates: RatePoint[]; // append-only timeline, ascending by fromBlock (Registry order)
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

const TRUSTED_DRPC_HOSTS = new Set(["lb.drpc.org", "lb.drpc.live"]);

export function makeClient(rpcUrl: string, drpcKey?: string, timeoutMs = DEFAULT_RPC_TIMEOUT_MS): PublicClient {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
    throw new Error(`RPC timeout must be a positive integer, got ${timeoutMs}`);
  }
  if (drpcKey) {
    let endpoint: URL;
    try {
      endpoint = new URL(rpcUrl);
    } catch {
      throw new Error("refusing to send DRPC_KEY: RPC URL is invalid");
    }
    if (
      endpoint.protocol !== "https:" ||
      !TRUSTED_DRPC_HOSTS.has(endpoint.hostname) ||
      (endpoint.port !== "" && endpoint.port !== "443") ||
      endpoint.username !== "" ||
      endpoint.password !== ""
    ) {
      throw new Error(`refusing to send DRPC_KEY to untrusted RPC endpoint ${endpoint.origin}`);
    }
  }
  const metrics = freshRpcMetrics();
  const baseTransport = http(rpcUrl, {
    retryCount: 5,
    timeout: timeoutMs,
    onFetchRequest: () => {
      metrics.transportRequests++;
    },
    onFetchResponse: () => {
      metrics.transportResponses++;
    },
    // JSON-RPC endpoints should not redirect. Failing redirects also prevents
    // Drpc-Key from being forwarded to a different origin by fetch.
    fetchOptions: {
      redirect: "error",
      ...(drpcKey ? { headers: { "Drpc-Key": drpcKey } } : {}),
    },
  });
  const instrumentedTransport: typeof baseTransport = (options) => {
    const transport = baseTransport(options);
    return {
      ...transport,
      request: async (request, requestOptions) => {
        metrics.rpcRequests++;
        try {
          return await transport.request(request, requestOptions);
        } finally {
          metrics.transportRetries = Math.max(0, metrics.transportRequests - metrics.rpcRequests);
        }
      },
    };
  };
  const client = createPublicClient({ transport: instrumentedTransport });
  RPC_METRICS.set(client as object, metrics);
  return client;
}

/** Confirm a configured address is a contract at the exact historical anchor. */
export async function assertContractCodeAt(
  client: PublicClient,
  address: `0x${string}`,
  label: string,
  blockNumber: bigint
): Promise<void> {
  const bytecode = await client.getBytecode({ address, blockNumber });
  if (!bytecode || bytecode === "0x") {
    throw new Error(`${label} ${address} has no bytecode at block ${blockNumber}`);
  }
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

// eth_getLogs safety (audit H-A). A single unbounded getLogs over a multi-million-
// block span — e.g. a scored token's integral from its startBlock, or a claimant's
// full transfer history — is either REJECTED by a rate-limited provider (throws →
// no root → the incident voids → coverage denied) or, worse, SILENTLY TRUNCATED,
// dropping Transfer logs so a claimant's held balance is overstated (overpay) and
// two honest recomputes disagree. Every historical read goes through this instead:
// it walks the range in bounded chunks AND, if any chunk returns a full page
// (≥ LOG_RESULT_CAP), bisects it — so truncation can never pass unnoticed and the
// merged result is identical regardless of provider. An inverted range (to < from)
// yields [] deterministically (guards the degenerate window, audit L-C).
//
// The caps live in config.ts (recorded in configHash) and MUST be ≤ the
// configured provider's documented limits — there is no universal cap (Blockscout
// is 1,000, not 10,000). If bisection reaches a single block that STILL returns a
// full page, we can't prove completeness, so we FAIL CLOSED (throw) rather than
// sign a possibly-truncated result.
type LogQuery = { address: `0x${string}`; event: unknown; args?: Record<string, unknown> };

export interface RpcMetrics {
  rpcRequests: number;
  transportRequests: number;
  transportResponses: number;
  transportRetries: number;
  logRequests: number;
  logBisections: number;
  logErrors: number;
  logMaxActive: number;
  logElapsedMs: number;
}

interface MutableRpcMetrics extends RpcMetrics {
  active: number;
}

const RPC_METRICS = new WeakMap<object, MutableRpcMetrics>();

function freshRpcMetrics(): MutableRpcMetrics {
  return {
    rpcRequests: 0,
    transportRequests: 0,
    transportResponses: 0,
    transportRetries: 0,
    logRequests: 0,
    logBisections: 0,
    logErrors: 0,
    logMaxActive: 0,
    logElapsedMs: 0,
    active: 0,
  };
}

function mutableRpcMetrics(client: PublicClient): MutableRpcMetrics {
  let metrics = RPC_METRICS.get(client as object);
  if (!metrics) {
    metrics = freshRpcMetrics();
    RPC_METRICS.set(client as object, metrics);
  }
  return metrics;
}

/** Snapshot of logical, transport-level, and historical-log RPC work. */
export function rpcMetricsOf(client: PublicClient): RpcMetrics {
  const { active: _active, ...snapshot } = mutableRpcMetrics(client);
  return snapshot;
}

export async function getLogsChunked(
  client: PublicClient,
  q: LogQuery,
  fromBlock: bigint,
  toBlock: bigint
): Promise<any[]> {
  const out: any[] = [];
  for (let start = fromBlock; start <= toBlock; start += MAX_LOG_RANGE) {
    const end = start + MAX_LOG_RANGE - 1n < toBlock ? start + MAX_LOG_RANGE - 1n : toBlock;
    out.push(...(await getLogsBisect(client, q, start, end)));
  }
  return out;
}

async function getLogsBisect(client: PublicClient, q: LogQuery, fromBlock: bigint, toBlock: bigint): Promise<any[]> {
  const metrics = mutableRpcMetrics(client);
  metrics.logRequests++;
  metrics.active++;
  metrics.logMaxActive = Math.max(metrics.logMaxActive, metrics.active);
  const started = performance.now();

  let logs: any[] = [];
  let requestFailed = false;
  let requestError: unknown;
  try {
    logs = (await client.getLogs({ ...q, fromBlock, toBlock } as any)) as any[];
  } catch (error) {
    requestFailed = true;
    requestError = error;
    metrics.logErrors++;
  } finally {
    metrics.active--;
    metrics.logElapsedMs += performance.now() - started;
  }

  if (requestFailed) {
    // dRPC and other providers reject expensive eth_getLogs ranges with an
    // explicit timeout/range/result-size error. Treat that as pagination
    // feedback and bisect; auth, malformed-query, and unrelated failures remain
    // fatal rather than causing an unbounded retry tree.
    const message = requestError instanceof Error ? `${requestError.name}: ${requestError.message}` : String(requestError);
    const rangeLimited = /\b408\b|request timeout|timed?\s*out|query duration|block range|range (?:is )?too (?:large|wide)|too many results|result(?:s| set)? (?:size|limit)|response (?:size|too large)/i.test(
      message
    );
    if (!rangeLimited || fromBlock === toBlock) throw requestError;

    metrics.logBisections++;
    const mid = fromBlock + (toBlock - fromBlock) / 2n;
    const lo = await getLogsBisect(client, q, fromBlock, mid);
    const hi = await getLogsBisect(client, q, mid + 1n, toBlock);
    return [...lo, ...hi];
  }

  // Under the cap → provably complete (cap is ≤ the provider's real limit).
  if (logs.length < LOG_RESULT_CAP) return logs;
  // A full page might have been silently capped. Split and retry to page it all in.
  if (fromBlock < toBlock) {
    metrics.logBisections++;
    const mid = fromBlock + (toBlock - fromBlock) / 2n;
    const lo = await getLogsBisect(client, q, fromBlock, mid);
    const hi = await getLogsBisect(client, q, mid + 1n, toBlock);
    return [...lo, ...hi];
  }
  // Single block still full: nothing left to split, so completeness is
  // unprovable. Fail closed rather than sign a possibly-truncated history (M-01).
  throw new Error(
    `getLogs returned ${logs.length} ≥ LOG_RESULT_CAP (${LOG_RESULT_CAP}) for single block ${fromBlock} — ` +
      `cannot prove completeness. Lower LOG_RESULT_CAP below the provider's documented cap, or use an indexed source.`
  );
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
  const regs = await getLogsChunked(
    client,
    { address: CONFIG.defiInsurance, event: CLAIM_REGISTERED, args: { incidentId } },
    fromBlock,
    toBlock
  );
  const claimIds = new Set(regs.map((r) => r.args.claimId!));
  const cancels = await getLogsChunked(
    client,
    { address: CONFIG.defiInsurance, event: CLAIM_CANCELLED },
    fromBlock,
    toBlock
  );

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
  })) as {
    maxCoverageBps: bigint;
    underlyingPriceOracle: `0x${string}`;
    underlyingConversionAddress: `0x${string}`;
    underlyingConversionCallData: `0x${string}`;
    minClaimAmount: bigint;
  };

  const [twapLookbackBlocks, holdingMarginBlocks, sampleStepBlocks] = (await client.readContract({
    address: CONFIG.defiInsurance,
    abi: DEFI_ABI,
    functionName: "settlementParams",
    blockNumber: openBlock,
  })) as readonly [bigint, bigint, bigint];

  // The Registry is the canonical source for scored-token rates: there are no local
  // USD8/sUSD8 rate constants here. Read every token and its append-only timeline at
  // openBlock. earnedScoreOf integrates each segment at its OWN rate, so a past rate
  // change never re-prices already-accrued score. Decimals are also pinned so a
  // non-18-dec token's integral normalizes to the shared 18-dec basis (F6).
  const tokenList = (await client.readContract({
    address: CONFIG.registry,
    abi: REGISTRY_ABI,
    functionName: "getScoredTokens",
    blockNumber: openBlock,
  })) as `0x${string}`[];
  const scoredTokens: ScoredToken[] = [];
  for (const token of tokenList) {
    const rates = (await client.readContract({
      address: CONFIG.registry,
      abi: REGISTRY_ABI,
      functionName: "getScoredRateHistory",
      args: [token],
      blockNumber: openBlock,
    })) as { fromBlock: bigint; rate: bigint }[];
    scoredTokens.push({ token, rates: [...rates], decimals: await decimalsOf(client, token, openBlock) });
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
    functionName: "coverPools",
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

/** PCR0/PCR1/PCR2 commitment snapshotted for an incident at open. */
export async function incidentTeePcrHashAt(
  client: PublicClient,
  incidentId: bigint,
  blockNumber: bigint
): Promise<`0x${string}`> {
  const value = (await client.readContract({
    address: CONFIG.defiInsurance,
    abi: DEFI_ABI,
    functionName: "incidentTeePcrHash",
    args: [incidentId],
    blockNumber,
  })) as `0x${string}`;
  if (value === `0x${"0".repeat(64)}`) throw new Error("incident teePcrHash is zero");
  return value;
}

/** The universal per-incident payout cap (bps) as of `blockNumber`. */
export async function maxCoverPoolPayoutBpsAt(client: PublicClient, blockNumber: bigint): Promise<bigint> {
  return (await client.readContract({
    address: CONFIG.registry,
    abi: REGISTRY_ABI,
    functionName: "maxCoverPoolPayoutBps",
    blockNumber,
  })) as bigint;
}

/**
 * Insurance score already spent by `user` as of `blockNumber` — one archive read
 * of {Registry.scoreSpent}, the durable cumulative total every payout module
 * mirrors at finalize ({DefiInsurance.finalizeClaim} → recordScoreSpent). It
 * survives module swaps by design, so a single view replaces the old
 * genesis-wide ScoreSpent/DefiInsuranceSet log scans (simpler, cheaper, immune
 * to RPC getLogs range caps).
 *
 * Callers anchor at the END of openBlock (M-03) — an INTENTIONAL asymmetry with
 * earnedScoreOf, which anchors at the earlier `referenceBlock` (do not "align"
 * them): earned is capped pre-incident so score can't be farmed during the claim
 * window, but spent must subtract EVERY prior commitment up to the open, INCLUDING
 * a prior incident that finalized EARLIER IN THE SAME BLOCK this one opens in —
 * openBlock−1 would miss that same-block spend and let it be reused. Reading at
 * openBlock is safe because a newly-opened incident can't finalize in its own
 * opening block, so this snapshot never includes the incident being settled.
 * Anchoring spent at referenceBlock instead would miss score a user burned in
 * (referenceBlock, openBlock] and let them re-claim it (double-spend).
 */
export async function spentScoreOf(client: PublicClient, user: `0x${string}`, blockNumber: bigint): Promise<bigint> {
  return (await client.readContract({
    address: CONFIG.registry,
    abi: REGISTRY_ABI,
    functionName: "scoreSpent",
    args: [user],
    blockNumber,
  })) as bigint;
}

/**
 * Highest block whose timestamp is ≤ `ts` (binary search) — the LAST block still
 * inside a `block.timestamp <= ts` window. The contract accepts claims while
 * `block.timestamp <= claimWindowEndTime`, so the window-end reads must anchor on
 * this block, not the first post-deadline one (H-02): otherwise a transfer or
 * oracle update in the first block after the deadline could alter settlement.
 * All settlement reads anchor on deterministic blocks (openBlock, window-end) so
 * the computation is reproducible by anyone at any later time.
 */
export async function blockAtOrBeforeTimestamp(
  client: PublicClient,
  ts: bigint,
  upperBound?: bigint
): Promise<bigint> {
  let lo = 1n;
  let hi = upperBound ?? (await client.getBlockNumber());
  if ((await client.getBlock({ blockNumber: hi })).timestamp < ts) {
    throw new Error(
      upperBound === undefined
        ? `timestamp ${ts} is in the future`
        : `timestamp ${ts} is later than finalized block ${hi}`
    );
  }
  while (lo < hi) {
    const mid = (lo + hi + 1n) / 2n; // upper mid: converge toward the MAX in-window block
    const t = (await client.getBlock({ blockNumber: mid })).timestamp;
    if (t <= ts) lo = mid;
    else hi = mid - 1n;
  }
  return lo;
}

export interface BlockAnchor {
  number: bigint;
  timestamp: bigint;
  hash: `0x${string}`;
}

export interface SettlementAnchors {
  reference: BlockAnchor;
  open: BlockAnchor;
  windowEnd: BlockAnchor;
  finalizedHead: BlockAnchor;
}

async function readBlockAnchor(client: PublicClient, blockNumber: bigint): Promise<BlockAnchor> {
  const block = await client.getBlock({ blockNumber });
  if (block.number === null || block.hash === null) throw new Error(`block ${blockNumber} is missing number or hash`);
  return { number: block.number, timestamp: block.timestamp, hash: block.hash };
}

/** Resolve every settlement block under Ethereum's finalized head. No root is
 * computed while the claim-window boundary can still be reorged. */
export async function finalizedSettlementAnchors(
  client: PublicClient,
  referenceBlock: bigint,
  openBlock: bigint,
  windowEndTimestamp: bigint
): Promise<SettlementAnchors> {
  const finalized = await client.getBlock({ blockTag: "finalized" });
  if (finalized.number === null || finalized.hash === null) throw new Error("finalized head is missing number or hash");
  if (finalized.timestamp < windowEndTimestamp) {
    throw new Error(
      `claim window is not finalized: deadline ${windowEndTimestamp}, finalized head ${finalized.number} timestamp ${finalized.timestamp}`
    );
  }
  if (referenceBlock > finalized.number || openBlock > finalized.number) {
    throw new Error(
      `settlement anchor is not finalized: reference ${referenceBlock}, open ${openBlock}, finalized head ${finalized.number}`
    );
  }

  const windowEndBlock = await blockAtOrBeforeTimestamp(client, windowEndTimestamp, finalized.number);
  const [reference, open, windowEnd] = await Promise.all([
    readBlockAnchor(client, referenceBlock),
    readBlockAnchor(client, openBlock),
    readBlockAnchor(client, windowEndBlock),
  ]);
  return {
    reference,
    open,
    windowEnd,
    finalizedHead: { number: finalized.number, timestamp: finalized.timestamp, hash: finalized.hash },
  };
}

/** Re-read anchors after all RPC work. Any hash mutation makes the result unsafe
 * to emit or sign, even when the block numbers still exist. */
export async function assertBlockAnchorsUnchanged(
  client: PublicClient,
  anchors: SettlementAnchors
): Promise<void> {
  for (const [name, expected] of Object.entries(anchors) as [keyof SettlementAnchors, BlockAnchor][]) {
    const actual = await readBlockAnchor(client, expected.number);
    if (actual.hash.toLowerCase() !== expected.hash.toLowerCase()) {
      throw new Error(`anchor hash changed for ${name} block ${expected.number}: ${expected.hash} -> ${actual.hash}`);
    }
  }
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
  if (res.data === undefined || res.data.length !== 66) {
    throw new Error(`conversion ${conversionAddress} returned malformed uint256 data`);
  }
  const [ratio] = decodeAbiParameters([{ type: "uint256" }], res.data);
  if (ratio === 0n) throw new Error(`conversion ${conversionAddress} returned non-positive ratio`);
  return ratio;
}

/**
 * USD price from a Chainlink-style oracle at `blockNumber`, normalized to 1e18.
 * Reads the oracle's own `decimals()` and pins the block so the value is
 * reproducible. Rejects a non-positive answer, an incomplete round
 * (startedAt/updatedAt == 0 or reversed), a future-dated update, a superseded
 * round, and a feed staler than the Registry policy at the incident openBlock.
 */
export async function priceUsd1e18(client: PublicClient, oracle: `0x${string}`, blockNumber: bigint): Promise<bigint> {
  const [roundId, answer, startedAt, updatedAt, answeredInRound] = (await client.readContract({
    address: oracle,
    abi: FEED_ABI,
    functionName: "latestRoundData",
    blockNumber,
  })) as [bigint, bigint, bigint, bigint, bigint];
  if (answer <= 0n) throw new Error(`oracle ${oracle} returned non-positive price`);
  // Round completeness + staleness: compare the feed's last-update time to the
  // pinned block's own timestamp (both deterministic, so every honest recompute agrees).
  if (startedAt === 0n || updatedAt === 0n) throw new Error(`oracle ${oracle} round incomplete`);
  if (startedAt > updatedAt) {
    throw new Error(`oracle ${oracle} startedAt ${startedAt} is after updatedAt ${updatedAt}`);
  }
  if (answeredInRound < roundId) {
    throw new Error(`oracle ${oracle} answeredInRound ${answeredInRound} is older than roundId ${roundId}`);
  }
  const blockTs = (await client.getBlock({ blockNumber })).timestamp;
  if (updatedAt > blockTs) {
    throw new Error(`oracle ${oracle} updatedAt ${updatedAt} is later than pinned block ts ${blockTs}`);
  }
  if (blockTs - updatedAt > CONFIG.maxOracleStaleness) {
    throw new Error(`oracle ${oracle} stale: updatedAt ${updatedAt}, block ts ${blockTs} (> ${CONFIG.maxOracleStaleness}s)`);
  }
  const dec = BigInt(
    (await client.readContract({ address: oracle, abi: FEED_ABI, functionName: "decimals", blockNumber })) as number
  );
  // Normalize both directions so a feed with > 18 decimals doesn't throw a
  // negative-exponent RangeError (Chainlink USD feeds are 8-dec; guard exotics).
  return dec <= 18n ? answer * 10n ** (18n - dec) : answer / 10n ** (dec - 18n);
}

/** Token decimals pinned to `blockNumber` (M-05): an upgradeable token changing
 *  decimals must never alter the recomputation of an old incident. */
export async function decimalsOf(client: PublicClient, token: `0x${string}`, blockNumber: bigint): Promise<number> {
  return (await client.readContract({
    address: token,
    abi: ERC20_ABI,
    functionName: "decimals",
    blockNumber,
  })) as number;
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
 * L-02 supported-token contract for historical balance replay. A supported
 * ERC-20 changes `balanceOf` only through canonical `Transfer` events whose
 * `value` equals the actual balance delta. Rebasing/reflection/elastic balances,
 * hidden hook accounting, and proxy upgrades that violate that rule are not
 * supported. Reconcile the replayed endpoint with historical `balanceOf` and
 * fail closed on divergence; governance must only allowlist tokens satisfying
 * this semantic contract for insurance eligibility or score accrual.
 *
 * This endpoint check catches persistent hidden changes. A temporary unlogged
 * change that fully reverses before `toBlock` is inherently unprovable from
 * ERC-20 logs and remains outside the supported-token contract.
 */
async function assertErc20ReplayEnd(
  client: PublicClient,
  token: `0x${string}`,
  who: `0x${string}`,
  toBlock: bigint,
  replayedBalance: bigint
): Promise<void> {
  const actualBalance = await balanceOfAt(client, token, who, toBlock);
  if (replayedBalance !== actualBalance) {
    throw new Error(
      `unsupported token balance semantics for ${token}: Transfer replay ended at ${replayedBalance}, ` +
        `balanceOf(${who}) at block ${toBlock} is ${actualBalance}`
    );
  }
}

async function assertErc1155ReplayEnd(
  client: PublicClient,
  collection: `0x${string}`,
  who: `0x${string}`,
  id: bigint,
  toBlock: bigint,
  replayedBalance: bigint
): Promise<void> {
  const actualBalance = (await client.readContract({
    address: collection,
    abi: ERC1155_ABI,
    functionName: "balanceOf",
    args: [who, id],
    blockNumber: toBlock,
  })) as bigint;
  if (replayedBalance !== actualBalance) {
    throw new Error(
      `unsupported ERC-1155 balance semantics for ${collection} token ${id}: transfer replay ended at ` +
        `${replayedBalance}, balanceOf(${who}, ${id}) at block ${toBlock} is ${actualBalance}`
    );
  }
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
  if (toBlock <= fromBlock) return min; // degenerate window (audit L-C)
  const outs = await getLogsChunked(client, { address: token, event: ERC20_TRANSFER, args: { from: who } }, fromBlock + 1n, toBlock);
  const ins = await getLogsChunked(client, { address: token, event: ERC20_TRANSFER, args: { to: who } }, fromBlock + 1n, toBlock);
  for (const e of netByLog(outs, ins)) {
    bal += e.delta;
    if (bal < min) min = bal;
  }
  await assertErc20ReplayEnd(client, token, who, toBlock, bal);
  return min;
}

/**
 * Minimum ERC-1155 balance of `who` for `id` over [fromBlock, toBlock], by
 * replaying TransferSingle/TransferBatch — the same continuous-holding rule the
 * insured-token eligibility uses, applied to the booster. This is the cap on the
 * boost a claim can apply: the claimant must have held the committed boosters
 * continuously from the end of the filing block through window-end (they are
 * burned at finalize). Ethereum's historical state API is block-granular, so
 * intra-filing-block balance changes are intentionally outside this window.
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

  const outSingle = await getLogsChunked(client, { address: collection, event: ERC1155_TRANSFER_SINGLE, args: { from: who } }, from, toBlock);
  const inSingle = await getLogsChunked(client, { address: collection, event: ERC1155_TRANSFER_SINGLE, args: { to: who } }, from, toBlock);
  for (const l of outSingle) if ((l.args.id as bigint) === id) push(l, -(l.args.value as bigint));
  for (const l of inSingle) if ((l.args.id as bigint) === id) push(l, l.args.value as bigint);

  const outBatch = await getLogsChunked(client, { address: collection, event: ERC1155_TRANSFER_BATCH, args: { from: who } }, from, toBlock);
  const inBatch = await getLogsChunked(client, { address: collection, event: ERC1155_TRANSFER_BATCH, args: { to: who } }, from, toBlock);
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
  await assertErc1155ReplayEnd(client, collection, who, id, toBlock, bal);
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
  const outs = await getLogsChunked(client, { address: token, event: ERC20_TRANSFER, args: { from: who } }, fromBlock + 1n, toBlock);
  const ins = await getLogsChunked(client, { address: token, event: ERC20_TRANSFER, args: { to: who } }, fromBlock + 1n, toBlock);
  let acc = 0n;
  let cursor = fromBlock;
  for (const e of netByLog(outs, ins)) {
    acc += bal * (e.blockNumber - cursor);
    cursor = e.blockNumber;
    bal += e.delta;
  }
  acc += bal * (toBlock - cursor);
  await assertErc20ReplayEnd(client, token, who, toBlock, bal);
  return acc;
}
