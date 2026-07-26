#!/usr/bin/env python3
"""Fail-closed verification for USD8 TEE release bundles and live AWS state."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
from typing import Any, NoReturn

HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX96 = re.compile(r"^[0-9a-fA-F]{96}$")
ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
AMI = re.compile(r"^ami-[0-9a-f]+$")
REQUIRED_ARTIFACTS = {"eif", "parent", "settlement", "lambda", "janitor", "kmsPolicy", "instancePolicy"}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"RELEASE_VERIFY_FAILED: {message}")


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read JSON {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"JSON object required: {path}")
    return value


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def verify_distinct_roles(aws: dict) -> None:
    if aws.get("lambdaRole") == aws.get("janitorRole"):
        fail("API and janitor roles must be distinct")


def exact_artifact(root: pathlib.Path, entry: Any, name: str) -> pathlib.Path:
    if not isinstance(entry, dict) or set(entry) != {"path", "sha256"}:
        fail(f"artifact {name} must contain exactly path and sha256")
    relative = entry["path"]
    expected = entry["sha256"]
    if not isinstance(relative, str) or pathlib.PurePosixPath(relative).is_absolute() or ".." in pathlib.PurePosixPath(relative).parts:
        fail(f"artifact {name} has unsafe path")
    if not isinstance(expected, str) or not HEX64.fullmatch(expected):
        fail(f"artifact {name} has invalid SHA-256")
    candidate = root / relative
    if candidate.is_symlink():
        fail(f"artifact {name} is a symlink")
    path = candidate.resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError:
        fail(f"artifact {name} escapes release directory")
    if not path.is_file():
        fail(f"artifact {name} is missing")
    actual = sha256(path)
    if actual != expected:
        fail(f"artifact {name} hash mismatch: expected {expected}, got {actual}")
    return path


def statements_with_sid(policy: dict[str, Any], sid: str) -> list[dict[str, Any]]:
    statements = policy.get("Statement")
    if not isinstance(statements, list):
        fail("policy Statement must be an array")
    return [item for item in statements if isinstance(item, dict) and item.get("Sid") == sid]


def verify_policy_bindings(manifest: dict[str, Any], paths: dict[str, pathlib.Path]) -> None:
    pcr0 = manifest["Measurements"]["PCR0"]
    for artifact, sid in (("kmsPolicy", "AttestedEnclaveDecryptOnly"), ("instancePolicy", "AttestedDecryptOnly")):
        policy = load_json(paths[artifact])
        matches = statements_with_sid(policy, sid)
        if len(matches) != 1:
            fail(f"{artifact} must contain exactly one {sid} statement")
        actual = matches[0].get("Condition", {}).get("StringEqualsIgnoreCase", {}).get(
            "kms:RecipientAttestation:ImageSha384"
        )
        if actual != pcr0:
            fail(f"{artifact} PCR0 does not match manifest")
    if manifest["status"] == "final":
        policy = load_json(paths["lambdaPolicy"])
        ami_id = manifest["aws"]["amiId"]
        encoded = json.dumps(policy, sort_keys=True)
        if encoded.count(ami_id) != 1:
            fail("lambda policy must bind the manifest AMI exactly once")


def aws_json(args: list[str], region: str) -> Any:
    env = os.environ.copy()
    env["AWS_REGION"] = region
    env["AWS_DEFAULT_REGION"] = region
    try:
        output = subprocess.run(["aws", *args, "--output", "json"], check=True, capture_output=True, text=True, env=env)
        return json.loads(output.stdout)
    except (FileNotFoundError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        fail(f"AWS query failed: {detail.strip()}")


def verify_live(manifest: dict[str, Any], paths: dict[str, pathlib.Path]) -> None:
    if manifest["status"] != "final":
        fail("live verification requires a final release")
    aws = manifest["aws"]
    region = aws["region"]
    image_doc = aws_json(["ec2", "describe-images", "--image-ids", aws["amiId"]], region)
    images = image_doc.get("Images", [])
    if len(images) != 1:
        fail("live AMI is missing")
    image = images[0]
    if image.get("ImageId") != aws["amiId"]:
        fail("live AMI ID differs from manifest")
    root = image.get("RootDeviceName")
    mapping = next((item.get("Ebs") for item in image.get("BlockDeviceMappings", []) if item.get("DeviceName") == root), None)
    if image.get("State") != "available" or image.get("Public") is not False:
        fail("live AMI is unavailable or public")
    if not isinstance(mapping, dict):
        fail("live AMI lacks root EBS")
    if mapping.get("Encrypted") is not True or mapping.get("DeleteOnTermination") is not True:
        fail("live AMI root is not encrypted and delete-on-termination")
    if mapping.get("SnapshotId") != aws["rootSnapshotId"]:
        fail("live AMI root snapshot differs from manifest")

    for artifact, function, expected_code, role in (
        ("lambda", aws["lambdaFunction"], aws["lambdaCodeSha256Base64"], aws["lambdaRole"]),
        ("janitor", aws["janitorFunction"], aws["janitorCodeSha256Base64"], aws["janitorRole"]),
    ):
        function_doc = aws_json(["lambda", "get-function", "--function-name", function], region)
        config = function_doc.get("Configuration", {})
        if config.get("CodeSha256") != expected_code:
            fail(f"live {function} code hash differs from manifest")
        expected_environment = aws["lambdaEnvironment" if artifact == "lambda" else "janitorEnvironment"]
        actual_environment = config.get("Environment", {}).get("Variables", {})
        if any(actual_environment.get(key) != value for key, value in expected_environment.items()):
            fail(f"live {function} environment differs from manifest")
        role_doc = aws_json(["iam", "get-role", "--role-name", role], region)
        if config.get("Role") != role_doc.get("Role", {}).get("Arn"):
            fail(f"live {function} execution role differs from manifest")
    function_url = aws_json(
        ["lambda", "get-function-url-config", "--function-name", aws["lambdaFunction"]], region
    )
    if function_url.get("AuthType") != aws["functionUrlAuthType"]:
        fail("live Lambda Function URL authorization differs from manifest")

    live_kms = aws_json(["kms", "get-key-policy", "--key-id", aws["kmsKeyId"], "--policy-name", "default"], region)
    try:
        live_kms_policy = json.loads(live_kms["Policy"])
    except (KeyError, TypeError, json.JSONDecodeError):
        fail("live KMS policy is malformed")
    if canonical_sha256(live_kms_policy) != canonical_sha256(load_json(paths["kmsPolicy"])):
        fail("live KMS policy differs from release")

    for artifact, role, policy_name in (
        ("instancePolicy", aws["instanceRole"], aws["instancePolicyName"]),
        ("lambdaPolicy", aws["lambdaRole"], aws["lambdaPolicyName"]),
        ("janitorPolicy", aws["janitorRole"], aws["janitorPolicyName"]),
    ):
        live = aws_json(["iam", "get-role-policy", "--role-name", role, "--policy-name", policy_name], region)
        if canonical_sha256(live.get("PolicyDocument")) != canonical_sha256(load_json(paths[artifact])):
            fail(f"live IAM policy {role}/{policy_name} differs from release")


def verify(manifest_path: pathlib.Path, allow_built: bool, live: bool) -> None:
    manifest = load_json(manifest_path)
    if manifest.get("schemaVersion") != 2:
        fail("schemaVersion must be 2")
    status = manifest.get("status")
    if status not in ({"built", "final"} if allow_built else {"final"}):
        fail("release must be final")
    source = manifest.get("source", {})
    if not HEX64.fullmatch(str(source.get("sha256", ""))):
        fail("source SHA-256 is invalid")
    if not re.fullmatch(r"[0-9a-f]{40}", str(source.get("gitCommit", ""))):
        fail("git commit is invalid")
    if not isinstance(source.get("gitDirty"), bool):
        fail("gitDirty must be boolean")
    if source["gitDirty"]:
        fail("dirty source releases are forbidden")
    locks = source.get("cargoLocks", {})
    if not all(HEX64.fullmatch(str(locks.get(name, ""))) for name in ("root", "jobApi")):
        fail("Cargo lock hashes are invalid")
    toolchain = manifest.get("toolchain", {})
    if not re.fullmatch(r"rustc 1\.94\.1(?: .*)?", str(toolchain.get("rustc", ""))):
        fail("release must use pinned rustc 1.94.1")
    if not re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", str(toolchain.get("enclaveBaseImage", ""))):
        fail("enclave base image is not digest-pinned")
    if manifest.get("network") not in {"ethereum", "sepolia"}:
        fail("network is invalid")
    expected_chain = 1 if manifest["network"] == "ethereum" else 11155111
    if manifest.get("chainId") != expected_chain:
        fail("chain ID does not match network")
    if not ADDRESS.fullmatch(str(manifest.get("registry", ""))) or int(manifest["registry"], 16) == 0:
        fail("registry is invalid")
    if not ADDRESS.fullmatch(str(manifest.get("signer", ""))):
        fail("signer is invalid")
    measurements = manifest.get("Measurements", {})
    if measurements.get("HashAlgorithm") != "Sha384" or not all(
        HEX96.fullmatch(str(measurements.get(name, ""))) for name in ("PCR0", "PCR1", "PCR2")
    ):
        fail("EIF measurements are invalid")
    if not re.fullmatch(r"0x[0-9a-fA-F]{64}", str(manifest.get("teePcrHash", ""))):
        fail("TEE PCR hash is invalid")

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict):
        fail("artifacts object is missing")
    required = set(REQUIRED_ARTIFACTS)
    if status == "final":
        required.update(("lambdaPolicy", "janitorPolicy"))
    if set(artifacts) != required:
        fail(f"artifact set mismatch: expected {sorted(required)}")
    root = manifest_path.resolve().parent
    paths = {name: exact_artifact(root, entry, name) for name, entry in artifacts.items()}
    verify_policy_bindings(manifest, paths)

    if status == "final":
        if not HEX64.fullmatch(str(manifest.get("releaseId", ""))):
            fail("releaseId is invalid")
        unsigned_manifest = dict(manifest)
        release_id = unsigned_manifest.pop("releaseId")
        if canonical_sha256(unsigned_manifest) != release_id:
            fail("releaseId does not bind the complete manifest")
        aws = manifest.get("aws", {})
        required_aws = {
            "region", "amiId", "rootSnapshotId", "lambdaFunction", "janitorFunction",
            "lambdaCodeSha256Base64", "janitorCodeSha256Base64", "kmsKeyId",
            "instanceRole", "instancePolicyName", "lambdaRole", "lambdaPolicyName",
            "janitorRole", "janitorPolicyName",
            "functionUrlAuthType", "lambdaEnvironment", "janitorEnvironment",
        }
        if set(aws) != required_aws:
            fail("AWS release fields are incomplete or unknown")
        verify_distinct_roles(aws)
        if not AMI.fullmatch(str(aws["amiId"])) or aws["region"] != "eu-central-1":
            fail("AWS AMI or region is invalid")
        expected_lambda_environment = {
            "USD8_REGISTRY", "USD8_JOB_BUCKET", "USD8_TEE_AMI_ID",
            "USD8_TEE_INSTANCE_TYPE", "USD8_TEE_INSTANCE_PROFILE",
            "USD8_TEE_SUBNET_ID", "USD8_TEE_SECURITY_GROUP_ID",
        }
        if set(aws["lambdaEnvironment"]) != expected_lambda_environment:
            fail("Lambda environment manifest is incomplete or unknown")
        if aws["lambdaEnvironment"]["USD8_REGISTRY"] != manifest["registry"] or aws["lambdaEnvironment"]["USD8_TEE_AMI_ID"] != aws["amiId"]:
            fail("Lambda environment is not bound to Registry and AMI")
        if set(aws["janitorEnvironment"]) != {"USD8_TEE_MAX_AGE_SECONDS"}:
            fail("janitor environment manifest is incomplete or unknown")
        if aws["functionUrlAuthType"] != "AWS_IAM":
            fail("Function URL must use AWS_IAM")
        for artifact, field in (("lambda", "lambdaCodeSha256Base64"), ("janitor", "janitorCodeSha256Base64")):
            expected = base64.b64encode(bytes.fromhex(artifacts[artifact]["sha256"])).decode()
            if aws[field] != expected:
                fail(f"{field} does not match packaged ZIP")
    if live:
        verify_live(manifest, paths)
    print(f"RELEASE_VERIFY_PASSED: {manifest_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("--allow-built", action="store_true")
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args()
    verify(args.manifest, args.allow_built, args.live)


if __name__ == "__main__":
    main()
