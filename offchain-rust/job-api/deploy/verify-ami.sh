#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^ami-[0-9a-f]+$ ]]; then
  echo "usage: $0 <ami-id>" >&2
  exit 2
fi

ami_id=$1
region=${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}

aws ec2 describe-images \
  --region "$region" \
  --image-ids "$ami_id" \
  --output json \
| python3 -c '
import json
import sys

ami_id = sys.argv[1]
doc = json.load(sys.stdin)
images = doc.get("Images", [])
if len(images) != 1:
    raise SystemExit(f"AMI_ENCRYPTION_CHECK_FAILED: expected one image for {ami_id}")
image = images[0]
if image.get("State") != "available":
    raise SystemExit("AMI_ENCRYPTION_CHECK_FAILED: image is not available")
if image.get("Public") is not False:
    raise SystemExit("AMI_ENCRYPTION_CHECK_FAILED: image is public")
root = image.get("RootDeviceName")
root_mapping = next(
    (item.get("Ebs") for item in image.get("BlockDeviceMappings", []) if item.get("DeviceName") == root),
    None,
)
if not root_mapping:
    raise SystemExit("AMI_ENCRYPTION_CHECK_FAILED: root EBS mapping is missing")
if root_mapping.get("Encrypted") is not True:
    raise SystemExit("AMI_ENCRYPTION_CHECK_FAILED: root EBS snapshot is not encrypted")
if root_mapping.get("DeleteOnTermination") is not True:
    raise SystemExit("AMI_ENCRYPTION_CHECK_FAILED: root EBS volume is not delete-on-termination")
snapshot_id = root_mapping.get("SnapshotId")
if not snapshot_id:
    raise SystemExit("AMI_ENCRYPTION_CHECK_FAILED: root EBS snapshot ID is missing")
print(f"AMI_ENCRYPTION_CHECK_PASSED: {ami_id} {snapshot_id}")
' "$ami_id"
