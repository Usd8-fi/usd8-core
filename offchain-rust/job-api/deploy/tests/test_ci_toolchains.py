import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[4]
WORKFLOW = ROOT / ".github" / "workflows" / "test.yml"


class CiToolchainTest(unittest.TestCase):
    def test_score_api_and_release_share_independent_linux_gates(self) -> None:
        workflow = WORKFLOW.read_text()
        self.assertIn("bash offchain-rust/job-api/deploy/release-quality-gates.sh", workflow)
        deploy = ROOT / "offchain-rust/job-api/deploy"
        self.assertIn('bash "$ROOT/job-api/deploy/release-quality-gates.sh"', (deploy / "build-release.sh").read_text())
        script = (deploy / "release-quality-gates.sh").read_text()
        job_api_section = script.split('cd "$ROOT/job-api"', 1)[1]
        job_api_section = job_api_section.split('cd "$ROOT/score-api"', 1)[0]
        for command in (
            "cargo +1.94.1 fmt --check",
            "cargo +1.94.1 test --locked --all-targets --all-features",
            "cargo +1.94.1 clippy --locked --all-targets --all-features -- -D warnings",
        ):
            self.assertIn(command, job_api_section)
        self.assertIn('cd "$ROOT/score-api"', script)
        for command in ("cargo +1.94.1 fmt --check", "cargo +1.94.1 test --locked --all-targets --features lambda,sepolia",
                        "cargo +1.94.1 clippy --locked --all-targets --features lambda,sepolia -- -D warnings",
                        'python3 "$ROOT/job-api/deploy/audit-dependencies.py"', "python3 -m unittest discover"):
            self.assertIn(command, script)
        self.assertIn('cd "$ROOT/score-core"', script)
        self.assertIn('[[ $(uname -s) == Linux ]]', script)

    def test_release_gates_receive_selected_registry_for_linux_enclave_tests(self):
        script = (ROOT / "offchain-rust/job-api/deploy/build-release.sh").read_text()
        gate = [line for line in script.splitlines()
                if 'bash "$ROOT/job-api/deploy/release-quality-gates.sh"' in line]
        self.assertEqual(gate, [
            'USD8_REGISTRY="$REGISTRY" bash "$ROOT/job-api/deploy/release-quality-gates.sh"'
        ])

    def test_release_wrapper_overrides_registry_and_propagates_gate_failure(self):
        script = (ROOT / "offchain-rust/job-api/deploy/build-release.sh").read_text()
        registry = "0x1111111111111111111111111111111111111111"
        for ambient in (None, "0x0000000000000000000000000000000000000001"):
            with self.subTest(ambient_registry=ambient), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                repo = root / "repo"
                deploy = repo / "offchain-rust/job-api/deploy"
                deploy.mkdir(parents=True)
                (deploy / "build-release.sh").write_text(script)
                # Explicit test double: capture the exported gate's environment,
                # then stop before any Cargo, Docker, Nitro, or AWS operation.
                (deploy / "release-quality-gates.sh").write_text(
                    '#!/bin/bash\nset -eu\n'
                    'printf "%s\\n" "${USD8_REGISTRY-<unset>}" > "$GATE_CAPTURE"\n'
                    'printf "%s\\n" "$0" >> "$GATE_CAPTURE"\n'
                    'exit 37\n'
                )
                workflows = repo / ".github/workflows"
                workflows.mkdir(parents=True)
                (workflows / "test.yml").write_text("# committed archive fixture\n")
                # Only wrapper prerequisites are reachable, even if it were to
                # regress and continue past the deliberately failing gate.
                bin_dir = root / "bin"
                bin_dir.mkdir()
                for command in ("bash", "git", "dirname", "mktemp", "mkdir", "tar", "rm"):
                    executable = shutil.which(command)
                    if executable is None:
                        self.fail(f"required wrapper prerequisite not found: {command}")
                    (bin_dir / command).symlink_to(executable)
                capture = root / "gate-capture"
                out = root / "new-release"
                env = {
                    "PATH": str(bin_dir),
                    "HOME": str(root),
                    "TMPDIR": str(root),
                    "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_CONFIG_SYSTEM": os.devnull,
                    "REGISTRY": registry,
                    "EXPECTED_SIGNER": "0x2222222222222222222222222222222222222222",
                    "NETWORK": "sepolia",
                    "OUT_DIR": str(out),
                    "GATE_CAPTURE": str(capture),
                }
                if ambient is not None:
                    env["USD8_REGISTRY"] = ambient
                for args in (
                    ["init", "--quiet", "--template="],
                    ["add", "."],
                    ["-c", "user.name=Release Fixture", "-c", "user.email=fixture@example.invalid",
                     "-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + os.devnull,
                     "commit", "--quiet", "-m", "Commit release wrapper and fake gate"],
                ):
                    subprocess.run(["git", *args], cwd=repo, env=env, check=True,
                                   capture_output=True, text=True, timeout=30)
                result = subprocess.run(
                    ["bash", str(deploy / "build-release.sh")], cwd=repo, env=env,
                    capture_output=True, text=True, timeout=30,
                )
                self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
                self.assertFalse(out.exists(), "failed gate must not publish a release")
                captured_registry, gate_path = capture.read_text().splitlines()
                self.assertIn("/source/offchain-rust/job-api/deploy/", gate_path)
                self.assertNotEqual(gate_path, str(deploy / "release-quality-gates.sh"))
                self.assertEqual(captured_registry, registry)

    def test_release_export_includes_workflow_inputs_for_python_tests(self):
        script = (ROOT / "offchain-rust/job-api/deploy/build-release.sh").read_text()
        self.assertIn('archive "$GIT_COMMIT" offchain-rust .github/workflows', script)

    def test_linux_gate_runs_real_dynamodb_races_not_ignored_tests(self):
        deploy = ROOT / "offchain-rust/job-api/deploy"
        script = (deploy / "release-quality-gates.sh").read_text()
        self.assertIn('with-dynamodb-tests.py', script)
        self.assertIn('-- --include-ignored', script)
        self.assertIn('dynalite@4.0.0', (deploy / 'with-dynamodb-tests.py').read_text())

    def test_job_api_uses_declared_rust_toolchain(self) -> None:
        workflow = WORKFLOW.read_text()
        self.assertIn("rustup toolchain install 1.94.1", workflow)
        self.assertIn(
            'USD8_REGISTRY: "0x0000000000000000000000000000000000000001"',
            workflow,
        )

        job_api_section = workflow.split("- name: Check TEE job API formatting", 1)[1]
        job_api_section = job_api_section.split("- name: Test standalone real-history helpers", 1)[0]
        cargo_commands = [
            line.strip()
            for line in job_api_section.splitlines()
            if line.strip().startswith("cargo ")
        ]
        self.assertTrue(cargo_commands)
        self.assertTrue(
            all(command.startswith("cargo +1.94.1 ") for command in cargo_commands),
            cargo_commands,
        )


if __name__ == "__main__":
    unittest.main()
