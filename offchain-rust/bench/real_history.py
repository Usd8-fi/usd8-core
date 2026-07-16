#!/usr/bin/env python3
"""Real USDC/USDT history helpers for the USD8 settlement benchmark."""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
from typing import Iterable, Mapping, MutableMapping, Sequence

WAD = 10**18
TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
ZERO_ADDRESS = "0x" + "00" * 20


class RpcError(RuntimeError):
    def __init__(self, code: int, message: str, *, splittable: bool = False) -> None:
        super().__init__(f"RPC error {code}: {message}")
        self.code = code
        self.message = message
        self.splittable = splittable


@dataclass
class TokenHistory:
    start_balance: int
    net_delta: int = 0
    weighted_delta: int = 0
    transfer_count: int = 0
    inflow: int = 0
    outflow: int = 0

    @property
    def end_balance(self) -> int:
        return self.start_balance + self.net_delta

    def integral(self, start_block: int, end_block: int) -> int:
        return self.start_balance * (end_block - start_block) + self.weighted_delta


def _topic_address(topic: str) -> str:
    if not isinstance(topic, str) or len(topic) != 66 or not topic.startswith("0x"):
        raise ValueError("malformed indexed address topic")
    return "0x" + topic[-40:].lower()


def _quantity(value: object, field: str) -> int:
    if not isinstance(value, str) or not value.startswith("0x"):
        raise ValueError(f"malformed {field}")
    return int(value, 16)


def apply_transfer_logs(
    histories: MutableMapping[str, TokenHistory],
    logs: Iterable[Mapping[str, object]],
    selected: set[str],
    start_block: int,
    end_block: int,
) -> None:
    """Apply unique Transfer logs and retain the exact balance×block integral."""
    selected = {address.lower() for address in selected}
    unique: dict[tuple[str, int], Mapping[str, object]] = {}
    for log in logs:
        transaction_hash = log.get("transactionHash")
        if not isinstance(transaction_hash, str):
            raise ValueError("malformed transactionHash")
        index = _quantity(log.get("logIndex"), "logIndex")
        unique[(transaction_hash.lower(), index)] = log

    def sort_key(log: Mapping[str, object]) -> tuple[int, int]:
        return (_quantity(log.get("blockNumber"), "blockNumber"), _quantity(log.get("logIndex"), "logIndex"))

    for log in sorted(unique.values(), key=sort_key):
        topics = log.get("topics")
        if not isinstance(topics, list) or len(topics) < 3 or str(topics[0]).lower() != TRANSFER_TOPIC:
            raise ValueError("malformed Transfer topics")
        block = _quantity(log.get("blockNumber"), "blockNumber")
        if block <= start_block or block > end_block:
            raise ValueError(f"Transfer block {block} outside ({start_block}, {end_block}]")
        sender = _topic_address(str(topics[1]))
        receiver = _topic_address(str(topics[2]))
        value = _quantity(log.get("data"), "data")

        participants = ({sender, receiver} & selected) - {ZERO_ADDRESS}
        for address in participants:
            histories[address].transfer_count += 1
        if sender in selected and sender != ZERO_ADDRESS:
            history = histories[sender]
            history.net_delta -= value
            history.weighted_delta -= value * (end_block - block)
            history.outflow += value
        if receiver in selected and receiver != ZERO_ADDRESS:
            history = histories[receiver]
            history.net_delta += value
            history.weighted_delta += value * (end_block - block)
            history.inflow += value


def _split_filter_or(log_filter: dict) -> tuple[dict, dict] | None:
    topics = log_filter.get("topics")
    candidates: list[tuple[int, int]] = []
    if isinstance(topics, list):
        for index, topic in enumerate(topics):
            if isinstance(topic, list) and len(topic) > 1:
                candidates.append((len(topic), index))
    if candidates:
        _, index = max(candidates)
        values = topics[index]
        midpoint = len(values) // 2
        left = dict(log_filter)
        right = dict(log_filter)
        left_topics = list(topics)
        right_topics = list(topics)
        left_topics[index] = values[:midpoint]
        right_topics[index] = values[midpoint:]
        left["topics"] = left_topics
        right["topics"] = right_topics
        return left, right
    addresses = log_filter.get("address")
    if isinstance(addresses, list) and len(addresses) > 1:
        midpoint = len(addresses) // 2
        left = dict(log_filter)
        right = dict(log_filter)
        left["address"] = addresses[:midpoint]
        right["address"] = addresses[midpoint:]
        return left, right
    return None


