#!/bin/sh
# Read-only verification of the external SDX55M 5G modem on OnePlus 9R.
#
# Checks PCIe2/MHI AMSS state, EFS sync pipe, QRTR node 3, QMI DMS/UIM/NAS
# responses, and the mhi_hwip0 network interface.  Does NOT require a working
# physical SIM or cellular data registration.
set -u

NODE=${QRTR_MODEM_NODE:-3}

section() { printf '\n=== %s ===\n' "$*"; }

section "MHI state"
if [ -d /sys/bus/mhi/devices/mhi0 ]; then
	for f in ee state; do
		if [ -r "/sys/bus/mhi/devices/mhi0/$f" ]; then
			printf 'mhi0/%s=%s\n' "$f" "$(cat "/sys/bus/mhi/devices/mhi0/$f")"
		fi
	done
else
	echo "mhi0 not present"
fi
ls -l /dev/mhi_pipe_* /dev/wwan* 2>/dev/null || true

section "WWAN / MHI net interfaces"
ip -br link show mhi_hwip0 2>/dev/null || echo "mhi_hwip0 not present"
ip -br link show mhi_swip0 2>/dev/null || true

section "Services"
for u in tqftpserv.service lemonades-sdx55-modem.service; do
	printf '%s: %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"
done
ls -lh /var/lib/lemonades-sdx55/efs 2>/dev/null || true

section "QRTR lookup (node $NODE & TFTP 4096)"
if command -v qrtr-lookup >/dev/null 2>&1; then
	qrtr-lookup | awk -v n="$NODE" 'NR==1 || $1==4096 || $4==n'
else
	echo "qrtr-lookup not installed"
fi

section "QMI probes (qrtr://$NODE)"
if command -v qmicli >/dev/null 2>&1; then
	for cmd in \
		--dms-get-manufacturer \
		--dms-get-model \
		--dms-get-revision \
		--dms-get-operating-mode \
		--dms-get-ids \
		--uim-get-card-status \
		--nas-get-rf-band-info \
		--nas-get-signal-info
	do
		printf '\n--- qmicli %s ---\n' "$cmd"
		qmicli -d "qrtr://$NODE" "$cmd" 2>&1 || true
	done
else
	echo "qmicli not installed"
fi
