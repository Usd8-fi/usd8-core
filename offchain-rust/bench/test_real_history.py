import json
import sys
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCH))

from collect_real_history import NoRedirectHandler, RpcClient  # noqa: E402
from real_history import (  # noqa: E402
    RpcError,
    TokenHistory,
    apply_transfer_logs,
    assert_end_balances,
    build_settlement_fixture,
    deterministic_rank,
    fetch_logs_complete,
    gross_score_from_components,
    score_from_integral,
)


USDC_RATE = 138_888_888_888_889
SUSD8_RATE = 13_888_888_888_889


class RpcCredentialBoundaryTests(unittest.TestCase):
    def test_drpc_key_is_limited_to_exact_trusted_https_hosts(self) -> None:
        client = RpcClient("https://lb.drpc.org/ogrpc?network=ethereum", "test-key")
        RpcClient("https://LB.DRPC.LIVE/ethereum", "test-key")
        handlers = getattr(client._opener, "handlers", [])
        self.assertTrue(any(isinstance(handler, NoRedirectHandler) for handler in handlers))

        for endpoint in (
            "http://lb.drpc.org/ethereum",
            "https://lb.drpc.org:444/ethereum",
            "https://lb.drpc.org:not-a-port/ethereum",
            "https://lb.drpc.org.evil.example/ethereum",
            "https://attacker.example/ethereum",
            "https://user@lb.drpc.org/ethereum",
        ):
            with self.subTest(endpoint=endpoint):
                with self.assertRaisesRegex(ValueError, "refusing to send DRPC_KEY"):
                    RpcClient(endpoint, "test-key")


