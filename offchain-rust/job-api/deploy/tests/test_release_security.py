import copy
import json
import pathlib
import unittest
from unittest import mock
from test_release_manifest import VERIFY_MODULE as V

DEPLOY = pathlib.Path(__file__).parents[1]


def manifest():
    return {"status": "final", "Measurements": {"PCR0": "1" * 96},
            "recipientAttestation": {"PCR3": V.pcr3_for_role_arn("arn:aws:iam::919437049909:role/USD8TeeInstanceRole")},
            "aws": {
                "region": "eu-central-1", "amiId": "ami-123456789abcdef01",
                "kmsKeyId": "arn:aws:kms:eu-central-1:919437049909:key/11111111-2222-3333-4444-555555555555",
                "instanceRole": "USD8TeeInstanceRole", "instanceRoleArn": "arn:aws:iam::919437049909:role/USD8TeeInstanceRole",
                "instancePolicyName": "InstancePolicy", "lambdaRole": "USD8TeeLambdaRole",
                "lambdaPolicyName": "LambdaPolicy", "janitorRole": "JanitorRole", "janitorPolicyName": "JanitorPolicy",
                "lambdaFunction": "usd8-tee-job-api", "janitorFunction": "usd8-tee-janitor",
                "lambdaEnvironment": {"USD8_JOB_BUCKET": "usd8-tee-jobs-919437049909-eu-central-1",
                    "USD8_TEE_AMI_ID": "ami-123456789abcdef01", "USD8_TEE_INSTANCE_TYPE": "c6i.xlarge",
                    "USD8_TEE_INSTANCE_PROFILE": "USD8TeeInstanceProfile",
                    "USD8_TEE_SUBNET_ID": "subnet-0d42339eecdaddbaa",
                    "USD8_TEE_SECURITY_GROUP_ID": "sg-0d93490bebb3d2251"}}}


def score_descriptor():
    return {"function": "usd8-score-api", "roleArn": "arn:aws:iam::919437049909:role/USD8ScoreLambdaRole",
            "policyName": "ScoreRuntimePolicy", "environment": {"USD8_SCORE_TABLE": "scores"},
            "secretEnvironmentSha256": {}, "functionUrlAuthType": "NONE", "timeoutSeconds": 25}


def score_policy():
    return {"Version": "2012-10-17", "Statement": [
        {"Sid": "WriteDedicatedScoreLogs", "Effect": "Allow", "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
         "Resource": "arn:aws:logs:eu-central-1:919437049909:log-group:/aws/lambda/usd8-score-api:*"},
        {"Sid": "UseDedicatedScoreCheckpointTable", "Effect": "Allow", "Action": ["dynamodb:GetItem", "dynamodb:UpdateItem"],
         "Resource": "arn:aws:dynamodb:eu-central-1:919437049909:table/scores"}]}


