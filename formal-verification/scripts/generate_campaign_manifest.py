#!/usr/bin/env python3
"""Generate a fail-closed provenance manifest for the Kontrol campaign."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
FORMAL = ROOT / "formal-verification"
REPORTS = FORMAL / "reports"
OUTPUT = REPORTS / "campaign-manifest.json"
APPROVED_INVENTORY = FORMAL / "approved-campaign-inventory.json"
EXECUTION_RECORD = FORMAL / "cache" / "campaign-execution.json"

PRODUCTION_TARGETS = {
    "Registry": "src/Registry.sol:Registry",
    "USD8": "src/USD8.sol:USD8",
    "Treasury": "src/Treasury.sol:Treasury",
    "DefiInsurance": "src/DefiInsurance.sol:DefiInsurance",
    "SingleAssetCoverPool": "src/SingleAssetCoverPool.sol:SingleAssetCoverPool",
    "ERC4626Strategy": "src/strategies/ERC4626Strategy.sol:ERC4626Strategy",
    "USD8PriceOracle": "src/oracles/USD8PriceOracle.sol:USD8PriceOracle",
    "USD8SavingsAdapter": "src/adapters/USD8SavingsAdapter.sol:USD8SavingsAdapter",
    "USD8SavingsBootstrap": "src/deployment/USD8SavingsBootstrap.sol:USD8SavingsBootstrap",
}
REPORT_NAME_OVERRIDES = {"TreasuryKontrolTest": "treasury-base-kontrol.xml"}
SMOKE_CLASS = "KontrolTransientStorageSmokeTest"
SMOKE_REPORT = "transient-storage-smoke-kontrol.xml"


def campaign_env() -> dict[str, str]:
    env = os.environ.copy()
    env["FOUNDRY_PROFILE"] = "kontrol"
    env["FOUNDRY_DISABLE_NIGHTLY_WARNING"] = "1"
    env.pop("FOUNDRY_TEST", None)
    return env


def run(*args: str, env: dict[str, str] | None = None) -> str:
    return subprocess.run(
        args, cwd=ROOT, env=env, check=True, capture_output=True, text=True
    ).stdout.strip()


def canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_record(path: Path) -> dict[str, str | int]:
    data = path.read_bytes()
    return {
        "path": str(path.relative_to(ROOT)),
        "bytes": len(data),
        "sha256": digest_bytes(data),
    }


def typed_test_signatures(tests: object) -> list[str]:
    if not isinstance(tests, list) or not all(isinstance(item, str) for item in tests):
        raise ValueError("forge test --list returned a malformed test list")
    signatures = sorted(item for item in tests if item.startswith("test_"))
    if len(signatures) != len(set(signatures)):
        raise ValueError("forge test --list returned duplicate typed signatures")
    return signatures


def family_for(contract: str) -> str:
    matches = [name for name in PRODUCTION_TARGETS if contract.startswith(name)]
    if not matches:
        return "infrastructure"
    return max(matches, key=len)


def kebab_contract(contract: str) -> str:
    stem = contract.removesuffix("KontrolTest")
    # Keep initialisms/numbers together: USD8PriceOracle -> usd8-price-oracle.
    words = re.findall(r"[A-Z]+(?=[A-Z][a-z]|\d|$)|[A-Z]?[a-z]+|\d+", stem)
    merged: list[str] = []
    for index, word in enumerate(words):
        if word.isdigit() and merged and words[index - 1].isupper():
            merged[-1] += word.lower()
        else:
            merged.append(word.lower())
    return "-".join(merged) + "-kontrol.xml"


def inventory_from_forge(listed: dict[str, object]) -> dict[str, object]:
    candidates: dict[str, object] = {}
    foundry_only: dict[str, object] = {}
    for source_path, raw_contracts in sorted(listed.items()):
        if not source_path.startswith("formal-verification/"):
            continue
        if not isinstance(raw_contracts, dict):
            raise ValueError(f"malformed contract inventory for {source_path}")
        for contract, raw_tests in sorted(raw_contracts.items()):
            signatures = typed_test_signatures(raw_tests)
            if not signatures:
                continue
            record: dict[str, object] = {
                "source": source_path,
                "family": family_for(contract),
                "signatures": signatures,
            }
            if contract.endswith("KontrolTest"):
                record["report"] = REPORT_NAME_OVERRIDES.get(contract, kebab_contract(contract))
                candidates[contract] = record
            else:
                if contract == SMOKE_CLASS:
                    record["solver_report"] = SMOKE_REPORT
                foundry_only[contract] = record

    reports = [str(record["report"]) for record in candidates.values()]
    if len(reports) != len(set(reports)):
        raise ValueError("candidate contracts map to duplicate XML report names")
    family_counts: dict[str, dict[str, int]] = {}
    for kind, contracts in (("candidates", candidates), ("foundry_only", foundry_only)):
        for record in contracts.values():
            family = str(record["family"])
            counts = family_counts.setdefault(family, {"candidates": 0, "foundry_only": 0})
            counts[kind] += len(record["signatures"])  # type: ignore[arg-type]
    return {
        "schema": 1,
        "candidates": candidates,
        "foundry_only": foundry_only,
        "family_counts": dict(sorted(family_counts.items())),
        "accounting": {
            "candidate_classes": len(candidates),
            "candidate_signatures": sum(len(r["signatures"]) for r in candidates.values()),  # type: ignore[arg-type]
            "foundry_only_classes": len(foundry_only),
            "foundry_only_signatures": sum(len(r["signatures"]) for r in foundry_only.values()),  # type: ignore[arg-type]
            "total_executable_signatures": sum(len(r["signatures"]) for r in candidates.values())  # type: ignore[arg-type]
            + sum(len(r["signatures"]) for r in foundry_only.values()),  # type: ignore[arg-type]
        },
    }


def _current_inventory(env: dict[str, str]) -> dict[str, object]:
    listed = json.loads(run("forge", "test", "--list", "--json", env=env))
    if not isinstance(listed, dict):
        raise ValueError("forge test --list --json did not return an object")

    # Foundry 1.7's list JSON identifies the exact source/class/name inventory,
    # but strips parameter types. Resolve only those listed names against each
    # compiled methods table so XML identities remain canonical and overload-safe.
    typed_listed: dict[str, object] = {}
    for source_path, raw_contracts in listed.items():
        if not source_path.startswith("formal-verification/"):
            continue
        if not isinstance(raw_contracts, dict):
            raise ValueError(f"malformed contract inventory for {source_path}")
        typed_contracts: dict[str, list[str]] = {}
        for contract, raw_tests in raw_contracts.items():
            listed_names = typed_test_signatures(raw_tests)
            if not listed_names:
                continue
            methods = json.loads(run("forge", "inspect", contract, "methods", "--json", env=env))
            if not isinstance(methods, dict):
                raise ValueError(f"forge inspect returned malformed methods for {contract}")
            signatures = sorted(
                signature for signature in methods if signature.partition("(")[0] in set(listed_names)
            )
            resolved_names = {signature.partition("(")[0] for signature in signatures}
            if resolved_names != set(listed_names):
                raise ValueError(
                    f"typed method resolution mismatch for {contract}: "
                    f"listed={sorted(set(listed_names))!r}, resolved={sorted(resolved_names)!r}"
                )
            typed_contracts[contract] = signatures
        if typed_contracts:
            typed_listed[source_path] = typed_contracts
    return inventory_from_forge(typed_listed)


def current_inventory(env: dict[str, str]) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="usd8-formal-inventory-") as temporary:
        isolated_env = env.copy()
        isolated_env["FOUNDRY_OUT"] = str(Path(temporary) / "out")
        isolated_env["FOUNDRY_CACHE_PATH"] = str(Path(temporary) / "cache")
        return _current_inventory(isolated_env)


def approved_inventory() -> dict[str, object]:
    value = json.loads(APPROVED_INVENTORY.read_text())
    if not isinstance(value, dict):
        raise ValueError("approved campaign inventory is not an object")
    return value


def ensure_approved(live: dict[str, object]) -> None:
    approved = approved_inventory()
    if live != approved:
        raise ValueError(
            "compiled campaign inventory differs from approved-campaign-inventory.json; "
            "review forge test --list output and explicitly refresh the approval"
        )


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def int_attribute(element: ET.Element, name: str) -> int:
    raw = element.attrib.get(name)
    if raw is None or not raw.isdigit():
        raise ValueError(f"XML root has missing/non-integer {name!r}")
    return int(raw)


def parse_report(path: Path) -> dict[str, object]:
    root = ET.parse(path).getroot()
    if local_name(root.tag) not in {"testsuite", "testsuites"}:
        raise ValueError(f"unexpected XML root {root.tag!r}")
    cases = [element for element in root.iter() if local_name(element.tag) == "testcase"]
    failures = sum(
        1
        for case in cases
        if any(local_name(child.tag) == "failure" for child in case.iter() if child is not case)
    )
    errors = sum(
        1
        for case in cases
        if any(local_name(child.tag) == "error" for child in case.iter() if child is not case)
    )
    skipped = sum(
        1
        for case in cases
        if any(local_name(child.tag) == "skipped" for child in case.iter() if child is not case)
    )
    counters = {name: int_attribute(root, name) for name in ("tests", "failures", "errors")}
    root_skipped = int(root.attrib.get("skipped", "0"))
    if counters != {"tests": len(cases), "failures": failures, "errors": errors}:
        raise ValueError("XML aggregate counters do not match nested testcases")
    if root_skipped != skipped:
        raise ValueError("XML skipped counter does not match nested testcases")
    if failures or errors or skipped:
        raise ValueError("XML contains a failed, errored, or skipped nested testcase")

    signatures: list[tuple[str, str]] = []
    for case in cases:
        name = case.attrib.get("name")
        classname = case.attrib.get("classname")
        if not name or not classname:
            raise ValueError("XML testcase lacks name or classname")
        if name.startswith("test_"):
            signatures.append((classname, name))
    if len(signatures) != len(set(signatures)):
        raise ValueError("XML contains duplicate typed signatures within one report")
    return {"record": {**file_record(path), **counters, "skipped": root_skipped}, "signatures": signatures}


def expected_reports(inventory: dict[str, object]) -> dict[str, set[tuple[str, str]]]:
    expected: dict[str, set[tuple[str, str]]] = {}
    candidates = inventory["candidates"]
    assert isinstance(candidates, dict)
    for contract, raw in candidates.items():
        assert isinstance(raw, dict)
        expected[str(raw["report"])] = {(contract, sig) for sig in raw["signatures"]}  # type: ignore[misc]
    foundry = inventory["foundry_only"]
    assert isinstance(foundry, dict)
    smoke = foundry.get(SMOKE_CLASS)
    if not isinstance(smoke, dict) or smoke.get("solver_report") != SMOKE_REPORT:
        raise ValueError("approved inventory lacks the exact transient-storage smoke assignment")
    expected[SMOKE_REPORT] = {(SMOKE_CLASS, sig) for sig in smoke["signatures"]}  # type: ignore[misc]
    return expected


def audit_reports(reports_dir: Path, inventory: dict[str, object]) -> dict[str, object]:
    expected = expected_reports(inventory)
    actual_names = {path.name for path in reports_dir.glob("*.xml")}
    expected_names = set(expected)
    issues: list[str] = []
    if actual_names - expected_names:
        issues.append("unexpected root XML: " + ", ".join(sorted(actual_names - expected_names)))
    if expected_names - actual_names:
        issues.append("missing root XML: " + ", ".join(sorted(expected_names - actual_names)))

    records: list[dict[str, object]] = []
    passed: set[tuple[str, str]] = set()
    for name in sorted(actual_names & expected_names):
        try:
            parsed = parse_report(reports_dir / name)
            signatures = list(parsed["signatures"])  # type: ignore[arg-type]
            duplicate_across = passed.intersection(signatures)
            if duplicate_across:
                issues.append(f"{name}: duplicate signatures across XML reports: {sorted(duplicate_across)!r}")
            passed.update(signatures)
            actual = set(signatures)
            missing = expected[name] - actual
            stale = actual - expected[name]
            if missing:
                issues.append(f"{name}: missing signatures: {sorted(missing)!r}")
            if stale:
                issues.append(f"{name}: stale signatures: {sorted(stale)!r}")
            records.append(parsed["record"])  # type: ignore[arg-type]
        except (ET.ParseError, OSError, ValueError) as exc:
            issues.append(f"{name}: {exc}")

    candidates = inventory["candidates"]
    assert isinstance(candidates, dict)
    candidate_set = {
        (contract, signature)
        for contract, raw in candidates.items()
        for signature in raw["signatures"]  # type: ignore[index]
    }
    smoke_set = expected[SMOKE_REPORT]
    return {
        "ok": not issues,
        "issues": issues,
        "accepted_reports": sorted(records, key=lambda item: str(item["path"])),
        "xml_validated_candidate_signatures": sorted(passed & candidate_set),
        "xml_validated_auxiliary_signatures": sorted(passed & smoke_set),
    }


def source_records() -> list[dict[str, str | int]]:
    paths = sorted(
        {
            *ROOT.glob("src/**/*.sol"),
            *ROOT.glob("formal-verification/properties/**/*.sol"),
            *ROOT.glob("formal-verification/regressions/**/*.sol"),
            *ROOT.glob("formal-verification/scripts/*.py"),
            *ROOT.glob("formal-verification/scripts/*.sh"),
            *ROOT.glob("formal-verification/**/*.md"),
            *ROOT.glob("formal-verification/plans/**/*.json"),
            ROOT / "foundry.toml",
            APPROVED_INVENTORY,
        }
    )
    return [file_record(path) for path in paths]


def source_set_sha256() -> str:
    records = source_records()
    material = "\n".join(f"{record['path']}:{record['sha256']}" for record in records)
    return digest_bytes(material.encode())


def execution_toolchain(env: dict[str, str]) -> dict[str, str]:
    return {
        "forge": run("forge", "--version").splitlines()[0],
        "kontrol": run("kontrol", "version", env=env),
    }


def verified_execution_record(
    env: dict[str, str],
    inventory: dict[str, object],
    audit: dict[str, object],
    execution_record_path: Path = EXECUTION_RECORD,
) -> dict[str, object]:
    try:
        record = json.loads(execution_record_path.read_text())
    except FileNotFoundError as exc:
        raise ValueError(
            "runner execution record is missing; XML schema validation alone is not solver provenance"
        ) from exc
    if not isinstance(record, dict):
        raise ValueError("runner execution record root is not an object")
    required_keys = {
        "schema",
        "started_at_utc",
        "completed_at_utc",
        "source_set_sha256",
        "runner",
        "toolchain",
        "solver_runs",
        "foundry_runs",
        "final_gates",
    }
    if set(record) != required_keys or record.get("schema") != 1:
        raise ValueError("runner execution record has an unexpected schema")
    for key in ("started_at_utc", "completed_at_utc"):
        value = record.get(key)
        if not isinstance(value, str) or not value:
            raise ValueError(f"runner execution record lacks {key}")
        try:
            datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as exc:
            raise ValueError(f"runner execution record has invalid {key}") from exc
    if record["source_set_sha256"] != source_set_sha256():
        raise ValueError("runner execution record source-set digest is stale")
    if record["runner"] != file_record(FORMAL / "scripts" / "run_campaign.sh"):
        raise ValueError("runner execution record does not bind the current campaign runner")
    if record["toolchain"] != execution_toolchain(env):
        raise ValueError("runner execution record toolchain differs from the current toolchain")

    report_hashes = {
        Path(str(item["path"])).name: str(item["sha256"])
        for item in audit["accepted_reports"]  # type: ignore[union-attr]
    }
    candidates = inventory["candidates"]
    foundry_only = inventory["foundry_only"]
    assert isinstance(candidates, dict) and isinstance(foundry_only, dict)
    expected_solver_runs = [
        {
            "contract": contract,
            "match_test": f"{contract}.test_.*",
            "report": str(raw["report"]),
            "report_sha256": report_hashes[str(raw["report"])],
            "schedule": "CANCUN",
            "exit_code": 0,
        }
        for contract, raw in sorted(candidates.items())
        if isinstance(raw, dict)
    ]
    smoke = foundry_only.get(SMOKE_CLASS)
    if not isinstance(smoke, dict):
        raise ValueError("approved inventory lacks the transient-storage smoke class")
    smoke_signatures = smoke.get("signatures")
    if not isinstance(smoke_signatures, list) or len(smoke_signatures) != 1:
        raise ValueError("approved transient-storage smoke inventory is not singular")
    expected_solver_runs.append(
        {
            "contract": SMOKE_CLASS,
            "match_test": f"{SMOKE_CLASS}.{smoke_signatures[0]}",
            "report": SMOKE_REPORT,
            "report_sha256": report_hashes[SMOKE_REPORT],
            "schedule": "CANCUN",
            "exit_code": 0,
        }
    )
    expected_solver_runs.sort(key=lambda item: str(item["report"]))
    actual_solver_runs = record["solver_runs"]
    if not isinstance(actual_solver_runs, list) or sorted(
        actual_solver_runs,
        key=lambda item: str(item.get("report", "")) if isinstance(item, dict) else "",
    ) != expected_solver_runs:
        raise ValueError("runner execution record does not contain every exact successful solver command/report")

    expected_foundry_runs = [
        {
            "contract": contract,
            "command": f"forge test --match-contract {contract}",
            "exit_code": 0,
        }
        for contract in sorted(foundry_only)
    ]
    if record["foundry_runs"] != expected_foundry_runs:
        raise ValueError("runner execution record does not contain every approved Foundry-only class gate")
    expected_final_gates = [
        {"command": "forge test -q", "exit_code": 0},
        {"command": "forge fmt --check", "exit_code": 0},
        {"command": "git diff --check", "exit_code": 0},
    ]
    if record["final_gates"] != expected_final_gates:
        raise ValueError("runner execution record lacks exact successful final gates")
    return record


def production_artifacts(env: dict[str, str]) -> dict[str, object]:
    result: dict[str, object] = {}
    for name, target in PRODUCTION_TARGETS.items():
        abi = json.loads(run("forge", "inspect", target, "abi", "--json", env=env))
        creation = run("forge", "inspect", target, "bytecode", env=env).lower()
        runtime = run("forge", "inspect", target, "deployedBytecode", env=env).lower()
        metadata = json.loads(run("forge", "inspect", target, "metadata", "--json", env=env))
        closure_paths = sorted(metadata.get("sources", {}))
        closure = [file_record(ROOT / path) for path in closure_paths]
        closure_digest = digest_bytes(
            "\n".join(f"{r['path']}:{r['sha256']}" for r in closure).encode()
        )
        creation_bytes = bytes.fromhex(creation.removeprefix("0x"))
        runtime_bytes = bytes.fromhex(runtime.removeprefix("0x"))
        result[name] = {
            "target": target,
            "source_closure_sha256": closure_digest,
            "source_closure": closure,
            "canonical_abi": abi,
            "abi_sha256": digest_bytes(canonical_json(abi)),
            "creation_bytecode": creation,
            "creation_sha256": digest_bytes(creation_bytes),
            "runtime_bytecode": runtime,
            "runtime_sha256": digest_bytes(runtime_bytes),
        }
    return result


def manifest_payload(env: dict[str, str], inventory: dict[str, object], audit: dict[str, object]) -> dict[str, object]:
    sources = source_records()
    forge_config = json.loads(run("forge", "config", "--json", env=env))
    build_info = [
        file_record(path)
        for path in sorted((FORMAL / "out" / "build-info").glob("*.json"))
    ]
    execution = verified_execution_record(env, inventory, audit)
    return {
        "schema": 2,
        "git_head": run("git", "rev-parse", "HEAD"),
        "toolchain": {
            **execution_toolchain(env),
            "solc": str(forge_config.get("solc")),
        },
        "configuration": {
            "foundry_profile": "kontrol",
            "foundry_toml": file_record(ROOT / "foundry.toml"),
            "effective_forge_config": forge_config,
            "effective_forge_config_sha256": digest_bytes(canonical_json(forge_config)),
        },
        "approved_inventory": inventory,
        "approved_inventory_record": file_record(APPROVED_INVENTORY),
        "source_set_sha256": source_set_sha256(),
        "sources": sources,
        "build_info": build_info,
        "campaign_runner": file_record(FORMAL / "scripts" / "run_campaign.sh"),
        "campaign_execution": execution,
        "production_artifacts": production_artifacts(env),
        "accepted_reports": audit["accepted_reports"],
        "solver_passed_candidate_signatures": audit["xml_validated_candidate_signatures"],
        "solver_passed_auxiliary_signatures": audit["xml_validated_auxiliary_signatures"],
        "acceptance": "Exact XML schema/signatures are accepted as solver evidence only with the runner-produced command/exit/snapshot/toolchain/report-hash execution record.",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--write-approved-inventory",
        action="store_true",
        help="explicitly replace the frozen approval from current forge test --list JSON",
    )
    parser.add_argument(
        "--check-approved-inventory",
        action="store_true",
        help="check the live Forge candidate inventory without requiring solver XML reports",
    )
    parser.add_argument(
        "--print-source-set-sha256",
        action="store_true",
        help="print the canonical durable campaign source-set digest without compiling",
    )
    args = parser.parse_args()
    selected_modes = sum(
        bool(value)
        for value in (
            args.write_approved_inventory,
            args.check_approved_inventory,
            args.print_source_set_sha256,
        )
    )
    if selected_modes > 1:
        parser.error("inventory write/check and source-digest modes are mutually exclusive")
    if args.print_source_set_sha256:
        print(source_set_sha256())
        return 0
    env = campaign_env()
    live = current_inventory(env)
    if args.write_approved_inventory:
        APPROVED_INVENTORY.write_text(json.dumps(live, indent=2, sort_keys=True) + "\n")
        print(APPROVED_INVENTORY.relative_to(ROOT))
        return 0
    ensure_approved(live)
    if args.check_approved_inventory:
        accounting = live["accounting"]
        assert isinstance(accounting, dict)
        print(
            "approved campaign inventory unchanged: "
            f"classes={accounting['candidate_classes']}, "
            f"candidates={accounting['candidate_signatures']}"
        )
        return 0
    audit = audit_reports(REPORTS, live)
    if not audit["ok"]:
        raise SystemExit("report audit failed:\n- " + "\n- ".join(audit["issues"]))  # type: ignore[arg-type]
    manifest = manifest_payload(env, live, audit)
    manifest["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
    OUTPUT.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(OUTPUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
