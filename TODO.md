# TODO — lemonades-linux (OnePlus 9R / SM8250)

## Phase 1: Khởi tạo cây build & Fix lỗi sập nguồn UFS
- [x] Tạo cấu trúc repo chuẩn (học theo `picasso-linux`: `patches/`, `configs/`, `scripts/`, `initramfs/`), đóng gói `boot.img` v2 (`header_version=2`, `pagesize=4096`) + `dtbo.img` trống.
- [x] Thêm `ramoops` (`ramoops@b0000000`) vào `reserved-memory` trong DTS để bắt log `pstore` khi crash/sập nguồn.
- [x] Sửa UFS (`lanes-per-direction = <0x02>;`) và regulators trong DTS (`ldo6`, `ldo17` `regulator-allow-set-load;`, `ldo17` min `2856000 uV`).

## Phase 2: Boot Denial Mobile trên layout A/B + `super`
- [x] Kiểm tra bảng phân vùng UFS thực tế của `lemonades` (`_a`/`_b`, `sda1..sda24`, `userdata` = `/dev/sda24`, `modem_a` = `/dev/sde4`, `bluetooth_a` = `/dev/sde5`, `dsp_a` = `/dev/sde9`).
- [x] Viết/mở rộng `initramfs` (`init.c`) để nhận diện slot `_a`/`_b` đang active từ cmdline (`androidboot.slot_suffix=`), mount firmware vào `/lib/firmware`, và `switch_root` sang `/dev/sda24` chứa Denial Mobile (`systemd` PID 1).
- [x] Cấu hình USB gadget (`usb0` NCM `172.16.42.1/24` + `ttyGS0` ACM console kèm lệnh `sh <cmd>` & `bootloader`) để debug sớm.

## Phase 3: Bring-up phần cứng cho Denial Mobile
- [x] **Display & Touch**: Tích hợp `panel-samsung-amb655x.c` (OLED 1080x2400 120Hz/60Hz DSC + backlight `ae94000.dsi.0`) + `synaptics_s3908.c` (`Synaptics TCM Oncell Touchscreen` `/dev/input/event2`), sửa đúng `reset-gpios` (GPIO 75 cho panel, GPIO 38 cho touch), lên Homescreen Denial Mobile + cảm ứng hoạt động.
- [x] **Audio**: Soundcard `0 [SM8250OnePlus9R]: sm8250 - SM8250-OnePlus-9R` (`MultiMedia1..3`, `wcd938x`, 2 loa stereo SoundWire `wsa881x` `SpkrLeft`/`SpkrRight`, `Headset Jack`, `DP0 Jack` DisplayPort Audio); tiếp theo cấu hình UCM2 / WirePlumber DSP nếu cần tinh chỉnh routing.
- [x] **Power / Battery / Charging**: Đọc pin `bq27541-0` (`ti,bq27541`) và Type-C PD `pm8150b-typec` hoạt động; tiếp theo kiểm tra sạc nhanh Warp Charge 65W / ngưỡng ngắt sạc.
- [x] **Wi-Fi / Bluetooth**: `ath11k_pci` (`qca6390 hw2.0` -> `wlp1s0` / `phy0`) + Bluetooth (`qca/htbtfw20.tlv` & `qca/htnv20.bin` -> `hci0`) hoạt động qua read-only `overlayfs` firmware + `CONFIG_INPUT_UINPUT=y`.
- [ ] **GNSS / Location**: Dùng `picasso-gnss` (QMI LOC) + cầu nối `org.dmail.Location1` cho Droidloom.
- [ ] **Haptics / Camera / Flash**: Tìm IC rung I2C của 9R (`aw8697`), profile `braun` cho camera sensors, flash LED `pm8150l`.
- [ ] **Sleep (`s2idle`)**: Kiểm tra `hexagonrpcd` (`systemd-sleep` hook) và các wakeup IRQs khi ngủ sâu.

