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
| **Sạc nhanh USB-PD** | ✅ | Đàm phán **USB-PD 9V / 3A** (`18W` operational, `9.0V` qua hub PD), đọc pin 2S qua `ti,bq27541`. |
| **Giới hạn sạc & Battery Bypass (24/7)** | ✅ | Driver **MPS MP2650** (`i2c5 @ 0x5c`, `REG08 BIT(4)` `CHG_EN`) + app GUI **Charge Limit** cài sẵn từ `boot.img`: khi đạt ngưỡng (mặc định `75%–80%` hoặc bật Bypass thủ công), dòng vào pin tụt về **`0.0 mA`** (`0 uA`, áp nghỉ `8.45V`) trong khi máy chạy trực tiếp từ **USB-PD 9V** qua NVDC — chống phồng pin khi cắm dock 24/24. |
| **Loa ngoài Stereo** | ✅ | 2× ampli **NXP `tfa9874`** (`15-0034` & `15-0035`) qua `TERT_MI2S_RX`, đã bật bộ **DC-DC Boost** (`SYS_CTRL0[4]`), tự cấu hình ALSA UCM2 + WirePlumber (`S16LE`, `RW_INTERLEAVED`) từ `boot.img`. |
| **Âm thanh HDMI / DisplayPort** | ✅ | Hoạt động qua `DISPLAY_PORT_RX` (cấu hình DP audio trong `hw_params` trước `q6afe` port `0x6020`), hiện song song cùng Loa ngoài trong **Settings → Sound**. |
| **Wi-Fi 6 & Bluetooth** | ✅ | Qualcomm **QCA6390** (`ath11k_pci` + `hci_uart_qca`), rebind Bluetooth chạy nền không làm chậm boot. |
| **Containers & Ảo hóa (Incus)** | ✅ | Tích hợp sẵn toàn bộ Kconfig built-in cho **Incus** (`BRIDGE`, `BTRFS`, `OVERLAY`, `SQUASHFS`, `DM_THIN_PROVISIONING`, `VHOST/VSOCK`, `MACVLAN/IPVLAN/VXLAN`, `NFT_FIB`, `CHECKPOINT_RESTORE`). |
| **SLPI / Cảm biến** | 🟡 | SLPI boot sạch không còn crash (nhờ `fastrpc_mem` CMA + revert `fastrpc`), `hexagonrpcd` đọc/ghi xong registry; cảm biến vật lý qua `ssccli` vẫn đang tiếp tục điều tra. |

## Cấu trúc repository

```text
build.sh                    Script build kernel, initramfs, boot.img v2, export-patches & check toàn trình
configs/linux/              Fragment Kconfig (base.config + lemonades.config)
initramfs/                  Early init (PID 1) + app GUI Charge Limit (self-contained provisioning)
patches/linux/series        Thứ tự áp dụng 15 patch lên upstream/linux (v7.3.5)
patches/linux/lemonades/    Các patch kernel cho OnePlus 9R (DTS, panel, touch, TFA9874, DPU, DP audio, FastRPC, MP2650)
scripts/                    Công cụ đóng gói/kiểm chứng boot.img v2 + dtbo.img trống, mkinitramfs, flash A/B an toàn
upstream/                   Clone read-only Linux v7.3.5 (không commit vào git)
build/                      Thư mục build cô lập và đầu ra build/out/{boot.img,dtbo.img}
```

## Thiết kế `boot.img` tự đủ (Zero-Touch Provisioning)

Dự án cố ý để `initramfs/init.c` tự đảm bảo các cấu hình phần cứng đặc thù của OnePlus 9R trên `/newroot` trước khi `switch_root` để 1 file `boot.img` hoạt động ngay cả khi flash lại `userdata` trắng:
- **Charge Limit & Battery Bypass**: tự cài `/usr/local/bin/lemonades-charge-gui`, shortcut **Charge Limit**, udev rule (`0666` trên `/sys/class/power_supply/mp2650-charger/charge_*`), và `lemonades-charge-limit.service` (tự khôi phục ngưỡng đã lưu sau mỗi lần reboot).
- **Audio**: ALSA UCM2 cho `SM8250-OnePlus-9R` (**Stereo Speakers** + **DisplayPort / HDMI Output**) và WirePlumber `51-lemonades-audio.conf` (`S16LE`, `48000 Hz`, `period-size = 1024`, `disable-mmap = true`).
- **Truy cập từ xa & Containers**: `sshd` drop-in **chỉ chấp nhận SSH key** (`PermitRootLogin prohibit-password`, `PasswordAuthentication no`), sao lưu/khôi phục `authorized_keys`, chuẩn hoá `subuid`/`subgid` và USB gadget `ACM + NCM` (`172.16.42.1/24` + rescue console `/dev/ttyACM0`).

