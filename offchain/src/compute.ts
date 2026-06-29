// The settlement algorithm. Pure given chain reads — every step here is
// recomputable by anyone from the per-incident config snapshot, which is what
// the dispute window verifies.

import { encodeAbiParameters, keccak256, type PublicClient } from "viem";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import {
  WAD,
  ratioAt,
  priceUsd1e18,
  minBalanceOver,
  tokenBlockIntegral,
  type IncidentConfig,
  type InputEvent,
} from "./chain.js";

const BPS = 10_000n;
// Hard-coded booster policy, mirrors CoverPool.BOOSTER_BOOST_BPS: each committed
// unit of booster id 1 adds +1% to the insurance-score multiplier.
const BOOSTER_ID = 1n;
const BOOSTER_BOOST_BPS = 100n;

export interface SettledRow {
  claimId: bigint;
  user: `0x${string}`;
  escrowAmount: bigint;
  eligibleAmount: bigint;
  lossUsd: bigint; // 1e18
  earnedScore: bigint; // total available-to-spend before this claim
  scoreSpent: bigint; // min(requested, available) — the payout weight, recorded on-chain
  payoutUsd: bigint; // 1e18, post-κ, post-share
  amounts: bigint[]; // aligned to stake-asset list
}

export interface Settlement {
  incidentId: bigint;
  referenceBlock: bigint; // admin-pinned pre-incident block losses are valued against
  twapRatio: bigint;
  inputHash: `0x${string}`;
  root: `0x${string}`;
  assetOrder: `0x${string}`[];
  rows: SettledRow[];
}

/**
 * Replicate the contract's running claimant-table commitment by replaying the
 * register/cancel events in true chain order. Each `register` chains
 * `keccak256(abi.encode(h, claimId, user, escrow, scoreToSpend, boosterIds,
 * boosterAmounts))`; each `cancel` chains `keccak256(abi.encode(h, claimId,
 * "CANCEL"))` — byte-identical to DefiInsurance's `joinClaim`/`cancelClaim`.
 */
