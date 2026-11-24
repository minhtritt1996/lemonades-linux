#!/bin/bash
# Install the SDX55M modem userspace (SAHARA loader + bring-up unit) on the phone.
#
#   scripts/modem/install.sh [--enable] [root@host]
#
#   --enable   enable + start lemonades-sdx55-modem.service (default: install only)
#   host       default: ${LEMONADES_HOST:-root@172.16.42.1} (USB gadget NCM)
#
# The kernel side (MHI SAHARA profile, pipes) must already be running; see
# build/5g-bringup.md.
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
HOST="${LEMONADES_HOST:-root@172.16.42.1}"
ENABLE=0
for arg in "$@"; do
	case "$arg" in
	--enable) ENABLE=1 ;;
	-*) echo "unknown option: $arg" >&2; exit 2 ;;
	*@*) HOST=$arg ;;
	*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

SRC="$ROOT/scripts/modem"
for f in sahara_fw_loader.py lemonades-sdx55-modem.sh verify-modem.sh; do
	[ -f "$SRC/$f" ] || { echo "ERROR: missing $SRC/$f" >&2; exit 1; }
done

ssh_do() { ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$HOST" "$@"; }
scp_to() { scp -q -o StrictHostKeyChecking=accept-new "$1" "$HOST:$2"; }

echo "==> installing modem userspace on $HOST"
scp_to "$SRC/sahara_fw_loader.py" /usr/local/sbin/lemonades-sdx55-sahara
scp_to "$SRC/lemonades-sdx55-modem.sh" /usr/local/sbin/lemonades-sdx55-modem.sh
scp_to "$SRC/verify-modem.sh" /usr/local/sbin/lemonades-sdx55-verify
scp_to "$SRC/lemonades-sdx55-modem.service" /etc/systemd/system/lemonades-sdx55-modem.service
ssh_do 'chmod 755 /usr/local/sbin/lemonades-sdx55-sahara /usr/local/sbin/lemonades-sdx55-modem.sh /usr/local/sbin/lemonades-sdx55-verify
	systemctl daemon-reload
	mkdir -p /var/lib/lemonades-sdx55/efs'

if [ "$ENABLE" = 1 ]; then
	ssh_do 'systemctl enable --now lemonades-sdx55-modem.service && systemctl --no-pager --lines=0 status lemonades-sdx55-modem.service'
else
	echo "installed (unit left disabled; pass --enable to start it)"
fi
