import os
import pathlib
import subprocess
import tempfile
import unittest


DEPLOY = pathlib.Path(__file__).resolve().parents[1]


class ReleaseRootGatesTest(unittest.TestCase):
    def test_external_target_is_rejected_before_build_prerequisites(self):
        for target in ("external-target", "/external/target", " "):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                out = pathlib.Path(tmp) / "release"
                result = subprocess.run(
                    ["/bin/bash", str(DEPLOY / "build-release.sh")],
                    env={"PATH": os.devnull, "CARGO_TARGET_DIR": target, "OUT_DIR": str(out)},
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("CARGO_TARGET_DIR must be unset or empty", result.stderr)
                self.assertFalse(out.exists())

    def test_empty_target_reaches_normal_prerequisite_validation(self):
        for target in (None, ""):
            with self.subTest(target=target):
                env = {"PATH": os.devnull}
                if target is not None:
                    env["CARGO_TARGET_DIR"] = target
                result = subprocess.run(
                    ["/bin/bash", str(DEPLOY / "build-release.sh")], env=env,
                    capture_output=True, text=True, timeout=10,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("set EXPECTED_SIGNER", result.stderr)
                self.assertNotIn("CARGO_TARGET_DIR must", result.stderr)

    def test_root_and_score_core_have_pinned_release_gates(self):
        script = (DEPLOY / "release-quality-gates.sh").read_text()
        root = script.split('cd "$ROOT/job-api"', 1)[0]
        self.assertIn('cd "$ROOT"', root)
        for command in (
            'cargo +1.94.1 fmt --check',
            'cargo +1.94.1 test --locked --all-targets --features nitro,sepolia',
            'cargo +1.94.1 clippy --locked --all-targets --features nitro,sepolia -- -D warnings',
            'cargo +1.94.1 test --locked --all-targets --features nitro\n',
            'cargo +1.94.1 clippy --locked --all-targets --features nitro -- -D warnings',
        ):
            self.assertIn(command, root)
        core = script.split('cd "$ROOT/score-core"', 1)[1].split('cd "$ROOT"', 1)[0]
        self.assertIn('cargo +1.94.1 fmt --check', core)


if __name__ == "__main__":
    unittest.main()
