import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";

const WAD = 10n ** 18n;
const h = vi.hoisted(() => ({ minHeld: new Map<string, bigint>() }));

vi.mock("../src/chain.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/chain.js")>();
  return {
    ...actual,
    ratioAt: vi.fn(async () => WAD),
    priceUsd1e18: vi.fn(async () => WAD),
    minBalanceOver: vi.fn(async (_client: unknown, _token: unknown, user: string) => h.minHeld.get(user.toLowerCase()) ?? 0n),
  };
});

import { settle } from "../src/compute.js";

type RawClaim = {
  claimId: string;
  user: `0x${string}`;
  escrowAmount: string;
  minHeld: string;
  grossEarnedScore: string;
  spentScore: string;
  scoreToSpend: string;
  boosterAmount: string;
};
type RawInput = {
  incidentId: string;
  coverageBps: string;
  insuredDecimals: number;
  twapRatio: string;
  underlyingUsd: string;
  maxCoverPoolPayoutBps: string;
  pools: { balance: string; assetUsd: string; assetDecimals: number }[];
  claims: RawClaim[];
};
type Expected = {
  rows: {
    claimId: string;
    eligibleAmount: string;
    lossUsd: string;
    earnedScore: string;
    scoreSpent: string;
    boostedScore: string;
    payoutUsd: string;
    amounts: string[];
  }[];
  poolPayouts: string[];
};
type Vector = { name: string; derivation: string[]; input: RawInput; expected: Expected };

const vectors = JSON.parse(
  readFileSync(new URL("../../test-vectors/golden-claim-results.json", import.meta.url), "utf8")
) as Vector[];

function address(index: number): `0x${string}` {
  return `0x${(0x1001n + BigInt(index)).toString(16).padStart(40, "0")}`;
}

async function compute(input: RawInput) {
  const claims = input.claims;
  const byUser = new Map(claims.map((claim) => [claim.user.toLowerCase(), claim]));
  h.minHeld = new Map(claims.map((claim) => [claim.user.toLowerCase(), BigInt(claim.minHeld)]));
  const pools = input.pools.map((_, index) => address(index));
  const events = claims.map((claim, index) => ({
    kind: "register" as const,
    claimId: BigInt(claim.claimId),
    user: claim.user,
    amount: BigInt(claim.escrowAmount),
    scoreToSpend: BigInt(claim.scoreToSpend),
    boosterAmount: BigInt(claim.boosterAmount),
    blockNumber: 100n + BigInt(index),
    logIndex: index,
  }));
  const cfg = {
    coverageBps: BigInt(input.coverageBps),
    underlyingPriceOracle: "0x000000000000000000000000000000000000044c" as const,
    underlyingConversionAddress: "0x0000000000000000000000000000000000000000" as const,
    underlyingConversionCallData: "0x" as const,
    params: { twapLookbackBlocks: 0n, holdingMarginBlocks: 0n, sampleStepBlocks: 1n },
    scoredTokens: [],
  };
  return settle({} as never, BigInt(input.incidentId), cfg, events, {
    insuredToken: "0x0000000000000000000000000000000000001115",
    insuredDecimals: input.insuredDecimals,
    referenceBlock: 100n,
    windowEndBlock: 110n,
    poolOrder: pools,
    poolAddrs: pools,
    poolBalances: input.pools.map((pool) => BigInt(pool.balance)),
    poolAssetUsd1e18: input.pools.map((pool) => BigInt(pool.assetUsd)),
    poolAssetDecimals: input.pools.map((pool) => pool.assetDecimals),
    grossScoreOf: async (user) => BigInt(byUser.get(user.toLowerCase())!.grossEarnedScore),
    spentOf: (user) => BigInt(byUser.get(user.toLowerCase())!.spentScore),
    maxCoverPoolPayoutBps: BigInt(input.maxCoverPoolPayoutBps),
  });
}

describe("pre-crafted golden claim results", () => {
  for (const vector of vectors) {
    it(vector.name, async () => {
      expect(vector.derivation.length).toBeGreaterThan(0);
      const actual = await compute(vector.input);
      expect({
        rows: actual.rows.map((row) => ({
          claimId: row.claimId.toString(),
          eligibleAmount: row.eligibleAmount.toString(),
          lossUsd: row.lossUsd.toString(),
          earnedScore: row.earnedScore.toString(),
          scoreSpent: row.scoreSpent.toString(),
          boostedScore: row.boostedScore.toString(),
          payoutUsd: row.payoutUsd.toString(),
          amounts: row.amounts.map(String),
        })),
        poolPayouts: actual.poolPayouts.map(String),
      }).toEqual(vector.expected);
    });
  }
});
