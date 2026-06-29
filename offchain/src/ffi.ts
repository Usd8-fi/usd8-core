// FFI bridge for the Foundry cross-language integration test
// (test/SettlementIntegration.t.sol). It runs the REAL settlement encoding —
// computeInputHash and settlementTree from compute.ts — so the test proves the
// off-chain root/proofs/inputHash match what the contracts produce/expect.
//
// Invoked as `node dist/ffi.js <cmd> <abiHexPayload> [arg]`. Input and output
// are ABI-encoded hex so Foundry can build/decode them with abi.encode/decode.

import { decodeAbiParameters, encodeAbiParameters } from "viem";
import { computeInputHash, settlementTree } from "./compute.js";
import type { InputEvent } from "./chain.js";

const [cmd, payload, arg] = process.argv.slice(2);
const hex = payload as `0x${string}`;

function emit(type: string, value: unknown): void {
  process.stdout.write(encodeAbiParameters([{ type }], [value]));
}

if (cmd === "inputhash") {
  // (uint256[] claimIds, address[] users, uint256[] escrows, uint256[] scoreToSpends,
  //  uint256[][] boosterIds, uint256[][] boosterAmounts) — registers in chain order.
  const [ids, users, escrows, spends, bIds, bAmts] = decodeAbiParameters(
    [{ type: "uint256[]" }, { type: "address[]" }, { type: "uint256[]" }, { type: "uint256[]" }, { type: "uint256[][]" }, { type: "uint256[][]" }],
    hex
  ) as [bigint[], `0x${string}`[], bigint[], bigint[], bigint[][], bigint[][]];
  const events: InputEvent[] = ids.map((id, i) => ({
    kind: "register",
    claimId: id,
    user: users[i],
    amount: escrows[i],
    scoreToSpend: spends[i],
    boosterIds: [...bIds[i]],
    boosterAmounts: [...bAmts[i]],
    blockNumber: 0n,
    logIndex: 0,
  }));
  emit("bytes32", computeInputHash(events));
} else if (cmd === "root" || cmd === "proof") {
  // (uint256 incidentId, uint256[] claimIds, address[] users, uint256[][] amounts, uint256[] scoreSpents)
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
