# Piano touch bring-up, iteration 2 (2026-09-26)

Follows `docs/touch-spi-trial.md`. Branches: umbrella `piano/touch-bringup`,
`linux-piano` `piano/touch-bringup`, `debian-piano` `bp/touch-bringup`.
Build: `scripts/build-touch-test-image.sh --jobs 32` →
`debian-piano/out/touch-v2/{boot.img,dtbo.img,MANIFEST.txt}`.

## What the hardware needs (from the MiCode piano sources)

| Item | Source | Value |
|---|---|---|
| Touch IC | `vendor_xiaomi_proprietary_touch-driver/p81/nt36532` | Novatek NT36532(E) TDDI, host-download (no flash) |
| Driver mode | `p81/Android.mk` | `CONFIG_TOUCH_THP_SUPPORT=1`, `CONFIG_TOUCH_TDDI_SUPPORT=1`: the IC streams raw frames, coordinates are computed on the host |
| Bus | `piano-xiaomi-touch-pinctrl.dtsi`, `sun-pinctrl.dtsi` | QUP1 SE2 SPI, GPIO40-43 (`qup1_se2`, 6 mA, no bias), 19.2 MHz, mode 0 |
| IRQ | same | GPIO162, rising edge (`INT_TRIGGER_TYPE`) |
| Panel ID | `nt36xxx.c` `nvt_parse_dt()` | GPIO100 input: 0 = CSOT, 1 = BOE; selects the firmware |
| Reset GPIO | `nt36xxx.h` | none (`NVT_TOUCH_SUPPORT_HW_RST 0`) |
| Power | touch node has no supply | TDDI: powered with the panel. `touch_avdd_vreg` (GPIO114, also a CCI pin) is an unused leftover |
| Memory map | `nt36xxx_mem_map.h` (THP) | cascade chip: event buffer 0x11C400, polling info 0x1093D8 |
| Frame | `nt36xxx.c` `nvt_ts_work_func()` | read 256 event bytes + `frame_len` from the polling info; payload type @56, cols/rows @48/49, matrix @64 |
| Secure GPIOs | `sun.dtsi` `qcom,gpios-reserved` | 36-39, 48-51, 74 |

Both firmware blobs (`novatek_nt36532_piano_fw_{csot,boe}.bin`, fw 0x12 / 0x13)
parse identically with the MiCode and the sheng-derived header parsers; the
header CRCs equal the computed ILM/DLM CRC32.

## Changes

Kernel (`drivers/input/touchscreen/nt36532e`): THP memory map and frame length
from the polling info, firmware picked by the panel ID pin, no-DRM-panel mode
(display left on by the bootloader), IRQ enabled only after a successful
download, full frame read on every IRQ, stock CS timing, sheng-only doze
tuning removed, `/proc/nvt_thp_status` extended, `/proc/nvt_thp_cmd` for
single extended host commands. Config: built-in pstore RAM + console, uinput.

Overlay (`debian-piano/boot/dtbo-piano-touch-v2.dts`): mainline TLMM node with
the secure pins reserved and the SE2 pin state; stock `novatek@0` disabled
(its `panel` phandle blocks probing and cannot be deleted by an overlay) and a
new `touchscreen@0`; ramoops trades pmsg for oops records. Checked with
`fdtoverlay` on the stock vendor DTB `vbdtb-04` (SunP v2 Alt. Thermal).

Probable cause of the earlier TLMM reboot: without `gpio-reserved-ranges`,
gpiolib reads the direction register of every pin at registration, including
the secure ones. With the stock reserved list the probe reads exactly the pins
the stock kernel reads.

## Device procedure

Host, device in fastboot:

```
fastboot getvar current-slot        # must be b
fastboot flash dtbo_b debian-piano/out/touch-v2/dtbo.img
fastboot boot debian-piano/out/touch-v2/boot.img
nc 10.42.0.2 23                     # busybox telnetd
```

Device: `piano-touch-test --stage 0` … `--stage 4` one at a time (or no
argument for all). Evidence: `http://10.42.0.2:8080/touch-test.log`,
`/fdt.dtb`, `/tlmm-pre.txt`, `/pstore-prev/`.

If the device resets: hold Volume Down to land in fastboot directly (Android
must not boot, or it overwrites ramoops), RAM-boot the same image again and
read `/run/pstore-prev/console-ramoops-0`.

Rollback: `debian-piano/out/adsp-m1/rollback-spi-good.dtbo.img` or the
milestone-1 pair in `debian-piano/out/test-image/`.

## Results

(filled in after the device session)
