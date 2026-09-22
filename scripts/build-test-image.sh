#!/usr/bin/env bash
# build-test-image.sh — one-command builder for the piano RAM-boot test
# image, tying the two component repos together from the workspace root.
#
# Usage:
#   scripts/build-test-image.sh [--jobs N] [--kernel-out DIR]
#       [--output-dir DIR] [--skip-kernel-build]
#
# Why this lives in the umbrella repo: the test image consumes artifacts
# from BOTH component repos (linux-piano kernel outputs + debian-piano
# packaging scripts). Per the workspace layout, cross-repo orchestration
# belongs here (scripts/), NOT inside linux-piano or hardcoded with
# relative ../ paths inside debian-piano.
#
# Produces exactly THREE deliverables in --output-dir (packed and
# round-trip-verified by debian-piano/scripts/build-test-bootimg.sh):
#   boot.img  dtbo.img  MANIFEST.txt
#
# Steps:
#   1. Refuses to run unless linux-piano is on piano/test-bringup (the
#      branch this image is defined for) and the tree is clean.
#   2. Builds the debug initramfs (busybox + telnetd NCM environment).
#      Modules/firmware are deliberately NOT packed: ABL concatenates the
#      CURRENT SLOT's stock vendor ramdisk after ours, which already
#      carries the flat .ko set (runbook §7.3).
#   3. Points CONFIG_INITRAMFS_SOURCE at it in the PRESERVED out/.config
#      and builds Image. An existing out/.config is NEVER regenerated:
#      it carries hand-accumulated boot-critical options (golden copy:
#      linux-piano/out/usb31-golden.config; defconfig pinning: branch
#      piano/config-boot-criticals). A silent `make piano_defconfig`
#      over it once produced gray-screen kernels for a whole evening.
#   4. Runs debian-piano/scripts/build-test-bootimg.sh.

set -euo pipefail

usage() {
    sed -n '2,27p' "$0"; exit 2
}

die() {
    echo "build-test-image: error: $*" >&2
    exit 1
}

JOBS=$(nproc)
KERNEL_OUT=""
OUTPUT_DIR=""
SKIP_KERNEL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --jobs)              JOBS=${2-}; shift 2 ;;
        --kernel-out)        KERNEL_OUT=${2-}; shift 2 ;;
        --output-dir)        OUTPUT_DIR=${2-}; shift 2 ;;
        --skip-kernel-build) SKIP_KERNEL=1; shift ;;
        -h|--help)           usage ;;
        *) die "unknown option: $1" ;;
    esac
done

case "$JOBS" in ''|*[!0-9]*) die "--jobs must be a positive integer (got '$JOBS')" ;; esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"

WORKSPACE=$(cd "$(dirname "$0")/.." && pwd)
KERNEL="$WORKSPACE/linux-piano"
DEBIAN="$WORKSPACE/debian-piano"
REQUIRED_BRANCH=piano/test-bringup

[ -d "$KERNEL/.git" ] || [ -f "$KERNEL/.git" ] \
    || die "linux-piano submodule not found at $KERNEL (git submodule update --init)"
[ -d "$DEBIAN/.git" ] || [ -f "$DEBIAN/.git" ] \
    || die "debian-piano submodule not found at $DEBIAN"
[ -x "$DEBIAN/scripts/build-test-bootimg.sh" ] \
    || die "$DEBIAN does not carry build-test-bootimg.sh (branch too old?)"

BRANCH=$(git -C "$KERNEL" rev-parse --abbrev-ref HEAD)
COMMIT=$(git -C "$KERNEL" rev-parse --short HEAD)
if [ "$BRANCH" != "$REQUIRED_BRANCH" ]; then
    die "linux-piano is on '$BRANCH' ($COMMIT); this image requires $REQUIRED_BRANCH
      cd linux-piano && git checkout $REQUIRED_BRANCH
