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
// openBlock; pool balances/prices at the window-end block; and cumulative spent
// score from Registry state. Set DRPC_KEY for the default authenticated dRPC
// Ethereum archive endpoint, or point RPC_URL at another archive node; see
// config.ts for the addresses and per-asset USD feeds.

import {
  makeClient,
  DEFI_ABI,
  assertContractCodeAt,
  readInputEvents,
  assertBlockAnchorsUnchanged,
  finalizedSettlementAnchors,
  incidentConfigOf,
  poolsAt,
  poolTotalAssetsAt,
  boosterNftAt,
  incidentTeePcrHashAt,
  maxCoverPoolPayoutBpsAt,
  spentScoreOf,
  priceUsd1e18,
  decimalsOf,
  rpcMetricsOf,
  type RpcMetrics,
  type SettlementAnchors,
} from "./chain.js";
import {
  CONFIG,
  CONFIG_VERSION,
  BOOSTER_ID,
  CHAIN_ID,
  DEFAULT_RPC_CONCURRENCY,
  assertBootstrapConfig,
  assetUsdFeedOf,
  configHash,
} from "./config.js";
import {
  assertClaimSetMatches,
  canonicalSettlementInputRows,
  settle,
  proofsFor,
  type Settlement,
} from "./compute.js";
import { RpcScoreSource, type ScoreSource } from "./score.js";
import { CheckpointScoreSource, type CheckpointScoreMetadata } from "./checkpointScore.js";
import {
  assertFinalizedIncidentFields,
  readScoreCheckpointOptions,
  readSpentScores,
  type SpentReadMetrics,
} from "./runtime.js";

const DRPC_ETHEREUM_URL = "https://lb.drpc.org/ogrpc?network=ethereum";

function rpc(): { url: string; drpcKey?: string } {
  const drpcKey = process.env.DRPC_KEY?.trim() || undefined;
  const configuredUrl = process.env.RPC_URL?.trim() || undefined;
  const url = configuredUrl ?? (drpcKey ? DRPC_ETHEREUM_URL : undefined);
  if (!url) {
    throw new Error(
      "RPC not configured — set DRPC_KEY for dRPC Ethereum, or RPC_URL for another mainnet archive node"
    );
  }
  return { url, drpcKey };
}

/** Recompute the full settlement for `incidentId`, and return the root the
 *  admin already submitted on-chain (0x0 if none yet) alongside it. */
interface RunMetadata {
  anchors: SettlementAnchors;
  teePcrHash: `0x${string}`;
  rpc: RpcMetrics;
  scoreSource: CheckpointScoreMetadata | { kind: "raw-rpc"; asOfBlock: bigint };
  spentReads: SpentReadMetrics;
}

