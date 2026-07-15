import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { encodeAbiParameters, hashTypedData, keccak256 } from "viem";

// Replace the chain-reading helpers with deterministic stubs so the pure
// settlement algorithm can be exercised without an RPC. earnedScoreOf /
// twapRatioBefore are NOT mocked — they run for real over the stubbed reads.
const h = vi.hoisted(() => ({
  integrals: new Map<string, bigint>(),
  minBalances: new Map<string, bigint>(),
  boosterBalances: new Map<string, bigint>(),
  // When true, tokenBlockIntegral returns the WINDOW LENGTH (to−from) — a balance≡1
  // proxy — so the piecewise rate-timeline tests can check per-segment integration.
  windowMode: false,
}));

vi.mock("../src/chain.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/chain.js")>();
  return {
    ...actual,
    ratioAt: vi.fn(async () => actual.WAD), // token→underlying ratio = 1.0
    priceUsd1e18: vi.fn(async () => actual.WAD), // underlying = $1
    minBalanceOver: vi.fn(async (_c: any, _t: any, who: string) => h.minBalances.get(who.toLowerCase()) ?? 10_000n * actual.WAD),
    minErc1155BalanceOver: vi.fn(async (_c: any, _col: any, who: string) => h.boosterBalances.get(who.toLowerCase()) ?? 0n),
    tokenBlockIntegral: vi.fn(async (_c: any, _t: any, who: string, from: bigint, to: bigint) =>
      h.windowMode ? to - from : (h.integrals.get(who.toLowerCase()) ?? 0n)
    ),
  };
});

import * as chain from "../src/chain.js";
import {
  settle,
  earnedScoreOf,
  settlementInputHashOf,
  settlementTree,
  settlementTypedData,
  LEAF_ENCODING,
} from "../src/compute.js";
import { RpcScoreSource } from "../src/score.js";
import type { IncidentConfig, InputEvent } from "../src/chain.js";

beforeEach(() => vi.clearAllMocks());

const WAD = 10n ** 18n;
const ALICE = "0x000000000000000000000000000000000000a11c" as const;
const BOB = "0x000000000000000000000000000000000000b0b0" as const;
const CAROL = "0x000000000000000000000000000000000000ca50" as const;
const INS = "0x0000000000000000000000000000000000001115" as const;
const ASSET = "0x0000000000000000000000000000000000000a55" as const;
const SCORED = "0x0000000000000000000000000000000000005c04" as const;
const ORACLE = "0x000000000000000000000000000000000000044c" as const;
const BOOSTER = "0x00000000000000000000000000000000b0057e40" as const;
const ZERO = "0x0000000000000000000000000000000000000000" as const;

const cfg: IncidentConfig = {
  coverageBps: 8000n, // κ = 80%
  underlyingPriceOracle: ORACLE,
  underlyingConversionAddress: ZERO,
  underlyingConversionCallData: "0x",
  params: { twapLookbackBlocks: 10n, holdingMarginBlocks: 5n, sampleStepBlocks: 5n },
  scoredTokens: [{ token: SCORED, rates: [{ fromBlock: 0n, rate: WAD }], decimals: 18 }], // 1e18 = 1.0/token/block
};

function reg(claimId: bigint, user: `0x${string}`, amount: bigint, scoreToSpend: bigint): InputEvent {
  // joinBlock after referenceBlock (100): bob joins at 105, carol at 106.
  return { kind: "register", claimId, user, amount, scoreToSpend, boosterAmount: 0n, blockNumber: 104n + claimId, logIndex: 0 };
}

function baseOpts(assetBalance: bigint) {
  return {
    insuredToken: INS,
    insuredDecimals: 18,
    referenceBlock: 100n,
    windowEndBlock: 110n,
    poolOrder: [ASSET] as `0x${string}`[],
    poolAddrs: [ASSET] as `0x${string}`[],
    poolBalances: [assetBalance],
    poolAssetUsd1e18: [WAD], // $1 per asset token
    poolAssetDecimals: [18],
    boosterCollection: BOOSTER,
    boosterId: 1n,
    grossScoreOf: vi.fn(async (u: `0x${string}`) => h.integrals.get(u.toLowerCase()) ?? 0n),
    spentOf: (_u: `0x${string}`) => 0n,
    maxCoverPoolPayoutBps: 10_000n, // no per-incident cap by default; a dedicated test exercises it
  };
}

