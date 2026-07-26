#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <built-release-directory> <final-release-directory>" >&2
  exit 2
fi
BUILD_DIR=$(cd "$1" && pwd)
OUT=$2
AMI_ID=${AMI_ID:?set AMI_ID}
AWS_REGION=${AWS_REGION:?set AWS_REGION}
KMS_KEY_ID=${KMS_KEY_ID:?set KMS_KEY_ID}
LAMBDA_FUNCTION=${LAMBDA_FUNCTION:?set LAMBDA_FUNCTION}
JANITOR_FUNCTION=${JANITOR_FUNCTION:?set JANITOR_FUNCTION}
LAMBDA_ROLE=${LAMBDA_ROLE:?set LAMBDA_ROLE}
LAMBDA_POLICY_NAME=${LAMBDA_POLICY_NAME:?set LAMBDA_POLICY_NAME}
JANITOR_ROLE=${JANITOR_ROLE:?set JANITOR_ROLE}
JANITOR_POLICY_NAME=${JANITOR_POLICY_NAME:?set JANITOR_POLICY_NAME}
INSTANCE_ROLE=${INSTANCE_ROLE:?set INSTANCE_ROLE}
INSTANCE_POLICY_NAME=${INSTANCE_POLICY_NAME:?set INSTANCE_POLICY_NAME}
JOB_BUCKET=${JOB_BUCKET:?set JOB_BUCKET}
INSTANCE_TYPE=${INSTANCE_TYPE:?set INSTANCE_TYPE}
INSTANCE_PROFILE=${INSTANCE_PROFILE:?set INSTANCE_PROFILE}
SUBNET_ID=${SUBNET_ID:?set SUBNET_ID}
SECURITY_GROUP_ID=${SECURITY_GROUP_ID:?set SECURITY_GROUP_ID}
JANITOR_MAX_AGE_SECONDS=${JANITOR_MAX_AGE_SECONDS:?set JANITOR_MAX_AGE_SECONDS}

[[ "$AMI_ID" =~ ^ami-[0-9a-f]+$ ]] || { echo 'invalid AMI_ID' >&2; exit 2; }
[[ "$AWS_REGION" == eu-central-1 ]] || { echo 'AWS_REGION must be eu-central-1' >&2; exit 2; }
[[ ! -e "$OUT" ]] || { echo "final release already exists: $OUT" >&2; exit 2; }

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

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
RELEASE="$STAGE/release"
mkdir "$RELEASE"
cp -a "$BUILD_DIR/." "$RELEASE/"

jq --arg ami "arn:aws:ec2:${AWS_REGION}::image/${AMI_ID}" '
  walk(if type == "string" and test("^arn:aws:ec2:[^:]+::image/ami-") then $ami else . end)
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
TMP_MANIFEST="$RELEASE/release-manifest.json.tmp"
jq \
  --arg region "$AWS_REGION" --arg ami "$AMI_ID" \
  --arg snapshot "$ROOT_SNAPSHOT" --arg lambdaFunction "$LAMBDA_FUNCTION" \
  --arg janitorFunction "$JANITOR_FUNCTION" --arg lambdaCode "$LAMBDA_CODE_SHA256_B64" \
  --arg janitorCode "$JANITOR_CODE_SHA256_B64" --arg kmsKey "$KMS_KEY_ID" \
  --arg instanceRole "$INSTANCE_ROLE" --arg instancePolicyName "$INSTANCE_POLICY_NAME" \
  --arg lambdaRole "$LAMBDA_ROLE" --arg lambdaPolicyName "$LAMBDA_POLICY_NAME" \
  --arg janitorRole "$JANITOR_ROLE" --arg janitorPolicyName "$JANITOR_POLICY_NAME" \
  --arg jobBucket "$JOB_BUCKET" --arg instanceType "$INSTANCE_TYPE" \
  --arg instanceProfile "$INSTANCE_PROFILE" --arg subnet "$SUBNET_ID" \
  --arg securityGroup "$SECURITY_GROUP_ID" --arg janitorMaxAge "$JANITOR_MAX_AGE_SECONDS" \
  --arg lambdaPolicyHash "$LAMBDA_POLICY_SHA256" --arg janitorPolicyHash "$JANITOR_POLICY_SHA256" '
  .status = "final"
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
      lambdaCodeSha256Base64: $lambdaCode,
      janitorCodeSha256Base64: $janitorCode,
      kmsKeyId: $kmsKey,
      instanceRole: $instanceRole,
      instancePolicyName: $instancePolicyName,
      lambdaRole: $lambdaRole,
      lambdaPolicyName: $lambdaPolicyName,
      janitorRole: $janitorRole,
      janitorPolicyName: $janitorPolicyName,
      functionUrlAuthType: "AWS_IAM",
      lambdaEnvironment: {
        USD8_REGISTRY: .registry,
        USD8_JOB_BUCKET: $jobBucket,
        USD8_TEE_AMI_ID: $ami,
        USD8_TEE_INSTANCE_TYPE: $instanceType,
        USD8_TEE_INSTANCE_PROFILE: $instanceProfile,
        USD8_TEE_SUBNET_ID: $subnet,
        USD8_TEE_SECURITY_GROUP_ID: $securityGroup
      },
      janitorEnvironment: {USD8_TEE_MAX_AGE_SECONDS: $janitorMaxAge}
    }
' "$RELEASE/release-manifest.json" > "$TMP_MANIFEST"
mv "$TMP_MANIFEST" "$RELEASE/release-manifest.json"
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
(cd "$RELEASE" && sha256sum lambda-role-policy.json janitor-role-policy.json >> SHA256SUMS)
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
printf 'FINAL_RELEASE_CREATED=%s\nRELEASE_ID=%s\n' "$OUT" "$RELEASE_ID"
