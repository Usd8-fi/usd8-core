// Off-chain settlement for USD8 DeFi insurance — runnable by anyone, locally.
//
//   compute <incidentId>   recompute the settlement table + merkle root + per-claim
//                          proofs (the root the TEE signs / admin submits; the proofs claimants
//                          finalize with)
//   verify  <incidentId>   recompute and compare to the root the admin submitted
//                          on-chain — prints MATCH / MISMATCH (exit 1 on mismatch)
//
// Everything is read from chain state — there are no trusted inputs. The
// per-incident config is reconstructed from contract state at the incident's
// openBlock; pool balances/prices at the window-end block; the spent-score
// ledger from ScoreSpent logs. Point RPC_URL at any archive node for the
// relevant chain; see config.ts for the addresses and per-asset USD feeds.

import {
  makeClient,
  DEFI_ABI,
  readInputEvents,
  blockAtTimestamp,
  incidentConfigOf,
  poolsAt,
  poolTotalAssetsAt,
  boosterNftAt,
  maxCoverPoolPayoutBpsAt,
  spentScoreByUser,
  priceUsd1e18,
  decimalsOf,
} from "./chain.js";
import { CONFIG, CONFIG_VERSION, CHAIN_ID, assetUsdFeedOf } from "./config.js";
import { settle, proofFor, type Settlement } from "./compute.js";

// The only booster token id in use (USD8Booster tier: id 1 = the 1% booster);
// mirrors DefiInsurance.BOOSTER_ID.
const BOOSTER_ID = 1n;

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
  // fork/testnet and silently produce a misleading root.
  const actualChainId = await client.getChainId();
  if (actualChainId !== CHAIN_ID) {
    throw new Error(`wrong chain: RPC reports ${actualChainId}, expected ${CHAIN_ID} (mainnet)`);
  }

  const inc = (await client.readContract({
    address: CONFIG.defiInsurance,
    abi: DEFI_ABI,
    functionName: "incidents",
    args: [incidentId],
  })) as readonly [`0x${string}`, bigint, `0x${string}`, bigint, bigint, bigint, bigint, number, bigint];

  const insuredToken = inc[0];
  const windowEnd = inc[1];
  const onchainRoot = inc[2];
  const referenceBlock = inc[5]; // pre-incident block (HWM block or admin-pinned)
  const openBlock = inc[6]; // block the incident opened at — config/topology anchor

  // Deterministic block anchors: openBlock (config + topology + spent-score
  // cutoff), referenceBlock (earned score — the pre-incident point), and the
  // window-end block (found from its timestamp; pool balances + prices + booster
  // holdings). Every read pins one of these, so the settlement is identical no
  // matter when it is (re)computed.
  const windowEndBlock = await blockAtTimestamp(client, windowEnd);

  // Register/cancel event stream in true chain order → the live claimant table.
  const events = await readInputEvents(client, incidentId, openBlock, windowEndBlock);

  // Per-incident settlement config, reconstructed from contract state at openBlock.
  const cfg = await incidentConfigOf(client, insuredToken, openBlock);
  const insuredDecimals = await decimalsOf(client, insuredToken);

  // Registered pool set at openBlock (frozen for the incident's life, so it equals
  // the live list) → per-pool balances + prices at window-end. INVARIANT: this exact
  // order — registry.coverPools() at openBlock — is what the contract snapshotted into
  // incidentPools, and amounts[i] pays incidentPools[i]. Never sort or reorder `assets`
  // / `poolAddrs`; the `pools` hash in the settlement signature binds this ordering.
  const { assets, poolAddrs } = await poolsAt(client, openBlock);
  const poolBalances: bigint[] = [];
  const poolAssetUsd1e18: bigint[] = [];
  const poolAssetDecimals: number[] = [];
  for (let i = 0; i < poolAddrs.length; i++) {
    poolBalances.push(await poolTotalAssetsAt(client, poolAddrs[i], windowEndBlock));
    poolAssetUsd1e18.push(await priceUsd1e18(client, assetUsdFeedOf(assets[i]), windowEndBlock));
    poolAssetDecimals.push(await decimalsOf(client, assets[i]));
  }

  const boosterCollection = await boosterNftAt(client, openBlock);
  // Per-incident payout cap — read at openBlock (topology anchor); it can't change
  // mid-incident (Registry.setMaxPayoutBps is frozen-gated), so this is the same
  // value settleIncident checks the committed poolPayouts against.
  const maxCoverPoolPayoutBps = await maxCoverPoolPayoutBpsAt(client, openBlock);

  // Insurance score already spent per user, summed from ScoreSpent logs across
  // every payout module ever registered, pinned to blocks before openBlock.
  // Intentionally a LATER cutoff than earned (referenceBlock): earned is capped
  // pre-incident to stop farming; spent must catch every prior commitment, else a
  // score burned between referenceBlock and open could be re-claimed. See
  // spentScoreByUser.
  const spentMap = await spentScoreByUser(client, openBlock);
  const spentOf = (user: `0x${string}`) => spentMap.get(user.toLowerCase()) ?? 0n;

  const s = await settle(client, incidentId, cfg, events, {
    insuredToken,
    insuredDecimals,
    referenceBlock,
    windowEndBlock,
    poolOrder: assets,
    poolAddrs,
    poolBalances,
    poolAssetUsd1e18,
    poolAssetDecimals,
    boosterCollection,
    boosterId: BOOSTER_ID,
    spentOf,
    maxCoverPoolPayoutBps,
  });
  return { s, onchainRoot };
}

function printSettlement(s: Settlement, withProofs: boolean) {
  const out = {
    configVersion: CONFIG_VERSION,
    chainId: CHAIN_ID,
    registry: CONFIG.registry,
    defiInsurance: CONFIG.defiInsurance,
    incidentId: s.incidentId.toString(),
    referenceBlock: s.referenceBlock.toString(),
    twapRatio: s.twapRatio.toString(),
    root: s.root,
    poolOrder: s.poolOrder,
    poolPayouts: s.poolPayouts.map((p) => p.toString()),
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
