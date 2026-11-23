#!/bin/bash
# lemonades-linux build driver (OnePlus 9R / SM8250).
#
# Builds mainline Linux (pinned v7.3.5) with lemonades patches from read-only ./upstream
# into ./build. Never modifies upstream/.
#
#   ./build.sh linux [--clean]     Image.gz + sm8250-oneplus-lemonades.dtb -> build/out/
#   ./build.sh initramfs           build/out/initrd.cpio.gz
#   ./build.sh bootimg             build/out/boot.img (v2) + build/out/dtbo.img (empty)
#   ./build.sh export-patches      regenerate patches/linux/lemonades/*.patch from build/linux
#   ./build.sh check               apply series to a fresh tree and verify kernel + DTB build
#   ./build.sh clean               remove build/
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
UP="$ROOT/upstream"
BUILD="$ROOT/build"
WS="$BUILD/linux"
KB="$WS/out"
OUT="$BUILD/out"
PATCHES="$ROOT/patches/linux"
LINUX_UP="$UP/linux"

LINUX_REV="988117cc1bb17338c586a4e21ade88b5397eac33"

CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"
MAKE=(make -C "$WS" O="$KB" ARCH=arm64 CROSS_COMPILE="$CROSS")

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
	sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

verify_upstream() {
	local rev
	[ -d "$LINUX_UP/.git" ] || die "missing $LINUX_UP (git clone --branch v7.3.5 --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git upstream/linux)"
	rev=$(git -C "$LINUX_UP" rev-parse HEAD)
	[ "$rev" = "$LINUX_REV" ] || die "upstream/linux HEAD is $rev, expected $LINUX_REV"
	[ -z "$(git -C "$LINUX_UP" status --porcelain)" ] || die "upstream/linux is modified"
}

series() {
	grep -vE '^[[:space:]]*(#|$)' "$PATCHES/series"
}

apply_series() {
	local target=$1 p n=0
	[ -f "$PATCHES/series" ] || return 0
	while read -r p; do
		[ -f "$PATCHES/$p" ] || die "missing patch $p"
		git -C "$target" apply --whitespace=nowarn "$PATCHES/$p" || die "failed to apply $p"
		n=$((n + 1))
	done < <(series)
	echo "    [OK] $n patches applied"
}

prepare() {
	verify_upstream
	mkdir -p "$BUILD" "$OUT"
	if [ ! -d "$WS/.git" ]; then
		echo "==> Cloning upstream/linux into $WS"
		git clone -q "$LINUX_UP" "$WS"
		git -C "$WS" checkout -q "$LINUX_REV"
		echo "==> Applying lemonades patches"
		apply_series "$WS"
	else
		echo "==> Reusing existing $WS (use --clean to rebuild from upstream)"
	fi
	mkdir -p "$KB"
}

