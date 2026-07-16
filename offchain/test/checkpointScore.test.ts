import { afterEach, describe, expect, it } from "vitest";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CheckpointScoreSource } from "../src/checkpointScore.js";
import { earnedScoreOf } from "../src/score.js";
import type { IncidentConfig } from "../src/chain.js";

const WAD = 10n ** 18n;
const ZERO = "0x0000000000000000000000000000000000000000" as const;
const TOKEN = "0x0000000000000000000000000000000000001000" as const;
const ALICE = "0x000000000000000000000000000000000000a11c" as const;
const BOB = "0x000000000000000000000000000000000000b0b0" as const;
const ORACLE = "0x0000000000000000000000000000000000000001" as const;
const INTEGRITY_KEY = Buffer.alloc(32, 7);
const dirs: string[] = [];

const hashOf = (n: bigint) => `0x${n.toString(16).padStart(64, "0")}` as `0x${string}`;

type Transfer = {
  blockNumber: bigint;
  logIndex: number;
  args: { from: `0x${string}`; to: `0x${string}`; value: bigint };
};

function scoreConfig(decimals: number, rates: { fromBlock: bigint; rate: bigint }[]): IncidentConfig {
  return {
    coverageBps: 8_000n,
    underlyingPriceOracle: ORACLE,
    underlyingConversionAddress: ZERO,
    underlyingConversionCallData: "0x",
    params: { twapLookbackBlocks: 1n, holdingMarginBlocks: 1n, sampleStepBlocks: 1n },
    scoredTokens: [{ token: TOKEN, decimals, rates }],
  };
}

function fakeClient(transfers: Transfer[]) {
  const hashOverrides = new Map<bigint, `0x${string}`>();
  let globalLogQueries = 0;
  const balanceAt = (who: string, block: bigint) => {
    let balance = 0n;
    for (const transfer of transfers) {
      if (transfer.blockNumber > block) continue;
      if (transfer.args.from.toLowerCase() === who.toLowerCase()) balance -= transfer.args.value;
      if (transfer.args.to.toLowerCase() === who.toLowerCase()) balance += transfer.args.value;
    }
    return balance;
  };
  const client = {
    getChainId: async () => 1,
    getBlock: async ({ blockNumber }: { blockNumber: bigint }) => ({
      number: blockNumber,
      timestamp: blockNumber * 12n,
      hash: hashOverrides.get(blockNumber) ?? hashOf(blockNumber),
    }),
    getLogs: async ({ fromBlock, toBlock, args }: { fromBlock: bigint; toBlock: bigint; args?: { from?: string; to?: string } }) => {
      if (!args) globalLogQueries++;
      return transfers.filter((transfer) => {
        if (transfer.blockNumber < fromBlock || transfer.blockNumber > toBlock) return false;
        if (args?.from && transfer.args.from.toLowerCase() !== args.from.toLowerCase()) return false;
        if (args?.to && transfer.args.to.toLowerCase() !== args.to.toLowerCase()) return false;
        return true;
      });
    },
    readContract: async ({ functionName, args, blockNumber }: { functionName: string; args: [string]; blockNumber: bigint }) => {
      if (functionName !== "balanceOf") throw new Error(`unexpected read ${functionName}`);
      return balanceAt(args[0], blockNumber);
    },
  } as any;
  return {
    client,
    hashOverrides,
    globalLogQueries: () => globalLogQueries,
  };
}

async function checkpointPath() {
  const dir = await mkdtemp(join(tmpdir(), "usd8-score-checkpoint-"));
  dirs.push(dir);
  return join(dir, "score-index.json");
}

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

