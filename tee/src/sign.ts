// EIP-712 over Settlement(incidentId, root, inputHash). The signing key is
// generated INSIDE the enclave (see keygen in main.ts) and never leaves; its
// public address is published in the Nitro attestation document so anyone can
// confirm CoverPool.teeSigner belongs to this open-source code.
//
// TODO(infra): persist the key sealed across enclave restarts. The key must
// survive a restart without ever existing in plaintext outside the enclave —
// seal it to the enclave's PCR measurement via AWS KMS (Encrypt under the
// attested image, Decrypt only on a matching attestation document). Until that
// lands, the key is passed in via SIGNER_KEY env, which is a TRUSTED-SETUP-ONLY
// stopgap and not safe for production.

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
