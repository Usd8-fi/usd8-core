"""Executable integration tests; synthetic artifacts and local AWS CLI double only."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
import copy
from unittest import mock
import test_release_manifest as fixtures
from test_release_security import manifest, score_descriptor, score_policy

V = fixtures.VERIFY_MODULE
DEPLOY = pathlib.Path(__file__).parents[1]


class FinalizationCliTest(unittest.TestCase):
    def test_finalizer_score_composition_and_actual_deploy_live_failure(self):
        self.run_finalizer(include_score=True, bound="3600", active="4")

    def test_finalizer_without_score_or_bound_explicit_cost_only_mode(self):
        self.run_finalizer(include_score=False, bound=None, active="0")

    def run_finalizer(self, include_score, bound, active):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            build = root / "built"
            build.mkdir()
            factory = fixtures.ReleaseManifestTest()
            path = factory.make_release(build)
            m = json.loads(path.read_text())
            for artifact, filename in (("kmsPolicy", "kms-key-policy.json"), ("instancePolicy", "instance-role-policy.json")):
                policy = json.loads((DEPLOY / filename).read_text())
                for s in policy["Statement"]:
                    if "Condition" in s:
                        s["Condition"]["StringEqualsIgnoreCase"] = {
                            "kms:RecipientAttestation:ImageSha384": fixtures.PCR0,
                            "kms:RecipientAttestation:PCR3": fixtures.PCR3}
                (build / filename).write_text(json.dumps(policy))
                m["artifacts"][artifact]["sha256"] = V.sha256(build / filename)
            path.write_text(json.dumps(m))
            factory.write_checksums(build, m["artifacts"])
            aws = manifest()["aws"]
            evidence = {
                "describe-images": {"Images": [{"ImageId": aws["amiId"], "State": "available", "Public": False,
                    "RootDeviceName": "/dev/xvda", "BlockDeviceMappings": [{"DeviceName": "/dev/xvda",
                        "Ebs": {"SnapshotId": "snap-12345678", "Encrypted": True, "DeleteOnTermination": True}}]}]},
                "get-role": {"Role": {"Arn": aws["instanceRoleArn"]}},
                "describe-key": {"KeyMetadata": {"Arn": aws["kmsKeyId"]}}}
            (root / "evidence.json").write_text(json.dumps(evidence))
            cli = root / "aws"
            cli.write_text('#!' + sys.executable + '\nimport json, os, pathlib, sys\n'
                'root = pathlib.Path(os.environ["FIXTURE_ROOT"])\n'
                'with (root / "aws-calls").open("a") as out: out.write(sys.argv[2] + "\\n")\n'
                'responses = json.loads((root / "evidence.json").read_text())\n'
                'if sys.argv[2] not in responses: sys.exit(42)\n'
                'print(json.dumps(responses[sys.argv[2]]))\n')
            cli.chmod(0o755)
            (root / "score.zip").write_bytes(b"synthetic-score-package")
            (root / "score.json").write_text(json.dumps(score_descriptor()))
            (root / "score-policy.json").write_text(json.dumps(score_policy()))
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                   "FIXTURE_ROOT": str(root), "AMI_ID": aws["amiId"], "AWS_REGION": aws["region"],
                   "KMS_KEY_ID": aws["kmsKeyId"], "LAMBDA_FUNCTION": aws["lambdaFunction"],
                   "JANITOR_FUNCTION": aws["janitorFunction"], "LAMBDA_ROLE": aws["lambdaRole"],
                   "JANITOR_ROLE": aws["janitorRole"], "INSTANCE_ROLE": aws["instanceRole"],
                   "LAMBDA_POLICY_NAME": aws["lambdaPolicyName"], "JANITOR_POLICY_NAME": aws["janitorPolicyName"],
                   "INSTANCE_POLICY_NAME": aws["instancePolicyName"], "JOB_BUCKET": aws["lambdaEnvironment"]["USD8_JOB_BUCKET"],
                   "INSTANCE_TYPE": "c6i.xlarge", "INSTANCE_PROFILE": "USD8TeeInstanceProfile",
                   "USD8_EC2_RECONCILIATION_BOUND_SECONDS": "3600",
                   "LAMBDA_TIMEOUT_SECONDS": "30", "JANITOR_TIMEOUT_SECONDS": "60",
                   "SUBNET_ID": "subnet-fffffffffffffffff",
                   "SECURITY_GROUP_ID": aws["lambdaEnvironment"]["USD8_TEE_SECURITY_GROUP_ID"],
                   "JANITOR_MAX_AGE_SECONDS": "1500", "USD8_MAX_ACTIVE_WORKERS": "4", "USD8_MAX_STARTS_PER_HOUR": "16", "DEFI_INSURANCE": "0x" + "d" * 40,
                   "USD8_JOB_HMAC_KEY_B64": "synthetic-secret-never-print", "USD8_PRECHECK_RPC_URL": "https://fixture.invalid/secret",
                   "SCORE_PACKAGE": str(root / "score.zip"), "SCORE_CONFIG_JSON": str(root / "score.json"),
                   "SCORE_RUNTIME_POLICY_JSON": str(root / "score-policy.json")}
            env["USD8_MAX_ACTIVE_WORKERS"] = active
            if bound is None:
                env.pop("USD8_EC2_RECONCILIATION_BOUND_SECONDS", None)
            else:
                env["USD8_EC2_RECONCILIATION_BOUND_SECONDS"] = bound
            if not include_score:
                for key in ("SCORE_PACKAGE", "SCORE_CONFIG_JSON", "SCORE_RUNTIME_POLICY_JSON"):
                    env.pop(key, None)
            out = root / "final"
            for key in ("LAMBDA_TIMEOUT_SECONDS", "JANITOR_TIMEOUT_SECONDS"):
                for value in (None, "0", "901", "1.5", "-1", "030"):
                    invalid = dict(env)
                    if value is None:
                        invalid.pop(key)
                    else:
                        invalid[key] = value
                    rejected = subprocess.run(["bash", str(DEPLOY / "finalize-release.sh"), str(build), str(out)], env=invalid, capture_output=True, text=True)
                    with self.subTest(key=key, value=value):
                        self.assertNotEqual(rejected.returncode, 0)
                        self.assertFalse(out.exists())
                        self.assertFalse((root / "aws-calls").exists())
            result = subprocess.run(["bash", str(DEPLOY / "finalize-release.sh"), str(build), str(out)], env=env, capture_output=True, text=True)
            try:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("RELEASE_CANDIDATE_CREATED", result.stdout)
                self.assertNotIn(env["USD8_JOB_HMAC_KEY_B64"], result.stdout + result.stderr)
                final = json.loads((out / "release-manifest.json").read_text())
                self.assertEqual(final["aws"].get("lambdaTimeoutSeconds"), 30)
                self.assertEqual(final["aws"].get("janitorTimeoutSeconds"), 60)
                self.assertEqual(final["aws"]["lambdaEnvironment"]["USD8_MAX_ACTIVE_WORKERS"], active)
                self.assertEqual(final["aws"]["lambdaEnvironment"].get("USD8_EC2_RECONCILIATION_BOUND_SECONDS"), bound)
                if include_score:
                    self.assertEqual(final["artifacts"]["scoreLambda"]["sha256"], V.sha256(root / "score.zip"))
                    self.assertEqual(final["scoreService"], score_descriptor())
                    self.assertEqual(final["artifacts"]["scoreRuntimePolicy"]["sha256"], V.sha256(root / "score-policy.json"))
                else:
                    self.assertNotIn("scoreService", final)
                    self.assertNotIn("scoreLambda", final["artifacts"])
                    self.assertNotIn("scoreRuntimePolicy", final["artifacts"])
                final_path = out / "release-manifest.json"
                final_path.chmod(0o644)
                for field in ("lambdaTimeoutSeconds", "janitorTimeoutSeconds"):
                    for value in (None, 0, 901, True, "30", 30.5):
                        altered = copy.deepcopy(final)
                        if value is None:
                            del altered["aws"][field]
                        else:
                            altered["aws"][field] = value
                        del altered["releaseId"]
                        altered["releaseId"] = V.canonical_sha256(altered)
                        final_path.write_text(json.dumps(altered))
                        with self.subTest(field=field, value=value), self.assertRaisesRegex(SystemExit, "AWS release fields|timeout"), mock.patch("builtins.print"):
                            V.verify(final_path, False, False)
                final_path.write_text(json.dumps(final))
                final_path.chmod(0o444)
                approval = root / "approved.json"
                approval.write_text(json.dumps({"releaseId": final["releaseId"], "roleTrustPolicies": {}, "bucketEncryption": {}}))
                command = [sys.executable, str(DEPLOY / "deploy-release.py"), str(out / "release-manifest.json"),
                    "--security-baseline", str(approval), "--baseline-sha256", V.sha256(approval), "--rpc-url", "https://fixture.invalid"]
                marker = root / "cutover-ran"
                cutover = [sys.executable, "-c", "import pathlib; pathlib.Path(" + repr(str(marker)) + ").touch()"]
                before = (root / "aws-calls").read_text()
                plan = subprocess.run(command + ["--plan", "--"] + cutover, env=env, capture_output=True, text=True)
                self.assertEqual(plan.returncode, 0, plan.stderr)
                self.assertFalse(marker.exists())
                self.assertEqual((root / "aws-calls").read_text(), before)
                execution = subprocess.run(command + ["--"] + cutover, env=env, capture_output=True, text=True)
                self.assertTrue(marker.exists())
                self.assertNotEqual(execution.returncode, 0)
                self.assertIn("DEPLOYED_UNVERIFIED", execution.stderr)
                self.assertNotIn("RELEASE_DEPLOYED_AND_LIVE_VERIFIED", execution.stdout)
                self.assertEqual((root / "aws-calls").read_text().splitlines()[-1], "list-grants")
            finally:
                if out.exists():
                    out.chmod(0o755)
                    for child in out.rglob("*"):
                        child.chmod(0o755 if child.is_dir() else 0o644)


if __name__ == "__main__":
    unittest.main()
