// The settlement algorithm. Pure given chain reads — every step here is
// recomputable by anyone from on-chain state at the incident's openBlock, which
// is what the dispute window verifies.

import { type PublicClient, keccak256, encodePacked, encodeAbiParameters } from "viem";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import {
  WAD,
  ZERO_ADDRESS,
  ratioAt,
  priceUsd1e18,
  minBalanceOver,
  minErc1155BalanceOver,
  type IncidentConfig,
  type InputEvent,
} from "./chain.js";
import type { GrossScoreProvider } from "./score.js";
import { BOOSTER_BOOST_BPS } from "./config.js";

// Backward-compatible export for callers/tests that use the raw-RPC score
// helper directly. Settlement itself consumes an injected gross-score provider.
export { earnedScoreOf } from "./score.js";

const BPS = 10_000n;

/** Floor square root for non-negative bigint values. */
function sqrtFloor(value: bigint): bigint {
  if (value < 0n) throw new Error("square root of negative value");
  if (value < 2n) return value;

  // Start at a power of two above sqrt(value), avoiding a linear-in-bit-length
  // sequence of halvings for large cumulative token-block scores.
  const bitLength = BigInt(value.toString(2).length);
  let previous = 1n << ((bitLength + 1n) >> 1n);
  let next = (previous + value / previous) >> 1n;
  while (next < previous) {
    previous = next;
    next = (next + value / next) >> 1n;
  }
  return previous;
}
export interface SettledRow {
  claimId: bigint;
  user: `0x${string}`;
  escrowAmount: bigint;
  eligibleAmount: bigint;
  lossUsd: bigint; // 1e18
  grossEarnedScore: bigint; // raw lifetime score at referenceBlock, before spent-score subtraction
  earnedScore: bigint; // raw score available to spend = raw lifetime − prior raw score spent
  scoreSpent: bigint; // raw score consumed = min(requested, raw available), recorded via ScoreSpent
  boosterAmountUsed: bigint; // min(committed, continuously held), committed in the payout leaf
  boostedScore: bigint; // scoreSpent × booster multiplier, used only for payout weighting
  payoutUsd: bigint; // 1e18, post-coverage-cap and capped-geometric allocation
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
  claimSetHash: `0x${string}`; // replayed Incident.claimSetHash — bound into the settlement signature (M-06)
  settlementInputHash: `0x${string}`; // canonical hash of sorted (user, grossEarnedScore) Phase-1 input rows
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
    grossScoreOf: GrossScoreProvider; // raw lifetime score at referenceBlock, before spent/booster
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
  const cancelledClaimIds = new Set(events.filter((e) => e.kind === "cancel").map((e) => e.claimId));
  const live = events.filter((e) => e.kind === "register" && !cancelledClaimIds.has(e.claimId));
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
    // lossUsd = eligible × TWAP ratio × underlying USD price (1e18) — the FULL
    // pre-incident value of the eligible tokens, NOT the pre/post price decrease.
    // DELIBERATE (audit D-01): payouts are a BUYOUT, not loss indemnity. The
    // claimant forfeits the eligible tokens at finalizeClaim (escrowed at join),
    // so the protocol pays up to κ (coverageBps) of what the surrendered tokens
    // were worth BEFORE the incident and keeps their residual value. Valuing
    // pre-incident also removes any dependence on a manipulable mid-crash
    // "after" price.
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

