// Bootstrap pointers ONLY: the contract addresses to read from. All settlement
// parameters live on-chain (read per-incident via DefiInsurance.getIncidentConfig)
// — coverage κ, windows, the value-conversion recipe, the price oracle, the
// scored-token set — so the settlement is reproducible from chain state alone by
// anyone. Version it.

export const CONFIG_VERSION = "2.0.0";

// USD8 deploys to Ethereum mainnet only. Locked here (not configurable) so the
// tool can never be pointed at a fork/testnet with colliding addresses; the
// RPC's chain id is checked against this at startup.
export const CHAIN_ID = 1;

export interface Config {
  /** CoverPool proxy — capital base: stake assets, balances, scored tokens, insuranceScoreSpent. */
  coverPool: `0x${string}`;
  /** DefiInsurance proxy — incidents, claims, per-incident settlement config. */
  defiInsurance: `0x${string}`;
}

// Filled in after CoverPool and DefiInsurance are deployed to mainnet — this
// package is published once the proxy addresses are known.
export const CONFIG: Config = {
  coverPool: "0x0000000000000000000000000000000000000000",
  defiInsurance: "0x0000000000000000000000000000000000000000",
};
