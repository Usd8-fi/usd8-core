// Bootstrap pointers ONLY: the contract addresses to read from, plus the
// per-asset USD price feeds (the ONLY off-chain-configured settlement input —
// pool asset pricing is no longer on-chain). Everything else — coverage κ,
// windows, the conversion recipe, the underlying oracle, the scored-token set —
// lives on-chain and is read as of each incident's openBlock, so the settlement
// is reproducible from chain state alone. Version it.

import { isAddress, keccak256, stringToHex } from "viem";

// 4.0.0 introduced capped geometric payout-root semantics.
// 4.1.0 added per-insured-token minimum claim enforcement and the matching ABI.
// 4.2.0 rejects future-dated, reversed, and superseded oracle rounds.
// 4.3.0 fails closed on claim-set and ERC-20 balance-replay mismatches.
// 4.4.0 requires finalized settlement anchors and supports authenticated exact score checkpoints.
// 4.5.0 records the booster token ID and score multiplier policy in configHash.
// 4.6.0 uses the minimal on-chain settlement digest; config/input hashes remain artifact metadata.
// 4.7.0 separates raw score consumption from boosted payout score and commits both in each Merkle leaf.
// 4.8.0 commits boosterAmountUsed and verifies booster arithmetic on-chain.
export const CONFIG_VERSION = "4.8.0";

// Settlement policy mirrored from DefiInsurance's public constants. Kept here as
// the single TypeScript source used by computation, RPC orchestration, and the
// reproducibility artifact.
export const BOOSTER_ID = 1n;
export const BOOSTER_BOOST_BPS = 100n;

// Max age (seconds) a Chainlink feed's answer may have, measured at the pinned
// block, before settlement treats it as stale and refuses to value against it
// (audit L-02). Conservative default (24h) covering long-heartbeat USD feeds; tune
// down per-feed if all configured oracles have tighter heartbeats. A stale feed
// throws → no root is produced → the incident voids (escrow recoverable) rather
// than settling on a frozen price the dispute window can't self-correct.
// Lives here (not chain.ts) because it is settlement policy recorded by {configHash}.
export const MAX_ORACLE_STALENESS = 86_400n;

// eth_getLogs completeness policy (M-01). A truncating provider that silently
// caps results makes the settler drop Transfer logs → wrong min-balance/score →
// a wrong signed root. There is NO universal cap: providers differ (e.g.
// Blockscout documents a 1,000-result eth_getLogs limit). So these MUST be set
// to values at or below the CONFIGURED provider's documented limits. {configHash}
// records which policy produced an artifact. LOG_RESULT_CAP: if a single-block range still returns
// ≥ this, the settler FAILS CLOSED (throws) rather than sign a possibly-truncated
// result — completeness can't be proven past one block. Defaults are conservative
// (Blockscout-compatible); raise only to a value proven ≤ the real provider cap.
export const MAX_LOG_RANGE = 1_000n; // blocks per eth_getLogs request
export const LOG_RESULT_CAP = 1_000; // results per request treated as "possibly truncated"

// Operational RPC controls. These do not affect settlement math or configHash:
// they only bound provider load and stop hung HTTP requests.
export const DEFAULT_RPC_CONCURRENCY = 8;
export const DEFAULT_RPC_TIMEOUT_MS = 30_000;

// USD8 deploys to Ethereum mainnet only. Locked here (not configurable) so the
// tool can never be pointed at a fork/testnet with colliding addresses; the
// RPC's chain id is checked against this at startup.
export const CHAIN_ID = 1;

export interface Config {
  /** Registry — topology hub: coverPools(), scored tokens, boosterNFT, payout-module history. */
  registry: `0x${string}`;
  /** DefiInsurance — incidents, claims, per-incident settlement config, ScoreSpent ledger. */
  defiInsurance: `0x${string}`;
  /**
   * USD price feed per pool asset. Pool valuation is no longer an on-chain
   * per-asset feed; pools no longer hold one, so the settler prices each pool's
   * asset() from this map.
   * Keyed by the LOWERCASED asset address → a Chainlink-style AggregatorV3 feed
   * (latestRoundData/decimals). Every registered pool asset MUST have an entry.
   */
  assetUsdFeed: Record<string, `0x${string}`>;
}

// Filled in after Registry and DefiInsurance are deployed to mainnet — this
// package is published once the addresses (and pool assets) are known.
export const CONFIG: Config = {
  registry: "0x0000000000000000000000000000000000000000",
  defiInsurance: "0x0000000000000000000000000000000000000000",
  assetUsdFeed: {
    // "0xa0b8...eb48": "0x8fFf...6" // e.g. USDC → USDC/USD feed
  },
};

const ZERO_CONFIG_ADDRESS = "0x0000000000000000000000000000000000000000";

function assertConfiguredAddress(value: string, label: string): void {
  if (!isAddress(value)) throw new Error(`invalid ${label} address: ${value}`);
  if (value.toLowerCase() === ZERO_CONFIG_ADDRESS) throw new Error(`${label} address is zero`);
}

/** Fail before RPC work if deployment pointers are placeholders or malformed. */
export function assertBootstrapConfig(config: Config = CONFIG): void {
  assertConfiguredAddress(config.registry, "registry");
  assertConfiguredAddress(config.defiInsurance, "defiInsurance");
  if (config.registry.toLowerCase() === config.defiInsurance.toLowerCase()) {
    throw new Error("registry and defiInsurance addresses must differ");
  }
  for (const [asset, feed] of Object.entries(config.assetUsdFeed)) {
    if (asset !== asset.toLowerCase()) throw new Error(`assetUsdFeed key must be lowercase: ${asset}`);
    assertConfiguredAddress(asset, "pool asset");
    assertConfiguredAddress(feed, `USD feed for ${asset}`);
  }
}

/** The USD feed for a pool asset, or throw if unconfigured. */
export function assetUsdFeedOf(asset: `0x${string}`): `0x${string}` {
  const feed = CONFIG.assetUsdFeed[asset.toLowerCase()];
  if (!feed) throw new Error(`no assetUsdFeed configured for pool asset ${asset} — add it to config.ts`);
  return feed;
}

/**
 * Artifact hash of every off-chain settlement input that isn't read from chain
 * state: the software/config version, chain, contract addresses, the pool-asset
 * feed map, and the staleness policy. Used for reproducibility only; it is not
 * included in the on-chain settlement signature. Deterministic: keys sorted and
 * addresses lowercased.
 */
export function configHash(): `0x${string}` {
  const feeds = Object.keys(CONFIG.assetUsdFeed)
    .map((k) => k.toLowerCase())
    .sort()
    .map((k) => [k, CONFIG.assetUsdFeed[k].toLowerCase()]);
  return keccak256(
    stringToHex(
      JSON.stringify({
        version: CONFIG_VERSION,
        chainId: CHAIN_ID,
        registry: CONFIG.registry.toLowerCase(),
        defiInsurance: CONFIG.defiInsurance.toLowerCase(),
        boosterId: BOOSTER_ID.toString(),
        boosterBoostBps: BOOSTER_BOOST_BPS.toString(),
        assetUsdFeed: feeds,
        maxOracleStaleness: MAX_ORACLE_STALENESS.toString(),
        maxLogRange: MAX_LOG_RANGE.toString(),
        logResultCap: LOG_RESULT_CAP.toString(),
      })
    )
  );
}
