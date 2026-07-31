#!/usr/bin/env python3
"""Validate or execute a Foundry dry-run artifact with the ignored Sepolia agent EOA.

The private key is loaded in-process from test/testnet/.accounts/accounts.json. It is
never printed, written to an artifact, or passed in a subprocess argument.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time
from pathlib import Path
from typing import Any
from urllib.request import Request, urlopen

from eth_account import Account
from eth_utils import to_checksum_address

CHAIN_ID = 11_155_111
DEFAULT_RPC = "https://ethereum-sepolia-rpc.publicnode.com"
DEFAULT_ACCOUNTS = Path("test/testnet/.accounts/accounts.json")
EXPECTED_AGENT = "0x724e8951d39e14CEBcB5fB02638f49A637C97838"


def rpc(url: str, method: str, params: list[Any]) -> Any:
    request = Request(
        url,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "usd8-agent-deployer/1.0"},
    )
    with urlopen(request, timeout=60) as response:
        payload = json.load(response)
    if "error" in payload:
        raise RuntimeError(f"RPC {method} failed: {payload['error']}")
    return payload["result"]


def quantity(value: str | int) -> int:
    return int(value, 16) if isinstance(value, str) else value


def load_account(accounts_path: Path, role: str):
    payload = json.loads(accounts_path.read_text())
    try:
        actor = next(account for account in payload["accounts"] if account.get("role") == role)
    except StopIteration as error:
        raise RuntimeError(f"unknown testnet actor role: {role}") from error
    account = Account.from_key(actor["privateKey"])
    if account.address.lower() != actor["address"].lower():
        raise RuntimeError(f"testnet actor custody mismatch: {role}")
    if role == "funder" and account.address.lower() != EXPECTED_AGENT.lower():
        raise RuntimeError("funder custody mismatch")
    return account


def wait_for_receipt(url: str, tx_hash: str, timeout: int = 600) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        receipt = rpc(url, "eth_getTransactionReceipt", [tx_hash])
        if receipt is not None:
            return receipt
        time.sleep(3)
    raise TimeoutError(f"receipt timeout: {tx_hash}")


def fee_caps(url: str) -> tuple[int, int]:
    pending = rpc(url, "eth_getBlockByNumber", ["pending", False])
    base_fee = quantity(pending.get("baseFeePerGas", "0x0"))
    try:
        priority = quantity(rpc(url, "eth_maxPriorityFeePerGas", []))
    except RuntimeError:
        priority = 1_000_000_000
    priority = max(priority, 1_000_000)
    return base_fee * 2 + priority, priority


def artifact_transactions(artifact: dict[str, Any]) -> list[dict[str, Any]]:
    result = []
    for entry in artifact.get("transactions", []):
        tx = entry["transaction"]
        result.append(
            {
                "label": entry.get("contractName") or entry.get("function") or entry["transactionType"],
                "transactionType": entry["transactionType"],
                "expectedContractAddress": entry.get("contractAddress") if entry["transactionType"] == "CREATE" else None,
                "from": tx["from"],
                "to": tx.get("to"),
                "gas": quantity(tx["gas"]),
                "value": quantity(tx["value"]),
                "data": tx["input"],
                "nonce": quantity(tx["nonce"]),
                "chainId": quantity(tx["chainId"]),
            }
        )
    if not result:
        raise RuntimeError("artifact contains no transactions")
    return result


def save_state(path: Path, value: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--accounts", type=Path, default=DEFAULT_ACCOUNTS)
    parser.add_argument("--role", default="funder", help="ignored testnet account role (default: funder)")
    parser.add_argument("--rpc-url", default=DEFAULT_RPC)
    parser.add_argument("--broadcast", action="store_true")
    parser.add_argument("--yes", action="store_true")
    args = parser.parse_args()

    artifact_bytes = args.artifact.read_bytes()
    artifact = json.loads(artifact_bytes)
    transactions = artifact_transactions(artifact)
    account = load_account(args.accounts, args.role)

    if quantity(rpc(args.rpc_url, "eth_chainId", [])) != CHAIN_ID:
        raise RuntimeError("RPC is not Ethereum Sepolia")
    if any(tx["chainId"] != CHAIN_ID for tx in transactions):
        raise RuntimeError("artifact chain mismatch")
    if any(tx["from"].lower() != account.address.lower() for tx in transactions):
        raise RuntimeError("artifact sender mismatch")
    first_nonce = transactions[0]["nonce"]
    if [tx["nonce"] for tx in transactions] != list(range(first_nonce, first_nonce + len(transactions))):
        raise RuntimeError("artifact nonces are not contiguous")

    digest = hashlib.sha256(artifact_bytes).hexdigest()
    state_path = args.artifact.with_suffix(".agent-state.json")
    state: dict[str, Any] = {"artifactSha256": digest, "role": args.role, "sender": account.address, "receipts": []}
    if state_path.exists():
        state = json.loads(state_path.read_text())
        if (
            state.get("artifactSha256") != digest
            or state.get("role") != args.role
            or state.get("sender", "").lower() != account.address.lower()
        ):
            raise RuntimeError("deployment journal does not match artifact/sender")

    completed = 0
    for entry in state["receipts"]:
        if entry["index"] != completed or entry["nonce"] != transactions[completed]["nonce"]:
            raise RuntimeError("deployment journal is not contiguous")
        receipt = rpc(args.rpc_url, "eth_getTransactionReceipt", [entry["transactionHash"]])
        if receipt is None:
            raise RuntimeError(f"journaled transaction is still pending: {entry['transactionHash']}")
        if quantity(receipt["status"]) != 1:
            raise RuntimeError(f"journaled transaction reverted: {entry['transactionHash']}")
        expected = transactions[completed]["expectedContractAddress"]
        actual = receipt.get("contractAddress")
        if expected and (not actual or expected.lower() != actual.lower()):
            raise RuntimeError(f"journaled CREATE address mismatch: expected={expected} actual={actual}")
        entry["status"] = "confirmed"
        entry["blockNumber"] = quantity(receipt["blockNumber"])
        entry["contractAddress"] = actual
        completed += 1
    if state["receipts"]:
        save_state(state_path, state)

    latest_nonce = quantity(rpc(args.rpc_url, "eth_getTransactionCount", [account.address, "latest"]))
    pending_nonce = quantity(rpc(args.rpc_url, "eth_getTransactionCount", [account.address, "pending"]))
    expected_nonce = first_nonce + completed
    if latest_nonce != pending_nonce:
        raise RuntimeError(f"pending nonce uncertainty: latest={latest_nonce} pending={pending_nonce}")
    if latest_nonce != expected_nonce:
        raise RuntimeError(f"stale artifact/journal nonce: live={latest_nonce} expected={expected_nonce}")

    print(f"artifact_sha256={digest}")
    print(f"role={args.role}")
    print(f"sender={account.address}")
    print(f"nonce_range={first_nonce}-{transactions[-1]['nonce']}")
    print(f"transactions={len(transactions)} completed={completed}")
    if not args.broadcast:
        print("mode=validated-dry-run")
        return 0
    if not args.yes:
        raise RuntimeError("broadcast requires --yes")
    if completed == len(transactions):
        print(f"mode=already-complete state={state_path}")
        return 0

    max_fee, priority_fee = fee_caps(args.rpc_url)

    for index, tx in enumerate(transactions[completed:], start=completed):
        live_nonce = quantity(rpc(args.rpc_url, "eth_getTransactionCount", [account.address, "latest"]))
        pending = quantity(rpc(args.rpc_url, "eth_getTransactionCount", [account.address, "pending"]))
        if live_nonce != tx["nonce"] or pending != live_nonce:
            raise RuntimeError(f"nonce changed before transaction {index}: latest={live_nonce} pending={pending}")
        call = {
            "from": account.address,
            "to": tx["to"],
            "value": hex(tx["value"]),
            "data": tx["data"],
        }
        estimate = quantity(rpc(args.rpc_url, "eth_estimateGas", [call]))
        gas = max(tx["gas"], estimate) * 120 // 100
        unsigned = {
            "chainId": CHAIN_ID,
            "nonce": tx["nonce"],
            "gas": gas,
            "maxFeePerGas": max_fee,
            "maxPriorityFeePerGas": priority_fee,
            "value": tx["value"],
            "data": tx["data"],
            "type": 2,
        }
        if tx["to"]:
            unsigned["to"] = to_checksum_address(tx["to"])
        signed = account.sign_transaction(unsigned)
        tx_hash = rpc(args.rpc_url, "eth_sendRawTransaction", ["0x" + signed.raw_transaction.hex()])
        print(f"sent index={index} nonce={tx['nonce']} label={tx['label']} tx={tx_hash}")
        journal_entry = {
            "index": index,
            "nonce": tx["nonce"],
            "label": tx["label"],
            "transactionHash": tx_hash,
            "status": "sent",
        }
        state["receipts"].append(journal_entry)
        save_state(state_path, state)

        receipt = wait_for_receipt(args.rpc_url, tx_hash)
        if quantity(receipt["status"]) != 1:
            raise RuntimeError(f"transaction reverted: {tx_hash}")
        expected = tx["expectedContractAddress"]
        actual = receipt.get("contractAddress")
        if expected and (not actual or expected.lower() != actual.lower()):
            raise RuntimeError(f"CREATE address mismatch: expected={expected} actual={actual}")
        journal_entry["status"] = "confirmed"
        journal_entry["blockNumber"] = quantity(receipt["blockNumber"])
        journal_entry["contractAddress"] = actual
        save_state(state_path, state)

    print(f"mode=broadcast-complete state={state_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
