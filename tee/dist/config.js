// Settlement parameters. This file is baked into the enclave image, so the
// Nitro PCR measurement commits to every number here — changing any value
// produces a different, publicly visible enclave measurement. Version it.
export const CONFIG_VERSION = "1.0.0";
// ───────────────────────── mainnet config ─────────────────────────
// PLACEHOLDER ADDRESSES — fill at deployment, then freeze + publish.
export const CONFIG = {
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
