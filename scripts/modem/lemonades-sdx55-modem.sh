#!/bin/sh
# Bring the external SDX55M (PCIe2/MHI) up to AMSS and keep its EFS in sync.
#
# Deployed by scripts/modem/install.sh and run as
# lemonades-sdx55-modem.service on the phone.  The kernel side is
# patches/linux/lemonades/0016-*/0017-* plus CONFIG_MHI_SAHARA/MHI_NET/WWAN,
# which load sbl1.mbn through BHI and expose /dev/mhi_pipe_2 (SAHARA) and
# /dev/mhi_pipe_10 (EFS).
#
# The modem has no flash: everything after the SBL is pushed by this script's
# SAHARA loader, and its NV lives on the phone's mdm1m9kefs* partitions.
set -u

FWDIR=${FWDIR:-/lib/firmware/qcom/sdx55m}
STORE=${STORE:-/var/lib/lemonades-sdx55/efs}
SEED=${SEED:-/run/lemonades-sdx55}
LOADER=${LOADER:-/usr/local/sbin/lemonades-sdx55-sahara}

log() { printf '[lemonades-sdx55] %s\n' "$*"; }

mkdir -p "$STORE" "$SEED"

# Brief settle delay before touching MHI pipes at early boot.
if [ "${MODEM_SETTLE_S:-2}" -gt 0 ] 2>/dev/null; then
	sleep "${MODEM_SETTLE_S:-2}"
fi

# SAHARA image IDs 16/17/20 are the modem's EFS (NV) images and 34 is DDR
# training data.  The files shipped in image/sdx55m are not usable for those:
# efs{1,2,3}.bin are 512-byte "IMGEFS- DUMMY" placeholders and mdmddr.mbn is a
# 40-byte header.  Serve read-only copies of the live partitions instead;
# nothing is ever written back to raw UFS partitions.
seed_part() {
	id=$1 label=$2 dev=/dev/disk/by-partlabel/$label
	if [ ! -e "$dev" ]; then
		log "missing partition $label"
		return 1
	fi
	dd if="$dev" of="$SEED/img$id.bin" bs=1M status=none || return 1
	log "seeded img$id.bin from $label ($(stat -c%s "$SEED/img$id.bin") bytes)"
}

OVERRIDES=""
if seed_part 16 mdm1m9kefs1 && seed_part 17 mdm1m9kefs2 && seed_part 20 mdm1m9kefs3; then
	OVERRIDES="--override 16=$SEED/img16.bin"
	OVERRIDES="$OVERRIDES --override 17=$SEED/img17.bin"
	OVERRIDES="$OVERRIDES --override 20=$SEED/img20.bin"
else
	log "WARNING: falling back to the placeholder EFS images (no IMEI/NV)"
fi
if seed_part 34 mdmddr; then
	OVERRIDES="$OVERRIDES --override 34=$SEED/img34.bin"
fi

BLLOG_PID=""
cleanup() {
	[ -n "$BLLOG_PID" ] && kill "$BLLOG_PID" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Image transfer.  The modem keeps its SBL/AMSS state across an AP reboot,
#    so an existing EFS pipe means it is already in mission mode.
if [ -e /dev/mhi_pipe_10 ]; then
	log "EFS pipe present: modem is already in mission mode"
else
	i=0
	while [ ! -e /dev/mhi_pipe_2 ] && [ "$i" -lt 120 ]; do
		i=$((i + 1))
		sleep 1
	done
	if [ ! -e /dev/mhi_pipe_2 ]; then
		log "ERROR: SAHARA pipe /dev/mhi_pipe_2 never appeared"
		exit 1
	fi
	log "pushing images on /dev/mhi_pipe_2 from $FWDIR"
	# The SBL streams its boot log into the BL channel; keep it drained so the
	# SBL never blocks on an unconsumed log ring, and keep it for diagnosis.
	if [ -e /dev/mhi_pipe_25 ]; then
		BLLOG=${BLLOG:-/var/log/lemonades-sdx55-bl.log}
		mkdir -p "$(dirname "$BLLOG")"
		cat /dev/mhi_pipe_25 >"$BLLOG" 2>/dev/null &
		BLLOG_PID=$!
		log "SBL boot log -> $BLLOG"
	fi
	# Optional legacy restart workaround (disabled by default now that MSI
	# and ap2mdm_status are wired cleanly).
	if [ "${MODEM_SAHARA_RESTART_WORKAROUND:-0}" = "1" ] && [ -d /sys/module/mhi_sahara/parameters ]; then
		echo 500 > /sys/module/mhi_sahara/parameters/restart_after_hello_resp_ms 2>/dev/null || true
		echo 300 > /sys/module/mhi_sahara/parameters/restart_after_data_ms 2>/dev/null || true
		echo 1 > /sys/module/mhi_sahara/parameters/restart_resync_db 2>/dev/null || true
	fi
	# The SAHARA pipe can be opened before the device has finished its
	# SBL transition; that open fails with EIO, so retry a few times.
	attempt=0
	while :; do
		attempt=$((attempt + 1))
		# shellcheck disable=SC2086 # OVERRIDES is a list of arguments
		"$LOADER" --dev /dev/mhi_pipe_2 --firmware-dir "$FWDIR" \
			--sessions 12 --max-request 0 $OVERRIDES
		rc=$?
		if [ "$rc" -eq 0 ] || [ -e /dev/mhi_pipe_10 ] || [ "$attempt" -ge 6 ]; then
			break
		fi
		log "loader attempt $attempt failed (rc=$rc); retrying in 10 s"
		sleep 10
	done
fi

# 2. Persistent EFS sync responder, Android `ks -m -p pipe_10 -w <store> -t -1`.
#    Note: writes atomically into $STORE only; raw mdm1m9kefs* partitions are
#    never written to.
i=0
while [ ! -e /dev/mhi_pipe_10 ] && [ "$i" -lt 120 ]; do
	i=$((i + 1))
	sleep 1
done
if [ ! -e /dev/mhi_pipe_10 ]; then
	log "ERROR: EFS pipe /dev/mhi_pipe_10 never appeared; modem not in AMSS"
	exit 1
fi
[ -n "$BLLOG_PID" ] && kill "$BLLOG_PID" 2>/dev/null || true
BLLOG_PID=""
log "starting persistent EFS sync responder (dumps -> $STORE)"
exec "$LOADER" --dev /dev/mhi_pipe_10 --hello-mode 2 --persist \
	--mem-dump-dir "$STORE" --mem-prefix ""
