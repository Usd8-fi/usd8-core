import pathlib
import re
import unittest
import ast
import json
import os
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[4]
APPROVED = {"RUSTSEC-2021-0127", "RUSTSEC-2024-0388", "RUSTSEC-2024-0436"}


class AuditExceptions(unittest.TestCase):
    def assert_only_ignore_config(self, text, expected):
        # Deliberately accept only our tiny TOML subset, not arbitrary TOML.
        # Full matching rejects extra tables/keys/filters without a Python 3.11 dependency.
        text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
        advisory = r'"RUSTSEC-\d{4}-\d{4}"'
        pattern = r'\s*\[advisories\]\s*ignore\s*=\s*(\[\s*(?:' + advisory + r'(?:\s*,\s*' + advisory + r')*\s*,?\s*)?\])\s*'
        match = re.fullmatch(pattern, text)
        if match is None:
            self.fail('audit config must contain only a literal advisory ignore list')
        values = ast.literal_eval(match.group(1))
        self.assertEqual(set(values), expected)
        self.assertEqual(len(values), len(expected))

    def test_config_validation_rejects_additional_policy_and_malformed_lists(self):
        valid = '[advisories]\nignore = ["RUSTSEC-2021-0127", "RUSTSEC-2024-0388", "RUSTSEC-2024-0436"]\n'
        bad_configs = (
            valid + '[yanked]\nenabled = false\n',
            valid + '[target]\nos = "macos"\n',
            valid + '[database]\nfetch = false\n',
            valid + 'ignore = []\n',
            valid.replace('"RUSTSEC-2024-0436"]', '"RUSTSEC-2024-0436", "RUSTSEC-2023-0071"]'),
            valid.replace('"RUSTSEC-2024-0436"', '"RUSTSEC-2024-0388"'),
            valid.replace(', "RUSTSEC', ' "RUSTSEC'),
        )
        self.assert_only_ignore_config(valid, APPROVED)
        for text in bad_configs:
            with self.subTest(config=text), self.assertRaises(AssertionError):
                self.assert_only_ignore_config(text, APPROVED)

    def test_effective_hidden_configs_have_no_extra_exceptions_or_filters(self):
        for rel in ("offchain-rust/.cargo/audit.toml", "offchain-rust/job-api/.cargo/audit.toml"):
            with self.subTest(config=rel):
                self.assert_only_ignore_config((ROOT / rel).read_text(), APPROVED)

    def test_isolated_helper_runs_all_four_graphs_without_ambient_exceptions(self):
        helper = ROOT / "offchain-rust/job-api/deploy/audit-dependencies.py"
        self.assertTrue(helper.is_file(), "controlled audit helper is required")
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            home = base / "cargo-home"
            home.mkdir()
            ambient = ('[advisories]\nignore = ["RUSTSEC-2023-0071", "RUSTSEC-2026-0173"]\n'
                       '[yanked]\nenabled = false\n[target]\nos = "macos"\n')
            (home / "audit.toml").write_text(ambient)
            (base / ".cargo").mkdir()
            (base / ".cargo/audit.toml").write_text(ambient)
            uname = base / "uname"
            uname.write_text("#!/bin/sh\nprintf 'Linux\\n'\n")
            uname.chmod(0o755)
            fake = base / "cargo"
            fake.write_text(
                f"#!{sys.executable}\n"
                "import json, os, pathlib, sys\n"
                "record = {'argv': sys.argv[1:], 'config': pathlib.Path('.cargo/audit.toml').read_text()}\n"
                "with open(os.environ['AUDIT_TEST_LOG'], 'a') as out: out.write(json.dumps(record) + '\\n')\n"
                "graph = pathlib.Path(sys.argv[-1]).parent.name\n"
                "sys.exit(json.loads(os.environ['AUDIT_TEST_EXITS']).get(graph, 0))\n"
            )
            fake.chmod(0o755)
            log = base / "calls.jsonl"
            env = dict(os.environ, PATH=str(base) + os.pathsep + os.environ['PATH'],
                       CARGO_HOME=str(home), AUDIT_TEST_LOG=str(log))
            cases = ({}, {"offchain-rust": 1}, {"job-api": 2},
                     {"offchain-rust": 2, "job-api": 1}, {"score-core": 1})
            for exits in cases:
                status = max(exits.values(), default=0)
                commands = [[sys.executable, str(helper)]]
                if status:
                    # Exercise the real release shell entrypoint with explicit test doubles.
                    commands.append(["bash", str(helper.with_name("release-quality-gates.sh"))])
                for command in commands:
                    with self.subTest(exits=exits, command=command):
                        self.check_audit_calls(command, env, exits, status, log, base, home, ambient)

    def check_audit_calls(self, command, env, exits, status, log, base, home, ambient):
        log.write_text("")
        env['AUDIT_TEST_EXITS'] = json.dumps(exits)
        result = subprocess.run(command, cwd=base, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, status, result.stderr)
        records = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(len(records), 4)
        for record, graph in zip(records, (".", "job-api", "score-api", "score-core")):
            self.assert_only_ignore_config(record['config'], set())
            self.assertEqual(record['argv'], [
                '+1.94.1', 'audit', '--deny', 'warnings',
                '--ignore', 'RUSTSEC-2021-0127',
                '--ignore', 'RUSTSEC-2024-0388', '--ignore', 'RUSTSEC-2024-0436',
                '--file', str((ROOT / 'offchain-rust' / graph / 'Cargo.lock').resolve()),
            ])
        self.assertEqual((home / 'audit.toml').read_text(), ambient)
        self.assertEqual((base / '.cargo/audit.toml').read_text(), ambient)

    def test_ci_and_release_use_one_controlled_four_graph_gate(self):
        deploy = ROOT / "offchain-rust/job-api/deploy"
        workflow = (ROOT / ".github/workflows/test.yml").read_text()
        build = (deploy / "build-release.sh").read_text()
        gates = (deploy / "release-quality-gates.sh").read_text()
        for text in (workflow, build, gates):
            self.assertNotRegex(text, r"\bcargo(?:\s+\+\S+)?\s+audit\b")
            self.assertNotIn("--ignore", text)
        self.assertEqual(workflow.count("bash offchain-rust/job-api/deploy/release-quality-gates.sh"), 1)
        self.assertEqual(build.count('bash "$ROOT/job-api/deploy/release-quality-gates.sh"'), 1)
        command = 'python3 "$ROOT/job-api/deploy/audit-dependencies.py"'
        self.assertEqual(gates.count(command), 1)
        self.assertIn("set -euo pipefail", gates)
        self.assertLess(gates.index(command), gates.index('cd "$ROOT/score-api"'))


if __name__ == "__main__":
    unittest.main()
