#!/usr/bin/env python3
"""Audit every independent lock graph with only operator-approved exceptions.

cargo-audit 0.22.2 has no --config option. Its current-directory audit.toml
replaces (rather than merges with) CARGO_HOME/audit.toml. Run in a private
controlled directory so ambient configuration cannot silently suppress findings.
"""
import pathlib
import shlex
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
GRAPHS = (".", "job-api", "score-api", "score-core")


def main():
    status = 0
    with tempfile.TemporaryDirectory(prefix="usd8-audit-") as directory:
        cwd = pathlib.Path(directory)
        (cwd / ".cargo").mkdir()
        (cwd / ".cargo/audit.toml").write_text("[advisories]\nignore = []\n")
        for graph in GRAPHS:
            lockfile = (ROOT / graph / "Cargo.lock").resolve()
            if not lockfile.is_file():
                print(f"Missing lockfile: {lockfile}", flush=True)
                status = 2
                continue
            command = [
                "cargo", "+1.94.1", "audit", "--deny", "warnings",
                "--ignore", "RUSTSEC-2021-0127",
                "--ignore", "RUSTSEC-2024-0388", "--ignore", "RUSTSEC-2024-0436",
                "--file", str(lockfile),
            ]
            print(f"\n[{graph}] {shlex.join(command)}", flush=True)
            result = subprocess.run(command, cwd=cwd)
            code = result.returncode if result.returncode >= 0 else 2
            status = max(status, code)
            print(f"[{graph}] audit exit={code}", flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
