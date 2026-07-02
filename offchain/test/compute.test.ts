import { describe, it, expect, vi, beforeEach } from "vitest";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

// Replace the chain-reading helpers with deterministic stubs so the pure
// settlement algorithm can be exercised without an RPC. earnedScoreOf /
// twapRatioBefore are NOT mocked — they run for real over the stubbed reads.
const h = vi.hoisted(() => ({
  integrals: new Map<string, bigint>(),
  minBalances: new Map<string, bigint>(),
}));

vi.mock("../src/chain.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/chain.js")>();
  return {
    ...actual,
    ratioAt: vi.fn(async () => actual.WAD), // token→underlying ratio = 1.0
    priceUsd1e18: vi.fn(async () => actual.WAD), // underlying = $1
    minBalanceOver: vi.fn(async (_c: any, _t: any, who: string) => h.minBalances.get(who.toLowerCase()) ?? 10_000n * actual.WAD),
    tokenBlockIntegral: vi.fn(async (_c: any, _t: any, who: string) => h.integrals.get(who.toLowerCase()) ?? 0n),
  };
});

import * as chain from "../src/chain.js";
import { settle, earnedScoreOf, computeInputHash, settlementTree, LEAF_ENCODING } from "../src/compute.js";
import type { IncidentConfig, InputEvent } from "../src/chain.js";

beforeEach(() => vi.clearAllMocks());

const WAD = 10n ** 18n;
const BOB = "0x000000000000000000000000000000000000b0b0" as const;
const CAROL = "0x000000000000000000000000000000000000ca50" as const;
const INS = "0x0000000000000000000000000000000000001115" as const;
const ASSET = "0x0000000000000000000000000000000000000a55" as const;
const SCORED = "0x0000000000000000000000000000000000005c04" as const;
const ORACLE = "0x000000000000000000000000000000000000044c" as const;
const ZERO = "0x0000000000000000000000000000000000000000" as const;

