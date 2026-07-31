#!/usr/bin/env python3
"""Fail-closed DefiInsurance selector/error closure manifest validator.

This validates compiled ABI identity, selectors, evidence schema, and compiled
test identity. It deliberately does not infer Solidity assertion semantics from
source text; the Forge/Kontrol test run is the executable evidence for those.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "formal-verification" / "defi-insurance-abi-closure.json"


def canonical_type(item: dict) -> str:
    typ = item["type"]
    if not typ.startswith("tuple"):
        return typ
    suffix = typ[5:]
    return "(" + ",".join(canonical_type(component) for component in item["components"]) + ")" + suffix


def signature(item: dict) -> str:
    return item["name"] + "(" + ",".join(canonical_type(arg) for arg in item.get("inputs", [])) + ")"


def run(*args: str) -> str:
    return subprocess.run(args, cwd=ROOT, check=True, text=True, capture_output=True).stdout.strip()


def fail(message: str) -> NoReturn:
    print(f"DefiInsurance ABI closure FAILED: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    manifest = json.loads(MANIFEST.read_text())
    abi = json.loads(run("forge", "inspect", "DefiInsurance", "abi", "--json"))
    compiled = {
        kind: {signature(item) for item in abi if item["type"] == kind}
        for kind in ("function", "error", "event")
    }

    expected_functions = {row["signature"] for row in manifest["selectors"]}
    expected_errors = {row["signature"] for row in manifest["errors"]}
    function_count = manifest["compiled_counts"]["functions"]
    error_count = manifest["compiled_counts"]["errors"]
    if len(manifest["selectors"]) != function_count or len(expected_functions) != function_count:
        fail(f"selector matrix is not exactly {function_count} unique rows")
    if len(manifest["errors"]) != error_count or len(expected_errors) != error_count:
        fail(f"error matrix is not exactly {error_count} unique rows")
    if compiled["function"] != expected_functions:
        fail(f"function drift: missing={sorted(compiled['function'] - expected_functions)}, stale={sorted(expected_functions - compiled['function'])}")
    if compiled["error"] != expected_errors:
        fail(f"error drift: missing={sorted(compiled['error'] - expected_errors)}, stale={sorted(expected_errors - compiled['error'])}")
    if len(compiled["event"]) != manifest["compiled_counts"]["events"]:
        fail(f"event count drift: compiled={len(compiled['event'])}")

    for family in ("selectors", "errors"):
        for row in manifest[family]:
            actual = run("cast", "sig", row["signature"])
            if actual != row["selector"]:
                fail(f"wrong selector for {row['signature']}: {row['selector']} != {actual}")

    allowed = {"reachable", "preempted", "structural"}
    classes = {row.get("classification") for row in manifest["errors"]}
    if not classes <= allowed or classes != allowed:
        fail(f"error classifications must use all and only {sorted(allowed)}; got {sorted(classes)}")
    test_inventory: dict[str, set[str]] = {}
    test_sources = {
        "DefiInsuranceConfigKontrolTest": "formal-verification/properties/DefiInsuranceConfig.k.sol",
        "DefiInsuranceClaimLifecycleKontrolTest": "formal-verification/properties/DefiInsuranceClaimLifecycle.k.sol",
        "DefiInsuranceSettlementKontrolTest": "formal-verification/properties/DefiInsuranceSettlement.k.sol",
        "DefiInsuranceFinalizationKontrolTest": "formal-verification/properties/DefiInsuranceFinalization.k.sol",
        "DefiInsuranceAdminKontrolTest": "formal-verification/properties/DefiInsuranceAdmin.k.sol",
    }

    def resolve_test(identity: str) -> None:
        if "::" not in identity:
            fail(f"invalid test identity {identity!r}; expected Contract::signature")
        contract, test_signature = identity.split("::", 1)
        if contract not in test_inventory:
            source = test_sources.get(contract)
            if source is None:
                fail(f"no isolated formal source registered for evidence contract {contract}")
            run("env", f"FOUNDRY_TEST={source}", "FOUNDRY_PROFILE=kontrol", "forge", "build", "--silent")
            artifact = ROOT / "formal-verification" / "out" / Path(source).name / f"{contract}.json"
            if not artifact.is_file():
                fail(f"compiled evidence artifact missing: {artifact.relative_to(ROOT)}")
            test_abi = json.loads(artifact.read_text())["abi"]
            test_inventory[contract] = {
                signature(item) for item in test_abi if item["type"] == "function" and item["name"].startswith("test")
            }
        if test_signature not in test_inventory[contract]:
            fail(f"evidence test does not resolve: {identity}")

    for row in manifest["selectors"]:
        evidence = row.get("evidence")
        if not isinstance(evidence, dict) or set(evidence) != {"test", "assertions"}:
            fail(f"selector evidence fields must be exactly test/assertions for {row['signature']}")
        if not isinstance(evidence["assertions"], list) or not evidence["assertions"]:
            fail(f"selector evidence assertions missing for {row['signature']}")
        resolve_test(evidence["test"])

    for row in manifest["errors"]:
        evidence = row.get("evidence")
        if row["classification"] == "reachable":
            if not isinstance(evidence, dict) or set(evidence) != {"test", "returndata", "returndata_length", "rollback"}:
                fail(f"reachable evidence fields must be exactly test/returndata/returndata_length/rollback for {row['signature']}")
            if evidence["returndata"] != "exact-length-and-content":
                fail(f"reachable error must compare exact returndata length and content for {row['signature']}")
            expected_length: int | str = 4 if row["signature"].endswith("()") else "abi"
            if evidence["returndata_length"] != expected_length:
                fail(f"wrong returndata length evidence for {row['signature']}: expected {expected_length!r}")
            if not isinstance(evidence["rollback"], list) or not evidence["rollback"]:
                fail(f"reachable error rollback evidence missing for {row['signature']}")
            resolve_test(evidence["test"])
        else:
            if not isinstance(evidence, dict) or set(evidence) != {"reason", "source_path"}:
                fail(f"excluded evidence fields must be exactly reason/source_path for {row['signature']}")
            if not all(isinstance(evidence[key], str) and evidence[key].strip() for key in evidence):
                fail(f"empty exclusion evidence for {row['signature']}")

    counts = {name: sum(row["classification"] == name for row in manifest["errors"]) for name in sorted(allowed)}
    print(
        f"DefiInsurance ABI closure OK: {function_count} selectors, "
        f"{error_count} errors {counts}, {len(compiled['event'])} events"
    )


if __name__ == "__main__":
    main()