describe("CheckpointScoreSource", () => {
  it("matches raw replay while advancing one global token scan across rate changes", async () => {
    const transfers: Transfer[] = [
      { blockNumber: 1n, logIndex: 0, args: { from: ZERO, to: ALICE, value: 100n } },
      { blockNumber: 4n, logIndex: 0, args: { from: ALICE, to: BOB, value: 40n } },
      { blockNumber: 8n, logIndex: 0, args: { from: BOB, to: ALICE, value: 10n } },
    ];
    const cfg = scoreConfig(18, [
      { fromBlock: 2n, rate: 2n * WAD },
      { fromBlock: 6n, rate: WAD },
    ]);
    const fake = fakeClient(transfers);
    const path = await checkpointPath();

    const first = await CheckpointScoreSource.open(fake.client, cfg, 6n, path, 1, INTEGRITY_KEY);
    expect(await first.grossScoreOf(ALICE)).toBe(await earnedScoreOf(fake.client, cfg, ALICE, 6n));
    expect(await first.grossScoreOf(BOB)).toBe(await earnedScoreOf(fake.client, cfg, BOB, 6n));

    const second = await CheckpointScoreSource.open(fake.client, cfg, 10n, path, 1, INTEGRITY_KEY);
    expect(await second.grossScoreOf(ALICE)).toBe(900n);
    expect(await second.grossScoreOf(BOB)).toBe(300n);
    expect(await second.grossScoreOf(ALICE)).toBe(await earnedScoreOf(fake.client, cfg, ALICE, 10n));
    expect(fake.globalLogQueries()).toBe(2); // [1,6] once, then [7,10] once — not once per user

    await CheckpointScoreSource.open(fake.client, cfg, 10n, path, 1, INTEGRITY_KEY);
    expect(fake.globalLogQueries()).toBe(2); // reload at same finalized block reuses persisted state
  });

  it("divides by WAD once after summing every token numerator", async () => {
    const transfers: Transfer[] = [
      { blockNumber: 1n, logIndex: 0, args: { from: ZERO, to: ALICE, value: 1n } },
    ];
    const one = scoreConfig(18, [{ fromBlock: 2n, rate: WAD / 2n }]).scoredTokens[0];
    const cfg = { ...scoreConfig(18, []), scoredTokens: [one, { ...one }] };
    const fake = fakeClient(transfers);
    const source = await CheckpointScoreSource.open(fake.client, cfg, 3n, await checkpointPath(), 1, INTEGRITY_KEY);

    expect(await source.grossScoreOf(ALICE)).toBe(1n); // two half-WAD numerators; per-token flooring would return zero
    expect(await source.grossScoreOf(ALICE)).toBe(await earnedScoreOf(fake.client, cfg, ALICE, 3n));
  });

  it("does not index tokens whose rates contribute nothing at the pinned block", async () => {
    const transfers: Transfer[] = [
      { blockNumber: 1n, logIndex: 0, args: { from: ZERO, to: ALICE, value: 100n } },
    ];
    const cfg = scoreConfig(18, [
      { fromBlock: 2n, rate: 0n },
      { fromBlock: 20n, rate: WAD },
    ]);
    const fake = fakeClient(transfers);
    const source = await CheckpointScoreSource.open(
      fake.client,
      cfg,
      10n,
      await checkpointPath(),
      1,
      INTEGRITY_KEY
    );

    expect(await source.grossScoreOf(ALICE)).toBe(await earnedScoreOf(fake.client, cfg, ALICE, 10n));
    expect(fake.globalLogQueries()).toBe(0);
    expect(source.metadata.indexedTokens).toBe(0);
  });

  it("does not round twice when a checkpoint splits a >18-decimal rate segment", async () => {
    const transfers: Transfer[] = [
      { blockNumber: 1n, logIndex: 0, args: { from: ZERO, to: ALICE, value: 15n } },
    ];
    const cfg = scoreConfig(19, [{ fromBlock: 2n, rate: WAD }]);
    const fake = fakeClient(transfers);
    const path = await checkpointPath();

    await CheckpointScoreSource.open(fake.client, cfg, 5n, path, 1, INTEGRITY_KEY);
    const source = await CheckpointScoreSource.open(fake.client, cfg, 10n, path, 1, INTEGRITY_KEY);

    expect(await source.grossScoreOf(ALICE)).toBe(12n); // floor((15 × 8 blocks) / 10), not floor(45/10)+floor(75/10)
    expect(await source.grossScoreOf(ALICE)).toBe(await earnedScoreOf(fake.client, cfg, ALICE, 10n));
  });

  it("matches raw scoring across transfer, rate-boundary, checkpoint, and decimal matrices", async () => {
    for (const decimals of [6, 18, 19, 24]) {
      const unit = 10n ** BigInt(Math.max(0, decimals - 18));
      const transfers: Transfer[] = [
        { blockNumber: 1n, logIndex: 0, args: { from: ZERO, to: ALICE, value: 1_000n * unit } },
        { blockNumber: 1n, logIndex: 1, args: { from: ZERO, to: BOB, value: 600n * unit } },
        { blockNumber: 4n, logIndex: 0, args: { from: ALICE, to: BOB, value: 125n * unit } },
        { blockNumber: 9n, logIndex: 0, args: { from: BOB, to: ALICE, value: 75n * unit } },
        { blockNumber: 13n, logIndex: 0, args: { from: ALICE, to: BOB, value: 20n * unit } },
      ];
      const cfg = scoreConfig(decimals, [
        { fromBlock: 2n, rate: WAD / 3n },
        { fromBlock: 7n, rate: 2n * WAD },
        { fromBlock: 12n, rate: WAD / 7n },
      ]);
      const fake = fakeClient(transfers);
      const path = await checkpointPath();
      await CheckpointScoreSource.open(fake.client, cfg, 8n, path, 1, INTEGRITY_KEY);
      const source = await CheckpointScoreSource.open(fake.client, cfg, 16n, path, 1, INTEGRITY_KEY);

      expect(await source.grossScoreOf(ALICE), `Alice decimals=${decimals}`).toBe(
        await earnedScoreOf(fake.client, cfg, ALICE, 16n)
      );
      expect(await source.grossScoreOf(BOB), `Bob decimals=${decimals}`).toBe(
        await earnedScoreOf(fake.client, cfg, BOB, 16n)
      );
    }
  });

  it("fails closed when the persisted checkpoint block hash changed", async () => {
    const transfers: Transfer[] = [
      { blockNumber: 1n, logIndex: 0, args: { from: ZERO, to: ALICE, value: 100n } },
    ];
    const cfg = scoreConfig(18, [{ fromBlock: 2n, rate: WAD }]);
    const fake = fakeClient(transfers);
    const path = await checkpointPath();
    await CheckpointScoreSource.open(fake.client, cfg, 6n, path, 1, INTEGRITY_KEY);
    fake.hashOverrides.set(6n, `0x${"ff".repeat(32)}`);

    await expect(CheckpointScoreSource.open(fake.client, cfg, 10n, path, 1, INTEGRITY_KEY)).rejects.toThrow(/checkpoint block hash mismatch/);
  });

  it("rejects a locally tampered checkpoint before using any score state", async () => {
    const transfers: Transfer[] = [
      { blockNumber: 1n, logIndex: 0, args: { from: ZERO, to: ALICE, value: 100n } },
    ];
    const cfg = scoreConfig(18, [{ fromBlock: 2n, rate: WAD }]);
    const fake = fakeClient(transfers);
    const path = await checkpointPath();
    await CheckpointScoreSource.open(fake.client, cfg, 6n, path, 1, INTEGRITY_KEY);

    const persisted = JSON.parse(await readFile(path, "utf8"));
    persisted.tokens[TOKEN].accounts[ALICE].completedNumerator = "999999999999999999999999";
    await writeFile(path, JSON.stringify(persisted));

    await expect(CheckpointScoreSource.open(fake.client, cfg, 6n, path, 1, INTEGRITY_KEY)).rejects.toThrow(
      /checkpoint authentication failed/
    );
  });
});
