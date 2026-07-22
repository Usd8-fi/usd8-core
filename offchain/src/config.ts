import { isAddress, keccak256, stringToHex } from "viem";

export const CONFIG_VERSION = "5.0.0";
export const CHAIN_ID = 1;
export const BOOSTER_ID = 1n;
export const BOOSTER_BOOST_BPS = 100n;
export const MAX_LOG_RANGE = 1_000n;
export const LOG_RESULT_CAP = 1_000;
export const DEFAULT_RPC_TIMEOUT_MS = 30_000;
export const DEFAULT_RPC_CONCURRENCY = 24;

export interface Config {
  registry: `0x${string}`;
  defiInsurance: `0x${string}`;
  boosterId: bigint;
  boosterBoostBps: bigint;
  assetUsdFeed: Record<string, `0x${string}`>;
  maxOracleStaleness: bigint;
}

const ZERO = "0x0000000000000000000000000000000000000000" as const;

/** Runtime configuration is derived from Registry state at the incident openBlock. */
export const CONFIG: Config = {
  registry: ZERO,
  defiInsurance: ZERO,
  boosterId: BOOSTER_ID,
  boosterBoostBps: BOOSTER_BOOST_BPS,
  assetUsdFeed: {},
  maxOracleStaleness: 0n,
};

function assertAddress(value: string, label: string): asserts value is `0x${string}` {
  if (!isAddress(value)) throw new Error(`invalid ${label} address: ${value}`);
  if (value.toLowerCase() === ZERO) throw new Error(`${label} address is zero`);
}

/** Set the single external root before any RPC-derived configuration is loaded. */
export function setRegistryRoot(value: string): `0x${string}` {
  assertAddress(value, "registry");
  CONFIG.registry = value;
  return value;
}

/** Install and validate configuration reconstructed from historical on-chain state. */
export function setDerivedConfig(config: Config): void {
  assertAddress(config.registry, "registry");
  assertAddress(config.defiInsurance, "defiInsurance");
  if (config.registry.toLowerCase() === config.defiInsurance.toLowerCase()) {
    throw new Error("registry and defiInsurance addresses must differ");
  }
  if (config.boosterId !== BOOSTER_ID || config.boosterBoostBps !== BOOSTER_BOOST_BPS) {
    throw new Error(`unsupported booster policy: id=${config.boosterId}, boostBps=${config.boosterBoostBps}`);
  }
  if (config.maxOracleStaleness <= 0n) throw new Error("maxOracleStaleness must be positive");
  for (const [asset, feed] of Object.entries(config.assetUsdFeed)) {
    if (asset !== asset.toLowerCase()) throw new Error(`assetUsdFeed key must be lowercase: ${asset}`);
    assertAddress(asset, "pool asset");
    assertAddress(feed, `USD feed for ${asset}`);
  }
  Object.assign(CONFIG, config);
}

export function assertBootstrapConfig(config: Config = CONFIG): void {
  assertAddress(config.registry, "registry");
  assertAddress(config.defiInsurance, "defiInsurance");
  if (config.registry.toLowerCase() === config.defiInsurance.toLowerCase()) {
    throw new Error("registry and defiInsurance addresses must differ");
  }
  if (config.boosterId !== BOOSTER_ID || config.boosterBoostBps !== BOOSTER_BOOST_BPS) {
    throw new Error(`unsupported booster policy: id=${config.boosterId}, boostBps=${config.boosterBoostBps}`);
  }
  if (config.maxOracleStaleness <= 0n) throw new Error("maxOracleStaleness must be positive");
  for (const [asset, feed] of Object.entries(config.assetUsdFeed)) {
    if (asset !== asset.toLowerCase()) throw new Error(`assetUsdFeed key must be lowercase: ${asset}`);
    assertAddress(asset, "pool asset");
    assertAddress(feed, `USD feed for ${asset}`);
  }
}

export function assetUsdFeedOf(asset: `0x${string}`): `0x${string}` {
  const feed = CONFIG.assetUsdFeed[asset.toLowerCase()];
  if (!feed) throw new Error(`no on-chain assetUsdFeed configured for pool asset ${asset}`);
  return feed;
}

export function configHash(config: Config = CONFIG): `0x${string}` {
  const feeds = Object.keys(config.assetUsdFeed)
    .map((key) => key.toLowerCase())
    .sort()
    .map((key) => [key, config.assetUsdFeed[key].toLowerCase()]);
  return keccak256(
    stringToHex(
      JSON.stringify({
        version: CONFIG_VERSION,
        chainId: CHAIN_ID.toString(),
        registry: config.registry.toLowerCase(),
        defiInsurance: config.defiInsurance.toLowerCase(),
        boosterId: config.boosterId.toString(),
        boosterBoostBps: config.boosterBoostBps.toString(),
        assetUsdFeed: feeds,
        maxOracleStaleness: config.maxOracleStaleness.toString(),
        maxLogRange: MAX_LOG_RANGE.toString(),
        logResultCap: LOG_RESULT_CAP.toString(),
      })
    )
  );
}