describe("settle — payout math", () => {
  // bob earns score 60, carol 40; both lose $100 of an equal escrow.
  const events = [reg(1n, BOB, 100n * WAD, 60n), reg(2n, CAROL, 100n * WAD, 40n)];
  function setEarned() {
    h.integrals.clear();
    h.minBalances.clear();
    h.integrals.set(BOB.toLowerCase(), 60n);
    h.integrals.set(CAROL.toLowerCase(), 40n);
  }

  it("uses both covered need and spent score, while zero-cap score has zero allocation weight", async () => {
    h.integrals.clear();
    h.minBalances.clear();
    h.integrals.set(BOB.toLowerCase(), 100n);
    h.integrals.set(CAROL.toLowerCase(), 100n);
    h.integrals.set(ALICE.toLowerCase(), 2_000_000n);

    const geometricEvents = [
      reg(1n, BOB, 45n * WAD, 100n), // claim cap = $36; sqrt(36e18 × 100) = 60e9
      reg(2n, CAROL, 80n * WAD, 100n), // claim cap = $64; sqrt(64e18 × 100) = 80e9
      reg(3n, ALICE, 1n, 2_000_000n), // claim cap floors to zero, so weight must be zero
    ];

    const s = await settle({} as any, 1n, cfg, geometricEvents, baseOpts(70n * WAD));

    // Equal score does not mean equal payout: covered need also contributes to weight.
    // The zero-cap/high-score row cannot dilute either meaningful claimant.
    expect(s.rows.map((r) => r.payoutUsd)).toEqual([30n * WAD, 40n * WAD, 0n]);
    expect(s.poolPayouts).toEqual([70n * WAD]);
  });

  it("redistributes a saturated claim's unused geometric share without exceeding any claim cap", async () => {
    h.integrals.clear();
    h.minBalances.clear();
    h.integrals.set(ALICE.toLowerCase(), 90n);
    h.integrals.set(BOB.toLowerCase(), 100n);
    h.integrals.set(CAROL.toLowerCase(), 100n);

    const cappedEvents = [
      reg(1n, ALICE, (25n * WAD) / 2n, 90n), // cap $10, geometric weight 30e9
      reg(2n, BOB, 45n * WAD, 100n), // cap $36, geometric weight 60e9
      reg(3n, CAROL, 80n * WAD, 100n), // cap $64, geometric weight 80e9
    ];

    const s = await settle({} as any, 1n, cfg, cappedEvents, baseOpts(80n * WAD));

    // Alice's initial geometric share is above her $10 cap. The unused amount is
    // recomputed across Bob and Carol at their 60:80 weight ratio.
    expect(s.rows.map((r) => r.payoutUsd)).toEqual([10n * WAD, 30n * WAD, 40n * WAD]);
    expect(s.poolPayouts).toEqual([80n * WAD]);
  });

  it("produces the same payout per claim regardless of claimant-table order", async () => {
    h.integrals.clear();
    h.minBalances.clear();
    h.integrals.set(ALICE.toLowerCase(), 90n);
    h.integrals.set(BOB.toLowerCase(), 100n);
    h.integrals.set(CAROL.toLowerCase(), 100n);
    const ordered = [
      reg(1n, ALICE, (25n * WAD) / 2n, 90n),
      reg(2n, BOB, 45n * WAD, 100n),
      reg(3n, CAROL, 80n * WAD, 100n),
    ];

    const forward = await settle({} as any, 1n, cfg, ordered, baseOpts(80n * WAD));
    const reversed = await settle({} as any, 1n, cfg, [...ordered].reverse(), baseOpts(80n * WAD));
    const byClaimId = (rows: typeof forward.rows) =>
      [...rows]
        .sort((a, b) => (a.claimId < b.claimId ? -1 : a.claimId > b.claimId ? 1 : 0))
        .map((row) => [row.claimId, row.payoutUsd]);

    expect(byClaimId(reversed.rows)).toEqual(byClaimId(forward.rows));
  });

  it("is neutral to proportional splitting of both covered need and spent score", async () => {
    h.integrals.clear();
    h.minBalances.clear();
    h.integrals.set(BOB.toLowerCase(), 100n);
    const single = await settle(
      {} as any,
      1n,
      cfg,
      [reg(1n, BOB, 100n * WAD, 100n)],
      baseOpts(40n * WAD)
    );

    h.integrals.set(BOB.toLowerCase(), 50n);
    h.integrals.set(CAROL.toLowerCase(), 50n);
    const split = await settle(
      {} as any,
      1n,
      cfg,
      [reg(1n, BOB, 50n * WAD, 50n), reg(2n, CAROL, 50n * WAD, 50n)],
      baseOpts(40n * WAD)
    );

    expect(single.rows[0].payoutUsd).toBe(40n * WAD);
    expect(split.rows.map((row) => row.payoutUsd)).toEqual([20n * WAD, 20n * WAD]);
  });

  it("scarce pool → equal-need payouts use the square root of spent score", async () => {
    setEarned();
    // Both caps are $80, so covered need is equal and the weights differ only by
    // sqrt(scoreSpent). Integer division leaves one wei of deterministic dust.
    const s = await settle({} as any, 1n, cfg, events, baseOpts(100n * WAD));

    expect(s.rows.map((r) => r.scoreSpent)).toEqual([60n, 40n]);
    expect(s.rows.map((r) => r.eligibleAmount)).toEqual([100n * WAD, 100n * WAD]);
    expect(s.rows.map((r) => r.lossUsd)).toEqual([100n * WAD, 100n * WAD]);
    expect(s.rows.map((r) => r.earnedScore)).toEqual([60n, 40n]);
    const expected = [55_051_025_721_816_600_736n, 44_948_974_278_183_399_263n];
    expect(s.rows.map((r) => r.payoutUsd)).toEqual(expected);
    expect(s.rows.map((r) => r.amounts)).toEqual(expected.map((amount) => [amount]));
    expect(s.rows.reduce((a, r) => a + r.amounts[0], 0n)).toEqual(100n * WAD - 1n);
    expect(s.poolPayouts).toEqual([100n * WAD - 1n]);
  });

  it("uses the per-incident LP-loss cap as the geometric allocation budget", async () => {
    setEarned();
    // The 80% pool cap makes $80 the water-filling budget from the outset.
    const s = await settle({} as any, 1n, cfg, events, { ...baseOpts(100n * WAD), maxCoverPoolPayoutBps: 8000n });
    const expected = [44_040_820_577_453_280_589n, 35_959_179_422_546_719_410n];
    expect(s.rows.map((r) => r.payoutUsd)).toEqual(expected);
    expect(s.rows.map((r) => r.amounts)).toEqual(expected.map((amount) => [amount]));
    expect(s.poolPayouts).toEqual([80n * WAD - 1n]); // one wei dust stays in the pool
  });

  it("abundant pool → payouts bound by κ·loss cap", async () => {
    setEarned();
    // The $10,000 incident budget exceeds the $160 aggregate covered need, so
    // water-filling saturates both claims at their $80 caps.
    const s = await settle({} as any, 1n, cfg, events, baseOpts(10_000n * WAD));
    expect(s.rows.map((r) => r.payoutUsd)).toEqual([80n * WAD, 80n * WAD]); // 80% of $100
    expect(s.rows.map((r) => r.amounts)).toEqual([[80n * WAD], [80n * WAD]]);
  });

  it("requested score is capped to available; over-request just clamps", async () => {
    setEarned();
    const overReq = [reg(1n, BOB, 100n * WAD, 1000n), reg(2n, CAROL, 100n * WAD, 40n)];
    const s = await settle({} as any, 1n, cfg, overReq, baseOpts(100n * WAD));
    expect(s.rows[0].scoreSpent).toEqual(60n); // clamped to earned 60, not 1000
  });

  it("prior spent score is subtracted from availability", async () => {
    setEarned();
    const opts = { ...baseOpts(100n * WAD), spentOf: (u: `0x${string}`) => (u === BOB ? 50n : 0n) };
    const s = await settle({} as any, 1n, cfg, events, opts);
    expect(s.rows[0].scoreSpent).toEqual(10n); // 60 earned − 50 spent
  });

  it("eligibility is capped by the minimum held balance", async () => {
    setEarned();
    h.minBalances.set(BOB.toLowerCase(), 30n * WAD); // bob only continuously held 30
    const s = await settle({} as any, 1n, cfg, events, baseOpts(10_000n * WAD));
    expect(s.rows[0].eligibleAmount).toEqual(30n * WAD);
    expect(s.rows[0].lossUsd).toEqual(30n * WAD);
  });

  it("eligibility ends at referenceBlock and settlement obtains score through its provider", async () => {
    setEarned();
    const opts = baseOpts(100n * WAD); // referenceBlock=100, windowEndBlock=110; joins at 105/106
    await settle({} as any, 1n, cfg, events, opts);
    // Insured-token min-balance is anchored ENTIRELY pre-incident: the window ends at
    // referenceBlock for every claim, so transfers after the incident are ignored
    // (finalize refunds any over-escrow).
    const elig = (chain.minBalanceOver as unknown as { mock: { calls: any[][] } }).mock.calls;
    expect(elig.map((c) => c[1])).toEqual([opts.insuredToken, opts.insuredToken]);
    expect(elig.map((c) => c[4])).toEqual(events.map(() => opts.referenceBlock)); // both end at referenceBlock (100)
    // Settlement no longer knows how score was produced; it consumes the injected
    // gross-score provider. The Phase-1 RpcScoreSource pins its own referenceBlock.
    const score = (opts.grossScoreOf as unknown as { mock: { calls: any[][] } }).mock.calls;
    expect(score.map((c) => c[0])).toEqual([BOB, CAROL]);
    expect((chain.tokenBlockIntegral as unknown as { mock: { calls: any[][] } }).mock.calls).toHaveLength(0);
  });

  it("no live claims → zero root, empty rows (L-D, no crash)", async () => {
    setEarned();
    // Every registered claim cancelled → rows empty. Must NOT throw in
    // StandardMerkleTree.of([]); returns the zero root instead.
    const allCancelled: InputEvent[] = [
      reg(1n, BOB, 100n * WAD, 60n),
      { kind: "cancel", claimId: 1n, user: BOB, amount: 0n, scoreToSpend: 0n, boosterAmount: 0n, blockNumber: 5n, logIndex: 0 },
    ];
    const s = await settle({} as any, 1n, cfg, allCancelled, baseOpts(100n * WAD));
    expect(s.rows).toEqual([]);
    expect(s.root).toBe(`0x${"0".repeat(64)}`);
    expect(s.poolPayouts).toEqual([0n]);
  });

  it("cancelled claims are excluded", async () => {
    setEarned();
    const withCancel: InputEvent[] = [
      ...events,
      { kind: "cancel", claimId: 2n, user: CAROL, amount: 0n, scoreToSpend: 0n, boosterAmount: 0n, blockNumber: 5n, logIndex: 0 },
    ];
    const s = await settle({} as any, 1n, cfg, withCancel, baseOpts(100n * WAD));
    expect(s.rows.map((r) => r.claimId)).toEqual([1n]); // carol dropped
    expect(s.settlementInputHash).toBe(settlementInputHashOf([{ user: BOB, grossEarnedScore: 60n }]));
  });
});

