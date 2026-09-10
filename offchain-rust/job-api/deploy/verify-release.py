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
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, NoReturn, Optional

HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX96 = re.compile(r"^[0-9a-fA-F]{96}$")
ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
AMI = re.compile(r"^ami-[0-9a-f]+$")
IAM_ROLE_ARN = re.compile(r"^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$")
REQUIRED_ARTIFACTS = {
    "eif", "parent", "settlement", "lambda", "janitor", "kmsPolicy", "instancePolicy",
    "bucketCors",
}
BUCKET_CORS_ORIGINS = {
    "https://usd8.fi",
    "https://usd8-fi.github.io",
    "http://127.0.0.1:4173",
    "http://localhost:4173",
    "http://127.0.0.1:5173",
    "http://localhost:5173",
}
ABI_WORD = re.compile(r"^0x[0-9a-fA-F]{64}$")
TEE_PCR_HASH_SELECTOR = "0x235c9c7b"
DEFI_INSURANCE_SELECTOR = "0xa4119c10"
IS_TEE_SIGNER_SELECTOR = "0x8e50991b"
KECCAK_RATE = 136
KECCAK_MASK = (1 << 64) - 1
KECCAK_ROUND_CONSTANTS = (
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
)
KECCAK_ROTATION_OFFSETS = (
    (0, 36, 3, 41, 18), (1, 44, 10, 45, 2), (62, 6, 43, 15, 61),
    (28, 55, 25, 21, 56), (27, 20, 39, 8, 14),
)


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


def normalize_bucket_cors(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"CORSRules"}:
        fail("bucket CORS configuration is malformed")
    rules = value["CORSRules"]
    if not isinstance(rules, list) or len(rules) != 1 or not isinstance(rules[0], dict):
        fail("bucket CORS must contain exactly one rule")
    rule = rules[0]
    if set(rule) != {"AllowedMethods", "AllowedOrigins", "ExposeHeaders", "MaxAgeSeconds"}:
        fail("bucket CORS rule contains missing or unknown fields")
    methods = rule["AllowedMethods"]
    origins = rule["AllowedOrigins"]
    exposed = rule["ExposeHeaders"]
    if methods != ["GET"]:
        fail("bucket CORS must allow only GET")
    if (
        not isinstance(origins, list)
        or len(origins) != len(BUCKET_CORS_ORIGINS)
        or set(origins) != BUCKET_CORS_ORIGINS
    ):
        fail("bucket CORS origins differ from the reviewed allowlist")
    if exposed != ["Content-Length"] or rule["MaxAgeSeconds"] != 300:
        fail("bucket CORS response headers or max age differ from reviewed values")
    return {
        "CORSRules": [{
            "AllowedMethods": ["GET"],
            "AllowedOrigins": sorted(origins),
            "ExposeHeaders": ["Content-Length"],
            "MaxAgeSeconds": 300,
        }],
    }


def rotate_left_64(value: int, count: int) -> int:
    return ((value << count) | (value >> (64 - count))) & KECCAK_MASK if count else value


