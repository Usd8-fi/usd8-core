// Bootstrap pointer ONLY. All settlement parameters live on-chain (read
// per-incident via DefiInsurance.getIncidentConfig); this file just pins which
// chain + contracts to read. Everything else — coverage κ, windows, the
// value-ratio recipe, the price oracle, the scored-token set — is fetched from
// the contracts, so the settlement is reproducible from chain state alone by
// anyone (V1: open-source, admin-submitted; no TEE). Version it.

export const CONFIG_VERSION = "2.0.0";

export interface Config {
  chainId: number;
  /** CoverPool proxy — capital base: stake assets, balances, scored tokens, historyScoreSpent. */
  coverPool: `0x${string}`;
  /** DefiInsurance proxy — incidents, claims, per-incident settlement config. */
  defiInsurance: `0x${string}`;
}

// PLACEHOLDER — fill at deployment.
export const CONFIG: Config = {
  chainId: 1,
  coverPool: "0x0000000000000000000000000000000000000000",
  defiInsurance: "0x0000000000000000000000000000000000000000",
};
