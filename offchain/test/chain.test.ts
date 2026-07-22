import { describe, it, expect } from "vitest";
import {
  assertBlockAnchorsUnchanged,
  assertContractCodeAt,
  finalizedSettlementAnchors,
  getLogsChunked,
  incidentTeePcrHashAt,
  makeClient,
  minBalanceOver,
  minErc1155BalanceOver,
  priceUsd1e18,
  ratioAt,
  rpcMetricsOf,
  tokenBlockIntegral,
} from "../src/chain.js";
import { CONFIG, LOG_RESULT_CAP, MAX_LOG_RANGE } from "../src/config.js";

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
const blockHash = (n: bigint) => `0x${n.toString(16).padStart(64, "0")}` as `0x${string}`;

describe("incident TEE PCR commitment", () => {
  it("reads the incident snapshot and rejects an unset commitment", async () => {
    const hash = `0x${"44".repeat(32)}` as `0x${string}`;
    let request: any;
    const client = (value: `0x${string}`) => ({
      readContract: async (next: any) => {
        request = next;
        return value;
      },
    }) as any;
    await expect(incidentTeePcrHashAt(client(hash), 7n, 100n)).resolves.toBe(hash);
    expect(request).toMatchObject({
      address: CONFIG.defiInsurance,
      functionName: "incidentTeePcrHash",
      args: [7n],
      blockNumber: 100n,
    });
    await expect(incidentTeePcrHashAt(client(`0x${"0".repeat(64)}`), 7n, 100n)).rejects.toThrow(
      /incident teePcrHash is zero/
    );
  });
});