## Phase 4: Droidloom Android cell + dọn dẹp dmesg
- [x] **Kernel cho Droidloom (built-in, không có `/lib/modules`)**: `CONFIG_ANDROID_BINDER_IPC`, `CONFIG_ANDROID_BINDERFS`, `CONFIG_PSI`, `CONFIG_VETH=y`, `CONFIG_DMABUF_HEAPS_SYSTEM/CMA=y`. `droidloom-doctor` → `READY (0 blockers)`; cell `u1000` chạy, Android ready, `droidloomctl applications` liệt kê app.
- [x] **subuid/subgid**: hai file trống trong image (và một lần ghi dở để lại NUL padding khiến runtime parse ra 0 range); thêm `root:300000:100000` và initramfs chuẩn hoá lại mỗi boot.
- [x] **SSH bền vững**: initramfs ghi `99-lemonades.conf` (`ListenAddress 0.0.0.0`, `PermitRootLogin yes`) trước `switch_root`, sao lưu/khôi phục `/root/.ssh/authorized_keys`.
- [x] **OPP cpu7**: thêm 1747.2 MHz và 3187.2 MHz có trong LUT EPSS (trước đó `Voltage update failed` và bị loại); `policy7` giờ đạt 3187200 kHz.
- [x] **PCIe / GPU dummy regulator**: DTS thêm `vdda-supply`/`vddpe-3v3-supply` (l5a 0.88 V + l11c 3.3 V always-on); MSM GPU lấy `vdd`/`vddcx` dạng optional (SM8250 dùng RPMh power domain).
- [x] **SoundWire / LPASS**: port override chỉ log `info` thay vì `err`; WSA/RX macro sort `reg_defaults` + `reg_default_cb` (hết cảnh báo unsorted/zero-init); `qcom,dmic-sample-rate = <4800000>` và `vdd-micb-supply` cho VA macro.
- [x] **Khác**: q6afe bỏ qua response `DEVOTE` (0x100f6); PMIC Type-C `tx_sig` xuống `dev_dbg`; firmware sớm (BT `qca/*`, `regulatory.db`, SLPI) nhúng vào initramfs; `log_buf_len=8M` để log boot không bị log Android đẩy khỏi ring buffer.
- [ ] **Residual đã biết**: (1) 10 dòng SMMU context fault của display khi kernel tiếp quản splash bootloader (một lần mỗi boot, tự hết khi DPU scanout buffer của nó); (2) DCS `f0 5a 5a` timeout lần đầu trong `amb655x_prepare` — đã bỏ DCS sleep-in và thêm 50 ms settle, các boot gần nhất không còn timeout DCS (chỉ còn 2 dòng `dsi_err_worker: status=c` tuỳ boot, từ trạng thái DSI bootloader để lại); (3) hai amp loa WSA881x trên master `3250000.soundwire` ở trạng thái `UNATTACHED` (WCD938x vẫn attach); (4) MHI/SDX55 không có firmware mainline; (5) log userspace của cell (cpuset cgroup v1, `uprobestats` cần BTF, apexd device-mapper) là giới hạn của image Android, không phải driver kernel.

## Phase 5: Đối chiếu `timeroute/hakios-op8t` (OnePlus 8T / kebab) cho residual
- [x] **Panel amb655x (8T ≈ 9R)**: cùng panel Samsung amb655x 1080x2400 command-mode + DSC; switch 120 Hz của 8T là `f0 5a 5a` / `60 10` / `f0 a5 a5` (`docs/devices/kebab.md:13`), driver 9R đã có đúng chuỗi này. Áp dụng quy tắc an toàn của hakios (`docs/devices/kebab.md:129`): **không gửi DCS sleep-in 0x10** cho panel (mất DSC/vendor state) → bỏ `enter_sleep_mode` khỏi `amb655x_off`, chỉ dùng display off/on 0x28/0x29; thêm 50 ms settle sau reset trước lần gửi DCS đầu. Đã kiểm chứng trên máy: tắt DPMS rồi wake, ảnh chụp home screen đúng (không static màu).
- [x] **Splash/SMMU**: `docs/subsystems/display.md:58-63` xác nhận firmware để pipeline command-mode tự refresh framebuffer `0x9c000000` (0x2300000, trùng reserved-memory của 9R) qua apps-SMMU CB4 với autorefresh bật (`0x80000001`); đọc context bank của display = CrashDump. Đã thử tắt autorefresh sớm trong `dpu_kms_hw_init` sau `dpu_rm_init`: 10 fault vẫn y nguyên (burst nằm trong lúc init, trước điểm tắt) → **revert**, không giữ thay đổi vô tác dụng. Muốn hết phải map vùng splash vào IOMMU domain của DPU (hoặc đổi bootloader).
- [x] **WSA881x**: 8T/8/8 Pro dùng TFA9874 hoặc AW88261 trên MI2S/TDM (`docs/subsystems/audio.md:12,75-84`) — **không có WSA881x**, nên không có gì để copy; 9R (lemonades) là biến thể WSA8815 x2 trên SoundWire `3250000` (vendor DTB: `sdw20217211000`, powerdown GPIO 26/127). Đã thử retry frame-generator (SW reset, 3 lần) ở probe + runtime resume: **không fix**, amps vẫn `UNATTACHED` và log lỗi lặp → **revert**; giữ patch chỉ hạ log port-override.
- [ ] **WSA881x (tiếp)**: cần debug tầng LPASS/SWR: `fsgen`/MCLK của WSA macro lúc master resume, `SWRM_COMP_STATUS` bit 0, và so write-sequence WSA macro với Android trước khi start master.
- [x] **BT QCA6390**: `docs/subsystems/bluetooth.md` xác nhận cùng wiring (BT_EN GPIO 21, sw-ctrl GPIO 124, UART engine 6 @998000, rails smpa5/smpc8/ldoa16, thứ tự fw patch→NVM→HCI_Reset@115200→3.2 Mbaud, IBS 0xfd/0xfe). Linux dùng pwrseq 60 ms + GPIO delay 100 ms; lỗi đầu boot chỉ là retry rồi `QCA setup on UART is completed` — không cần đổi.
- [ ] **Haptics AW8697**: tham chiếu `docs/subsystems/input-peripherals.md:87` (I2C `0x5a`, reset GPIO 35, `aw8697_haptic.bin`) — dùng cho Phase 3.
- [x] **A/B fallback**: thêm `scripts/flash-boot-ab.sh` (chỉ ghi slot không active, verify sha + `dtbo_*` toàn 0, `qbootctl -s <slot>` — tham số **không** dấu `_`, vd `-s b`); `AGENTS.md` ghi quy trình bắt buộc. Lưu ý: slot `_b` chưa boot được sau khi activate (điện thoại không lên mạng; cần kiểm tra `hyp_b`/`tz_b`/`keymaster_b`/`cmnlib*_b`/`mdtp*_b` trước khi dùng lại).
