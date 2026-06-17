// The settlement algorithm. Pure given chain reads — every step here is
// recomputable by anyone, which is what the dispute window verifies.

import { encodeAbiParameters, keccak256, type PublicClient } from "viem";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { CONFIG, type InsuredTokenConfig } from "./config.js";
import {
  ratioAt,
  feedUsd1e18,
  minBalanceOver,
  twabOver,
  type InputEvent,
} from "./chain.js";

const WAD = 10n ** 18n;
const BPS = 10_000n;

export interface SettledRow {
  claimId: bigint;
  user: `0x${string}`;
  escrowAmount: bigint;
  eligibleAmount: bigint;
  lossUsd: bigint; // 1e18
  score: bigint;
  payoutUsd: bigint; // 1e18, post-κ, post-share
  amounts: bigint[]; // aligned to stake-asset list
}

export interface Settlement {
  incidentId: bigint;
  incidentBlock: bigint; // B — detected cliff edge
  twapRatio: bigint;
  inputHash: `0x${string}`;
  root: `0x${string}`;
  assetOrder: `0x${string}`[];
  rows: SettledRow[];
}

/**
 * Replicate the contract's running claimant-table commitment by replaying the
 * register/cancel events in true chain order. Each `register` chains
 * `keccak256(abi.encode(h, claimId, user, amount))`; each `cancel` chains
 * `keccak256(abi.encode(h, claimId, "CANCEL"))` — byte-identical to
 * CoverPool's `registerClaim`/`cancelClaim`.
 */
export function computeInputHash(events: InputEvent[]): `0x${string}` {
  let h: `0x${string}` = `0x${"00".repeat(32)}`;
  for (const e of events) {
    if (e.kind === "register") {
      h = keccak256(
        encodeAbiParameters(
          [{ type: "bytes32" }, { type: "uint256" }, { type: "address" }, { type: "uint128" }],
          [h, e.claimId, e.user, e.amount]
        )
      );
    } else {
      h = keccak256(
        encodeAbiParameters(
          [{ type: "bytes32" }, { type: "uint256" }, { type: "string" }],
          [h, e.claimId, "CANCEL"]
        )
      );
    }
  }
  return h;
}

/**
 * Detect the incident block B: the pre-cliff edge. Scan sampled blocks in
 * [first-claim − maxLookback, windowEnd]; B is the sample with the maximum
 * ratio such that the ratio within the following dropWindow falls below
 * (1 − θ) × ratio(B). Returns null if no qualifying cliff exists — the
 * whole incident is then invalid and MUST NOT be signed (void path).
 */
export async function detectIncidentBlock(
  client: PublicClient,
  cfg: InsuredTokenConfig,
  firstClaimBlock: bigint,
  windowEndBlock: bigint
): Promise<{ b: bigint; ratioAtB: bigint } | null> {
  const lookbackBlocks = cfg.maxLookbackSec / CONFIG.secondsPerBlock;
  const dropBlocks = cfg.dropWindowSec / CONFIG.secondsPerBlock;
  const start = firstClaimBlock > lookbackBlocks ? firstClaimBlock - lookbackBlocks : 1n;
  const step = CONFIG.sampleStepBlocks;

  // Sample the ratio series once.
  const samples: { block: bigint; ratio: bigint }[] = [];
  for (let b = start; b <= windowEndBlock; b += step) {
    samples.push({ block: b, ratio: await ratioAt(client, cfg, b) });
  }

  let best: { b: bigint; ratioAtB: bigint } | null = null;
  for (let i = 0; i < samples.length; i++) {
    const s = samples[i];
    const threshold = (s.ratio * (BPS - cfg.thetaBps)) / BPS;
    // Does any sample within dropWindow after s fall below threshold?
    let cliff = false;
    for (let j = i + 1; j < samples.length && samples[j].block <= s.block + dropBlocks; j++) {
      if (samples[j].ratio <= threshold) {
        cliff = true;
        break;
      }
    }
    if (cliff && (best === null || s.ratio > best.ratioAtB)) {
      best = { b: s.block, ratioAtB: s.ratio };
    }
  }
  return best;
}

/** TWAP of the ratio over [B − W, B], sampled. */
export async function twapRatioBefore(
  client: PublicClient,
  cfg: InsuredTokenConfig,
  b: bigint
): Promise<bigint> {
  const wBlocks = cfg.twapLookbackSec / CONFIG.secondsPerBlock;
  const start = b > wBlocks ? b - wBlocks : 1n;
  let sum = 0n;
  let n = 0n;
  for (let blk = start; blk <= b; blk += CONFIG.sampleStepBlocks) {
    sum += await ratioAt(client, cfg, blk);
    n += 1n;
  }
  return n === 0n ? 0n : sum / n;
}

/**
 * Full settlement for one incident. Throws if the incident has no valid
 * cliff (caller must NOT sign anything — that is the void path).
 */
