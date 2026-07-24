#!/usr/bin/env python3
"""Real-Sepolia preflight for the staged USD8 incident-open exercise.

This independently checks live chain inputs. It does not create a TEE signature or
replace Nitro attestation/KMS verification.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

RPCS = (
    "https://sepolia.drpc.org",
    "https://ethereum-sepolia-rpc.publicnode.com",
)
THRESHOLD_BPS = 2_000
BPS = 10_000
MAX_BLOCK_BALANCE_CHECKS = 128


def run(*args: str) -> str:
    completed = subprocess.run(
        args,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def first_int(output: str) -> int:
    token = output.split()[0]
    return int(token, 16) if token.startswith("0x") else int(token)


def call(rpc: str, target: str, signature: str, *args: str, block: int | None = None) -> str:
    command = ["cast", "call", target, signature, *args]
    if block is not None:
        command.extend(("--block", str(block)))
    command.extend(("--rpc-url", rpc))
    return run(*command)


def finalized_block(rpc: str) -> int:
    envelope = json.loads(run("cast", "block", "finalized", "--json", "--rpc-url", rpc))
    block = envelope.get("data", envelope)
    return int(block["number"], 16)


def oracle_answer(rpc: str, oracle: str, block: int) -> int:
    output = call(
        rpc,
        oracle,
        "latestRoundData()(uint80,int256,uint256,uint256,uint80)",
        block=block,
    )
    return first_int(output.splitlines()[1])


def tuple_values(output: str) -> tuple[int, ...]:
    return tuple(first_int(line) for line in output.splitlines())


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    deployment = json.loads((root / "deployments/sepolia/deployment.json").read_text())
    exercise = json.loads((root / "deployments/sepolia/incident-simulation.json").read_text())

    contracts = deployment["contracts"]
    claimant = exercise["claimantPreparation"]["account"]
    insured = exercise["insuredToken"]["address"]
    oracle = exercise["oracle"]["address"]
    pre_block = int(exercise["preDropReference"]["blockNumber"])
    reference = exercise["futureOpenRequest"]["referenceBlockSelection"][
        "candidateReferenceBlock"
    ]

    finalized = [finalized_block(rpc) for rpc in RPCS]
    if any(block < reference for block in finalized):
        raise RuntimeError(f"reference block {reference} is not finalized on both RPCs: {finalized}")

    rpc = RPCS[0]
    params = tuple_values(
        call(
            rpc,
            contracts["defiInsurance"],
            "settlementParams()(uint64,uint64,uint64)",
        )
    )
    twap_lookback, holding_margin, sample_step = params
    if holding_margin > MAX_BLOCK_BALANCE_CHECKS:
        raise RuntimeError(
            f"holding margin {holding_margin} exceeds local preflight cap {MAX_BLOCK_BALANCE_CHECKS}"
        )

    pre_price = oracle_answer(rpc, oracle, pre_block)
    reference_price = oracle_answer(rpc, oracle, reference)
    if pre_price <= 0 or reference_price <= 0 or reference_price > pre_price:
        raise RuntimeError(f"invalid staged prices: pre={pre_price}, reference={reference_price}")
    drop_bps = (pre_price - reference_price) * BPS // pre_price

    balances = [
        first_int(call(rpc, insured, "balanceOf(address)(uint256)", claimant, block=block))
        for block in range(reference - holding_margin, reference + 1)
    ]
    minimum_held = min(balances)

    insured_config = call(
        rpc,
        contracts["defiInsurance"],
        "getInsuredToken(address)((uint256,address,address,bytes,uint128))",
        insured,
    )
    minimum_match = re.search(r",\s*(\d+)(?:\s+\[[^]]+\])?\)$", insured_config)
    if minimum_match is None:
        raise RuntimeError(f"could not parse minimum claim amount: {insured_config}")
    minimum_claim = int(minimum_match.group(1))

    pool_assets = first_int(
        call(rpc, contracts["coverPool"], "totalAssets()(uint256)", block=reference)
    )
    active_incident = first_int(
        call(rpc, contracts["defiInsurance"], "activeIncidentId()(uint256)")
    )
    pcr_hash = call(rpc, contracts["registry"], "teePcrHash()(bytes32)")

    checks = {
        "referenceFinalized": all(block >= reference for block in finalized),
        "dropThreshold": drop_bps >= THRESHOLD_BPS,
        "historicalHolding": minimum_held >= minimum_claim,
        "coverPoolFunded": pool_assets > 0,
        "noActiveIncident": active_incident == 0,
        "settlementWindowUsable": twap_lookback > 0 and sample_step > 0,
    }

    result = {
        "boundary": "real-chain preflight; not a Nitro/TEE signature E2E",
        "network": "sepolia",
        "referenceBlock": reference,
        "finalizedHeads": finalized,
        "preDropBlock": pre_block,
        "preDropPrice": pre_price,
        "referencePrice": reference_price,
        "dropBps": drop_bps,
        "thresholdBps": THRESHOLD_BPS,
        "settlementParams": {
            "twapLookbackBlocks": twap_lookback,
            "holdingMarginBlocks": holding_margin,
            "sampleStepBlocks": sample_step,
        },
        "minimumHistoricalHolding": minimum_held,
        "minimumClaimAmount": minimum_claim,
        "coverPoolAssets": pool_assets,
        "activeIncidentId": active_incident,
        "registryTeePcrHash": pcr_hash,
        "checks": checks,
        "preflightPass": all(checks.values()),
        "teeConfigurationReady": pcr_hash != "0x" + "0" * 64,
    }
    print(json.dumps(result, indent=2))
    return 0 if result["preflightPass"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, RuntimeError, ValueError) as error:
        print(f"incident-open preflight failed: {error}", file=sys.stderr)
        raise SystemExit(1)