def _fetch_split_filter_or(
    rpc: object,
    log_filter: dict,
    block: int,
    result_cap: int,
) -> list[dict]:
    split = _split_filter_or(log_filter)
    if split is None:
        raise RpcError(-1, f"single block {block} cannot be split further", splittable=False)
    left, right = split
    return fetch_logs_complete(rpc, left, block, block, result_cap=result_cap) + fetch_logs_complete(
        rpc, right, block, block, result_cap=result_cap
    )


def fetch_logs_complete(
    rpc: object,
    log_filter: dict,
    start_block: int,
    end_block: int,
    *,
    result_cap: int,
) -> list[dict]:
    """Fetch a complete inclusive range, bisecting provider-limited responses."""
    if end_block < start_block:
        return []
    try:
        logs = rpc(log_filter, start_block, end_block)  # type: ignore[operator]
    except RpcError as error:
        if not error.splittable:
            raise
        if start_block == end_block:
            return _fetch_split_filter_or(rpc, log_filter, start_block, result_cap)
        midpoint = (start_block + end_block) // 2
        return fetch_logs_complete(rpc, log_filter, start_block, midpoint, result_cap=result_cap) + fetch_logs_complete(
            rpc, log_filter, midpoint + 1, end_block, result_cap=result_cap
        )
    if len(logs) >= result_cap:
        if start_block == end_block:
            return _fetch_split_filter_or(rpc, log_filter, start_block, result_cap)
        midpoint = (start_block + end_block) // 2
        return fetch_logs_complete(rpc, log_filter, start_block, midpoint, result_cap=result_cap) + fetch_logs_complete(
            rpc, log_filter, midpoint + 1, end_block, result_cap=result_cap
        )
    return list(logs)


def assert_end_balances(histories: Mapping[str, TokenHistory], expected: Mapping[str, int]) -> None:
    for address, history in histories.items():
        actual = expected[address]
        if history.end_balance != actual:
            raise ValueError(
                f"replay end balance mismatch for {address}: replay={history.end_balance}, archive={actual}"
            )


def score_numerator_from_integral(integral: int, decimals: int, rate: int) -> int:
    if integral < 0 or decimals < 0 or rate < 0:
        raise ValueError("score inputs must be non-negative")
    scaled = integral * 10 ** (18 - decimals) if decimals <= 18 else integral // 10 ** (decimals - 18)
    return scaled * rate


def score_from_integral(integral: int, decimals: int, rate: int) -> int:
    return score_numerator_from_integral(integral, decimals, rate) // WAD


def gross_score_from_components(components: Iterable[tuple[int, int, int]]) -> int:
    return sum(score_numerator_from_integral(integral, decimals, rate) for integral, decimals, rate in components) // WAD


def deterministic_rank(addresses: Iterable[str], seed: str) -> list[str]:
    normalized = {address.lower() for address in addresses}
    return sorted(normalized, key=lambda address: (sha256(f"{seed}:{address}".encode()).digest(), address))


def synthetic_claim_amount(address: str) -> int:
    whole_dollars = 100 + int.from_bytes(sha256(bytes.fromhex(address[2:])).digest()[:8], "big") % 9_901
    return whole_dollars * WAD


def build_settlement_fixture(records: Sequence[Mapping[str, str]], incident_id: int) -> dict:
    claims = []
    for index, record in enumerate(records, 1):
        address = record["address"].lower()
        gross_score = record["grossScore"]
        claim_amount = synthetic_claim_amount(address)
        claims.append(
            {
                "claimId": str(index),
                "user": address,
                "escrowAmount": str(claim_amount),
                "minHeld": str(claim_amount),
                "grossEarnedScore": gross_score,
                "spentScore": "0",
                "scoreToSpend": gross_score,
                "boosterAmount": "0",
                "boosterHeld": "0",
            }
        )
    total_claims = sum(int(claim["escrowAmount"]) for claim in claims)
    return {
        "incidentId": str(incident_id),
        "insuredDecimals": 18,
        "underlyingUsd": str(WAD),
        "twapRatio": str(WAD),
        "coverageBps": "8000",
        "maxCoverPoolPayoutBps": "10000",
        "claims": claims,
        "pools": [
            {
                "balance": str(total_claims // 5),
                "assetUsd": str(WAD),
                "assetDecimals": 18,
            }
        ],
    }
