// FFI bridge for the Foundry cross-language integration test
// (test/SettlementIntegration.t.sol). It runs the REAL settlement encoding —
// settlementTree from compute.ts — so the test proves the off-chain
// root/proofs match what the contracts produce/expect.
//
// Invoked as `node dist/ffi.js <cmd> <abiHexPayload> [arg]`. Both commands take
// the SAME payload, abi.encode'd by Foundry:
//
//   (uint256 incidentId, uint256[] claimIds, address[] users,
//    uint256[][] amounts, uint256[] scoreSpents, uint256[] eligibles)
//
// where amounts[i] aligns to the registered pool list. Output is abi-encoded
// hex so Foundry can decode it with abi.decode. Commands:
//
//   root              → prints abi.encode(bytes32) of the merkle root
//                       (Foundry: abi.decode(out, (bytes32))).
//   proof <claimId>   → prints abi.encode(bytes32[]) of that claim's merkle
//                       proof (Foundry: abi.decode(out, (bytes32[]))).
//
// The `digest` command uses a DIFFERENT payload — the full EIP-712 settlement
// digest inputs — so the golden-vector test can prove the viem digest equals the
// contract's _hashTypedDataV4 byte-for-byte (H-01):
//
//   digest            → payload abi.encode(uint256 chainId, address verifyingContract,
//                       uint256 incidentId, bytes32 root, uint256 unresolved,
//                       uint256[] poolPayouts, address[] poolAddrs, bytes32 claimSet,
//                       bytes32 configHash, bytes32 settlementInputHash); prints
//                       abi.encode(bytes32) of the EIP-712 settlement digest.
//   claimset          → payload abi.encode(uint8[] kinds (0=register, 1=cancel),
//                       uint256[] claimIds, address[] users, uint256[] escrows,
//                       uint256[] scoreToSpends, uint256[] boosterAmounts), aligned
//                       arrays in chain order; prints abi.encode(bytes32) of the
//                       replayed claim-set accumulator (must equal the contract's
//                       Incident.claimSetHash — M-06).

import { decodeAbiParameters, encodeAbiParameters, hashTypedData } from "viem";
import { claimSetHashOf, settlementTree, settlementTypedData } from "./compute.js";
import type { InputEvent } from "./chain.js";

const [cmd, payload, arg] = process.argv.slice(2);
const hex = payload as `0x${string}`;

function emit(type: string, value: unknown): void {
  process.stdout.write(encodeAbiParameters([{ type }], [value]));
}

if (cmd === "root" || cmd === "proof") {
  const [incidentId, ids, users, amounts, spents, eligibles] = decodeAbiParameters(
    [
      { type: "uint256" },
      { type: "uint256[]" },
      { type: "address[]" },
      { type: "uint256[][]" },
      { type: "uint256[]" },
      { type: "uint256[]" },
    ],
    hex
  ) as [bigint, bigint[], `0x${string}`[], bigint[][], bigint[], bigint[]];
  const rows = ids.map((id, i) => ({
    claimId: id,
    user: users[i],
    amounts: [...amounts[i]],
    scoreSpent: spents[i],
    eligibleAmount: eligibles[i],
  }));
  const tree = settlementTree(incidentId, rows);
  if (cmd === "root") {
    emit("bytes32", tree.root);
  } else {
    const target = BigInt(arg);
    let proof: `0x${string}`[] = [];
    for (const [i, v] of tree.entries()) if ((v as unknown[])[1] === target) proof = tree.getProof(i) as `0x${string}`[];
    emit("bytes32[]", proof);
  }
} else if (cmd === "digest") {
  const [
    chainId,
    verifyingContract,
    incidentId,
    root,
    unresolved,
    poolPayouts,
    poolAddrs,
    claimSet,
    configHash,
    settlementInputHash,
  ] = decodeAbiParameters(
    [
      { type: "uint256" },
      { type: "address" },
      { type: "uint256" },
      { type: "bytes32" },
      { type: "uint256" },
      { type: "uint256[]" },
      { type: "address[]" },
      { type: "bytes32" },
      { type: "bytes32" },
      { type: "bytes32" },
    ],
    hex
  ) as [
    bigint,
    `0x${string}`,
    bigint,
    `0x${string}`,
    bigint,
    bigint[],
    `0x${string}`[],
    `0x${string}`,
    `0x${string}`,
    `0x${string}`,
  ];
  const typedData = settlementTypedData(
    Number(chainId),
    verifyingContract,
    { incidentId, root, poolPayouts: [...poolPayouts], poolAddrs: [...poolAddrs] },
    unresolved,
    claimSet,
    configHash,
    settlementInputHash
  );
  emit("bytes32", hashTypedData(typedData));
} else if (cmd === "claimset") {
  const [kinds, claimIds, users, escrows, scoreToSpends, boosterAmounts] = decodeAbiParameters(
    [
      { type: "uint8[]" },
      { type: "uint256[]" },
      { type: "address[]" },
      { type: "uint256[]" },
      { type: "uint256[]" },
      { type: "uint256[]" },
    ],
    hex
  ) as [number[], bigint[], `0x${string}`[], bigint[], bigint[], bigint[]];
  const events: InputEvent[] = kinds.map((k, i) => ({
    kind: k === 0 ? "register" : "cancel",
    claimId: claimIds[i],
    user: users[i],
    amount: escrows[i],
    scoreToSpend: scoreToSpends[i],
    boosterAmount: boosterAmounts[i],
    blockNumber: BigInt(i),
    logIndex: i,
  }));
  emit("bytes32", claimSetHashOf(events));
} else {
  process.stderr.write(`unknown ffi command: ${cmd}\n`);
  process.exit(1);
}