describe("makeClient — authenticated single dRPC endpoint", () => {
  it("rejects an invalid transport timeout", () => {
    expect(() => makeClient("https://rpc.example", undefined, 0)).toThrow(/timeout/);
    expect(() => makeClient("https://rpc.example", undefined, 1.5)).toThrow(/timeout/);
  });

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
      expect(rpcMetricsOf(client)).toMatchObject({
        rpcRequests: 1,
        transportRequests: 1,
        transportResponses: 1,
        transportRetries: 0,
      });
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("counts transport retries separately from logical RPC calls", async () => {
    const originalFetch = globalThis.fetch;
    let attempts = 0;
    globalThis.fetch = (async (input, init) => {
      attempts++;
      if (attempts === 1) return new Response("temporary", { status: 500 });
      const request = new Request(input, init);
      const body = JSON.parse(await request.text()) as { id: number };
      return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, result: "0x1" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;

    try {
      const client = makeClient("https://rpc.example", undefined);
      await expect(client.getChainId()).resolves.toBe(1);
      expect(rpcMetricsOf(client)).toMatchObject({
        rpcRequests: 1,
        transportRequests: 2,
        transportResponses: 2,
        transportRetries: 1,
      });
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

describe("finalized settlement anchors", () => {
  it("finds the last in-window block under the finalized head and records every anchor hash", async () => {
    const client = {
      getBlock: async ({ blockNumber, blockTag }: { blockNumber?: bigint; blockTag?: string }) => {
        const number = blockTag === "finalized" ? 10n : blockNumber!;
        return { number, timestamp: number * 12n, hash: blockHash(number) };
      },
    } as any;

    const anchors = await finalizedSettlementAnchors(client, 3n, 4n, 65n);

    expect(anchors.reference).toEqual({ number: 3n, timestamp: 36n, hash: blockHash(3n) });
    expect(anchors.open).toEqual({ number: 4n, timestamp: 48n, hash: blockHash(4n) });
    expect(anchors.windowEnd).toEqual({ number: 5n, timestamp: 60n, hash: blockHash(5n) });
    expect(anchors.finalizedHead).toEqual({ number: 10n, timestamp: 120n, hash: blockHash(10n) });
  });

  it("fails closed when an anchor hash changes before output", async () => {
    const hashes = new Map<bigint, `0x${string}`>();
    const client = {
      getBlock: async ({ blockNumber, blockTag }: { blockNumber?: bigint; blockTag?: string }) => {
        const number = blockTag === "finalized" ? 10n : blockNumber!;
        return { number, timestamp: number * 12n, hash: hashes.get(number) ?? blockHash(number) };
      },
    } as any;
    const anchors = await finalizedSettlementAnchors(client, 3n, 4n, 65n);
    hashes.set(5n, `0x${"ff".repeat(32)}`);

    await expect(assertBlockAnchorsUnchanged(client, anchors)).rejects.toThrow(/anchor hash changed.*windowEnd/);
  });

  it("refuses to compute before the claim-window boundary is finalized", async () => {
    const client = {
      getBlock: async ({ blockNumber, blockTag }: { blockNumber?: bigint; blockTag?: string }) => {
        const number = blockTag === "finalized" ? 5n : blockNumber!;
        return { number, timestamp: number * 12n, hash: blockHash(number) };
      },
    } as any;

    await expect(finalizedSettlementAnchors(client, 3n, 4n, 65n)).rejects.toThrow(/claim window is not finalized/);
  });
});

describe("contract-code bootstrap checks", () => {
  it("accepts deployed code and rejects EOAs or empty historical addresses", async () => {
    const deployed = { getBytecode: async () => "0x6000" } as any;
    const empty = { getBytecode: async () => "0x" } as any;

    await expect(assertContractCodeAt(deployed, Q.address, "Registry", 10n)).resolves.toBeUndefined();
    await expect(assertContractCodeAt(empty, Q.address, "Registry", 10n)).rejects.toThrow(/Registry.*no bytecode.*10/);
  });
});

describe("ratioAt — conversion returndata validation", () => {
  const conversion = "0x0000000000000000000000000000000000000003" as const;
  const callData = "0x12345678" as const;

  it.each([
    ["empty", undefined],
    ["short", "0x01"],
    ["long", `0x${"01".repeat(33)}`],
    ["zero", `0x${"00".repeat(32)}`],
  ])("fails closed on %s conversion returndata", async (_name, data) => {
    const client = { call: async () => ({ data }) } as any;
    await expect(ratioAt(client, conversion, callData, 10n)).rejects.toThrow(/conversion.*return|non-positive/i);
  });

  it("decodes one ABI uint256", async () => {
    const data = `0x${(2n * 10n ** 18n).toString(16).padStart(64, "0")}` as const;
    const client = { call: async () => ({ data }) } as any;
    await expect(ratioAt(client, conversion, callData, 10n)).resolves.toBe(2n * 10n ** 18n);
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
    expect(rpcMetricsOf(client)).toMatchObject({
      logRequests: client.requests.length,
      logBisections: expect.any(Number),
      logErrors: 0,
    });
    expect(rpcMetricsOf(client).logBisections).toBeGreaterThan(0);
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
    CONFIG.maxOracleStaleness = 86_400n;
    const client = oracleClient({ updatedAt: blockTs - CONFIG.maxOracleStaleness - 1n, blockTs });
    await expect(priceUsd1e18(client, ORACLE, 123n)).rejects.toThrow(/stale/);
  });
});

describe("ERC-20 balance replay — L-02 semantic safety", () => {
  const hiddenBalanceChangeClient = () =>
    ({
      readContract: async ({ blockNumber }: { blockNumber: bigint }) => (blockNumber === 10n ? 100n : 110n),
      getLogs: async () => [],
    }) as any;

  it("fails closed when eligibility balance changes without a Transfer event", async () => {
    await expect(minBalanceOver(hiddenBalanceChangeClient(), Q.address, ORACLE, 10n, 20n)).rejects.toThrow(
      /unsupported token balance semantics/
    );
  });

  it("fails closed when score balance changes without a Transfer event", async () => {
    await expect(tokenBlockIntegral(hiddenBalanceChangeClient(), Q.address, ORACLE, 10n, 20n)).rejects.toThrow(
      /unsupported token balance semantics/
    );
  });
});

describe("ERC-1155 balance replay — booster semantic safety", () => {
  it("fails closed when the endpoint balance changes without a transfer log", async () => {
    const client = {
      readContract: async ({ blockNumber }: { blockNumber: bigint }) => (blockNumber === 10n ? 3n : 2n),
      getLogs: async () => [],
    } as any;

    await expect(minErc1155BalanceOver(client, Q.address, ORACLE, 1n, 10n, 20n)).rejects.toThrow(
      /unsupported ERC-1155 balance semantics/
    );
  });
});
