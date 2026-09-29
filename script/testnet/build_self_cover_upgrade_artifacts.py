#!/usr/bin/env python3
# /// script
# dependencies = ["eth-abi", "eth-utils", "rlp", "eth-hash[pycryptodome]"]
# ///
"""Build deterministic Sepolia artifacts for the global self-cover UUPS upgrade.

This script does not load keys or broadcast. It freezes the current agent nonce,
CREATE addresses, implementation bytecode, timelock operation, and execution
payload for review by script/testnet/agent_deploy.py.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from urllib.request import Request, urlopen

import rlp
from eth_abi import encode
from eth_utils import keccak, to_checksum_address

CHAIN_ID = 11_155_111
AGENT = "0x724e8951d39E14CEBcB5fB02638f49A637C97838"
REGISTRY_PROXY = "0xB34D92cd05005DF36050370433819597a9BaC693"
DEFI_PROXY = "0x4E346CcD0a46D51ebaE6810d653791982968d502"
TIMELOCK = "0x158494e7b95c0e5F87e8dB4Ad1Be5c32de99F645"
ZERO32 = b"\0" * 32
DELAY = 1_800


def rpc(url: str, method: str, params: list[object]) -> str:
    request = Request(
        url,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "usd8-upgrade-artifact-builder/1.0"},
    )
    with urlopen(request, timeout=60) as response:
        payload = json.load(response)
    if "error" in payload:
        raise RuntimeError(f"{method}: {payload['error']}")
    result = payload["result"]
    if not isinstance(result, str):
        raise RuntimeError(f"{method}: expected string result")
    return result


def selector(signature: str) -> bytes:
    return keccak(text=signature)[:4]


def create_address(sender: str, nonce: int) -> str:
    raw = keccak(rlp.encode([bytes.fromhex(sender[2:]), nonce]))[-20:]
    return to_checksum_address(raw)


def load_bytecode(path: Path) -> bytes:
    value = json.loads(path.read_text())["bytecode"]["object"]
    if not value.startswith("0x") or len(value) <= 2:
        raise RuntimeError(f"missing bytecode in {path}")
    return bytes.fromhex(value[2:])


def tx_entry(kind: str, name: str, nonce: int, data: bytes, to: str | None = None, address: str | None = None) -> dict:
    entry = {
        "transactionType": kind,
        "contractName": name,
        "transaction": {
            "from": AGENT,
            "gas": "0x0",
            "value": "0x0",
            "input": "0x" + data.hex(),
            "nonce": hex(nonce),
            "chainId": hex(CHAIN_ID),
        },
    }
    if to is not None:
        entry["transaction"]["to"] = to
    if address is not None:
        entry["contractAddress"] = address
    return entry


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc-url", default="https://ethereum-sepolia-rpc.publicnode.com")
    parser.add_argument("--output-dir", type=Path, default=Path("deployments/sepolia/mock-usdc"))
    args = parser.parse_args()

    if int(rpc(args.rpc_url, "eth_chainId", []), 16) != CHAIN_ID:
        raise RuntimeError("RPC is not Sepolia")
    nonce = int(rpc(args.rpc_url, "eth_getTransactionCount", [AGENT, "pending"]), 16)
    latest_nonce = int(rpc(args.rpc_url, "eth_getTransactionCount", [AGENT, "latest"]), 16)
    if nonce != latest_nonce:
        raise RuntimeError(f"pending nonce uncertainty: latest={latest_nonce} pending={nonce}")

    registry_init = load_bytecode(Path("out/Registry.sol/Registry.json"))
    defi_init = load_bytecode(Path("out/DefiInsurance.sol/DefiInsurance.json"))
    registry_impl = create_address(AGENT, nonce)
    defi_impl = create_address(AGENT, nonce + 1)

    upgrade_sig = "upgradeToAndCall(address,bytes)"
    registry_upgrade = selector(upgrade_sig) + encode(["address", "bytes"], [registry_impl, b""])
    defi_upgrade = selector(upgrade_sig) + encode(["address", "bytes"], [defi_impl, b""])
    targets = [REGISTRY_PROXY, DEFI_PROXY]
    values = [0, 0]
    payloads = [registry_upgrade, defi_upgrade]
    source_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    salt = keccak(
        text=(
            "usd8-sepolia-global-self-cover-upgrade-v1:"
            + source_commit
            + ":"
            + hashlib.sha256(registry_init).hexdigest()
            + ":"
            + hashlib.sha256(defi_init).hexdigest()
        )
    )
    operation_encoding = encode(
        ["address[]", "uint256[]", "bytes[]", "bytes32", "bytes32"],
        [targets, values, payloads, ZERO32, salt],
    )
    operation_id = keccak(operation_encoding)
    schedule = selector("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)") + encode(
        ["address[]", "uint256[]", "bytes[]", "bytes32", "bytes32", "uint256"],
        [targets, values, payloads, ZERO32, salt, DELAY],
    )
    execute = selector("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)") + operation_encoding

    common = {
        "chain": CHAIN_ID,
        "purpose": "TESTNET ONLY: globally permit insured tokens to also be registered cover-pool assets",
        "sourceCommit": source_commit,
        "registryProxy": REGISTRY_PROXY,
        "defiInsuranceProxy": DEFI_PROXY,
        "timelock": TIMELOCK,
        "registryImplementation": registry_impl,
        "defiInsuranceImplementation": defi_impl,
        "registryInitCodeSha256": hashlib.sha256(registry_init).hexdigest(),
        "defiInsuranceInitCodeSha256": hashlib.sha256(defi_init).hexdigest(),
        "salt": "0x" + salt.hex(),
        "operationId": "0x" + operation_id.hex(),
        "delaySeconds": DELAY,
        "targets": targets,
        "values": values,
        "payloads": ["0x" + item.hex() for item in payloads],
        "predecessor": "0x" + ZERO32.hex(),
    }
    schedule_artifact = {
        **common,
        "transactions": [
            tx_entry("CREATE", "Registry implementation", nonce, registry_init, address=registry_impl),
            tx_entry("CREATE", "DefiInsurance implementation", nonce + 1, defi_init, address=defi_impl),
            tx_entry("CALL", "TimelockController.scheduleBatch self-cover upgrade", nonce + 2, schedule, to=TIMELOCK),
        ],
    }
    execute_artifact = {
        **common,
        "transactions": [
            tx_entry("CALL", "TimelockController.executeBatch self-cover upgrade", nonce + 3, execute, to=TIMELOCK)
        ],
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    schedule_path = args.output_dir / "schedule-global-self-cover-upgrade-20260914.json"
    execute_path = args.output_dir / "execute-global-self-cover-upgrade-20260914.json"
    schedule_path.write_text(json.dumps(schedule_artifact, indent=2) + "\n")
    execute_path.write_text(json.dumps(execute_artifact, indent=2) + "\n")
    print(schedule_path)
    print(execute_path)
    print(f"nonce_range={nonce}-{nonce + 3}")
    print(f"registry_impl={registry_impl}")
    print(f"defi_impl={defi_impl}")
    print(f"operation_id=0x{operation_id.hex()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