## Build từ mã nguồn

### Yêu cầu công cụ (Debian / Ubuntu / Arch)
- Cross-compiler ARM64: `aarch64-linux-gnu-gcc` (hoặc truyền `CROSS_COMPILE=...`)
- Build kernel: `make`, `bc`, `bison`, `flex`, `perl`, `openssl`/`libssl-dev`, `libelf-dev`, `gzip`, `git`
- Đóng gói & kiểm chứng: `python3`, `cpio`, `dtc` (`device-tree-compiler`), `mkbootimg`, `mkdtboimg`

```bash
# 1. Chuẩn bị cây upstream read-only (chỉ làm 1 lần)
git clone --branch v7.3.5 --depth 1 \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git upstream/linux

# 2. Build kernel, initramfs và đóng gói boot.img v2 + dtbo.img trống
./build.sh linux
./build.sh initramfs
./build.sh bootimg

# 3. Kiểm chứng toàn trình trên cây sạch (15 patch + Image.gz + DTB + initramfs + boot.img v2 + dtbo.img)
./build.sh check
```

Đầu ra nằm tại `build/out/boot.img` và `build/out/dtbo.img`.

## Hướng dẫn Flash an toàn (A/B)

Tải `boot.img` và `dtbo.img` từ trang [Releases](https://github.com/minhtritt1996/lemonades-linux/releases) (hoặc tự build ở trên).

### 1. Thử nghiệm không ghi UFS (khuyên dùng trước tiên)
```bash
fastboot boot boot.img
```

### 2. Chuyển từ Android sang Linux lần đầu (xoá overlay vendor trong `dtbo`)
ABL của OnePlus sẽ ghép `dtbo_<slot>` của Android lên DTB mainline nếu phân vùng `dtbo` còn overlay cũ. Chỉ cần flash `dtbo.img` trống (1-entry empty DTBO hợp lệ, 218 byte — hoặc phân vùng `dtbo` toàn `0x00`) **một lần** cho slot bạn dùng:
```bash
# Xác định slot không đang chạy (ví dụ đang ở _a thì flash vào _b)
fastboot flash dtbo_b dtbo.img
fastboot flash boot_b boot.img
fastboot --set-active=b
fastboot reboot
```

### 3. Cập nhật kernel qua SSH mà vẫn giữ nguyên slot dự phòng (rollback A/B)
Dùng script [scripts/flash-boot-ab.sh](scripts/flash-boot-ab.sh) — **không bao giờ ghi đè slot đang chạy**, tự kiểm tra SHA-256 readback và xác nhận `dtbo_<inactive>` sạch:
```bash
# Xem trước kế hoạch (dry-run, mặc định kết nối USB gadget root@172.16.42.1)
./scripts/flash-boot-ab.sh

# Ghi vào slot không hoạt động (truyền root@<ip> nếu dùng LAN/Tailscale)
./scripts/flash-boot-ab.sh --yes build/out/boot.img root@172.16.42.1

# Sau đó reboot vào bootloader và chuyển slot bằng fastboot:
fastboot --set-active=<a|b>
fastboot reboot
```

> **Cảnh báo A/B**: **Không chạy `qbootctl -s <slot>`** để chuyển slot vì bug đảo ngược TypeGUID trên LUN 4 của `linux-msm/qbootctl` có thể khiến ABL báo `Failed to load/authenticate boot image: Device Error`. Luôn chuyển slot bằng `fastboot --set-active=<a|b>`; `slot-success.service` sẽ tự đánh dấu slot thành công sau khi `denial.service` + `sshd.service` chạy ổn định 60 giây.
