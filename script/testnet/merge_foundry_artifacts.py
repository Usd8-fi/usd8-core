#!/usr/bin/env python3
"""Merge staged Foundry broadcast artifacts into one nonce-contiguous artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("artifacts", type=Path, nargs="+")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    transactions: list[dict[str, Any]] = []
    chain_id: int | None = None
    sender: str | None = None

    for path in args.artifacts:
        artifact = json.loads(path.read_text())
        staged = artifact.get("transactions")
        if not isinstance(staged, list) or not staged:
            raise SystemExit(f"{path}: no transactions")
        for entry in staged:
            tx = entry.get("transaction", {})
            current_chain = int(tx["chainId"], 16)
            current_sender = tx["from"].lower()
            if chain_id is None:
                chain_id = current_chain
                sender = current_sender
            if current_chain != chain_id or current_sender != sender:
                raise SystemExit(f"{path}: chain or sender mismatch")
            transactions.append(entry)

    nonces = [int(entry["transaction"]["nonce"], 16) for entry in transactions]
    if nonces != list(range(nonces[0], nonces[0] + len(nonces))):
        raise SystemExit(f"non-contiguous nonces: {nonces}")

    output = {
        "chain": chain_id,
        "sender": sender,
        "transactions": transactions,
        "receipts": [],
        "libraries": [],
        "pending": [],
        "returns": {},
        "timestamp": 0,
        "commit": "merged-reviewed-artifact",
    }
    encoded = (json.dumps(output, indent=2) + "\n").encode()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(encoded)
    print(f"transactions={len(transactions)} nonces={nonces[0]}..{nonces[-1]}")
    print(f"sha256={hashlib.sha256(encoded).hexdigest()}")
    print(args.output)


if __name__ == "__main__":
    main()
