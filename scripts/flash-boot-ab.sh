#!/bin/bash
# Flash a candidate boot.img to the INACTIVE OnePlus 9R A/B slot and activate it.
#
# The running slot is never written.  After the candidate boots, slot-success.service
# (units=denial.service sshd.service, settle=60) marks the new slot successful; if it
# hangs before that, Qualcomm ABL falls back to the still-successful old slot.
#
#   scripts/flash-boot-ab.sh [--yes] [BOOT.IMG] [root@host]
#
#   --yes   actually write and activate (default: print the plan only)
#   default image: build/out/boot.img
#   default host:  root@100.77.140.71
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
IMG="$ROOT/build/out/boot.img"
HOST=root@100.77.140.71
YES=0

for arg in "$@"; do
	case "$arg" in
	--yes) YES=1 ;;
	-*) echo "unknown option: $arg" >&2; exit 2 ;;
	*@*) HOST=$arg ;;
	*) IMG=$arg ;;
	esac
done

ssh_do() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$HOST" "$@"; }

[ -f "$IMG" ] || { echo "ERROR: missing $IMG" >&2; exit 1; }

# Image.gz must stay below the ramdisk offset (ABL loads initrd at 0x01000000).
if [ -f "$ROOT/build/out/Image.gz" ]; then
	sz=$(stat -c %s "$ROOT/build/out/Image.gz")
	[ "$sz" -lt 16744448 ] || { echo "ERROR: Image.gz $sz >= 16744448" >&2; exit 1; }
fi

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

size=$(stat -c %s "$IMG")
sha=$(sha256sum "$IMG" | cut -d' ' -f1)

echo "running slot : $cur (active, successful)"
echo "candidate    : $other  <- will be overwritten and activated"
echo "image        : $IMG ($size bytes, sha256 $sha)"
echo "host         : $HOST"

if [ "$YES" != 1 ]; then
	echo "DRY RUN: pass --yes to write /dev/disk/by-partlabel/boot$other (then switch slot via fastboot --set-active=${other#_})"
	exit 0
fi

scp -o StrictHostKeyChecking=no -q "$IMG" "$HOST:/tmp/boot.img"
remote_sha=$(ssh_do sha256sum /tmp/boot.img | cut -d' ' -f1)
[ "$remote_sha" = "$sha" ] || { echo "ERROR: copy sha mismatch ($remote_sha)" >&2; exit 1; }

ssh_do "dd if=/tmp/boot.img of=/dev/disk/by-partlabel/boot$other bs=4M conv=fsync 2>&1 | tail -1; sync"
back_sha=$(ssh_do "head -c $size /dev/disk/by-partlabel/boot$other | sha256sum" | cut -d' ' -f1)
[ "$back_sha" = "$sha" ] || { echo "ERROR: readback sha mismatch ($back_sha)" >&2; exit 1; }

zeros=$(ssh_do "head -c 64 /dev/disk/by-partlabel/dtbo$other | od -An -v -tx1 | tr -d ' \n'")
case "$zeros" in
*[!0]*) echo "ERROR: dtbo$other is not zeroed; ABL may reject the slot" >&2; exit 1 ;;
esac

# Do NOT call `qbootctl -s`: upstream linux-msm/qbootctl (bootctrl_impl.c:551-558)
# swaps TypeGUIDs in the opposite direction of the Active flag on LUN 4, leaving
# the new active slot with inactive_guid (77036cd4) and triggering ABL
# "Failed to load/authenticate boot image: Device Error".
echo "candidate written to boot$other."
echo "reboot to bootloader and run: fastboot --set-active=${other#_}"
echo "after boot, slot-success marks $other successful once denial+sshd ran for 60 s."
