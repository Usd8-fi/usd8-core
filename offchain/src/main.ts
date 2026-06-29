// Off-chain settlement for USD8 DeFi insurance — runnable by anyone, locally.
//
//   compute <incidentId>   recompute the settlement table + merkle root + per-claim
//                          proofs (the root the admin submits; the proofs claimants
//                          finalize with)
//   verify  <incidentId>   recompute and compare to the root the admin submitted
//                          on-chain — prints MATCH / MISMATCH (exit 1 on mismatch)
//
// Everything is read from chain state — there are no trusted inputs. The
// per-incident config snapshot, the claimant-table commitment
// (Incident.inputHash), and the pool balances/prices all come from the
// contracts, so the result is reproducible by anyone. Point RPC_URL at any
// archive node for the relevant chain; see config.ts for the addresses.

import {
  makeClient,
  COVER_POOL_ABI,
  readInputEvents,
  firstClaimBlockOf,
  blockAtTimestamp,
  incidentConfigOf,
  priceUsd1e18,
  decimalsOf,
  insuranceScoreLedgerOf,
  insuranceScoreSpentOf,
} from "./chain.js";
import { CONFIG, CONFIG_VERSION, CHAIN_ID } from "./config.js";
import { settle, computeInputHash, proofFor, type Settlement } from "./compute.js";

function rpc(): string {
  const u = process.env.RPC_URL;
  if (!u) throw new Error("RPC_URL not set — point it at an archive node for the configured chain");
  return u;
}

/** Recompute the full settlement for `incidentId`, and return the root the
 *  admin already submitted on-chain (0x0 if none yet) alongside it. */
async function buildSettlement(incidentId: bigint): Promise<{ s: Settlement; onchainRoot: `0x${string}` }> {
  const client = makeClient(rpc());

  // Guard against pointing the tool at the wrong RPC: addresses can collide on a
  // fork/testnet and silently produce a misleading root. Refuse unless the RPC's
  // chain id matches the one CONFIG was pinned to.
  const actualChainId = await client.getChainId();
  if (actualChainId !== CHAIN_ID) {
    throw new Error(`wrong chain: RPC reports ${actualChainId}, expected ${CHAIN_ID} (mainnet)`);
  }

  const inc = (await client.readContract({
    address: CONFIG.defiInsurance,
    abi: COVER_POOL_ABI,
    functionName: "incidents",
    args: [incidentId],
  })) as readonly [`0x${string}`, bigint, `0x${string}`, `0x${string}`, bigint, bigint, bigint, bigint];

  const insuredToken = inc[0];
  const windowEnd = inc[1];
  const onchainRoot = inc[2];
  const onchainInputHash = inc[3];
  const referenceBlock = inc[7]; // admin-pinned pre-incident block

  // Deterministic block anchors: the window-end block (found from its
  // timestamp) and the incident's first-claim block. Every read below pins one
  // of these, so the settlement is identical no matter when it is (re)computed.
  const windowEndBlock = await blockAtTimestamp(client, windowEnd);
  const firstClaimBlock = await firstClaimBlockOf(client, incidentId, 1n, windowEndBlock);

  // Register/cancel event stream in true chain order → claimant-table commitment.
  const events = await readInputEvents(client, incidentId, firstClaimBlock, windowEndBlock);

  // Self-check: the reconstructed stream MUST hash to the contract's stored
  // value, or the table is wrong (reordered/partial) — refuse to proceed.
  const localHash = computeInputHash(events);
  if (localHash.toLowerCase() !== onchainInputHash.toLowerCase()) {
    throw new Error(`inputHash mismatch: local ${localHash} vs on-chain ${onchainInputHash} — table reconstruction is wrong`);
  }

  // Per-incident settlement config, frozen on-chain when the incident opened.
  const cfg = await incidentConfigOf(client, incidentId);
  const insuredDecimals = await decimalsOf(client, insuredToken);

  // Stake-asset list + balances + USD prices, in CoverPool order, pinned to the
  // window-end block. Price feeds come from coverPoolAssets(...).usdPriceFeed.
  const nAssets = (await client.readContract({
    address: CONFIG.coverPool,
    abi: COVER_POOL_ABI,
    functionName: "coverPoolAssetListLength",
    blockNumber: windowEndBlock,
  })) as bigint;
  const assetOrder: `0x${string}`[] = [];
  const assetBalances: bigint[] = [];
  const assetUsd1e18: bigint[] = [];
  const assetDecimals: number[] = [];
  for (let i = 0n; i < nAssets; i++) {
    const a = (await client.readContract({
      address: CONFIG.coverPool,
      abi: COVER_POOL_ABI,
      functionName: "coverPoolAssetList",
      args: [i],
      blockNumber: windowEndBlock,
    })) as `0x${string}`;
    const bal = (await client.readContract({
      address: CONFIG.coverPool,
      abi: COVER_POOL_ABI,
      functionName: "totalAssets",
      args: [a],
      blockNumber: windowEndBlock,
    })) as bigint;
    const assetState = (await client.readContract({
      address: CONFIG.coverPool,
      abi: COVER_POOL_ABI,
      functionName: "coverPoolAssets",
      args: [a],
      blockNumber: windowEndBlock,
    })) as readonly [bigint, bigint, bigint, bigint, bigint, bigint, `0x${string}`, bigint];
    assetOrder.push(a);
    assetBalances.push(bal);
    assetUsd1e18.push(await priceUsd1e18(client, assetState[6], windowEndBlock));
    assetDecimals.push(await decimalsOf(client, a));
  }

  // Insurance score already spent per user (CoverPool ledger), pinned at the
  // pre-incident referenceBlock to match earnedScoreOf — available = earned −
  // spent, both as of referenceBlock. Cached per user.
  const ledger = await insuranceScoreLedgerOf(client);
  const spentCache = new Map<string, bigint>();
  const spentOf = (user: `0x${string}`) => spentCache.get(user.toLowerCase()) ?? 0n;
  for (const e of events) {
    const key = e.user.toLowerCase();
    if (spentCache.has(key)) continue;
    spentCache.set(key, await insuranceScoreSpentOf(client, ledger, e.user, referenceBlock));
  }

  const s = await settle(client, incidentId, cfg, events, {
    insuredToken,
    insuredDecimals,
    referenceBlock,
    windowEndBlock,
    assetOrder,
    assetBalances,
    assetUsd1e18,
    assetDecimals,
    spentOf,
  });
  return { s, onchainRoot };
}