async function buildSettlement(
  incidentId: bigint
): Promise<{ s: Settlement; onchainRoot: `0x${string}`; metadata: RunMetadata }> {
  assertBootstrapConfig();
  const connection = rpc();
  const client = makeClient(connection.url, connection.drpcKey);

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
  })) as readonly [`0x${string}`, bigint, `0x${string}`, bigint, bigint, bigint, bigint, number, bigint, `0x${string}`];

  const insuredToken = inc[0];
  const windowEnd = inc[1];
  const referenceBlock = inc[5]; // pre-incident block (HWM block or admin-pinned)
  const openBlock = inc[6]; // block the incident opened at — config/topology anchor

  // Deterministic block anchors: openBlock (config + topology + spent-score
  // cutoff), referenceBlock (earned score — the pre-incident point), and the
  // window-end block (LAST block with timestamp <= claimWindowEndTime — the last
  // in-window block; pool balances + prices + booster holdings). Every read pins
  // one of these, so the settlement is identical no matter when it is (re)computed.
  const anchors = await finalizedSettlementAnchors(client, referenceBlock, openBlock, windowEnd);
  const windowEndBlock = anchors.windowEnd.number;
  const finalizedIncident = (await client.readContract({
    address: CONFIG.defiInsurance,
    abi: DEFI_ABI,
    functionName: "incidents",
    args: [incidentId],
    blockNumber: anchors.finalizedHead.number,
  })) as typeof inc;
  assertFinalizedIncidentFields(
    { insuredToken, windowEnd, referenceBlock, openBlock },
    {
      insuredToken: finalizedIncident[0],
      windowEnd: finalizedIncident[1],
      referenceBlock: finalizedIncident[5],
      openBlock: finalizedIncident[6],
    }
  );
  await Promise.all([
    assertContractCodeAt(client, CONFIG.registry, "Registry", openBlock),
    assertContractCodeAt(client, CONFIG.defiInsurance, "DefiInsurance", openBlock),
  ]);
  const teePcrHash = await incidentTeePcrHashAt(client, incidentId, openBlock);

  // Replay logs and read the incident at the exact claim-window boundary. Using
  // historical state avoids false mismatches after later claim finalizations
  // decrement the live `unresolved` counter.
  const [events, incidentAtWindowEnd] = await Promise.all([
    readInputEvents(client, incidentId, openBlock, windowEndBlock),
    client.readContract({
      address: CONFIG.defiInsurance,
      abi: DEFI_ABI,
      functionName: "incidents",
      args: [incidentId],
      blockNumber: windowEndBlock,
    }) as Promise<typeof inc>,
  ]);
  assertClaimSetMatches(events, incidentAtWindowEnd[3], incidentAtWindowEnd[9]);

  // Per-incident settlement config, reconstructed from contract state at openBlock.
  const cfg = await incidentConfigOf(client, insuredToken, openBlock);
  // Raw replay remains the default verifier. Operators may opt into the exact
  // global Transfer checkpoint using a KMS-injected HMAC key; settlement math
  // and settlementInputHash remain identical under either source.
  const checkpoint = readScoreCheckpointOptions(process.env);
  let scoreSource: ScoreSource;
  let scoreSourceMetadata: RunMetadata["scoreSource"];
  if (checkpoint) {
    const indexed = await CheckpointScoreSource.open(
      client,
      cfg,
      referenceBlock,
      checkpoint.path,
      CHAIN_ID,
      checkpoint.integrityKey
    );
    scoreSource = indexed;
    scoreSourceMetadata = indexed.metadata;
  } else {
    scoreSource = new RpcScoreSource(client, cfg, referenceBlock);
    scoreSourceMetadata = { kind: "raw-rpc", asOfBlock: referenceBlock };
  }
  // Decimals pinned to the incident's snapshot blocks (M-05): an upgradeable
  // token changing decimals must never alter an old incident's recomputation.
  const insuredDecimals = await decimalsOf(client, insuredToken, openBlock);

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
    const feed = assetUsdFeedOf(assets[i]);
    await Promise.all([
      assertContractCodeAt(client, poolAddrs[i], `cover pool ${i}`, openBlock),
      assertContractCodeAt(client, feed, `USD feed for ${assets[i]}`, windowEndBlock),
    ]);
    poolBalances.push(await poolTotalAssetsAt(client, poolAddrs[i], windowEndBlock));
    poolAssetUsd1e18.push(await priceUsd1e18(client, feed, windowEndBlock));
    poolAssetDecimals.push(await decimalsOf(client, assets[i], windowEndBlock));
  }

  const boosterCollection = await boosterNftAt(client, openBlock);
  // Per-incident payout cap — read at openBlock (topology anchor); it can't change
  // mid-incident (Registry.setMaxPayoutBps is frozen-gated), so this is the same
  // value settleIncident checks the committed poolPayouts against.
  const maxCoverPoolPayoutBps = await maxCoverPoolPayoutBpsAt(client, openBlock);

  // Insurance score already spent per claimant: one Registry.scoreSpent archive
  // read each at the END of openBlock (claimant addresses are known from the event
  // replay above). Reading at openBlock — not openBlock−1 (M-03) — captures score
  // consumption recorded EARLIER IN THE SAME BLOCK, e.g. a prior incident finalizing
  // in a separate tx before this incident opens; openBlock−1 would miss it and let
  // that score be reused. Safe because a newly-opened incident cannot finalize in
  // its own opening block, so this snapshot never includes the incident being
  // settled. Intentionally a LATER cutoff than earned (referenceBlock): earned is
  // capped pre-incident to stop farming; spent must catch every prior commitment.
  const claimants = events.filter((e) => e.kind === "register").map((e) => e.user);
  const spentReads = await readSpentScores(
    claimants,
    DEFAULT_RPC_CONCURRENCY,
    async (user) => await spentScoreOf(client, user, openBlock)
  );
  const spentOf = (user: `0x${string}`) => spentReads.values.get(user.toLowerCase()) ?? 0n;

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
    grossScoreOf: (user) => scoreSource.grossScoreOf(user),
    spentOf,
    maxCoverPoolPayoutBps,
  });
  // The root may be submitted while a long historical computation is running.
  // Re-read it after deterministic computation so `verify` compares against
  // current chain state rather than startup. Then make the anchor assertion the
  // final RPC work before returning or printing an artifact.
  const latestIncident = (await client.readContract({
    address: CONFIG.defiInsurance,
    abi: DEFI_ABI,
    functionName: "incidents",
    args: [incidentId],
  })) as typeof inc;
  await assertBlockAnchorsUnchanged(client, anchors);
  return {
    s,
    onchainRoot: latestIncident[2],
    metadata: {
      anchors,
      teePcrHash,
      rpc: rpcMetricsOf(client),
      scoreSource: scoreSourceMetadata,
      spentReads: spentReads.metrics,
    },
  };
}

