import { createHmac, timingSafeEqual } from "node:crypto";
import { mkdir, open as openFile, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import type { PublicClient } from "viem";
import {
  ERC20_TRANSFER,
  WAD,
  ZERO_ADDRESS,
  balanceOfAt,
  getLogsChunked,
  type IncidentConfig,
  type RatePoint,
  type ScoredToken,
} from "./chain.js";
import type { ScoreSource } from "./score.js";

const SCHEMA_VERSION = 1;
const ZERO_HASH = `0x${"0".repeat(64)}` as `0x${string}`;

type Address = `0x${string}`;

interface AccountState {
  balance: bigint;
  lastBlock: bigint;
  completedNumerator: bigint;
  activeSegmentFrom: bigint | null;
  activeIntegral: bigint;
}

interface TokenState {
  decimals: number;
  cursorBlock: bigint;
  cursorBlockHash: `0x${string}`;
  rates: RatePoint[];
  accounts: Map<string, AccountState>;
}

interface CheckpointState {
  chainId: number;
  tokens: Map<string, TokenState>;
}

interface PersistedAccount {
  balance: string;
  lastBlock: string;
  completedNumerator: string;
  activeSegmentFrom: string | null;
  activeIntegral: string;
}

interface PersistedToken {
  decimals: number;
  cursorBlock: string;
  cursorBlockHash: `0x${string}`;
  rates: { fromBlock: string; rate: string }[];
  accounts: Record<string, PersistedAccount>;
}

interface PersistedCheckpoint {
  schemaVersion: number;
  chainId: number;
  tokens: Record<string, PersistedToken>;
}

interface AuthenticatedCheckpoint extends PersistedCheckpoint {
  authentication: `0x${string}`;
}

export interface CheckpointScoreMetadata {
  kind: "checkpoint";
  path: string;
  asOfBlock: bigint;
  asOfBlockHash: `0x${string}`;
  indexedTransfers: number;
  indexedTokens: number;
}

function normalizeAddress(address: Address): Address {
  return address.toLowerCase() as Address;
}

function bigintField(value: unknown, field: string): bigint {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`invalid checkpoint bigint ${field}`);
  }
  return BigInt(value);
}

function emptyAccount(): AccountState {
  return { balance: 0n, lastBlock: 0n, completedNumerator: 0n, activeSegmentFrom: null, activeIntegral: 0n };
}

function scaleIntegral(integral: bigint, decimals: number): bigint {
  return decimals <= 18
    ? integral * 10n ** BigInt(18 - decimals)
    : integral / 10n ** BigInt(decimals - 18);
}

function rateFor(rates: readonly RatePoint[], fromBlock: bigint): bigint {
  const point = rates.find((rate) => rate.fromBlock === fromBlock);
  if (!point) throw new Error(`checkpoint active rate segment ${fromBlock} is absent from current rate history`);
  return point.rate;
}

function finalizeActiveSegment(state: AccountState, rates: readonly RatePoint[], decimals: number): void {
  if (state.activeSegmentFrom === null) return;
  state.completedNumerator +=
    scaleIntegral(state.activeIntegral, decimals) * rateFor(rates, state.activeSegmentFrom);
  state.activeSegmentFrom = null;
  state.activeIntegral = 0n;
}

/** Advance one account without rounding a rate segment at checkpoint boundaries.
 * Only actual Registry rate boundaries finalize `activeIntegral`. */
function accrueTo(state: AccountState, toBlock: bigint, rates: readonly RatePoint[], decimals: number): void {
  if (toBlock < state.lastBlock) throw new Error(`cannot move score account backward from ${state.lastBlock} to ${toBlock}`);
  if (toBlock === state.lastBlock) return;

  for (let i = 0; i < rates.length; i++) {
    const segmentFrom = rates[i].fromBlock;
    const nextFrom = i + 1 < rates.length ? rates[i + 1].fromBlock : null;
    const overlapFrom = state.lastBlock > segmentFrom ? state.lastBlock : segmentFrom;
    const overlapTo = nextFrom !== null && nextFrom < toBlock ? nextFrom : toBlock;
    if (overlapFrom >= overlapTo) continue;

    if (state.activeSegmentFrom !== segmentFrom) {
      if (state.activeSegmentFrom !== null) finalizeActiveSegment(state, rates, decimals);
      state.activeSegmentFrom = segmentFrom;
      state.activeIntegral = 0n;
    }
    state.activeIntegral += state.balance * (overlapTo - overlapFrom);

    if (nextFrom !== null && overlapTo === nextFrom && nextFrom <= toBlock) {
      finalizeActiveSegment(state, rates, decimals);
    }
  }
  state.lastBlock = toBlock;
}

