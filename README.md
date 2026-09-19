# xiaomi-piano-linux

Mainline Linux for the **Xiaomi Pad 8 Pro** (codename **piano**, Qualcomm SM8750 / Snapdragon 8 Elite, Adreno 830, Wi-Fi-only tablet).

Goal: a self-built Debian system — mainline kernel, rootfs, boot images — with **MVP = graphical desktop + GPU driver + charging & power management**. Everything is built from our own repositories; no hand-assembled images.

## How to build, run and test

### Kernel

```sh
git submodule update --init
scripts/build-kernel.sh                 # --jobs N --out DIR optional; defaults nproc, out/kernel
```

Exits non-zero if the submodule is missing, `piano_defconfig` is absent, the build fails, or the two piano artifacts (`Image`, `sm8750-xiaomi-piano.dtb`) were not produced. Manual equivalent inside `linux-piano/`:

```sh
make ARCH=arm64 LLVM=1 O=out piano_defconfig
make ARCH=arm64 LLVM=1 O=out -j$(nproc) Image dtbs modules
```

Device-tree validation (needs `dtschema`):

```sh
make ARCH=arm64 LLVM=1 O=out CHECK_DTBS=y qcom/sm8750-xiaomi-piano.dtb
```

### Rootfs (Debian trixie, arm64)

```sh
cd debian-piano
sudo scripts/build-rootfs.sh --suite trixie --output out/rootfs \
    [--firmware-dir /path/to/local/firmware | --allow-missing-firmware]
```

Fails with an explicit prerequisite list when `debootstrap`/root/network (or, on x86 hosts, `qemu-aarch64-static` + binfmt) are missing. Without `--firmware-dir` it refuses unless `--allow-missing-firmware` is passed; the firmware-less image records the gap in `/usr/share/xiaomi-piano/firmware-missing`. Outputs: `out/rootfs/rootfs/` tree + `build-manifest.txt` + `firmware-manifest.txt`.

### Debug initramfs (USB-NCM network + dropbear shell)

```sh
scripts/build-initramfs.sh \
    --busybox <dir with static busybox> \
    --dropbear <dir with dropbear + dropbearkey> \
    --output out/initramfs-piano.cpio.gz
```

The generated `/init` mounts pseudo-filesystems, brings up the configfs NCM gadget (gadget 10.42.0.2, DHCP pool 10.42.0.10–20), starts dropbear, and drops to a debug shell. It never writes any partition.

### Boot image (and its verification gate)

```sh
scripts/build-bootimg.sh \
    --kernel <Image> --ramdisk <uncompressed cpio> --dtb <dtb> \
    --header-version 4 --pagesize 4096 --ramdisk-compression lz4 \
    --output out/boot.img
```

Every parameter must be CONFIRMED in `boot/stock-boot-params.env` (provenance from the stock-ROM measurements); any UNVERIFIED parameter aborts the build. `--allow-unverified` produces a synthetic smoke artifact only, with a forced `synthetic-` filename prefix. Quick gate self-test:

```sh
# expect refusal with no --allow-unverified:
scripts/build-bootimg.sh --kernel K --ramdisk R --dtb D \
    --header-version 4 --pagesize 4096 --ramdisk-compression gzip \
    --output out/boot.img && echo "GATE BROKEN"
```

### Lint / CI

Local: `bash -n`/`shellcheck` on all scripts, `python3 -m py_compile mkbootimg/*.py`, `yamllint` + `actionlint` on workflows. CI (GitHub Actions, arm64 native): `lint` runs the same suite; `build` produces the initramfs, a firmware-less trixie/phosh rootfs tarball, and the synthetic boot-image smoke (including the UNVERIFIED-gate refusal check). Both are required checks on `debian-piano/main`.

## Repositories

| Repository | Role |
|---|---|
| [bluseliu50/xiaomi-piano-linux](https://github.com/bluseliu50/xiaomi-piano-linux) (this repo) | Umbrella: docs, orchestration scripts, submodule pointers |
| [bluseliu50/linux-piano](https://github.com/bluseliu50/linux-piano) | Kernel: fork of gregkh/linux, vanilla **v7.2.6** baseline + `piano-*` device branches |
| [bluseliu50/debian-piano](https://github.com/bluseliu50/debian-piano) | Rootfs / initramfs / boot-image builder (from scratch, MIT; vendored AOSP mkbootimg under Apache-2.0) |

## Directory layout

```
AGENTS.md        workspace guide (authoritative; read it first)
scripts/         cross-repo build entry points (build-kernel.sh)
linux-piano/     kernel submodule (branch piano-7.2.6)
debian-piano/    rootfs builder submodule (branch main)
local/           device extractions & proprietary firmware (gitignored, NEVER committed — irreplaceable device data)
out/             build outputs (gitignored)
```

## License & proprietary-content policy

- Docs and scripts in this repo: MIT unless stated otherwise.
- Kernel: GPL-2.0; cherry-picks preserve original authorship (`git cherry-pick -x`).
- **No proprietary blob ever enters any git repository.** Firmware is extracted from the user's own stock ROM into `local/` and injected at build time (`--firmware-dir`). `local/` is never committed.

## Device safety rules (mandatory with hardware attached)

1. Only ever write `boot_b`, `dtbo_b`, or userdata-derived partitions. NEVER flash `abl`/`xbl`/`xbl_config`/`tz`/`hyp`/`devcfg` or any bootloader-chain partition.
2. Prefer `fastboot boot boot.img` (RAM boot) for iteration.
3. `fastboot getvar current-slot` before any write; slot A stock Android must remain bootable at all times.
4. Keep a fastboot ROM package in `local/rom/` for rescue.
5. Bootloader unlock and account eligibility are the user's responsibility, never an agent task.

## Development workflow

All owned repositories enforce branch protection: PRs required (0 approvals while solo), conversations resolved, linear history, force pushes and deletions blocked; required CI checks where CI exists. Agents open PRs and read CI; **every merge is a human action**.
