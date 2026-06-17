// Settlement parameters. This file is baked into the enclave image, so the
// Nitro PCR measurement commits to every number here — changing any value
// produces a different, publicly visible enclave measurement. Version it.

export const CONFIG_VERSION = "1.0.0";

export interface InsuredTokenConfig {
  /** ERC20 address of the insured token. */
  token: `0x${string}`;
  /** Human label for published tables. */
  label: string;
  /**
   * How to read the token's ratio vs its underlying at a historical block.
   * - erc4626: call convertToAssets(1e18) on the token itself.
   * - exchangeRate: call `call.to` with `call.data`, decode uint256.
   */
  ratioSource:
    | { kind: "erc4626" }
    | { kind: "exchangeRate"; to: `0x${string}`; data: `0x${string}` };
  /** Chainlink-style USD feed (8 decimals) for the UNDERLYING asset. */
  underlyingUsdFeed: `0x${string}`;
  /** Underlying decimals (ratio is underlying-per-1e18-token, this scales USD). */
  underlyingDecimals: number;
  /** θ: required ratio drop to validate an incident, in bps (1000 = 10%). */
  thetaBps: bigint;
  /** W: TWAP lookback before the incident block B, in seconds. */
  twapLookbackSec: bigint;
  /** δ: window after B in which the drop must appear, in seconds. */
  dropWindowSec: bigint;
  /** margin: claimant must have held since B − margin, in seconds. */
  holdingMarginSec: bigint;
  /** Max distance B may sit before the incident's first claim, in seconds. */
  maxLookbackSec: bigint;
}

export interface StakeAssetConfig {
  token: `0x${string}`;
  label: string;
  decimals: number;
  /** Chainlink-style USD feed (8 decimals). */
  usdFeed: `0x${string}`;
}

export interface Config {
  chainId: number;
  coverPool: `0x${string}`;
  usd8: `0x${string}`;
  /** USD8 history score: time-weighted balance lookback, seconds. */
  scoreLookbackSec: bigint;
  /** Blocks between ratio/balance samples (TWAP + min-balance scans). */
  sampleStepBlocks: bigint;
  /** Average seconds per block, for time→block conversion. */
  secondsPerBlock: bigint;
  insuredTokens: InsuredTokenConfig[];
  stakeAssets: StakeAssetConfig[];
}

// ───────────────────────── mainnet config ─────────────────────────
// PLACEHOLDER ADDRESSES — fill at deployment, then freeze + publish.

export const CONFIG: Config = {
  chainId: 1,
  coverPool: "0x0000000000000000000000000000000000000000",
  usd8: "0x0000000000000000000000000000000000000000",
  scoreLookbackSec: 90n * 86400n,
  sampleStepBlocks: 300n, // ~1h on mainnet
  secondsPerBlock: 12n,
  insuredTokens: [
    {
      token: "0x0000000000000000000000000000000000000000",
      label: "scrvUSD",
      ratioSource: { kind: "erc4626" },
      underlyingUsdFeed: "0x0000000000000000000000000000000000000000", // crvUSD/USD
      underlyingDecimals: 18,
      thetaBps: 1000n,
      twapLookbackSec: 7n * 86400n,
      dropWindowSec: 1n * 86400n,
      holdingMarginSec: 3n * 86400n,
      maxLookbackSec: 30n * 86400n,
    },
  ],
  stakeAssets: [
    {
      token: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      label: "USDC",
      decimals: 6,
      usdFeed: "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6", // Chainlink USDC/USD
    },
  ],
};
