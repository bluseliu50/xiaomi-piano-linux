# AGENTS.md — linux-xiaomi-piano workspace guide

> This is the single agent-guidance file for the whole workspace. Do NOT create
> AGENTS.md/CLAUDE.md files inside component repos (linux-piano, debian-piano,
> userspace/*) — the kernel repo in particular must stay clean for upstream interaction.
> Always work from the workspace root.

## Project

Port a complete Linux system (Debian first) to the Xiaomi Pad 8 Pro (codename **piano**,
Qualcomm SM8750 / Snapdragon 8 Elite / Adreno 830, Wi-Fi-only, no modem).
MVP = graphical desktop + GPU driver + charging & power management.
Stretch goals: keyboard & touchpad, stylus, MiPPS fast-charge protocol, sensors, WiFi/BT,
audio; long tail: camera, fingerprint, NFC.

## Directory semantics

| Path | Meaning | Git |
|---|---|---|
| `docs/` | project docs (feasibility, plan, bring-up logs, boot-image notes, component specs) | tracked |
| `scripts/` | cross-repo orchestration (build/extract/flash helpers) | tracked |
| `refer/` | external reference material (see policy below) | ignored |
| `local/` | device extractions, backups, proprietary firmware (irreplaceable) | ignored — NEVER commit |
| `out/` | build outputs | ignored |
| `linux-piano/` | kernel repo — submodule (vanilla v7.2.6 base, device branch `piano-7.2.6`) | submodule |
| `debian-piano/` | rootfs/packaging repo — GitHub repo exists (empty); written from scratch, local clone created when implementation starts | ignored → future submodule |
| `userspace/` | userspace shallow forks — created per-phase on demand (currently absent) | ignored → future submodules |

Component repo specs are added under `docs/` as each repo is bootstrapped.

## refer/ policy (explicit permission)

Although `refer/` is git-ignored, agents are allowed (and encouraged) to create
directories, download files, and clone repositories inside it:

1. Purpose-driven: only material worth referencing — upstream code, precedent projects,
   docs, firmware samples. Not a dumping ground.
2. Naming: `<org>_<repo>` or `<topic>` (existing style: `MiCode_piano`, `xiaomi-sheng_3rd`).
3. Clone style: `git clone --depth 1` in general; deeper or full clones when history or
   cherry-picking is needed (kernel forks, pmaports).
4. **Backfill obligation**: after adding a new reference, update the
   "Reference repositories" list below.
5. Treat every `refer/` subtree as read-only — never modify reference sources in place.
6. Reference `refer/` content from project docs using workspace-root-relative paths
   (e.g. `refer/MiCode_piano/...`).

## Reference repositories (recommended downloads)

### Required (component bootstrap + early bring-up)

| Repository | URL | Why |
|---|---|---|
| ianchb/sm8550-mainline | https://github.com/ianchb/sm8550-mainline | sheng precedent tree (branch `sheng-7.2.y`) — **cherry-pick source** for device drivers (nt36532e panel, NVT touch SPI, nanosic keyboard); NOT a base (our base is vanilla stable) |
| ianchb/debian-sheng | https://github.com/ianchb/debian-sheng | Build-flow REFERENCE ONLY for `debian-piano` — the repo has **no LICENSE**; never copy files from it (read for Actions pipeline / flash-flow / initramfs ideas). Our builder is written from scratch. |
| ianchb/sheng-firmware | https://github.com/ianchb/sheng-firmware | sheng firmware repo precedent; reference for building the piano firmware manifest |
| Linux stable | git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git | `upstream` remote for `linux-piano` (7.2.y baseline); shallow clone acceptable |
| postmarketOS pmaports | https://gitlab.com/postmarketOS/pmaports | Gold-standard initramfs hooks (USB-net debugging) + SM8750 device packages (e.g. oneplus-pagani, the most mature SM8750 device) |
| ianchb userspace packages | https://github.com/ianchb/{xiaomi-mipps-auth, xiaomi-charger-mode, xiaomi-sheng-thp, xiaomi-pen-status, xiaomi-sheng-keyboard-helper, xiaomi-sheng-fingerprint} | Upstreams for the `userspace/` shallow forks (first five) + fingerprint (excluded from our set; reference only) |

### Phase-dependent

| Repository | URL | Why |
|---|---|---|
| AviderMin/ofrp_device_xiaomi_piano | https://github.com/AviderMin/ofrp_device_xiaomi_piano | Maintained OFRP recovery device tree for piano (branch fox_16.0; ADB, decryption, display, OTG all working). The recovery vehicle for the full-partition backup, and a source of boot-format/partition facts. Derived from YuKongA/twrp_device_xiaomi_sm8750_thales. |
| XEC Mainline | https://github.com/Xlie-Electronic-Customs/linux | Adreno 830 kernel support (commit a6ec84af) for the GPU phase |
| Mesa | https://gitlab.freedesktop.org/mesa/mesa | freedreno Gen8 userspace; GPU bug triage |
| Qualcomm Adreno 830 UMD | qualcomm developer pages (search "Adreno 830 Linux UMD") | Official Vulkan 1.4 userspace fallback (a .deb download, not a clone) |

### Optional / archive

| Repository | URL | Why |
|---|---|---|
| alghiffaryfa19/Linux-xiaomi-sheng | https://github.com/alghiffaryfa19/Linux-xiaomi-sheng | Original build scripts that debian-sheng derives from (history) |
| Mu-Silicium | GitHub search "Mu-Silicium" | UEFI route alternative — NOT on our critical path (we boot via stock abl) |
| xiaomi-8750 org (xuanyuan, SM8750 sibling) | https://github.com/orgs/xiaomi-8750/repositories | ROM-build infra for the SM8750 sibling device "xuanyuan". `proprietary_vendor_xiaomi_xuanyuan` is a cross-device firmware-naming reference (esp. a8xx GPU firmware). Browse on demand; do not bulk-clone the blobs repo. |
| sm8750-mainline org | https://github.com/sm8750-mainline | Evaluated 2026-09 and dismissed: `linux` is a near-vanilla v6.16 fork with no piano/device/a8xx work; `LunarisOS-android` is an Android tree. Do not use as a base — our baseline is far ahead. |

Web-only resources (no clone needed): linux-msm SM8750 status page, pmOS wiki pages
(Xiaomi_Pad_8_Pro / SM8750 / Mainlining), lore.kernel.org a8xx patch series.

## Hard rules

1. `local/` and any proprietary blob (firmware, keys, partition images) never enters any
   git repo. `.gitignore` has a safety net; bypassing requires `git add -f` plus a stated
   justification.
2. `out/` never enters git. All flashable artifacts must come out of `debian-piano` builds
   (reproducibility: no hand-assembled images).
3. No AGENTS.md/CLAUDE.md/device-firmware files inside component repos.
4. All userspace packages are shallow forks — nothing is consumed "directly from upstream".
   Shallow-fork discipline: track upstream on `main`; keep the piano diff as a minimal,
   ideally data-only patch set; `git diff upstream/main --stat` must stay reviewable at a
   glance; rebase regularly; upstream the diff as soon as upstream gains a profile/config
   mechanism; a growing logic diff means it is becoming a deep fork — refactor it back to
   data-only or accept the maintenance cost explicitly.
5. Device-flashing safety rules (full list, mandatory whenever a real device is attached):
   - Only ever write `boot_b`, `dtbo_b`, or userdata-derived partitions. NEVER flash
     abl/xbl/xbl_config/tz/hyp/devcfg or any other bootloader-chain partition.
   - Prefer `fastboot boot boot.img` (RAM boot, zero-risk iteration); flash `boot_b` only
     if RAM boot is unsupported.
   - Run `fastboot getvar current-slot` before any write.
   - Slot-A stock Android must remain bootable at all times.
   - Keep a fastboot ROM package in `local/rom/` for rescue re-flashing. Note: EDL (9008)
     is likely unavailable on piano (the OFRP tree sets `TW_HAS_EDL_MODE := false`) — the
     real safety net is never touching the bootloader chain and keeping slot A bootable.
6. Bootloader unlock and account eligibility are the user's responsibility — never an
   agent task.
7. License posture: never copy files from unlicensed repos (`refer/` is read-only
   inspiration); vendored third-party code keeps its upstream license (e.g. AOSP
   mkbootimg, Apache-2.0); kernel cherry-picks preserve original authorship and
   `Signed-off-by` (`git cherry-pick -x`, GPL-2.0).

## Language policy

English for commit messages and all repo-tracked content (docs, script comments,
component-repo commits and patch series).

## Toolchain & build

- Requirements: clang + lld (recommended; pass `LLVM=1`) or an aarch64 cross GCC;
  plus flex, bison, cpio, rsync.
- Kernel build (inside `linux-piano/`):

  ```
  make ARCH=arm64 LLVM=1 O=out piano_defconfig
  make ARCH=arm64 LLVM=1 O=out -j$(nproc) Image dtbs modules
  ```

- All device-derived inputs (ROM package, extracted firmware, sensors data, backups) live
  under `local/` on each contributor's machine — they are never committed.

## Git conventions

- Umbrella branch: `main`. Commit style: conventional English (`docs: …`, `scripts: …`,
  `chore: …`).
- Kernel repo commit labels:
  - `BACKPORT: <subject> (lore: <url>)` — pending-upstream patch series; keep original
    authorship; backport whole series only, never hand-splice them.
  - `BACKPORT-XEC: …` — Adreno 830/a8xx commits from the XEC tree; cite the source hash.
  - `piano: <area> …` — own code, written to upstreamable standard (dt-binding present,
    checkpatch clean) for eventual linux-arm/ml submission.
- After any rebase or upstream sync, re-verify the build (dtb compile is the minimum bar).

## Component repo bootstrap

- `linux-piano`: based on vanilla stable v7.2.6 (NOT on ianchb's tree). The GitHub repo
  is a **fork of gregkh/linux renamed to `linux-piano`** — v7.2.6 is the tip of gregkh's
  `linux-7.2.y` branch, so all objects exist server-side and pushes are ref-only
  (the fork is an object-sharing mechanism, not a code-identity statement; the
  canonical upstream is kernel.org). Local remotes: `upstream` = kernel.org stable,
  `gregkh` = gregkh/linux (transport mirror for deepening history), `sheng` =
  ianchb/sm8550-mainline (cherry-pick source: nt36532e panel, NVT touch SPI, nanosic
  keyboard), `origin` = our repo. The local clone stays shallow (depth 1) until history
  is needed (`git fetch gregkh linux-7.2.y --unshallow`). Branches: `master` (vanilla
  v7.2.6 mirror) + `piano-<base>` device line (currently `piano-7.2.6`, the default
  branch; each stable bump opens a new `piano-<base>` branch — never force-push old
  ones). Cherry-picks keep original authorship and `Signed-off-by`
  (`git cherry-pick -x`). GPL-2.0; proprietary blobs never enter the repo.
- `debian-piano`: written **from scratch** in the empty repo
  https://github.com/bluseliu50/debian-piano (no file copying from unlicensed repos;
  `refer/xiaomi-sheng_3rd/debian-sheng` is read-only reference; mkbootimg is vendored
  from AOSP with its Apache-2.0 license intact). Produces rootfs + boot.img via
  GitHub Actions; proprietary firmware blobs never enter the repo (bring-your-own-blobs
  from `local/`).
- `userspace/*`: shallow forks of the ianchb packages, created **per-phase on demand**
  (P4: mipps-auth + charger-mode; P5-A: keyboard-helper; P5-B: thp + pen-status; thp
  may be pulled into P2 early if kernel-side touch events prove incomplete).
