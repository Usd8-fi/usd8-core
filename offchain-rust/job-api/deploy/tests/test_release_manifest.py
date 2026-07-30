import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import urllib.error
import unittest
from typing import Optional
from unittest import mock

VERIFY = pathlib.Path(__file__).parents[1] / "verify-release.py"
PCR0 = "1" * 96
PCR3 = "c" * 96
TEE_PCR_HASH = "0x19a6783258a3fb88892b020755695164658cba4311990d68e64d9b44178037f4"
INSTANCE_ROLE_ARN = "arn:aws:iam::919437049909:role/USD8TeeInstanceRole"

SPEC = importlib.util.spec_from_file_location("verify_release", VERIFY)
assert SPEC is not None and SPEC.loader is not None
VERIFY_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY_MODULE)


class ReleaseManifestTest(unittest.TestCase):
    def chain_manifest(self) -> dict:
        return {
            "chainId": 11155111,
            "registry": "0x" + "9" * 40,
            "teePcrHash": "0x" + "a" * 64,
            "signer": "0x" + "b" * 40,
        }

    def chain_rpc(self, manifest: dict, *, pcr: Optional[str] = None, signer_authorized: bool = True):
        defi_insurance = "0x" + "c" * 40

        def request(_rpc_url: str, method: str, params: list):
            if method == "eth_chainId":
                return hex(manifest["chainId"])
            if method == "eth_getCode":
                self.assertIn(params[0].lower(), {manifest["registry"].lower(), defi_insurance})
                self.assertEqual(params[1], "latest")
                return "0x6000"
            self.assertEqual(method, "eth_call")
            request_data = params[0]
            self.assertEqual(params[1], "latest")
            if request_data["data"] == VERIFY_MODULE.TEE_PCR_HASH_SELECTOR:
                self.assertEqual(request_data["to"].lower(), manifest["registry"].lower())
                return pcr or manifest["teePcrHash"]
            if request_data["data"] == VERIFY_MODULE.DEFI_INSURANCE_SELECTOR:
                self.assertEqual(request_data["to"].lower(), manifest["registry"].lower())
                return "0x" + "0" * 24 + defi_insurance[2:]
            self.assertEqual(request_data["to"], defi_insurance)
            self.assertEqual(
                request_data["data"],
                VERIFY_MODULE.IS_TEE_SIGNER_SELECTOR + "0" * 24 + manifest["signer"][2:],
            )
            return "0x" + "0" * 63 + ("1" if signer_authorized else "0")

        return request

    def write_checksums(self, root: pathlib.Path, entries: dict) -> None:
        (root / "SHA256SUMS").write_text(
            "".join(f"{entry['sha256']}  {entry['path']}\n" for entry in entries.values())
        )

    def test_live_environment_comparison_rejects_extra_variables(self) -> None:
        expected = {"USD8_REGISTRY": "0x1234"}
        with self.assertRaises(SystemExit):
            VERIFY_MODULE.verify_environment(
                "usd8-tee-job-api",
                {**expected, "USD8_TEE_MAX_AGE_SECONDS": "1800"},
                expected,
            )
        VERIFY_MODULE.verify_environment("usd8-tee-job-api", expected, expected)

    def test_live_verifier_exposes_explicit_rpc_url_option(self) -> None:
        result = subprocess.run(
            [sys.executable, str(VERIFY), "--help"],
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--rpc-url", result.stdout)

    def test_live_rpc_requires_direct_https_endpoint(self) -> None:
        VERIFY_MODULE.validate_live_rpc_url("https://sepolia.example.invalid/rpc")
        for invalid in (
            "http://sepolia.example.invalid/rpc",
            "https://user@sepolia.example.invalid/rpc",
            "https://sepolia.example.invalid:8443/rpc",
        ):
            with self.assertRaisesRegex(SystemExit, "HTTPS"):
                VERIFY_MODULE.validate_live_rpc_url(invalid)

    def test_live_rpc_refuses_redirects(self) -> None:
        handler = VERIFY_MODULE.NoRedirect()
        with self.assertRaises(urllib.error.HTTPError) as raised:
            handler.redirect_request(None, None, 302, "https://redirect.invalid", {}, None)
        raised.exception.close()

    def test_live_chain_preflight_accepts_manifest_bound_registry_and_signer(self) -> None:
        manifest = self.chain_manifest()
        with mock.patch.object(VERIFY_MODULE, "rpc_json", side_effect=self.chain_rpc(manifest)) as rpc:
            VERIFY_MODULE.verify_live_chain(manifest, "https://sepolia.example.invalid")

        self.assertEqual(
            [call.args[1] for call in rpc.call_args_list],
            ["eth_chainId", "eth_getCode", "eth_call", "eth_call", "eth_getCode", "eth_call"],
        )

    def test_live_chain_preflight_rejects_stale_registry_pcr(self) -> None:
        manifest = self.chain_manifest()
        with mock.patch.object(
            VERIFY_MODULE,
            "rpc_json",
            side_effect=self.chain_rpc(manifest, pcr="0x" + "d" * 64),
        ):
            with self.assertRaisesRegex(SystemExit, "teePcrHash differs"):
                VERIFY_MODULE.verify_live_chain(manifest, "https://sepolia.example.invalid")

    def test_live_chain_preflight_rejects_unauthorized_manifest_signer(self) -> None:
        manifest = self.chain_manifest()
        with mock.patch.object(
            VERIFY_MODULE,
            "rpc_json",
            side_effect=self.chain_rpc(manifest, signer_authorized=False),
        ):
            with self.assertRaisesRegex(SystemExit, "does not authorize manifest signer"):
                VERIFY_MODULE.verify_live_chain(manifest, "https://sepolia.example.invalid")

    def test_live_verification_requires_rpc_url_before_aws_queries(self) -> None:
        with self.assertRaisesRegex(SystemExit, "requires --rpc-url"):
            VERIFY_MODULE.verify_live({"status": "final"}, {}, None)

    def test_live_environment_requires_committed_hmac_without_storing_secret(self) -> None:
        public = {"USD8_REGISTRY": "0x1234"}
        secret_name = "USD8_JOB_HMAC_KEY_B64"
        secret_value = "dGVzdC1zZWNyZXQ="
        secret_commitments = {secret_name: hashlib.sha256(secret_value.encode()).hexdigest()}

        VERIFY_MODULE.verify_environment(
            "usd8-tee-job-api",
            {**public, secret_name: secret_value},
            public,
            secret_commitments,
        )
        with self.assertRaises(SystemExit):
            VERIFY_MODULE.verify_environment(
                "usd8-tee-job-api",
                {**public, secret_name: "d3Jvbmctc2VjcmV0"},
                public,
                secret_commitments,
            )
        with self.assertRaises(SystemExit):
            VERIFY_MODULE.verify_environment(
                "usd8-tee-job-api",
                {**public, secret_name: secret_value, "UNDECLARED": "1"},
                public,
                secret_commitments,
            )
        self.assertNotIn(secret_value, json.dumps(secret_commitments))

    def test_pcr3_is_derived_from_the_instance_role_arn(self) -> None:
        self.assertEqual(
            VERIFY_MODULE.pcr3_for_role_arn(INSTANCE_ROLE_ARN),
            "1dc0aeefd8ca0b888ba8ed140ea3a1793eafd569a833d8b19a176e2a2cf8e95919561e4369d635546f97e1107c981c6b",
        )

    def test_attested_kms_principal_must_match_selected_instance_role(self) -> None:
        policy = {
            "Principal": {"AWS": INSTANCE_ROLE_ARN},
            "Condition": {"StringEqualsIgnoreCase": {
                "kms:RecipientAttestation:PCR3": VERIFY_MODULE.pcr3_for_role_arn(INSTANCE_ROLE_ARN),
            }},
        }
        VERIFY_MODULE.verify_attested_role_binding(policy, INSTANCE_ROLE_ARN)
        policy["Principal"]["AWS"] = "arn:aws:iam::919437049909:role/OtherRole"
        with self.assertRaises(SystemExit):
            VERIFY_MODULE.verify_attested_role_binding(policy, INSTANCE_ROLE_ARN)

    def make_release(self, root: pathlib.Path) -> pathlib.Path:
        artifacts = {
            "eif": "usd8-tee-enclave.eif",
            "parent": "usd8-tee-parent",
            "settlement": "usd8-settlement",
            "lambda": "lambda.zip",
            "janitor": "janitor.zip",
            "kmsPolicy": "kms-key-policy.json",
            "instancePolicy": "instance-role-policy.json",
        }
        policies = {
            "kmsPolicy": {
                "Statement": [{
                    "Sid": "AttestedEnclaveDecryptOnly",
                    "Condition": {"StringEqualsIgnoreCase": {
                        "kms:RecipientAttestation:ImageSha384": PCR0,
                        "kms:RecipientAttestation:PCR3": PCR3,
                    }},
                }]
            },
            "instancePolicy": {
                "Statement": [{
                    "Sid": "AttestedDecryptOnly",
                    "Condition": {"StringEqualsIgnoreCase": {
                        "kms:RecipientAttestation:ImageSha384": PCR0,
                        "kms:RecipientAttestation:PCR3": PCR3,
                    }},
                }]
            },
        }
        entries = {}
        for name, relative in artifacts.items():
            path = root / relative
            if name in policies:
                path.write_text(json.dumps(policies[name], sort_keys=True))
            else:
                path.write_bytes(f"fixture-{name}".encode())
            entries[name] = {
                "path": relative,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        self.write_checksums(root, entries)
        manifest = {
            "schemaVersion": 2,
            "status": "built",
            "source": {
                "sha256": "2" * 64,
                "gitCommit": "3" * 40,
                "gitDirty": False,
                "cargoLocks": {"root": "4" * 64, "jobApi": "5" * 64},
            },
            "toolchain": {
                "rustc": "rustc 1.94.1 (fixture)",
                "enclaveBaseImage": "amazonlinux@sha256:" + "6" * 64,
            },
            "Measurements": {
                "HashAlgorithm": "Sha384",
                "PCR0": PCR0,
                "PCR1": "7" * 96,
                "PCR2": "8" * 96,
            },
            "recipientAttestation": {"PCR3": PCR3},
            "chainId": 11155111,
            "network": "sepolia",
            "registry": "0x" + "9" * 40,
            "teePcrHash": TEE_PCR_HASH,
            "signer": "0x" + "b" * 40,
            "artifacts": entries,
        }
        path = root / "release-manifest.json"
        path.write_text(json.dumps(manifest, indent=2))
        return path

    def run_verify(self, manifest: pathlib.Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(VERIFY), str(manifest), "--allow-built"],
            capture_output=True,
            text=True,
        )

    def test_accepts_complete_hash_bound_build(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.make_release(pathlib.Path(directory))
            result = self.run_verify(manifest)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("RELEASE_VERIFY_PASSED", result.stdout)

    def test_rejects_dirty_source_build(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest_path = self.make_release(root)
            manifest = json.loads(manifest_path.read_text())
            manifest["source"]["gitDirty"] = True
            manifest_path.write_text(json.dumps(manifest))

            result = self.run_verify(manifest_path)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("dirty source", result.stderr)

    def test_rejects_non_sepolia_release_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest_path = self.make_release(root)
            manifest = json.loads(manifest_path.read_text())
            manifest["network"] = "ethereum"
            manifest["chainId"] = 1
            manifest_path.write_text(json.dumps(manifest))

            result = self.run_verify(manifest_path)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Sepolia", result.stderr)

    def test_rejects_tee_pcr_hash_that_does_not_match_eif_measurements(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest_path = self.make_release(root)
            manifest = json.loads(manifest_path.read_text())
            manifest["teePcrHash"] = "0x" + "f" * 64
            manifest_path.write_text(json.dumps(manifest))

            result = self.run_verify(manifest_path)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("TEE PCR hash does not match EIF measurements", result.stderr)

    def test_rejects_artifact_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest = self.make_release(root)
            (root / "lambda.zip").write_bytes(b"tampered")
            result = self.run_verify(manifest)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("artifact lambda hash mismatch", result.stderr)

    def test_rejects_unmanifested_release_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest = self.make_release(root)
            (root / "aws-credentials").write_text("AWS_SECRET_ACCESS_KEY=not-a-real-secret")

            result = self.run_verify(manifest)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unmanifested", result.stderr)
            self.assertIn("aws-credentials", result.stderr)

    def test_rejects_stale_checksum_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest = self.make_release(root)
            lines = (root / "SHA256SUMS").read_text().splitlines()
            lines[0] = "0" * 64 + "  usd8-tee-enclave.eif"
            (root / "SHA256SUMS").write_text("\n".join(lines) + "\n")

            result = self.run_verify(manifest)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not exactly match", result.stderr)

    def test_rejects_policy_that_does_not_bind_eif_pcr0(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest_path = self.make_release(root)
            manifest = json.loads(manifest_path.read_text())
            policy_path = root / "kms-key-policy.json"
            policy = json.loads(policy_path.read_text())
            policy["Statement"][0]["Condition"]["StringEqualsIgnoreCase"][
                "kms:RecipientAttestation:ImageSha384"
            ] = "f" * 96
            policy_path.write_text(json.dumps(policy))
            manifest["artifacts"]["kmsPolicy"]["sha256"] = hashlib.sha256(
                policy_path.read_bytes()
            ).hexdigest()
            self.write_checksums(root, manifest["artifacts"])
            manifest_path.write_text(json.dumps(manifest))
            result = self.run_verify(manifest_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("kmsPolicy PCR0 does not match manifest", result.stderr)

    def test_rejects_policy_that_does_not_bind_expected_pcr3(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest_path = self.make_release(root)
            manifest = json.loads(manifest_path.read_text())
            policy_path = root / "instance-role-policy.json"
            policy = json.loads(policy_path.read_text())
            policy["Statement"][0]["Condition"]["StringEqualsIgnoreCase"][
                "kms:RecipientAttestation:PCR3"
            ] = "f" * 96
            policy_path.write_text(json.dumps(policy))
            manifest["artifacts"]["instancePolicy"]["sha256"] = hashlib.sha256(
                policy_path.read_bytes()
            ).hexdigest()
            self.write_checksums(root, manifest["artifacts"])
            manifest_path.write_text(json.dumps(manifest))

            result = self.run_verify(manifest_path)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("instancePolicy PCR3 does not match manifest", result.stderr)

    def test_rejects_artifact_path_escape(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest_path = self.make_release(root)
            manifest = json.loads(manifest_path.read_text())
            manifest["artifacts"]["lambda"]["path"] = "../lambda.zip"
            manifest_path.write_text(json.dumps(manifest))
            result = self.run_verify(manifest_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("artifact lambda has unsafe path", result.stderr)

    def test_rejects_shared_api_and_janitor_roles(self) -> None:
        with self.assertRaises(SystemExit):
            VERIFY_MODULE.verify_distinct_roles({"lambdaRole": "shared", "janitorRole": "shared"})


if __name__ == "__main__":
    unittest.main()
