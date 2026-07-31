#!/usr/bin/env python3
"""Fail closed: the retired Python incident-open model is not protocol-authoritative."""

from __future__ import annotations

import sys


def main() -> int:
    print(
        "incident-open preflight moved to offchain-rust: use the pinned "
        "`usd8-settlement attested-open <insuredToken> --registry <address> "
        "--rpc-url <url> --expected-signer <address>` path. The retired Python "
        "USD-oracle/minClaimAmount model is intentionally disabled.",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
