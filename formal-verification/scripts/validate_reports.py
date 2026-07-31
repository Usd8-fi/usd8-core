#!/usr/bin/env python3
"""Validate campaign inventory, exact XML evidence, and manifest provenance."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import tempfile
import xml.etree.ElementTree as ET

from generate_campaign_manifest import (
    OUTPUT,
    REPORTS,
    SMOKE_CLASS,
    SMOKE_REPORT,
    approved_inventory,
    audit_reports,
    campaign_env,
    current_inventory,
    manifest_payload,
    verified_execution_record,
)


def manifest_matches(
    env: dict[str, str], inventory: dict[str, object], audit: dict[str, object]
) -> tuple[bool, str | None]:
    if not OUTPUT.exists():
        return False, "campaign-manifest.json is missing"
    try:
        actual = json.loads(OUTPUT.read_text())
        if not isinstance(actual, dict):
            return False, "campaign manifest root is not an object"
        generated_at = actual.pop("generated_at_utc", None)
        if not isinstance(generated_at, str) or not generated_at:
            return False, "campaign manifest lacks generated_at_utc"
        expected = manifest_payload(env, inventory, audit)
        if actual != expected:
            return False, "campaign manifest differs from the current authenticated snapshot"
        return True, None
    except (OSError, ValueError, json.JSONDecodeError, KeyError) as exc:
        return False, str(exc)


def _write_xml(path: Path, cases: list[tuple[str, str, str | None]]) -> None:
    root = ET.Element("testsuites")
    suite = ET.SubElement(root, "testsuite")
    failures = errors = skipped = 0
    for classname, name, outcome in cases:
        case = ET.SubElement(suite, "testcase", classname=classname, name=name)
        if outcome:
            ET.SubElement(case, outcome)
            failures += outcome == "failure"
            errors += outcome == "error"
            skipped += outcome == "skipped"
    root.attrib.update(
        tests=str(len(cases)), failures=str(failures), errors=str(errors), skipped=str(skipped)
    )
    ET.ElementTree(root).write(path, encoding="unicode")


def self_test() -> int:
    inventory: dict[str, object] = {
        "schema": 1,
        "candidates": {
            "AlphaKontrolTest": {
                "source": "formal-verification/properties/Alpha.k.sol",
                "family": "infrastructure",
                "report": "alpha-kontrol.xml",
                "signatures": ["test_a(uint256)", "test_b()"],
            }
        },
        "foundry_only": {
            SMOKE_CLASS: {
                "source": "formal-verification/properties/TransientStorageSmoke.t.sol",
                "family": "infrastructure",
                "solver_report": SMOKE_REPORT,
                "signatures": ["test_transientStorageRoundTrip()"],
            }
        },
        "family_counts": {"infrastructure": {"candidates": 2, "foundry_only": 1}},
        "accounting": {
            "candidate_classes": 1,
            "candidate_signatures": 2,
            "foundry_only_classes": 1,
            "foundry_only_signatures": 1,
            "total_executable_signatures": 3,
        },
    }
    # Keep fixtures below ROOT because report records intentionally reject paths
    # outside the authenticated repository.
    with tempfile.TemporaryDirectory(dir=REPORTS.parent) as raw:
        directory = Path(raw)
        empty = audit_reports(directory, inventory)
        assert not empty["ok"] and any("missing root XML" in issue for issue in empty["issues"])

        _write_xml(
            directory / "alpha-kontrol.xml",
            [
                ("AlphaKontrolTest", "test_a(uint256)", None),
                ("AlphaKontrolTest", "test_b()", None),
            ],
        )
        _write_xml(
            directory / SMOKE_REPORT,
            [(SMOKE_CLASS, "test_transientStorageRoundTrip()", None)],
        )
        clean = audit_reports(directory, inventory)
        assert clean["ok"]
        candidate_signatures = clean["xml_validated_candidate_signatures"]
        auxiliary_signatures = clean["xml_validated_auxiliary_signatures"]
        assert isinstance(candidate_signatures, list) and len(candidate_signatures) == 2
        assert isinstance(auxiliary_signatures, list) and len(auxiliary_signatures) == 1
        assert "solver_passed_candidate_signatures" not in clean
        try:
            verified_execution_record(campaign_env(), inventory, clean, directory / "missing-execution.json")
        except ValueError as exc:
            assert "XML schema validation alone is not solver provenance" in str(exc)
        else:
            raise AssertionError("synthetic XML was accepted without a runner execution record")

        _write_xml(
            directory / "alpha-kontrol.xml",
            [
                ("AlphaKontrolTest", "test_a(uint256)", None),
                ("AlphaKontrolTest", "test_a(uint256)", None),
                ("AlphaKontrolTest", "test_b()", None),
            ],
        )
        duplicate = audit_reports(directory, inventory)
        assert not duplicate["ok"] and any("duplicate" in issue for issue in duplicate["issues"])

        _write_xml(
            directory / "alpha-kontrol.xml",
            [
                ("AlphaKontrolTest", "test_a(uint256)", "error"),
                ("AlphaKontrolTest", "test_b()", None),
            ],
        )
        nested_error = audit_reports(directory, inventory)
        assert not nested_error["ok"] and any("errored" in issue for issue in nested_error["issues"])

        _write_xml(
            directory / "alpha-kontrol.xml",
            [
                ("AlphaKontrolTest", "test_a(uint256)", None),
                ("AlphaKontrolTest", "test_stale()", None),
            ],
        )
        stale_missing = audit_reports(directory, inventory)
        assert not stale_missing["ok"]
        assert any("missing signatures" in issue for issue in stale_missing["issues"])
        assert any("stale signatures" in issue for issue in stale_missing["issues"])

        (directory / "unexpected.xml").write_text("<not-junit />")
        unexpected = audit_reports(directory, inventory)
        assert not unexpected["ok"] and any("unexpected root XML" in issue for issue in unexpected["issues"])
    print("synthetic report audit self-test: passed")
    return 0


def main() -> int:
    env = campaign_env()
    issues: list[str] = []
    try:
        live = current_inventory(env)
        approved = approved_inventory()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(json.dumps({"all_passed": False, "issues": [str(exc)]}, indent=2, sort_keys=True))
        return 1

    inventory_approved = live == approved
    if not inventory_approved:
        issues.append("compiled inventory differs from frozen approved inventory")
    audit = audit_reports(REPORTS, approved)
    issues.extend(str(issue) for issue in audit["issues"])  # type: ignore[arg-type]

    execution_ok = False
    if inventory_approved and audit["ok"]:
        try:
            verified_execution_record(env, live, audit)
            execution_ok = True
        except (OSError, ValueError, KeyError) as exc:
            issues.append(str(exc))

    manifest_ok = False
    if execution_ok:
        manifest_ok, manifest_issue = manifest_matches(env, live, audit)
        if manifest_issue:
            issues.append(manifest_issue)
    else:
        issues.append("campaign manifest cannot be accepted until inventory, XML, and runner execution are exact")

    accounting = live.get("accounting", {})
    checks = {
        "approved_compiled_inventory": inventory_approved,
        "exact_root_report_set": not any(
            issue.startswith(("unexpected root XML", "missing root XML"))
            for issue in audit["issues"]  # type: ignore[union-attr]
        ),
        "exact_clean_xml_signatures": bool(audit["ok"]),
        "runner_execution_record": execution_ok,
        "campaign_manifest": manifest_ok,
    }
    result = {
        "accounting": accounting,
        "xml_validated_candidate_signatures": len(audit["xml_validated_candidate_signatures"]),  # type: ignore[arg-type]
        "xml_validated_auxiliary_signatures": len(audit["xml_validated_auxiliary_signatures"]),  # type: ignore[arg-type]
        "checks": checks,
        "all_passed": all(checks.values()),
        "issues": issues,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["all_passed"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    sys.exit(self_test() if arguments.self_test else main())
