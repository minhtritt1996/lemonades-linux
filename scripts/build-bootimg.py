#!/usr/bin/env python3
"""Pack Android boot.img (header_version=2) and empty dtbo.img for OnePlus 9R (lemonades)."""

import argparse
import os
import shutil
import struct
import subprocess
import sys


DEFAULT_CMDLINE = (
    "ufshcd_core.use_mcq_mode=N "
    "console=tty0 "
    "fbcon=font:TER16x32 "
    "clk_ignore_unused "
    "pd_ignore_unused "
    "modprobe.blacklist=mhi_pci_generic "
    "swiotlb=2048 "
    # Droidloom's Android userspace logs through /dev/kmsg; keep the boot-time
    # driver log in the ring buffer instead of evicting it.
    "log_buf_len=8M"
)


def write_empty_dtbo(path: str) -> None:
    """Create a valid 1-entry empty Android DTBO image using dtc + mkdtboimg."""
    import tempfile

    dtc = shutil.which("dtc")
    mkdtboimg = shutil.which("mkdtboimg")
    if not dtc or not mkdtboimg:
        raise RuntimeError("dtc and mkdtboimg are required to build empty dtbo.img")

    with tempfile.TemporaryDirectory() as td:
        dts = os.path.join(td, "empty.dts")
        dtb = os.path.join(td, "empty.dtb")
        with open(dts, "w") as f:
            f.write(
                "/dts-v1/;\n"
                "/ {\n"
                "\tqcom,msm-id = <0x164 0x10000 0x164 0x20001>;\n"
                "\tqcom,board-id = <0x08 0x00 0x00 0x00>;\n"
                "};\n"
            )
        subprocess.run([dtc, "-I", "dts", "-O", "dtb", "-o", dtb, dts], check=True)
        subprocess.run(
            [
                mkdtboimg, "create", path,
                "--page_size=4096",
                "--id=0x164",
                "--rev=0x20001",
                dtb,
            ],
            check=True,
        )


def main() -> int:
    ap = argparse.ArgumentParser(description="Build OnePlus 9R boot.img v2 + empty dtbo.img")
    ap.add_argument("--kernel", required=True, help="Path to Image.gz (or Image)")
    ap.add_argument("--ramdisk", required=True, help="Path to initrd.cpio.gz")
    ap.add_argument("--dtb", required=True, help="Path to sm8250-oneplus-lemonades.dtb")
    ap.add_argument("--out", required=True, help="Output boot.img path")
    ap.add_argument("--dtbo-out", required=True, help="Output empty dtbo.img path")
    ap.add_argument("--cmdline", default=DEFAULT_CMDLINE, help="Kernel cmdline")
    args = ap.parse_args()

    mkbootimg = shutil.which("mkbootimg")
    if not mkbootimg:
        print("ERROR: mkbootimg not found in PATH", file=sys.stderr)
        return 1

    for p in (args.kernel, args.ramdisk, args.dtb):
        if not os.path.isfile(p):
            print(f"ERROR: missing input file: {p}", file=sys.stderr)
            return 1

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(args.dtbo_out)), exist_ok=True)

    cmd = [
        mkbootimg,
        "--header_version", "2",
        "--pagesize", "4096",
        "--base", "0x00000000",
        "--kernel_offset", "0x00008000",
        "--ramdisk_offset", "0x01000000",
        "--second_offset", "0x00000000",
        "--tags_offset", "0x00000100",
        "--dtb_offset", "0x01f00000",
        "--os_version", "13.0.0",
        "--os_patch_level", "2023-04",
        "--kernel", args.kernel,
        "--ramdisk", args.ramdisk,
        "--dtb", args.dtb,
        "--cmdline", args.cmdline,
        "-o", args.out,
    ]
    subprocess.run(cmd, check=True)
    write_empty_dtbo(args.dtbo_out)

    print(f"    [OK] {args.out} ({os.path.getsize(args.out)} bytes)")
    print(f"    [OK] {args.dtbo_out} ({os.path.getsize(args.dtbo_out)} bytes, empty DTBO)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
