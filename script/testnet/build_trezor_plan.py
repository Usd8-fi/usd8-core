#!/usr/bin/env python3
"""Convert a Foundry dry-run artifact into a Trezor plan for trezor_deploy.py.

Usage (after `forge script ... --sender <deployer>` WITHOUT --broadcast):

    python3 script/testnet/build_trezor_plan.py \
        broadcast/01_DeployUSD8System.s.sol/11155111/dry-run/run-latest.json \
        --name "USD8 Sepolia step 01 system" \
        --out deployments/sepolia/01-system-create3-plan.json

The plan carries only what was simulated: sender, chain, nonces, targets, values and
calldata (with a SHA-256 per transaction). Gas is estimated live by trezor_deploy.py at
signing time. CreateX deployCreate3 calls are labelled with their USD8 CREATE3 label and
the address CreateX deploys to, so every signing prompt names the contract being created.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

CREATEX = "0xba5ed099633d3b313e4d5f7bdc1305d3c28ba5ed"
LABELS_FILE = Path(__file__).resolve().parents[1] / "lib" / "USD8DeploymentLabels.sol"
LABEL_RE = re.compile(r'string internal constant (LABEL_\w+) = "([^"]+)";')
NETWORKS = {1: "ethereum-mainnet", 11155111: "ethereum-sepolia"}


def keccak_hex(text: str) -> str:
    return subprocess.check_output(["cast", "keccak", text], text=True).strip().lower()


def label_salts(deployer: str) -> dict[str, str]:
    """Map raw CreateX salt -> label, mirroring Create3Deployer._create3Salt."""
    labels = LABEL_RE.findall(LABELS_FILE.read_text())
    if not labels:
        raise SystemExit(f"no labels found in {LABELS_FILE}")
    prefix = deployer.lower().removeprefix("0x") + "00"
    return {"0x" + prefix + keccak_hex(label)[2:24]: label for _, label in labels}


def as_hex(value: object) -> str:
    if value is None:
        return "0x0"
    if isinstance(value, int):
        return hex(value)
    return str(value).lower()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dry_run", type=Path)
    parser.add_argument("--name", required=True, help="plan name you must retype before signing")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--derivation-path", default="m/44h/60h/0h/0/0")
    args = parser.parse_args()

    run = json.loads(args.dry_run.read_text())
    entries = run.get("transactions") or []
    if not entries:
        raise SystemExit("dry run contains no transactions")

    chain_id = int(run["chain"])
    senders = {e["transaction"]["from"].lower() for e in entries}
    if len(senders) != 1:
        raise SystemExit(f"expected one sender, found {sorted(senders)}")
    sender = senders.pop()
    if sender == "0x1804c8ab1f12e6bbf3894d4083f33e07309d1f38":
        raise SystemExit("dry run used Foundry's default sender; rerun forge with --sender <deployer>")
    salts = label_salts(sender)

    transactions = []
    outputs: dict[str, str] = {}
    start_nonce = int(as_hex(entries[0]["transaction"]["nonce"]), 16)
    for index, entry in enumerate(entries):
        tx = entry["transaction"]
        nonce = int(as_hex(tx["nonce"]), 16)
        if nonce != start_nonce + index:
            raise SystemExit(f"non-contiguous nonce at index {index}: {nonce}")
        if tx.get("chainId") is not None and int(as_hex(tx["chainId"]), 16) != chain_id:
            raise SystemExit(f"transaction {index} chain id mismatch")
        data = (tx.get("input") or tx.get("data") or "0x").lower()
        to = tx.get("to")
        function = entry.get("function")
        contract_name = entry.get("contractName")
        expected = None

        if to and to.lower() == CREATEX and function and function.startswith("deployCreate3"):
            salt = str(entry["arguments"][0]).lower()
            label = salts.get(salt)
            if label is None:
                raise SystemExit(f"transaction {index}: CreateX salt {salt} matches no USD8 label for {sender}")
            created = [
                c["address"]
                for c in entry.get("additionalContracts") or []
                if c.get("transactionType") == "CREATE"
            ]
            expected = created[-1] if created else None
            contract_name = label
            if expected:
                outputs[label] = expected
        elif contract_name and function:
            contract_name = f"{contract_name}.{function}"

        transactions.append(
            {
                "index": index,
                "nonce": nonce,
                "transactionType": entry["transactionType"],
                "contractName": contract_name,
                "function": function,
                "to": to,
                "value": as_hex(tx.get("value")),
                "data": data,
                "dataSha256": hashlib.sha256(bytes.fromhex(data.removeprefix("0x"))).hexdigest(),
                "expectedContractAddress": expected,
            }
        )

    plan = {
        "schemaVersion": 1,
        "name": args.name,
        "network": NETWORKS.get(chain_id, f"chain-{chain_id}"),
        "chainId": chain_id,
        "sender": sender,
        "derivationPath": args.derivation_path,
        "expectedStartNonce": start_nonce,
        "expectedEndNonce": start_nonce + len(transactions),
        "transactions": transactions,
        "expectedOutputs": outputs,
    }
    args.out.write_text(json.dumps(plan, indent=2) + "\n")

    print(f"Plan:     {args.name}")
    print(f"Chain:    {chain_id}   Sender: {sender}")
    print(f"Nonces:   {start_nonce} .. {start_nonce + len(transactions) - 1}  ({len(transactions)} transactions)")
    for tx in transactions:
        what = tx["contractName"] or tx["function"] or tx["transactionType"]
        print(f"  [{tx['index'] + 1:>2}] nonce {tx['nonce']:<4} {what:<42} to={tx['to']}")
    if outputs:
        print("Expected CREATE3 addresses:")
        for label, address in outputs.items():
            print(f"  {label:<40} {address}")
    print(f"Wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
