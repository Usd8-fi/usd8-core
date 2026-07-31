#!/usr/bin/env python3
"""Prepare deterministic Sepolia deployments and the atomic timing upgrade batch.

Build first with the repository's pinned Foundry settings. This script never
broadcasts and never reads a private key. It writes a reviewable JSON manifest
whose transactions can be submitted through Ambire.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "deployments/sepolia/configurable-timing-upgrade.json"
RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com"

CHAIN_ID = 11_155_111
CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
TIMELOCK = "0x8d10C99dDE0E91Dba85896ce65Daa861B972b330"
REGISTRY_PROXY = "0x3Fa82eC1842f72c36580D84E03377b10B5E2F590"
USD8_PROXY = "0x12C7b483C164C648b4F7b72Af4b93250bED623CE"
TREASURY_PROXY = "0x5B5e52b7E603cA71C7dc37134924855cc45864c1"
DEFI_INSURANCE_PROXY = "0x72B6BBd66Da3Ac20EC203405A30bb97EaF893230"
COVER_POOL_BEACON = "0x02051110D30CD5087a3cE0f03F2d419d0415640E"
ZERO32 = "0x" + "00" * 32

# Current incident phases use one snapshotted duration; preserve production exits.
INCIDENT_CONFIG = (3 * 24 * 60 * 60, 43_200)
EXIT_CONFIG = (7 * 24 * 60 * 60, 3 * 24 * 60 * 60)

ARTIFACTS = {
    "registry": ROOT / "out/Registry.sol/Registry.json",
    "usd8": ROOT / "out/USD8.sol/USD8.json",
    "treasury": ROOT / "out/Treasury.sol/Treasury.json",
    "defiInsurance": ROOT / "out/DefiInsurance.sol/DefiInsurance.json",
    "coverPool": ROOT / "out/SingleAssetCoverPool.sol/SingleAssetCoverPool.json",
}


def run(*args: str) -> str:
    result = subprocess.run(args, cwd=ROOT, check=True, text=True, capture_output=True)
    return result.stdout.strip()


def cast_keccak(value: str) -> str:
    return run("cast", "keccak", value)


def calldata(signature: str, *args: str) -> str:
    return run("cast", "calldata", signature, *args)


def contract_call(signature: str, *args: str) -> str:
    return run("cast", "call", TIMELOCK, signature, *args, "-r", RPC_URL).split()[0]


def artifact_code(path: Path, field: str) -> str:
    if not path.exists():
        raise SystemExit(f"missing artifact {path}; run `forge build` first")
    value = json.loads(path.read_text())[field]["object"]
    return value if value.startswith("0x") else "0x" + value


def materialized_runtime(path: Path, deployment_address: str) -> str:
    """Inject Solidity immutable references into deployed runtime bytecode."""
    artifact = json.loads(path.read_text())
    deployed = artifact["deployedBytecode"]
    value = deployed["object"]
    runtime = bytearray.fromhex(value[2:] if value.startswith("0x") else value)
    address_bytes = bytes.fromhex(deployment_address[2:])
    for references in deployed.get("immutableReferences", {}).values():
        for reference in references:
            start = reference["start"]
            length = reference["length"]
            if length < len(address_bytes):
                raise SystemExit(f"unsupported immutable length {length} in {path}")
            runtime[start : start + length] = address_bytes.rjust(length, b"\x00")
    return "0x" + runtime.hex()


def array(items: list[str]) -> str:
    return "[" + ",".join(items) + "]"


def main() -> None:
    deployments: dict[str, dict[str, str]] = {}
    implementation_addresses: dict[str, str] = {}

    for name, path in ARTIFACTS.items():
        init_code = artifact_code(path, "bytecode")
        init_hash = cast_keccak(init_code)
        salt = cast_keccak(f"usd8-sepolia-current-implementations-v2:{name}:{init_hash}")
        address = run(
            "cast",
            "create2",
            "--deployer",
            CREATE2_FACTORY,
            "--salt",
            salt,
            "--init-code-hash",
            init_hash,
        ).split()[0]
        runtime_hash = cast_keccak(materialized_runtime(path, address))
        deploy_data = salt + init_code[2:]
        implementation_addresses[name] = address
        deployments[name] = {
            "factory": CREATE2_FACTORY,
            "to": CREATE2_FACTORY,
            "value": "0",
            "salt": salt,
            "initCodeHash": init_hash,
            "expectedAddress": address,
            "expectedRuntimeCodeHash": runtime_hash,
            "data": deploy_data,
        }

    incident_tuple = "(" + ",".join(map(str, INCIDENT_CONFIG)) + ")"
    exit_tuple = "(" + ",".join(map(str, EXIT_CONFIG)) + ")"
    targets = [
        REGISTRY_PROXY,
        REGISTRY_PROXY,
        REGISTRY_PROXY,
        USD8_PROXY,
        TREASURY_PROXY,
        DEFI_INSURANCE_PROXY,
        COVER_POOL_BEACON,
    ]
    payloads = [
        calldata(
            "upgradeToAndCall(address,bytes)", implementation_addresses["registry"], "0x"
        ),
        calldata(
            "setIncidentTimingConfig((uint64,uint64))",
            incident_tuple,
        ),
        calldata("setExitTimingConfig((uint64,uint64))", exit_tuple),
        calldata("upgradeToAndCall(address,bytes)", implementation_addresses["usd8"], "0x"),
        calldata("upgradeToAndCall(address,bytes)", implementation_addresses["treasury"], "0x"),
        calldata(
            "upgradeToAndCall(address,bytes)",
            implementation_addresses["defiInsurance"],
            "0x",
        ),
        calldata("upgradeTo(address)", implementation_addresses["coverPool"]),
    ]
    values = ["0"] * len(targets)
    operation_salt = cast_keccak(
        "usd8-sepolia-current-implementations-upgrade-v2:"
        + ":".join(implementation_addresses.values())
    )

    targets_arg = array(targets)
    values_arg = array(values)
    payloads_arg = array(payloads)
    operation_id = contract_call(
        "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)",
        targets_arg,
        values_arg,
        payloads_arg,
        ZERO32,
        operation_salt,
    )
    schedule_data = calldata(
        "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)",
        targets_arg,
        values_arg,
        payloads_arg,
        ZERO32,
        operation_salt,
        "0",
    )
    execute_data = calldata(
        "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)",
        targets_arg,
        values_arg,
        payloads_arg,
        ZERO32,
        operation_salt,
    )

    manifest = {
        "schemaVersion": 1,
        "network": "sepolia",
        "chainId": CHAIN_ID,
        "compilerProfile": {"solc": "0.8.28", "optimizer": True, "optimizerRuns": 1, "viaIR": False},
        "preservedConfiguration": {
            "incidentTiming": {
                "phaseWindow": INCIDENT_CONFIG[0],
                "maxReferenceBlockAge": INCIDENT_CONFIG[1],
            },
            "exitTiming": {
                "unstakeCooldown": EXIT_CONFIG[0],
                "exitBatchInterval": EXIT_CONFIG[1],
            },
        },
        "deployments": deployments,
        "timelockBatch": {
            "timelock": TIMELOCK,
            "targets": targets,
            "values": values,
            "payloads": payloads,
            "predecessor": ZERO32,
            "salt": operation_salt,
            "operationId": operation_id,
            "scheduleTransaction": {"to": TIMELOCK, "value": "0", "data": schedule_data},
            "executeTransaction": {"to": TIMELOCK, "value": "0", "data": execute_data},
        },
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(manifest, indent=2) + "\n")
    print(OUTPUT)
    for name, address in implementation_addresses.items():
        print(f"{name}: {address}")
    print(f"operationId: {operation_id}")


if __name__ == "__main__":
    main()