class RealHistoryMathTests(unittest.TestCase):
    def test_integral_matches_stepwise_replay(self) -> None:
        history = TokenHistory(start_balance=100)
        selected = {"0x" + "11" * 20}
        who = next(iter(selected))
        logs = [
            transfer_log(12, 0, who, "0x" + "22" * 20, 30),
            transfer_log(15, 1, "0x" + "33" * 20, who, 10),
        ]

        apply_transfer_logs({who: history}, logs, selected, start_block=10, end_block=20)

        self.assertEqual(history.end_balance, 80)
        self.assertEqual(history.integral(10, 20), 810)
        self.assertEqual(history.transfer_count, 2)
        self.assertEqual(history.inflow, 10)
        self.assertEqual(history.outflow, 30)

    def test_duplicate_direction_results_and_self_transfer_are_counted_once(self) -> None:
        who = "0x" + "11" * 20
        self_log = transfer_log(12, 7, who, who, 40)
        incoming = transfer_log(15, 8, "0x" + "22" * 20, who, 5)
        histories = {who: TokenHistory(start_balance=10)}

        # The same log may arrive from both indexed `from` and `to` queries.
        apply_transfer_logs(histories, [self_log, incoming, self_log, incoming], {who}, 10, 20)

        self.assertEqual(histories[who].end_balance, 15)
        self.assertEqual(histories[who].integral(10, 20), 125)
        self.assertEqual(histories[who].transfer_count, 2)
        self.assertEqual(histories[who].inflow, 45)
        self.assertEqual(histories[who].outflow, 40)

    def test_six_decimal_rates_match_launch_score_per_day(self) -> None:
        one_token_day_integral = 1_000_000 * 7_200

        self.assertEqual(
            score_from_integral(one_token_day_integral, decimals=6, rate=USDC_RATE),
            1_000_000_000_000_000_800,
        )
        self.assertEqual(
            score_from_integral(one_token_day_integral, decimals=6, rate=SUSD8_RATE),
            100_000_000_000_000_800,
        )

    def test_gross_score_rounds_once_after_summing_token_numerators(self) -> None:
        half_wad = 10**18 // 2

        self.assertEqual(score_from_integral(1, decimals=18, rate=half_wad), 0)
        self.assertEqual(
            gross_score_from_components([(1, 18, half_wad), (1, 18, half_wad)]),
            1,
        )

    def test_deterministic_rank_is_order_independent(self) -> None:
        addresses = ["0x" + f"{i:040x}" for i in range(1, 20)]
        seed = "24886575:25539412"

        self.assertEqual(
            deterministic_rank(addresses, seed),
            deterministic_rank(reversed(addresses), seed),
        )
        self.assertEqual(len(deterministic_rank(addresses + addresses, seed)), len(addresses))

    def test_fetch_logs_bisects_provider_limited_ranges_without_gaps(self) -> None:
        calls = []

        def fake_rpc(log_filter: dict, start_block: int, end_block: int) -> list[dict]:
            del log_filter
            calls.append((start_block, end_block))
            if end_block - start_block + 1 > 2:
                raise RpcError(-32602, "range too large", splittable=True)
            return [
                {"blockNumber": hex(block), "logIndex": "0x0", "transactionHash": "0x" + f"{block:064x}"}
                for block in range(start_block, end_block + 1)
            ]

        logs = fetch_logs_complete(fake_rpc, {"address": "0x1"}, 11, 15, result_cap=20_000)

        self.assertEqual([int(log["blockNumber"], 16) for log in logs], [11, 12, 13, 14, 15])
        self.assertIn((11, 15), calls)
        self.assertTrue(all(start <= end for start, end in calls))

    def test_fetch_logs_splits_topic_or_when_single_block_times_out(self) -> None:
        addresses = ["0x" + f"{index:064x}" for index in range(1, 6)]
        calls = []

        def fake_rpc(log_filter: dict, start_block: int, end_block: int) -> list[dict]:
            self.assertEqual(start_block, end_block)
            topics = log_filter["topics"][1]
            calls.append(list(topics))
            if len(topics) > 2:
                raise RpcError(30, "single-block timeout", splittable=True)
            return [
                {
                    "blockNumber": hex(start_block),
                    "logIndex": hex(index),
                    "transactionHash": topic,
                }
                for index, topic in enumerate(topics)
            ]

        logs = fetch_logs_complete(
            fake_rpc,
            {"topics": ["0xtransfer", addresses, None]},
            99,
            99,
            result_cap=20_000,
        )

        self.assertEqual({log["transactionHash"] for log in logs}, set(addresses))
        self.assertEqual(len(logs), 5)
        self.assertTrue(any(len(topics) == 5 for topics in calls))
        self.assertTrue(any(len(topics) <= 2 for topics in calls))
        self.assertLess(max(len(topics) for topics in calls[1:]), 5)

    def test_end_balance_check_fails_on_missing_transfer(self) -> None:
        histories = {"0x" + "11" * 20: TokenHistory(start_balance=100, net_delta=-30)}

        with self.assertRaisesRegex(ValueError, "replay end balance mismatch"):
            assert_end_balances(histories, {"0x" + "11" * 20: 80})

    def test_fixture_uses_real_scores_and_synthetic_claim_amounts(self) -> None:
        records = [
            {"address": "0x" + "11" * 20, "grossScore": "123"},
            {"address": "0x" + "22" * 20, "grossScore": "456"},
        ]

        fixture = build_settlement_fixture(records, incident_id=77)

        self.assertEqual(fixture["incidentId"], "77")
        self.assertEqual(
            set(fixture),
            {
                "incidentId",
                "coverageBps",
                "insuredDecimals",
                "twapRatio",
                "underlyingUsd",
                "maxCoverPoolPayoutBps",
                "pools",
                "claims",
            },
        )
        self.assertEqual(len(fixture["claims"]), 2)
        self.assertEqual(fixture["claims"][0]["grossEarnedScore"], "123")
        self.assertEqual(fixture["claims"][0]["scoreToSpend"], "123")
        self.assertEqual(fixture["claims"][0]["spentScore"], "0")
        self.assertEqual(fixture["claims"][0]["boosterAmount"], "0")
        self.assertEqual(fixture["claims"][0]["boosterHeld"], "0")
        self.assertNotIn("boost", fixture["claims"][0])
        self.assertEqual(fixture["twapRatio"], str(10**18))
        self.assertEqual(fixture["pools"][0]["assetUsd"], str(10**18))
        self.assertEqual(fixture["pools"][0]["assetDecimals"], 18)
        self.assertEqual(
            fixture["claims"][0]["escrowAmount"],
            fixture["claims"][0]["minHeld"],
        )
        total_claims = sum(int(claim["escrowAmount"]) for claim in fixture["claims"])
        self.assertEqual(int(fixture["pools"][0]["balance"]), total_claims // 5)
        json.dumps(fixture)


def transfer_log(block: int, index: int, sender: str, receiver: str, value: int) -> dict:
    return {
        "blockNumber": hex(block),
        "logIndex": hex(index),
        "transactionHash": "0x" + f"{block * 1000 + index:064x}",
        "topics": [
            "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
            "0x" + "0" * 24 + sender[2:],
            "0x" + "0" * 24 + receiver[2:],
        ],
        "data": hex(value),
    }


if __name__ == "__main__":
    unittest.main()