configure() {
	echo "==> Configuring (defconfig + configs/linux/*.config)"
	local frags=()
	for f in "$ROOT"/configs/linux/*.config; do frags+=("$f"); done
	"${MAKE[@]}" defconfig
	ARCH=arm64 CROSS_COMPILE="$CROSS" "$WS/scripts/kconfig/merge_config.sh" \
		-m -O "$KB" "$KB/.config" "${frags[@]}" >/dev/null
	"${MAKE[@]}" olddefconfig
}

build_kernel() {
	prepare
	configure
	echo "==> Building Image.gz + qcom/sm8250-oneplus-lemonades.dtb (-j$JOBS)"
	"${MAKE[@]}" -j"$JOBS" Image.gz qcom/sm8250-oneplus-lemonades.dtb
	cp -f "$KB/arch/arm64/boot/Image.gz" "$OUT/Image.gz"
	cp -f "$KB/arch/arm64/boot/dts/qcom/sm8250-oneplus-lemonades.dtb" "$OUT/sm8250-oneplus-lemonades.dtb"
	echo "==> Artifacts:"
	ls -lh "$OUT/Image.gz" "$OUT/sm8250-oneplus-lemonades.dtb"
}

build_initramfs() {
	echo "==> Building initramfs"
	"$ROOT/scripts/mkinitramfs.sh" "$OUT/initrd.cpio.gz"
}

build_bootimg() {
	[ -f "$OUT/Image.gz" ] || build_kernel
	[ -f "$OUT/initrd.cpio.gz" ] || build_initramfs
	echo "==> Packing boot.img (v2) + empty dtbo.img"
	python3 "$ROOT/scripts/build-bootimg.py" \
		--kernel "$OUT/Image.gz" \
		--ramdisk "$OUT/initrd.cpio.gz" \
		--dtb "$OUT/sm8250-oneplus-lemonades.dtb" \
		--out "$OUT/boot.img" \
		--dtbo-out "$OUT/dtbo.img"
}

export_patch() {
	local p="$1"; shift
	echo "==> Exporting $p"
	git -C "$WS" add -N "$@" 2>/dev/null || true
	local t
	t=$(mktemp)
	git -C "$WS" diff HEAD -- "$@" > "$t"
	if [ -s "$t" ]; then
		mv "$t" "$PATCHES/$p"
		grep -qxF "$p" "$PATCHES/series" || echo "$p" >> "$PATCHES/series"
		echo "    [OK] exported $p ($(wc -l < "$PATCHES/$p") lines)"
	else
		rm -f "$t"
		echo "    (no delta for $p)"
	fi
}

export_patches() {
	[ -d "$WS/.git" ] || die "$WS does not exist; run ./build.sh linux first"
	mkdir -p "$PATCHES/lemonades"
	export_patch "lemonades/0001-arm64-dts-qcom-add-oneplus-lemonades.patch" \
		arch/arm64/boot/dts/qcom/Makefile \
		arch/arm64/boot/dts/qcom/sm8250-oneplus-common.dtsi \
		arch/arm64/boot/dts/qcom/sm8250-oneplus-lemonades.dts
	export_patch "lemonades/0002-drm-panel-add-samsung-amb655x.patch" \
		drivers/gpu/drm/panel/Kconfig \
		drivers/gpu/drm/panel/Makefile \
		drivers/gpu/drm/panel/panel-samsung-amb655x.c
	export_patch "lemonades/0003-input-touchscreen-add-synaptics-s3908.patch" \
		drivers/input/touchscreen/Kconfig \
		drivers/input/touchscreen/Makefile \
		drivers/input/touchscreen/synaptics_s3908.c
	export_patch "lemonades/0004-drm-msm-dsi-skip-link-clk-when-active.patch" \
		drivers/gpu/drm/msm/dsi/dsi_host.c
	export_patch "lemonades/0005-drm-msm-optional-gpu-regulators.patch" \
		drivers/gpu/drm/msm/msm_gpu.c
	export_patch "lemonades/0006-soundwire-qcom-dt-port-override.patch" \
		drivers/soundwire/qcom.c
	export_patch "lemonades/0007-ASoC-qdsp6-ignore-devote-response.patch" \
		sound/soc/qcom/qdsp6/q6afe.c
	export_patch "lemonades/0008-ASoC-lpass-macros-fix-regcache-defaults.patch" \
		sound/soc/codecs/lpass-wsa-macro.c sound/soc/codecs/lpass-rx-macro.c
	export_patch "lemonades/0009-usb-typec-qcom-demote-tx-sig-log.patch" \
		drivers/usb/typec/tcpm/qcom/qcom_pmic_typec_pdphy.c
	export_patch "lemonades/0010-ASoC-codecs-add-tfa987x-amplifier-driver.patch" \
		sound/soc/codecs/Kconfig \
		sound/soc/codecs/Makefile \
		sound/soc/codecs/tfa987x.c
	export_patch "lemonades/0011-arm64-dts-qcom-sm8250-add-q6usbdai-and-fastrpc-cma.patch" \
		arch/arm64/boot/dts/qcom/sm8250.dtsi
	export_patch "lemonades/0012-misc-fastrpc-revert-client-id-regressions.patch" \
		drivers/misc/fastrpc.c
	export_patch "lemonades/0013-drm-msm-dpu-prefer-upper-lms-for-non-dsc.patch" \
		drivers/gpu/drm/msm/disp/dpu1/dpu_rm.c
	export_patch "lemonades/0014-drm-display-hdmi-audio-configure-from-hw_params.patch" \
		drivers/gpu/drm/display/drm_hdmi_audio_helper.c
	export_patch "lemonades/0015-power-supply-add-mps-mp2650-charge-limit-driver.patch" \
		drivers/power/supply/Kconfig \
		drivers/power/supply/Makefile \
		drivers/power/supply/mps_mp2650_charger.c
}

check_tree() {
	local tmp
	tmp=$(mktemp -d)
	trap "rm -rf '$tmp'" EXIT
	verify_upstream
	echo "==> Check: cloning clean upstream into $tmp"
	git clone -q "$LINUX_UP" "$tmp/linux"
	git -C "$tmp/linux" checkout -q "$LINUX_REV"
	apply_series "$tmp/linux"
	echo "==> Check: building Image.gz + sm8250-oneplus-lemonades.dtb"
	local frags=()
	for f in "$ROOT"/configs/linux/*.config; do frags+=("$f"); done
	mkdir -p "$tmp/out"
	make -C "$tmp/linux" O="$tmp/out" ARCH=arm64 CROSS_COMPILE="$CROSS" defconfig
	ARCH=arm64 CROSS_COMPILE="$CROSS" "$tmp/linux/scripts/kconfig/merge_config.sh" \
		-m -O "$tmp/out" "$tmp/out/.config" "${frags[@]}" >/dev/null
	make -C "$tmp/linux" O="$tmp/out" ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig
	make -C "$tmp/linux" O="$tmp/out" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" \
		Image.gz qcom/sm8250-oneplus-lemonades.dtb
	echo "==> Check: validating initramfs + Charge Limit GUI + boot.img v2 + dtbo.img"
	python3 -m py_compile "$ROOT/initramfs/charge-gui/lemonades-charge-gui"
	CROSS_COMPILE="$CROSS" "$ROOT/scripts/mkinitramfs.sh" "$tmp/out/initrd.cpio.gz"
	python3 "$ROOT/scripts/build-bootimg.py" \
		--kernel "$tmp/out/arch/arm64/boot/Image.gz" \
		--ramdisk "$tmp/out/initrd.cpio.gz" \
		--dtb "$tmp/out/arch/arm64/boot/dts/qcom/sm8250-oneplus-lemonades.dtb" \
		--out "$tmp/out/boot.img" \
		--dtbo-out "$tmp/out/dtbo.img"
	echo "==> [PASS] clean series + kernel + DTB + initramfs + boot.img v2 + dtbo.img OK"
}

cmd=${1:-}
case "$cmd" in
	linux)
		if [ "${2:-}" = "--clean" ]; then rm -rf "$WS"; fi
		build_kernel
		;;
	initramfs)
		build_initramfs
		;;
	bootimg)
		build_bootimg
		;;
	export-patches)
		export_patches
		;;
	check)
		check_tree
		;;
	clean)
		rm -rf "$BUILD"
		echo "==> Cleaned $BUILD"
		;;
	*)
		usage
		;;
esac
