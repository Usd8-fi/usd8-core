// All chain reads. Plain read-only RPC calls against a public archive node.

import { createPublicClient, http, parseAbi, parseAbiItem, type PublicClient } from "viem";
import { CONFIG } from "./config.js";

export const WAD = 10n ** 18n;

// Contract surface this tool reads. Settlement config comes from the
// per-incident snapshot (DefiInsurance.getIncidentConfig); per-stake-asset
// price feeds from coverPoolAssets(...).usdPriceFeed; spent score from the
// CoverPool ledger.
export const COVER_POOL_ABI = parseAbi([
  "function incidents(uint256) view returns (address insuredToken, uint64 windowEndTime, bytes32 root, bytes32 inputHash, uint256 claimCount, uint256 resolvedCount, uint64 rootSubmittedAt, uint64 referenceBlock)",
  "function claims(uint256) view returns (address user, uint256 incidentId, uint128 insuredTokenAmount, bool finalized, bool closed)",
  "function getIncidentConfig(uint256) view returns ((uint256 coverageBps, address priceOracle, address underlyingConversionAddress, bytes underlyingConversionCallData, (uint64 twapLookbackBlocks, uint64 holdingMarginBlocks, uint64 sampleStepBlocks) params, (address token, uint128 scorePerTokenPerBlock, uint64 startBlock)[] scoredTokens))",
  "function getClaimBoosters(uint256) view returns (uint256[])",
  "function coverPoolAssetListLength() view returns (uint256)",
  "function coverPoolAssetList(uint256) view returns (address)",
  "function totalAssets(address) view returns (uint256)",
  "function coverPoolAssets(address) view returns (uint256 totalShares, uint256 totalAssets, uint256 unstakingShares, uint128 rewardRate, uint64 periodFinish, uint64 lastUpdateTime, address usdPriceFeed, uint256 rewardPerShareStored)",
]);

export const CLAIM_REGISTERED = parseAbiItem(
  "event ClaimRegistered(uint256 indexed claimId, uint256 indexed incidentId, address indexed user, uint128 insuredTokenAmount, uint256 scoreToSpend, uint256[] boosterIds, uint256[] boosterAmounts)"
);
export const CLAIM_CANCELLED = parseAbiItem("event ClaimCancelled(uint256 indexed claimId, address indexed user)");
export const ERC20_TRANSFER = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 value)"
);

const FEED_ABI = parseAbi([
  "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
  "function decimals() view returns (uint8)",
]);
const ERC20_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
]);
const LEDGER_ABI = parseAbi(["function insuranceScoreSpent(address) view returns (uint256)"]);

// Mirror of the on-chain config structs (see CoverPool).
export interface SettlementParams {
  twapLookbackBlocks: bigint;
  holdingMarginBlocks: bigint;
  sampleStepBlocks: bigint;
}
export interface ScoredToken {
  token: `0x${string}`;
  scorePerTokenPerBlock: bigint;
  startBlock: bigint;
}
export interface IncidentConfig {
  coverageBps: bigint;
  priceOracle: `0x${string}`;
  underlyingConversionAddress: `0x${string}`;
  underlyingConversionCallData: `0x${string}`;
  params: SettlementParams;
  scoredTokens: ScoredToken[];
}

export function makeClient(rpcUrl: string): PublicClient {
  return createPublicClient({ transport: http(rpcUrl, { retryCount: 5 }) });
}

/** One register-or-cancel event, in true chain order. The contract chains
 *  `inputHash` in exactly this order, so the commitment must be replayed over
 *  this stream — NOT register-order with cancels folded in. */
export interface InputEvent {
  kind: "register" | "cancel";
  claimId: bigint;
  user: `0x${string}`;
  amount: bigint; // register only (escrow actually received)
  scoreToSpend: bigint; // register only — requested insurance score to spend
  boosterIds: bigint[]; // register only — committed booster tier ids
  boosterAmounts: bigint[]; // register only — units per id (parallel)
  blockNumber: bigint;
  logIndex: number;
}

function orderLogs<T extends { blockNumber: bigint; logIndex: number }>(a: T, b: T): number {
  return a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber);
}

/**
 * The incident's register/cancel events in chronological (block, logIndex)
 * order — the exact order the contract chained {Incident.inputHash}. Note
 * ClaimCancelled is not indexed by incidentId, so cancels are matched to this
 * incident by claimId membership.
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
      boosterIds: [...(r.args.boosterIds ?? [])],
      boosterAmounts: [...(r.args.boosterAmounts ?? [])],
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
        boosterIds: [] as bigint[],
        boosterAmounts: [] as bigint[],
        blockNumber: c.blockNumber!,
        logIndex: c.logIndex!,
      })),
  ];
  return events.sort(orderLogs);
}

/** Read the per-incident config snapshot frozen at open. */
export async function incidentConfigOf(client: PublicClient, incidentId: bigint): Promise<IncidentConfig> {
  return (await client.readContract({
    address: CONFIG.defiInsurance,
    abi: COVER_POOL_ABI,
    functionName: "getIncidentConfig",
    args: [incidentId],
  })) as IncidentConfig;
}

