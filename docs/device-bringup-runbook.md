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
- Built image set: `debian-piano/out/test-image/` (MANIFEST.txt + 5 images).

## 3. Boot order (each attempt is costless)

```
fastboot devices                      # device visible
fastboot getvar current-slot          # RECORD it
fastboot getvar unlocked              # expect: yes

# variant 1 — stock layout (primary)
fastboot boot piano-test-boot.img piano-test-vendor_boot.img

# variant 2 — if the device rejects variant 1 (vendor-ramdisk handling)
fastboot boot piano-test-boot-ramdisk.img piano-test-vendor_boot-dtb.img

# variant 3 — legacy all-in-one
fastboot boot piano-test-boot-v2.img
```

If a variant hangs or returns to fastboot: hold power to reset, then try the
next. Nothing was written; stock Android is one reboot away at all times.

## 4. After boot

Expected: kernel console text **on the panel** (fbcon — the display test)
and/or a USB network interface on the host (the gadget runs udhcpd; the
host may also use static 10.42.0.1/24).

```
ssh -i debian-piano/out/test-image/piano-test-ssh-ed25519 root@10.42.0.2
# or, built with --root-password:  ssh root@10.42.0.2   (then password)
# or, built with --root-password '': press enter at the password prompt

piano-tests          # menu: probe status, touch, display, evidence
```

- **Touch test** (`1`): enables `/proc/nvt_thp_raw` and streams decoded
  THP frames (sequence, validity flags, CRC, first event bytes) to the SSH
  session for 30 s — touch the screen. Pass criterion: frames with
  `VALID` and increasing sequence while touching.
- **Display test** (`2`): DRM connector status, fb geometry, full-screen
  R/G/B/W/K fields + noise via `/dev/fb0`. Pass criterion: fields visible.
- **Evidence** (`3`): tarball with dmesg, /proc state, DRM/touch status;
  `scp root@10.42.0.2:/run/piano-evidence-*.tar.gz .`
- A boot smoke report is written automatically to `/run/boot-smoke.log`.

## 5. Abort criteria (stop, hold power, collect evidence)

- Panel area or SoC area becomes noticeably hot, or any burning smell.
- Panel stays dark AND the VSP/VSN area heats (rail mapping suspect — OQ#16).
- Battery below 20 %.
- Repeated boot aborts in all three variants (record `fastboot` output).

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