function projectedNumerator(state: AccountState, toBlock: bigint, rates: readonly RatePoint[], decimals: number): bigint {
  const copy = { ...state };
  accrueTo(copy, toBlock, rates, decimals);
  let numerator = copy.completedNumerator;
  if (copy.activeSegmentFrom !== null) {
    numerator += scaleIntegral(copy.activeIntegral, decimals) * rateFor(rates, copy.activeSegmentFrom);
  }
  return numerator;
}

function assertRates(rates: readonly RatePoint[]): void {
  for (let i = 0; i < rates.length; i++) {
    if (rates[i].fromBlock < 0n || (i > 0 && rates[i - 1].fromBlock >= rates[i].fromBlock)) {
      throw new Error("scored-token rate history must be strictly ascending");
    }
  }
}

function contributesAt(scored: ScoredToken, asOfBlock: bigint): boolean {
  for (let i = 0; i < scored.rates.length; i++) {
    const from = scored.rates[i].fromBlock;
    const nextFrom = i + 1 < scored.rates.length ? scored.rates[i + 1].fromBlock : asOfBlock;
    const to = nextFrom < asOfBlock ? nextFrom : asOfBlock;
    if (scored.rates[i].rate !== 0n && from < to) return true;
  }
  return false;
}

function checkpointAuthentication(checkpoint: PersistedCheckpoint, integrityKey: Uint8Array): `0x${string}` {
  return `0x${createHmac("sha256", integrityKey).update(JSON.stringify(checkpoint)).digest("hex")}`;
}

function authenticateCheckpoint(value: unknown, integrityKey: Uint8Array): PersistedCheckpoint {
  const envelope = value as Partial<AuthenticatedCheckpoint>;
  const { authentication, ...checkpoint } = envelope;
  if (typeof authentication !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(authentication)) {
    throw new Error("checkpoint authentication failed: missing or malformed HMAC");
  }
  const expected = checkpointAuthentication(checkpoint as PersistedCheckpoint, integrityKey);
  const suppliedBytes = Buffer.from(authentication.slice(2), "hex");
  const expectedBytes = Buffer.from(expected.slice(2), "hex");
  if (suppliedBytes.length !== expectedBytes.length || !timingSafeEqual(suppliedBytes, expectedBytes)) {
    throw new Error("checkpoint authentication failed: HMAC mismatch");
  }
  return checkpoint as PersistedCheckpoint;
}

function parseCheckpoint(value: unknown): CheckpointState {
  const persisted = value as Partial<PersistedCheckpoint>;
  if (!persisted || persisted.schemaVersion !== SCHEMA_VERSION || !Number.isSafeInteger(persisted.chainId)) {
    throw new Error(`unsupported or invalid score checkpoint schema`);
  }
  if (!persisted.tokens || typeof persisted.tokens !== "object") throw new Error("invalid score checkpoint tokens");

  const tokens = new Map<string, TokenState>();
  for (const [token, rawToken] of Object.entries(persisted.tokens)) {
    if (!Number.isSafeInteger(rawToken.decimals) || rawToken.decimals < 0 || rawToken.decimals > 255) {
      throw new Error(`invalid checkpoint decimals for ${token}`);
    }
    const rates = rawToken.rates.map((rate, index) => ({
      fromBlock: bigintField(rate.fromBlock, `${token}.rates[${index}].fromBlock`),
      rate: bigintField(rate.rate, `${token}.rates[${index}].rate`),
    }));
    assertRates(rates);
    const accounts = new Map<string, AccountState>();
    for (const [account, rawAccount] of Object.entries(rawToken.accounts)) {
      accounts.set(account.toLowerCase(), {
        balance: bigintField(rawAccount.balance, `${token}.${account}.balance`),
        lastBlock: bigintField(rawAccount.lastBlock, `${token}.${account}.lastBlock`),
        completedNumerator: bigintField(rawAccount.completedNumerator, `${token}.${account}.completedNumerator`),
        activeSegmentFrom:
          rawAccount.activeSegmentFrom === null
            ? null
            : bigintField(rawAccount.activeSegmentFrom, `${token}.${account}.activeSegmentFrom`),
        activeIntegral: bigintField(rawAccount.activeIntegral, `${token}.${account}.activeIntegral`),
      });
    }
    tokens.set(token.toLowerCase(), {
      decimals: rawToken.decimals,
      cursorBlock: bigintField(rawToken.cursorBlock, `${token}.cursorBlock`),
      cursorBlockHash: rawToken.cursorBlockHash,
      rates,
      accounts,
    });
  }
  return { chainId: persisted.chainId!, tokens };
}

