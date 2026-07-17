import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { pcr0To2Hash } from "../src/tee.js";

type Vector = {
  name: string;
  pcr0: `0x${string}`;
  pcr1: `0x${string}`;
  pcr2: `0x${string}`;
  expectedHash: `0x${string}`;
};

const fixture = JSON.parse(
  readFileSync(new URL("../../offchain-rust/fixtures/tee-pcr-vectors.json", import.meta.url), "utf8")
) as { vectors: Vector[] };

describe("Nitro PCR0-2 commitment", () => {
  it.each(fixture.vectors)("matches shared vector $name", ({ pcr0, pcr1, pcr2, expectedHash }) => {
    expect(pcr0To2Hash(pcr0, pcr1, pcr2)).toBe(expectedHash);
  });

  it("rejects malformed or non-SHA384 measurements", () => {
    const good = `0x${"00".repeat(48)}` as const;
    expect(() => pcr0To2Hash("0x00", good, good)).toThrow(/PCR0.*48 bytes/);
    expect(() => pcr0To2Hash("not-hex" as `0x${string}`, good, good)).toThrow(/PCR0/);
  });
});