class ReleaseSecurityTest(unittest.TestCase):
    def setUp(self):
        printer = mock.patch("builtins.print")
        printer.start()
        self.addCleanup(printer.stop)

    def policy_paths(self, directory, m):
        paths = {}
        for kind, filename in (("lambdaPolicy", "lambda-role-policy.json"), ("janitorPolicy", "janitor-role-policy.json"),
                               ("kmsPolicy", "kms-key-policy.json"), ("instancePolicy", "instance-role-policy.json"),
                               ("bucketPolicy", "bucket-policy.json"), ("bucketCors", "bucket-cors.json")):
            policy = json.loads((DEPLOY / filename).read_text())
            for s in policy.get("Statement", []):
                if s.get("Sid") in {"AttestedDecryptOnly", "AttestedEnclaveDecryptOnly"}:
                    s["Condition"]["StringEqualsIgnoreCase"] = {
                        "kms:RecipientAttestation:ImageSha384": m["Measurements"]["PCR0"],
                        "kms:RecipientAttestation:PCR3": m["recipientAttestation"]["PCR3"]}
                    if kind == "instancePolicy":
                        s["Resource"] = m["aws"]["kmsKeyId"]
                if s.get("Sid") == "LaunchTaggedWorkers":
                    s["Condition"]["ArnEquals"] = {"ec2:InstanceProfile": "arn:aws:iam::919437049909:instance-profile/USD8TeeInstanceProfile"}
                if s.get("Sid") == "UseApprovedWorkerInfrastructure":
                    s["Resource"][0] = "arn:aws:ec2:eu-central-1::image/" + m["aws"]["amiId"]
            paths[kind] = pathlib.Path(directory) / filename
            paths[kind].write_text(json.dumps(policy))
        return paths

    def test_semantic_policy_gate_rejects_extra_decrypt_and_wildcard_subnet(self):
        import tempfile
        m = manifest()
        with tempfile.TemporaryDirectory() as directory:
            paths = self.policy_paths(directory, m)
            V.verify_policy_bindings(m, paths)
            for artifact in ("kmsPolicy", "lambdaPolicy"):
                original = paths[artifact].read_text()
                policy = json.loads(original)
                if artifact == "kmsPolicy":
                    policy["Statement"].append({"Sid": "Backdoor", "Effect": "Allow", "Action": "kms:Decrypt", "Resource": "*", "Principal": "*"})
                else:
                    policy["Statement"][4]["Resource"][1] = "arn:aws:ec2:eu-central-1:919437049909:subnet/*"
                paths[artifact].write_text(json.dumps(policy))
                with self.subTest(artifact=artifact), self.assertRaisesRegex(SystemExit, "reviewed policy"):
                    V.verify_policy_bindings(m, paths)
                paths[artifact].write_text(original)
            m["aws"]["lambdaEnvironment"]["USD8_TEE_SUBNET_ID"] = "subnet-fffffffffffffffff"
            with self.assertRaisesRegex(SystemExit, "launch resource"):
                V.verify_policy_bindings(m, paths)

    def test_grants_missing_denied_or_nonempty_fail_closed(self):
        for response in ({}, {"Grants": [{"Operations": ["Decrypt"]}]},
                         {"Grants": [], "NextMarker": "more"}):
            with self.subTest(response=response), mock.patch.object(V, "aws_json", return_value=response):
                with self.assertRaisesRegex(SystemExit, "grant inventory"):
                    V.verify_kms_grants(manifest()["aws"])
        with mock.patch.object(V, "aws_json", side_effect=SystemExit("AWS query failed: denied")):
            with self.assertRaisesRegex(SystemExit, "grant inventory.*uninspectable"):
                V.verify_kms_grants(manifest()["aws"])
        with mock.patch.object(V, "aws_json", return_value={"Grants": []}):
            V.verify_kms_grants(manifest()["aws"])

    def test_bucket_controls_reject_lifecycle_expiry_and_public_access(self):
        m = manifest()
        encryption = {"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}
        replies = {
            "get-bucket-lifecycle-configuration": json.loads((DEPLOY / "bucket-lifecycle.json").read_text()),
            "get-bucket-policy": {"Policy": (DEPLOY / "bucket-policy.json").read_text()},
            "get-bucket-versioning": {"Status": "Enabled"},
            "get-public-access-block": {"PublicAccessBlockConfiguration": {k: True for k in
                ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")}},
            "get-bucket-encryption": {"ServerSideEncryptionConfiguration": encryption},
            "get-bucket-ownership-controls": {"OwnershipControls": {"Rules": [{"ObjectOwnership": "BucketOwnerEnforced"}]}},
        }
        with mock.patch.object(V, "aws_json", side_effect=lambda args, region: replies[args[1]]):
            V.verify_live_bucket_security(m, {"bucketEncryption": encryption})
            original = copy.deepcopy(replies)
            for mutation in ("settlements", "launch", "public"):
                replies = copy.deepcopy(original)
                if mutation == "settlements":
                    replies["get-bucket-lifecycle-configuration"]["Rules"].append({"ID": "Bad", "Status": "Enabled", "Filter": {"Prefix": "settlements/"}, "Expiration": {"Days": 1}})
                elif mutation == "launch":
                    replies["get-bucket-lifecycle-configuration"]["Rules"][2]["Expiration"]["Days"] = 2
                else:
                    replies["get-public-access-block"]["PublicAccessBlockConfiguration"]["BlockPublicPolicy"] = False
                with self.subTest(mutation=mutation), self.assertRaises(SystemExit):
                    V.verify_live_bucket_security(m, {"bucketEncryption": encryption})

    def test_independent_baseline_rejects_self_updated_manifest_and_env(self):
        import tempfile
        m = {"releaseId": "a" * 64}
        baseline = {"releaseId": m["releaseId"], "roleTrustPolicies": {}, "bucketEncryption": {}}
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "approved.json"
            path.write_text(json.dumps(baseline))
            digest = V.sha256(path)
            self.assertEqual(V.verify_security_baseline(m, path, digest), baseline)
            m["releaseId"] = "b" * 64  # attacker rehashed an unexpected env/policy
            with self.assertRaisesRegex(SystemExit, "independently approved"):
                V.verify_security_baseline(m, path, digest)
            baseline["releaseId"] = m["releaseId"]
            path.write_text(json.dumps(baseline))
            with self.assertRaisesRegex(SystemExit, "baseline.*digest"):
                V.verify_security_baseline(m, path, digest)
        with self.assertRaisesRegex(SystemExit, "independent security baseline"):
            V.verify_live({"status": "final"}, {}, "https://example.invalid")

    def test_effective_inventory_binds_profile_and_trust(self):
        m = manifest()
        aws = m["aws"]
        trust = {"Version": "2012-10-17", "Statement": []}
        baseline = {"roleTrustPolicies": {aws[k + "Role"]: trust for k in ("instance", "lambda", "janitor")}}
        def reply(args, region):
            op = args[1]
            if op == "list-grants": return {"Grants": []}
            if op == "get-instance-profile": return {"InstanceProfile": {"Roles": [{"Arn": aws["instanceRoleArn"]}]}}
            role = args[args.index("--role-name") + 1]
            kind = next(k for k in ("instance", "lambda", "janitor") if aws[k + "Role"] == role)
            if op == "get-role": return {"Role": {"Arn": "arn:aws:iam::919437049909:role/" + role, "AssumeRolePolicyDocument": trust}}
            if op == "list-role-policies": return {"PolicyNames": [aws[kind + "PolicyName"]]}
            if op == "list-attached-role-policies": return {"AttachedPolicies": []}
            raise AssertionError(args)
        with mock.patch.object(V, "aws_json", side_effect=reply):
            V.verify_live_authority(m, baseline)
        def wrong_profile(args, region):
            if args[1] == "get-instance-profile": return {"InstanceProfile": {"Roles": [{"Arn": "arn:wrong"}]}}
            return reply(args, region)
        with mock.patch.object(V, "aws_json", side_effect=wrong_profile):
            with self.assertRaisesRegex(SystemExit, "profile"):
                V.verify_live_authority(m, baseline)

    def test_score_role_must_be_distinct_from_other_runtime_roles(self):
        import tempfile
        m = manifest()
        m["scoreService"] = score_descriptor()
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "score.json"
            path.write_text(json.dumps(score_policy()))
            for kind in ("instance", "lambda", "janitor"):
                m["scoreService"]["roleArn"] = "arn:aws:iam::919437049909:role/" + m["aws"][kind + "Role"]
                with self.subTest(kind=kind), self.assertRaisesRegex(SystemExit, "distinct"):
                    V.verify_score_runtime_policy(m, {"scoreRuntimePolicy": path})

    def test_score_authority_includes_complete_inventory_trust_and_boundary(self):
        m = manifest()
        m["scoreService"] = score_descriptor()
        aws = m["aws"]
        score_role = "USD8ScoreLambdaRole"
        trust = {"Version": "2012-10-17", "Statement": []}
        baseline = {"roleTrustPolicies": {role: copy.deepcopy(trust) for role in
            [aws[k + "Role"] for k in ("instance", "lambda", "janitor")] + [score_role]}}
        responses = {"list-role-policies": {"PolicyNames": ["ScoreRuntimePolicy"]},
                     "list-attached-role-policies": {"AttachedPolicies": []},
                     "get-role": {"Role": {"Arn": m["scoreService"]["roleArn"], "AssumeRolePolicyDocument": trust}}}
        def reply(args, region):
            op = args[1]
            if op == "list-grants": return {"Grants": []}
            if op == "get-instance-profile": return {"InstanceProfile": {"Roles": [{"Arn": aws["instanceRoleArn"]}]}}
            role = args[args.index("--role-name") + 1]
            if role == score_role:
                value = responses[op]
                if isinstance(value, BaseException): raise value
                return value
            kind = next(k for k in ("instance", "lambda", "janitor") if aws[k + "Role"] == role)
            if op == "get-role": return {"Role": {"Arn": "arn:aws:iam::919437049909:role/" + role, "AssumeRolePolicyDocument": trust}}
            if op == "list-role-policies": return {"PolicyNames": [aws[kind + "PolicyName"]]}
            if op == "list-attached-role-policies": return {"AttachedPolicies": []}
            raise AssertionError(args)
        with mock.patch.object(V, "aws_json", side_effect=reply):
            V.verify_live_authority(m, baseline)
            original = copy.deepcopy(responses)
            for op, bad in (
                ("list-role-policies", {"PolicyNames": ["ScoreRuntimePolicy", "Backdoor"]}),
                ("list-role-policies", {"PolicyNames": ["OtherName"]}),
                ("list-role-policies", {"PolicyNames": ["ScoreRuntimePolicy"], "IsTruncated": True}),
                ("list-role-policies", SystemExit("denied")),
                ("list-attached-role-policies", {"AttachedPolicies": [{"PolicyArn": "arn:extra"}]}),
                ("list-attached-role-policies", {}),
                ("list-attached-role-policies", SystemExit("denied")),
                ("get-role", {"Role": {"AssumeRolePolicyDocument": {}}}),
                ("get-role", {"Role": {**original["get-role"]["Role"], "PermissionsBoundary": {"PermissionsBoundaryArn": "arn:boundary"}}}),
                ("get-role", {"Role": {**original["get-role"]["Role"], "PermissionsBoundary": {}}}),
                ("get-role", {"Role": {**original["get-role"]["Role"], "Arn": "arn:wrong"}}),
            ):
                responses = copy.deepcopy(original)
                responses[op] = bad
                with self.subTest(op=op, bad=bad), self.assertRaises(SystemExit):
                    V.verify_live_authority(m, baseline)
            responses = original
            del baseline["roleTrustPolicies"][score_role]
            with self.assertRaisesRegex(SystemExit, "trust inventory"):
                V.verify_live_authority(m, baseline)
            del m["scoreService"]
            V.verify_live_authority(m, baseline)
            baseline["roleTrustPolicies"][score_role] = trust
            with self.assertRaisesRegex(SystemExit, "trust inventory"):
                V.verify_live_authority(m, baseline)

    def test_included_score_package_hash_and_environment_are_live_bound(self):
        import base64
        m = manifest()
        m["artifacts"] = {"scoreLambda": {"sha256": "a" * 64}}
        m["scoreService"] = {"function": "usd8-score-api", "roleArn": "arn:aws:iam::919437049909:role/USD8ScoreLambdaRole",
            "environment": {"USD8_SCORE_TABLE": "scores"}, "secretEnvironmentSha256": {}, "functionUrlAuthType": "NONE", "timeoutSeconds": 25}
        config = {"Timeout": 25, "CodeSha256": base64.b64encode(bytes.fromhex("a" * 64)).decode(),
                  "Role": m["scoreService"]["roleArn"], "Environment": {"Variables": {"USD8_SCORE_TABLE": "scores"}}}
        def reply(args, region):
            if args[1] == "get-function": return {"Configuration": config}
            return {"AuthType": "NONE"}
        with mock.patch.object(V, "aws_json", side_effect=reply):
            V.verify_live_score(m)
            config["Timeout"] = 30
            with self.assertRaisesRegex(SystemExit, "score.*timeout"):
                V.verify_live_score(m)
            config["Timeout"] = 25
            config["CodeSha256"] = "wrong"
            with self.assertRaisesRegex(SystemExit, "score.*hash"):
                V.verify_live_score(m)
            config["CodeSha256"] = base64.b64encode(bytes.fromhex("a" * 64)).decode()
            config["Environment"]["Variables"]["UNEXPECTED"] = "secret-not-to-print"
            with self.assertRaises(SystemExit) as error:
                V.verify_live_score(m)
            self.assertNotIn("secret-not-to-print", str(error.exception))

    def test_optional_score_artifact_requires_descriptor_and_hash(self):
        import tempfile
        import test_release_manifest as fixtures
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture = fixtures.ReleaseManifestTest()
            path = fixture.make_release(root)
            m = json.loads(path.read_text())
            (root / "score-lambda.zip").write_bytes(b"synthetic-score-fixture")
            m["artifacts"]["scoreLambda"] = {"path": "score-lambda.zip", "sha256": V.sha256(root / "score-lambda.zip")}
            m["scoreService"] = score_descriptor()
            (root / "score-runtime-policy.json").write_text(json.dumps(score_policy()))
            m["artifacts"]["scoreRuntimePolicy"] = {"path": "score-runtime-policy.json", "sha256": V.sha256(root / "score-runtime-policy.json")}
            path.write_text(json.dumps(m))
            fixture.write_checksums(root, m["artifacts"])
            V.verify(path, True, False)
            original = copy.deepcopy(m)
            policy_path = root / "score-runtime-policy.json"
            for mutation in ("missing-update", "wildcard", "wrong-table", "extra-policy", "secret-table", "wrong-env", "bad-name", "wrong-account"):
                m = copy.deepcopy(original)
                policy = score_policy()
                if mutation == "missing-update": policy["Statement"][1]["Action"] = ["dynamodb:GetItem"]
                if mutation == "wildcard": policy["Statement"][1]["Resource"] = "*"
                if mutation == "wrong-table": policy["Statement"][1]["Resource"] += "-other"
                if mutation == "extra-policy": policy["Statement"].append({"Effect": "Allow", "Action": "*", "Resource": "*"})
                if mutation == "secret-table":
                    del m["scoreService"]["environment"]["USD8_SCORE_TABLE"]
                    m["scoreService"]["secretEnvironmentSha256"]["USD8_SCORE_TABLE"] = "a" * 64
                if mutation == "wrong-env": m["scoreService"]["environment"]["USD8_SCORE_TABLE"] = "other-table"
                if mutation == "bad-name": m["scoreService"]["policyName"] = "*"
                if mutation == "wrong-account": m["scoreService"]["roleArn"] = m["scoreService"]["roleArn"].replace("919437049909", "111111111111")
                policy_path.write_text(json.dumps(policy))
                m["artifacts"]["scoreRuntimePolicy"]["sha256"] = V.sha256(policy_path)
                path.write_text(json.dumps(m))
                fixture.write_checksums(root, m["artifacts"])
                with self.subTest(mutation=mutation), self.assertRaisesRegex(SystemExit, "score"):
                    V.verify(path, True, False)
            policy_path.write_text(json.dumps(score_policy()))
            path.write_text(json.dumps(original))
            fixture.write_checksums(root, original["artifacts"])
            (root / "score-lambda.zip").write_bytes(b"tampered")
            with self.assertRaisesRegex(SystemExit, "scoreLambda hash mismatch"):
                V.verify(path, True, False)

    def test_live_chain_binds_promoter_module_environment(self):
        import test_release_manifest as fixtures
        fixture = fixtures.ReleaseManifestTest()
        m = fixture.chain_manifest()
        m["aws"] = {"lambdaEnvironment": {"USD8_DEFI_INSURANCE": "0x" + "d" * 40}}
        with mock.patch.object(V, "rpc_json", side_effect=fixture.chain_rpc(m)):
            with self.assertRaisesRegex(SystemExit, "module environment"):
                V.verify_live_chain(m, "https://fixture.invalid")

    def test_control_iam_and_readonly_grant_auditor_are_narrow(self):
        policy = json.loads((DEPLOY / "lambda-role-policy.json").read_text())
        statements = {s["Sid"]: s for s in policy["Statement"]}
        bucket = "arn:aws:s3:::usd8-tee-jobs-919437049909-eu-central-1/"
        self.assertIn(bucket + "control/*", statements["CreateRequests"]["Resource"])
        self.assertIn(bucket + "control/*", statements["ReadJobs"]["Resource"])
        self.assertIn("control/*", statements["ListExactJobPrefixes"]["Condition"]["ForAnyValue:StringLike"]["s3:prefix"])
        self.assertEqual(statements["ObserveWorkerTermination"]["Action"], "ec2:DescribeInstances")
        bucket_policy = json.loads((DEPLOY / "bucket-policy.json").read_text())
        create_only = next(s for s in bucket_policy["Statement"] if s["Sid"] == "RequireCreateIfAbsent")
        self.assertNotIn(bucket + "control/*", create_only["Resource"])
        self.assertNotIn("control/", (DEPLOY / "instance-role-policy.json").read_text())
        self.assertNotIn("control/", (DEPLOY / "bucket-lifecycle.json").read_text())
        kms = json.loads((DEPLOY / "kms-key-policy.json").read_text())
        audit = next((s for s in kms["Statement"] if s["Sid"] == "ReadOnlyGrantAudit"), None)
        self.assertEqual(audit, {"Sid": "ReadOnlyGrantAudit", "Effect": "Allow", "Principal": {
            "AWS": "arn:aws:iam::919437049909:user/hermes-tee-agent"}, "Action": "kms:ListGrants", "Resource": "*"})

    def test_optional_reconciliation_bound_is_positive_safe_integer(self):
        env = {**manifest()["aws"]["lambdaEnvironment"], "USD8_REGISTRY": "0x" + "a" * 40,
            "USD8_DEFI_INSURANCE": "0x" + "b" * 40, "USD8_MAX_ACTIVE_WORKERS": "4", "USD8_MAX_STARTS_PER_HOUR": "16"}
        V.verify_job_environment_schema(env)
        key = "USD8_EC2_RECONCILIATION_BOUND_SECONDS"
        for value in ("1", "9007199254740991"):
            V.verify_job_environment_schema({**env, key: value})
        for value in ("", "0", "-1", "1.5", "01", "9007199254740992", 1, True):
            with self.subTest(value=value), self.assertRaises(SystemExit):
                V.verify_job_environment_schema({**env, key: value})

    def test_job_security_environment_is_explicit_and_bounded(self):
        env = {**manifest()["aws"]["lambdaEnvironment"], "USD8_REGISTRY": "0x" + "a" * 40,
            "USD8_DEFI_INSURANCE": "0x" + "b" * 40, "USD8_MAX_ACTIVE_WORKERS": "4", "USD8_MAX_STARTS_PER_HOUR": "16"}
        V.verify_job_environment_schema(env)
        V.verify_job_environment_schema({**env, "USD8_MAX_ACTIVE_WORKERS": "0"})
        for key, value in (("USD8_MAX_ACTIVE_WORKERS", "129"), ("USD8_MAX_ACTIVE_WORKERS", "-1"), ("USD8_MAX_STARTS_PER_HOUR", "0"),
                           ("USD8_DEFI_INSURANCE", "0x" + "0" * 40), ("UNEXPECTED", "secret-not-to-print")):
            with self.subTest(key=key), self.assertRaises(SystemExit) as error:
                V.verify_job_environment_schema({**env, key: value})
            self.assertNotIn("secret-not-to-print", str(error.exception))

    def test_score_operator_policy_preserves_hard_timeout_lease_order(self):
        policy = {"calculationTimeoutMs": 20000, "leaseSeconds": 30, "failureCooldownSeconds": 30,
                  "budgetWindowSeconds": 60, "budgetMaxAttempts": 10}
        score = {"environment": {}, "secretEnvironmentSha256": {}, "timeoutSeconds": 25}
        V.verify_score_work_policy(score)
        for key, value in (("calculationTimeoutMs", 25000), ("leaseSeconds", 25), ("budgetMaxAttempts", 1001), ("unexpected", 1)):
            score["environment"]["USD8_SCORE_WORK_POLICY_JSON"] = json.dumps({**policy, key: value})
            with self.subTest(key=key), self.assertRaisesRegex(SystemExit, "score work policy"):
                V.verify_score_work_policy(score)

    def test_aws_errors_never_echo_environment_or_credentials(self):
        import subprocess
        with mock.patch.object(V.subprocess, "run", side_effect=subprocess.CalledProcessError(
                1, ["aws"], stderr="plaintext-environment-secret")):
            with self.assertRaises(SystemExit) as error:
                V.aws_json(["lambda", "get-function", "--function-name", "fixture"], "eu-central-1")
            self.assertNotIn("plaintext-environment-secret", str(error.exception))

    def test_canonical_selected_kms_key_cannot_be_wildcard(self):
        import tempfile
        m = manifest()
        m["aws"]["kmsKeyId"] = "*"
        with tempfile.TemporaryDirectory() as directory:
            paths = self.policy_paths(directory, m)
            with self.assertRaisesRegex(SystemExit, "canonical KMS"):
                V.verify_policy_bindings(m, paths)

    def test_extra_inline_or_managed_policy_fails_inventory(self):
        m = manifest()
        for response in ({"PolicyNames": ["InstancePolicy", "Unexpected"]},
                         {"PolicyNames": ["InstancePolicy"], "AttachedPolicies": [{"PolicyArn": "arn:extra"}]}):
            with self.subTest(response=response), mock.patch.object(V, "aws_json", return_value=response):
                with self.assertRaisesRegex(SystemExit, "policy inventory"):
                    V.verify_role_policy_inventory(m["aws"], "instance")


if __name__ == "__main__":
    unittest.main()
