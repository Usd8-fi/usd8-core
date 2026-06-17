// All chain reads. Inside the enclave these go through the parent's
// vsock→TCP proxy; TLS terminates in here, so the parent can delay or drop
// traffic but never tamper with it.
import { createPublicClient, http, parseAbi, parseAbiItem, } from "viem";
import { CONFIG } from "./config.js";
export const COVER_POOL_ABI = parseAbi([
    "function incidents(uint256) view returns (address insuredToken, uint64 startTime, uint64 windowEndTime, bytes32 root, bytes32 inputHash, uint256 claimCount, uint256 resolvedCount)",
    "function claims(uint256) view returns (address user, uint256 incidentId, uint128 insuredTokenAmount, bool finalized, bool closed)",
    "function coverageBps(address) view returns (uint256)",
    "function assetListLength() view returns (uint256)",
    "function assetList(uint256) view returns (address)",
    "function totalAssets(address) view returns (uint256)",
]);
export const CLAIM_REGISTERED = parseAbiItem("event ClaimRegistered(uint256 indexed claimId, uint256 indexed incidentId, address indexed user, uint128 insuredTokenAmount)");
export const CLAIM_CANCELLED = parseAbiItem("event ClaimCancelled(uint256 indexed claimId, address indexed user)");
export const ERC20_TRANSFER = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 value)");
const ERC4626_ABI = parseAbi(["function convertToAssets(uint256) view returns (uint256)"]);
const FEED_ABI = parseAbi([
    "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
    "function decimals() view returns (uint8)",
]);
const ERC20_ABI = parseAbi(["function balanceOf(address) view returns (uint256)"]);
export function makeClient(rpcUrl) {
    return createPublicClient({ transport: http(rpcUrl, { retryCount: 5 }) });
}
function orderLogs(a, b) {
    return a.blockNumber === b.blockNumber
        ? a.logIndex - b.logIndex
        : Number(a.blockNumber - b.blockNumber);
}
/**
 * The incident's register/cancel events in chronological (block, logIndex)
 * order — the exact order the contract chained {Incident.inputHash}. Note
 * ClaimCancelled is not indexed by incidentId, so cancels are matched to this
 * incident by claimId membership.
 */
export async function readInputEvents(client, incidentId, fromBlock, toBlock) {
    const regs = await client.getLogs({
        address: CONFIG.coverPool,
        event: CLAIM_REGISTERED,
        args: { incidentId },
        fromBlock,
        toBlock,
    });
    const claimIds = new Set(regs.map((r) => r.args.claimId));
    const cancels = await client.getLogs({
        address: CONFIG.coverPool,
        event: CLAIM_CANCELLED,
        fromBlock,
        toBlock,
    });
    const events = [
        ...regs.map((r) => ({
            kind: "register",
            claimId: r.args.claimId,
            user: r.args.user,
            amount: r.args.insuredTokenAmount,
            blockNumber: r.blockNumber,
            logIndex: r.logIndex,
        })),
        ...cancels
            .filter((c) => claimIds.has(c.args.claimId))
            .map((c) => ({
            kind: "cancel",
            claimId: c.args.claimId,
            user: c.args.user,
            amount: 0n,
            blockNumber: c.blockNumber,
            logIndex: c.logIndex,
        })),
    ];
    return events.sort(orderLogs);
}
/** Live claimant table (registered, not cancelled), preserving register order. */
export function liveTable(events) {
    const cancelled = new Set(events.filter((e) => e.kind === "cancel").map((e) => e.claimId));
    return events
        .filter((e) => e.kind === "register")
        .map((e) => ({ claimId: e.claimId, user: e.user, amount: e.amount, cancelled: cancelled.has(e.claimId) }));
}
/** First block at which `incidentId` saw a claim — deterministic lower bound. */
export async function firstClaimBlockOf(client, incidentId, fromBlock, toBlock) {
    const regs = await client.getLogs({
        address: CONFIG.coverPool,
        event: CLAIM_REGISTERED,
        args: { incidentId },
        fromBlock,
        toBlock,
    });
    if (regs.length === 0)
        throw new Error(`no claims for incident ${incidentId}`);
    return regs.reduce((m, r) => (r.blockNumber < m ? r.blockNumber : m), regs[0].blockNumber);
}
/**
 * First block whose timestamp is ≥ `ts` (binary search). All settlement
 * reads anchor on the incident's window-end block found this way, making the
 * whole computation reproducible by anyone at any later time.
 */
