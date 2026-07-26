#!/bin/bash
set -euo pipefail

RELEASE_DIR=${1:?usage: install-parent.sh RELEASE_DIR}
EIF_SHA256=$(sha256sum "$RELEASE_DIR/usd8-tee-enclave.eif" | cut -d' ' -f1)
install -d -m 0755 /opt/usd8
install -m 0555 "$RELEASE_DIR/usd8-tee-parent" /opt/usd8/usd8-tee-parent
install -m 0444 "$RELEASE_DIR/usd8-tee-enclave.eif" /opt/usd8/enclave.eif
cat > /opt/usd8/release.env <<EOF
USD8_EIF_PATH=/opt/usd8/enclave.eif
USD8_EIF_SHA256=$EIF_SHA256
EOF
chmod 0444 /opt/usd8/release.env
install -m 0444 "$(dirname "$0")/usd8-tee-job.service" /etc/systemd/system/usd8-tee-job.service
cat > /etc/nitro_enclaves/allocator.yaml <<'EOF'
---
memory_mib: 3072
cpu_count: 2
EOF
# The fixed Rust parent owns both vsock proxies; do not install an independent
# proxy allowlist that can drift from the build-pinned parent binary.
rm -f /etc/nitro_enclaves/vsock-proxy.yaml
systemctl daemon-reload
systemctl enable nitro-enclaves-allocator.service
systemctl disable usd8-tee-job.service sshd.service
rm -rf /root/.ssh /home/ec2-user/.ssh
