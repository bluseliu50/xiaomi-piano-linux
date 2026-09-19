#!/usr/bin/env bash
# build-test-image.sh — one-command builder for the piano RAM-boot test
# image, tying the two component repos together from the workspace root.
#
# Usage:
#   scripts/build-test-image.sh [--jobs N] [--kernel-out DIR]
#       [--output-dir DIR] [--authorized-keys FILE]
#       [--root-password PASS] [--skip-kernel-build]
#
# Why this lives in the umbrella repo: the test image consumes artifacts
# from BOTH component repos (linux-piano kernel outputs + debian-piano
# packaging scripts) plus local/ firmware. Per the workspace layout,
# cross-repo orchestration belongs here (scripts/), NOT inside linux-piano
# (a kernel-only fork kept clean for upstream) or hardcoded with relative
# ../ paths inside debian-piano.
#
# Steps:
#   1. Refuses to run unless linux-piano is on piano/test-bringup (the
#      display+touch integration branch this image is defined for).
#   2. Builds the kernel (piano_defconfig + Image dtbs modules) into
#      linux-piano/out (override with --kernel-out).
#   3. Stages the arm64 userland (busybox + dropbear closure) if missing.
#   4. Runs debian-piano/scripts/build-test-bootimg.sh, which builds and
#      round-trip-verifies the five boot-image variants.
#
# Auth passthrough: --authorized-keys FILE or --root-password PASS
# (empty string = blank-password login). Default: a per-build ed25519 key.

set -euo pipefail

usage() {
    sed -n '2,20p' "$0"; exit 2
}

die() {
    echo "build-test-image: error: $*" >&2
    exit 1
}

JOBS=$(nproc)
KERNEL_OUT=""
OUTPUT_DIR=""
AUTHORIZED_KEYS=""
ROOT_PASSWORD=""
ROOT_PASSWORD_SET=0
SKIP_KERNEL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --jobs)             JOBS=${2-}; shift 2 ;;
        --kernel-out)       KERNEL_OUT=${2-}; shift 2 ;;
        --output-dir)       OUTPUT_DIR=${2-}; shift 2 ;;
        --authorized-keys)  AUTHORIZED_KEYS=${2-}; shift 2 ;;
        --root-password)    ROOT_PASSWORD=${2-}; ROOT_PASSWORD_SET=1; shift 2 ;;
        --skip-kernel-build) SKIP_KERNEL=1; shift ;;
        -h|--help)          usage ;;
        *) die "unknown option: $1" ;;
    esac
done

case "$JOBS" in ''|*[!0-9]*) die "--jobs must be a positive integer (got '$JOBS')" ;; esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"

WORKSPACE=$(cd "$(dirname "$0")/.." && pwd)
KERNEL="$WORKSPACE/linux-piano"
DEBIAN="$WORKSPACE/debian-piano"
FIRMWARE="$WORKSPACE/local/firmware"
REQUIRED_BRANCH=piano/test-bringup

[ -d "$KERNEL/.git" ] || [ -f "$KERNEL/.git" ] \
    || die "linux-piano submodule not found at $KERNEL (git submodule update --init)"
[ -d "$DEBIAN/.git" ] || [ -f "$DEBIAN/.git" ] \
    || die "debian-piano submodule not found at $DEBIAN"
[ -x "$DEBIAN/scripts/build-test-bootimg.sh" ] \
    || die "$DEBIAN does not carry build-test-bootimg.sh (branch too old?)"
[ -d "$FIRMWARE/odm/firmware" ] \
    || die "touch firmware missing under $FIRMWARE (P0-A extraction)"

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

echo "build-test-image: kernel branch=$BRANCH commit=$COMMIT out=$KERNEL_OUT"

if [ "$SKIP_KERNEL" != 1 ]; then
    make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" piano_defconfig
    make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" -j"$JOBS" Image dtbs modules
fi

for f in \
    "$KERNEL_OUT/arch/arm64/boot/Image" \
    "$KERNEL_OUT/arch/arm64/boot/dts/qcom/sm8750-xiaomi-piano.dtb" \
    "$KERNEL_OUT/drivers/input/touchscreen/nt36532e/nt36532e_ts.ko" \
    "$KERNEL_OUT/drivers/spi/spi-geni-qcom.ko" \
    "$KERNEL_OUT/include/generated/utsrelease.h"; do
    [ -s "$f" ] || die "expected kernel artifact missing (build first?): $f"
done

ARGS=(
    --kernel-dir "$KERNEL_OUT"
    --firmware-dir "$FIRMWARE"
    --output-dir "$OUTPUT_DIR"
)
[ -n "$AUTHORIZED_KEYS" ] && ARGS+=(--authorized-keys "$AUTHORIZED_KEYS")
[ "$ROOT_PASSWORD_SET" = 1 ] && ARGS+=(--root-password "$ROOT_PASSWORD")

"$DEBIAN/scripts/build-test-bootimg.sh" "${ARGS[@]}"

echo
echo "build-test-image: complete. Boot order and safety rules:"
echo "  docs/device-bringup-runbook.md  (fastboot boot only, nothing is flashed)"
echo "  images + MANIFEST: $OUTPUT_DIR"