describe("earnedScoreOf — raw lifetime score", () => {
  it("is the un-boosted integral × rate (booster applied later, on the unspent remainder)", async () => {
    h.integrals.set(BOB.toLowerCase(), 60n);
    expect(await earnedScoreOf({} as any, cfg, BOB, 110n)).toEqual(60n);
  });

  it("RpcScoreSource preserves the raw-RPC calculation at its pinned block", async () => {
    h.integrals.set(BOB.toLowerCase(), 60n);
    const source = new RpcScoreSource({} as any, cfg, 110n);
    expect(await source.grossScoreOf(BOB)).toBe(60n);
    const calls = (chain.tokenBlockIntegral as unknown as { mock: { calls: any[][] } }).mock.calls;
    expect(calls).toHaveLength(1);
    expect(calls[0].slice(2)).toEqual([BOB, 0n, 110n]);
  });
});

describe("settle — booster cap", () => {
  // A committed boost is capped at the claimant's MIN booster balance over
  // [joinBlock, windowEnd] (boosters aren't escrowed, so continuous holding is
  // required). bob commits 2 units; his effective boost is min(2, held).
  function boostReg(user: `0x${string}`, boosterAmount: bigint): InputEvent {
    return { kind: "register", claimId: 1n, user, amount: 100n * WAD, scoreToSpend: 1_000_000n, boosterAmount, blockNumber: 105n, logIndex: 0 };
  }

  it("held boosters ≥ committed → full boost applied", async () => {
    h.integrals.clear();
    h.minBalances.clear();
    h.boosterBalances.clear();
    h.integrals.set(BOB.toLowerCase(), 100n);
    h.boosterBalances.set(BOB.toLowerCase(), 2n); // holds ≥ the 2 committed
    const s = await settle({} as any, 1n, cfg, [boostReg(BOB, 2n)], baseOpts(10_000n * WAD));
    // 100 × 10200/10000 = 102
    expect(s.rows[0].earnedScore).toEqual(102n);
  });

  it("boost capped at min held; sold-down boosters don't count", async () => {
    h.integrals.clear();
    h.minBalances.clear();
    h.boosterBalances.clear();
    h.integrals.set(BOB.toLowerCase(), 100n);
    h.boosterBalances.set(BOB.toLowerCase(), 0n); // committed 2 but held 0 over the window
    const s = await settle({} as any, 1n, cfg, [boostReg(BOB, 2n)], baseOpts(10_000n * WAD));
    expect(s.rows[0].earnedScore).toEqual(100n); // no boost
    expect((chain.minErc1155BalanceOver as unknown as { mock: { calls: any[][] } }).mock.calls.length).toBe(1);
  });

  it("no committed boosters → no ERC1155 read", async () => {
    h.integrals.clear();
    h.minBalances.clear();
    h.boosterBalances.clear();
    h.integrals.set(BOB.toLowerCase(), 100n);
    await settle({} as any, 1n, cfg, [boostReg(BOB, 0n)], baseOpts(10_000n * WAD));
    expect((chain.minErc1155BalanceOver as unknown as { mock: { calls: any[][] } }).mock.calls.length).toBe(0);
  });

  it("I-2: booster boosts ONLY the unspent remainder, not already-spent score", async () => {
    h.integrals.clear();
    h.minBalances.clear();
    h.boosterBalances.clear();
    h.integrals.set(BOB.toLowerCase(), 100n); // raw lifetime earned = 100
    h.boosterBalances.set(BOB.toLowerCase(), 2n); // holds the 2 committed
    // 40 already spent on prior incidents. Correct: (100 − 40) × 10200/10000 = 61.
    // The old bug gave 100 × 10200/10000 − 40 = 62 (booster boosting spent score).
    const opts = { ...baseOpts(10_000n * WAD), spentOf: (_u: `0x${string}`) => 40n };
    const s = await settle({} as any, 1n, cfg, [boostReg(BOB, 2n)], opts);
    expect(s.rows[0].grossEarnedScore).toEqual(100n); // signed input is pre-spend, pre-booster
    expect(s.rows[0].earnedScore).toEqual(61n);
    expect(s.rows[0].scoreSpent).toEqual(61n);
    expect(s.settlementInputHash).toBe(settlementInputHashOf([{ user: BOB, grossEarnedScore: 100n }]));
  });
});

