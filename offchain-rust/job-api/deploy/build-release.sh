#!/bin/bash
set -euo pipefail

EXPECTED_SIGNER=${EXPECTED_SIGNER:?set EXPECTED_SIGNER}
NETWORK=${NETWORK:?set NETWORK to ethereum or sepolia}
REGISTRY=${REGISTRY:?set REGISTRY}
OUT=${OUT_DIR:?set OUT_DIR to a new release-build directory}
[[ "$EXPECTED_SIGNER" =~ ^0x[0-9a-fA-F]{40}$ ]] || {
  echo 'EXPECTED_SIGNER must be a 20-byte 0x hex address' >&2; exit 2;
}
[[ "$REGISTRY" =~ ^0x[0-9a-fA-F]{40}$ && "$REGISTRY" != 0x0000000000000000000000000000000000000000 ]] || {
  echo 'REGISTRY must be a nonzero 20-byte 0x hex address' >&2; exit 2;
}
case "$NETWORK" in
  ethereum) ROOT_FEATURES=(); JOB_FEATURES=worker,parent; CHAIN_ID=1 ;;
  sepolia) ROOT_FEATURES=(--features sepolia); JOB_FEATURES=worker,parent,sepolia; CHAIN_ID=11155111 ;;
  *) echo 'NETWORK must be ethereum or sepolia' >&2; exit 2 ;;
esac
WORKTREE_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REPO_ROOT=$(git -C "$WORKTREE_ROOT" rev-parse --show-toplevel)
export RUSTUP_TOOLCHAIN=1.94.1
[[ ! -e "$OUT" ]] || { echo "OUT_DIR already exists: $OUT" >&2; exit 2; }
[[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- offchain-rust)" ]] || {
  echo 'measured offchain-rust source must be committed and clean' >&2; exit 1;
}
GIT_COMMIT=$(git -C "$REPO_ROOT" rev-parse HEAD)
STAGE=$(mktemp -d)
CONTEXT="$STAGE/context"
RELEASE="$STAGE/release"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$CONTEXT" "$RELEASE" "$STAGE/source"
git -C "$REPO_ROOT" archive "$GIT_COMMIT" offchain-rust | tar -x -C "$STAGE/source"
ROOT="$STAGE/source/offchain-rust"

SOURCE_SHA256=$(python3 - "$ROOT" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
patterns = (
    "Cargo.toml", "Cargo.lock", ".cargo/**/*", "src/**/*.rs",
    "job-api/Cargo.toml", "job-api/Cargo.lock", "job-api/rust-toolchain.toml",
    "job-api/.cargo/**/*", "job-api/src/**/*.rs", "job-api/deploy/**/*",
)
files = sorted({p for pattern in patterns for p in root.glob(pattern) if p.is_file()
                and p.name != "release-manifest.json" and p.suffix != ".pyc"
                and "__pycache__" not in p.parts})
h = hashlib.sha256()
for path in files:
    relative = path.relative_to(root).as_posix().encode()
    h.update(len(relative).to_bytes(4, "big"))
    h.update(relative)
    data = path.read_bytes()
    h.update(len(data).to_bytes(8, "big"))
    h.update(data)
print(h.hexdigest())
PY
)
GIT_DIRTY=false
ROOT_LOCK_SHA256=$(sha256sum "$ROOT/Cargo.lock" | cut -d' ' -f1)
JOB_LOCK_SHA256=$(sha256sum "$ROOT/job-api/Cargo.lock" | cut -d' ' -f1)
RUSTC_VERSION=$(rustc --version)
BASE_IMAGE=$(sed -n 's/^FROM //p' "$ROOT/job-api/deploy/Dockerfile.enclave")
[[ "$BASE_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || { echo 'enclave base image must be digest-pinned' >&2; exit 1; }

cd "$ROOT"
CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-1} cargo build --release --locked \
  "${ROOT_FEATURES[@]}" --bin usd8-settlement
cd job-api
USD8_REGISTRY="$REGISTRY" CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-1} cargo build --release --locked \
  --features "$JOB_FEATURES" --bin usd8-tee-enclave --bin usd8-tee-parent
CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-1} cargo build --release --locked \
  --features lambda,janitor --bin usd8-tee-job-lambda --bin usd8-tee-janitor

install -m 0555 target/release/usd8-tee-enclave "$CONTEXT/usd8-tee-enclave"
install -m 0444 deploy/Dockerfile.enclave "$CONTEXT/Dockerfile"
docker build --pull=false --build-arg "EXPECTED_SIGNER=$EXPECTED_SIGNER" \
  -t usd8-tee-enclave:release "$CONTEXT"
nitro-cli build-enclave --docker-uri usd8-tee-enclave:release \
  --output-file "$RELEASE/usd8-tee-enclave.eif" > "$RELEASE/measurements.json"
install -m 0555 target/release/usd8-tee-parent "$RELEASE/usd8-tee-parent"
install -m 0555 "$ROOT/target/release/usd8-settlement" "$RELEASE/usd8-settlement"
python3 - target/release/usd8-tee-job-lambda "$RELEASE/lambda.zip" \
  target/release/usd8-tee-janitor "$RELEASE/janitor.zip" <<'PY'
import pathlib
import stat
import sys
import zipfile

