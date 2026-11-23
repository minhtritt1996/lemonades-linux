# lemonades-linux

Mainline Linux (`v7.3.5`) + Denial Mobile cho **OnePlus 9R (`lemonades`, Qualcomm SM8250 / Snapdragon 870)**, khởi động trực tiếp qua **XBL → ABL gốc của OnePlus** bằng `boot.img` v2 và `dtbo.img` trống.

## Trạng thái phần cứng & Thành tựu đã kiểm chứng

| Thành phần | Trạng thái | Chi tiết kiểm chứng trên máy thật |
| :--- | :---: | :--- |
| **Khởi động nhanh** | ✅ | **~5.6 – 5.9 giây** tổng thời gian (`~2.0s` kernel/initramfs + `~3.1s` tới `graphical.target`). |
| **Lưu trữ UFS** | ✅ | Clean DTS theo kiến trúc Nura OS 7.2, hết hoàn toàn lỗi sập nguồn khi xả cache nặng — vượt qua **sysbench 20 GB (4 luồng)** ở **`306.01 MiB/s`** + 30s `rndrw`/`fsync`, 0 lỗi `dmesg`. |
| **Màn hình & Cảm ứng** | ✅ | OLED `samsung,amb655x` (`1080x2400 @ 120Hz`, CMD + DSC), cảm ứng `syna,s3908`, GPU **Adreno A650** tăng tốc phần cứng đầy đủ. |
| **Xuất màn hình ngoài (DisplayPort)** | ✅ | Chạy đồng thời **2 màn hình** (`1080x2400 @ 120Hz` + `1920x1080 @ 100Hz`) qua hub USB-C mà không bị nhiễu/lag kể cả khi tắt/bật màn điện thoại (patch `dpu_rm` giữ `LM_0/1` cho `DSI-1`). |
| **USB 3.0 / OTG / Hub** | ✅ | SuperSpeed **5 Gbps** đồng thời với DisplayPort (`Pin Assignment D`); test đọc SSD NVMe qua hub UGREEN đạt **`257 MB/s`**. |
| **Mạng LAN Gigabit (USB-C Hub)** | ✅ | Built-in `USBNET`, `AX88179A`, `RTL8152/8153`, `CDC-NCM`, `CDC-ECM`; nhận **`1000 Mbps`** full Gigabit. |
| **Sạc nhanh USB-PD** | ✅ | Đàm phán **USB-PD 9V / 3A** (`18W` operational, `9.0V` qua hub PD), đọc pin qua `ti,bq27541`. |
| **Loa ngoài Stereo** | ✅ | 2× ampli **NXP `tfa9874`** (`15-0034` & `15-0035`) qua `TERT_MI2S_RX`, đã bật bộ **DC-DC Boost** (`SYS_CTRL0[4]`), tự cấu hình ALSA UCM2 + WirePlumber (`S16LE`, `RW_INTERLEAVED`) từ `boot.img`. |
| **Âm thanh HDMI / DisplayPort** | ✅ | Hoạt động qua `DISPLAY_PORT_RX` (cấu hình DP audio trong `hw_params` trước `q6afe` port `0x6020`), hiện song song cùng Loa ngoài trong **Settings → Sound**. |
| **Wi-Fi 6 & Bluetooth** | ✅ | Qualcomm **QCA6390** (`ath11k_pci` + `hci_uart_qca`), rebind Bluetooth chạy nền không làm chậm boot. |
| **Containers & Ảo hóa (Incus)** | ✅ | Tích hợp sẵn toàn bộ Kconfig built-in cho **Incus** (`BRIDGE`, `BTRFS`, `OVERLAY`, `SQUASHFS`, `DM_THIN_PROVISIONING`, `VHOST/VSOCK`, `MACVLAN/IPVLAN/VXLAN`, `NFT_FIB`, `CHECKPOINT_RESTORE`). |
| **SLPI / Cảm biến** | 🟡 | SLPI boot sạch không còn crash (nhờ `fastrpc_mem` CMA + revert `fastrpc`), `hexagonrpcd` đọc/ghi xong registry; cảm biến vật lý qua `ssccli` vẫn đang tiếp tục điều tra. |

## Cấu trúc repository

```text
build.sh                    Script build kernel, initramfs, boot.img v2, export-patches & check
configs/linux/              Fragment Kconfig (base.config + lemonades.config)
initramfs/                  Early init (PID 1): mount firmware, USB gadget, tự cấu hình SSH/UCM2/WirePlumber
patches/linux/series        Thứ tự áp dụng 14 patch lên upstream/linux (v7.3.5)
patches/linux/lemonades/    Các patch kernel cho OnePlus 9R (DTS, panel, touch, TFA9874, DPU, DP audio, FastRPC)
scripts/                    Công cụ đóng gói boot.img v2 + dtbo.img trống, mkinitramfs, flash A/B an toàn
upstream/                   Clone read-only Linux v7.3.5 (không commit vào git)
build/                      Thư mục build cô lập và đầu ra build/out/{boot.img,dtbo.img}
```

## Tự cấu hình từ `boot.img`

`initramfs/init.c` tự động đảm bảo các cấu hình thiết yếu trên `/newroot` trước khi `switch_root`, giúp máy chạy ngay sau khi flash lại `userdata` mới mà không cần chỉnh tay:
- ALSA UCM2 cho `SM8250-OnePlus-9R` (gồm cả **Stereo Speakers** và **DisplayPort / HDMI Output**).
- WirePlumber rule `51-lemonades-audio.conf` (`S16LE`, `48000 Hz`, `period-size = 1024`, `disable-mmap = true`).
- `sshd` drop-in (`ListenAddress 0.0.0.0`, sao lưu/khôi phục `authorized_keys`) và `subuid`/`subgid` cho Droidloom/containers.
- USB gadget `ACM + NCM` (`172.16.42.1/24` + rescue console `/dev/ttyACM0`).

## Build từ mã nguồn

```bash
# 1. Chuẩn bị cây upstream read-only (chỉ làm 1 lần)
git clone --branch v7.3.5 --depth 1 \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git upstream/linux

# 2. Build kernel, initramfs và đóng gói boot.img v2 + dtbo.img trống
./build.sh linux
./build.sh initramfs
./build.sh bootimg

# 3. Kiểm chứng sạch (apply toàn bộ series lên cây sạch + build Image.gz & DTB)
./build.sh check
```

Đầu ra nằm tại `build/out/boot.img` và `build/out/dtbo.img`.

## Hướng dẫn Flash

Tải `boot.img` và `dtbo.img` từ trang [Releases](https://github.com/minhtritt1996/lemonades-linux/releases) (hoặc tự build ở trên):

```bash
# Thử nghiệm an toàn trên RAM (không ghi UFS)
fastboot boot boot.img

# Flash cố định vào cả 2 slot A/B
fastboot flash boot_a boot.img
fastboot flash boot_b boot.img
fastboot flash dtbo_a dtbo.img
fastboot flash dtbo_b dtbo.img
```

> **Cảnh báo A/B**: Không dùng `qbootctl -s <slot>` để chuyển slot vì bug đảo ngược TypeGUID trên LUN 4 của `linux-msm/qbootctl` có thể khiến ABL không khởi động được. Luôn chuyển slot bằng `fastboot --set-active=<a|b>`.
