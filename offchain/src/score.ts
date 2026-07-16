// Insurance-score sources. Raw RPC replay remains the canonical independent
// verifier while settlement math is decoupled from how a claimant's gross score
// is obtained. CheckpointScoreSource implements the same contract from an
// authenticated global Transfer index and must return the identical pre-spend,
// pre-booster gross score at the incident's pinned reference block.

import type { PublicClient } from "viem";
import { WAD, tokenBlockIntegral, type IncidentConfig } from "./chain.js";

const SCORE_SCALE = WAD;

export type GrossScoreProvider = (user: `0x${string}`) => Promise<bigint>;

export interface ScoreSource {
  grossScoreOf(user: `0x${string}`): Promise<bigint>;
}

/**
 * Raw-RPC implementation used by the Phase-1 compute/verify CLI. It preserves
 * the exact existing calculation: replay each scored token's Transfer history
 * over every append-only rate segment, normalize token decimals to 18, and sum
 * the resulting lifetime score at the pinned reference block.
 */
export class RpcScoreSource implements ScoreSource {
  constructor(
    private readonly client: PublicClient,
    private readonly cfg: IncidentConfig,
    private readonly asOfBlock: bigint
  ) {}

  grossScoreOf(user: `0x${string}`): Promise<bigint> {
    return earnedScoreOf(this.client, this.cfg, user, this.asOfBlock);
  }
}

/**
 * USD8 insurance score EARNED by `user` as of `asOfBlock`: the cumulative
 * token·block integral of every scored token, with each rate segment applied
 * only to its own interval. This is the raw/gross figure; spent score and the
 * incident booster are applied later by {settle}.
 */
export async function earnedScoreOf(
  client: PublicClient,
  cfg: IncidentConfig,
  user: `0x${string}`,
  asOfBlock: bigint
): Promise<bigint> {
  const scale = (integral: bigint, decimals: number) =>
    decimals <= 18 ? integral * 10n ** BigInt(18 - decimals) : integral / 10n ** BigInt(decimals - 18);

  let score = 0n;
  for (const st of cfg.scoredTokens) {
    // Integrate each rate SEGMENT over [fromBlock, nextFromBlock), with the last
    // segment capped at asOfBlock. Rate 0 means scoring is off for that interval.
    for (let i = 0; i < st.rates.length; i++) {
      const from = st.rates[i].fromBlock;
      const nextFrom = i + 1 < st.rates.length ? st.rates[i + 1].fromBlock : asOfBlock;
      const to = nextFrom < asOfBlock ? nextFrom : asOfBlock;
      if (st.rates[i].rate === 0n || from >= to) continue;

      const integral = await tokenBlockIntegral(client, st.token, user, from, to);
      score += scale(integral, st.decimals) * st.rates[i].rate;
    }
  }
  return score / SCORE_SCALE;
}