for source, destination in zip(sys.argv[1::2], sys.argv[2::2]):
    info = zipfile.ZipInfo("bootstrap", date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (stat.S_IFREG | 0o555) << 16
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        archive.writestr(info, pathlib.Path(source).read_bytes())
PY

# Keep every release descriptor and both halves of the KMS authorization gate
# synchronized with the exact EIF produced above.
PCR0=$(jq -er '.Measurements.PCR0 | select(test("^[0-9a-fA-F]{96}$"))' "$RELEASE/measurements.json")
PCR1=$(jq -er '.Measurements.PCR1 | select(test("^[0-9a-fA-F]{96}$"))' "$RELEASE/measurements.json")
PCR2=$(jq -er '.Measurements.PCR2 | select(test("^[0-9a-fA-F]{96}$"))' "$RELEASE/measurements.json")
TEE_PCR_HASH=$("$ROOT/target/release/usd8-settlement" pcr-hash "$PCR0" "$PCR1" "$PCR2")
[[ "$TEE_PCR_HASH" =~ ^0x[0-9a-fA-F]{64}$ ]] || {
  echo 'invalid derived TEE PCR hash' >&2; exit 1;
}
for POLICY in kms-key-policy.json instance-role-policy.json; do
  jq --arg pcr0 "$PCR0" '
    .Statement |= map(
      if (.Sid == "AttestedEnclaveDecryptOnly" or .Sid == "AttestedDecryptOnly")
      then .Condition.StringEqualsIgnoreCase["kms:RecipientAttestation:ImageSha384"] = $pcr0
      else . end
    )' "deploy/$POLICY" > "$RELEASE/$POLICY"
done

EIF_SHA256=$(sha256sum "$RELEASE/usd8-tee-enclave.eif" | cut -d' ' -f1)
PARENT_SHA256=$(sha256sum "$RELEASE/usd8-tee-parent" | cut -d' ' -f1)
SETTLEMENT_SHA256=$(sha256sum "$RELEASE/usd8-settlement" | cut -d' ' -f1)
LAMBDA_SHA256=$(sha256sum "$RELEASE/lambda.zip" | cut -d' ' -f1)
JANITOR_SHA256=$(sha256sum "$RELEASE/janitor.zip" | cut -d' ' -f1)
KMS_POLICY_SHA256=$(sha256sum "$RELEASE/kms-key-policy.json" | cut -d' ' -f1)
INSTANCE_POLICY_SHA256=$(sha256sum "$RELEASE/instance-role-policy.json" | cut -d' ' -f1)
jq -n \
  --arg source "$SOURCE_SHA256" --arg commit "$GIT_COMMIT" --argjson dirty "$GIT_DIRTY" \
  --arg rootLock "$ROOT_LOCK_SHA256" --arg jobLock "$JOB_LOCK_SHA256" \
  --arg rustc "$RUSTC_VERSION" --arg baseImage "$BASE_IMAGE" \
  --arg pcr0 "$PCR0" --arg pcr1 "$PCR1" --arg pcr2 "$PCR2" \
  --arg teePcrHash "$TEE_PCR_HASH" \
  --arg network "$NETWORK" --argjson chainId "$CHAIN_ID" \
  --arg registry "$REGISTRY" --arg signer "$EXPECTED_SIGNER" \
  --arg eif "$EIF_SHA256" --arg parent "$PARENT_SHA256" \
  --arg settlement "$SETTLEMENT_SHA256" --arg lambda "$LAMBDA_SHA256" \
  --arg janitor "$JANITOR_SHA256" --arg kmsPolicy "$KMS_POLICY_SHA256" \
  --arg instancePolicy "$INSTANCE_POLICY_SHA256" '
  {
    schemaVersion: 2,
    status: "built",
    source: {sha256: $source, gitCommit: $commit, gitDirty: $dirty,
      cargoLocks: {root: $rootLock, jobApi: $jobLock}},
    toolchain: {rustc: $rustc, enclaveBaseImage: $baseImage},
    Measurements: {HashAlgorithm: "Sha384", PCR0: $pcr0, PCR1: $pcr1, PCR2: $pcr2},
    chainId: $chainId,
    network: $network,
    registry: $registry,
    teePcrHash: $teePcrHash,
    signer: $signer,
    artifacts: {
      eif: {path: "usd8-tee-enclave.eif", sha256: $eif},
      parent: {path: "usd8-tee-parent", sha256: $parent},
      settlement: {path: "usd8-settlement", sha256: $settlement},
      lambda: {path: "lambda.zip", sha256: $lambda},
      janitor: {path: "janitor.zip", sha256: $janitor},
      kmsPolicy: {path: "kms-key-policy.json", sha256: $kmsPolicy},
      instancePolicy: {path: "instance-role-policy.json", sha256: $instancePolicy}
    }
  }' > "$RELEASE/release-manifest.json"
(cd "$RELEASE" && sha256sum usd8-tee-enclave.eif usd8-tee-parent usd8-settlement \
  lambda.zip janitor.zip kms-key-policy.json instance-role-policy.json > SHA256SUMS)
python3 deploy/verify-release.py "$RELEASE/release-manifest.json" --allow-built
mkdir -p "$(dirname "$OUT")"
mv "$RELEASE" "$OUT"
printf 'RELEASE_BUILD_CREATED=%s\n' "$OUT"
