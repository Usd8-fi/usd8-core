// FFI bridge for the Foundry cross-language integration test
// (test/SettlementIntegration.t.sol). It runs the REAL settlement encoding —
// settlementTree from compute.ts — so the test proves the off-chain
// root/proofs match what the contracts produce/expect.
//
// Invoked as `node dist/ffi.js <cmd> <abiHexPayload> [arg]`. Both commands take
// the SAME payload, abi.encode'd by Foundry:
//
//   (uint256 incidentId, uint256[] claimIds, address[] users,
//    uint256[][] amounts, uint256[] scoreSpents)
//
// where amounts[i] aligns to the registered pool list. Output is abi-encoded
// hex so Foundry can decode it with abi.decode. Commands:
//
//   root              → prints abi.encode(bytes32) of the merkle root
//                       (Foundry: abi.decode(out, (bytes32))).
//   proof <claimId>   → prints abi.encode(bytes32[]) of that claim's merkle
//                       proof (Foundry: abi.decode(out, (bytes32[]))).

import { decodeAbiParameters, encodeAbiParameters } from "viem";
import { settlementTree } from "./compute.js";

const [cmd, payload, arg] = process.argv.slice(2);
const hex = payload as `0x${string}`;

function emit(type: string, value: unknown): void {
  process.stdout.write(encodeAbiParameters([{ type }], [value]));
}

if (cmd === "root" || cmd === "proof") {
  const [incidentId, ids, users, amounts, spents] = decodeAbiParameters(
    [{ type: "uint256" }, { type: "uint256[]" }, { type: "address[]" }, { type: "uint256[][]" }, { type: "uint256[]" }],
    hex
  ) as [bigint, bigint[], `0x${string}`[], bigint[][], bigint[]];
  const rows = ids.map((id, i) => ({ claimId: id, user: users[i], amounts: [...amounts[i]], scoreSpent: spents[i] }));
  const tree = settlementTree(incidentId, rows);
  if (cmd === "root") {
    emit("bytes32", tree.root);
  } else {
    const target = BigInt(arg);
    let proof: `0x${string}`[] = [];
    for (const [i, v] of tree.entries()) if ((v as unknown[])[1] === target) proof = tree.getProof(i) as `0x${string}`[];
    emit("bytes32[]", proof);
  }
} else {
  process.stderr.write(`unknown ffi command: ${cmd}\n`);
  process.exit(1);
}
