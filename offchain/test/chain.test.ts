import { describe, it, expect } from "vitest";
import { getLogsChunked, makeClient, priceUsd1e18 } from "../src/chain.js";
import { LOG_RESULT_CAP, MAX_LOG_RANGE, MAX_ORACLE_STALENESS } from "../src/config.js";

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
const ORACLE = "0x0000000000000000000000000000000000000002" as const;

describe("makeClient — authenticated single dRPC endpoint", () => {
  it.each([
    "https://arbitrary.example",
    "http://lb.drpc.org/ogrpc?network=ethereum",
    "https://lb.drpc.org:8443/ogrpc?network=ethereum",
    "https://user@lb.drpc.org/ogrpc?network=ethereum",
  ])("refuses to send a dRPC key to untrusted endpoint %s", (endpoint) => {
    expect(() => makeClient(endpoint, "test-drpc-key")).toThrow(/refusing to send DRPC_KEY/);
  });

  it("sends the dRPC key as a header rather than embedding it in the URL", async () => {
    const endpoint = "https://lb.drpc.org/ogrpc?network=ethereum";
    const originalFetch = globalThis.fetch;
    let receivedKey: string | null = null;
    let receivedUrl: string | undefined;
    let receivedRedirect: RequestRedirect | undefined;

    globalThis.fetch = (async (input, init) => {
      const request = new Request(input, init);
      receivedKey = request.headers.get("Drpc-Key");
      receivedUrl = request.url;
      receivedRedirect = request.redirect;
      return new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, result: "0x1" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;

    try {
      const client = makeClient(endpoint, "test-drpc-key");
      await expect(client.getChainId()).resolves.toBe(1);
      expect(receivedKey).toBe("test-drpc-key");
      expect(receivedUrl).toBe(endpoint);
      expect(receivedUrl).not.toContain("test-drpc-key");
      expect(receivedRedirect).toBe("error");
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

function oracleClient({
  roundId = 7n,
  answer = 100_000_000n,
  startedAt = 900n,
  updatedAt = 950n,
  answeredInRound = 7n,
  blockTs = 1_000n,
} = {}) {
  return {
    readContract: async ({ functionName }: { functionName: string }) => {
      if (functionName === "latestRoundData") return [roundId, answer, startedAt, updatedAt, answeredInRound];
      if (functionName === "decimals") return 8;
      throw new Error(`unexpected read ${functionName}`);
    },
    getBlock: async () => ({ timestamp: blockTs }),
  } as any;
}

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

  it("bisects and recovers when dRPC rejects an oversized or timed-out range", async () => {
    const logs = Array.from({ length: 20 }, (_, i) => ({ blockNumber: BigInt(i + 1), logIndex: i }));
    const requests: Array<{ from: bigint; to: bigint }> = [];
    const client = {
      getLogs: async ({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) => {
        requests.push({ from: fromBlock, to: toBlock });
        if (toBlock - fromBlock + 1n > 5n) throw new Error("Request timeout: query duration limit exceeded");
        return logs.filter((log) => log.blockNumber >= fromBlock && log.blockNumber <= toBlock);
      },
    } as any;

    const got = await getLogsChunked(client, Q, 1n, 20n);

    expect(got.map(key)).toEqual(logs.map(key));
    expect(requests.some((request) => request.to - request.from + 1n > 5n)).toBe(true);
    expect(requests.filter((request) => request.to - request.from + 1n <= 5n).length).toBeGreaterThan(1);
  });

  it("does not bisect unrelated rate-limit or quota failures", async () => {
    let requests = 0;
    const client = {
      getLogs: async () => {
        requests++;
        throw new Error("rate limit exceeded");
      },
    } as any;

    await expect(getLogsChunked(client, Q, 1n, 20n)).rejects.toThrow("rate limit exceeded");
    expect(requests).toBe(1);
  });

  it("does not retry a recognized range failure once bisection reaches one block", async () => {
    let requests = 0;
    const client = {
      getLogs: async () => {
        requests++;
        throw new Error("block range too large");
      },
    } as any;

    await expect(getLogsChunked(client, Q, 7n, 7n)).rejects.toThrow("block range too large");
    expect(requests).toBe(1);
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

describe("priceUsd1e18 — L-02 pinned-block round validity", () => {
  it("rejects an oracle update timestamp later than the pinned block", async () => {
    const client = oracleClient({ updatedAt: 1_001n, blockTs: 1_000n });
    await expect(priceUsd1e18(client, ORACLE, 123n)).rejects.toThrow(/later than pinned block/);
  });

  it("rejects a round whose start timestamp is after its update", async () => {
    const client = oracleClient({ startedAt: 951n, updatedAt: 950n });
    await expect(priceUsd1e18(client, ORACLE, 123n)).rejects.toThrow(/startedAt.*after updatedAt/);
  });

  it("rejects answeredInRound older than roundId", async () => {
    const client = oracleClient({ roundId: 7n, answeredInRound: 6n });
    await expect(priceUsd1e18(client, ORACLE, 123n)).rejects.toThrow(/answeredInRound.*older than roundId/);
  });

  it("accepts a complete round updated exactly at the pinned block timestamp", async () => {
    const client = oracleClient({ startedAt: 999n, updatedAt: 1_000n, blockTs: 1_000n });
    await expect(priceUsd1e18(client, ORACLE, 123n)).resolves.toBe(10n ** 18n);
  });

  it("rejects a round older than the committed staleness policy", async () => {
    const blockTs = 100_000n;
    const client = oracleClient({ updatedAt: blockTs - MAX_ORACLE_STALENESS - 1n, blockTs });
    await expect(priceUsd1e18(client, ORACLE, 123n)).rejects.toThrow(/stale/);
  });
});
