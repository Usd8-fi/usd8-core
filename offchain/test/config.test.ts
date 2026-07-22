import { describe, expect, it } from "vitest";
import {
  BOOSTER_BOOST_BPS,
  BOOSTER_ID,
  CHAIN_ID,
  CONFIG_VERSION,
  LOG_RESULT_CAP,
  MAX_LOG_RANGE,
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
  boosterId: BOOSTER_ID,
  boosterBoostBps: BOOSTER_BOOST_BPS,
  assetUsdFeed: { [ASSET]: FEED },
  maxOracleStaleness: 129_600n,
});

describe("Registry-derived configuration", () => {
  it("accepts complete historical on-chain state", () => {
    expect(() => assertBootstrapConfig(valid())).not.toThrow();
    expect(CONFIG_VERSION).toBe("5.0.0");
    expect(CHAIN_ID).toBe(1);
    expect(MAX_LOG_RANGE).toBe(1_000n);
    expect(LOG_RESULT_CAP).toBe(1_000);
  });

  it("rejects invalid topology or policy", () => {
    expect(() => assertBootstrapConfig({ ...valid(), registry: "0x0000000000000000000000000000000000000000" })).toThrow(
      /registry.*zero/
    );
    expect(() => assertBootstrapConfig({ ...valid(), defiInsurance: REGISTRY })).toThrow(/must differ/);
    expect(() => assertBootstrapConfig({ ...valid(), boosterId: 2n })).toThrow(/unsupported booster/);
    expect(() => assertBootstrapConfig({ ...valid(), maxOracleStaleness: 0n })).toThrow(/positive/);
    expect(() =>
      assertBootstrapConfig({ ...valid(), assetUsdFeed: { [ASSET.toUpperCase()]: FEED } })
    ).toThrow(/lowercase/);
  });

  it("matches the Rust v5 derived-config commitment vector", () => {
    const vector: Config = {
      ...valid(),
      assetUsdFeed: {
        [ASSET]: FEED,
        "0x0000000000000000000000000000000000005000": "0x0000000000000000000000000000000000006000",
      },
    };
    expect(configHash(vector)).toBe("0xf4c864ca629a28b3755712eeec7a8a3c80be0bf5f1e6d8d8abaab4eb84674449");
  });

  it("commits derived state and baked RPC limits deterministically", () => {
    const base = valid();
    const hash = configHash(base);
    expect(hash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(configHash({ ...base, boosterBoostBps: 101n })).not.toBe(hash);
    expect(configHash({ ...base, maxOracleStaleness: 172_800n })).not.toBe(hash);
    expect(configHash({ ...base, assetUsdFeed: { [ASSET]: "0x0000000000000000000000000000000000005000" } })).not.toBe(hash);
  });
});