/** First block at which `incidentId` saw a claim — deterministic lower bound. */
export async function firstClaimBlockOf(
  client: PublicClient,
  incidentId: bigint,
  fromBlock: bigint,
  toBlock: bigint
): Promise<bigint> {
  const regs = await client.getLogs({
    address: CONFIG.defiInsurance,
    event: CLAIM_REGISTERED,
    args: { incidentId },
    fromBlock,
    toBlock,
  });
  if (regs.length === 0) throw new Error(`no claims for incident ${incidentId}`);
  return regs.reduce((m, r) => (r.blockNumber! < m ? r.blockNumber! : m), regs[0].blockNumber!);
}

/**
 * First block whose timestamp is ≥ `ts` (binary search). All settlement
 * reads anchor on the incident's window-end block found this way, making the
 * whole computation reproducible by anyone at any later time.
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
 * Insured-token → underlying ratio at `blockNumber`, as the contract's recipe
 * specifies: `staticcall(conversionAddress, conversionCallData)` → uint256
 * (WAD-normalized underlying-per-token). `address(0)` ⇒ identity (the token IS
 * the underlying, e.g. an LP), ratio = 1e18.
 */
export async function ratioAt(
  client: PublicClient,
  conversionAddress: `0x${string}`,
  conversionCallData: `0x${string}`,
  blockNumber: bigint
): Promise<bigint> {
  if (conversionAddress === "0x0000000000000000000000000000000000000000") return WAD;
  const res = await client.call({ to: conversionAddress, data: conversionCallData, blockNumber });
  return BigInt(res.data ?? "0x0");
}

/**
 * USD price from a Chainlink-style oracle at `blockNumber`, normalized to 1e18.
 * Reads the oracle's own `decimals()` and pins the block so the value is
 * reproducible. For non-USD/comparative/LP underlyings this points at one of
 * our adapters conforming to the same interface.
 */
export async function priceUsd1e18(
  client: PublicClient,
  oracle: `0x${string}`,
  blockNumber: bigint
): Promise<bigint> {
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

/** The insurance-score spend ledger — the CoverPool itself holds it. */
export async function insuranceScoreLedgerOf(_client: PublicClient): Promise<`0x${string}`> {
  return CONFIG.coverPool;
}

/** How much insurance score `user` has already spent, pinned at `blockNumber`. */
export async function insuranceScoreSpentOf(
  client: PublicClient,
  ledger: `0x${string}`,
  user: `0x${string}`,
  blockNumber: bigint
): Promise<bigint> {
  if (ledger === "0x0000000000000000000000000000000000000000") return 0n;
  return (await client.readContract({
    address: ledger,
    abi: LEDGER_ABI,
    functionName: "insuranceScoreSpent",
    args: [user],
    blockNumber,
  })) as bigint;
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

function sortedTransfers(outs: any[], ins: any[]) {
  return [...outs.map((l) => ({ l, sign: -1n })), ...ins.map((l) => ({ l, sign: 1n }))].sort((a, b) =>
    a.l.blockNumber === b.l.blockNumber
      ? Number(a.l.logIndex! - b.l.logIndex!)
      : Number(a.l.blockNumber! - b.l.blockNumber!)
  );
}

/**
 * Minimum balance of `who` in `token` over [fromBlock, toBlock], computed
 * exactly: start from balanceOf(fromBlock) and replay Transfer events. The
 * min over the window is what the holder provably kept the whole time — this
 * is also what makes cross-claimant dedupe automatic: tokens moved
 * wallet-to-wallet mid-window depress the sender's min after the transfer and
 * the receiver's min before it, so the same units can never count twice.
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
  for (const { l, sign } of sortedTransfers(outs, ins)) {
    bal += sign * (l.args.value as bigint);
    if (bal < min) min = bal;
  }
  return min;
}

/**
 * Cumulative token·block integral of `who`'s `token` balance over [fromBlock,
 * toBlock] — `Σ balance × blockDuration`. This is the USD8 insurance-score
 * primitive: a NON-expiring accumulator (not a time-weighted average), so
 * holding longer always grows the score. Event-replayed; weighted by block
 * distance; result is in token-base-units × blocks.
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
  for (const { l, sign } of sortedTransfers(outs, ins)) {
    acc += bal * (l.blockNumber! - cursor);
    cursor = l.blockNumber!;
    bal += sign * (l.args.value as bigint);
  }
  acc += bal * (toBlock - cursor);
  return acc;
}