const cfg: IncidentConfig = {
  coverageBps: 8000n, // κ = 80%
  underlyingPriceOracle: ORACLE,
  adapter: ZERO,
  params: { twapLookbackBlocks: 10n, holdingMarginBlocks: 5n, sampleStepBlocks: 5n },
  scoredTokens: [{ token: SCORED, scorePerTokenPerBlock: WAD, startBlock: 0n }], // 1e18 = 1.0/token/block
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
    assetOrder: [ASSET] as `0x${string}`[],
    assetBalances: [assetBalance],
    assetUsd1e18: [WAD], // $1 per asset token
    assetDecimals: [18],
    spentOf: (_u: `0x${string}`) => 0n,
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

  it("scarce pool → payouts bound by score share, sum to the pool", async () => {
    setEarned();
    // poolUsd = $100, totalSpent = 100 ⇒ share = scoreSpent (per $1). Below κ·loss=$80? no:
    // bob share $60 < $80 cap, carol $40 < $80 ⇒ both share-bound.
    const s = await settle({} as any, 1n, cfg, events, baseOpts(100n * WAD));

    expect(s.rows.map((r) => r.scoreSpent)).toEqual([60n, 40n]);
    expect(s.rows.map((r) => r.eligibleAmount)).toEqual([100n * WAD, 100n * WAD]);
    expect(s.rows.map((r) => r.lossUsd)).toEqual([100n * WAD, 100n * WAD]);
    expect(s.rows.map((r) => r.earnedScore)).toEqual([60n, 40n]);
    expect(s.rows.map((r) => r.payoutUsd)).toEqual([60n * WAD, 40n * WAD]);
    expect(s.rows.map((r) => r.amounts)).toEqual([[60n * WAD], [40n * WAD]]);
    // whole pool distributed
    expect(s.rows.reduce((a, r) => a + r.amounts[0], 0n)).toEqual(100n * WAD);
  });

  it("abundant pool → payouts bound by κ·loss cap", async () => {
    setEarned();
    // poolUsd = $10,000 ⇒ each score share dwarfs the $80 cap.
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

  it("eligibility ends at joinBlock−1; score/price pinned to referenceBlock", async () => {
    setEarned();
    const opts = baseOpts(100n * WAD); // referenceBlock=100, windowEndBlock=110; joins at 105/106
    await settle({} as any, 1n, cfg, events, opts);
    // Insured-token min-balance reads end one block before each claim's join, so
    // the escrow transfer never slashes the min, but continuous holding right up
    // to filing is required (closes the sell-at-par gap).
    const elig = (chain.minBalanceOver as unknown as { mock: { calls: any[][] } }).mock.calls;
    expect(elig.map((c) => c[1])).toEqual([opts.insuredToken, opts.insuredToken]);
    expect(elig.map((c) => c[4])).toEqual(events.map((e) => e.blockNumber - 1n)); // [104, 105]
    // Score integral still ends at referenceBlock — no farming score during the
    // claim window to inflate payout weight.
    const score = (chain.tokenBlockIntegral as unknown as { mock: { calls: any[][] } }).mock.calls;
    expect(score.length).toBe(2); // 2 claimants × 1 scored token
    for (const c of score) expect(c[4]).toBe(opts.referenceBlock);
  });

  it("cancelled claims are excluded", async () => {
    setEarned();
    const withCancel: InputEvent[] = [
      ...events,
      { kind: "cancel", claimId: 2n, user: CAROL, amount: 0n, scoreToSpend: 0n, boosterAmount: 0n, blockNumber: 5n, logIndex: 0 },
    ];
    const s = await settle({} as any, 1n, cfg, withCancel, baseOpts(100n * WAD));
    expect(s.rows.map((r) => r.claimId)).toEqual([1n]); // carol dropped
  });
});

describe("earnedScoreOf — booster multiplier", () => {
  it("no boosters → integral × rate", async () => {
    h.integrals.set(BOB.toLowerCase(), 60n);
    expect(await earnedScoreOf({} as any, cfg, BOB, 0n, 110n)).toEqual(60n);
  });
  it("each booster unit adds +100bps", async () => {
    h.integrals.set(BOB.toLowerCase(), 60n);
    // 2 units ⇒ +200bps ⇒ 60 × 10200/10000 = 61 (floored)
    expect(await earnedScoreOf({} as any, cfg, BOB, 2n, 110n)).toEqual(61n);
  });
});

describe("computeInputHash", () => {
  const a = reg(1n, BOB, 100n * WAD, 60n);
  const b = reg(2n, CAROL, 50n * WAD, 40n);

  it("is deterministic", () => {
    expect(computeInputHash([a, b])).toEqual(computeInputHash([a, b]));
  });
  it("is order-sensitive", () => {
    expect(computeInputHash([a, b])).not.toEqual(computeInputHash([b, a]));
  });
  it("a cancel changes the hash", () => {
    const cancel: InputEvent = { kind: "cancel", claimId: 1n, user: BOB, amount: 0n, scoreToSpend: 0n, boosterAmount: 0n, blockNumber: 3n, logIndex: 0 };
    expect(computeInputHash([a])).not.toEqual(computeInputHash([a, cancel]));
  });
});

describe("settlementTree / proofs", () => {
  it("proofs verify against the root with the canonical leaf encoding", () => {
    const rows = [
      { claimId: 1n, user: BOB, amounts: [60n * WAD], scoreSpent: 60n },
      { claimId: 2n, user: CAROL, amounts: [40n * WAD], scoreSpent: 40n },
    ];
    const tree = settlementTree(1n, rows);
    for (const [i, v] of tree.entries()) {
      const proof = tree.getProof(i);
      expect(StandardMerkleTree.verify(tree.root, LEAF_ENCODING as unknown as string[], v, proof)).toBe(true);
    }
  });
});
