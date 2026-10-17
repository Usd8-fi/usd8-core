#!/usr/bin/env python3
"""Find the Trezor derivation path for a given Ethereum address (read-only).

Reads addresses without displaying them on the device, so there is nothing to
confirm per address. Enter the PIN / passphrase on the Trezor if it asks; the
passphrase selects which wallet is searched. Nothing is signed.

    DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/libusb/lib \
    python3 script/testnet/find_trezor_account.py 0x977c... --device webusb:000:1:1
"""
import argparse
import os
import sys

VENV_PYTHON = "/Users/rickchen/.local/venvs/trezor-safe7-ble/bin/python"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("address")
    parser.add_argument("--device", default="webusb:000:1")
    parser.add_argument("--count", type=int, default=50, help="addresses to try per path style")
    args = parser.parse_args()

    from trezorlib import ethereum
    from trezorlib.cli import TrezorConnection
    from trezorlib.tools import parse_path

    target = args.address.lower()
    session = TrezorConnection(path=args.device).get_session()
    styles = (
        ("Trezor / MetaMask (address index)", lambda i: f"m/44h/60h/0h/0/{i}"),
        ("Ledger Live (account index)", lambda i: f"m/44h/60h/{i}h/0/0"),
    )
    first = None
    for name, path_of in styles:
        for index in range(args.count):
            path = path_of(index)
            address = ethereum.get_address(session, parse_path(path), show_display=False)
            first = first or address
            if address.lower() == target:
                print(f"MATCH: {path}  {address}  ({name}, index {index})")
                return 0
    print(f"No match in the first {args.count} addresses of either path style.")
    print(f"This wallet's first address is {first}. If that is not the wallet you expected,")
    print("rerun and enter the other passphrase (or none) when the Trezor asks.")
    return 1


if __name__ == "__main__":
    if os.path.realpath(sys.executable) != os.path.realpath(VENV_PYTHON) and os.path.exists(VENV_PYTHON):
        os.execv(VENV_PYTHON, [VENV_PYTHON, *sys.argv])
    raise SystemExit(main())