    // Raw lifetime earned score as of referenceBlock, minus what's already been
    // spent on prior claims → the UNSPENT remainder. Pinned pre-incident (like
    // eligibility) so the claim window can't be used to farm fresh score.
    const grossEarnedScore = await opts.grossScoreOf(e.user);
    const spent = opts.spentOf(e.user);
    const unspent = grossEarnedScore > spent ? grossEarnedScore - spent : 0n;
    // Consume only raw score so the durable on-chain ledger can never exceed the
    // claimant's reproducible history. Apply the booster afterward and use that
    // separate value only for payout allocation.
    const scoreSpent = e.scoreToSpend < unspent ? e.scoreToSpend : unspent;
    const boostedScore = (scoreSpent * (BPS + boost * BOOSTER_BOOST_BPS)) / BPS;
    rows.push({
      claimId: e.claimId,
      user: e.user,
      escrowAmount: e.amount,
      eligibleAmount: eligible,
      lossUsd,
      grossEarnedScore,
      earnedScore: unspent,
      scoreSpent,
      boosterAmountUsed: boost,
      boostedScore,
      payoutUsd: 0n,
      amounts: [],
    });
  }

  // Pool USD value.
  let poolUsd = 0n;
  for (let i = 0; i < opts.poolOrder.length; i++) {
    poolUsd += (opts.poolBalances[i] * opts.poolAssetUsd1e18[i]) / 10n ** BigInt(opts.poolAssetDecimals[i]);
  }
  // Per-incident payout budget. Because every claim is split pro-rata across the
  // same pool mix below, this aggregate cap also keeps each pool at or below its
  // Registry.maxCoverPoolPayoutBps limit.
  const maxTotalUsd = (poolUsd * opts.maxCoverPoolPayoutBps) / BPS;

  // Capped geometric weighting gives covered need and boosted score equal
  // multiplicative influence: weight = floor(sqrt(claimCapUsd * boostedScore)).
  // Global units cancel because only weight ratios are used. A zero cap or zero
  // score produces zero weight, so unusable score cannot dilute valid claims.
  const weighted = rows.map((row) => {
    const cap = (row.lossUsd * cfg.coverageBps) / BPS;
    return { row, cap, weight: sqrtFloor(cap * row.boostedScore) };
  });
  for (const claim of weighted) claim.row.payoutUsd = 0n;

  // Solve payout_i = min(cap_i, lambda * weight_i) without floating point.
  // Sorting by cap/weight identifies claims that saturate first. Cross-products
  // preserve exact bigint ordering; claimId is only a deterministic tie-breaker.
  const active = weighted
    .filter((claim) => claim.cap > 0n && claim.weight > 0n)
    .sort((a, b) => {
      const left = a.cap * b.weight;
      const right = b.cap * a.weight;
      if (left < right) return -1;
      if (left > right) return 1;
      return a.row.claimId < b.row.claimId ? -1 : a.row.claimId > b.row.claimId ? 1 : 0;
    });

  let remainingBudget = maxTotalUsd;
  let remainingWeight = active.reduce((sum, claim) => sum + claim.weight, 0n);
  let firstUnsaturated = 0;
  for (; firstUnsaturated < active.length && remainingWeight > 0n; firstUnsaturated++) {
    const claim = active[firstUnsaturated];
    // The lowest remaining cap/weight claim saturates iff its proportional
    // allocation reaches its cap. Compare by multiplication to avoid division.
    if (remainingBudget * claim.weight < claim.cap * remainingWeight) break;
    claim.row.payoutUsd = claim.cap;
    remainingBudget -= claim.cap;
    remainingWeight -= claim.weight;
  }

  // No remaining claim reaches its cap, so distribute the remaining budget by
  // geometric weight. Integer-division dust deliberately stays in the pools.
  if (remainingBudget > 0n && remainingWeight > 0n) {
    for (let i = firstUnsaturated; i < active.length; i++) {
      const claim = active[i];
      claim.row.payoutUsd = (remainingBudget * claim.weight) / remainingWeight;
    }
  }

  // Split each claim's payout per pool, pro-rata to the pool mix; sum per pool.
  const poolPayouts = opts.poolOrder.map(() => 0n);
  for (const r of rows) {
    r.amounts = opts.poolOrder.map((_, i) => (poolUsd === 0n ? 0n : (r.payoutUsd * opts.poolBalances[i]) / poolUsd));
    for (let i = 0; i < poolPayouts.length; i++) poolPayouts[i] += r.amounts[i];
  }

  // No live claims (claimless open, or all cancelled) → no leaves. OZ
  // StandardMerkleTree.of([]) throws, so return the zero root explicitly (L-D):
  // such an incident is non-settleable on-chain (unresolved == 0), so this is a
  // clean "nothing to settle" result, not a crash.
  const root = rows.length === 0 ? (`0x${"0".repeat(64)}` as `0x${string}`) : (settlementTree(incidentId, rows).root as `0x${string}`);

  return {
    incidentId,
    referenceBlock: refBlock,
    twapRatio: twap,
    root,
    poolOrder: opts.poolOrder,
    poolAddrs: opts.poolAddrs,
    poolPayouts,
    claimSetHash: claimSetHashOf(events),
    settlementInputHash: settlementInputHashOf(rows),
    rows,
  };
}

