// Bootstrap pointers ONLY: the contract addresses to read from, plus the
// per-asset USD price feeds (the ONLY off-chain-configured settlement input —
// pool asset pricing is no longer on-chain). Everything else — coverage κ,
// windows, the conversion recipe, the underlying oracle, the scored-token set —
// lives on-chain and is read as of each incident's openBlock, so the settlement
// is reproducible from chain state alone. Version it.

export const CONFIG_VERSION = "3.0.0";

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
