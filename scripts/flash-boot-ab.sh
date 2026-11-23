#!/bin/bash
# Flash a candidate boot.img to the INACTIVE OnePlus 9R A/B slot.
#
# The running slot is never written. After switching slot via
# `fastboot --set-active=<a|b>`, slot-success.service
# (units=denial.service sshd.service, settle=60) marks the new slot successful;
# if it hangs before that, Qualcomm ABL falls back to the still-successful old slot.
#
#   scripts/flash-boot-ab.sh [--yes] [BOOT.IMG] [root@host]
#
#   --yes   actually write /dev/disk/by-partlabel/boot_<inactive> (default: dry-run)
#   default image: build/out/boot.img
#   default host:  ${LEMONADES_HOST:-root@172.16.42.1} (USB gadget NCM)
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
IMG="$ROOT/build/out/boot.img"
DTBO_IMG="$ROOT/build/out/dtbo.img"
HOST="${LEMONADES_HOST:-root@172.16.42.1}"
YES=0

for arg in "$@"; do
	case "$arg" in
	--yes) YES=1 ;;
	-*) echo "unknown option: $arg" >&2; exit 2 ;;
	*@*) HOST=$arg ;;
	*) IMG=$arg ;;
	esac
done

ssh_do() { ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$HOST" "$@"; }

[ -f "$IMG" ] || { echo "ERROR: missing $IMG" >&2; exit 1; }
if [ -f "$(dirname "$IMG")/dtbo.img" ]; then
	DTBO_IMG="$(dirname "$IMG")/dtbo.img"
fi

# Validate boot.img v2 header (magic, page_size=4096, header_version=2) & 96 MiB limit.
size=$(stat -c %s "$IMG")
[ "$size" -gt 0 ] || { echo "ERROR: $IMG is empty" >&2; exit 1; }
[ "$size" -le 100663296 ] || { echo "ERROR: $IMG ($size bytes) exceeds 96 MiB boot partition" >&2; exit 1; }
python3 - "$IMG" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    hdr = f.read(44)
magic = hdr[:8]
page_size, header_ver = struct.unpack_from("<II", hdr, 36)
if magic != b"ANDROID!" or page_size != 4096 or header_ver != 2:
    sys.exit(f"ERROR: invalid boot.img header (magic={magic!r} page={page_size} ver={header_ver})")
PY

slot_state=$(ssh_do /usr/lib/slot-success/qbootctl)
cur=$(printf '%s\n' "$slot_state" | awk '/^Current slot:/{print $3}')
case "$cur" in
_a) other=_b ;;
_b) other=_a ;;
*) echo "ERROR: cannot read current slot from qbootctl" >&2; exit 1 ;;
esac

if ! printf '%s\n' "$slot_state" | awk -v s="SLOT $cur:" '
	$0 == s { inb = 1; next }
	/^SLOT / { inb = 0 }
	inb && /Active/    { a = $3 }
	inb && /Successful/{ ok = $3 }
	END { exit !(a == 1 && ok == 1) }'; then
	echo "ERROR: running slot $cur is not Active=1/Successful=1; refusing" >&2
	exit 1
fi

sha=$(sha256sum "$IMG" | cut -d' ' -f1)

echo "running slot : $cur (active, successful)"
echo "candidate    : $other  <- will be written (running slot stays untouched)"
echo "image        : $IMG ($size bytes, sha256 $sha)"
echo "host         : $HOST"

# Preflight DTBO check BEFORE writing boot$other: must be either all-zeroed OR
# match the generated empty dtbo.img (fail closed if read fails or DTBO_IMG is missing).
dtbo_hdr=$(ssh_do "test -r /dev/disk/by-partlabel/dtbo$other && head -c 64 /dev/disk/by-partlabel/dtbo$other | od -An -v -tx1 | tr -d ' \n'")
if [ "${#dtbo_hdr}" -ne 128 ] || [[ "$dtbo_hdr" == *[!0-9a-fA-F]* ]]; then
	echo "ERROR: failed to read 64-byte header from dtbo$other (got ${#dtbo_hdr} hex chars)" >&2
	exit 1
fi
case "$dtbo_hdr" in
d7b7ab1e*)
	[ -f "$DTBO_IMG" ] || { echo "ERROR: dtbo$other has DTBO magic but $DTBO_IMG is missing to verify it" >&2; exit 1; }
	dtbo_sz=$(stat -c %s "$DTBO_IMG")
	[ "$dtbo_sz" -gt 0 ] || { echo "ERROR: $DTBO_IMG is empty" >&2; exit 1; }
	dtbo_local=$(sha256sum "$DTBO_IMG" | cut -d' ' -f1)
	dtbo_remote=$(ssh_do "test -r /dev/disk/by-partlabel/dtbo$other && head -c $dtbo_sz /dev/disk/by-partlabel/dtbo$other | sha256sum" | cut -d' ' -f1)
	[ "${#dtbo_remote}" -eq 64 ] && [ "$dtbo_remote" = "$dtbo_local" ] || { echo "ERROR: dtbo$other contains non-empty vendor DTBO (flash empty dtbo.img once via fastboot)" >&2; exit 1; }
	;;
*[!0]*)
	echo "ERROR: dtbo$other is neither zeroed nor matching empty dtbo.img; ABL may apply conflicting vendor overlays" >&2
	exit 1
	;;
esac

if [ "$YES" != 1 ]; then
	echo "DRY RUN: pass --yes to write /dev/disk/by-partlabel/boot$other (then switch slot via fastboot --set-active=${other#_})"
	exit 0
fi

scp -o StrictHostKeyChecking=accept-new -q "$IMG" "$HOST:/tmp/boot.img"
remote_sha=$(ssh_do sha256sum /tmp/boot.img | cut -d' ' -f1)
[ "$remote_sha" = "$sha" ] || { echo "ERROR: copy sha mismatch ($remote_sha)" >&2; exit 1; }

ssh_do "trap 'rm -f /tmp/boot.img' EXIT; dd if=/tmp/boot.img of=/dev/disk/by-partlabel/boot$other bs=4M conv=fsync status=none && sync"
back_sha=$(ssh_do "test -r /dev/disk/by-partlabel/boot$other && head -c $size /dev/disk/by-partlabel/boot$other | sha256sum" | cut -d' ' -f1)
[ "${#back_sha}" -eq 64 ] && [ "$back_sha" = "$sha" ] || { echo "ERROR: readback sha mismatch ($back_sha)" >&2; exit 1; }

# Do NOT call `qbootctl -s`: upstream linux-msm/qbootctl (bootctrl_impl.c:551-558)
# swaps TypeGUIDs in the opposite direction of the Active flag on LUN 4, leaving
# the new active slot with inactive_guid (77036cd4) and triggering ABL
# "Failed to load/authenticate boot image: Device Error".
echo "candidate written and verified on boot$other."
echo "reboot to bootloader and run: fastboot --set-active=${other#_}"
echo "after boot, slot-success marks $other successful once denial+sshd ran for 60 s."
