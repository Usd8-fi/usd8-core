// CLI entrypoint. Three modes, ONE codebase — the verifier any disputer runs
// is byte-identical to the signing enclave, which is the whole credibility
// argument.
//
//   settle <incidentId>   compute table + root, sign, print signature
//   verify <incidentId>   compute table + root, print — NO signing key needed
//   keygen                generate the in-enclave signing key (Nitro only)
//
// Inside AWS Nitro the RPC_URL points at the parent's vsock→TCP proxy. TLS
// terminates in here, so the parent relays bytes but cannot read or alter
// chain responses. Locally, RPC_URL is any archive node.
import { randomBytes } from "node:crypto";
import { makeClient, COVER_POOL_ABI, readInputEvents, firstClaimBlockOf, blockAtTimestamp, feedUsd1e18, } from "./chain.js";
import { CONFIG, CONFIG_VERSION } from "./config.js";
import { settle, computeInputHash } from "./compute.js";
import { signSettlement, signerAddress } from "./sign.js";
function rpc() {
    const u = process.env.RPC_URL;
    if (!u)
        throw new Error("RPC_URL not set");
    return u;
}
async function buildSettlement(incidentId) {
    const client = makeClient(rpc());
    const inc = (await client.readContract({
        address: CONFIG.coverPool,
        abi: COVER_POOL_ABI,
        functionName: "incidents",
        args: [incidentId],
    }));
    const insuredToken = inc[0];
    const windowEnd = inc[2];
    const onchainInputHash = inc[4];
    const cfg = CONFIG.insuredTokens.find((t) => t.token.toLowerCase() === insuredToken.toLowerCase());
    if (!cfg)
        throw new Error(`insured token ${insuredToken} not in config`);
    // Deterministic block anchors: window-end block found from its timestamp,
    // and the incident's first-claim block. Every read below pins one of these,
    // so the settlement is byte-identical no matter when it is (re)computed.
    const windowEndBlock = await blockAtTimestamp(client, windowEnd);
    const firstClaimBlock = await firstClaimBlockOf(client, incidentId, 1n, windowEndBlock);
    // Register/cancel event stream in true chain order → commitment.
    const events = await readInputEvents(client, incidentId, firstClaimBlock, windowEndBlock);
    // Self-check: our reconstructed stream MUST hash to the contract's value.
    const localHash = computeInputHash(events);
    if (localHash.toLowerCase() !== onchainInputHash.toLowerCase()) {
        throw new Error(`inputHash mismatch: local ${localHash} vs onchain ${onchainInputHash} — table reconstruction is wrong`);
    }
    // All config + pool reads pinned to windowEndBlock for reproducibility.
    const coverageBps = (await client.readContract({
        address: CONFIG.coverPool,
        abi: COVER_POOL_ABI,
        functionName: "coverageBps",
        args: [insuredToken],
        blockNumber: windowEndBlock,
    }));
    // Stake-asset list + balances + USD prices, in CoverPool order.
    const nAssets = (await client.readContract({
        address: CONFIG.coverPool,
        abi: COVER_POOL_ABI,
        functionName: "assetListLength",
        blockNumber: windowEndBlock,
    }));
    const assetOrder = [];
    const assetBalances = [];
    const assetUsd1e18 = [];
    const assetDecimals = [];
    for (let i = 0n; i < nAssets; i++) {
        const a = (await client.readContract({
            address: CONFIG.coverPool,
            abi: COVER_POOL_ABI,
            functionName: "assetList",
            args: [i],
            blockNumber: windowEndBlock,
        }));
        const bal = (await client.readContract({
            address: CONFIG.coverPool,
            abi: COVER_POOL_ABI,
            functionName: "totalAssets",
            args: [a],
            blockNumber: windowEndBlock,
        }));
        const sa = CONFIG.stakeAssets.find((s) => s.token.toLowerCase() === a.toLowerCase());
        if (!sa)
            throw new Error(`stake asset ${a} not in config`);
        assetOrder.push(a);
        assetBalances.push(bal);
        assetUsd1e18.push(await feedUsd1e18(client, sa.usdFeed, windowEndBlock));
        assetDecimals.push(sa.decimals);
    }
    return settle(client, incidentId, cfg, events, {
        firstClaimBlock,
        windowEndBlock,
        coverageBps,
        assetOrder,
        assetBalances,
        assetUsd1e18,
        assetDecimals,
    });
}
function printTable(s) {
    const out = {
        configVersion: CONFIG_VERSION,
        incidentId: s.incidentId.toString(),
        incidentBlock: s.incidentBlock.toString(),
        twapRatio: s.twapRatio.toString(),
        inputHash: s.inputHash,
        root: s.root,
        assetOrder: s.assetOrder,
        rows: s.rows.map((r) => ({
            claimId: r.claimId.toString(),
            user: r.user,
            escrowAmount: r.escrowAmount.toString(),
            eligibleAmount: r.eligibleAmount.toString(),
            lossUsd: r.lossUsd.toString(),
            score: r.score.toString(),
            payoutUsd: r.payoutUsd.toString(),
            amounts: r.amounts.map((a) => a.toString()),
        })),
    };
    console.log(JSON.stringify(out, null, 2));
}
async function main() {
    const [mode, arg] = process.argv.slice(2);
    if (mode === "keygen") {
        // In production this runs once inside the enclave; the key is held in
        // enclave memory only and the address is attested. NEVER print the key
        // outside a trusted setup.
        const pk = `0x${randomBytes(32).toString("hex")}`;
        console.error("signer address:", signerAddress(pk));
        if (process.env.PRINT_KEY === "1")
            console.log(pk);
        return;
    }
    if (mode !== "settle" && mode !== "verify") {
        console.error("usage: main <settle|verify|keygen> [incidentId]");
        process.exit(2);
    }
    const incidentId = BigInt(arg);
    const s = await buildSettlement(incidentId);
    printTable(s);
    if (mode === "settle") {
        const key = process.env.SIGNER_KEY;
        if (!key)
            throw new Error("SIGNER_KEY not set (enclave-held key)");
        const sig = await signSettlement(key, s.incidentId, s.root, s.inputHash);
        console.error("settlement signature:", sig);
        console.error("submit: settleIncident(", s.incidentId.toString(), ",", s.root, ",", sig, ")");
    }
}
main().catch((e) => {
    console.error("FATAL:", e.message);
    process.exit(1);
});
