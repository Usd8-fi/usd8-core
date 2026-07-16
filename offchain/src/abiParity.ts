import { readFile } from "node:fs/promises";
import type { Abi, AbiEvent, AbiFunction, AbiParameter } from "viem";
import {
  CLAIM_CANCELLED,
  CLAIM_REGISTERED,
  DEFI_ABI,
  POOL_ABI,
  REGISTRY_ABI,
} from "./chain.js";

function parameterType(parameter: AbiParameter): string {
  if (!parameter.type.startsWith("tuple")) return parameter.type;
  const suffix = parameter.type.slice("tuple".length);
  const components = "components" in parameter ? parameter.components : [];
  return `(${components.map(parameterType).join(",")})${suffix}`;
}

function itemIdentity(item: Abi[number]): string | undefined {
  if (item.type !== "function" && item.type !== "event") return undefined;
  return `${item.type}:${item.name}(${item.inputs.map(parameterType).join(",")})`;
}

function sameTypes(left: readonly AbiParameter[], right: readonly AbiParameter[]): boolean {
  return left.length === right.length && left.every((parameter, index) => parameterType(parameter) === parameterType(right[index]));
}

/** Assert that each handwritten function/event exists with full semantics, not
 * merely the same selector/topic. Output tuple drift and indexed drift matter. */
export function assertAbiSubset(label: string, handwritten: Abi, artifact: Abi): number {
  let checked = 0;
  for (const expected of handwritten) {
    const identity = itemIdentity(expected);
    if (!identity) continue;
    const actual = artifact.find((candidate) => itemIdentity(candidate) === identity);
    if (!actual) throw new Error(`${label} ABI missing ${identity}`);

    if (expected.type === "function" && actual.type === "function") {
      const expectedFunction = expected as AbiFunction;
      const actualFunction = actual as AbiFunction;
      if (!sameTypes(expectedFunction.outputs, actualFunction.outputs)) {
        throw new Error(`${label} ${identity} outputs mismatch`);
      }
      if (expectedFunction.stateMutability !== actualFunction.stateMutability) {
        throw new Error(`${label} ${identity} stateMutability mismatch`);
      }
    } else if (expected.type === "event" && actual.type === "event") {
      const expectedEvent = expected as AbiEvent;
      const actualEvent = actual as AbiEvent;
      const expectedIndexed = expectedEvent.inputs.map((input) => Boolean(input.indexed));
      const actualIndexed = actualEvent.inputs.map((input) => Boolean(input.indexed));
      if (expectedIndexed.some((indexed, index) => indexed !== actualIndexed[index])) {
        throw new Error(`${label} ${identity} indexed fields mismatch`);
      }
      if (Boolean(expectedEvent.anonymous) !== Boolean(actualEvent.anonymous)) {
        throw new Error(`${label} ${identity} anonymous flag mismatch`);
      }
    } else {
      throw new Error(`${label} ABI item type mismatch for ${identity}`);
    }
    checked++;
  }
  return checked;
}

async function artifactAbi(root: URL, relativePath: string): Promise<Abi> {
  const artifact = JSON.parse(await readFile(new URL(relativePath, root), "utf8")) as { abi?: Abi };
  if (!Array.isArray(artifact.abi)) throw new Error(`Foundry artifact missing ABI: ${relativePath}`);
  return artifact.abi;
}

/** Compare all 14 first-party entries used by the off-chain settler. */
export async function assertFirstPartyAbiParity(artifactsRoot: URL): Promise<{ checked: number }> {
  const [defiArtifact, registryArtifact, poolArtifact] = await Promise.all([
    artifactAbi(artifactsRoot, "DefiInsurance.sol/DefiInsurance.json"),
    artifactAbi(artifactsRoot, "Registry.sol/Registry.json"),
    artifactAbi(artifactsRoot, "SingleAssetCoverPool.sol/SingleAssetCoverPool.json"),
  ]);
  const checked =
    assertAbiSubset("DefiInsurance", [...DEFI_ABI, CLAIM_REGISTERED, CLAIM_CANCELLED] as Abi, defiArtifact) +
    assertAbiSubset("Registry", REGISTRY_ABI, registryArtifact) +
    assertAbiSubset("SingleAssetCoverPool", POOL_ABI, poolArtifact);
  return { checked };
}
