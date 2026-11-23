# lemonades-linux

Mainline Linux (`v7.3.5`) + Denial Mobile cho **OnePlus 9R (`lemonades`, Qualcomm SM8250 / Snapdragon 870)**, khởi động trực tiếp qua chuỗi **XBL -> ABL gốc của OnePlus** bằng `boot.img` v2 và `dtbo.img` trống.

[Phần cứng](#trạng-thái-phần-cứng) · [Cơ chế tự cấu hình](#cơ-chế-tự-cấu-hình-zero-touch-provisioning) · [Build](#build-từ-mã-nguồn) · [Flash A/B](#cài-đặt--cập-nhật-an-toàn-ab) · [Cấu trúc](#cấu-trúc-repository) · [Donate](#ủng-hộ-dự-án-donate)

---

## Trạng thái phần cứng

Tất cả hạng mục đánh dấu ✅ đã được kiểm chứng trực tiếp trên máy thật OnePlus 9R:

| Thành phần | Trạng thái | Chi tiết kiểm chứng |
| :--- | :---: | :--- |
| **Khởi động nhanh** | ✅ | Tổng thời gian **~5.6–5.9 giây** (`~2.0s` kernel/initramfs + `~3.1s` tới `graphical.target`). |
| **Lưu trữ UFS** | ✅ | DTS theo kiến trúc Nura OS 7.2, vượt qua **sysbench 20 GB (4 luồng)** ở **`306.01 MiB/s`** + 30s `rndrw`/`fsync`, 0 lỗi `dmesg`. |
| **Màn hình & Cảm ứng** | ✅ | OLED `samsung,amb655x` (`1080x2400 @ 120Hz`, CMD + DSC), cảm ứng `syna,s3908`, GPU **Adreno A650** tăng tốc phần cứng. |
| **Xuất màn hình ngoài (DP)** | ✅ | Xuất đồng thời **2 màn hình** (`1080x2400 @ 120Hz` + `1920x1080 @ 100Hz`) qua hub USB-C, không nhiễu khi tắt/bật màn điện thoại. |
| **USB 3.0 / OTG / Hub** | ✅ | SuperSpeed **5 Gbps** đồng thời DisplayPort (`Pin Assignment D`); đọc SSD NVMe qua hub đạt **`257 MB/s`**. |
| **Mạng LAN Gigabit** | ✅ | Built-in `USBNET`, `AX88179A`, `RTL8152/8153`, `CDC-NCM`, `CDC-ECM`; đạt **`1000 Mbps`** qua hub USB-C. |
| **Sạc nhanh USB-PD** | ✅ | Đàm phán **USB-PD 9V / 3A** (`18W` operational, `9.0V` qua hub PD), giám sát pin 2S qua `ti,bq27541`. |
| **Charge Limit & Bypass** | ✅ | Driver **MPS MP2650** (`i2c5 @ 0x5c`, `REG08 BIT(4)` `CHG_EN`) + app **Charge Limit**: ngắt dòng sạc về **`0.0 mA`** (`0 uA`, áp nghỉ `8.45V`) và nuôi máy trực tiếp từ USB-PD qua NVDC khi cắm dock 24/7. |
| **Bảo vệ quá nhiệt** | ✅ | 29 vùng cảm biến TSENS/PMIC (`step_wise` + `cpufreq`/`devfreq`): hạ xung CPU ở `90°C/95°C`, GPU ở `85°C`; tự động shutdown ở `110°C` (SoC) và `145°C` (PMIC + ngắt nguồn phần cứng). |
| **Loa ngoài Stereo** | ✅ | 2× ampli **NXP `tfa9874`** (`15-0034`, `15-0035`) qua `TERT_MI2S_RX` với **DC-DC Boost** (`SYS_CTRL0[4]`), tự cấu hình ALSA UCM2 + WirePlumber. |
| **Âm thanh HDMI / DP** | ✅ | Xuất âm thanh qua `DISPLAY_PORT_RX` (`q6afe` port `0x6020`), hoạt động song song cùng loa ngoài. |
| **Wi-Fi 6 & Bluetooth** | ✅ | Qualcomm **QCA6390** (`ath11k_pci` + `hci_uart_qca` rebind nền không làm chậm quá trình boot). |
| **Containers & Ảo hóa** | ✅ | Built-in đầy đủ Kconfig cho **Incus** / **Droidspaces** (`BRIDGE`, `BTRFS`, `OVERLAY`, `SQUASHFS`, `DM_THIN_PROVISIONING`, `VHOST/VSOCK`, `MACVLAN/IPVLAN/VXLAN`, `NFT_FIB`, `CHECKPOINT_RESTORE`). |
| **Cập nhật A/B từ xa** | ✅ | Đã vá bug đảo TypeGUID trên LUN 4 trong `qbootctl` ([patch](patches/qbootctl/0001-sm8250-fix-slot-guid-swap-and-ptn-list.patch)); kiểm chứng chuyển slot `_a` → `_b` từ xa qua SSH + `slot-success` tự xác nhận. |
| **SLPI / Cảm biến** | 🟡 | SLPI boot sạch không crash (`fastrpc_mem` CMA + revert `fastrpc`), `hexagonrpcd` đọc/ghi xong registry; cảm biến vật lý qua `ssccli` đang tiếp tục hoàn thiện. |

---

## Cơ chế tự cấu hình (Zero-Touch Provisioning)

`initramfs/init.c` (PID 1) tự động đồng bộ các cấu hình đặc thù của OnePlus 9R vào `/newroot` trước khi `switch_root`, giúp một tệp `boot.img` duy nhất hoạt động ngay cả khi flash lại phân vùng `userdata` trắng:

- **Quản lý sạc & Bypass 24/7:** Tự cài `/usr/local/bin/lemonades-charge-gui`, biểu tượng ứng dụng **Charge Limit**, quy tắc udev (`0660 root:wheel` trên sysfs `mp2650-charger`) và dịch vụ `lemonades-charge-limit.service` khôi phục ngưỡng sạc tại `/etc/lemonades/charge-limit/charge-limit.conf`.
- **Âm thanh Out-of-the-Box:** Tự ghi profile ALSA UCM2 cho `SM8250-OnePlus-9R` (**Stereo Speakers** + **DisplayPort / HDMI Output**) và cấu hình WirePlumber (`S16LE`, `48000 Hz`, `period-size = 1024`, `disable-mmap = true`).
- **Truy cập từ xa & Cứu hộ:** Mở USB gadget **CDC-NCM (`172.16.42.1/24`) + CDC-ACM (`/dev/ttyGS0`)**, chuẩn hóa `subuid`/`subgid` cho container, cấu hình `sshd` chỉ nhận SSH key (`PermitRootLogin prohibit-password`, `PasswordAuthentication no`) và tự sao lưu/khôi phục `authorized_keys` tại `/etc/lemonades/ssh/authorized_keys` (`0700`/`0600`).

---

## Build từ mã nguồn

### Yêu cầu công cụ
- **Cross-compiler ARM64:** `aarch64-linux-gnu-gcc` (hoặc truyền biến `CROSS_COMPILE=...`)
- **Build kernel:** `make`, `bc`, `bison`, `flex`, `perl`, `openssl`/`libssl-dev`, `libelf-dev`, `gzip`, `git`
- **Đóng gói & kiểm chứng:** `python3`, `cpio`, `dtc` (`device-tree-compiler`), `mkbootimg`, `mkdtboimg`

### Các bước thực hiện

```bash
# 1. Clone cây Linux upstream read-only đúng tag/commit trong patches/linux/UPSTREAM (chỉ làm 1 lần)
git clone --branch v7.3.5 --depth 1 \
  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git upstream/linux

# 2. Build kernel, initramfs và đóng gói boot.img v2 + dtbo.img trống
./build.sh linux
./build.sh initramfs
./build.sh bootimg

# 3. Kiểm chứng toàn trình trên cây sạch (15 patch + Image.gz + DTB + initramfs + boot.img v2 + dtbo.img)
./build.sh check
```

Ảnh đầu ra được xuất tại `build/out/boot.img` và `build/out/dtbo.img` (có thể dùng lệnh rút gọn `make build` hoặc `make check`).

---

## Cài đặt & Cập nhật an toàn (A/B)

Tải sẵn `boot.img` và `dtbo.img` tại trang [Releases](https://github.com/minhtritt1996/lemonades-linux/releases) hoặc tự build theo hướng dẫn trên.

### 1. Khởi động thử nghiệm không ghi vào UFS
```bash
fastboot boot boot.img
```

### 2. Chuyển từ Android sang Linux lần đầu
ABL của OnePlus sẽ ghép overlay vendor từ `dtbo_<slot>` lên DTB mainline nếu phân vùng `dtbo` chưa được làm sạch. Chỉ cần flash `dtbo.img` trống (218 byte, hoặc phân vùng toàn `0x00`) **một lần** cho slot đích:

```bash
# Ví dụ đang chạy slot _a thì flash sang slot _b dự phòng
fastboot flash dtbo_b dtbo.img
fastboot flash boot_b boot.img
fastboot --set-active=b
fastboot reboot
```

### 3. Cập nhật kernel qua SSH giữ nguyên slot dự phòng
Sử dụng [scripts/flash-boot-ab.sh](scripts/flash-boot-ab.sh) để ghi vào slot **không đang chạy**, tự đối chiếu SHA-256 readback và kiểm tra `dtbo_<inactive>` sạch:

```bash
# Kiểm tra kế hoạch trước (dry-run, mặc định qua USB gadget root@172.16.42.1)
./scripts/flash-boot-ab.sh

# Ghi ảnh vào slot không active (có thể truyền root@<ip> qua LAN/Tailscale)
./scripts/flash-boot-ab.sh --yes build/out/boot.img root@172.16.42.1

# Chuyển slot:
# - Cách chuẩn (mọi máy): reboot vào bootloader và chạy fastboot --set-active=<a|b> && fastboot reboot
# - Từ xa qua SSH (CHỈ khi máy đã cài qbootctl đã vá): qbootctl -s <0|1> && reboot
```

> **Lưu ý quan trọng về A/B:** Tuyệt đối **không chạy `qbootctl -s <slot>` bản gốc upstream** vì bug đảo ngược TypeGUID trên LUN 4 của `linux-msm/qbootctl` (`bootctrl_impl.c:551-558`) khiến ABL báo `Failed to load/authenticate boot image: Device Error`. Chỉ chuyển slot từ xa bằng `qbootctl -s <0|1>` khi máy đã cài bản vá [patches/qbootctl/0001-sm8250-fix-slot-guid-swap-and-ptn-list.patch](patches/qbootctl/0001-sm8250-fix-slot-guid-swap-and-ptn-list.patch) (nếu chưa, luôn đổi slot bằng `fastboot --set-active=<a|b>`). Dịch vụ `slot-success.service` sẽ tự đánh dấu slot thành công sau khi `denial.service` và `sshd.service` ổn định 60 giây.

---

## Cấu trúc repository

```text
build.sh                    Script điều phối build kernel, initramfs, boot.img v2, export-patches và check
Makefile                    Wrapper gọi nhanh các lệnh build.sh
configs/linux/              Fragment Kconfig (base.config + lemonades.config)
initramfs/                  Early init (PID 1) và ứng dụng GUI Charge Limit
patches/linux/series        Thứ tự áp dụng 15 patch lên upstream/linux (v7.3.5)
patches/linux/lemonades/    Các patch kernel cho OnePlus 9R (DTS, panel, touch, TFA9874, DPU, DP audio, FastRPC, MP2650)
patches/qbootctl/           Bản vá SM8250 cho linux-msm/qbootctl (chuyển slot A/B từ xa qua SSH)
scripts/                    Công cụ đóng gói boot.img v2 + dtbo.img trống, mkinitramfs và flash A/B an toàn
upstream/                   Clone read-only Linux v7.3.5 (không theo dõi trong git)
build/                      Thư mục build cô lập và đầu ra build/out/{boot.img,dtbo.img}
```

---

## Ủng hộ dự án (Donate)

Nếu dự án giúp ích cho việc chạy Linux mainline hoặc biến OnePlus 9R thành máy chủ mini 24/7, bạn có thể ủng hộ quá trình phát triển và thử nghiệm phần cứng qua địa chỉ ví EVM duy nhất bên dưới:

```text
0xc604a10270d5e37fa36676f2dec54383399b7e51
```

| Mạng lưới hỗ trợ (EVM) | Token gợi ý |
| :--- | :--- |
| **Ethereum / Arbitrum / Optimism / Base** | ETH, USDT, USDC |
| **BNB Smart Chain (BSC)** | BNB, USDT, USDC |
| **Polygon** | POL (MATIC), USDT, USDC |

*(Vui lòng kiểm tra đúng mạng lưới tương thích EVM trước khi gửi.)*
