import { describe, expect, it } from "vitest";
import { assertFinalizedIncidentFields, readScoreCheckpointOptions, readSpentScores } from "../src/runtime.js";

const address = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as `0x${string}`;

describe("readSpentScores", () => {
  it("deduplicates users, preserves every value, and never exceeds the concurrency limit", async () => {
    let active = 0;
    let maxActive = 0;
    const users = [...Array.from({ length: 12 }, (_, i) => address(i + 1)), address(1), address(2).toUpperCase() as `0x${string}`];

    const result = await readSpentScores(users, 3, async (user) => {
      active++;
      maxActive = Math.max(maxActive, active);
      await new Promise((resolve) => setTimeout(resolve, 2));
      active--;
      return BigInt(`0x${user.slice(2)}`);
    });

    expect(result.values.size).toBe(12);
    expect(result.values.get(address(7))).toBe(7n);
    expect(result.metrics).toMatchObject({ requestedUsers: 14, uniqueUsers: 12, readCount: 12, concurrencyLimit: 3 });
    expect(result.metrics.maxActive).toBeLessThanOrEqual(3);
    expect(maxActive).toBeLessThanOrEqual(3);
  });

  it("rejects a non-positive or non-integer concurrency limit", async () => {
    await expect(readSpentScores([], 0, async () => 0n)).rejects.toThrow(/concurrency/);
    await expect(readSpentScores([], 1.5, async () => 0n)).rejects.toThrow(/concurrency/);
  });
});

describe("readScoreCheckpointOptions", () => {
  it("keeps raw RPC as default and requires path plus a 256-bit hex integrity key", () => {
    expect(readScoreCheckpointOptions({})).toBeUndefined();
    expect(() => readScoreCheckpointOptions({ SCORE_CHECKPOINT_PATH: "/tmp/index.json" })).toThrow(/HMAC key/);
    expect(() => readScoreCheckpointOptions({ SCORE_CHECKPOINT_HMAC_KEY: "11".repeat(32) })).toThrow(/path/);
    expect(() =>
      readScoreCheckpointOptions({ SCORE_CHECKPOINT_PATH: "/tmp/index.json", SCORE_CHECKPOINT_HMAC_KEY: "abcd" })
    ).toThrow(/64 hex/);

    const options = readScoreCheckpointOptions({
      SCORE_CHECKPOINT_PATH: "/tmp/index.json",
      SCORE_CHECKPOINT_HMAC_KEY: "11".repeat(32),
    });
    expect(options?.path).toBe("/tmp/index.json");
    expect(options?.integrityKey).toEqual(Buffer.alloc(32, 0x11));
  });
});

describe("assertFinalizedIncidentFields", () => {
  const fields = {
    insuredToken: address(1),
    windowEnd: 100n,
    referenceBlock: 80n,
    openBlock: 90n,
  };

  it("rejects provisional incident anchors that disagree with finalized state", () => {
    expect(() => assertFinalizedIncidentFields(fields, { ...fields })).not.toThrow();
    expect(() => assertFinalizedIncidentFields(fields, { ...fields, referenceBlock: 81n })).toThrow(
      /referenceBlock.*finalized/
    );
  });
});
