#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = resolve(process.argv[2] ?? "");
if (!process.argv[2]) {
  console.error("usage: node compare.mjs <fixture.json>");
  process.exit(2);
}
const rust = resolve(here, "../target/release/usd8-settlement");
const ts = resolve(here, "ts-kernel.mjs");
const options = { encoding: "utf8", maxBuffer: 512 * 1024 * 1024 };

function checked(command, args) {
  const run = spawnSync(command, args, options);
  if (run.status !== 0) {
    throw new Error(`${command} failed (${run.status}): ${run.stderr}`);
  }
  return JSON.parse(run.stdout);
}

const tsOutput = checked(process.execPath, [ts, fixture, "1"]);
const rustOutput = checked(rust, [fixture, "1"]);
assert.deepStrictEqual(rustOutput, tsOutput);
const claims = JSON.parse(readFileSync(fixture, "utf8")).claims.length;
console.log(JSON.stringify({ parity: true, claims, root: rustOutput.root }));
