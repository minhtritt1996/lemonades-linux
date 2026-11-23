# TODO — lemonades-linux (OnePlus 9R / SM8250)

## Đã hoàn thành & kiểm chứng trên máy thật
- [x] **Cây build & đóng gói**: Cấu trúc patch-first (`upstream/` read-only + 15 patch trong `patches/linux/lemonades/`), `./build.sh check` kiểm chứng toàn trình từ upstream sạch tới `boot.img` v2 + `dtbo.img` trống.
- [x] **UFS ổn định dưới tải nặng**: Clean DTS (`lanes-per-direction = <2>`, `ldo6`/`ldo17` `regulator-allow-set-load`), vượt qua sysbench 20 GB (4 luồng, `306.01 MiB/s`) + 30s `rndrw`/`fsync`, 0 lỗi `dmesg`.
- [x] **Display & Touch (Dual Display)**: `samsung,amb655x` (`1080x2400 @ 120Hz` DSC) + `syna,s3908` + Adreno A650 + DisplayPort `1080p @ 100Hz` chạy đồng thời (`dpu_rm` ưu tiên `LM_2/3` cho non-DSC, giữ `LM_0/1` cho `DSI-1`).
- [x] **Audio (Stereo Speakers + HDMI/DP Audio)**: 2× **NXP `tfa9874`** (`15-0034`, `15-0035`) qua `TERT_MI2S_RX` (đã sửa lỗi `DCDC_CTRL6` bật DC-DC boost + `GENMASK(7, 4)`) + `DISPLAY_PORT_RX` audio (`hw_params` hook), tự cài ALSA UCM2 + WirePlumber (`S16LE`, `disable-mmap = true`) từ `initramfs`.
- [x] **USB 3.0 5 Gbps + Gigabit LAN + USB-PD 9V/3A**: SuperSpeed 5 Gbps đồng thời DisplayPort, `AX88179A`/`RTL8152` built-in đạt 1000 Mbps, NVMe qua hub 257 MB/s, PD 9V/3A.
- [x] **Charge Limit & Battery Bypass (24/7)**: Driver **MPS MP2650** (`i2c5 @ 0x5c`, `REG08 BIT(4)` `CHG_EN`) + app GUI **Charge Limit** cài sẵn từ `boot.img` — đã kiểm chứng dòng pin về **`0.0 mA`** khi chạy trực tiếp từ nguồn USB-PD 9V.
- [x] **Wi-Fi 6 / Bluetooth / Fast Boot**: `ath11k_pci` (`QCA6390`) + `hci_uart_qca` rebind nền, tổng thời gian boot **~5.6–5.9s**.
- [x] **Droidloom + Incus + Security**: Built-in Kconfig cho Droidloom & Incus, `subuid`/`subgid` tự chuẩn hoá, SSH key-only (`PermitRootLogin prohibit-password`, `PasswordAuthentication no`), A/B deploy an toàn qua `scripts/flash-boot-ab.sh`.
- [x] **Chuyển slot A/B từ xa qua SSH (`qbootctl` đã vá)**: Vá lỗi đảo TypeGUID trong `linux-msm/qbootctl` (`bootctrl_impl.c:551-558`) + bổ sung đủ 25 phân vùng A/B trên LUN 4 (`patches/qbootctl/0001-sm8250-fix-slot-guid-swap-and-ptn-list.patch`); đã kiểm chứng chuyển `_a` → `_b` hoàn toàn qua SSH (`qbootctl -s 1 && reboot`, không cần `fastboot`) và `slot-success.service` tự đánh dấu `SLOT _b: Active=1, Successful=1` trong khi giữ `SLOT _a: Successful=1` để rollback.

## Các hạng mục còn lại
- [ ] **SLPI / Cảm biến vật lý**: SLPI đã boot sạch và `hexagonrpcd` đọc/ghi xong registry, nhưng `ssccli` chưa thấy accel/gyro — cần tiếp tục đối chiếu cấu hình sensor registry / QMI SSC.
- [ ] **GNSS / Location**: Tích hợp QMI LOC (`picasso-gnss`) + cầu nối `org.dmail.Location1`.
- [ ] **Haptics / Camera / Flash**: Driver rung I2C `aw8697` (`i2c11 @ 0x5a`, reset GPIO 35), camera sensors (CAMSS / libcamera) và flash LED `pm8150l`.
- [ ] **Residual đã biết (không ảnh hưởng sử dụng)**: 10 dòng SMMU context fault một lần lúc bàn giao splash framebuffer từ ABL sang DPU; MHI/SDX55 modem chưa có firmware mainline.

## Ngoài phạm vi (máy chủ 24/7)
- **Suspend / Resume (`s2idle`)**: Không thuộc mục tiêu vận hành máy chủ cắm nguồn PD 24/7 (chỉ xem xét nếu sau này chuyển sang dùng cầm tay chạy pin).