function serializeCheckpoint(state: CheckpointState): PersistedCheckpoint {
  const tokens: Record<string, PersistedToken> = {};
  for (const [token, tokenState] of [...state.tokens.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    const accounts: Record<string, PersistedAccount> = {};
    for (const [account, value] of [...tokenState.accounts.entries()].sort(([a], [b]) => a.localeCompare(b))) {
      accounts[account] = {
        balance: value.balance.toString(),
        lastBlock: value.lastBlock.toString(),
        completedNumerator: value.completedNumerator.toString(),
        activeSegmentFrom: value.activeSegmentFrom?.toString() ?? null,
        activeIntegral: value.activeIntegral.toString(),
      };
    }
    tokens[token] = {
      decimals: tokenState.decimals,
      cursorBlock: tokenState.cursorBlock.toString(),
      cursorBlockHash: tokenState.cursorBlockHash,
      rates: tokenState.rates.map((rate) => ({ fromBlock: rate.fromBlock.toString(), rate: rate.rate.toString() })),
      accounts,
    };
  }
  return { schemaVersion: SCHEMA_VERSION, chainId: state.chainId, tokens };
}

async function loadCheckpoint(path: string, chainId: number, integrityKey: Uint8Array): Promise<CheckpointState> {
  try {
    const raw = JSON.parse(await readFile(path, "utf8"));
    const parsed = parseCheckpoint(authenticateCheckpoint(raw, integrityKey));
    if (parsed.chainId !== chainId) throw new Error(`checkpoint chain ${parsed.chainId} does not match RPC chain ${chainId}`);
    return parsed;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { chainId, tokens: new Map() };
    throw error;
  }
}

async function saveCheckpoint(path: string, state: CheckpointState, integrityKey: Uint8Array): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
  const checkpoint = serializeCheckpoint(state);
  const envelope: AuthenticatedCheckpoint = {
    ...checkpoint,
    authentication: checkpointAuthentication(checkpoint, integrityKey),
  };
  await writeFile(temporary, `${JSON.stringify(envelope)}\n`, { encoding: "utf8", mode: 0o600 });
  await rename(temporary, path);
}

function validateStoredToken(stored: TokenState, current: ScoredToken): void {
  if (stored.decimals !== current.decimals) {
    throw new Error(`checkpoint decimals mismatch for ${current.token}: ${stored.decimals} != ${current.decimals}`);
  }
  if (current.rates.length < stored.rates.length) throw new Error(`checkpoint rate history shrank for ${current.token}`);
  for (let i = 0; i < stored.rates.length; i++) {
    if (
      stored.rates[i].fromBlock !== current.rates[i].fromBlock ||
      stored.rates[i].rate !== current.rates[i].rate
    ) {
      throw new Error(`checkpoint rate history mismatch for ${current.token} at index ${i}`);
    }
  }
  for (let i = stored.rates.length; i < current.rates.length; i++) {
    if (current.rates[i].fromBlock <= stored.cursorBlock) {
      throw new Error(`new rate for ${current.token} begins at/before checkpoint block ${stored.cursorBlock}`);
    }
  }
}

async function blockHash(client: PublicClient, blockNumber: bigint): Promise<`0x${string}`> {
  const block = await client.getBlock({ blockNumber });
  if (block.hash === null || block.number === null) throw new Error(`checkpoint block ${blockNumber} is missing hash`);
  return block.hash;
}

async function validateCheckpointHash(client: PublicClient, token: Address, state: TokenState): Promise<void> {
  if (state.cursorBlock === 0n) return;
  const currentHash = await blockHash(client, state.cursorBlock);
  if (currentHash.toLowerCase() !== state.cursorBlockHash.toLowerCase()) {
    throw new Error(
      `checkpoint block hash mismatch for ${token} at ${state.cursorBlock}: ${state.cursorBlockHash} != ${currentHash}`
    );
  }
}

function accountOf(token: TokenState, address: Address): AccountState {
  const key = normalizeAddress(address);
  let account = token.accounts.get(key);
  if (!account) {
    account = emptyAccount();
    token.accounts.set(key, account);
  }
  return account;
}

function applyTransferDelta(token: TokenState, rates: readonly RatePoint[], address: Address, block: bigint, delta: bigint): void {
  if (normalizeAddress(address) === ZERO_ADDRESS) return;
  const account = accountOf(token, address);
  accrueTo(account, block, rates, token.decimals);
  account.balance += delta;
  if (account.balance < 0n) {
    throw new Error(`Transfer index produced negative balance for ${address} at block ${block}`);
  }
}