describe("settlementInputHash — canonical gross-score commitment", () => {
  const rows = [
    { user: BOB, grossEarnedScore: 60n },
    { user: CAROL, grossEarnedScore: 40n },
  ];

  it("is order-insensitive and exactly hashes abi.encode(address[],uint256[])", () => {
    const expected = keccak256(
      encodeAbiParameters(
        [{ type: "address[]" }, { type: "uint256[]" }],
        [[BOB, CAROL], [60n, 40n]]
      )
    );
    expect(settlementInputHashOf(rows)).toBe(expected);
    expect(settlementInputHashOf([...rows].reverse())).toBe(expected);
  });

  it("changes when one gross score changes by one unit", () => {
    expect(settlementInputHashOf([{ ...rows[0], grossEarnedScore: 61n }, rows[1]])).not.toBe(
      settlementInputHashOf(rows)
    );
  });

  it("rejects duplicate users, including checksum/casing variants", () => {
    const bobMixedCase = "0x000000000000000000000000000000000000B0B0" as const;
    expect(() => settlementInputHashOf([rows[0], { user: bobMixedCase, grossEarnedScore: 1n }])).toThrow(
      /duplicate settlement input user/
    );
  });

  it("hashes empty input as two ABI-encoded empty arrays, not bytes32(0)", () => {
    const expected = keccak256(
      encodeAbiParameters(
        [{ type: "address[]" }, { type: "uint256[]" }],
        [[], []]
      )
    );
    expect(settlementInputHashOf([])).toBe(expected);
    expect(expected).not.toBe(`0x${"0".repeat(64)}`);
  });

  it("is appended to the EIP-712 Settlement payload and changes its digest", () => {
    const settlement = {
      incidentId: 7n,
      root: `0x${"11".repeat(32)}` as `0x${string}`,
      poolPayouts: [1n, 2n],
      poolAddrs: [ASSET, INS],
    };
    const claimSet = `0x${"22".repeat(32)}` as `0x${string}`;
    const configHash = `0x${"33".repeat(32)}` as `0x${string}`;
    const inputHash = settlementInputHashOf(rows);
    const typed = settlementTypedData(1, INS, settlement, 2n, claimSet, configHash, inputHash);
    expect(typed.types.Settlement.at(-1)).toEqual({ name: "settlementInputHash", type: "bytes32" });
    expect(typed.message.settlementInputHash).toBe(inputHash);

    const changed = settlementTypedData(
      1,
      INS,
      settlement,
      2n,
      claimSet,
      configHash,
      `0x${"44".repeat(32)}`
    );
    expect(hashTypedData(changed)).not.toBe(hashTypedData(typed));
  });
});

