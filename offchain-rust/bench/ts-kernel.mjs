#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { performance } from "node:perf_hooks";
import { proofsFor, settle } from "../../offchain/dist/compute.js";

const ZERO = "0x0000000000000000000000000000000000000000";
const ORACLE = "0x000000000000000000000000000000000000044c";
const INSURED = "0x0000000000000000000000000000000000001115";
const BOOSTER = "0x00000000000000000000000000000000b0057e40";
const BLOCK_TIMESTAMP = 1_000n;
const WAD = 10n ** 18n;

function amount(value) {
  return BigInt(value);
}

function poolAddress(index) {
  return `0x${(0x1001n + BigInt(index)).toString(16).padStart(40, "0")}`;
}

function outputOf(settlement) {
  const proofs = proofsFor(settlement);
  return {
    rows: settlement.rows.map((row) => ({
      claimId: row.claimId.toString(),
      user: row.user.toLowerCase(),
      escrowAmount: row.escrowAmount.toString(),
      eligibleAmount: row.eligibleAmount.toString(),
      lossUsd: row.lossUsd.toString(),
      grossEarnedScore: row.grossEarnedScore.toString(),
      earnedScore: row.earnedScore.toString(),
      scoreSpent: row.scoreSpent.toString(),
      payoutUsd: row.payoutUsd.toString(),
      amounts: row.amounts.map(String),
    })),
    poolPayouts: settlement.poolPayouts.map(String),
    claimSetHash: settlement.claimSetHash,
    settlementInputHash: settlement.settlementInputHash,
    root: settlement.root,
    proofs: Object.fromEntries(
      [...proofs.entries()].map(([claimId, proof]) => [claimId.toString(), proof])
    ),
  };
}

function prepare(raw) {
  const claims = raw.claims.map((claim) => ({
    claimId: amount(claim.claimId),
    user: claim.user,
    escrowAmount: amount(claim.escrowAmount),
    minHeld: amount(claim.minHeld),
    grossEarnedScore: amount(claim.grossEarnedScore),
    spentScore: amount(claim.spentScore),
    scoreToSpend: amount(claim.scoreToSpend),
    boosterAmount: amount(claim.boosterAmount),
    boosterHeld: amount(claim.boosterHeld),
  }));
  const poolsInput = raw.pools.map((pool) => ({
    balance: amount(pool.balance),
    assetUsd: amount(pool.assetUsd),
    assetDecimals: pool.assetDecimals,
  }));
  const incidentId = amount(raw.incidentId);
  const coverageBps = amount(raw.coverageBps);
  const maxCoverPoolPayoutBps = amount(raw.maxCoverPoolPayoutBps);
  const underlyingUsd = amount(raw.underlyingUsd);
  if (amount(raw.twapRatio) !== WAD) {
    throw new Error("benchmark TypeScript harness requires identity twapRatio=1e18");
  }

  const byUser = new Map(claims.map((claim) => [claim.user.toLowerCase(), claim]));
  const client = {
    readContract: async ({ functionName, args }) => {
      if (functionName === "latestRoundData") {
        return [1n, underlyingUsd, BLOCK_TIMESTAMP, BLOCK_TIMESTAMP, 1n];
      }
      if (functionName === "decimals") return 18;
      if (functionName === "balanceOf") {
        const claim = byUser.get(String(args[0]).toLowerCase());
        if (!claim) throw new Error(`unknown benchmark user ${args[0]}`);
        return args.length === 1 ? claim.minHeld : claim.boosterHeld;
      }
      throw new Error(`unexpected benchmark readContract ${functionName}`);
    },
    getBlock: async () => ({ timestamp: BLOCK_TIMESTAMP }),
    getLogs: async () => [],
  };
  const events = claims.map((claim, index) => ({
    kind: "register",
    claimId: claim.claimId,
    user: claim.user,
    amount: claim.escrowAmount,
    scoreToSpend: claim.scoreToSpend,
    boosterAmount: claim.boosterAmount,
    blockNumber: 100n + BigInt(index),
    logIndex: index,
  }));
  const pools = poolsInput.map((_, index) => poolAddress(index));
  const boosterEnabled = claims.some((claim) => claim.boosterAmount > 0n);
  const cfg = {
    coverageBps,
    underlyingPriceOracle: ORACLE,
    underlyingConversionAddress: ZERO,
    underlyingConversionCallData: "0x",
    params: { twapLookbackBlocks: 0n, holdingMarginBlocks: 0n, sampleStepBlocks: 1n },
    scoredTokens: [],
  };
  const opts = {
    insuredToken: INSURED,
    insuredDecimals: raw.insuredDecimals,
    referenceBlock: 100n,
    windowEndBlock: 110n,
    poolOrder: pools,
    poolAddrs: pools,
    poolBalances: poolsInput.map((pool) => pool.balance),
    poolAssetUsd1e18: poolsInput.map((pool) => pool.assetUsd),
    poolAssetDecimals: poolsInput.map((pool) => pool.assetDecimals),
    boosterCollection: boosterEnabled ? BOOSTER : ZERO,
    boosterId: 0n,
    grossScoreOf: async (user) => byUser.get(user.toLowerCase()).grossEarnedScore,
    spentOf: (user) => byUser.get(user.toLowerCase()).spentScore,
    maxCoverPoolPayoutBps,
  };

  return async () => outputOf(await settle(client, incidentId, cfg, events, opts));
}

const fixturePath = process.argv[2];
const iterations = Number(process.argv[3] ?? "1");
const warmupIterations = Number(process.argv[4] ?? "0");
if (
  !fixturePath ||
  !Number.isSafeInteger(iterations) ||
  iterations < 1 ||
  !Number.isSafeInteger(warmupIterations) ||
  warmupIterations < 0
) {
  console.error("usage: node ts-kernel.mjs <fixture.json> [iterations] [warmup-iterations]");
  process.exit(2);
}
const compute = prepare(JSON.parse(readFileSync(fixturePath, "utf8")));
let result;
for (let i = 0; i < warmupIterations; i++) await compute();
const started = performance.now();
for (let i = 0; i < iterations; i++) result = await compute();
const elapsedNs = Math.round((performance.now() - started) * 1_000_000);
if (iterations === 1) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
} else {
  process.stdout.write(`${JSON.stringify({ iterations, warmupIterations, elapsedNs, result })}\n`);
}