export async function blockAtTimestamp(client, ts) {
    let lo = 1n;
    let hi = await client.getBlockNumber();
    if ((await client.getBlock({ blockNumber: hi })).timestamp < ts) {
        throw new Error(`timestamp ${ts} is in the future`);
    }
    while (lo < hi) {
        const mid = (lo + hi) / 2n;
        const t = (await client.getBlock({ blockNumber: mid })).timestamp;
        if (t < ts)
            lo = mid + 1n;
        else
            hi = mid;
    }
    return lo;
}
/** Token-per-underlying ratio at a historical block, 1e18-scaled. */
export async function ratioAt(client, cfg, blockNumber) {
    if (cfg.ratioSource.kind === "erc4626") {
        return (await client.readContract({
            address: cfg.token,
            abi: ERC4626_ABI,
            functionName: "convertToAssets",
            args: [10n ** 18n],
            blockNumber,
        }));
    }
    const res = await client.call({
        to: cfg.ratioSource.to,
        data: cfg.ratioSource.data,
        blockNumber,
    });
    return BigInt(res.data ?? "0x0");
}
/**
 * USD price from a Chainlink-style feed at `blockNumber`, normalized to 1e18.
 * Reads the feed's own `decimals()` (not hardcoded — feeds are 8 or 18) and
 * pins the block so the value is reproducible. `latestRoundData` at a
 * historical block returns the latest round as of that block: deterministic.
 */
export async function feedUsd1e18(client, feed, blockNumber) {
    const [, answer] = (await client.readContract({
        address: feed,
        abi: FEED_ABI,
        functionName: "latestRoundData",
        blockNumber,
    }));
    if (answer <= 0n)
        throw new Error(`feed ${feed} returned non-positive price`);
    const dec = (await client.readContract({
        address: feed,
        abi: FEED_ABI,
        functionName: "decimals",
        blockNumber,
    }));
    return BigInt(answer) * 10n ** (18n - BigInt(dec));
}
export async function balanceOfAt(client, token, who, blockNumber) {
    return (await client.readContract({
        address: token,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [who],
        blockNumber,
    }));
}
/**
 * Minimum balance of `who` in `token` over [fromBlock, toBlock], computed
 * exactly: start from balanceOf(fromBlock) and replay Transfer events. The
 * min over the window is what the holder provably kept the whole time —
 * this is also what makes cross-claimant dedupe automatic: tokens moved
 * wallet-to-wallet mid-window depress the sender's min after the transfer
 * and the receiver's min before it, so the same units can never count twice.
 */
export async function minBalanceOver(client, token, who, fromBlock, toBlock) {
    let bal = await balanceOfAt(client, token, who, fromBlock);
    let min = bal;
    const outs = await client.getLogs({
        address: token,
        event: ERC20_TRANSFER,
        args: { from: who },
        fromBlock: fromBlock + 1n,
        toBlock,
    });
    const ins = await client.getLogs({
        address: token,
        event: ERC20_TRANSFER,
        args: { to: who },
        fromBlock: fromBlock + 1n,
        toBlock,
    });
    const events = [...outs.map((l) => ({ l, sign: -1n })), ...ins.map((l) => ({ l, sign: 1n }))].sort((a, b) => a.l.blockNumber === b.l.blockNumber
        ? Number(a.l.logIndex - b.l.logIndex)
        : Number(a.l.blockNumber - b.l.blockNumber));
    for (const { l, sign } of events) {
        bal += sign * l.args.value;
        if (bal < min)
            min = bal;
    }
    return min;
}
/**
 * Time-weighted average balance of `who` in `token` over [fromBlock,
 * toBlock] (the USD8 history score primitive). Event-replayed, weighted by
 * block distance, 1e18-scale of the token itself.
 */
export async function twabOver(client, token, who, fromBlock, toBlock) {
    let bal = await balanceOfAt(client, token, who, fromBlock);
    const outs = await client.getLogs({
        address: token,
        event: ERC20_TRANSFER,
        args: { from: who },
        fromBlock: fromBlock + 1n,
        toBlock,
    });
    const ins = await client.getLogs({
        address: token,
        event: ERC20_TRANSFER,
        args: { to: who },
        fromBlock: fromBlock + 1n,
        toBlock,
    });
    const events = [...outs.map((l) => ({ l, sign: -1n })), ...ins.map((l) => ({ l, sign: 1n }))].sort((a, b) => a.l.blockNumber === b.l.blockNumber
        ? Number(a.l.logIndex - b.l.logIndex)
        : Number(a.l.blockNumber - b.l.blockNumber));
    let acc = 0n;
    let cursor = fromBlock;
    for (const { l, sign } of events) {
        acc += bal * (l.blockNumber - cursor);
        cursor = l.blockNumber;
        bal += sign * l.args.value;
    }
    acc += bal * (toBlock - cursor);
    const span = toBlock - fromBlock;
    return span === 0n ? bal : acc / span;
}
