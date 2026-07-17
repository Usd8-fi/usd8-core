import { concatHex, hexToBytes, keccak256, stringToHex } from "viem";

export const PCR_BYTE_LENGTH = 48;
const PCR_HASH_DOMAIN = stringToHex("USD8_TEE_PCR0_2_V1");

function checkedPcr(name: string, value: `0x${string}`): `0x${string}` {
  let bytes: Uint8Array;
  try {
    bytes = hexToBytes(value);
  } catch {
    throw new Error(`${name} must be valid hex and ${PCR_BYTE_LENGTH} bytes`);
  }
  if (bytes.length !== PCR_BYTE_LENGTH) {
    throw new Error(`${name} must be ${PCR_BYTE_LENGTH} bytes, got ${bytes.length}`);
  }
  return value;
}

/** Canonical commitment shared with the Rust Nitro runtime and Registry. */
export function pcr0To2Hash(
  pcr0: `0x${string}`,
  pcr1: `0x${string}`,
  pcr2: `0x${string}`
): `0x${string}` {
  return keccak256(
    concatHex([
      PCR_HASH_DOMAIN,
      checkedPcr("PCR0", pcr0),
      checkedPcr("PCR1", pcr1),
      checkedPcr("PCR2", pcr2),
    ])
  );
}
