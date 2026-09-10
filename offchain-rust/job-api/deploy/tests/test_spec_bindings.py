"""F04 specification regressions; synthetic read-only AWS responses."""
import json
import pathlib
import tempfile
import unittest
from contextlib import ExitStack
from unittest import mock
import test_release_security as security
from test_release_security import manifest, score_descriptor, score_policy, V


class SpecBindingsTest(unittest.TestCase):
    def live_fixture(self, directory):
        m = manifest()
        aws = m["aws"]
        aws.update(rootSnapshotId="snap-fixture", lambdaTimeoutSeconds=30, janitorTimeoutSeconds=60,
                   lambdaCodeSha256Base64="job-hash", janitorCodeSha256Base64="janitor-hash",
                   lambdaSecretEnvironmentSha256={}, janitorEnvironment={}, functionUrlAuthType="AWS_IAM")
        paths = security.ReleaseSecurityTest().policy_paths(directory, m)
        configs = {aws[k + "Function"]: {"Timeout": aws[k + "TimeoutSeconds"],
                   "CodeSha256": aws[k + "CodeSha256Base64"],
                   "Environment": {"Variables": aws[k + "Environment"]},
                   "Role": "arn:aws:iam::919437049909:role/" + aws[k + "Role"]}
                   for k in ("lambda", "janitor")}
        def reply(args, region):
            op = args[1]
            if op == "describe-images":
                return {"Images": [{"ImageId": aws["amiId"], "State": "available", "Public": False,
                    "RootDeviceName": "/dev/root", "BlockDeviceMappings": [{"DeviceName": "/dev/root", "Ebs": {
                    "Encrypted": True, "DeleteOnTermination": True, "SnapshotId": aws["rootSnapshotId"]}}]}]}
            if op == "get-function": return {"Configuration": configs[args[-1]]}
            if op == "get-role": return {"Role": {"Arn": "arn:aws:iam::919437049909:role/" + args[-1]}}
            if op == "get-function-url-config": return {"AuthType": "AWS_IAM"}
            if op == "get-key-policy": return {"Policy": paths["kmsPolicy"].read_text()}
            if op == "get-role-policy":
                kind = next(k for k in ("instance", "lambda", "janitor") if aws[k + "Role"] == args[3])
                return {"PolicyDocument": json.loads(paths[kind + "Policy"].read_text())}
            raise AssertionError(args)
        return m, paths, configs, reply

    def test_live_score_named_policy_matches_entire_artifact(self):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            m, paths, configs, reply = self.live_fixture(directory)
            m["scoreService"] = score_descriptor()
            paths["scoreRuntimePolicy"] = pathlib.Path(directory) / "score-runtime-policy.json"
            paths["scoreRuntimePolicy"].write_text(json.dumps(score_policy()))
            live_policy = score_policy()
            calls = []
            def with_score(args, region):
                if args[1] == "get-role-policy" and args[3] == "USD8ScoreLambdaRole":
                    calls.append(args)
                    self.assertEqual(args[-1], "ScoreRuntimePolicy")
                    return {"PolicyDocument": live_policy}
                return reply(args, region)
            for name in ("verify_live_authority", "verify_live_bucket_security", "verify_live_chain", "verify_live_bucket_cors", "verify_live_score"):
                stack.enter_context(mock.patch.object(V, name))
            stack.enter_context(mock.patch.object(V, "aws_json", side_effect=with_score))
            V.verify_live(m, paths, "https://fixture.invalid", {})
            self.assertEqual(len(calls), 1)
            live_policy["Statement"][1]["Action"] = ["dynamodb:GetItem"]
            with self.assertRaisesRegex(SystemExit, "IAM policy"):
                V.verify_live(m, paths, "https://fixture.invalid", {})

    def test_live_job_and_janitor_timeout_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            m, paths, configs, reply = self.live_fixture(directory)
            for name in ("verify_live_authority", "verify_live_bucket_security", "verify_live_chain", "verify_live_bucket_cors"):
                stack.enter_context(mock.patch.object(V, name))
            stack.enter_context(mock.patch.object(V, "aws_json", side_effect=reply))
            V.verify_live(m, paths, "https://fixture.invalid", {})
            for kind in ("lambda", "janitor"):
                config = configs[m["aws"][kind + "Function"]]
                expected = config["Timeout"]
                for value in (None, expected + 1):
                    config["Timeout"] = value
                    with self.subTest(kind=kind, value=value), self.assertRaisesRegex(SystemExit, "timeout"):
                        V.verify_live(m, paths, "https://fixture.invalid", {})
                config["Timeout"] = expected


if __name__ == "__main__":
    unittest.main()
