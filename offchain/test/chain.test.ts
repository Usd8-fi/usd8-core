import { describe, it, expect } from "vitest";
import { getLogsChunked } from "../src/chain.js";
import { LOG_RESULT_CAP, MAX_LOG_RANGE } from "../src/config.js";

const CAP = Number(LOG_RESULT_CAP);
const RANGE = Number(MAX_LOG_RANGE);

// A provider that SILENTLY TRUNCATES: returns at most `cap` logs per request, in
// (block, logIndex) order, with no error — exactly the M-01 failure mode. The
// settler must recover everything by bisecting, or fail closed when it can't.
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

describe("getLogsChunked — M-01 truncation safety", () => {
  it("recovers ALL logs when the provider silently caps results (bisects)", async () => {
    // 3x the cap spread across a MAX_LOG_RANGE window → each request over-caps and
    // must bisect down until every page is complete. Density stays well under the
    // cap per block, so no single block is ambiguous.
    const n = CAP * 3;
    const logs = Array.from({ length: n }, (_, i) => ({ blockNumber: BigInt((i % RANGE) + 1), logIndex: i }));
    const client = truncatingClient(logs, CAP);

    const got = await getLogsChunked(client, Q, 1n, BigInt(RANGE));

    expect(got.length).toBe(n);
    expect(new Set(got.map(key)).size).toBe(n); // no drops, no dupes
    expect(client.requests.length).toBeGreaterThan(1); // bisection happened
  });

  it("FAILS CLOSED when a single block returns a full (possibly truncated) page", async () => {
    // 2x the cap all in one block: nothing left to split, completeness unprovable.
    const logs = Array.from({ length: CAP * 2 }, (_, i) => ({ blockNumber: 5n, logIndex: i }));
    const client = truncatingClient(logs, CAP);
    await expect(getLogsChunked(client, Q, 5n, 5n)).rejects.toThrow(/cannot prove completeness/);
  });

  it("returns [] for an inverted range without querying (degenerate window, L-C)", async () => {
    const client = truncatingClient([], CAP);
    const got = await getLogsChunked(client, Q, 100n, 99n);
    expect(got).toEqual([]);
    expect(client.requests.length).toBe(0);
  });

  it("bounds every sub-request to MAX_LOG_RANGE blocks and merges in order", async () => {
    const logs = [1n, BigInt(RANGE - 1), BigInt(RANGE + 1), BigInt(RANGE * 3)].map((b, i) => ({
      blockNumber: b,
      logIndex: i,
    }));
    const client = truncatingClient(logs, CAP);
    const got = await getLogsChunked(client, Q, 1n, BigInt(RANGE * 3));
    expect(got.map(key)).toEqual(logs.map(key));
    for (const r of client.requests) expect(r.to - r.from).toBeLessThan(BigInt(RANGE));
  });
});