export function computeInputHash(events: InputEvent[]): `0x${string}` {
  let h: `0x${string}` = `0x${"00".repeat(32)}`;
  for (const e of events) {
    if (e.kind === "register") {
      h = keccak256(
        encodeAbiParameters(
          [
            { type: "bytes32" },
            { type: "uint256" },
            { type: "address" },
            { type: "uint128" },
            { type: "uint256" },
            { type: "uint256[]" },
            { type: "uint256[]" },
          ],
          [h, e.claimId, e.user, e.amount, e.scoreToSpend, e.boosterIds, e.boosterAmounts]
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
 * TWAP of the token→underlying ratio over [referenceBlock − twapLookback,
 * referenceBlock], sampled. The reference block is the admin-pinned pre-incident
 * point ({Incident.referenceBlock}); TWAPing a short window before it smooths
 * any single-block oracle glitch. This is the "before" value losses are
 * measured against — no on-chain drop detection (the admin already opened).
 */
export async function twapRatioBefore(client: PublicClient, cfg: IncidentConfig, b: bigint): Promise<bigint> {
  if (cfg.params.sampleStepBlocks === 0n) throw new Error("invalid settlement params: sampleStepBlocks is zero");
  const w = cfg.params.twapLookbackBlocks;
  const start = b > w ? b - w : 1n;
  let sum = 0n;
  let n = 0n;
  for (let blk = start; blk <= b; blk += cfg.params.sampleStepBlocks) {
    sum += await ratioAt(client, cfg.underlyingConversionAddress, cfg.underlyingConversionCallData, blk);
    n += 1n;
  }
  return n === 0n ? 0n : sum / n;
}

/**
 * USD8 insurance score EARNED by `user` as of `asOfBlock`: the cumulative
 * token·block integral of each scored token from its `startBlock`, summed and
 * weighted by its on-chain rate, then boosted. This is the gross figure;
 * already-spent score (from the on-chain ledger) is subtracted by the caller.
 * Non-expiring (not a time-weighted average), so holding longer always grows
 * it. Each committed unit of booster id 1 adds BOOSTER_BOOST_BPS per unit.
 *
 * Anchored at the pre-incident `referenceBlock` (not window-end): otherwise a
 * claimant could pile scored tokens into their wallet DURING the claim window
 * to inflate their token·block integral and grab a larger payout share.
 */
export async function earnedScoreOf(
  client: PublicClient,
  cfg: IncidentConfig,
  user: `0x${string}`,
  boosterIds: bigint[],
  boosterAmounts: bigint[],
  asOfBlock: bigint
): Promise<bigint> {
  let score = 0n;
  for (const st of cfg.scoredTokens) {
    if (st.startBlock >= asOfBlock) continue;
    const integral = await tokenBlockIntegral(client, st.token, user, st.startBlock, asOfBlock);
    score += integral * st.scorePerTokenPerBlock;
  }
  // Booster multiplier: each committed unit of id 1 adds BOOSTER_BOOST_BPS
  // (every other id weighs 0). multiplier = (BPS + Σ amount × bps) / BPS.
  let boostBps = 0n;
  for (let i = 0; i < boosterIds.length; i++) {
    if (boosterIds[i] === BOOSTER_ID) boostBps += boosterAmounts[i] * BOOSTER_BOOST_BPS;
  }
  return (score * (BPS + boostBps)) / BPS;
}

/**
 * Full settlement for one incident: the claimant table, per-asset payout
 * amounts, and the merkle root the admin submits / anyone verifies.
 */
export async function settle(
  client: PublicClient,
  incidentId: bigint,
  cfg: IncidentConfig,
  events: InputEvent[],
  opts: {
    insuredToken: `0x${string}`;
    insuredDecimals: number;
    referenceBlock: bigint; // admin-pinned pre-incident block (Incident.referenceBlock)
    windowEndBlock: bigint;
    assetOrder: `0x${string}`[];
    assetBalances: bigint[]; // pool totalAssets per asset at windowEndBlock
    assetUsd1e18: bigint[]; // USD price per whole token at windowEndBlock
    assetDecimals: number[];
    spentOf: (user: `0x${string}`) => bigint; // insurance score already spent (on-chain ledger)
  }
): Promise<Settlement> {
  const inputHash = computeInputHash(events);

  // Pre-incident value, anchored at the admin-pinned reference block (no
  // on-chain drop detection — the admin already opened the incident).
  const refBlock = opts.referenceBlock;
  const twap = await twapRatioBefore(client, cfg, refBlock);
  // Underlying USD pinned to window-end block — reproducible.
  const underlyingUsd = await priceUsd1e18(client, cfg.priceOracle, opts.windowEndBlock);

  const holdFrom = refBlock > cfg.params.holdingMarginBlocks ? refBlock - cfg.params.holdingMarginBlocks : 1n;

  // Per-claim eligibility, valuation, score (live = registered, not cancelled).
  const live = events
    .filter((e) => e.kind === "register")
    .filter((e) => !events.some((c) => c.kind === "cancel" && c.claimId === e.claimId));
  const rows: SettledRow[] = [];
  for (const e of live) {
    // Eligible = continuous min holding over [B − margin, joinBlock − 1], capped
    // at escrow. The window ends one block BEFORE this claim's joinClaim — which
    // escrows the insured token out of the wallet in the same block as the
    // register event — so the escrow transfer never depresses the min, yet the
    // claimant must have held continuously from before the incident right up to
    // filing. This closes the [referenceBlock, joinBlock] gap (no sell-at-par-
    // then-rebuy-cheap), while the LOSS is still priced at the pre-incident
    // referenceBlock (twap above). Extending the window can only lower the min,
    // never raise it, so honest continuous holders are unaffected. Min-balance
    // replay makes cross-claimant double-counting impossible.
    const minHeld = await minBalanceOver(client, opts.insuredToken, e.user, holdFrom, e.blockNumber - 1n);
    const eligible = minHeld < e.amount ? minHeld : e.amount;
    // lossUsd = eligible × TWAP ratio × underlying USD price (1e18).
    const lossUsd = (((eligible * twap) / WAD) * underlyingUsd) / 10n ** BigInt(opts.insuredDecimals);
    // Earned score as of referenceBlock, minus what's already been spent on
    // prior claims. Pinned pre-incident (like eligibility) so the claim window
    // can't be used to farm fresh score. The contract caps each account to one
    // live claim per incident, so a user's whole budget maps to a single row.
    const earned = await earnedScoreOf(client, cfg, e.user, e.boosterIds, e.boosterAmounts, opts.referenceBlock);
    const spent = opts.spentOf(e.user);
    const available = earned > spent ? earned - spent : 0n;
    // The claimant spends what they requested, capped to availability (option A:
    // over-request just caps; no waste protection). This is their payout weight.
    const scoreSpent = e.scoreToSpend < available ? e.scoreToSpend : available;
    rows.push({
      claimId: e.claimId,
      user: e.user,
      escrowAmount: e.amount,
      eligibleAmount: eligible,
      lossUsd,
      earnedScore: earned,
      scoreSpent,
      payoutUsd: 0n,
      amounts: [],
    });
  }

  // Pool USD value.
  let poolUsd = 0n;
  for (let i = 0; i < opts.assetOrder.length; i++) {
    poolUsd += (opts.assetBalances[i] * opts.assetUsd1e18[i]) / 10n ** BigInt(opts.assetDecimals[i]);
  }
  // Payout weight is the SPENT score (not earned): claimants apportion by what
  // they choose to spend this incident.
  const totalSpent = rows.reduce((a, r) => a + (r.lossUsd > 0n ? r.scoreSpent : 0n), 0n);

  // payoutUsd = min(spent-share × poolUsd, κ × lossUsd); split per asset
  // pro-rata to the pool mix.
  for (const r of rows) {
    if (r.lossUsd === 0n || totalSpent === 0n) {
      r.amounts = opts.assetOrder.map(() => 0n);
      continue;
    }
    const share = (r.scoreSpent * poolUsd) / totalSpent;
    const cap = (r.lossUsd * cfg.coverageBps) / BPS;
    r.payoutUsd = share < cap ? share : cap;
    r.amounts = opts.assetOrder.map((_, i) =>
      poolUsd === 0n ? 0n : (r.payoutUsd * opts.assetBalances[i]) / poolUsd
    );
  }

  const tree = settlementTree(incidentId, rows);

  return {
    incidentId,
    referenceBlock: refBlock,
    twapRatio: twap,
    inputHash,
    root: tree.root as `0x${string}`,
    assetOrder: opts.assetOrder,
    rows,
  };
}

// Leaf encoding — SINGLE source of truth. The on-chain leaf in
// DefiInsurance.finalizeClaim (keccak256(bytes.concat(keccak256(abi.encode(
// incidentId, claimId, user, amounts, scoreSpent))))) and the FFI helper both
// mirror this exact tuple and type order; drift here breaks every on-chain proof.
export const LEAF_ENCODING = ["uint256", "uint256", "address", "uint256[]", "uint256"] as const;

/** Build the OZ StandardMerkleTree over settlement rows using {LEAF_ENCODING}. */
export function settlementTree(
  incidentId: bigint,
  rows: { claimId: bigint; user: `0x${string}`; amounts: bigint[]; scoreSpent: bigint }[]
) {
  return StandardMerkleTree.of(
    rows.map((r) => [incidentId, r.claimId, r.user, r.amounts, r.scoreSpent]) as unknown as any[][],
    LEAF_ENCODING as unknown as string[]
  );
}

export function proofFor(s: Settlement, claimId: bigint): `0x${string}`[] {
  const tree = settlementTree(s.incidentId, s.rows);
  for (const [i, v] of tree.entries()) {
    if ((v as any[])[1] === claimId) return tree.getProof(i) as `0x${string}`[];
  }
  throw new Error(`claim ${claimId} not in settlement`);
}
