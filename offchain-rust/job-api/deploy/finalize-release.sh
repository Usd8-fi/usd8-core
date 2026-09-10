#!/usr/bin/env bash
set -euo pipefail
# Candidate assembly only: read-only AWS metadata queries, no deployment.
# Actual cutover must use deploy-release.py, which executes the live gate.
export PYTHONDONTWRITEBYTECODE=1

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <built-release-directory> <candidate-release-directory>" >&2
  exit 2
fi
BUILD_DIR=$(cd "$1" && pwd)
OUT=$2
AMI_ID=${AMI_ID:?set AMI_ID}
AWS_REGION=${AWS_REGION:?set AWS_REGION}
KMS_KEY_ID=${KMS_KEY_ID:?set KMS_KEY_ID}
LAMBDA_FUNCTION=${LAMBDA_FUNCTION:?set LAMBDA_FUNCTION}
JANITOR_FUNCTION=${JANITOR_FUNCTION:?set JANITOR_FUNCTION}
LAMBDA_TIMEOUT_SECONDS=${LAMBDA_TIMEOUT_SECONDS:?set approved LAMBDA_TIMEOUT_SECONDS}
JANITOR_TIMEOUT_SECONDS=${JANITOR_TIMEOUT_SECONDS:?set approved JANITOR_TIMEOUT_SECONDS}
for timeout in "$LAMBDA_TIMEOUT_SECONDS" "$JANITOR_TIMEOUT_SECONDS"; do
  [[ "$timeout" =~ ^[1-9][0-9]{0,2}$ ]] && (( timeout <= 900 )) || { echo 'approved Lambda timeouts must be integers 1..900' >&2; exit 2; }
done
LAMBDA_ROLE=${LAMBDA_ROLE:?set LAMBDA_ROLE}
LAMBDA_POLICY_NAME=${LAMBDA_POLICY_NAME:?set LAMBDA_POLICY_NAME}
JANITOR_ROLE=${JANITOR_ROLE:?set JANITOR_ROLE}
JANITOR_POLICY_NAME=${JANITOR_POLICY_NAME:?set JANITOR_POLICY_NAME}
INSTANCE_ROLE=${INSTANCE_ROLE:?set INSTANCE_ROLE}
INSTANCE_POLICY_NAME=${INSTANCE_POLICY_NAME:?set INSTANCE_POLICY_NAME}
JOB_BUCKET=${JOB_BUCKET:?set JOB_BUCKET}
DEFI_INSURANCE=${DEFI_INSURANCE:?set DEFI_INSURANCE to the Registry-bound module}
USD8_MAX_ACTIVE_WORKERS=${USD8_MAX_ACTIVE_WORKERS:?set USD8_MAX_ACTIVE_WORKERS}
USD8_MAX_STARTS_PER_HOUR=${USD8_MAX_STARTS_PER_HOUR:?set USD8_MAX_STARTS_PER_HOUR}
INSTANCE_TYPE=${INSTANCE_TYPE:?set INSTANCE_TYPE}
INSTANCE_PROFILE=${INSTANCE_PROFILE:?set INSTANCE_PROFILE}
SUBNET_ID=${SUBNET_ID:?set SUBNET_ID}
SECURITY_GROUP_ID=${SECURITY_GROUP_ID:?set SECURITY_GROUP_ID}
JANITOR_MAX_AGE_SECONDS=${JANITOR_MAX_AGE_SECONDS:?set JANITOR_MAX_AGE_SECONDS}
USD8_JOB_HMAC_KEY_B64=${USD8_JOB_HMAC_KEY_B64:?set USD8_JOB_HMAC_KEY_B64}
USD8_PRECHECK_RPC_URL=${USD8_PRECHECK_RPC_URL:?set USD8_PRECHECK_RPC_URL}

