// Bootstrap pointers ONLY: the contract addresses to read from, plus the
// per-asset USD price feeds (the ONLY off-chain-configured settlement input —
// pool asset pricing is no longer on-chain). Everything else — coverage κ,
// windows, the conversion recipe, the underlying oracle, the scored-token set —
// lives on-chain and is read as of each incident's openBlock, so the settlement
// is reproducible from chain state alone. Version it.

import { keccak256, stringToHex } from "viem";

// 4.0.0 introduced capped geometric payout-root semantics.
// 4.1.0 added per-insured-token minimum claim enforcement and the matching ABI.
// 4.2.0 rejects future-dated, reversed, and superseded oracle rounds.
export const CONFIG_VERSION = "4.2.0";

// Max age (seconds) a Chainlink feed's answer may have, measured at the pinned
// block, before settlement treats it as stale and refuses to value against it
// (audit L-02). Conservative default (24h) covering long-heartbeat USD feeds; tune
// down per-feed if all configured oracles have tighter heartbeats. A stale feed
// throws → no root is produced → the incident voids (escrow recoverable) rather
// than settling on a frozen price the dispute window can't self-correct.
// Lives here (not chain.ts) because it is settlement POLICY — part of what
// {configHash} commits the signer to (M-04).
export const MAX_ORACLE_STALENESS = 86_400n;

// eth_getLogs completeness policy (M-01). A truncating provider that silently
// caps results makes the settler drop Transfer logs → wrong min-balance/score →
// a wrong signed root. There is NO universal cap: providers differ (e.g.
// Blockscout documents a 1,000-result eth_getLogs limit). So these MUST be set
// to values at or below the CONFIGURED provider's documented limits, and they are
// committed in {configHash} so which completeness policy produced a root is a
// public, disputable fact. LOG_RESULT_CAP: if a single-block range still returns
// ≥ this, the settler FAILS CLOSED (throws) rather than sign a possibly-truncated
// result — completeness can't be proven past one block. Defaults are conservative
// (Blockscout-compatible); raise only to a value proven ≤ the real provider cap.
export const MAX_LOG_RANGE = 1_000n; // blocks per eth_getLogs request
export const LOG_RESULT_CAP = 1_000; // results per request treated as "possibly truncated"

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

/** The USD feed for a pool asset, or throw if unconfigured. */
export function assetUsdFeedOf(asset: `0x${string}`): `0x${string}` {
  const feed = CONFIG.assetUsdFeed[asset.toLowerCase()];
  if (!feed) throw new Error(`no assetUsdFeed configured for pool asset ${asset} — add it to config.ts`);
  return feed;
}

/**
 * Commitment to every off-chain settlement input that isn't read from chain
 * state: the software/config version, chain, contract addresses, the pool-asset
 * feed map, and the staleness policy. Bound into the settlement signature
 * (M-04) and emitted by settleIncident, so which config produced a root is a
 * public, disputable fact — a root computed under a different feed map or
 * policy provably carries a different hash. Deterministic: keys sorted,
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
        assetUsdFeed: feeds,
        maxOracleStaleness: MAX_ORACLE_STALENESS.toString(),
        maxLogRange: MAX_LOG_RANGE.toString(),
        logResultCap: LOG_RESULT_CAP.toString(),
      })
    )
  );
}