function printSettlement(s: Settlement, withProofs: boolean) {
  const out = {
    configVersion: CONFIG_VERSION,
    chainId: CHAIN_ID,
    coverPool: CONFIG.coverPool,
    defiInsurance: CONFIG.defiInsurance,
    incidentId: s.incidentId.toString(),
    referenceBlock: s.referenceBlock.toString(),
    twapRatio: s.twapRatio.toString(),
    inputHash: s.inputHash,
    root: s.root,
    assetOrder: s.assetOrder,
    rows: s.rows.map((r) => ({
      claimId: r.claimId.toString(),
      user: r.user,
      escrowAmount: r.escrowAmount.toString(),
      eligibleAmount: r.eligibleAmount.toString(),
      lossUsd: r.lossUsd.toString(),
      earnedScore: r.earnedScore.toString(),
      scoreSpent: r.scoreSpent.toString(),
      payoutUsd: r.payoutUsd.toString(),
      amounts: r.amounts.map((a) => a.toString()),
      // The exact (amounts, scoreSpent, proof) a claimant passes to finalizeClaim.
      ...(withProofs ? { proof: proofFor(s, r.claimId) } : {}),
    })),
  };
  console.log(JSON.stringify(out, null, 2));
}

async function main() {
  const [mode, arg] = process.argv.slice(2);
  if ((mode !== "compute" && mode !== "verify") || !arg) {
    console.error("usage: <compute|verify> <incidentId>");
    process.exit(2);
  }
  const incidentId = BigInt(arg);
  const { s, onchainRoot } = await buildSettlement(incidentId);

  if (mode === "compute") {
    printSettlement(s, true);
    return;
  }

  // verify: compare the independent recompute to the root the admin submitted.
  printSettlement(s, false);
  const match = onchainRoot.toLowerCase() === s.root.toLowerCase();
  console.error(`computed root: ${s.root}`);
  console.error(`on-chain root: ${onchainRoot}`);
  if (!match) {
    console.error("MISMATCH — the submitted root does NOT reproduce from chain history (disputable).");
    process.exit(1);
  }
  console.error("MATCH — the submitted root reproduces exactly from chain history.");
}

main().catch((e) => {
  console.error("FATAL:", e.message);
  process.exit(1);
});
