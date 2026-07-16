#!/usr/bin/env node
import { writeFileSync } from "node:fs";

const count = Number(process.argv[2]);
const output = process.argv[3];
if (!Number.isSafeInteger(count) || count < 1 || count > 100_000 || !output) {
  console.error("usage: node generate-fixture.mjs <claims:1..100000> <output.json>");
  process.exit(2);
}

const WAD = 10n ** 18n;
const claims = [];
for (let index = 0; index < count; index++) {
  const id = BigInt(index + 1);
  const escrowWhole = 80n + BigInt((index * 17) % 121);
  const heldWhole = 50n + BigInt((index * 29) % 151);
  const gross = 1_000n + BigInt((index * 37) % 5_000);
  const spent = BigInt((index * 13) % 700);
  const requested = 200n + BigInt((index * 19) % 1_500);
  claims.push({
    claimId: id.toString(),
    user: `0x${id.toString(16).padStart(40, "0")}`,
    escrowAmount: (escrowWhole * WAD + BigInt(index % 97)).toString(),
    minHeld: (heldWhole * WAD + BigInt(index % 89)).toString(),
    grossEarnedScore: gross.toString(),
    spentScore: spent.toString(),
    scoreToSpend: requested.toString(),
    boosterAmount: "0",
    boosterHeld: "0",
  });
}

const fixture = {
  incidentId: "42",
  coverageBps: "8000",
  insuredDecimals: 18,
  twapRatio: WAD.toString(),
  underlyingUsd: WAD.toString(),
  maxCoverPoolPayoutBps: "10000",
  pools: [
    {
      balance: (BigInt(count) * 60n * WAD).toString(),
      assetUsd: WAD.toString(),
      assetDecimals: 18,
    },
  ],
  claims,
};
writeFileSync(output, `${JSON.stringify(fixture)}\n`);
console.log(JSON.stringify({ output, claims: count }));
