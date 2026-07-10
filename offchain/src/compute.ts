// The settlement algorithm. Pure given chain reads — every step here is
// recomputable by anyone from on-chain state at the incident's openBlock, which
// is what the dispute window verifies.

import { type PublicClient, keccak256, encodePacked } from "viem";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import {
  WAD,
  ZERO_ADDRESS,
  ratioAt,
  priceUsd1e18,
  minBalanceOver,
  minErc1155BalanceOver,
  tokenBlockIntegral,
  type IncidentConfig,
  type InputEvent,
} from "./chain.js";

const BPS = 10_000n;
// Hard-coded booster policy, mirrors DefiInsurance.BOOSTER_BOOST_BPS: each
// committed booster unit adds +1% to the insurance-score multiplier.
const BOOSTER_BOOST_BPS = 100n;
// scorePerTokenPerBlock is stored 1e18-scaled: 1e18 ⇒ 1.0 score/token/block.
// Because the rate multiplies a balance normalized to an 18-decimal basis (see
// earnedScoreOf), this /SCORE_SCALE cancels that shared 1e18 and yields score in
// WAD (1e18 = 1.0), applied once at the end of the sum.
const SCORE_SCALE = WAD;

export interface SettledRow {
  claimId: bigint;
  user: `0x${string}`;
  escrowAmount: bigint;
  eligibleAmount: bigint;
  lossUsd: bigint; // 1e18
  earnedScore: bigint; // total available-to-spend before this claim
  scoreSpent: bigint; // min(requested, available) — the payout weight, recorded via ScoreSpent
  payoutUsd: bigint; // 1e18, post-κ, post-share
  amounts: bigint[]; // aligned to the registered pool list (one scalar per pool)
}

export interface Settlement {
  incidentId: bigint;
  referenceBlock: bigint; // pre-incident block losses are valued against (HWM block or admin-pinned)
  twapRatio: bigint;
  root: `0x${string}`; // merkle root over the payout-table leaves (see settlementTree)
  poolOrder: `0x${string}`[]; // pool asset addresses, aligned to `amounts`
  poolAddrs: `0x${string}`[]; // pool CONTRACT addresses, SAME order/index as poolOrder — the on-chain
  // incidentPools snapshot; amounts[i] pays poolAddrs[i]. Signed via the `pools` hash so the
  // signature commits to the exact ordered list the payout row was computed against.
  poolPayouts: bigint[]; // total payout committed per pool (Σ amounts[i]); signed + checked ≤ cap at settle
  rows: SettledRow[];
}

/**
 * TWAP of the token→underlying ratio over [referenceBlock − twapLookback,
 * referenceBlock], sampled. The reference block is the pre-incident point:
 * TWAPing a short window before it smooths any single-block oracle glitch. This
 * is the "before" value losses are measured against.
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
 * already-spent score (from the ScoreSpent ledger) is subtracted by the caller.
 * Non-expiring (not a time-weighted average), so holding longer always grows
 * it. Each committed booster unit adds BOOSTER_BOOST_BPS to the multiplier.
 *
 * Anchored at the pre-incident `referenceBlock` (not window-end): otherwise a
 * claimant could pile scored tokens into their wallet DURING the claim window
 * to inflate their token·block integral and grab a larger payout share.
 */
export async function earnedScoreOf(
  client: PublicClient,
  cfg: IncidentConfig,
  user: `0x${string}`,
  boosterAmount: bigint,
  asOfBlock: bigint
): Promise<bigint> {
  let score = 0n;
  for (const st of cfg.scoredTokens) {
    if (st.startBlock >= asOfBlock) continue;
    const integral = await tokenBlockIntegral(client, st.token, user, st.startBlock, asOfBlock);
    // Normalize each token's raw balance·block integral to an 18-decimal basis
    // before summing across tokens, so a non-18-dec scored token isn't mis-scaled
    // relative to the others (F6). The final /SCORE_SCALE (=1e18) then cancels the
    // shared 18-dec basis exactly. (Scored-token decimals are expected ≤ 18.)
    const norm18 =
      st.decimals <= 18 ? integral * 10n ** BigInt(18 - st.decimals) : integral / 10n ** BigInt(st.decimals - 18);
    score += norm18 * st.scorePerTokenPerBlock;
  }
  // Booster multiplier: each committed unit adds BOOSTER_BOOST_BPS.
  // multiplier = (BPS + amount × bps) / BPS. Divide by SCORE_SCALE here so the
  // rate's hundredths convention applies once, at full precision.
  return (score * (BPS + boosterAmount * BOOSTER_BOOST_BPS)) / (BPS * SCORE_SCALE);
}

/**
 * Full settlement for one incident: the claimant table, per-pool payout
 * amounts, and the merkle root the TEE signs (or admin submits) / anyone verifies.
 */
