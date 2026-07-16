import { describe, expect, it } from "vitest";
import { keccak256, stringToHex } from "viem";
import {
  BOOSTER_BOOST_BPS,
  BOOSTER_ID,
  CHAIN_ID,
  CONFIG,
  CONFIG_VERSION,
  LOG_RESULT_CAP,
  MAX_LOG_RANGE,
  MAX_ORACLE_STALENESS,
  assertBootstrapConfig,
  configHash,
  type Config,
} from "../src/config.js";

const REGISTRY = "0x0000000000000000000000000000000000001000" as const;
const DEFI = "0x0000000000000000000000000000000000002000" as const;
const ASSET = "0x0000000000000000000000000000000000003000" as const;
const FEED = "0x0000000000000000000000000000000000004000" as const;

const valid = (): Config => ({
  registry: REGISTRY,
  defiInsurance: DEFI,
  assetUsdFeed: { [ASSET]: FEED },
});

describe("assertBootstrapConfig", () => {
  it("accepts distinct nonzero contracts and lowercase asset-feed keys", () => {
    expect(() => assertBootstrapConfig(valid())).not.toThrow();
  });

  it("rejects zero, duplicate, malformed, or noncanonical addresses", () => {
    expect(() => assertBootstrapConfig({ ...valid(), registry: "0x0000000000000000000000000000000000000000" })).toThrow(
      /registry.*zero/
    );
    expect(() => assertBootstrapConfig({ ...valid(), defiInsurance: REGISTRY })).toThrow(/must differ/);
    expect(() => assertBootstrapConfig({ ...valid(), registry: "0x1234" as `0x${string}` })).toThrow(/invalid registry/);
    expect(() =>
      assertBootstrapConfig({
        ...valid(),
        assetUsdFeed: { [ASSET.toUpperCase()]: FEED },
      })
    ).toThrow(/lowercase/);
  });
});

describe("configHash booster-policy commitment", () => {
  const hashWithPolicy = (boosterId: bigint, boosterBoostBps: bigint) => {
    const feeds = Object.keys(CONFIG.assetUsdFeed)
      .map((key) => key.toLowerCase())
      .sort()
      .map((key) => [key, CONFIG.assetUsdFeed[key].toLowerCase()]);
    return keccak256(
      stringToHex(
        JSON.stringify({
          version: CONFIG_VERSION,
          chainId: CHAIN_ID,
          registry: CONFIG.registry.toLowerCase(),
          defiInsurance: CONFIG.defiInsurance.toLowerCase(),
          boosterId: boosterId.toString(),
          boosterBoostBps: boosterBoostBps.toString(),
          assetUsdFeed: feeds,
          maxOracleStaleness: MAX_ORACLE_STALENESS.toString(),
          maxLogRange: MAX_LOG_RANGE.toString(),
          logResultCap: LOG_RESULT_CAP.toString(),
        })
      )
    );
  };

  it("commits to both booster policy constants", () => {
    const actual = configHash();
    expect(actual).toBe("0x2d7421cd81981dfbc0f63ad781d74a4e3b7b431d51887c3ccd72edcd66778f5e");
    expect(actual).toBe(hashWithPolicy(BOOSTER_ID, BOOSTER_BOOST_BPS));
    expect(actual).not.toBe(hashWithPolicy(BOOSTER_ID + 1n, BOOSTER_BOOST_BPS));
    expect(actual).not.toBe(hashWithPolicy(BOOSTER_ID, BOOSTER_BOOST_BPS + 1n));
  });
});
