#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { performance } from "node:perf_hooks";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = resolve(process.argv[2] ?? "");
const samples = Number(process.argv[3] ?? "11");
if (!process.argv[2] || !Number.isSafeInteger(samples) || samples < 3) {
  console.error("usage: node cold-start.mjs <fixture.json> [samples>=3]");
  process.exit(2);
}
const rust = resolve(here, "../target/release/usd8-settlement");
const ts = resolve(here, "ts-kernel.mjs");
const options = { encoding: "utf8", maxBuffer: 512 * 1024 * 1024 };
function elapsed(command, args) {
  const started = performance.now();
  const run = spawnSync(command, args, options);
  const milliseconds = performance.now() - started;
  if (run.status !== 0) throw new Error(`${command} failed (${run.status}): ${run.stderr}`);
  return { milliseconds, result: JSON.parse(run.stdout) };
}
function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}
const tsMs = [];
const rustMs = [];
let tsResult;
let rustResult;
for (let index = 0; index < samples; index++) {
  const first = index % 2 === 0
    ? [[process.execPath, [ts, fixture, "1"], tsMs, "ts"], [rust, [fixture, "1"], rustMs, "rust"]]
    : [[rust, [fixture, "1"], rustMs, "rust"], [process.execPath, [ts, fixture, "1"], tsMs, "ts"]];
  for (const [command, args, values, language] of first) {
    const run = elapsed(command, args);
    values.push(run.milliseconds);
    if (language === "ts") tsResult = run.result; else rustResult = run.result;
  }
}
assert.deepStrictEqual(rustResult, tsResult);
const tsMedianMs = median(tsMs);
const rustMedianMs = median(rustMs);
console.log(JSON.stringify({
  fixture,
  claims: tsResult.rows.length,
  samples,
  tsMedianMs,
  rustMedianMs,
  speedup: tsMedianMs / rustMedianMs,
  tsSamplesMs: tsMs,
  rustSamplesMs: rustMs,
  parity: true,
}));