export async function settle(
  client: PublicClient,
  incidentId: bigint,
  cfg: IncidentConfig,
  events: InputEvent[],
  opts: {
    insuredToken: `0x${string}`;
    insuredDecimals: number;
    referenceBlock: bigint; // pre-incident block (Incident.referenceBlock: HWM block or admin-pinned)
    windowEndBlock: bigint;
    poolOrder: `0x${string}`[]; // pool asset addresses, aligned to the openBlock pool list
    poolAddrs: `0x${string}`[]; // pool CONTRACT addresses, SAME order as poolOrder (= incidentPools)
    poolBalances: bigint[]; // SingleAssetCoverPool.totalAssets() per pool at windowEndBlock
    poolAssetUsd1e18: bigint[]; // USD price per whole asset token at windowEndBlock
    poolAssetDecimals: number[];
    boosterCollection: `0x${string}`; // Registry.boosterNFT() at openBlock (0 = none)
    boosterId: bigint;
    spentOf: (user: `0x${string}`) => bigint; // insurance score already spent (ScoreSpent ledger)
    maxCoverPoolPayoutBps: bigint; // Registry.maxCoverPoolPayoutBps: per-incident cap, as a share of each pool's balance
  }
): Promise<Settlement> {
  // Pre-incident value, anchored at Incident.referenceBlock.
  const refBlock = opts.referenceBlock;
  const twap = await twapRatioBefore(client, cfg, refBlock);
  // Underlying USD pinned to window-end block — reproducible.
  const underlyingUsd = await priceUsd1e18(client, cfg.underlyingPriceOracle, opts.windowEndBlock);

  const holdFrom = refBlock > cfg.params.holdingMarginBlocks ? refBlock - cfg.params.holdingMarginBlocks : 1n;

  // Per-claim eligibility, valuation, score (live = registered, not cancelled).
  const live = events
    .filter((e) => e.kind === "register")
    .filter((e) => !events.some((c) => c.kind === "cancel" && c.claimId === e.claimId));
  const rows: SettledRow[] = [];
  for (const e of live) {
    // Eligible = min holding over [B − margin, B] (B = referenceBlock), capped at
    // escrow. Anchored entirely PRE-INCIDENT: it proves genuine prior exposure and
    // ignores any transfers after referenceBlock. The claimant still swaps the token
    // in as escrow at joinClaim; finalizeClaim forfeits only `eligible` and refunds
    // any escrow above it, so escrowing more than one's eligible (or moving tokens
    // after the incident) is never over-charged.
    const minHeld = await minBalanceOver(client, opts.insuredToken, e.user, holdFrom, refBlock);
    const eligible = minHeld < e.amount ? minHeld : e.amount;
    // lossUsd = eligible × TWAP ratio × underlying USD price (1e18).
    const lossUsd = (((eligible * twap) / WAD) * underlyingUsd) / 10n ** BigInt(opts.insuredDecimals);

    // Booster boost is capped at the claimant's MIN booster balance over
    // [joinBlock, windowEnd] — boosters are not escrowed, so they must hold them
    // continuously (they are burned at finalize). No read when none committed.
    let boost = 0n;
    if (e.boosterAmount > 0n && opts.boosterCollection !== ZERO_ADDRESS) {
      const held = await minErc1155BalanceOver(
        client,
        opts.boosterCollection,
        e.user,
        opts.boosterId,
        e.blockNumber,
        opts.windowEndBlock
      );
      boost = e.boosterAmount < held ? e.boosterAmount : held;
    }

    // Earned score as of referenceBlock, minus what's already been spent on
    // prior claims. Pinned pre-incident (like eligibility) so the claim window
    // can't be used to farm fresh score.
    const earned = await earnedScoreOf(client, cfg, e.user, boost, opts.referenceBlock);
    const spent = opts.spentOf(e.user);
    const available = earned > spent ? earned - spent : 0n;
    // The claimant spends what they requested, capped to availability.
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
  for (let i = 0; i < opts.poolOrder.length; i++) {
    poolUsd += (opts.poolBalances[i] * opts.poolAssetUsd1e18[i]) / 10n ** BigInt(opts.poolAssetDecimals[i]);
  }
  // Payout weight is the SPENT score (not earned): claimants apportion by what
  // they choose to spend this incident.
  const totalSpent = rows.reduce((a, r) => a + (r.lossUsd > 0n ? r.scoreSpent : 0n), 0n);

  // payoutUsd = min(spent-share × poolUsd, κ × lossUsd).
  for (const r of rows) {
    if (r.lossUsd === 0n || totalSpent === 0n) {
      r.payoutUsd = 0n;
      continue;
    }
    const share = (r.scoreSpent * poolUsd) / totalSpent;
    const cap = (r.lossUsd * cfg.coverageBps) / BPS;
    r.payoutUsd = share < cap ? share : cap;
  }

  // Per-incident LP-loss cap (Registry.maxCoverPoolPayoutBps). Payouts are apportioned
  // pro-rata to each pool's balance, so capping the aggregate USD payout at
  // poolUsd × bps caps every pool at balance × bps — matching each pool's on-chain
  // maxPayoutPerIncident, which settleIncident checks poolPayouts against. Haircut
  // all claims uniformly if the raw total would exceed it.
  const maxTotalUsd = (poolUsd * opts.maxCoverPoolPayoutBps) / BPS;
  const rawTotalUsd = rows.reduce((a, r) => a + r.payoutUsd, 0n);
  if (rawTotalUsd > maxTotalUsd && rawTotalUsd > 0n) {
    for (const r of rows) r.payoutUsd = (r.payoutUsd * maxTotalUsd) / rawTotalUsd;
  }

  // Split each claim's payout per pool, pro-rata to the pool mix; sum per pool.
  const poolPayouts = opts.poolOrder.map(() => 0n);
  for (const r of rows) {
    r.amounts = opts.poolOrder.map((_, i) => (poolUsd === 0n ? 0n : (r.payoutUsd * opts.poolBalances[i]) / poolUsd));
    for (let i = 0; i < poolPayouts.length; i++) poolPayouts[i] += r.amounts[i];
  }

  const tree = settlementTree(incidentId, rows);

  return {
    incidentId,
    referenceBlock: refBlock,
    twapRatio: twap,
    root: tree.root as `0x${string}`,
    poolOrder: opts.poolOrder,
    poolAddrs: opts.poolAddrs,
    poolPayouts,
    rows,
  };
}

// Leaf encoding — SINGLE source of truth. The on-chain leaf in
// DefiInsurance.finalizeClaim (keccak256(bytes.concat(keccak256(abi.encode(
// incidentId, claimId, user, amounts, scoreSpent, eligible))))) and the FFI helper
// both mirror this exact tuple and type order; `amounts` aligns to the registered
// pool list, `eligible` is the covered insured-token amount (forfeited from escrow,
// rest refunded at finalize). Drift here breaks every on-chain proof.
export const LEAF_ENCODING = ["uint256", "uint256", "address", "uint256[]", "uint256", "uint256"] as const;

/** Build the OZ StandardMerkleTree over settlement rows using {LEAF_ENCODING}. */
export function settlementTree(
  incidentId: bigint,
  rows: { claimId: bigint; user: `0x${string}`; amounts: bigint[]; scoreSpent: bigint; eligibleAmount: bigint }[]
) {
  return StandardMerkleTree.of(
    rows.map((r) => [incidentId, r.claimId, r.user, r.amounts, r.scoreSpent, r.eligibleAmount]) as unknown as any[][],
    LEAF_ENCODING as unknown as string[]
  );
}

/** The merkle proof for `claimId`'s leaf against the settlement root. */
export function proofFor(s: Settlement, claimId: bigint): `0x${string}`[] {
  const tree = settlementTree(s.incidentId, s.rows);
  for (const [i, v] of tree.entries()) {
    if ((v as any[])[1] === claimId) return tree.getProof(i) as `0x${string}`[];
  }
  throw new Error(`claim ${claimId} not in settlement`);
}

// EIP-712 payload the TEE signs for DefiInsurance.settleIncident — SINGLE source
// of truth mirroring SETTLEMENT_TYPEHASH on-chain. `unresolved` (the live-claim
// counter, Incident.unresolved) binds the signature to the exact claimant table
// that was scored — frozen across the whole submit window.
// Sign with viem: walletClient.signTypedData(settlementTypedData(...)).
export function settlementTypedData(
  chainId: number,
  defiInsurance: `0x${string}`,
  s: Pick<Settlement, "incidentId" | "root" | "poolPayouts" | "poolAddrs">,
  unresolved: bigint
) {
  // The `pools` hash is taken from s.poolAddrs — the SAME ordered pool list the payout row
  // was computed against (parallel to poolOrder) — NOT a fresh chain read. That's what makes
  // the binding meaningful: the signature commits to the exact list used for computation, so
  // a reordered compute-list can't silently pass. It must equal the contract's incidentPools
  // (registry.coverPools().poolAddrs at openBlock). Hashed as solidityPacked (20-byte-per-
  // address) to match the on-chain keccak256(abi.encodePacked(incidentPools[id])).
  const poolsHash = keccak256(encodePacked(s.poolAddrs.map(() => "address" as const), s.poolAddrs));
  return {
    domain: { name: "DefiInsurance", version: "1", chainId, verifyingContract: defiInsurance },
    types: {
      Settlement: [
        { name: "incidentId", type: "uint256" },
        { name: "root", type: "bytes32" },
        { name: "unresolved", type: "uint256" },
        { name: "poolPayouts", type: "uint256[]" },
        { name: "pools", type: "bytes32" },
      ],
    },
    primaryType: "Settlement",
    message: { incidentId: s.incidentId, root: s.root, unresolved, poolPayouts: s.poolPayouts, pools: poolsHash },
  } as const;
}
