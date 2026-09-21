# Xiaomi Pad 8 Pro (piano) — first-light device runbook

Scope: the RAM-boot (`fastboot boot`) test session using the
`piano/test-bringup` kernel and the `debian-piano` test image
(`out/test-image/`). Everything here is **read-only for the device's
permanent storage**: no partition is written, erased or flashed at any
point. Rebooting returns the device to stock Android on its current slot.

## 1. Safety audit (2026-09-19, offline review)

Findings from reviewing every branch/artifact that touches the device:

| # | Area | Finding | Risk | Mitigation |
|---|---|---|---|---|
| 1 | Boot flow | Test images boot via `fastboot boot` only; no flash/write path exists anywhere in `debian-piano` or the kernel branches (no `dd`, `mkfs`, `flash` commands in any shipped script; initramfs `/init` explicitly never writes to partitions and never `switch_root`s) | none (RAM only) | keep it that way; flashing needs a separate, explicit decision |
| 2 | Bootloader chain | Untouched: images contain only kernel+ramdisk+dtb; `abl/xbl/tz/hyp/...` never referenced | none | hard rule (AGENTS.md §5) |
| 3 | dtbo interaction | Stock `dtbo_b` stays in place; abl may try to apply stock overlays onto our DTB — symbols (`qupv3_se2_spi`, …) don't exist upstream, so an overlay apply may fail | boot aborts **before the kernel runs** (costless); OQ#7 territory | variant ladder below; never flash dtbo during RAM-boot testing |
| 4 | Display panel power | `display_panel_vsp/vsn` fixed regulators (GPIO 117/118, ~5.8 V) are `always-on` (OQ#17); stock also holds them at boot handoff | panel stress/heat on long sessions | keep sessions short; test script blanks the screen and drops backlight when done; power off between sessions |
| 5 | Panel rail mapping | `vci`/`vdd` assignments carried from the SM8750 MTP (OQ#16) — piano's downstream supply table lists only vddio+VSP/VSN | wrong-rail voltage if wiring differs — **main hardware risk of the display test** | first boot: watch dmesg + panel; if the panel stays dark, stop and collect evidence, do not iterate blindly |
| 6 | Touch firmware | DT pins the CSOT-family blob; the panel family is unknown until read (OQ#15). A wrong-family blob fails CRC inside the no-flash touch IC | touch init failure (recovers on reboot) | both families ship in the image; if CSOT fails, rebuild with the BOE `firmware-name` |
| 7 | Battery/charging | Mainline pmic-glink charger stack is unvalidated; the device runs on battery during the test | battery drain (fuel-gauge protection shuts down safely) | start > 50 %, keep USB connected, abort at < 20 % |
| 8 | GPU | The experimental GPU branch (`bp/gpu-v1`) is **not** part of this image | none in this test | GPU validation is a separate, later session |
| 9 | initramfs network | USB-NCM point-to-point only (usb0, 10.42.0.0/24); no other interface comes up | exposure limited to the plugged-in host | fixed test MACs; udhcpd pool on the link only |
| 10 | initramfs SSH | dropbear: pubkey (per-build ed25519) and/or root password (SHA-512 hash) or blank password (`-B`); no other services listen | someone with the USB cable can log in — accepted for bring-up | auth material lives only in gitignored `out/`; rebuild to change; remove blank/password modes once rootfs matures |
| 11 | Boot-image params | All from stock-ROM CONFIRMED values (`boot/stock-boot-params.env`); cmdline is console-only (operator policy) | none | provenance gate refuses UNVERIFIED values for deliverables |

## 2. Preconditions

- Unlocked bootloader (user's own action), battery > 50 %.
- Slot A stock Android bootable; rescue fastboot ROM in `local/rom/`.
- Host with `fastboot` (android-tools), SSH client, and the workspace.
  - Verified on the bring-up host (2026-09-21): `fastboot` runs without
    sudo from a local session — systemd's `70-uaccess.rules` tags ADB/
    fastboot USB devices (interface classes ff4201/ff4203) `uaccess`, and
    logind grants the seated user ACL access to the device node.
    OpenSSH 10.5p1 client is ready.
- Built image set: `debian-piano/out/test-image/` (MANIFEST.txt + 5 images).

## 3. Boot order (each attempt is costless)

```
fastboot devices                      # device visible
fastboot getvar current-slot          # RECORD it
fastboot getvar unlocked              # expect: yes

# primary — single image
fastboot boot piano-test-boot-v2.img

# optional abl-acceptance probe — v4 boot with EMPTY ramdisk, no dtb.
# Only tells whether abl accepts a RAM boot at all: the kernel starting
# and then stopping is EXPECTED (no initramfs/dtb inside this image).
fastboot boot piano-test-boot.img
```

Why no dual-image commands: the host fastboot (Debian android-tools
37.0.0, AOSP `FB_CMD_BOOT`: `boot KERNEL [RAMDISK [SECOND]]`) accepts
exactly ONE image per `boot`; passing a second boot.img dies with
`cannot boot a boot.img *and* ramdisk` (string confirmed in the host
binary). So the v4 combos (`boot`+`vendor_boot`,
`boot-ramdisk`+`vendor_boot-dtb`) have **no RAM path on this host**.
They become available again if the host fastboot's own usage text shows
multi-image boot support.

**If the primary (v2) is rejected by abl** (error, device returns to
fastboot): record the raw `fastboot` output and STOP — report it, do not
improvise. Rationale: the v4 dual-image combos are unusable here (see
above); flashing `vendor_boot_b` is NOT permitted (AGENTS.md writable
whitelist is `boot_b`/`dtbo_b`/userdata-derived only), so it is not a
bypass; and any new workaround (e.g. an Image+dtb concatenated sixth
variant) is new content that needs explicit user approval first.

## 4. After boot

Expected: kernel console text **on the panel** (fbcon — the display test)
and/or a USB network interface on the host (the gadget runs udhcpd; the
host may also use static 10.42.0.1/24).

```
ssh -i debian-piano/out/test-image/piano-test-ssh-ed25519 root@10.42.0.2
# or, built with --root-password:  ssh root@10.42.0.2   (then password)
# or, built with --root-password '': press enter at the password prompt

piano-tests          # interactive menu below (9 tests + status matrix)
```

- **Touch** (`1`): enables `/proc/nvt_thp_raw` and streams decoded THP
  frames (sequence, validity flags, CRC, first event bytes) for 30 s —
  touch the screen. Pass: `VALID` frames with increasing sequence.
- **Display** (`2`): DRM connector status, fb geometry, full-screen
  R/G/B/W/K fields + noise via `/dev/fb0`, held 2 s each.
  Pass: fields visible on the panel.
- **Audio** (`3`): walks the ADSP → soundwire → wcd9395 → wsa884x
  soundcard chain; `3a` additionally plays a 3 s 440/880 Hz tone through
  the speakers (manual listen: audible = full analog chain works).
- **Battery** (`4`): pmic-glink/battmgr telemetry (capacity, status,
  charge types) — requires ADSP running.
- **WLAN** (`5`): pcie0 enumeration → ath12k probe, optional scan.
- **Bluetooth** (`6`): uart14 serdev + pwrseq + hci0 bring-up.
- **Collect** (`7`, verbose `7v`): one-shot evidence tarball (dmesg,
  /proc state, DRM/touch status); `scp root@10.42.0.2:/run/piano-evidence-*.tar.gz .`
- **dmesg** (`8`): subsystem-filtered tail (panel/DRM/touch/USB/PMIC/
  remoteproc/audio/ath12k/qca).
- **probe** (`9`): refresh the status matrix.
- A boot smoke report is written automatically to `/run/boot-smoke.log`
  by `piano-tests --auto` ~5 s after boot (status matrix + evidence
  tarball, non-interactive).

### 4b. Device coverage & first-boot expectations

Kernel `7.2.6-00013-g2f4a243cb610` (`piano/test-bringup`). What the
image is prepared to bring up on first boot, and where it may not:

| Subsystem | DT node | Driver / module | Firmware in image | First-boot expectation | Known risk |
|---|---|---|---|---|---|
| Display | mdss_mdp + dsi0 + NT37801 panel | `DRM_MSM=y`, `DRM_PANEL_NOVATEK_NT37801=y` (fbcon) | — | kernel console text on the panel | panel family unknown (OQ#15); vci/vdd rail mapping from MTP (OQ#16); VSP/VSN regulators always-on → heat (OQ#17) |
| Touch | spi2 + nt36532e | `nt36532e_ts=m` + `spi-geni-qcom=m` | `novatek/novatek_nt36532_piano_fw_csot.bin` (CSOT pinned in DT; BOE variant also shipped) | probes after the panel; `/proc/nvt_thp_status` exists | wrong-family blob → CRC fail inside the IC, recovers on reboot; avdd/lcd-id GPIOs unmanaged (OQ#18) |
| USB-NCM | dwc3 gadget usb0 | built-in (`=y`: libcomposite + NCM, M31 eUSB2 + QMP combo phys); `pmic_glink_altmode=m` loaded by /init for Type-C role/orientation (gadget defaults to peripheral without it, USB2 speed only) | — | host gets 10.42.0.2/24, ssh works | — |
| Battery | pmic_glink → battmgr | `pmic_glink=m`, `qcom_battmgr=m` | via ADSP image | capacity/status readable once ADSP runs | needs the shipped `piano-pd-locator` for the glink domain |
| ADSP/CDSP | remoteproc `adsp`/`cdsp` | `qcom_q6v5_pas=m` | `qcom/sm8750/{adsp,cdsp}.mbn` (84 files: mdt→mbn renamed + bNN segments) | remoteproc state `running` for both | first load of a vendor firmware on mainline — watch dmesg |
| Audio | sm8750 sndcard + wcd9395 + wsa884x + soundwire | sc8280xp/wcd939x/wsa884x/soundwire chain `=m` | via ADSP image | `/proc/asound/cards` lists the card | WSA884x vs 883x amp variant decided by SDW enumeration (OQ#21) |
| WLAN | pcie0, PCI 17cb:110e | `pcie-qcom=y` + `qmp-pcie phy=m` (packed, loaded by /init), `ath12k=m` (ID added, probes the WCN7850 path) | `ath12k/WCN7850/hw2.0/` (4 files) + board data | PCI enum → MHI → QMI → wiphy | CE config / firmware family may differ from WCN7850 hw2.0 (OQ#20) |
| Bluetooth | uart14 serdev + pwrseq | `hci_uart=m`, `btqca`, `pwrseq-qcom-wcn=m` | `qca/` hmt family (6 files) | `hci0` appears with an address | same combo rails/clock as WLAN (OQ#20) |
| GPU | absent | not in this image | — | — | GPU validation is a separate later session (`bp/gpu-v1` is not merged into `piano/test-bringup`) |

## 5. Abort criteria (stop, hold power, collect evidence)

- Panel area or SoC area becomes noticeably hot, or any burning smell.
- Panel stays dark AND the VSP/VSN area heats (rail mapping suspect — OQ#16).
- Battery below 20 %.
- Primary (v2) rejected by abl — record the raw `fastboot` output and
  stop (§3). Repeated silent aborts of the primary likewise.

## 6. Rebuild / customize

One command from the workspace root (ties linux-piano + debian-piano +
local/ together; refuses to build from any kernel branch other than
`piano/test-bringup` and refuses a dirty kernel tree):

```
scripts/build-test-image.sh [--root-password 'x']      # '' = press-enter login
                             [--authorized-keys ~/.ssh/id_ed25519.pub]
                             [--jobs N] [--kernel-out DIR] [--output-dir DIR]
```

It builds the kernel into `linux-piano/out` (unless
`--skip-kernel-build`), stages the arm64 userland on demand, then runs
the debian-piano packer, which produces and round-trip-verifies the five
image variants into `debian-piano/out/test-image/` (MANIFEST.txt lists
hashes, parameters and the boot ladder).

Internals (component repos, reusable on their own):

```
debian-piano/scripts/fetch-arm64-tools.sh      # static busybox + dropbear tree
debian-piano/scripts/build-test-bootimg.sh \
    --kernel-dir ../linux-piano/out \
    --firmware-dir ../local/firmware \
    --output-dir out/test-image
```

Kernel side: `linux-piano` branch `piano/test-bringup`
(display pipeline + NT37801 panel + NT36532E SPI touch, panel-follower
wired).
