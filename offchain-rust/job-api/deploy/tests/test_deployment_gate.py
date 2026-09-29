import importlib.util
import pathlib
import subprocess
import unittest
from unittest import mock

DEPLOY = pathlib.Path(__file__).parents[1]


class DeploymentGateTest(unittest.TestCase):
    def setUp(self):
        printer = mock.patch("builtins.print")
        printer.start()
        self.addCleanup(printer.stop)

    def module(self):
        self.assertTrue((DEPLOY / "deploy-release.py").is_file(), "actual deployment wrapper is missing")
        spec = importlib.util.spec_from_file_location("deployment", DEPLOY / "deploy-release.py")
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_deployment_executes_live_gate_and_fails_deployed_unverified(self):
        module = self.module()
        with mock.patch.object(module.subprocess, "run", side_effect=[
                subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0),
                subprocess.CompletedProcess([], 1)]) as run:
            with self.assertRaisesRegex(SystemExit, "DEPLOYED_UNVERIFIED"):
                module.deploy(pathlib.Path("release.json"), pathlib.Path("approved.json"), "a" * 64,
                              "https://example.invalid", ["reviewed-cutover.sh"], False)
            self.assertEqual(run.call_args_list[1].args[0], ["reviewed-cutover.sh"])
            self.assertIn("--live", run.call_args_list[2].args[0])

    def test_plan_never_executes_deployment_or_live_aws(self):
        module = self.module()
        with mock.patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            module.deploy(pathlib.Path("release.json"), pathlib.Path("approved.json"), "a" * 64,
                          "https://example.invalid", ["reviewed-cutover.sh"], True)
            self.assertEqual(run.call_count, 1)
            self.assertNotIn("--live", run.call_args.args[0])
            self.assertNotIn("reviewed-cutover.sh", run.call_args.args[0])

    def test_success_only_after_live_gate_and_partial_deployment_failure(self):
        module = self.module()
        with mock.patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            module.deploy(pathlib.Path("release.json"), pathlib.Path("approved.json"), "a" * 64,
                          "https://example.invalid", ["reviewed-cutover.sh"], False)
            self.assertEqual(run.call_count, 3)
            self.assertIn("--live", run.call_args.args[0])
        with mock.patch.object(module.subprocess, "run", side_effect=[
                subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 1)]) as run:
            with self.assertRaisesRegex(SystemExit, "DEPLOYED_UNVERIFIED"):
                module.deploy(pathlib.Path("release.json"), pathlib.Path("approved.json"), "a" * 64,
                              "https://example.invalid", ["reviewed-cutover.sh"], False)
            self.assertEqual(run.call_count, 2)


if __name__ == "__main__":
    unittest.main()