async function advanceToken(
  client: PublicClient,
  scored: ScoredToken,
  token: TokenState,
  targetBlock: bigint
): Promise<number> {
  if (targetBlock < token.cursorBlock) {
    throw new Error(`checkpoint for ${scored.token} is ahead of requested block ${targetBlock}`);
  }
  if (targetBlock === token.cursorBlock) return 0;

  const fromBlock = token.cursorBlock + 1n;
  const logs = await getLogsChunked(client, { address: scored.token, event: ERC20_TRANSFER }, fromBlock, targetBlock);
  logs.sort((a, b) =>
    a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber)
  );
  for (const log of logs) {
    const from = log.args.from as Address;
    const to = log.args.to as Address;
    const value = log.args.value as bigint;
    if (typeof value !== "bigint" || !from || !to) throw new Error(`malformed Transfer log for ${scored.token}`);
    applyTransferDelta(token, scored.rates, from, log.blockNumber as bigint, -value);
    applyTransferDelta(token, scored.rates, to, log.blockNumber as bigint, value);
  }

  token.cursorBlock = targetBlock;
  token.cursorBlockHash = await blockHash(client, targetBlock);
  token.rates = scored.rates.map((rate) => ({ ...rate }));
  return logs.length;
}

/**
 * Persistent global Transfer index. The first run scans each scored token once;
 * later incidents advance from the finalized checkpoint instead of replaying
 * token history once per claimant. `grossScoreOf` verifies the indexed endpoint
 * balance against archive `balanceOf` and preserves the raw scorer's exact
 * per-rate-segment decimal normalization and final WAD division.
 */
export class CheckpointScoreSource implements ScoreSource {
  private constructor(
    private readonly client: PublicClient,
    private readonly cfg: IncidentConfig,
    private readonly asOfBlock: bigint,
    private readonly state: CheckpointState,
    readonly metadata: CheckpointScoreMetadata
  ) {}

  static async open(
    client: PublicClient,
    cfg: IncidentConfig,
    asOfBlock: bigint,
    checkpointPath: string,
    expectedChainId: number,
    integrityKey: Uint8Array
  ): Promise<CheckpointScoreSource> {
    if (integrityKey.byteLength < 32) throw new Error("score checkpoint integrity key must be at least 32 bytes");
    const path = resolve(checkpointPath);
    await mkdir(dirname(path), { recursive: true });
    const lockPath = `${path}.lock`;
    let lock;
    try {
      lock = await openFile(lockPath, "wx", 0o600);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "EEXIST") {
        throw new Error(`score checkpoint is locked by another process: ${lockPath}`);
      }
      throw error;
    }

    try {
      const actualChainId = await client.getChainId();
      if (actualChainId !== expectedChainId) {
        throw new Error(`checkpoint RPC chain ${actualChainId} does not match expected chain ${expectedChainId}`);
      }
      const state = await loadCheckpoint(path, expectedChainId, integrityKey);
      let indexedTransfers = 0;
      const activeScoredTokens = cfg.scoredTokens.filter((scored) => contributesAt(scored, asOfBlock));
      for (const scored of activeScoredTokens) {
        assertRates(scored.rates);
        const key = normalizeAddress(scored.token);
        let token = state.tokens.get(key);
        if (!token) {
          token = {
            decimals: scored.decimals,
            cursorBlock: 0n,
            cursorBlockHash: ZERO_HASH,
            rates: scored.rates.map((rate) => ({ ...rate })),
            accounts: new Map(),
          };
          state.tokens.set(key, token);
        } else {
          validateStoredToken(token, scored);
          await validateCheckpointHash(client, scored.token, token);
        }
        indexedTransfers += await advanceToken(client, scored, token, asOfBlock);
      }
      await saveCheckpoint(path, state, integrityKey);
      const asOfBlockHash = await blockHash(client, asOfBlock);
      return new CheckpointScoreSource(client, cfg, asOfBlock, state, {
        kind: "checkpoint",
        path,
        asOfBlock,
        asOfBlockHash,
        indexedTransfers,
        indexedTokens: activeScoredTokens.length,
      });
    } finally {
      await lock.close();
      await unlink(lockPath).catch(() => undefined);
    }
  }

  async grossScoreOf(user: Address): Promise<bigint> {
    let numerator = 0n;
    for (const scored of this.cfg.scoredTokens) {
      if (!contributesAt(scored, this.asOfBlock)) continue;
      const token = this.state.tokens.get(normalizeAddress(scored.token));
      if (!token) throw new Error(`score checkpoint missing token ${scored.token}`);
      const account = token.accounts.get(normalizeAddress(user)) ?? emptyAccount();
      const actualBalance = await balanceOfAt(this.client, scored.token, user, this.asOfBlock);
      if (actualBalance !== account.balance) {
        throw new Error(
          `unsupported token balance semantics for ${scored.token}: indexed balance ${account.balance}, ` +
            `balanceOf(${user}) at block ${this.asOfBlock} is ${actualBalance}`
        );
      }
      numerator += projectedNumerator(account, this.asOfBlock, scored.rates, scored.decimals);
    }
    return numerator / WAD;
  }
}
