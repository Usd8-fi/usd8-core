#!/usr/bin/env python3
"""Approved cutover command -> mandatory read-only live gate. No implicit rollback.

The caller supplies the reviewed deployment program as argv after --. Secrets
must be supplied through that program's safe input mechanism, not argv. Output
from the program/verifier is captured because it can contain environment values.
"""
import argparse
import os
import pathlib
import subprocess
import sys


def deploy(manifest, baseline, digest, rpc_url, command, plan):
    if not command:
        raise SystemExit("DEPLOYMENT_NOT_STARTED: explicit reviewed cutover command required")
    # Reverify against the same externally pinned approval after cutover; any
    # accidental bundle/baseline edits fail the mandatory final gate.
    verifier = pathlib.Path(__file__).with_name("verify-release.py")
    local = [sys.executable, str(verifier), str(manifest),
             "--security-baseline", str(baseline), "--baseline-sha256", digest]
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        result = subprocess.run(local, capture_output=True, env=env)
    except (OSError, KeyboardInterrupt):
        raise SystemExit("DEPLOYMENT_NOT_STARTED: local verification unavailable") from None
    if result.returncode:
        raise SystemExit("DEPLOYMENT_NOT_STARTED: local bundle / independent approval verification failed")
    if plan:
        print("RELEASE_PLAN_ONLY: local approval checked; no deployment or live verification performed")
        return
    if not rpc_url:
        raise SystemExit("DEPLOYMENT_NOT_STARTED: explicit --rpc-url required")
    try:
        result = subprocess.run(command, capture_output=True, env=env)
        if result.returncode:
            raise SystemExit("DEPLOYED_UNVERIFIED: cutover failed; partial deployment possible; no automatic rollback")
        # This is executed, not printed as an optional operator follow-up.
        result = subprocess.run(local + ["--live", "--rpc-url", rpc_url], capture_output=True, env=env)
        if result.returncode:
            raise SystemExit("DEPLOYED_UNVERIFIED: mandatory live AWS/chain security gate failed or uninspectable; no automatic rollback")
    except (OSError, KeyboardInterrupt):
        raise SystemExit("DEPLOYED_UNVERIFIED: cutover or mandatory live gate interrupted/unavailable; no automatic rollback") from None
    print("RELEASE_DEPLOYED_AND_LIVE_VERIFIED")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("--security-baseline", required=True, type=pathlib.Path)
    parser.add_argument("--baseline-sha256", required=True)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--plan", action="store_true", help="local validation only; never executes cutover/AWS")
    # Split explicitly: argparse REMAINDER would consume verifier options after manifest.
    argv = sys.argv[1:]
    if "--" not in argv:
        parser.error("supply the reviewed cutover command after --")
    separator = argv.index("--")
    args = parser.parse_args(argv[:separator])
    deploy(args.manifest, args.security_baseline, args.baseline_sha256, args.rpc_url,
           argv[separator + 1:], args.plan)


if __name__ == "__main__":
    main()
