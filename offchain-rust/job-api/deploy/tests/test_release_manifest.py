import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

VERIFY = pathlib.Path(__file__).parents[1] / "verify-release.py"
PCR0 = "1" * 96

SPEC = importlib.util.spec_from_file_location("verify_release", VERIFY)
assert SPEC is not None and SPEC.loader is not None
VERIFY_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY_MODULE)


class ReleaseManifestTest(unittest.TestCase):
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
                        "kms:RecipientAttestation:ImageSha384": PCR0
                    }},
                }]
            },
            "instancePolicy": {
                "Statement": [{
                    "Sid": "AttestedDecryptOnly",
                    "Condition": {"StringEqualsIgnoreCase": {
                        "kms:RecipientAttestation:ImageSha384": PCR0
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
            "chainId": 11155111,
            "network": "sepolia",
            "registry": "0x" + "9" * 40,
            "teePcrHash": "0x" + "a" * 64,
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

    def test_rejects_artifact_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest = self.make_release(root)
            (root / "lambda.zip").write_bytes(b"tampered")
            result = self.run_verify(manifest)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("artifact lambda hash mismatch", result.stderr)

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
            manifest_path.write_text(json.dumps(manifest))
            result = self.run_verify(manifest_path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("kmsPolicy PCR0 does not match manifest", result.stderr)

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
