#!/usr/bin/env python3
"""Prepare the Sepolia timelock batch that clones insured-token configuration.

The source configuration is the retired Sepolia insurance proxy. This script is
keyless: it only encodes calls, queries the timelock operation ID, and writes a
reviewable manifest.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "deployments/sepolia/insured-token-config.json"
RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com"
TIMELOCK = "0x8d10C99dDE0E91Dba85896ce65Daa861B972b330"
DEFI_INSURANCE = "0x72B6BBd66Da3Ac20EC203405A30bb97EaF893230"
SOURCE_DEFI_INSURANCE = "0x250CeBDD9d6997fFD45C60D6E713f42e44E383ec"
ZERO32 = "0x" + "00" * 32

TOKENS = [
    {
        "symbol": "USD8",
        "token": "0x12C7b483C164C648b4F7b72Af4b93250bED623CE",
        "maxCoverageBps": 8000,
        "underlyingPriceOracle": "0xc316AC5A8fa0D6961c2BCd26EA2d9F9e657626f5",
        "conversionAddress": "0x0000000000000000000000000000000000000000",
        "conversionCallData": "0x",
    },
    {
        "symbol": "sGHO",
        "token": "0xe872eC93fe8728ea522d1024dc8A41028C43338F",
        "maxCoverageBps": 8000,
        "underlyingPriceOracle": "0x25b66809E99bACE57f7A89c4509DeA64C1ea4B11",
        "conversionAddress": "0xe872eC93fe8728ea522d1024dc8A41028C43338F",
        "conversionCallData": "0x07a2d13a0000000000000000000000000000000000000000000000000de0b6b3a7640000",
    },
    {
        "symbol": "sUSDS",
        "token": "0x6313e1f725F6ce1410c6b5312b854c4737cCeA9C",
        "maxCoverageBps": 7000,
        "underlyingPriceOracle": "0x6b27162f197a03103f3C5b840bbA3f09597ac08A",
        "conversionAddress": "0x6313e1f725F6ce1410c6b5312b854c4737cCeA9C",
        "conversionCallData": "0x07a2d13a0000000000000000000000000000000000000000000000000de0b6b3a7640000",
    },
    {
        "symbol": "sUSD8",
        "token": "0x64E64eAdD9817e5F97266D34FF057ba4777c395B",
        "maxCoverageBps": 8000,
        "underlyingPriceOracle": "0xc316AC5A8fa0D6961c2BCd26EA2d9F9e657626f5",
        "conversionAddress": "0x64E64eAdD9817e5F97266D34FF057ba4777c395B",
        "conversionCallData": "0x07a2d13a0000000000000000000000000000000000000000000000000de0b6b3a7640000",
    },
]


def run(*args: str) -> str:
    return subprocess.run(args, cwd=ROOT, check=True, text=True, capture_output=True).stdout.strip()


def calldata(signature: str, *args: str) -> str:
    return run("cast", "calldata", signature, *args)


def array(items: list[str]) -> str:
    return "[" + ",".join(items) + "]"


def main() -> None:
    targets = [DEFI_INSURANCE] * len(TOKENS)
    values = ["0"] * len(TOKENS)
    payloads = [
        calldata(
            "editInsuredToken(address,uint256,address,address,bytes)",
            item["token"],
            str(item["maxCoverageBps"]),
            item["underlyingPriceOracle"],
            item["conversionAddress"],
            item["conversionCallData"],
        )
        for item in TOKENS
    ]
    payload_hashes = [run("cast", "keccak", payload) for payload in payloads]
    salt = run("cast", "keccak", "usd8-sepolia-insured-token-config-v1:" + ":".join(payload_hashes))
    targets_arg, values_arg, payloads_arg = array(targets), array(values), array(payloads)
    operation_id = run(
        "cast", "call", TIMELOCK,
        "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)",
        targets_arg, values_arg, payloads_arg, ZERO32, salt, "-r", RPC_URL,
    ).split()[0]
    schedule_data = calldata(
        "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)",
        targets_arg, values_arg, payloads_arg, ZERO32, salt, "0",
    )
    execute_data = calldata(
        "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)",
        targets_arg, values_arg, payloads_arg, ZERO32, salt,
    )
    manifest = {
        "schemaVersion": 1,
        "network": "sepolia",
        "chainId": 11_155_111,
        "sourceDefiInsurance": SOURCE_DEFI_INSURANCE,
        "targetDefiInsurance": DEFI_INSURANCE,
        "tokens": TOKENS,
        "timelockBatch": {
            "timelock": TIMELOCK,
            "targets": targets,
            "values": values,
            "payloads": payloads,
            "predecessor": ZERO32,
            "salt": salt,
            "operationId": operation_id,
            "scheduleTransaction": {"to": TIMELOCK, "value": "0", "data": schedule_data},
            "executeTransaction": {"to": TIMELOCK, "value": "0", "data": execute_data},
        },
    }
    OUTPUT.write_text(json.dumps(manifest, indent=2) + "\n")
    print(OUTPUT)
    print(f"operationId: {operation_id}")


if __name__ == "__main__":
    main()