describe("settlementTree / proofs", () => {
  const rows = [
    { claimId: 1n, user: BOB, amounts: [60n * WAD], scoreSpent: 60n, eligibleAmount: 100n * WAD },
    { claimId: 2n, user: CAROL, amounts: [40n * WAD], scoreSpent: 40n, eligibleAmount: 100n * WAD },
  ];

  it("proofs verify against the root with the canonical leaf encoding", () => {
    const tree = settlementTree(1n, rows);
    for (const [i, v] of tree.entries()) {
      const proof = tree.getProof(i);
      expect(StandardMerkleTree.verify(tree.root, LEAF_ENCODING as unknown as string[], v, proof)).toBe(true);
    }
  });

  it("root is deterministic and changes with amounts, scoreSpent, or eligible", () => {
    const base = settlementTree(1n, rows).root;
    expect(settlementTree(1n, rows).root).toEqual(base);
    expect(settlementTree(1n, [{ ...rows[0], amounts: [61n * WAD] }, rows[1]]).root).not.toEqual(base);
    expect(settlementTree(1n, [{ ...rows[0], scoreSpent: 59n }, rows[1]]).root).not.toEqual(base);
    expect(settlementTree(1n, [{ ...rows[0], eligibleAmount: 99n * WAD }, rows[1]]).root).not.toEqual(base);
  });
});