export async function settle(
  client: PublicClient,
  incidentId: bigint,
  cfg: InsuredTokenConfig,
  events: InputEvent[],
  opts: {
    firstClaimBlock: bigint;
    windowEndBlock: bigint;
    coverageBps: bigint;
    assetOrder: `0x${string}`[];
    assetBalances: bigint[]; // pool totalAssets per asset at windowEndBlock
    assetUsd1e18: bigint[]; // USD price per whole token at windowEndBlock
    assetDecimals: number[];
  }
): Promise<Settlement> {
  const inputHash = computeInputHash(events);

  const cliff = await detectIncidentBlock(client, cfg, opts.firstClaimBlock, opts.windowEndBlock);
  if (!cliff) throw new Error("no qualifying ratio cliff: incident invalid, do not sign");
  const twap = await twapRatioBefore(client, cfg, cliff.b);
  // Underlying USD pinned to window-end block — reproducible.
  const underlyingUsd = await feedUsd1e18(client, cfg.underlyingUsdFeed, opts.windowEndBlock);

  const marginBlocks = cfg.holdingMarginSec / CONFIG.secondsPerBlock;
  const holdFrom = cliff.b > marginBlocks ? cliff.b - marginBlocks : 1n;
  const scoreBlocks = CONFIG.scoreLookbackSec / CONFIG.secondsPerBlock;
  const scoreFrom =
    opts.windowEndBlock > scoreBlocks ? opts.windowEndBlock - scoreBlocks : 1n;

  // Per-claim eligibility, valuation, score (live = registered, not cancelled).
  const live = events
    .filter((e) => e.kind === "register")
    .filter((e) => !events.some((c) => c.kind === "cancel" && c.claimId === e.claimId));
  const rows: SettledRow[] = [];
  for (const e of live) {
    // Eligible = continuous min holding since B − margin, capped at escrow.
    // Min-balance replay makes cross-claimant double-counting impossible.
    const minHeld = await minBalanceOver(client, cfg.token, e.user, holdFrom, opts.windowEndBlock);
    const eligible = minHeld < e.amount ? minHeld : e.amount;
    // lossUsd = eligible × TWAP ratio × underlying USD price.
    const lossUsd =
      (((eligible * twap) / WAD) * underlyingUsd) / 10n ** BigInt(cfg.underlyingDecimals);
    // USD8 history score = time-weighted USD8 balance over the lookback.
    const score = await twabOver(client, CONFIG.usd8, e.user, scoreFrom, opts.windowEndBlock);
    rows.push({
      claimId: e.claimId,
      user: e.user,
      escrowAmount: e.amount,
      eligibleAmount: eligible,
      lossUsd,
      score,
      payoutUsd: 0n,
      amounts: [],
    });
  }

  // Pool USD value.
  let poolUsd = 0n;
  for (let i = 0; i < opts.assetOrder.length; i++) {
    poolUsd +=
      (opts.assetBalances[i] * opts.assetUsd1e18[i]) / 10n ** BigInt(opts.assetDecimals[i]);
  }
  const totalScore = rows.reduce((a, r) => a + (r.lossUsd > 0n ? r.score : 0n), 0n);

  // payoutUsd = min(score-share × poolUsd, κ × lossUsd); split per asset
  // pro-rata to the pool mix.
  for (const r of rows) {
    if (r.lossUsd === 0n || totalScore === 0n) {
      r.amounts = opts.assetOrder.map(() => 0n);
      continue;
    }
    const share = (r.score * poolUsd) / totalScore;
    const cap = (r.lossUsd * opts.coverageBps) / BPS;
    r.payoutUsd = share < cap ? share : cap;
    r.amounts = opts.assetOrder.map((_, i) =>
      poolUsd === 0n ? 0n : (r.payoutUsd * opts.assetBalances[i]) / poolUsd
    );
  }

  // OZ standard merkle tree — leaf encoding matches CoverPool exactly:
  // keccak256(bytes.concat(keccak256(abi.encode(incidentId, claimId, user, amounts)))).
  const tree = StandardMerkleTree.of(
    rows.map((r) => [incidentId, r.claimId, r.user, r.amounts] as const) as unknown as any[][],
    ["uint256", "uint256", "address", "uint256[]"]
  );

  return {
    incidentId,
    incidentBlock: cliff.b,
    twapRatio: twap,
    inputHash,
    root: tree.root as `0x${string}`,
    assetOrder: opts.assetOrder,
    rows,
  };
}

export function proofFor(s: Settlement, claimId: bigint): `0x${string}`[] {
  const tree = StandardMerkleTree.of(
    s.rows.map((r) => [s.incidentId, r.claimId, r.user, r.amounts] as const) as unknown as any[][],
    ["uint256", "uint256", "address", "uint256[]"]
  );
  for (const [i, v] of tree.entries()) {
    if ((v as any[])[1] === claimId) return tree.getProof(i) as `0x${string}`[];
  }
  throw new Error(`claim ${claimId} not in settlement`);
}