function printSettlement(s: Settlement, metadata: RunMetadata, withProofs: boolean) {
  const proofs = withProofs ? proofsFor(s) : undefined;
  const out = {
    configVersion: CONFIG_VERSION,
    // Reproducibility metadata plus the commitments bound by the settlement digest.
    configHash: configHash(),
    teePcrHash: metadata.teePcrHash,
    claimSetHash: s.claimSetHash,
    settlementInputHash: s.settlementInputHash,
    // Canonical preimage of settlementInputHash: one live row per user, sorted
    // by the address's 20-byte value. Scores are pre-spend and pre-booster.
    settlementInputRows: canonicalSettlementInputRows(s.rows).map((r) => ({
      user: r.user,
      grossEarnedScore: r.grossEarnedScore.toString(),
    })),
    chainId: CHAIN_ID,
    blockAnchors: Object.fromEntries(
      Object.entries(metadata.anchors).map(([name, anchor]) => [
        name,
        { number: anchor.number.toString(), timestamp: anchor.timestamp.toString(), hash: anchor.hash },
      ])
    ),
    rpcMetrics: {
      historicalLogs: metadata.rpc,
      spentReads: metadata.spentReads,
    },
    scoreSource:
      metadata.scoreSource.kind === "raw-rpc"
        ? { kind: metadata.scoreSource.kind, asOfBlock: metadata.scoreSource.asOfBlock.toString() }
        : {
            kind: metadata.scoreSource.kind,
            path: metadata.scoreSource.path,
            asOfBlock: metadata.scoreSource.asOfBlock.toString(),
            asOfBlockHash: metadata.scoreSource.asOfBlockHash,
            indexedTransfers: metadata.scoreSource.indexedTransfers,
            indexedTokens: metadata.scoreSource.indexedTokens,
          },
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
      grossEarnedScore: r.grossEarnedScore.toString(),
      earnedScore: r.earnedScore.toString(),
      scoreSpent: r.scoreSpent.toString(),
      boosterAmountUsed: r.boosterAmountUsed.toString(),
      boostedScore: r.boostedScore.toString(),
      payoutUsd: r.payoutUsd.toString(),
      amounts: r.amounts.map((a) => a.toString()),
      // Exact finalizeClaim values: amounts, raw scoreSpent, boosterAmountUsed,
      // boostedScore, eligibleAmount, and proof.
      ...(proofs ? { proof: proofs.get(r.claimId)! } : {}),
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
  const { s, onchainRoot, metadata } = await buildSettlement(incidentId);

  if (mode === "compute") {
    printSettlement(s, metadata, true);
    return;
  }

  // verify: compare the independent recompute to the root the admin submitted.
  printSettlement(s, metadata, false);
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