// Leaf encoding — SINGLE source of truth. The on-chain leaf in
// DefiInsurance.finalizeClaim (keccak256(bytes.concat(keccak256(abi.encode(
// incidentId, claimId, user, amounts, scoreSpent, boosterAmountUsed, boostedScore, eligible))))) and the FFI helper
// both mirror this exact tuple and type order; `scoreSpent` is raw score recorded
// on-chain, `boosterAmountUsed` is the historically eligible booster quantity, and
// `boostedScore` is used only for payout weighting. `amounts` aligns
// to the registered pool list, and `eligible` is the covered insured-token amount
// (forfeited from escrow, rest refunded at finalize). Drift here breaks every proof.
export const LEAF_ENCODING = ["uint256", "uint256", "address", "uint256[]", "uint256", "uint256", "uint256", "uint256"] as const;

/** Build the OZ StandardMerkleTree over settlement rows using {LEAF_ENCODING}. */
export function settlementTree(
  incidentId: bigint,
  rows: { claimId: bigint; user: `0x${string}`; amounts: bigint[]; scoreSpent: bigint; boosterAmountUsed: bigint; boostedScore: bigint; eligibleAmount: bigint }[]
) {
  return StandardMerkleTree.of(
    rows.map((r) => [incidentId, r.claimId, r.user, r.amounts, r.scoreSpent, r.boosterAmountUsed, r.boostedScore, r.eligibleAmount]) as unknown as any[][],
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

/** Build every claim proof from one tree. Use this when serializing a complete
 * settlement; rebuilding the tree once per row is quadratic in claimant count. */
export function proofsFor(s: Settlement): Map<bigint, `0x${string}`[]> {
  const tree = settlementTree(s.incidentId, s.rows);
  const proofs = new Map<bigint, `0x${string}`[]>();
  for (const [i, value] of tree.entries()) {
    const claimId = (value as unknown as any[])[1] as bigint;
    if (proofs.has(claimId)) throw new Error(`duplicate claim ${claimId} in settlement`);
    proofs.set(claimId, tree.getProof(i) as `0x${string}`[]);
  }
  return proofs;
}

/**
 * Replay the incident's register/cancel events (chain order) into the same
 * rolling claim-set commitment the contract maintains in Incident.claimSetHash
 * (M-06): join chains keccak(abi.encode(prev, claimId, user, escrow,
 * scoreToSpend, boosterAmount)); cancel chains keccak(abi.encode(prev, claimId)).
 * Must equal the on-chain value at settle or the signature won't verify.
 */
export function claimSetHashOf(events: InputEvent[]): `0x${string}` {
  let h: `0x${string}` = `0x${"0".repeat(64)}`;
  for (const e of events) {
    h =
      e.kind === "register"
        ? keccak256(
            encodeAbiParameters(
              [{ type: "bytes32" }, { type: "uint256" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
              [h, e.claimId, e.user, e.amount, e.scoreToSpend, e.boosterAmount]
            )
          )
        : keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [h, e.claimId]));
  }
  return h;
}

/** Fail closed if the RPC-replayed claim set differs from the incident commitment. */
export function assertClaimSetMatches(
  events: InputEvent[],
  onchainUnresolved: bigint,
  onchainClaimSetHash: `0x${string}`
): void {
  const replayedHash = claimSetHashOf(events);
  if (replayedHash.toLowerCase() !== onchainClaimSetHash.toLowerCase()) {
    throw new Error(`claim-set hash mismatch: replayed ${replayedHash}, on-chain ${onchainClaimSetHash}`);
  }

  const cancelled = new Set(events.filter((event) => event.kind === "cancel").map((event) => event.claimId));
  const replayedUnresolved = BigInt(
    events.filter((event) => event.kind === "register" && !cancelled.has(event.claimId)).length
  );
  if (replayedUnresolved !== onchainUnresolved) {
    throw new Error(
      `unresolved claim count mismatch: replayed ${replayedUnresolved}, on-chain ${onchainUnresolved}`
    );
  }
}

export interface SettlementInputRow {
  user: `0x${string}`;
  grossEarnedScore: bigint;
}

/**
 * Canonical Phase-1 settlement-score input rows. Exactly one row is permitted
 * per live claimant address; rows are sorted by the address's canonical 20-byte
 * value so event order, RPC response order, and checksum casing cannot affect
 * the artifact commitment.
 */
export function canonicalSettlementInputRows<T extends SettlementInputRow>(rows: readonly T[]): T[] {
  const sorted = [...rows].sort((a, b) => {
    const aa = a.user.toLowerCase();
    const bb = b.user.toLowerCase();
    return aa < bb ? -1 : aa > bb ? 1 : 0;
  });
  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i - 1].user.toLowerCase() === sorted[i].user.toLowerCase()) {
      throw new Error(`duplicate settlement input user: ${sorted[i].user}`);
    }
  }
  return sorted;
}

