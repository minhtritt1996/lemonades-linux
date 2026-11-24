#!/bin/bash
# Build and install tqftpserv patched to publish QRTR service 4096 at versions
# 1 and 3 (required by external PCIe/MHI SDX55M modems) on the phone.
#
#   scripts/modem/install-tqftpserv-v3.sh [root@host]
#
# Installs to /usr/local/sbin/tqftpserv and adds a systemd drop-in for
# tqftpserv.service so the pacman-managed /usr/bin/tqftpserv is never modified.
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
HOST="${1:-${LEMONADES_HOST:-root@172.16.42.1}}"
PATCH="$ROOT/scripts/modem/0001-tqftpserv-publish-qrtr-v3.patch"
REPO="https://github.com/linux-msm/tqftpserv.git"

[ -f "$PATCH" ] || { echo "ERROR: missing $PATCH" >&2; exit 1; }

ssh_do() { ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$HOST" "$@"; }
scp_to() { scp -q -o StrictHostKeyChecking=accept-new "$1" "$HOST:$2"; }

echo "==> staging tqftpserv QRTR v3 patch on $HOST"
scp_to "$PATCH" /tmp/0001-tqftpserv-publish-qrtr-v3.patch

ssh_do "set -euo pipefail
rm -rf /tmp/tqftpserv-v3-build
git clone --depth 1 '$REPO' /tmp/tqftpserv-v3-build
cd /tmp/tqftpserv-v3-build
git apply /tmp/0001-tqftpserv-publish-qrtr-v3.patch
meson setup build
ninja -C build tqftpserv
install -m 755 build/tqftpserv /usr/local/sbin/tqftpserv
mkdir -p /etc/systemd/system/tqftpserv.service.d
cat >/etc/systemd/system/tqftpserv.service.d/10-lemonades-qrtr3.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/sbin/tqftpserv
EOF
systemctl daemon-reload
systemctl restart tqftpserv.service
rm -rf /tmp/tqftpserv-v3-build /tmp/0001-tqftpserv-publish-qrtr-v3.patch
systemctl is-active tqftpserv.service
qrtr-lookup | awk 'NR==1 || \$1==4096'
"
