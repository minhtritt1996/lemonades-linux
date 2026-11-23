# lemonades-linux

Mainline Linux + Denial Mobile bring-up workspace cho **OnePlus 9R (`lemonades`, Qualcomm SM8250 / Snapdragon 865)**.

Tài liệu này tổng hợp toàn bộ kết quả nghiên cứu ban đầu để tiếp tục phát triển ở session mới.

---

## 1. Kiến trúc boot & phân vùng (đã xác nhận từ Nura OS `oneplus-kebab`)

OnePlus 8T (`kebab`) và OnePlus 9R (`lemonades`) dùng chung nền tảng **SM8250** và kiến trúc bootloader **XBL -> ABL gốc của OnePlus** (không dùng Mu-Silicium UEFI hay U-Boot):

- **Boot image format**: Android `boot.img` `header_version = 2`, `pagesize = 4096` (`mkbootimg`), flash qua `fastboot`.
- **DTBO**: Cần `dtbo.img` trống (như `sm8250-oneplus-kebab-empty.dts` của Nura) khi flash `dtbo` để ABL không ghép `dtbo` Android downstream lên DTB mainline.
- **Slot & Dynamic Partitions**: Máy dùng **A/B (`_a`/`_b`)** (`soc-qcom-qbootctl`) và dynamic partitions nằm trong `super` (trên `kebab` là `/dev/sda15`; cần kiểm tra chính xác partition table của `lemonades`).
- **Tài liệu tham khảo Nura OS (postmarketOS)**:
  - Device package `oneplus-kebab`: `https://gitlab.nura.eco/nura/pmaports/-/tree/main/device/testing/device-oneplus-kebab`
  - Kernel SM8250: `https://gitlab.nura.eco/soc/qualcomm-sm8250/linux` (tag `sm8250-7.2.0_git20261010`)
  - DTS chung OnePlus SM8250: `arch/arm64/boot/dts/qcom/sm8250-oneplus-common.dtsi`
- **Tài liệu tham khảo cùng hệ sinh thái Denial**: `picasso-linux` (cách tổ chức `build.sh`, patch series, `initramfs/init.c`, `picasso-gnss` + `org.dmail.Location1` bridge, `hexagonrpcd` `s2idle` hook, WirePlumber/BlueZ drop-ins).

---

## 2. Kết quả phân tích DTS hiện tại ([pmos_9r_safe.dts](reference/pmos_9r_safe.dts))

### Lỗi đã xác định: Sập nguồn khi flush khối lượng lớn dữ liệu từ RAM cache xuống UFS trên mainline Linux

Đối chiếu trực tiếp `reference/pmos_9r_safe.dts` với `sm8250-oneplus-common.dtsi` của Nura OS (`soc/qualcomm-sm8250/linux`):

1. **Thiếu `regulator-allow-set-load;` và `regulator-allowed-modes` trên LDO nuôi UFS**:
   - `ufshc@1d84000` (dòng `1997–2002`) đặt `vcc-max-microamp`, `vccq-max-microamp`, `vccq2-max-microamp` = `800000 uA` (`0xc3500`), nhưng `ldo17` (`vreg_l17a_3p0`, dòng `5573–5579`) và `ldo6` (`vreg_l6a_1p2`, dòng `5506–5512`) trong `pmos_9r_safe.dts` **bị thiếu**:
     ```dts
     regulator-allow-set-load;
     regulator-allowed-modes = <RPMH_REGULATOR_MODE_LPM
                                RPMH_REGULATOR_MODE_HPM>;
     ```
     *(Trong `sm8250-oneplus-common.dtsi` của Nura OS, cả `vreg_l6a_1p2` và `vreg_l17a_3p0` đều có 2 thuộc tính này.)*
   - Tương tự, `ldo5` (`vreg_l5a_0p88`, dòng `5499–5504`) và `ldo9` (`vreg_l9a_1p2`, dòng `5521–5527`) cấp cho `phy@1d87000` cũng nên kiểm tra thêm `regulator-allow-set-load;` / `regulator-always-on;`.
2. **Clock scaling UFS (`opp-table`)**:
   - `ufshc@1d84000` (dòng `2005–2018`) có 2 mức OPP `37.5 MHz` <-> `300 MHz`. Khi ghi burst lớn mà `vcc`/`vccq` chưa vote tải HPM đúng, quá trình chuyển xung + `auto-hibern8` dễ làm tụt áp hoặc treo NoC -> Watchdog cắt nguồn.
3. **Thiếu `ramoops`**:
   - `pmos_9r_safe.dts` chưa có node `ramoops` trong `reserved-memory`, nên chưa giữ được `console-ramoops` sau khi sập nguồn.