/**
 * Phase-1 commitment to the raw score inputs consumed by settlement:
 *
 *   keccak256(abi.encode(address[] users, uint256[] grossScores))
 *
 * `grossScores[i]` is lifetime score at referenceBlock before subtracting
 * scoreSpent and before applying the incident booster. Empty input hashes the
 * ABI encoding of two empty arrays (not bytes32(0)).
 */
export function settlementInputHashOf(rows: readonly SettlementInputRow[]): `0x${string}` {
  const canonical = canonicalSettlementInputRows(rows);
  return keccak256(
    encodeAbiParameters(
      [{ type: "address[]" }, { type: "uint256[]" }],
      [canonical.map((r) => r.user), canonical.map((r) => r.grossEarnedScore)]
    )
  );
}

// EIP-712 payload the TEE signs for DefiInsurance.settleIncident — SINGLE source
// of truth mirroring SETTLEMENT_TYPEHASH on-chain. `unresolved` (the live-claim
// counter, Incident.unresolved) and `claimSet` (the Incident.claimSetHash rolling
// commitment, reproduced by {claimSetHashOf}) bind the signature to the exact
// claimant table that was scored. `teePcrHash` binds the signer claim to the
// incident's snapshotted PCR0/PCR1/PCR2 image.
// Sign with viem: walletClient.signTypedData(settlementTypedData(...)).
export function settlementTypedData(
  chainId: number,
  defiInsurance: `0x${string}`,
  s: Pick<Settlement, "incidentId" | "root" | "poolPayouts" | "poolAddrs">,
  unresolved: bigint,
  claimSet: `0x${string}`,
  teePcrHash: `0x${string}`
) {
  // The `pools` hash is taken from s.poolAddrs — the SAME ordered pool list the payout row
  // was computed against (parallel to poolOrder) — NOT a fresh chain read. That's what makes
  // the binding meaningful: the signature commits to the exact list used for computation, so
  // a reordered compute-list can't silently pass. It must equal the contract's incidentPools
  // (registry.coverPools().poolAddrs at openBlock). Hashed as solidityPacked (20-byte-per-
  // address) to match the on-chain keccak256(abi.encodePacked(incidentPools[id])).
  // Encode as a single "address[]" so each element is word-padded to 32 bytes,
  // exactly as Solidity's abi.encodePacked(address[]) does (per-element "address"
  // packs 20 bytes and does NOT match the contract — see H-01).
  const poolsHash = keccak256(encodePacked(["address[]"], [s.poolAddrs]));
  return {
    domain: { name: "DefiInsurance", version: "1", chainId, verifyingContract: defiInsurance },
    types: {
      Settlement: [
        { name: "incidentId", type: "uint256" },
        { name: "root", type: "bytes32" },
        { name: "unresolved", type: "uint256" },
        { name: "poolPayouts", type: "uint256[]" },
        { name: "pools", type: "bytes32" },
        { name: "claimSet", type: "bytes32" },
        { name: "teePcrHash", type: "bytes32" },
      ],
    },
    primaryType: "Settlement",
    message: {
      incidentId: s.incidentId,
      root: s.root,
      unresolved,
      poolPayouts: s.poolPayouts,
      pools: poolsHash,
      claimSet,
      teePcrHash,
    },
  } as const;
}
