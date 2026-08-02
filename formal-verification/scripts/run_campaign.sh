#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
  # shellcheck disable=SC1091
  source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
export PATH="$HOME/.nix-profile/bin:$PATH"
export FOUNDRY_PROFILE=kontrol
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
unset FOUNDRY_TEST

REPORTS="formal-verification/reports"
PROOFS="formal-verification/out/proofs"
APPROVED="formal-verification/approved-campaign-inventory.json"
EXECUTION_RECORD="formal-verification/cache/campaign-execution.json"
KONTROL_WORKERS="${KONTROL_WORKERS:-4}"
CAMPAIGN_START_AT="${CAMPAIGN_START_AT:-}"
MODE=run
case "${1:-}" in
  "") ;;
  --dry-run) MODE=dry-run ;;
  --list) MODE=list ;;
  *) echo "usage: $0 [--dry-run|--list]" >&2; exit 2 ;;
esac
if [[ -n "$CAMPAIGN_START_AT" ]]; then
  echo "CAMPAIGN_START_AT is disabled: partial resume cannot authenticate skipped XMLs to the current snapshot" >&2
  exit 2
fi
if [[ ! -f "$APPROVED" ]]; then
  echo "missing frozen approved inventory: $APPROVED" >&2
  exit 2
fi
CAMPAIGN_STARTED_AT_UTC=""
if [[ "$MODE" == run ]]; then
  CAMPAIGN_STARTED_AT_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
fi

# One clean aggregate XML per compiled Kontrol class. This mapping is checked
# against the frozen approved inventory and the current compiled ABI below.
CAMPAIGN_GROUPS=(
  'USD8ERC20KontrolTest|usd8-erc20-kontrol.xml'
  'USD8PermitKontrolTest|usd8-permit-kontrol.xml'
  'USD8SweepKontrolTest|usd8-sweep-kontrol.xml'
  'USD8UpgradeKontrolTest|usd8-upgrade-kontrol.xml'
  'USD8TokenKontrolTest|usd8-token-kontrol.xml'
  'USD8EventsKontrolTest|usd8-events-kontrol.xml'
  'TreasuryKontrolTest|treasury-base-kontrol.xml'
  'TreasuryAclPauseKontrolTest|treasury-acl-pause-kontrol.xml'
  'TreasuryInitUpgradeKontrolTest|treasury-init-upgrade-kontrol.xml'
  'TreasurySweepKontrolTest|treasury-sweep-kontrol.xml'
  'TreasuryStrategySetKontrolTest|treasury-strategy-set-kontrol.xml'
  'TreasuryReceiverSetKontrolTest|treasury-receiver-set-kontrol.xml'
  'TreasuryStrategyFlowsKontrolTest|treasury-strategy-flows-kontrol.xml'
  'TreasuryReserveAdversarialKontrolTest|treasury-reserve-adversarial-kontrol.xml'
  'TreasuryLiquidityWalkKontrolTest|treasury-liquidity-walk-kontrol.xml'
  'TreasuryHarvestDirectKontrolTest|treasury-harvest-direct-kontrol.xml'
  'TreasuryHarvestHooksKontrolTest|treasury-harvest-hooks-kontrol.xml'
  'TreasuryEventsKontrolTest|treasury-events-kontrol.xml'
  'DefiInsuranceConfigKontrolTest|defi-insurance-config-kontrol.xml'
  'DefiInsuranceClaimLifecycleKontrolTest|defi-insurance-claim-lifecycle-kontrol.xml'
  'DefiInsuranceSettlementKontrolTest|defi-insurance-settlement-kontrol.xml'
  'DefiInsuranceFinalizationKontrolTest|defi-insurance-finalization-kontrol.xml'
  'DefiInsuranceAdminKontrolTest|defi-insurance-admin-kontrol.xml'
  'DefiInsuranceEventsKontrolTest|defi-insurance-events-kontrol.xml'
  'SingleAssetCoverPoolERC4626KontrolTest|single-asset-cover-pool-erc4626-kontrol.xml'
  'SingleAssetCoverPoolExitKontrolTest|single-asset-cover-pool-exit-kontrol.xml'
  'SingleAssetCoverPoolRewardsKontrolTest|single-asset-cover-pool-rewards-kontrol.xml'
  'SingleAssetCoverPoolSweepKontrolTest|single-asset-cover-pool-sweep-kontrol.xml'
  'SingleAssetCoverPoolPayoutKontrolTest|single-asset-cover-pool-payout-kontrol.xml'
  'SingleAssetCoverPoolErrorsKontrolTest|single-asset-cover-pool-errors-kontrol.xml'
  'SingleAssetCoverPoolEventsKontrolTest|single-asset-cover-pool-events-kontrol.xml'
  'RegistryAccessKontrolTest|registry-access-kontrol.xml'
  'RegistryTopologyKontrolTest|registry-topology-kontrol.xml'
  'RegistryModuleScoringKontrolTest|registry-module-scoring-kontrol.xml'
  'RegistryTimingKontrolTest|registry-timing-kontrol.xml'
  'RegistryUpgradeKontrolTest|registry-upgrade-kontrol.xml'
  'ERC4626StrategyConstructionViewsKontrolTest|erc4626-strategy-construction-views-kontrol.xml'
  'ERC4626StrategyDeployWithdrawKontrolTest|erc4626-strategy-deploy-withdraw-kontrol.xml'
  'ERC4626StrategySwapKontrolTest|erc4626-strategy-swap-kontrol.xml'
  'ERC4626StrategySweepKontrolTest|erc4626-strategy-sweep-kontrol.xml'
  'ERC4626StrategyExternalModesKontrolTest|erc4626-strategy-external-modes-kontrol.xml'
  'ERC4626StrategySwapModesKontrolTest|erc4626-strategy-swap-modes-kontrol.xml'
  'USD8PriceOracleKontrolTest|usd8-price-oracle-kontrol.xml'
  'USD8SavingsAdapterCoreKontrolTest|usd8-savings-adapter-core-kontrol.xml'
  'USD8SavingsAdapterProfitKontrolTest|usd8-savings-adapter-profit-kontrol.xml'
  'USD8SavingsBootstrapKontrolTest|usd8-savings-bootstrap-kontrol.xml'
)

