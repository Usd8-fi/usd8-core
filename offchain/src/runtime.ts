export interface SpentReadMetrics {
  requestedUsers: number;
  uniqueUsers: number;
  readCount: number;
  concurrencyLimit: number;
  maxActive: number;
  elapsedMs: number;
}

export interface SpentReadResult {
  values: Map<string, bigint>;
  metrics: SpentReadMetrics;
}

export interface ScoreCheckpointOptions {
  path: string;
  integrityKey: Uint8Array;
}

export interface IncidentAnchorFields {
  insuredToken: `0x${string}`;
  windowEnd: bigint;
  referenceBlock: bigint;
  openBlock: bigint;
}

/** A latest-state lookup is used only to discover anchors. Those immutable
 * fields must then reproduce at the finalized head before any computation. */
export function assertFinalizedIncidentFields(
  provisional: IncidentAnchorFields,
  finalized: IncidentAnchorFields
): void {
  const fields = ["insuredToken", "windowEnd", "referenceBlock", "openBlock"] as const;
  for (const field of fields) {
    const left = provisional[field];
    const right = finalized[field];
    const equal =
      typeof left === "string" && typeof right === "string" ? left.toLowerCase() === right.toLowerCase() : left === right;
    if (!equal) {
      throw new Error(`${field} differs from finalized incident state: provisional ${left}, finalized ${right}`);
    }
  }
}

/** Parse checkpoint opt-in without ever logging or retaining the hex key. */
export function readScoreCheckpointOptions(
  env: Readonly<Record<string, string | undefined>>
): ScoreCheckpointOptions | undefined {
  const path = env.SCORE_CHECKPOINT_PATH?.trim();
  const encodedKey = env.SCORE_CHECKPOINT_HMAC_KEY?.trim();
  if (!path && !encodedKey) return undefined;
  if (!path) {
    throw new Error("checkpoint path is required in SCORE_CHECKPOINT_PATH when checkpoint HMAC key is configured");
  }
  if (!encodedKey) {
    throw new Error("checkpoint HMAC key is required in SCORE_CHECKPOINT_HMAC_KEY when checkpoint path is configured");
  }
  if (!/^[0-9a-fA-F]{64}$/.test(encodedKey)) {
    throw new Error("SCORE_CHECKPOINT_HMAC_KEY must contain exactly 64 hex characters");
  }
  return { path, integrityKey: Buffer.from(encodedKey, "hex") };
}

/** Read each claimant once with bounded concurrency. Returned keys are lowercase
 * addresses so checksum casing cannot create duplicate RPC work. */
export async function readSpentScores(
  users: readonly `0x${string}`[],
  concurrency: number,
  read: (user: `0x${string}`) => Promise<bigint>
): Promise<SpentReadResult> {
  if (!Number.isSafeInteger(concurrency) || concurrency <= 0) {
    throw new Error(`RPC concurrency must be a positive integer, got ${concurrency}`);
  }

  const unique = [...new Set(users.map((user) => user.toLowerCase()))] as `0x${string}`[];
  const results = new Array<bigint>(unique.length);
  let next = 0;
  let active = 0;
  let maxActive = 0;
  let readCount = 0;
  const started = performance.now();

  const worker = async () => {
    while (true) {
      const index = next++;
      if (index >= unique.length) return;
      active++;
      maxActive = Math.max(maxActive, active);
      readCount++;
      try {
        results[index] = await read(unique[index]);
      } finally {
        active--;
      }
    }
  };

  await Promise.all(Array.from({ length: Math.min(concurrency, unique.length) }, worker));
  const values = new Map<string, bigint>();
  for (let i = 0; i < unique.length; i++) values.set(unique[i], results[i]);

  return {
    values,
    metrics: {
      requestedUsers: users.length,
      uniqueUsers: unique.length,
      readCount,
      concurrencyLimit: concurrency,
      maxActive,
      elapsedMs: performance.now() - started,
    },
  };
}
