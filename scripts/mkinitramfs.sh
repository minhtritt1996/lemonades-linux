#!/bin/bash
# Build the lemonades mainline ramdisk (initramfs).
#
#   scripts/mkinitramfs.sh [OUT]   default: build/out/initrd.cpio.gz
set -euo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
OUT=${1:-$ROOT/build/out/initrd.cpio.gz}
CC=${CC:-${CROSS_COMPILE:-aarch64-linux-gnu-}gcc}
TMP="$ROOT/build/initramfs"

command -v "$CC" >/dev/null || { echo "mkinitramfs: $CC not found" >&2; exit 1; }
command -v cpio >/dev/null || { echo "mkinitramfs: cpio not found" >&2; exit 1; }

rm -rf "$TMP"
mkdir -p "$TMP/dev" "$TMP/proc" "$TMP/sys" "$TMP/tmp" "$TMP/run" "$TMP/mnt" \
	 "$TMP/newroot" "$TMP/sys/fs/pstore" "$TMP/sys/kernel/config"
mkdir -p "$TMP/var/lib/tqftpserv/readonly" "$TMP/var/lib/tqftpserv/readwrite" \
	 "$TMP/var/lib/pd-mapper"

"$CC" -static -Os -s -Wall -Wextra -Werror -o "$TMP/init" "$ROOT/initramfs/init.c"
chmod 755 "$TMP/init"

# SM8250 GPU/ADSP/CDSP/Venus firmware (vendor blobs, kept out of git)
if [ -d "$ROOT/prebuilt/fw-sm8250" ]; then
	mkdir -p "$TMP/lib/firmware/qcom" "$TMP/lib/firmware/qca"
	cp -a "$ROOT"/prebuilt/fw-sm8250/* "$TMP/lib/firmware/qcom/"
	echo "    [OK] sm8250 firmware: $(find "$TMP/lib/firmware/qcom" -type f | wc -l) files"
fi

# QCA6390 Wi-Fi firmware (if staged locally)
if [ -d "$ROOT/prebuilt/fw-ath11k" ]; then
	mkdir -p "$TMP/lib/firmware/ath11k"
	cp -a "$ROOT"/prebuilt/fw-ath11k/* "$TMP/lib/firmware/ath11k/"
	echo "    [OK] ath11k firmware: $(find "$TMP/lib/firmware/ath11k" -type f | wc -l) files"
fi

# Firmware that built-in drivers request during initcalls, before /init can
# mount the vendor partitions: Bluetooth (hci_qca), cfg80211 regulatory.db and
# the SLPI image.  Staged from the phone; never committed (see .gitignore).
if [ -d "$ROOT/prebuilt/fw-extra" ]; then
	mkdir -p "$TMP/lib/firmware"
	cp -a "$ROOT"/prebuilt/fw-extra/. "$TMP/lib/firmware/"
	echo "    [OK] early firmware: $(find "$TMP/lib/firmware" -type f | wc -l) files"
fi

# Kernel modules (only pack 6.18.34 modules when explicitly requested)
if [ "${USE_618_MODULES:-0}" = "1" ] && [ -d "$ROOT/prebuilt/modules-6.18.34/6.18.34-current-sm8250" ]; then
	mkdir -p "$TMP/lib/modules"
	cp -a "$ROOT/prebuilt/modules-6.18.34/6.18.34-current-sm8250" "$TMP/lib/modules/"
	echo "    [OK] modules 6.18.34-current-sm8250: $(find "$TMP/lib/modules/6.18.34-current-sm8250" -type f | wc -l) files"
fi

mkdir -p "$TMP/bin" "$TMP/run/rmtfs" "$TMP/usr/share/lemonades"
if [ -f "$ROOT/initramfs/charge-gui/lemonades-charge-gui" ]; then
	cp "$ROOT/initramfs/charge-gui/lemonades-charge-gui" "$TMP/usr/share/lemonades/lemonades-charge-gui"
	chmod 755 "$TMP/usr/share/lemonades/lemonades-charge-gui"
fi
if compgen -G "$ROOT/initramfs/bin/*" >/dev/null; then
	for f in "$ROOT"/initramfs/bin/*; do
		case "$f" in *.md) continue ;; esac
		cp "$f" "$TMP/bin/"
	done
	chmod 755 "$TMP"/bin/* 2>/dev/null || true
fi

mkdir -p "$(dirname "$OUT")"
(cd "$TMP" && find . -print0 | cpio --null -o -H newc --owner=0:0 2>/dev/null | gzip -9) > "$OUT"
ls -lh "$OUT"
