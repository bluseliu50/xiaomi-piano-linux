# Bring-up guide for agents (piano, after milestone-touch)

Audience: an agent (possibly a smaller model) continuing the Xiaomi Pad 8 Pro
(piano, SM8750) port. Read this completely before touching code or the device,
together with `AGENTS.md`, `docs/device-bringup-runbook.md` §7-§8 and
`docs/touch-bringup-v2.md`. Everything here was measured on the device unless
marked *(unverified)*.

## 1. How this device actually boots (do not re-derive)

- RAM boot only: `fastboot boot boot.img` after `fastboot flash dtbo_b dtbo.img`,
  `current-slot` must be `b`. Never write anything else (AGENTS.md rule 5).
- ABL composes the **stock vendor DTB** (vendor_boot, `vbdtb-04` = "SunP v2 Alt.
  Thermal Profile") **plus our dtbo_b**. Our kernel never sees a mainline DTB.
  Every mainline node is an overlay fragment in
  `debian-piano/boot/dtbo-piano-touch-v2.dts` (which `#include`s the
  milestone-1 base `dtbo-piano-usb-nopd9.dts`).
- `/soc` in the stock tree is **1-cell address / 1-cell size**. Mainline
  `reg = <0x0 A 0x0 S>` must be written `reg = <A S>`.
- Overlay fragments: use `target-path` or `target = <&stock_label>`; new
  fragment numbers above the highest existing one (currently 228); labels you
  add yourself are fine inside the overlay. ABL rewrites phandles.
- You can simulate exactly what ABL builds:
  `fdtoverlay -i local/dtb-downstream/vbdtb-04.dtb -o merged.dtb overlay.dtb`
  (extract `overlay.dtb` from the DTBO container: header 32 B + entry 32 B,
  entry holds size/offset big-endian). For the milestone-1 overlay this was
  verified byte-identical to the live `/sys/firmware/fdt`. Always check the
  merged tree before a device test.
- Display is `simpledrm` on the bootloader's splash framebuffer
  (3200x2136, stride 12800, a8b8g8r8). No native DRM/DSI driver runs; the
  panel is powered by ABL and must be left alone.

## 2. Things that reset the SoC (each cost a device round)

| Trigger | Symptom | Rule |
|---|---|---|
| Unmatched **apps SMMU** stream (any new DMA master) | silent reset on first DMA, no log anywhere | see §3; check before loading any DMA driver |
| TLMM read outside 0x0f100000..0x0f202000, or of a secure GPIO | reset within seconds | TLMM node needs `gpio-reserved-ranges = <36 4>, <48 4>, <74 1>` |
| Reprogramming panel RPMh rails (L12B/L9B) or voltages mid-scanout | panel garbage + reset | never touch display rails |
| Booting the ADSP firmware | panel dies permanently (backlight stays) | ADSP work needs a separate display strategy |
| M31 eUSB2 PHY init | bus hang | USB2 stays on `usb_nop_phy` |
| Leaving custom `boot_b`/`vbmeta_b` next to stock | ABL aborts before the kernel | only dtbo_b is ever flashed |

pstore/ramoops is built in and the console is mirrored into it, but on this
device **it did not survive any of these resets**. Do not plan around pstore.
What works: `/dev/kmsg` streamed live to the host over telnet
(`cat /proc/kmsg`) — the last line before the link drops is your crash point.
Write a marker to `/dev/kmsg` before every risky step.

## 3. The apps SMMU (read this before any DMA peripheral)

The stock SMMU node is `qcom,qsmmu-v500` at 0x15000000; nothing binds it, so
it keeps the ABL state: `sCR0 = 0x002D0406` (USFCFG = 1, unmatched streams
fault), 127 stream-match groups, matches only for streams ABL uses:

| slot | stream/mask | owner | context bank |
|---|---|---|---|
| 0 | 0x60 | UFS | 0 |
| 1 | 0x540 | SDHC | 1 |
| 2 | 0x800/0x2 | display (0x800, 0x801) | 2 |
| 3 | 0x40 | USB dwc3 | 3 |
| 4 | 0x480 | ? | 4 |

All those context banks have stage 1 off (pass-through). `piano-qup-smmu`
(runs at boot from init) adds 0xb6 (QUP1 GPI) and 0xa3 (QUP1 SE) routed like
USB. Stream IDs of the other masters, from the stock `iommus`:

| Master | stream(s) | notes |
|---|---|---|
| QUP1 GPI / SE (touch SPI, keyboard i2c SE6) | 0xb6 / 0xa3 | matched at boot |
| QUP2 GPI / SE (uart14 BT, i2c on 0x8c0000) | 0x436 / 0x423 | **not matched** — add before using QUP2 DMA |
| PCIe0 (WLAN) | 0x1400, 0x1401 (`iommu-map`) | not matched |
| audio (msm-audio-ion) | 0x1001/0x80, 0x1041/0x20 | not matched |
| video (vidc) | 0x1940.. | not matched |
| GPU | separate KGSL SMMU 0x3da0000 | own SMMU, same issue class |

To extend: `piano-qup-smmu 0x436 0x423` (script accepts IDs). Verify with
`piano-qup-smmu --check`. The long-term fix is a mainline
`qcom,sm8750-smmu-500` node with proper `iommus` everywhere, designed so the
display streams keep working (the kernel would reset all SMRs at probe).
Do not attempt that without a plan for the display handoff.

## 4. Working method (what made touch succeed in one session)

1. **Read the vendor source first.** `refer/MiCode_piano/` holds the exact
   kernel, DT and drivers Xiaomi ships for piano. For a driver, find its build
   flags (`Android.mk`, `Kbuild`, `*.conf`) — e.g. touch is built with
   `CONFIG_TOUCH_THP_SUPPORT=1`, which changes the memory map. Other
   Xiaomi devices (sheng, p82) are only hints.
2. **Validate data offline.** Firmware headers, overlays (fdtoverlay),
   userspace tools (static musl + `qemu-aarch64-static` with synthetic input)
   — before any device round.
3. **Stage device work** so each step adds exactly one new hardware access,
   read-only first. Pattern: `piano-touch-test` (stages 0-4).
4. **Use `devmem` read-only** to learn hardware state (pin mux, SMMU tables,
   clocks) — always bound-check addresses on the host first.
5. **First data transfer through a trivial path** (`spidev` + a 4-byte read)
   before the real driver: it separates bus problems from driver problems.
6. **Every device round**: host log stream running, marker in kmsg, one
   change, and a written expectation of the outcome.
7. Build only with `scripts/build-test-image.sh --jobs "$(nproc)"`. It
   regenerates the kernel release and checks module vermagic (stale vermagic
   once masked five "independent" bugs). Never run `make` in a way that can
   stop at a Kconfig question in the background: after changing `.config`
   run `make olddefconfig`.

## 5. Tooling on the test image

- Host: `nmcli connection up piano-ncm` (10.42.0.1/24, matched by MAC
  02:66:77:88:99:aa). Device: telnet 10.42.0.2:23, HTTP of `/run` on :8080.
- Host has no `nc`; drive telnet from Python (answer the busybox
  `ESC[6n` cursor query, see the session scripts in `out/`).
- Serve files to the device with `python3 -m http.server --bind 10.42.0.1`
  and `wget` on the device; load modules with `insmod`/`modprobe`.
- `piano-tests` menu, `piano-touch-test`, `piano-touch-view`,
  `piano-qup-smmu`, `piano-collect`.

## 6. Remaining work, in recommended order

Each item: goal, vendor reference, known facts, first safe step, risks.

### 6.1 Touch → desktop input (small)
- Done: THP frames, simple tracker, uinput (`piano-touch-test --stage 5`).
- Next: package a proper THP service. Upstream candidate
  `refer/ianchb_xiaomi-sheng-thp` (Apache-2.0, sheng) expects the same
  `/proc/nvt_thp_*` interface; piano differs in frame length (5192 vs 5160,
  read from poll info) and orientation (rows reversed). Fork per AGENTS.md
  rule 4 into `userspace/`, keep the diff data-only (a profile).
- Stylus: frames of type 6/7/9/0x1d appear once `/proc/nvt_thp_stylus` is
  enabled; pen pressure comes over Bluetooth (needs BT first).

### 6.2 Keyboard + touchpad (medium)
- Stock: `nanosic,803` at i2c 0x4c on QUP1 SE6 (`qupv3_se6_i2c`,
  i2c@a98000), IRQ gpio97, reset gpio188, status gpio95, sleep gpio3,
  supplies dvdd/vdd; driver in `refer/MiCode_piano` (search `nanosic`), sheng
  precedent `ianchb/xiaomi-sheng-keyboard-helper`.
- QUP1 streams are already matched. Needs: mainline `qcom,geni-i2c` binding
  for SE6 (same conversion as SE2 in the touch overlay), pins via the mainline
  TLMM node, the driver port.
- Risk: the supplies are PMIC regulators — only read their state; do not
  enable/adjust rails until you know they are off-panel.

### 6.3 Battery / charging (MVP, hard)
- Needs ADSP (pmic-glink + battmgr); the pd-mapper fix
  (`d029c35e6`) and PAS tolerance commits are already on the kernel line.
- Blocker: booting ADSP kills the panel. Find out why before anything else
  (ADSP taking over a display rail or clock?). Test with the console on USB
  only and the panel treated as expendable for that round, with the user's
  consent. Audio stream IDs (§3) will also be needed.

### 6.4 WLAN / BT (medium)
- WLAN = "peach" PCI 17cb:110e (ath12k, WCN7850 path, commit on the kernel
  line). PCIe needs the SMMU streams 0x1400/0x1401 matched first.
- BT = uart14 on QUP2 (streams 0x436/0x423) + pwrseq-qcom-wcn.

### 6.5 Native display (DRM/DSI) and GPU (hard, MVP)
- Needed for the GPU and for real power management of the panel.
- Panel: the stock tree offers two Xiaomi P81 LCD panels
  (`dsi_p81_42_02_0a_dualdsi_dsc_lcd_video`, `..._35_02_0b_...`, dual-DSI
  DSC video) besides the NT37801 AMOLED that the early mainline DTS guessed;
  the 3200x2136 dual-DSI splash matches the P81 LCDs *(which of the two:
  unverified; the touch lcd-id pin read 1 = BOE)*.
  A panel driver must come from the MiCode display sources
  (`refer/MiCode_piano/vendor_opensource_display-drivers`,
  `vendor_qcom_opensource_display-devicetree`).
- Display streams 0x800/0x801 are already matched by ABL.
- GPU: `bp/gpu-v1` (XEC A830 backport) exists but is untested; the KGSL
  SMMU (0x3da0000) has the same unmatched-stream issue.

### 6.6 Sensors, suspend, rest
- Sensors go through the ADSP (SSC), after 6.3.
- Suspend/resume needs the native display path first.

## 7. Before you finish a session

- Commit in English, one logical change per commit, on a feature branch.
- Record device results (with kernel release and image hashes from
  `MANIFEST.txt`) in a `docs/` file.
- Update the workspace notes in `refer/GLM5.3_Report/STATUS.md`.
- Never leave the device with anything but stock partitions + dtbo_b.