[[ "$AMI_ID" =~ ^ami-[0-9a-f]+$ ]] || { echo 'invalid AMI_ID' >&2; exit 2; }
[[ "$AWS_REGION" == eu-central-1 ]] || { echo 'AWS_REGION must be eu-central-1' >&2; exit 2; }
[[ ! -e "$OUT" ]] || { echo "candidate release already exists: $OUT" >&2; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
python3 "$HERE/verify-release.py" "$BUILD_DIR/release-manifest.json" --allow-built
"$HERE/verify-ami.sh" "$AMI_ID"

IMAGE_JSON=$(aws ec2 describe-images --image-ids "$AMI_ID" --region "$AWS_REGION" --output json)
ROOT_SNAPSHOT=$(python3 -c '
import json, sys
image = json.load(sys.stdin)["Images"][0]
root = image["RootDeviceName"]
print(next(item["Ebs"]["SnapshotId"] for item in image["BlockDeviceMappings"] if item["DeviceName"] == root))
' <<<"$IMAGE_JSON")
INSTANCE_ROLE_JSON=$(aws iam get-role --role-name "$INSTANCE_ROLE" --output json)
INSTANCE_ROLE_ARN=$(python3 -c '
import json, sys
print(json.load(sys.stdin)["Role"]["Arn"])
' <<<"$INSTANCE_ROLE_JSON")
PCR3=$(python3 "$HERE/verify-release.py" --pcr3-for-role-arn "$INSTANCE_ROLE_ARN")
KMS_KEY_JSON=$(aws kms describe-key --key-id "$KMS_KEY_ID" --region "$AWS_REGION" --output json)
KMS_KEY_ARN=$(python3 -c '
import json, sys
print(json.load(sys.stdin)["KeyMetadata"]["Arn"])
' <<<"$KMS_KEY_JSON")

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
RELEASE="$STAGE/release"
mkdir "$RELEASE"
cp -a "$BUILD_DIR/." "$RELEASE/"

jq --arg roleArn "$INSTANCE_ROLE_ARN" --arg pcr3 "$PCR3" '
  .Statement |= map(
    if .Sid == "AttestedEnclaveDecryptOnly"
    then .Principal.AWS = $roleArn |
      .Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR3"] = $pcr3
    else . end
  )
' "$RELEASE/kms-key-policy.json" > "$RELEASE/kms-key-policy.json.tmp"
mv "$RELEASE/kms-key-policy.json.tmp" "$RELEASE/kms-key-policy.json"
jq --arg pcr3 "$PCR3" --arg kmsKeyArn "$KMS_KEY_ARN" '
  .Statement |= map(
    if .Sid == "AttestedDecryptOnly"
    then .Resource = $kmsKeyArn |
      .Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:PCR3"] = $pcr3
    else . end
  )
' "$RELEASE/instance-role-policy.json" > "$RELEASE/instance-role-policy.json.tmp"
mv "$RELEASE/instance-role-policy.json.tmp" "$RELEASE/instance-role-policy.json"
KMS_POLICY_SHA256=$(sha256sum "$RELEASE/kms-key-policy.json" | cut -d' ' -f1)
INSTANCE_POLICY_SHA256=$(sha256sum "$RELEASE/instance-role-policy.json" | cut -d' ' -f1)

jq --arg ami "arn:aws:ec2:${AWS_REGION}::image/${AMI_ID}" \
  --arg instanceType "$INSTANCE_TYPE" '
  walk(if type == "string" and test("^arn:aws:ec2:[^:]+::image/ami-") then $ami else . end)
  | (.Statement[] | select(.Sid == "LaunchTaggedWorkers").Condition.StringEquals["ec2:InstanceType"]) = $instanceType
' "$HERE/lambda-role-policy.json" > "$RELEASE/lambda-role-policy.json"
LAMBDA_POLICY_SHA256=$(sha256sum "$RELEASE/lambda-role-policy.json" | cut -d' ' -f1)
cp "$HERE/janitor-role-policy.json" "$RELEASE/janitor-role-policy.json"
JANITOR_POLICY_SHA256=$(sha256sum "$RELEASE/janitor-role-policy.json" | cut -d' ' -f1)
LAMBDA_CODE_SHA256_B64=$(python3 - "$RELEASE/lambda.zip" <<'PY'
import base64, hashlib, pathlib, sys
print(base64.b64encode(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).digest()).decode())
PY
)
JANITOR_CODE_SHA256_B64=$(python3 - "$RELEASE/janitor.zip" <<'PY'
import base64, hashlib, pathlib, sys
print(base64.b64encode(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).digest()).decode())
PY
)
JOB_HMAC_KEY_SHA256=$(printf '%s' "$USD8_JOB_HMAC_KEY_B64" | sha256sum | cut -d' ' -f1)
PRECHECK_RPC_URL_SHA256=$(printf '%s' "$USD8_PRECHECK_RPC_URL" | sha256sum | cut -d' ' -f1)
TMP_MANIFEST="$RELEASE/release-manifest.json.tmp"
jq \
  --arg region "$AWS_REGION" --arg ami "$AMI_ID" --arg defiInsurance "$DEFI_INSURANCE" \
  --arg snapshot "$ROOT_SNAPSHOT" --arg lambdaFunction "$LAMBDA_FUNCTION" \
  --arg janitorFunction "$JANITOR_FUNCTION" --arg lambdaCode "$LAMBDA_CODE_SHA256_B64" \
  --argjson lambdaTimeout "$LAMBDA_TIMEOUT_SECONDS" --argjson janitorTimeout "$JANITOR_TIMEOUT_SECONDS" \
  --arg janitorCode "$JANITOR_CODE_SHA256_B64" --arg kmsKey "$KMS_KEY_ARN" \
  --arg instanceRole "$INSTANCE_ROLE" --arg instanceRoleArn "$INSTANCE_ROLE_ARN" \
  --arg instancePolicyName "$INSTANCE_POLICY_NAME" --arg pcr3 "$PCR3" \
  --arg lambdaRole "$LAMBDA_ROLE" --arg lambdaPolicyName "$LAMBDA_POLICY_NAME" \
  --arg janitorRole "$JANITOR_ROLE" --arg janitorPolicyName "$JANITOR_POLICY_NAME" \
  --arg jobBucket "$JOB_BUCKET" --arg instanceType "$INSTANCE_TYPE" \
  --arg instanceProfile "$INSTANCE_PROFILE" --arg subnet "$SUBNET_ID" \
  --arg securityGroup "$SECURITY_GROUP_ID" --arg janitorMaxAge "$JANITOR_MAX_AGE_SECONDS" \
  --arg maxActiveWorkers "$USD8_MAX_ACTIVE_WORKERS" --arg maxStartsPerHour "$USD8_MAX_STARTS_PER_HOUR" \
  --arg jobHmacKeySha256 "$JOB_HMAC_KEY_SHA256" \
  --arg precheckRpcUrlSha256 "$PRECHECK_RPC_URL_SHA256" \
  --arg kmsPolicyHash "$KMS_POLICY_SHA256" --arg instancePolicyHash "$INSTANCE_POLICY_SHA256" \
  --arg lambdaPolicyHash "$LAMBDA_POLICY_SHA256" --arg janitorPolicyHash "$JANITOR_POLICY_SHA256" '
  .status = "final"
  | .recipientAttestation.PCR3 = $pcr3
  | .artifacts.kmsPolicy.sha256 = $kmsPolicyHash
  | .artifacts.instancePolicy.sha256 = $instancePolicyHash
  | .artifacts.lambdaPolicy = {
      path: "lambda-role-policy.json", sha256: $lambdaPolicyHash
    }
  | .artifacts.janitorPolicy = {
      path: "janitor-role-policy.json", sha256: $janitorPolicyHash
    }
  | .aws = {
      region: $region,
      amiId: $ami,
      rootSnapshotId: $snapshot,
      lambdaFunction: $lambdaFunction,
      janitorFunction: $janitorFunction,
      lambdaTimeoutSeconds: $lambdaTimeout,
      janitorTimeoutSeconds: $janitorTimeout,
      lambdaCodeSha256Base64: $lambdaCode,
      janitorCodeSha256Base64: $janitorCode,
      kmsKeyId: $kmsKey,
      instanceRole: $instanceRole,
      instanceRoleArn: $instanceRoleArn,
      instancePolicyName: $instancePolicyName,
      lambdaRole: $lambdaRole,
      lambdaPolicyName: $lambdaPolicyName,
      janitorRole: $janitorRole,
      janitorPolicyName: $janitorPolicyName,
      functionUrlAuthType: "AWS_IAM",
      lambdaEnvironment: {
        USD8_REGISTRY: .registry,
        USD8_DEFI_INSURANCE: $defiInsurance,
        USD8_MAX_ACTIVE_WORKERS: $maxActiveWorkers,
        USD8_MAX_STARTS_PER_HOUR: $maxStartsPerHour,
        USD8_JOB_BUCKET: $jobBucket,
        USD8_TEE_AMI_ID: $ami,
        USD8_TEE_INSTANCE_TYPE: $instanceType,
        USD8_TEE_INSTANCE_PROFILE: $instanceProfile,
        USD8_TEE_SUBNET_ID: $subnet,
        USD8_TEE_SECURITY_GROUP_ID: $securityGroup
      },
      lambdaSecretEnvironmentSha256: {
        USD8_JOB_HMAC_KEY_B64: $jobHmacKeySha256,
        USD8_PRECHECK_RPC_URL: $precheckRpcUrlSha256
      },
      janitorEnvironment: {USD8_TEE_MAX_AGE_SECONDS: $janitorMaxAge}
    }
' "$RELEASE/release-manifest.json" > "$TMP_MANIFEST"
mv "$TMP_MANIFEST" "$RELEASE/release-manifest.json"
# Optional composition: exact score ZIP, reviewed policy and descriptor.
# This does not rebuild score or assert it is an enclave dependency.
if [[ -n "${SCORE_PACKAGE:-}" || -n "${SCORE_CONFIG_JSON:-}" || -n "${SCORE_RUNTIME_POLICY_JSON:-}" ]]; then
  : "${SCORE_PACKAGE:?set SCORE_PACKAGE with SCORE_CONFIG_JSON}"
  : "${SCORE_CONFIG_JSON:?set SCORE_CONFIG_JSON with SCORE_PACKAGE}"
  : "${SCORE_RUNTIME_POLICY_JSON:?set reviewed SCORE_RUNTIME_POLICY_JSON with SCORE_PACKAGE}"
  install -m 0444 "$SCORE_PACKAGE" "$RELEASE/score-lambda.zip"
  install -m 0444 "$SCORE_RUNTIME_POLICY_JSON" "$RELEASE/score-runtime-policy.json"
  python3 - "$RELEASE" "$SCORE_CONFIG_JSON" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
path = root / "release-manifest.json"
manifest = json.loads(path.read_text())
manifest["scoreService"] = json.loads(pathlib.Path(sys.argv[2]).read_text())
manifest["artifacts"]["scoreLambda"] = {
    "path": "score-lambda.zip", "sha256": hashlib.sha256((root / "score-lambda.zip").read_bytes()).hexdigest()}
manifest["artifacts"]["scoreRuntimePolicy"] = {
    "path": "score-runtime-policy.json", "sha256": hashlib.sha256((root / "score-runtime-policy.json").read_bytes()).hexdigest()}
path.write_text(json.dumps(manifest, indent=2) + "\n")
PY
fi
# Render every launch/S3/log/PassRole/profile resource from the exact final tuple.
# The same reviewed renderer is independently applied by verify-release.py.
python3 - "$HERE" "$RELEASE" <<'PY'
import hashlib, importlib.util, json, os, pathlib, sys
here, root = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("release_verifier", here / "verify-release.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
path = root / "release-manifest.json"
manifest = json.loads(path.read_text())
for artifact, filename in (("lambdaPolicy", "lambda-role-policy.json"),
                           ("janitorPolicy", "janitor-role-policy.json"),
                           ("bucketPolicy", "bucket-policy.json")):
    policy_path = root / filename
    policy_path.write_text(json.dumps(module.render_launch_policy(manifest, artifact), indent=2) + "\n")
    manifest["artifacts"][artifact] = {"path": filename, "sha256": hashlib.sha256(policy_path.read_bytes()).hexdigest()}
key = "USD8_EC2_RECONCILIATION_BOUND_SECONDS"
if key in os.environ:
    manifest["aws"]["lambdaEnvironment"][key] = os.environ[key]
path.write_text(json.dumps(manifest, indent=2) + "\n")
PY
RELEASE_ID=$(python3 - "$RELEASE/release-manifest.json" <<'PY'
import hashlib, json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
print(hashlib.sha256(encoded).hexdigest())
PY
)
jq --arg releaseId "$RELEASE_ID" '.releaseId = $releaseId' \
  "$RELEASE/release-manifest.json" > "$TMP_MANIFEST"
mv "$TMP_MANIFEST" "$RELEASE/release-manifest.json"
python3 - "$RELEASE" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
artifacts = json.loads((root / "release-manifest.json").read_text())["artifacts"]
(root / "SHA256SUMS").write_text("".join(
    f"{entry['sha256']}  {entry['path']}\n" for entry in artifacts.values()))
PY
python3 "$HERE/verify-release.py" "$RELEASE/release-manifest.json"
mkdir -p "$(dirname "$OUT")"
mv "$RELEASE" "$OUT"
python3 - "$OUT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for path in root.rglob("*"):
    path.chmod(0o555 if path.is_dir() else 0o444)
root.chmod(0o555)
PY
printf 'RELEASE_CANDIDATE_CREATED=%s\nRELEASE_ID=%s\n' "$OUT" "$RELEASE_ID"
printf 'LIVE_VERIFICATION_REQUIRED=python3 %s/verify-release.py "%s/release-manifest.json" --live --rpc-url <direct-https-sepolia-rpc> --security-baseline <approved-json> --baseline-sha256 <externally-approved-sha256>\n' "$HERE" "$OUT"
printf 'DEPLOYMENT_ENTRYPOINT=python3 %s/deploy-release.py (see RELEASE-GATES.md; --plan is local-only)\n' "$HERE"
