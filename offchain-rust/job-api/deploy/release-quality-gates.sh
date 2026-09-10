#!/usr/bin/env bash
# Run from CI or the committed release export, never bypass with a dirty build.
set -euo pipefail
[[ $(uname -s) == Linux ]] || { printf 'LINUX_RELEASE_GATES_REQUIRED\n' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-1}
# Audit all four independent graphs once, before other gates can fail early.
python3 "$ROOT/job-api/deploy/audit-dependencies.py"
cd "$ROOT/job-api"
cargo +1.94.1 fmt --check
cargo +1.94.1 test --locked --all-targets --all-features
cargo +1.94.1 clippy --locked --all-targets --all-features -- -D warnings
cd "$ROOT/score-api"
cargo +1.94.1 fmt --check
python3 "$ROOT/job-api/deploy/with-dynamodb-tests.py" -- \
  cargo +1.94.1 test --locked --all-targets --features lambda,sepolia -- --include-ignored
cargo +1.94.1 clippy --locked --all-targets --features lambda,sepolia -- -D warnings
cd "$ROOT/score-core"
cargo +1.94.1 test --locked --all-targets
cargo +1.94.1 clippy --locked --all-targets -- -D warnings
cd "$ROOT"
python3 -m unittest discover -s job-api/deploy/tests -v
python3 -m unittest bench/test_real_history.py -v
printf 'LINUX_RELEASE_QUALITY_GATES_PASSED\n'
