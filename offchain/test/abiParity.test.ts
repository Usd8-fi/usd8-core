import { describe, expect, it } from "vitest";
import { parseAbi } from "viem";
import { assertAbiSubset, assertFirstPartyAbiParity } from "../src/abiParity.js";

describe("ABI parity", () => {
  it("matches every handwritten first-party entry to current Foundry artifacts", async () => {
    await expect(assertFirstPartyAbiParity(new URL("../../out/", import.meta.url))).resolves.toEqual({ checked: 14 });
  });

  it("detects return-type and event-indexing drift that selectors alone miss", () => {
    const manualFunction = parseAbi(["function value() view returns (uint256)"]);
    const changedFunction = parseAbi(["function value() view returns (address)"]);
    expect(() => assertAbiSubset("Example", manualFunction, changedFunction)).toThrow(/outputs/);

    const manualEvent = parseAbi(["event Changed(address indexed user, uint256 value)"]);
    const changedEvent = parseAbi(["event Changed(address user, uint256 value)"]);
    expect(() => assertAbiSubset("Example", manualEvent, changedEvent)).toThrow(/indexed/);
  });
});
