// EIP-712 over Settlement(incidentId, root, inputHash). The signing key is
// generated INSIDE the enclave (see keygen in main.ts) and never leaves; its
// public address is published in the Nitro attestation document so anyone can
// confirm CoverPool.claimSigner belongs to this open-source code.

import { privateKeyToAccount } from "viem/accounts";
import { CONFIG } from "./config.js";

const DOMAIN = {
  name: "USD8 CoverPool",
  version: "1",
  chainId: CONFIG.chainId,
  verifyingContract: CONFIG.coverPool,
} as const;

const TYPES = {
  Settlement: [
    { name: "incidentId", type: "uint256" },
    { name: "root", type: "bytes32" },
    { name: "inputHash", type: "bytes32" },
  ],
} as const;

export async function signSettlement(
  privateKey: `0x${string}`,
  incidentId: bigint,
  root: `0x${string}`,
  inputHash: `0x${string}`
): Promise<`0x${string}`> {
  const account = privateKeyToAccount(privateKey);
  return account.signTypedData({
    domain: DOMAIN,
    types: TYPES,
    primaryType: "Settlement",
    message: { incidentId, root, inputHash },
  });
}

export function signerAddress(privateKey: `0x${string}`): `0x${string}` {
  return privateKeyToAccount(privateKey).address;
}