def keccak_f1600(state: list[int]) -> None:
    for round_constant in KECCAK_ROUND_CONSTANTS:
        columns = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
        deltas = [columns[(x - 1) % 5] ^ rotate_left_64(columns[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                state[x + 5 * y] ^= deltas[x]
        transformed = [0] * 25
        for x in range(5):
            for y in range(5):
                transformed[y + 5 * ((2 * x + 3 * y) % 5)] = rotate_left_64(
                    state[x + 5 * y], KECCAK_ROTATION_OFFSETS[x][y]
                )
        for x in range(5):
            for y in range(5):
                state[x + 5 * y] = (
                    transformed[x + 5 * y]
                    ^ (~transformed[(x + 1) % 5 + 5 * y] & transformed[(x + 2) % 5 + 5 * y])
                ) & KECCAK_MASK
        state[0] ^= round_constant


def keccak256(value: bytes) -> bytes:
    padding = KECCAK_RATE - len(value) % KECCAK_RATE
    padded = value + (b"\x81" if padding == 1 else b"\x01" + bytes(padding - 2) + b"\x80")
    state = [0] * 25
    for offset in range(0, len(padded), KECCAK_RATE):
        block = padded[offset:offset + KECCAK_RATE]
        for lane in range(KECCAK_RATE // 8):
            state[lane] ^= int.from_bytes(block[8 * lane:8 * (lane + 1)], "little")
        keccak_f1600(state)
    return b"".join(lane.to_bytes(8, "little") for lane in state)[:32]


def tee_pcr_hash(measurements: dict[str, Any]) -> str:
    try:
        pcrs = [bytes.fromhex(measurements[name]) for name in ("PCR0", "PCR1", "PCR2")]
    except (KeyError, TypeError, ValueError):
        fail("EIF measurements are invalid")
    if any(len(pcr) != 48 for pcr in pcrs):
        fail("EIF measurements are invalid")
    return "0x" + keccak256(b"USD8_TEE_PCR0_2_V1" + b"".join(pcrs)).hex()


def pcr3_for_role_arn(role_arn: str) -> str:
    if not IAM_ROLE_ARN.fullmatch(role_arn):
        fail("instance role ARN is invalid")
    return hashlib.sha384(bytes(48) + role_arn.encode()).hexdigest()


def verify_attested_role_binding(statement: dict[str, Any], role_arn: str) -> None:
    expected_pcr3 = pcr3_for_role_arn(role_arn)
    if statement.get("Principal", {}).get("AWS") != role_arn:
        fail("KMS decrypt principal does not match instance role ARN")
    actual_pcr3 = statement.get("Condition", {}).get("StringEqualsIgnoreCase", {}).get(
        "kms:RecipientAttestation:PCR3"
    )
    if actual_pcr3 != expected_pcr3:
        fail("KMS decrypt PCR3 does not match instance role ARN")


def verify_distinct_roles(aws: dict) -> None:
    roles = [aws.get(k + "Role") for k in ("instance", "lambda", "janitor")]
    if len(set(roles)) != 3:
        fail("instance, API and janitor roles must be distinct")


def verify_job_environment_schema(environment: Any) -> None:
    required = {
        "USD8_REGISTRY", "USD8_DEFI_INSURANCE", "USD8_JOB_BUCKET", "USD8_TEE_AMI_ID",
        "USD8_TEE_INSTANCE_TYPE", "USD8_TEE_INSTANCE_PROFILE", "USD8_TEE_SUBNET_ID",
        "USD8_TEE_SECURITY_GROUP_ID", "USD8_MAX_ACTIVE_WORKERS", "USD8_MAX_STARTS_PER_HOUR",
    }
    optional = {"USD8_TEE_MAX_AGE_SECONDS", "USD8_EC2_RECONCILIATION_BOUND_SECONDS"}
    if (not isinstance(environment, dict) or not required <= set(environment)
            or set(environment) - required - optional
            or any(not isinstance(value, str) for value in environment.values())):
        fail("Lambda environment manifest is incomplete or unknown")
    for key in ("USD8_REGISTRY", "USD8_DEFI_INSURANCE"):
        value = environment[key]
        if not ADDRESS.fullmatch(value) or int(value, 16) == 0:
            fail("Lambda trusted chain address environment is invalid")
    for key, minimum, maximum in (("USD8_MAX_ACTIVE_WORKERS", 0, 128), ("USD8_MAX_STARTS_PER_HOUR", 1, 1024)):
        value = environment[key]
        if not re.fullmatch(r"0|[1-9][0-9]{0,3}", value) or not minimum <= int(value) <= maximum:
            fail("Lambda admission budget environment is outside reviewed bounds")
    bound = environment.get("USD8_EC2_RECONCILIATION_BOUND_SECONDS")
    if bound is not None and (not re.fullmatch(r"[1-9][0-9]{0,15}", bound) or int(bound) > 9007199254740991):
        fail("Lambda EC2 reconciliation bound must be a positive safe integer")
    if "USD8_TEE_MAX_AGE_SECONDS" in environment and not re.fullmatch(r"[1-9][0-9]*", environment["USD8_TEE_MAX_AGE_SECONDS"]):
        fail("Lambda job age environment is invalid")


def verify_environment(
    function: str,
    actual: Any,
    expected: dict[str, str],
    secret_commitments: Optional[dict[str, str]] = None,
) -> None:
    secret_commitments = secret_commitments or {}
    if (
        not isinstance(actual, dict)
        or set(actual) != set(expected) | set(secret_commitments)
        or any(actual.get(name) != value for name, value in expected.items())
        or any(
            not isinstance(actual.get(name), str)
            or hashlib.sha256(actual[name].encode()).hexdigest() != commitment
            for name, commitment in secret_commitments.items()
        )
    ):
        fail(f"live {function} environment differs from manifest")


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


def verify_checksums(root: pathlib.Path, artifacts: dict[str, Any]) -> pathlib.Path:
    path = root / "SHA256SUMS"
    if path.is_symlink() or not path.is_file():
        fail("SHA256SUMS is missing or is a symlink")
    expected = {entry["path"]: entry["sha256"] for entry in artifacts.values()}
    actual: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as exc:
        fail(f"cannot read SHA256SUMS: {exc}")
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\r\n]+)", line)
        if match is None:
            fail("SHA256SUMS contains a malformed line")
        digest, relative = match.groups()
        if relative in actual:
            fail(f"SHA256SUMS contains duplicate path {relative}")
        actual[relative] = digest
    if actual != expected:
        fail("SHA256SUMS does not exactly match manifest artifacts")
    return path


def verify_release_tree(
    root: pathlib.Path,
    manifest_path: pathlib.Path,
    artifacts: dict[str, Any],
) -> None:
    allowed_files = {manifest_path.name, "SHA256SUMS"}
    allowed_files.update(entry["path"] for entry in artifacts.values())
    allowed_directories: set[str] = set()
    for relative in allowed_files:
        parent = pathlib.PurePosixPath(relative).parent
        while parent != pathlib.PurePosixPath("."):
            allowed_directories.add(parent.as_posix())
            parent = parent.parent

    actual_files: set[str] = set()
    actual_directories: set[str] = set()
    for path in root.rglob("*"):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            fail(f"release directory contains symlink {relative}")
        if path.is_file():
            actual_files.add(relative)
        elif path.is_dir():
            actual_directories.add(relative)
        else:
            fail(f"release directory contains special path {relative}")

    extra_files = sorted(actual_files - allowed_files)
    if extra_files:
        fail(f"release directory contains unmanifested files: {', '.join(extra_files)}")
    missing_files = sorted(allowed_files - actual_files)
    if missing_files:
        fail(f"release directory is missing required files: {', '.join(missing_files)}")
    extra_directories = sorted(actual_directories - allowed_directories)
    if extra_directories:
        fail(f"release directory contains unmanifested directories: {', '.join(extra_directories)}")


def statements_with_sid(policy: dict[str, Any], sid: str) -> list[dict[str, Any]]:
    statements = policy.get("Statement")
    if not isinstance(statements, list):
        fail("policy Statement must be an array")
    return [item for item in statements if isinstance(item, dict) and item.get("Sid") == sid]


def verify_policy_bindings(manifest: dict[str, Any], paths: dict[str, pathlib.Path]) -> None:
    pcr0 = manifest["Measurements"]["PCR0"]
    pcr3 = manifest["recipientAttestation"]["PCR3"]
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
        actual_pcr3 = matches[0].get("Condition", {}).get("StringEqualsIgnoreCase", {}).get(
            "kms:RecipientAttestation:PCR3"
        )
        if actual_pcr3 != pcr3:
            fail(f"{artifact} PCR3 does not match manifest")
        if artifact == "kmsPolicy" and manifest["status"] == "final":
            role_arn = manifest.get("aws", {}).get("instanceRoleArn", "")
            if pcr3 != pcr3_for_role_arn(role_arn):
                fail("manifest PCR3 does not match instance role ARN")
            verify_attested_role_binding(matches[0], role_arn)
    if manifest["status"] == "final":
        verify_reviewed_policies(manifest, paths)
    normalize_bucket_cors(load_json(paths["bucketCors"]))


def render_launch_policy(manifest: dict[str, Any], artifact: str) -> dict[str, Any]:
    """Render only reviewed statement fields, with literal selected resources."""
    aws = manifest["aws"]
    env = aws["lambdaEnvironment"]
    role_arn = aws["instanceRoleArn"]
    if not IAM_ROLE_ARN.fullmatch(str(role_arn)):
        fail("launch resource instance role ARN is invalid")
    account = role_arn.split(":")[4]
    region = aws["region"]
    patterns = {
        "USD8_TEE_SUBNET_ID": r"subnet-[0-9a-f]+",
        "USD8_TEE_SECURITY_GROUP_ID": r"sg-[0-9a-f]+",
        "USD8_JOB_BUCKET": r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]",
        "USD8_TEE_INSTANCE_PROFILE": r"[A-Za-z0-9+=,.@_-]+",
        "USD8_TEE_INSTANCE_TYPE": r"[a-z0-9]+\.[a-z0-9]+",
    }
    if any(not re.fullmatch(pattern, str(env.get(key, ""))) for key, pattern in patterns.items()):
        fail("launch resource selection is malformed or wildcarded")
    if region != "eu-central-1" or account != "919437049909" or not AMI.fullmatch(str(aws["amiId"])):
        fail("launch resource account, region or AMI differs from supported release")
    for name in ("lambdaFunction", "janitorFunction", "lambdaRole"):
        if not re.fullmatch(r"[A-Za-z0-9_+=,.@-]+", str(aws[name])):
            fail("launch resource function or role name is invalid")
    filenames = {"lambdaPolicy": "lambda-role-policy.json", "janitorPolicy": "janitor-role-policy.json",
                 "bucketPolicy": "bucket-policy.json"}
    policy = load_json(pathlib.Path(__file__).resolve().parent / filenames[artifact])
    bucket = "arn:aws:s3:::" + env["USD8_JOB_BUCKET"]
    ec2 = f"arn:aws:ec2:{region}:{account}:"
    for statement in policy["Statement"]:
        sid = statement["Sid"]
        if sid in {"CreateRequests", "ReadJobs", "RequireCreateIfAbsent", "AllowLambdaJobReads"}:
            statement["Resource"] = [bucket + "/" + value.split("/", 1)[1] for value in statement["Resource"]]
        if sid == "RequireTls":
            statement["Resource"] = [bucket, bucket + "/*"]
        if sid == "AllowLambdaJobReads":
            statement["Principal"]["AWS"] = f"arn:aws:iam::{account}:root"
            statement["Condition"]["StringEquals"]["aws:PrincipalArn"] = f'arn:aws:iam::{account}:role/{aws["lambdaRole"]}'
        if sid == "ListExactJobPrefixes":
            statement["Resource"] = bucket
        if sid == "UseApprovedWorkerInfrastructure":
            statement["Resource"] = [f'arn:aws:ec2:{region}::image/{aws["amiId"]}',
                ec2 + "subnet/" + env["USD8_TEE_SUBNET_ID"],
                ec2 + "security-group/" + env["USD8_TEE_SECURITY_GROUP_ID"],
                ec2 + "network-interface/*", ec2 + "volume/*"]
        if sid in {"LaunchTaggedWorkers", "TagLaunchedWorkers"}:
            statement["Resource"] = ec2 + "instance/*"
        if sid == "LaunchTaggedWorkers":
            statement["Condition"]["StringEquals"]["ec2:InstanceType"] = env["USD8_TEE_INSTANCE_TYPE"]
            statement["Condition"]["ArnEquals"] = {
                "ec2:InstanceProfile": f'arn:aws:iam::{account}:instance-profile/{env["USD8_TEE_INSTANCE_PROFILE"]}'}
        if sid == "PassWorkerRoleOnly":
            statement["Resource"] = role_arn
        if sid in {"WriteFunctionLogs", "WriteJanitorLogs"}:
            function = aws["lambdaFunction" if sid == "WriteFunctionLogs" else "janitorFunction"]
            statement["Resource"] = f"arn:aws:logs:{region}:{account}:log-group:/aws/lambda/{function}:*"
    return policy


def verify_reviewed_policies(manifest: dict[str, Any], paths: dict[str, pathlib.Path]) -> None:
    """Bind full reviewed statement schemas to literal selected infrastructure."""
    aws = manifest["aws"]
    env = aws["lambdaEnvironment"]
    account = aws["instanceRoleArn"].split(":")[4]
    key_prefix = f'arn:aws:kms:{aws["region"]}:{account}:key/'
    if not re.fullmatch(re.escape(key_prefix) + r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", str(aws["kmsKeyId"])):
        fail("selected canonical KMS key ARN is invalid or outside release account/region")
    here = pathlib.Path(__file__).resolve().parent
    for artifact, filename in (("kmsPolicy", "kms-key-policy.json"),
                               ("instancePolicy", "instance-role-policy.json"),
                               ("lambdaPolicy", "lambda-role-policy.json"),
                               ("janitorPolicy", "janitor-role-policy.json"),
                               ("bucketPolicy", "bucket-policy.json")):
        expected = (render_launch_policy(manifest, artifact) if artifact in
                    {"lambdaPolicy", "janitorPolicy", "bucketPolicy"} else load_json(here / filename))
        for statement in expected["Statement"]:
            sid = statement["Sid"]
            if sid in {"AttestedEnclaveDecryptOnly", "AttestedDecryptOnly"}:
                statement["Condition"]["StringEqualsIgnoreCase"] = {
                    "kms:RecipientAttestation:ImageSha384": manifest["Measurements"]["PCR0"],
                    "kms:RecipientAttestation:PCR3": manifest["recipientAttestation"]["PCR3"],
                }
                if artifact == "instancePolicy":
                    statement["Resource"] = aws["kmsKeyId"]
                else:
                    statement["Principal"]["AWS"] = aws["instanceRoleArn"]
            if sid == "UseApprovedWorkerInfrastructure":
                statement["Resource"][0] = f'arn:aws:ec2:{aws["region"]}::image/{aws["amiId"]}'
                account = aws["instanceRoleArn"].split(":")[4]
                for key, resource in (("USD8_TEE_SUBNET_ID", "subnet"),
                                      ("USD8_TEE_SECURITY_GROUP_ID", "security-group")):
                    arn = f'arn:aws:ec2:{aws["region"]}:{account}:{resource}/{env[key]}'
                    if arn not in statement["Resource"] or any(c in env[key] for c in "*?"):
                        fail("launch resource differs from reviewed infrastructure")
            if sid == "LaunchTaggedWorkers":
                if not re.fullmatch(r"[a-z0-9]+\.[a-z0-9]+", env["USD8_TEE_INSTANCE_TYPE"]):
                    fail("launch resource instance type is invalid")
                statement["Condition"]["StringEquals"]["ec2:InstanceType"] = env["USD8_TEE_INSTANCE_TYPE"]
            if sid == "PassWorkerRoleOnly" and statement["Resource"] != aws["instanceRoleArn"]:
                fail("launch resource PassRole differs from reviewed infrastructure")
            if sid == "ListExactJobPrefixes" and statement["Resource"] != "arn:aws:s3:::" + env["USD8_JOB_BUCKET"]:
                fail("launch resource bucket differs from reviewed infrastructure")
            if sid in {"WriteFunctionLogs", "WriteJanitorLogs"}:
                function = aws["lambdaFunction" if artifact == "lambdaPolicy" else "janitorFunction"]
                if not statement["Resource"].endswith("/aws/lambda/" + function + ":*"):
                    fail("launch resource log function differs from reviewed infrastructure")
        if load_json(paths[artifact]) != expected:
            fail(f"{artifact} differs from reviewed policy (including exact launch resources)")


def aws_json(args: list[str], region: str) -> Any:
    env = os.environ.copy()
    env["AWS_REGION"] = region
    env["AWS_DEFAULT_REGION"] = region
    try:
        output = subprocess.run(["aws", *args, "--output", "json"], check=True, capture_output=True, text=True, env=env)
        return json.loads(output.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        # CLI error text can echo configuration values; never forward it.
        fail(f"AWS query failed: {args[0]} {args[1]}; required inventory unavailable")


def verify_kms_grants(aws: dict[str, Any]) -> None:
    try:
        grants = aws_json(["kms", "list-grants", "--key-id", aws["kmsKeyId"]], aws["region"])
    except SystemExit:
        fail("KMS grant inventory is uninspectable; security gate incomplete")
    if (grants.get("Grants") != [] or any(grants.get(k) for k in
                                           ("Truncated", "NextMarker", "NextToken"))):
        fail("KMS grant inventory is nonempty, incomplete or malformed")


def verify_role_policy_inventory(aws: dict[str, Any], kind: str) -> None:
    role = aws[kind + "Role"]
    region = aws["region"]
    inline = aws_json(["iam", "list-role-policies", "--role-name", role], region)
    attached = aws_json(["iam", "list-attached-role-policies", "--role-name", role], region)
    # AWS CLI auto-pagination must complete. Never accept a partial inventory.
    if (inline.get("PolicyNames") != [aws[kind + "PolicyName"]]
            or attached.get("AttachedPolicies") != []
            or any(doc.get(key) for doc in (inline, attached)
                   for key in ("IsTruncated", "Marker", "NextToken"))):
        fail(f"live {kind} policy inventory differs from exclusive reviewed set")


def verify_live_bucket_security(manifest: dict[str, Any], baseline: dict[str, Any]) -> None:
    aws = manifest["aws"]
    bucket = aws["lambdaEnvironment"]["USD8_JOB_BUCKET"]
    here = pathlib.Path(__file__).resolve().parent

    def query(operation: str) -> Any:
        return aws_json(["s3api", operation, "--bucket", bucket], aws["region"])

    rules = query("get-bucket-lifecycle-configuration").get("Rules")
    expected_rules = load_json(here / "bucket-lifecycle.json")["Rules"]
    if not isinstance(rules, list) or sorted(rules, key=canonical_sha256) != sorted(expected_rules, key=canonical_sha256):
        fail("live bucket lifecycle differs: require launch 1 / terminal 30 / requests 31; no settlements expiry")
    try:
        policy = json.loads(query("get-bucket-policy")["Policy"])
    except (KeyError, TypeError, json.JSONDecodeError):
        fail("live bucket policy is malformed")
    if policy != render_launch_policy(manifest, "bucketPolicy"):
        fail("live bucket access policy differs from reviewed policy")
    if query("get-bucket-versioning").get("Status") != "Enabled":
        fail("live bucket versioning is not Enabled")
    expected_block = {name: True for name in
                      ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")}
    if query("get-public-access-block").get("PublicAccessBlockConfiguration") != expected_block:
        fail("live bucket public access block is incomplete")
    if query("get-bucket-ownership-controls").get("OwnershipControls") != {
            "Rules": [{"ObjectOwnership": "BucketOwnerEnforced"}]}:
        fail("live bucket must disable ACLs with BucketOwnerEnforced")
    encryption = query("get-bucket-encryption").get("ServerSideEncryptionConfiguration")
    if encryption != baseline.get("bucketEncryption") or not isinstance(encryption, dict):
        fail("live bucket encryption differs from independent baseline")
    encryption_rules = encryption.get("Rules", [])
    if len(encryption_rules) != 1 or encryption_rules[0].get("ApplyServerSideEncryptionByDefault", {}).get("SSEAlgorithm") not in {"AES256", "aws:kms"}:
        fail("bucket encryption baseline is invalid")


def verify_live_bucket_cors(manifest: dict[str, Any], paths: dict[str, pathlib.Path]) -> None:
    aws = manifest["aws"]
    region = aws["region"]
    bucket = aws["lambdaEnvironment"]["USD8_JOB_BUCKET"]
    expected = normalize_bucket_cors(load_json(paths["bucketCors"]))
    live = aws_json(["s3api", "get-bucket-cors", "--bucket", bucket], region)
    if normalize_bucket_cors(live) != expected:
        fail("live job-bucket CORS differs from release")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str
    ) -> Any:
        raise urllib.error.HTTPError(newurl, code, "live chain RPC redirects are forbidden", headers, fp)


def validate_live_rpc_url(rpc_url: str) -> None:
    try:
        parsed = urllib.parse.urlparse(rpc_url)
        port = parsed.port
    except ValueError:
        fail("live chain RPC URL must be direct HTTPS")
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or port not in {None, 443}
    ):
        fail("live chain RPC URL must be direct HTTPS")


def rpc_json(rpc_url: str, method: str, params: list[Any]) -> Any:
    validate_live_rpc_url(rpc_url)
    request = urllib.request.Request(
        rpc_url,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "usd8-release-verifier/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
            value = json.loads(response.read())
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        fail(f"live chain RPC query failed: {exc}")
    if not isinstance(value, dict) or "error" in value or "result" not in value:
        fail(f"live chain RPC returned invalid {method} response")
    return value["result"]


def abi_word(value: Any, label: str) -> str:
    if not isinstance(value, str) or not ABI_WORD.fullmatch(value):
        fail(f"live {label} returned malformed ABI word")
    return value.lower()


def verify_live_chain(manifest: dict[str, Any], rpc_url: str) -> None:
    expected_chain = manifest["chainId"]
    chain_id = rpc_json(rpc_url, "eth_chainId", [])
    if not isinstance(chain_id, str) or not re.fullmatch(r"0x[0-9a-fA-F]+", chain_id):
        fail("live chain ID is malformed")
    if int(chain_id, 16) != expected_chain:
        fail("live chain ID differs from manifest")

    registry = manifest["registry"]
    registry_code = rpc_json(rpc_url, "eth_getCode", [registry, "latest"])
    if not isinstance(registry_code, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})+", registry_code):
        fail("live Registry has no bytecode")

    live_pcr = abi_word(
        rpc_json(rpc_url, "eth_call", [{"to": registry, "data": TEE_PCR_HASH_SELECTOR}, "latest"]),
        "Registry teePcrHash",
    )
    if live_pcr != manifest["teePcrHash"].lower():
        fail("live Registry teePcrHash differs from manifest")

    defi_insurance_word = abi_word(
        rpc_json(rpc_url, "eth_call", [{"to": registry, "data": DEFI_INSURANCE_SELECTOR}, "latest"]),
        "Registry defiInsurance",
    )
    defi_insurance = "0x" + defi_insurance_word[-40:]
    if int(defi_insurance, 16) == 0:
        fail("live Registry defiInsurance is zero")
    if "aws" in manifest and manifest["aws"]["lambdaEnvironment"].get("USD8_DEFI_INSURANCE", "").lower() != defi_insurance:
        fail("live Registry differs from trusted promoter module environment")
    defi_insurance_code = rpc_json(rpc_url, "eth_getCode", [defi_insurance, "latest"])
    if not isinstance(defi_insurance_code, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})+", defi_insurance_code):
        fail("live DefiInsurance has no bytecode")

    signer = manifest["signer"].lower()
    is_signer = abi_word(
        rpc_json(
            rpc_url,
            "eth_call",
            [{"to": defi_insurance, "data": IS_TEE_SIGNER_SELECTOR + signer[2:].rjust(64, "0")}, "latest"],
        ),
        "DefiInsurance isTeeSigner",
    )
    if is_signer != "0x" + "0" * 63 + "1":
        fail("live DefiInsurance does not authorize manifest signer")


def verify_score_runtime_policy(manifest: dict[str, Any], paths: dict[str, pathlib.Path]) -> None:
    if "scoreService" not in manifest:
        return
    score = manifest["scoreService"]
    aws = manifest.get("aws", {})
    if score["roleArn"].rsplit("/", 1)[-1] in {aws.get(k + "Role") for k in ("instance", "lambda", "janitor")}:
        fail("score and other runtime roles must be distinct")
    table = score["environment"].get("USD8_SCORE_TABLE")
    if not isinstance(table, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{3,255}", table):
        fail("score table must be an explicit non-secret exact table name")
    if not isinstance(score["policyName"], str) or not re.fullmatch(r"[A-Za-z0-9+=,.@_-]{1,128}", score["policyName"]):
        fail("score policy name must be exact")
    if score["roleArn"].split(":")[4] != "919437049909":
        fail("score role must belong to the reviewed account")
    expected = {"Version": "2012-10-17", "Statement": [
        {"Sid": "WriteDedicatedScoreLogs", "Effect": "Allow",
         "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
         "Resource": f'arn:aws:logs:eu-central-1:919437049909:log-group:/aws/lambda/{score["function"]}:*'},
        {"Sid": "UseDedicatedScoreCheckpointTable", "Effect": "Allow",
         "Action": ["dynamodb:GetItem", "dynamodb:UpdateItem"],
         "Resource": f"arn:aws:dynamodb:eu-central-1:919437049909:table/{table}"}]}
    if load_json(paths["scoreRuntimePolicy"]) != expected:
        fail("score runtime policy differs from reviewed exact function/table policy")


def verify_score_work_policy(score: dict[str, Any]) -> None:
    policy = {"calculationTimeoutMs": 20000, "leaseSeconds": 30, "failureCooldownSeconds": 30,
              "budgetWindowSeconds": 60, "budgetMaxAttempts": 10}
    key = "USD8_SCORE_WORK_POLICY_JSON"
    if key in score["secretEnvironmentSha256"]:
        fail("score work policy must be inspectable non-secret configuration")
    raw = score["environment"].get(key)
    if raw is not None:
        try:
            configured = json.loads(raw)
        except (ValueError, TypeError):
            fail("score work policy JSON is invalid")
        if not isinstance(configured, dict) or set(configured) != set(policy):
            fail("score work policy fields are incomplete or unknown")
        policy = configured
    if any(type(value) is not int for value in policy.values()):
        fail("score work policy must use integers")
    timeout = policy["calculationTimeoutMs"]
    lease = policy["leaseSeconds"]
    if (not 1 <= timeout <= 25000 or not 1 <= lease <= 300
            or lease < (timeout + 999) // 1000 + 5
            or not (timeout + 999) // 1000 < score["timeoutSeconds"] < lease
            or not 1 <= policy["failureCooldownSeconds"] <= 3600
            or not lease <= policy["budgetWindowSeconds"] <= 86400
            or not 1 <= policy["budgetMaxAttempts"] <= 1000):
        fail("score work policy bounds or application/hard-timeout/lease ordering are unsafe")


def verify_live_score(manifest: dict[str, Any]) -> None:
    if "scoreService" not in manifest:
        return
    score = manifest["scoreService"]
    region = manifest["aws"]["region"]
    function = score["function"]
    doc = aws_json(["lambda", "get-function", "--function-name", function], region)
    config = doc.get("Configuration", {})
    expected = base64.b64encode(bytes.fromhex(manifest["artifacts"]["scoreLambda"]["sha256"])).decode()
    if config.get("CodeSha256") != expected:
        fail("live score package hash differs from approved release")
    if config.get("Timeout") != score["timeoutSeconds"]:
        fail("live score hard timeout differs from approved release")
    if config.get("Role") != score["roleArn"]:
        fail("live score role differs from approved release")
    verify_environment("score service", config.get("Environment", {}).get("Variables", {}),
                       score["environment"], score["secretEnvironmentSha256"])
    doc = aws_json(["lambda", "get-function-url-config", "--function-name", function], region)
    if doc.get("AuthType") != score["functionUrlAuthType"]:
        fail("live score Function URL authorization differs from approved release")


def verify_security_baseline(manifest: dict[str, Any], path: Optional[pathlib.Path],
                             digest: Optional[str]) -> dict[str, Any]:
    if path is None or not digest:
        fail("live verification requires an independent security baseline and pinned digest")
    if not HEX64.fullmatch(digest) or path.is_symlink() or not path.is_file() or sha256(path) != digest:
        fail("security baseline digest mismatch or unsafe baseline path")
    baseline = load_json(path)
    if set(baseline) != {"releaseId", "roleTrustPolicies", "bucketEncryption"}:
        fail("security baseline fields are incomplete or unknown")
    if not HEX64.fullmatch(str(baseline["releaseId"])) or baseline["releaseId"] != manifest.get("releaseId"):
        fail("release is not the independently approved release (including environment and policy)")
    return baseline


def verify_live_authority(manifest: dict[str, Any], baseline: dict[str, Any]) -> None:
    aws = dict(manifest["aws"])
    verify_distinct_roles(aws)
    verify_kms_grants(aws)
    kinds = ["instance", "lambda", "janitor"]
    if "scoreService" in manifest:
        score = manifest["scoreService"]
        aws["scoreRole"] = score["roleArn"].rsplit("/", 1)[-1]
        aws["scorePolicyName"] = score["policyName"]
        kinds.append("score")
    trusts = baseline.get("roleTrustPolicies", {})
    if not isinstance(trusts, dict) or set(trusts) != {aws[k + "Role"] for k in kinds}:
        fail("independent role trust inventory is incomplete or unknown")
    for kind in kinds:
        verify_role_policy_inventory(aws, kind)
        role = aws[kind + "Role"]
        doc = aws_json(["iam", "get-role", "--role-name", role], aws["region"]).get("Role", {})
        if doc.get("AssumeRolePolicyDocument") != trusts[role] or not isinstance(trusts[role], dict):
            fail(f"live {kind} trust policy differs from independent baseline")
        if "PermissionsBoundary" in doc:
            fail(f"live {kind} has an unexpected permissions boundary")
        if kind == "instance" and doc.get("Arn") != aws["instanceRoleArn"]:
            fail("live instance role ARN differs from release")
        if kind == "score" and doc.get("Arn") != manifest["scoreService"]["roleArn"]:
            fail("live score role ARN differs from release")
    profile = aws["lambdaEnvironment"]["USD8_TEE_INSTANCE_PROFILE"]
    if not re.fullmatch(r"[A-Za-z0-9+=,.@_-]+", profile):
        fail("instance profile must be an exact name")
    doc = aws_json(["iam", "get-instance-profile", "--instance-profile-name", profile], aws["region"])
    roles = doc.get("InstanceProfile", {}).get("Roles", [])
    if len(roles) != 1 or roles[0].get("Arn") != aws["instanceRoleArn"]:
        fail("live instance profile must contain only the manifest instance role")


def verify_live(
    manifest: dict[str, Any], paths: dict[str, pathlib.Path], rpc_url: Optional[str],
    baseline: Optional[dict[str, Any]] = None,
) -> None:
    if manifest["status"] != "final":
        fail("live verification requires a final release")
    if not rpc_url:
        fail("live verification requires --rpc-url")
    if baseline is None:
        fail("live verification requires an independent security baseline")
    verify_live_authority(manifest, baseline)
    verify_live_bucket_security(manifest, baseline)
    verify_live_score(manifest)
    verify_live_chain(manifest, rpc_url)
    aws = manifest["aws"]
    region = aws["region"]
    verify_live_bucket_cors(manifest, paths)
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
        if type(config.get("Timeout")) is not int or config["Timeout"] != aws[artifact + "TimeoutSeconds"]:
            fail(f"live {function} hard timeout differs from approved release")
        expected_environment = aws["lambdaEnvironment" if artifact == "lambda" else "janitorEnvironment"]
        actual_environment = config.get("Environment", {}).get("Variables", {})
        secret_commitments = aws["lambdaSecretEnvironmentSha256"] if artifact == "lambda" else {}
        verify_environment(function, actual_environment, expected_environment, secret_commitments)
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

    role_policies = [
        ("instancePolicy", aws["instanceRole"], aws["instancePolicyName"]),
        ("lambdaPolicy", aws["lambdaRole"], aws["lambdaPolicyName"]),
        ("janitorPolicy", aws["janitorRole"], aws["janitorPolicyName"]),
    ]
    if "scoreService" in manifest:
        score = manifest["scoreService"]
        role_policies.append(("scoreRuntimePolicy", score["roleArn"].rsplit("/", 1)[-1], score["policyName"]))
    for artifact, role, policy_name in role_policies:
        if artifact == "instancePolicy":
            role_doc = aws_json(["iam", "get-role", "--role-name", role], region)
            if role_doc.get("Role", {}).get("Arn") != aws["instanceRoleArn"]:
                fail("live instance role ARN differs from release")
        live = aws_json(["iam", "get-role-policy", "--role-name", role, "--policy-name", policy_name], region)
        if canonical_sha256(live.get("PolicyDocument")) != canonical_sha256(load_json(paths[artifact])):
            fail(f"live IAM policy {role}/{policy_name} differs from release")


def verify(
    manifest_path: pathlib.Path, allow_built: bool, live: bool, rpc_url: Optional[str] = None,
    security_baseline: Optional[pathlib.Path] = None, baseline_sha256: Optional[str] = None,
) -> None:
    if manifest_path.is_symlink():
        fail("release manifest is a symlink")
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
    if manifest.get("network") != "sepolia" or manifest.get("chainId") != 11155111:
        fail("release network must be Sepolia (chain ID 11155111)")
    if not ADDRESS.fullmatch(str(manifest.get("registry", ""))) or int(manifest["registry"], 16) == 0:
        fail("registry is invalid")
    if not ADDRESS.fullmatch(str(manifest.get("signer", ""))) or int(manifest["signer"], 16) == 0:
        fail("signer is invalid")
    measurements = manifest.get("Measurements", {})
    if measurements.get("HashAlgorithm") != "Sha384" or not all(
        HEX96.fullmatch(str(measurements.get(name, ""))) for name in ("PCR0", "PCR1", "PCR2")
    ):
        fail("EIF measurements are invalid")
    recipient_attestation = manifest.get("recipientAttestation", {})
    if set(recipient_attestation) != {"PCR3"} or not HEX96.fullmatch(
        str(recipient_attestation.get("PCR3", ""))
    ):
        fail("recipient-attestation PCR3 is invalid")
    if not re.fullmatch(r"0x[0-9a-fA-F]{64}", str(manifest.get("teePcrHash", ""))):
        fail("TEE PCR hash is invalid")
    if manifest["teePcrHash"].lower() != tee_pcr_hash(measurements):
        fail("TEE PCR hash does not match EIF measurements")

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict):
        fail("artifacts object is missing")
    required = set(REQUIRED_ARTIFACTS)
    if "scoreService" in manifest:
        required.update(("scoreLambda", "scoreRuntimePolicy"))
        score = manifest["scoreService"]
        if not isinstance(score, dict) or set(score) != {"function", "roleArn", "policyName", "environment", "secretEnvironmentSha256", "functionUrlAuthType", "timeoutSeconds"}:
            fail("score service descriptor is incomplete or unknown")
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", str(score["function"])) or not IAM_ROLE_ARN.fullmatch(str(score["roleArn"])):
            fail("score function or role ARN is invalid")
        if score["functionUrlAuthType"] not in {"NONE", "AWS_IAM"}:
            fail("score Function URL authorization is invalid")
        if type(score["timeoutSeconds"]) is not int or score["timeoutSeconds"] != 25:
            fail("score hard timeout must be the reviewed 25 seconds")
        public, secrets = score["environment"], score["secretEnvironmentSha256"]
        if (not isinstance(public, dict) or not isinstance(secrets, dict)
                or set(public) & set(secrets)
                or any(not isinstance(v, str) for v in public.values())
                or any(not HEX64.fullmatch(str(v)) for v in secrets.values())):
            fail("score environment values or secret commitments are invalid")
        verify_score_work_policy(score)
    if status == "final":
        required.update(("lambdaPolicy", "janitorPolicy", "bucketPolicy"))
    if set(artifacts) != required:
        fail(f"artifact set mismatch: expected {sorted(required)}")
    artifact_paths = [entry.get("path") for entry in artifacts.values() if isinstance(entry, dict)]
    if len(artifact_paths) != len(artifacts) or len(set(artifact_paths)) != len(artifact_paths):
        fail("artifact paths must be present and unique")
    root = manifest_path.resolve().parent
    paths = {name: exact_artifact(root, entry, name) for name, entry in artifacts.items()}
    verify_checksums(root, artifacts)
    verify_release_tree(root, manifest_path.resolve(), artifacts)
    verify_policy_bindings(manifest, paths)
    verify_score_runtime_policy(manifest, paths)

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
            "instanceRole", "instanceRoleArn", "instancePolicyName", "lambdaRole", "lambdaPolicyName",
            "janitorRole", "janitorPolicyName",
            "lambdaTimeoutSeconds", "janitorTimeoutSeconds",
            "functionUrlAuthType", "lambdaEnvironment", "lambdaSecretEnvironmentSha256", "janitorEnvironment",
        }
        if set(aws) != required_aws:
            fail("AWS release fields are incomplete or unknown")
        verify_distinct_roles(aws)
        for kind in ("lambda", "janitor"):
            value = aws[kind + "TimeoutSeconds"]
            if type(value) is not int or not 1 <= value <= 900:
                fail(f"{kind} approved timeout must be an integer 1..900")
        if not AMI.fullmatch(str(aws["amiId"])) or aws["region"] != "eu-central-1":
            fail("AWS AMI or region is invalid")
        if not IAM_ROLE_ARN.fullmatch(str(aws["instanceRoleArn"])) or not aws["instanceRoleArn"].endswith(
            "/" + aws["instanceRole"]
        ):
            fail("instance role name and ARN do not match")
        verify_job_environment_schema(aws["lambdaEnvironment"])
        expected_lambda_secret_environment = {
            "USD8_JOB_HMAC_KEY_B64",
            "USD8_PRECHECK_RPC_URL",
        }
        if (
            set(aws["lambdaSecretEnvironmentSha256"]) != expected_lambda_secret_environment
            or not all(HEX64.fullmatch(str(value)) for value in aws["lambdaSecretEnvironmentSha256"].values())
        ):
            fail("Lambda secret-environment commitments are incomplete or invalid")
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
    baseline = None
    if live or security_baseline is not None or baseline_sha256 is not None:
        baseline = verify_security_baseline(manifest, security_baseline, baseline_sha256)
    if live:
        verify_live(manifest, paths, rpc_url, baseline)
    print(f"RELEASE_VERIFY_PASSED: {manifest_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", nargs="?", type=pathlib.Path)
    parser.add_argument("--pcr3-for-role-arn")
    parser.add_argument("--allow-built", action="store_true")
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--rpc-url")
    parser.add_argument("--security-baseline", type=pathlib.Path)
    parser.add_argument("--baseline-sha256")
    args = parser.parse_args()
    if args.pcr3_for_role_arn:
        if args.manifest is not None or args.allow_built or args.live:
            parser.error("PCR3 derivation cannot be combined with release verification")
        print(pcr3_for_role_arn(args.pcr3_for_role_arn))
        return
    if args.manifest is None:
        parser.error("manifest is required")
    if args.rpc_url and not args.live:
        parser.error("--rpc-url requires --live")
    verify(args.manifest, args.allow_built, args.live, args.rpc_url,
           args.security_baseline, args.baseline_sha256)


if __name__ == "__main__":
    main()