describe("blockAtOrBeforeTimestamp — window-end boundary (H-02)", () => {
  // Blocks 1..10 at 12s spacing: block n → timestamp 12·n (block5 = 60, block6 = 72).
  const N = 10n;
  const tsOf = (n: bigint) => 12n * n;
  const client = {
    getBlockNumber: async () => N,
    getBlock: async ({ blockNumber }: { blockNumber: bigint }) => ({ timestamp: tsOf(blockNumber) }),
  } as any;

  it("deadline exactly on a block → that block", async () => {
    expect(await chain.blockAtOrBeforeTimestamp(client, 60n)).toBe(5n);
  });

  it("no block equals the deadline → the LAST in-window block, not the first post-window one", async () => {
    // 65 sits between block5 (60) and block6 (72). Must pick 5, never 6.
    expect(await chain.blockAtOrBeforeTimestamp(client, 65n)).toBe(5n);
    expect(await chain.blockAtOrBeforeTimestamp(client, 71n)).toBe(5n);
    expect(await chain.blockAtOrBeforeTimestamp(client, 59n)).toBe(4n);
  });

  it("deadline on the head block → the head", async () => {
    expect(await chain.blockAtOrBeforeTimestamp(client, tsOf(N))).toBe(N);
  });

  it("deadline beyond the head → throws (window not closed on-chain yet)", async () => {
    await expect(chain.blockAtOrBeforeTimestamp(client, 121n)).rejects.toThrow(/in the future/);
  });
});