(booting another branch's kernel would silently change what is being tested)"
fi
if [ -n "$(git -C "$KERNEL" status --porcelain)" ]; then
    die "linux-piano has uncommitted changes — commit or stash first"
fi

KERNEL_OUT=${KERNEL_OUT:-$KERNEL/out}
KERNEL_OUT=$(realpath -m "$KERNEL_OUT")
OUTPUT_DIR=${OUTPUT_DIR:-$DEBIAN/out/test-image}
INITRAMFS="$KERNEL_OUT/initramfs.cpio.gz"

echo "build-test-image: kernel branch=$BRANCH commit=$COMMIT out=$KERNEL_OUT"

# --- kernel config: PRESERVE an existing out/.config --------------------------
# Only generate when absent; the critical-option gate below then fails
# loudly instead of silently shipping a crippled kernel.
if [ "$SKIP_KERNEL" != 1 ] && [ ! -s "$KERNEL_OUT/.config" ]; then
    echo "build-test-image: no out/.config found — generating piano_defconfig (first run)"
    make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" piano_defconfig
fi

if [ "$SKIP_KERNEL" != 1 ]; then
    # --- debug initramfs -------------------------------------------------------
    TOOLS="$DEBIAN/out/arm64-tools"
    BUSYBOX="$TOOLS/busybox"
    DROPBEAR_TREE="$TOOLS/dropbear/tree"
    [ -x "$BUSYBOX/busybox" ] \
        || die "no staged busybox at $BUSYBOX (run debian-piano/scripts/fetch-arm64-tools.sh)"
    [ -x "$DROPBEAR_TREE/usr/sbin/dropbear" ] \
        || die "no staged dropbear tree at $DROPBEAR_TREE (run fetch-arm64-tools.sh)"

    echo "build-test-image: building initramfs -> $INITRAMFS"
    "$DEBIAN/scripts/build-initramfs.sh" \
        --busybox "$BUSYBOX" --dropbear-tree "$DROPBEAR_TREE" \
        --output "$INITRAMFS" --compress gzip

    # --- embed it into the kernel image ----------------------------------------
    echo "build-test-image: embedding initramfs via CONFIG_INITRAMFS_SOURCE"
    "$KERNEL/scripts/config" --file "$KERNEL_OUT/.config" \
        --set-str CONFIG_INITRAMFS_SOURCE "$INITRAMFS"
    # NOTE: no olddefconfig on purpose — it can silently drop the
    # FONT_TER16x32 choice; the config is a complete valid config as-is.
fi

# --- critical-option gate (the 09-22 lesson, now enforced) ---------------------
if [ "$SKIP_KERNEL" != 1 ]; then
    absent=()
    for pair in CONFIG_CMDLINE_FORCE=y CONFIG_DRM_SIMPLEDRM=y \
                CONFIG_FRAMEBUFFER_CONSOLE=y CONFIG_FONT_TER16x32=y \
                CONFIG_SM_TCSRCC_8750=y; do
        grep -qxF "$pair" "$KERNEL_OUT/.config" || absent+=("$pair")
    done
    grep -q '^CONFIG_INITRAMFS_SOURCE="' "$KERNEL_OUT/.config" \
        || absent+=('CONFIG_INITRAMFS_SOURCE=<set>')
    if [ "${#absent[@]}" -gt 0 ]; then
        printf 'build-test-image: out/.config lost boot-critical options:\n' >&2
        printf '  %s\n' "${absent[@]}" >&2
        die "restore the golden config (linux-piano/out/usb31-golden.config) or merge branch piano/config-boot-criticals"
    fi
fi

if [ "$SKIP_KERNEL" != 1 ]; then
    make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" -j"$JOBS" Image
fi

for f in "$KERNEL_OUT/arch/arm64/boot/Image" \
         "$KERNEL_OUT/include/generated/utsrelease.h"; do
    [ -s "$f" ] || die "expected kernel artifact missing (build first?): $f"
done

"$DEBIAN/scripts/build-test-bootimg.sh" \
    --kernel-dir "$KERNEL_OUT" --output-dir "$OUTPUT_DIR"

echo
echo "build-test-image: complete. Deliverables (RAM boot; only dtbo_b is flashed):"
echo "  $OUTPUT_DIR/boot.img"
echo "  $OUTPUT_DIR/dtbo.img"
echo "  $OUTPUT_DIR/MANIFEST.txt   (recipe + safety notes)"