snapshot_digest() {
  python3 formal-verification/scripts/generate_campaign_manifest.py --print-source-set-sha256
}

CAMPAIGN_INPUT_DIGEST="$(snapshot_digest)"
GROUP_FILE="$(mktemp)"
FOUNDRY_GATE_FILE="$(mktemp)"
INVENTORY_FILE="$(mktemp)"
EXECUTION_LOG="$(mktemp)"
trap 'rm -f "$GROUP_FILE" "$FOUNDRY_GATE_FILE" "$INVENTORY_FILE" "$EXECUTION_LOG"' EXIT
printf '%s\n' "${CAMPAIGN_GROUPS[@]}" > "$GROUP_FILE"

if [[ "$MODE" == run ]]; then
  mkdir -p "$REPORTS"
  rm -f "$REPORTS"/*.xml "$REPORTS/campaign-manifest.json"
  rm -f "$EXECUTION_RECORD"
  find formal-verification/out -mindepth 1 -maxdepth 1 ! -name proofs -exec rm -rf {} +
  kontrol build --foundry-project-root . --regen
fi

# Resolve the live typed inventory once through the canonical generator, then
# derive every solver report and Foundry-only class gate from the durable review.
python3 formal-verification/scripts/generate_campaign_manifest.py --check-approved-inventory
python3 - "$APPROVED" "$GROUP_FILE" "$FOUNDRY_GATE_FILE" "$INVENTORY_FILE" <<'PY'
import json
from pathlib import Path
import sys

approved_path, group_path, foundry_gate_path, output_path = map(Path, sys.argv[1:])
approved = json.loads(approved_path.read_text())
if approved.get("schema") != 1:
    raise SystemExit("approved campaign inventory has an unsupported schema")
expected_accounting = {
    "candidate_classes": 46,
    "candidate_signatures": 841,
    "foundry_only_classes": 9,
    "foundry_only_signatures": 74,
    "total_executable_signatures": 915,
}
if approved.get("accounting") != expected_accounting:
    raise SystemExit(f"approved campaign accounting mismatch: {approved.get('accounting')!r}")
candidates = approved.get("candidates")
foundry_only = approved.get("foundry_only")
if not isinstance(candidates, dict) or not isinstance(foundry_only, dict):
    raise SystemExit("approved campaign inventory lacks candidate/foundry partitions")

groups = {}
reports = set()
for line in group_path.read_text().splitlines():
    if not line:
        continue
    contract, report = line.split("|", 1)
    if contract in groups or report in reports:
        raise SystemExit(f"duplicate campaign class/report: {line}")
    groups[contract] = report
    reports.add(report)
if set(groups) != set(candidates):
    raise SystemExit(
        "campaign class mismatch: missing=" + repr(sorted(set(candidates) - set(groups)))
        + " extra=" + repr(sorted(set(groups) - set(candidates)))
    )
for contract, raw in candidates.items():
    if not isinstance(raw, dict) or groups[contract] != raw.get("report"):
        raise SystemExit(f"campaign report mismatch for {contract}")
    signatures = raw.get("signatures")
    if not isinstance(signatures, list) or not signatures:
        raise SystemExit(f"empty/malformed candidate signatures for {contract}")

foundry_lines = []
for contract, raw in sorted(foundry_only.items()):
    if not isinstance(raw, dict):
        raise SystemExit(f"malformed Foundry-only inventory for {contract}")
    signatures = raw.get("signatures")
    if not isinstance(signatures, list) or not signatures:
        raise SystemExit(f"empty/malformed Foundry-only signatures for {contract}")
    foundry_lines.append(f"{contract}|{len(signatures)}")

output_path.write_text(json.dumps(candidates, indent=2, sort_keys=True) + "\n")
foundry_gate_path.write_text("\n".join(foundry_lines) + "\n")
print("Kontrol campaign inventory: 841 exact typed signatures across 46 classes")
print("Foundry-only inventory: 74 conventional signatures across 9 classes")
PY

if [[ "$MODE" == list ]]; then
  python3 - "$INVENTORY_FILE" <<'PY'
import json, sys
inventory = json.load(open(sys.argv[1]))
for contract, row in inventory.items():
    for signature in row["signatures"]:
        print(f"{contract}.{signature} -> {row['report']}")
PY
  printf 'Foundry-only conventional definitions: 74 across 9 classes; 7 camel-named auxiliary checks run in the full Forge gate\n'
  exit 0
fi

prove_group() {
  local contract="$1"
  local report="$2"
  local prove_args=(
    --foundry-project-root .
    --match-test "$contract.test_.*"
    --schedule CANCUN
    --reinit
    --workers "$KONTROL_WORKERS"
  )
  if [[ "$KONTROL_WORKERS" == "1" ]]; then
    prove_args+=(--force-sequential)
  fi
  prove_args+=(
    --max-iterations 50000
    --xml-test-report
    --xml-test-report-name "$REPORTS/$report"
  )
  if [[ "$MODE" == dry-run ]]; then
    printf 'kontrol prove --match-test %q --xml-test-report-name %q\n' \
      "$contract.test_.*" "$REPORTS/$report"
    return
  fi
  rm -rf "$PROOFS"
  if ! kontrol prove "${prove_args[@]}"; then
    echo "Parallel Kontrol aggregate failed; retrying clean and sequential: $contract ($report)" >&2
    rm -rf "$PROOFS"
    rm -f "$REPORTS/$report"
    # A Kore server-start race can orphan a booster after its parent exits.
    # Scope cleanup to this project's absolute generated definition.
    pkill -f "kore-rpc-booster $ROOT/formal-verification/out/kompiled/definition.kore" 2>/dev/null || true
    local retry_args=(
      --foundry-project-root .
      --match-test "$contract.test_.*"
      --schedule CANCUN
      --reinit
      --workers 1
      --force-sequential
      --max-iterations 50000
      --xml-test-report
      --xml-test-report-name "$REPORTS/$report"
    )
    if ! kontrol prove "${retry_args[@]}"; then
      echo "Kontrol proof group failed after clean sequential retry: $contract ($report)" >&2
      return 1
    fi
  fi

  # A successful command is insufficient: the aggregate must be clean and must
  # contain exactly this class's approved typed test_* inventory, once each.
  python3 - "$INVENTORY_FILE" "$contract" "$REPORTS/$report" <<'PY'
import json, sys
import xml.etree.ElementTree as ET
inventory_path, contract, report = sys.argv[1:]
expected = set(json.load(open(inventory_path))[contract]["signatures"])
root = ET.parse(report).getroot()
for key in ("failures", "errors", "skipped"):
    if int(root.attrib.get(key, 0)):
        raise SystemExit(f"unclean report {report}: {key}={root.attrib.get(key)}")
actual_list = [
    case.attrib["name"] for case in root.iter("testcase")
    if case.attrib.get("classname") == contract and case.attrib.get("name", "").startswith("test_")
]
actual = set(actual_list)
if len(actual_list) != len(actual) or actual != expected:
    raise SystemExit(
        f"report inventory mismatch for {contract}: duplicates={len(actual_list)-len(actual)} "
        f"missing={sorted(expected-actual)} stale={sorted(actual-expected)}"
    )
PY
  local report_sha256
  report_sha256="$(shasum -a 256 "$REPORTS/$report" | cut -d' ' -f1)"
  printf 'solver\t%s\t%s\t%s\t%s\t%s\n' \
    "$contract" "$contract.test_.*" "$report" CANCUN "$report_sha256" >> "$EXECUTION_LOG"
}

for group in "${CAMPAIGN_GROUPS[@]}"; do
  IFS='|' read -r contract report <<< "$group"
  prove_group "$contract" "$report"
done

if [[ "$MODE" == dry-run ]]; then
  printf 'kontrol prove --match-test %q --xml-test-report-name %q\n' \
    'KontrolTransientStorageSmokeTest.test_transientStorageRoundTrip()' \
    "$REPORTS/transient-storage-smoke-kontrol.xml"
else
  rm -rf "$PROOFS"
  kontrol prove \
    --foundry-project-root . \
    --match-test 'KontrolTransientStorageSmokeTest.test_transientStorageRoundTrip()' \
    --schedule CANCUN \
    --reinit \
    --workers 1 \
    --force-sequential \
    --xml-test-report \
    --xml-test-report-name "$REPORTS/transient-storage-smoke-kontrol.xml"
  python3 - "$REPORTS/transient-storage-smoke-kontrol.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for key in ("failures", "errors", "skipped"):
    if int(root.attrib.get(key, 0)):
        raise SystemExit(f"unclean transient-storage report: {key}={root.attrib.get(key)}")
cases = [
    (case.attrib.get("classname"), case.attrib.get("name"))
    for case in root.iter("testcase") if case.attrib.get("name", "").startswith("test_")
]
expected = [("KontrolTransientStorageSmokeTest", "test_transientStorageRoundTrip()")]
if cases != expected:
    raise SystemExit(f"transient-storage report inventory mismatch: {cases!r}")
PY
  smoke_sha256="$(shasum -a 256 "$REPORTS/transient-storage-smoke-kontrol.xml" | cut -d' ' -f1)"
  printf 'solver\t%s\t%s\t%s\t%s\t%s\n' \
    KontrolTransientStorageSmokeTest \
    'KontrolTransientStorageSmokeTest.test_transientStorageRoundTrip()' \
    transient-storage-smoke-kontrol.xml CANCUN "$smoke_sha256" >> "$EXECUTION_LOG"
  rm -rf "$PROOFS"
fi

foundry_definitions=0
foundry_classes=0
while IFS='|' read -r contract definitions; do
  [[ -n "$contract" ]] || continue
  foundry_classes=$((foundry_classes + 1))
  foundry_definitions=$((foundry_definitions + definitions))
  if [[ "$MODE" == dry-run ]]; then
    printf 'forge test --match-contract %q\n' "$contract"
  else
    forge test --match-contract "$contract"
    printf 'foundry\t%s\n' "$contract" >> "$EXECUTION_LOG"
  fi
done < "$FOUNDRY_GATE_FILE"
if [[ "$foundry_definitions" != 74 || "$foundry_classes" != 9 ]]; then
  echo "Foundry-only accounting mismatch: $foundry_definitions definitions / $foundry_classes classes; expected 74 / 9" >&2
  exit 2
fi

if [[ "$MODE" == dry-run ]]; then
  printf 'Validated dry run: 841 Kontrol candidates / 46 reports; 74 Foundry-only definitions / 9 classes; 7 auxiliary camel-named checks in full Forge gate\n'
  exit 0
fi

forge test -q
forge fmt --check
git diff --check
if [[ "$(snapshot_digest)" != "$CAMPAIGN_INPUT_DIGEST" ]]; then
  echo "formal campaign inputs changed while proofs were running" >&2
  exit 3
fi

# Record the exact successful commands and report hashes. The rich generator
# and validator reject XML-only evidence when this runner record is absent.
python3 - "$EXECUTION_LOG" "$EXECUTION_RECORD" "$CAMPAIGN_INPUT_DIGEST" "$CAMPAIGN_STARTED_AT_UTC" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

log_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
snapshot, started_at = sys.argv[3:5]
root = Path.cwd()

def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()

def file_record(path: Path) -> dict[str, str | int]:
    data = path.read_bytes()
    return {
        "path": str(path.relative_to(root)),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }

solver_runs = []
foundry_runs = []
for line in log_path.read_text().splitlines():
    parts = line.split("\t")
    if parts[0] == "solver" and len(parts) == 6:
        _, contract, match_test, report, schedule, report_sha256 = parts
        solver_runs.append({
            "contract": contract,
            "match_test": match_test,
            "report": report,
            "report_sha256": report_sha256,
            "schedule": schedule,
            "exit_code": 0,
        })
    elif parts[0] == "foundry" and len(parts) == 2:
        contract = parts[1]
        foundry_runs.append({
            "contract": contract,
            "command": f"forge test --match-contract {contract}",
            "exit_code": 0,
        })
    else:
        raise SystemExit(f"malformed campaign execution log row: {line!r}")

record = {
    "schema": 1,
    "started_at_utc": started_at,
    "completed_at_utc": datetime.now(timezone.utc).isoformat(),
    "source_set_sha256": snapshot,
    "runner": file_record(root / "formal-verification/scripts/run_campaign.sh"),
    "toolchain": {
        "forge": run("forge", "--version").splitlines()[0],
        "kontrol": run("kontrol", "version"),
    },
    "solver_runs": sorted(solver_runs, key=lambda item: item["report"]),
    "foundry_runs": sorted(foundry_runs, key=lambda item: item["contract"]),
    "final_gates": [
        {"command": "forge test -q", "exit_code": 0},
        {"command": "forge fmt --check", "exit_code": 0},
        {"command": "git diff --check", "exit_code": 0},
    ],
}
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
python3 formal-verification/scripts/generate_campaign_manifest.py
python3 formal-verification/scripts/validate_reports.py
