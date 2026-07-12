import { describe, it, expect } from "vitest";
import { getLogsChunked } from "../src/chain.js";

// A provider that SILENTLY TRUNCATES: it returns at most `cap` logs per request,
// in (block, logIndex) order, with no error — exactly the failure mode audit H-A
// warns about. getLogsChunked must still recover every log by bisecting.
function truncatingClient(logs: { blockNumber: bigint; logIndex: number }[], cap: number) {
  const requests: Array<{ from: bigint; to: bigint }> = [];
  return {
    requests,
    getLogs: async ({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) => {
      requests.push({ from: fromBlock, to: toBlock });
      const inRange = logs
        .filter((l) => l.blockNumber >= fromBlock && l.blockNumber <= toBlock)
        .sort((a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber)));
      return inRange.slice(0, cap); // silent cap
    },
  } as any;
}

const key = (l: { blockNumber: bigint; logIndex: number }) => `${l.blockNumber}:${l.logIndex}`;
const Q = { address: "0x0000000000000000000000000000000000000001" as const, event: {} };

describe("getLogsChunked — H-A truncation safety", () => {
  it("recovers ALL logs when the provider silently caps results (bisects)", async () => {
    // 25k logs inside a single 10k-block window, provider caps at the module's
    // 10k page — forces repeated bisection to page everything in.
    const logs = Array.from({ length: 25_000 }, (_, i) => ({ blockNumber: BigInt((i % 10_000) + 1), logIndex: i }));
    const client = truncatingClient(logs, 10_000);

    const got = await getLogsChunked(client, Q, 1n, 10_000n);

    expect(got.length).toBe(25_000);
    expect(new Set(got.map(key)).size).toBe(25_000); // no duplicates, no drops
    // Bisection actually happened (more than the one naive request).
    expect(client.requests.length).toBeGreaterThan(1);
  });

  it("returns [] for an inverted range (degenerate window, L-C) without querying", async () => {
    const client = truncatingClient([], 10_000);
    const got = await getLogsChunked(client, Q, 100n, 99n);
    expect(got).toEqual([]);
    expect(client.requests.length).toBe(0);
  });

  it("chunks a large range into bounded sub-requests and merges in order", async () => {
    // Sparse logs across 45k blocks → several MAX_LOG_RANGE chunks, none capped.
    const logs = [1n, 9_999n, 10_001n, 30_000n, 45_000n].map((b, i) => ({ blockNumber: b, logIndex: i }));
    const client = truncatingClient(logs, 10_000);

    const got = await getLogsChunked(client, Q, 1n, 45_000n);

    expect(got.map(key)).toEqual(logs.map(key)); // all recovered, in range order
    // 45k blocks / 10k per request = 5 chunks, none needing a bisect.
    expect(client.requests.length).toBe(5);
    for (const r of client.requests) expect(r.to - r.from).toBeLessThan(10_000n);
  });
});
