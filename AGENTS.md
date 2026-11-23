# Quy tắc bắt buộc — `lemonades-linux`

Áp dụng cho mọi thay đổi trong repository này (kernel mainline Linux + Denial Mobile cho
OnePlus 9R / `lemonades` / SM8250, boot qua XBL -> ABL gốc của OnePlus bằng `boot.img` v2 + `dtbo.img` trống).

## 1. Bất biến

1. **Bảo vệ UFS (chỉ flash `boot` / `dtbo` khi được yêu cầu).** Cấm `fastboot erase`, `fastboot flash` hay `dd` vào bất kỳ phân vùng UFS quan trọng nào (`xbl`, `abl`, `modem`, `persist`, `super`, ...) nếu người dùng chưa yêu cầu rõ. Thử nghiệm mặc định dùng `fastboot boot` hoặc flash vào slot A/B **không đang chạy**.
2. **Thử kernel qua A/B (KHÔNG dùng `qbootctl -s`).** Không ghi đè slot đang chạy: dùng `scripts/flash-boot-ab.sh --yes` (hoặc tương đương: `dd` `boot.img` vào `boot_a`/`boot_b` không active, `conv=fsync`, `sync`, đọc lại sha256, kiểm `dtbo_*` toàn 0), rồi reboot vào bootloader và chuyển slot bằng `fastboot --set-active=<a|b>`. **Cấm chạy `qbootctl -s <slot>`**: `linux-msm/qbootctl` (`bootctrl_impl.c:551-558`) có bug đảo ngược TypeGUID với cờ `Active` trên LUN 4 (gán `inactive_guid` `77036cd4` cho slot vừa kích hoạt), khiến ABL báo `Failed to load/authenticate boot image: Device Error`. Chỉ dùng `qbootctl` để xem trạng thái và `slot-success.service` (`units=denial.service sshd.service`, `settle=60`) để đánh dấu slot thành công.
3. **`upstream/` read-only.** `upstream/linux` phải luôn sạch và đúng commit trong `patches/linux/UPSTREAM`. Không sửa, không tạo file trong `upstream/`.
4. **Patch-first.** Mọi thay đổi kernel chỉ tồn tại dưới dạng patch trong `patches/linux/lemonades/` và được liệt kê trong `patches/linux/series`. Thử nghiệm trong `build/linux/`, xác nhận xong mới `./build.sh export-patches` để giữ repo nhẹ.
5. **Không hardcode đường dẫn tuyệt đối** trong script/tài liệu; suy dẫn từ gốc repository.

## 2. Nguồn giá trị phần cứng

- DTS nền chính: `reference/lemonades.dts` (mainline, hỗ trợ DisplayPort + USB 3.0 + OTG + Audio SoundWire + `samsung,amb655x` + `syna,s3908` + `bq27541` + `qca6390`).
- Tham số `boot.img` v2 chuẩn ABL OnePlus 9R: `pagesize=4096`, `header_version=2`, `--kernel_offset 0x8000`, `--ramdisk_offset 0x1000000`, `--tags_offset 0x100`, `--dtb_offset 0x1f00000`, `dtbo.img` trống.

## 3. Kiểm chứng

- `./build.sh check` trước khi commit: apply `series` lên cây sạch + build kernel & `sm8250-oneplus-lemonades.dtb`.
- Không tuyên bố "chạy được" khi chưa có log/ảnh chụp từ máy.

## 4. Cấu trúc

```text
patches/linux/series        thứ tự patch
patches/linux/lemonades/    patch delta cho OnePlus 9R (lemonades)
configs/linux/              fragment Kconfig
scripts/                    build, đóng gói boot.img v2 + dtbo.img trống, mkinitramfs
initramfs/                  init (PID 1) và helper nằm trong ramdisk
reference/                  lemonades.dts nền đối chiếu
build/                      cây build cô lập + build/out
```
