#!/usr/bin/env python3
"""Collect a real mainnet USDC/USDT cohort and build a USD8 settlement fixture.

The credential is read from a file or DRPC_KEY and is never printed or persisted.
All source blocks are finalized and every selected account's replay is checked
against archive balanceOf at the end block.
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from hashlib import sha256
from pathlib import Path
from threading import Lock
from typing import Iterable

from real_history import (
    RpcError,
    TokenHistory,
    TRANSFER_TOPIC,
    ZERO_ADDRESS,
    apply_transfer_logs,
    assert_end_balances,
    build_settlement_fixture,
    deterministic_rank,
    fetch_logs_complete,
    gross_score_from_components,
    score_from_integral,
)

USDC = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
USDT = "0xdac17f958d2ee523a2206206994597c13d831ec7"
TOKENS = {
    USDC: {"symbol": "USDC", "decimals": 6, "proxy": "USD8", "rate": 138_888_888_888_889},
    USDT: {"symbol": "USDT", "decimals": 6, "proxy": "sUSD8", "rate": 13_888_888_888_889},
}
RESULT_CAP = 20_000
USER_AGENT = "usd8-real-history-benchmark/1.0"
TRUSTED_DRPC_HOSTS = frozenset({"lb.drpc.org", "lb.drpc.live"})


def is_transient_rpc_error(status: int, code: int) -> bool:
    return status in (408, 429, 500, 502, 503, 504) or code in (12, 19, -32000, -32005)


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        del req, fp, code, msg, headers, newurl
        return None


def validate_drpc_endpoint(url: str) -> None:
    try:
        endpoint = urllib.parse.urlsplit(url)
        port = endpoint.port
    except ValueError as error:
        raise ValueError("refusing to send DRPC_KEY to malformed RPC endpoint") from error

    trusted = (
        endpoint.scheme.lower() == "https"
        and endpoint.hostname is not None
        and endpoint.hostname.lower() in TRUSTED_DRPC_HOSTS
        and port in (None, 443)
        and endpoint.username is None
        and endpoint.password is None
    )
    if not trusted:
        raise ValueError("refusing to send DRPC_KEY to untrusted RPC endpoint")


class RpcClient:
    def __init__(self, url: str, key: str, timeout: int = 30) -> None:
        validate_drpc_endpoint(url)
        self.url = url
        self.key = key
        self.timeout = timeout
        self._opener = urllib.request.build_opener(NoRedirectHandler())
        self._id = 0
        self._lock = Lock()
        self.call_count = 0
        self.retry_count = 0

    def _next_id(self) -> int:
        with self._lock:
            self._id += 1
            return self._id

    def call(self, method: str, params: list, *, split_on_limit: bool = False) -> object:
        payload = {"jsonrpc": "2.0", "id": self._next_id(), "method": method, "params": params}
        last_error = None
        for attempt in range(6):
            with self._lock:
                self.call_count += 1
            request = urllib.request.Request(
                self.url,
                data=json.dumps(payload, separators=(",", ":")).encode(),
                headers={"Content-Type": "application/json", "User-Agent": USER_AGENT, "Drpc-Key": self.key},
            )
            status = 200
            try:
                with self._opener.open(request, timeout=self.timeout) as response:
                    raw = response.read()
                    status = response.status
            except urllib.error.HTTPError as error:
                status = error.code
                raw = error.read()
            except Exception as error:
                last_error = error
                if attempt < 5:
                    with self._lock:
                        self.retry_count += 1
                    time.sleep(min(0.25 * 2**attempt, 4))
                    continue
                raise RpcError(-1, f"transport failure: {type(error).__name__}", splittable=split_on_limit)

            try:
                body = json.loads(raw)
            except Exception as error:
                last_error = error
                if attempt < 5:
                    with self._lock:
                        self.retry_count += 1
                    time.sleep(min(0.25 * 2**attempt, 4))
                    continue
                raise RpcError(status, "non-JSON RPC response", splittable=split_on_limit)

            if "result" in body:
                return body["result"]
            error = body.get("error", {})
            code = int(error.get("code", status))
            message = str(error.get("message", "unknown RPC error"))
            lower = message.lower()
            range_limited = split_on_limit and any(
                phrase in lower
                for phrase in (
                    "timeout",
                    "max results",
                    "range",
                    "response size",
                    "too many",
                    "exceeds",
                )
            )
            if range_limited:
                raise RpcError(code, message, splittable=True)
            transient = is_transient_rpc_error(status, code)
            if transient and attempt < 5:
                with self._lock:
                    self.retry_count += 1
                time.sleep(min(0.25 * 2**attempt, 4))
                continue
            raise RpcError(code, message, splittable=split_on_limit and transient)
        raise RpcError(-1, f"RPC failed: {last_error}", splittable=split_on_limit)


class CachedLogRpc:
    def __init__(self, client: RpcClient, cache_dir: Path) -> None:
        self.client = client
        self.cache_dir = cache_dir
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.cache_hits = 0
        self._lock = Lock()

    def __call__(self, log_filter: dict, start_block: int, end_block: int) -> list[dict]:
        material = json.dumps(
            {"filter": log_filter, "start": start_block, "end": end_block}, sort_keys=True, separators=(",", ":")
        )
        digest = sha256(material.encode()).hexdigest()
        path = self.cache_dir / f"{digest}.json.gz"
        if path.exists():
            with self._lock:
                self.cache_hits += 1
            with gzip.open(path, "rt", encoding="utf8") as handle:
                return json.load(handle)
        query = dict(log_filter)
        query["fromBlock"] = hex(start_block)
        query["toBlock"] = hex(end_block)
        result = self.client.call("eth_getLogs", [query], split_on_limit=True)
        if not isinstance(result, list):
            raise RpcError(-1, "eth_getLogs result is not an array")
        temporary = path.with_suffix(f".{os.getpid()}.tmp")
        with gzip.open(temporary, "wt", encoding="utf8") as handle:
            json.dump(result, handle, separators=(",", ":"))
        os.replace(temporary, path)
        return result


def topic_address(topic: str) -> str:
    return "0x" + topic[-40:].lower()


def indexed_address(address: str) -> str:
    return "0x" + "0" * 24 + address[2:].lower()


def balance_call_data(address: str) -> str:
    return "0x70a08231" + "0" * 24 + address[2:].lower()


def archive_balances(
    client: RpcClient, addresses: list[str], block: int, workers: int
) -> dict[str, dict[str, int]]:
    jobs = [(token, address) for token in TOKENS for address in addresses]

    def read(job: tuple[str, str]) -> tuple[str, str, int]:
        token, address = job
        raw = client.call("eth_call", [{"to": token, "data": balance_call_data(address)}, hex(block)])
        if not isinstance(raw, str):
            raise ValueError("eth_call balance result is not hex")
        return token, address, int(raw, 16)

    output = {token: {} for token in TOKENS}
    with ThreadPoolExecutor(max_workers=workers) as executor:
        for token, address, balance in executor.map(read, jobs):
            output[token][address] = balance
    return output


def select_eoas(
    client: RpcClient, ranked: list[str], block: int, count: int, workers: int
) -> tuple[list[str], int]:
    selected: list[str] = []
    checked = 0

    def code_at(address: str) -> tuple[str, str]:
        code = client.call("eth_getCode", [address, hex(block)])
        if not isinstance(code, str):
            raise ValueError("eth_getCode result is not hex")
        return address, code

    for offset in range(0, len(ranked), 300):
        batch = ranked[offset : offset + 300]
        with ThreadPoolExecutor(max_workers=workers) as executor:
            results = list(executor.map(code_at, batch))
        checked += len(results)
        for address, code in results:
            if code == "0x":
                selected.append(address)
                if len(selected) == count:
                    return selected, checked
    raise RuntimeError(f"only found {len(selected)} EOAs after checking {checked} active addresses")


def sample_candidates(
    log_rpc: CachedLogRpc, start_block: int, end_block: int, samples: int, workers: int
) -> tuple[Counter, list[int], int]:
    first = start_block + 1
    sample_blocks = [first + (end_block - first) * index // (samples - 1) for index in range(samples)]
    log_filter = {"address": list(TOKENS), "topics": [TRANSFER_TOPIC]}

    def fetch(block: int) -> list[dict]:
        return fetch_logs_complete(log_rpc, log_filter, block, block, result_cap=RESULT_CAP)

    activity: Counter = Counter()
    total_logs = 0
    with ThreadPoolExecutor(max_workers=workers) as executor:
        future_to_block = {executor.submit(fetch, block): block for block in sample_blocks}
        for future in as_completed(future_to_block):
            logs = future.result()
            total_logs += len(logs)
            for log in logs:
                topics = log.get("topics", [])
                if len(topics) < 3:
                    raise ValueError("sample returned malformed Transfer log")
                for topic in topics[1:3]:
                    address = topic_address(topic)
                    if address != ZERO_ADDRESS and address not in TOKENS:
                        activity[address] += 1
    return activity, sample_blocks, total_logs


def fetch_cohort_logs(
    log_rpc: CachedLogRpc,
    selected: list[str],
    start_block: int,
    end_block: int,
    base_range: int,
    workers: int,
) -> tuple[dict[str, list[dict]], int]:
    address_topics = [indexed_address(address) for address in selected]
    jobs = []
    for first in range(start_block + 1, end_block + 1, base_range):
        last = min(first + base_range - 1, end_block)
        for position in (1, 2):
            topics: list[object] = [TRANSFER_TOPIC, None, None]
            topics[position] = address_topics
            jobs.append((first, last, {"address": list(TOKENS), "topics": topics}))

    unique: dict[str, dict[tuple[str, int], dict]] = {token: {} for token in TOKENS}
    completed = 0

    def fetch(job: tuple[int, int, dict]) -> list[dict]:
        first, last, log_filter = job
        return fetch_logs_complete(log_rpc, log_filter, first, last, result_cap=RESULT_CAP)

    with ThreadPoolExecutor(max_workers=workers) as executor:
        future_to_job = {executor.submit(fetch, job): job for job in jobs}
        for future in as_completed(future_to_job):
            logs = future.result()
            for log in logs:
                token = str(log.get("address", "")).lower()
                if token not in unique:
                    raise ValueError(f"unexpected token in Transfer result: {token}")
                transaction_hash = str(log.get("transactionHash", "")).lower()
                log_index = int(str(log.get("logIndex")), 16)
                unique[token][(transaction_hash, log_index)] = log
            completed += 1
            if completed % 100 == 0 or completed == len(jobs):
                print(
                    f"history ranges {completed}/{len(jobs)}; unique logs "
                    + ", ".join(f"{TOKENS[token]['symbol']}={len(logs)}" for token, logs in unique.items()),
                    flush=True,
                )
    return {token: list(logs.values()) for token, logs in unique.items()}, len(jobs)


def block_metadata(client: RpcClient, number: int) -> dict:
    block = client.call("eth_getBlockByNumber", [hex(number), False])
    if not isinstance(block, dict) or block.get("number") != hex(number):
        raise ValueError(f"missing block {number}")
    return {
        "number": number,
        "hash": block["hash"],
        "timestamp": int(block["timestamp"], 16),
    }


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f"{path.suffix}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    os.replace(temporary, path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc-url", default="https://lb.drpc.live/ethereum")
    parser.add_argument("--key-file")
    parser.add_argument("--start-block", type=int, required=True)
    parser.add_argument("--end-block", type=int, required=True)
    parser.add_argument("--cohort-size", type=int, default=1000)
    parser.add_argument("--samples", type=int, default=91)
    parser.add_argument("--base-range", type=int, default=1000)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--cache-dir", default="/tmp/usd8-real-history-cache")
    parser.add_argument("--history-output", required=True)
    parser.add_argument("--fixture-output", required=True)
    args = parser.parse_args()

    key = Path(args.key_file).read_text().strip() if args.key_file else os.environ.get("DRPC_KEY", "")
    if not key:
        raise SystemExit("DRPC_KEY or --key-file is required")
    client = RpcClient(args.rpc_url, key)
    log_rpc = CachedLogRpc(client, Path(args.cache_dir))
    chain_id = int(str(client.call("eth_chainId", [])), 16)
    if chain_id != 1:
        raise RuntimeError(f"expected Ethereum chain 1, got {chain_id}")
    start = block_metadata(client, args.start_block)
    end = block_metadata(client, args.end_block)
    print(f"finalized source blocks {args.start_block}..{args.end_block}", flush=True)

    activity, sample_blocks, sampled_logs = sample_candidates(
        log_rpc, args.start_block, args.end_block, args.samples, args.workers
    )
    seed = f"{start['hash']}:{end['hash']}:USDC:USDT"
    eligible = [address for address in activity if address not in TOKENS and address != ZERO_ADDRESS]
    ranked = deterministic_rank(eligible, seed)
    selected, code_checked = select_eoas(client, ranked, args.end_block, args.cohort_size, args.workers)
    print(
        f"sampled {sampled_logs} logs across {len(sample_blocks)} blocks; "
        f"{len(activity)} active addresses; selected {len(selected)} EOAs",
        flush=True,
    )

    start_balances = archive_balances(client, selected, args.start_block, args.workers)
    end_balances = archive_balances(client, selected, args.end_block, args.workers)
    logs_by_token, range_jobs = fetch_cohort_logs(
        log_rpc, selected, args.start_block, args.end_block, args.base_range, args.workers
    )

    histories: dict[str, dict[str, TokenHistory]] = {}
    selected_set = set(selected)
    for token in TOKENS:
        token_histories = {address: TokenHistory(start_balances[token][address]) for address in selected}
        apply_transfer_logs(
            token_histories,
            logs_by_token[token],
            selected_set,
            args.start_block,
            args.end_block,
        )
        assert_end_balances(token_histories, end_balances[token])
        histories[token] = token_histories

    # Re-read source block hashes after collection. A mismatch makes provenance invalid.
    if block_metadata(client, args.start_block)["hash"] != start["hash"]:
        raise RuntimeError("start block hash changed during collection")
    if block_metadata(client, args.end_block)["hash"] != end["hash"]:
        raise RuntimeError("end block hash changed during collection")

    users = []
    for address in selected:
        token_records = {}
        score_components = []
        for token, token_config in TOKENS.items():
            history = histories[token][address]
            integral = history.integral(args.start_block, args.end_block)
            if integral < 0:
                raise ValueError(f"negative token-block integral for {address} {token}")
            score = score_from_integral(integral, token_config["decimals"], token_config["rate"])
            score_components.append((integral, token_config["decimals"], token_config["rate"]))
            token_records[token_config["symbol"]] = {
                "proxyRole": token_config["proxy"],
                "startBalanceRaw": str(history.start_balance),
                "endBalanceRaw": str(history.end_balance),
                "transferCount": history.transfer_count,
                "inflowRaw": str(history.inflow),
                "outflowRaw": str(history.outflow),
                "tokenBlockIntegralRaw": str(integral),
                "score": str(score),
            }
        gross_score = gross_score_from_components(score_components)
        users.append(
            {
                "address": address,
                "sampleActivityCount": activity[address],
                "grossScore": str(gross_score),
                "tokens": token_records,
            }
        )

    provenance = {
        "schemaVersion": 1,
        "chainId": chain_id,
        "provider": "dRPC Ethereum JSON-RPC",
        "credential": "Drpc-Key header (redacted)",
        "startBlock": start,
        "endBlock": end,
        "intervalSemantics": "balanceOf(startBlock) plus Transfer replay over (startBlock,endBlock] integrated over [startBlock,endBlock)",
        "tokens": {
            config["symbol"]: {
                "address": token,
                "decimals": config["decimals"],
                "proxyRole": config["proxy"],
                "scoreRatePerTokenBlockWad": str(config["rate"]),
            }
            for token, config in TOKENS.items()
        },
        "candidateDiscovery": {
            "method": "one evenly-spaced finalized block sampled per day-equivalent interval; both Transfer endpoints",
            "sampleBlocks": sample_blocks,
            "sampledTransferLogs": sampled_logs,
            "uniqueActiveAddresses": len(activity),
            "deterministicSelectionSeed": seed,
            "selection": "SHA-256 seeded ordering, then eth_getCode(endBlock)==0x",
            "addressesCodeChecked": code_checked,
            "selectedEoas": len(selected),
        },
        "historyCollection": {
            "method": "complete indexed from/to Transfer queries for selected cohort across full interval",
            "baseRangeBlocks": args.base_range,
            "rangeDirectionJobs": range_jobs,
            "resultCapFailClosed": RESULT_CAP,
            "uniqueLogs": {TOKENS[token]["symbol"]: len(logs) for token, logs in logs_by_token.items()},
            "archiveEndBalanceMismatches": 0,
            "rpcCalls": client.call_count,
            "rpcRetries": client.retry_count,
            "cacheHits": log_rpc.cache_hits,
        },
        "scoreModel": {
            "USDC": "mock USD8, launch rate ~= 1.0 score per whole token per 7200 blocks",
            "USDT": "mock sUSD8, launch rate ~= 0.1 score per whole token per 7200 blocks",
            "period": "only this three-month proxy interval; not pre-period lifetime history",
            "spentScore": "synthetic zero because USDC/USDT have no USD8 Registry spend ledger",
            "boost": "synthetic zero",
        },
    }
    history_output = {"provenance": provenance, "users": users}
    history_path = Path(args.history_output)
    atomic_json(history_path, history_output)

    fixture = build_settlement_fixture(users, incident_id=1_000)
    fixture_path = Path(args.fixture_output)
    atomic_json(fixture_path, fixture)

    print(
        json.dumps(
            {
                "historyOutput": str(history_path),
                "fixtureOutput": str(fixture_path),
                "users": len(users),
                "positiveScores": sum(int(user["grossScore"]) > 0 for user in users),
                "uniqueLogs": provenance["historyCollection"]["uniqueLogs"],
                "rpcCalls": client.call_count,
                "rpcRetries": client.retry_count,
                "cacheHits": log_rpc.cache_hits,
            }
        ),
        flush=True,
    )


if __name__ == "__main__":
    main()