describe("configHash — settlement config commitment (M-04)", () => {
  it("is deterministic and insensitive to feed-map key order", async () => {
    const { CONFIG, configHash } = await import("../src/config.js");
    const original = { ...CONFIG.assetUsdFeed };
    try {
      CONFIG.assetUsdFeed["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] = "0x1111111111111111111111111111111111111111";
      CONFIG.assetUsdFeed["0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] = "0x2222222222222222222222222222222222222222";
      const h1 = configHash();
      // Rebuild the map in reverse insertion order — hash must not care.
      for (const k of Object.keys(CONFIG.assetUsdFeed)) delete CONFIG.assetUsdFeed[k];
      CONFIG.assetUsdFeed["0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] = "0x2222222222222222222222222222222222222222";
      CONFIG.assetUsdFeed["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] = "0x1111111111111111111111111111111111111111";
      expect(configHash()).toBe(h1);
    } finally {
      for (const k of Object.keys(CONFIG.assetUsdFeed)) delete CONFIG.assetUsdFeed[k];
      Object.assign(CONFIG.assetUsdFeed, original);
    }
  });

  it("changes when a feed mapping changes", async () => {
    const { CONFIG, configHash } = await import("../src/config.js");
    const original = { ...CONFIG.assetUsdFeed };
    try {
      const base = configHash();
      CONFIG.assetUsdFeed["0xcccccccccccccccccccccccccccccccccccccccc"] = "0x3333333333333333333333333333333333333333";
      expect(configHash()).not.toBe(base);
      CONFIG.assetUsdFeed["0xcccccccccccccccccccccccccccccccccccccccc"] = "0x4444444444444444444444444444444444444444";
      expect(configHash()).not.toBe(base);
    } finally {
      for (const k of Object.keys(CONFIG.assetUsdFeed)) delete CONFIG.assetUsdFeed[k];
      Object.assign(CONFIG.assetUsdFeed, original);
    }
  });
});

describe("earnedScoreOf — rate timeline (piecewise, non-retroactive)", () => {
  // balance≡1 proxy: mock the integral over [from,to] to be the window length, so a
  // segment's contribution is exactly (windowLength × rate) and the piecewise sum is
  // trivially checkable.
  const scoredCfg = (rates: { fromBlock: bigint; rate: bigint }[]) => ({
    ...cfg,
    scoredTokens: [{ token: SCORED, rates, decimals: 18 }],
  });

  beforeEach(() => {
    h.windowMode = true;
  });
  afterEach(() => {
    h.windowMode = false;
  });

  it("single segment == constant rate over the whole window (reproduces the old result)", async () => {
    // [10,110] = 100 blocks × rate 1.0 → 100.
    expect(await earnedScoreOf({} as any, scoredCfg([{ fromBlock: 10n, rate: WAD }]), BOB, 110n)).toBe(100n);
  });

  it("a rate change applies the OLD rate to the old window and the NEW rate only from the change block", async () => {
    // rate 3 over [0,40) = 120, rate 1 over [40,100] = 60 → 180. The change does NOT
    // retroactively re-price [0,40) at rate 1 (that would give 100).
    const c = scoredCfg([{ fromBlock: 0n, rate: 3n * WAD }, { fromBlock: 40n, rate: WAD }]);
    expect(await earnedScoreOf({} as any, c, BOB, 100n)).toBe(180n);
  });

  it("a rate-0 segment (scoring off) accrues nothing over its window", async () => {
    // rate 1 over [0,50) = 50, rate 0 over [50,100] = 0 → 50.
    const c = scoredCfg([{ fromBlock: 0n, rate: WAD }, { fromBlock: 50n, rate: 0n }]);
    expect(await earnedScoreOf({} as any, c, BOB, 100n)).toBe(50n);
  });

  it("a segment starting at/after the reference block contributes nothing", async () => {
    const c = scoredCfg([{ fromBlock: 0n, rate: WAD }, { fromBlock: 100n, rate: 9n * WAD }]);
    // only [0,100) at rate 1 counts → 100; the {100, 9x} segment has an empty window.
    expect(await earnedScoreOf({} as any, c, BOB, 100n)).toBe(100n);
  });
});

describe("earnedScoreOf — decimal normalization (F6)", () => {
  it("normalizes each scored token's integral to an 18-dec basis before summing", async () => {
    h.integrals.clear();
    h.integrals.set(BOB.toLowerCase(), 1_000_000n); // same RAW balance·block integral

    const at = (dec: number) =>
      earnedScoreOf({} as any, { ...cfg, scoredTokens: [{ token: SCORED, rates: [{ fromBlock: 0n, rate: WAD }], decimals: dec }] }, BOB, 100n);

    // A 6-dec token's raw integral must scale up by 1e12 vs an 18-dec token's, so
    // the same *whole-token* holding scores the same regardless of token decimals.
    expect(await at(6)).toBe((await at(18)) * 10n ** 12n);
  });
});
