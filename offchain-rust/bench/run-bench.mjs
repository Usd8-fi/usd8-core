#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = resolve(process.argv[2] ?? "");
const iterations = Number(process.argv[3] ?? "10");
const samples = Number(process.argv[4] ?? "7");
const warmupIterations = Number(process.argv[5] ?? "3");
if (
  !process.argv[2] ||
  !Number.isSafeInteger(iterations) || iterations < 2 ||
  !Number.isSafeInteger(samples) || samples < 3 ||
  !Number.isSafeInteger(warmupIterations) || warmupIterations < 1
) {
  console.error("usage: node run-bench.mjs <fixture.json> [iterations>=2] [samples>=3] [warmup>=1]");
  process.exit(2);
}
const rust = resolve(here, "../target/release/usd8-settlement");
const ts = resolve(here, "ts-kernel.mjs");
const options = { encoding: "utf8", maxBuffer: 512 * 1024 * 1024 };

function checked(command, args) {
  const run = spawnSync(command, args, options);
  if (run.status !== 0) throw new Error(`${command} failed (${run.status}): ${run.stderr}`);
  return JSON.parse(run.stdout);
}
function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}
function sample(command, args) {
  const ns = [];
  let result;
  for (let index = 0; index < samples; index++) {
    const output = checked(command, args);
    ns.push(output.elapsedNs / output.iterations);
    result = output.result;
  }
  return { ns, result };
}

const args = [fixture, String(iterations), String(warmupIterations)];
const tsRun = sample(process.execPath, [ts, ...args]);
const rustRun = sample(rust, args);
assert.deepStrictEqual(rustRun.result, tsRun.result);
const tsMedianNs = median(tsRun.ns);
const rustMedianNs = median(rustRun.ns);
console.log(JSON.stringify({
  fixture,
  claims: tsRun.result.rows.length,
  iterations,
  samples,
  warmupIterations,
  tsMedianNs,
  rustMedianNs,
  speedup: tsMedianNs / rustMedianNs,
  tsSamplesNs: tsRun.ns,
  rustSamplesNs: rustRun.ns,
  parity: true,
}));
