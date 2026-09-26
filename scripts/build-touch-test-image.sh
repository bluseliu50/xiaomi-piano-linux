#!/usr/bin/env bash
# Build the touch bring-up RAM-boot image (boot.img + dtbo.img).
#
# Usage: scripts/build-touch-test-image.sh [--jobs N]
#
# Kernel: linux-piano piano/touch-bringup, fresh object dir out/touch.
# Overlay: debian-piano boot/dtbo-piano-touch-v2.dts (milestone-1 USB/display
# base + mainline TLMM node, SE2 SPI, NT36532 touch node, ramoops layout).
# Initramfs: the milestone-1 debug environment plus the touch driver closure,
# both piano touch firmware blobs, piano-touch-test and piano-touch-view.
# Nothing touch related is loaded at boot; piano-touch-test loads it in
# stages. Output: debian-piano/out/touch-v2/{boot.img,dtbo.img,MANIFEST.txt}.

set -euo pipefail

die() {
    echo "build-touch-test-image: error: $*" >&2
    exit 1
}

JOBS=$(nproc)
while [ $# -gt 0 ]; do
    case "$1" in
        --jobs) JOBS=${2-}; shift 2 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
case "$JOBS" in ''|*[!0-9]*) die "--jobs must be a positive integer" ;; esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"

WORKSPACE=$(cd "$(dirname "$0")/.." && pwd)
KERNEL="$WORKSPACE/linux-piano"
DEBIAN="$WORKSPACE/debian-piano"
KERNEL_OUT="$KERNEL/out/touch"
OUTPUT_DIR="$DEBIAN/out/touch-v2"
TOUCH_FIRMWARE_SRC="$WORKSPACE/local/firmware/odm/firmware"
STAGE="$KERNEL_OUT/stage"

[ "$(git -C "$KERNEL" branch --show-current)" = piano/touch-bringup ] \
    || die "linux-piano must be on piano/touch-bringup"
[ "$(git -C "$DEBIAN" branch --show-current)" = bp/touch-bringup ] \
    || die "debian-piano must be on bp/touch-bringup"
[ -z "$(git -C "$KERNEL" status --porcelain)" ] \
    || die "linux-piano has uncommitted changes"
[ -z "$(git -C "$DEBIAN" status --porcelain)" ] \
    || die "debian-piano has uncommitted changes"
[ -d "$TOUCH_FIRMWARE_SRC" ] || die "missing extracted touch firmware: $TOUCH_FIRMWARE_SRC"

TOOLS="$DEBIAN/out/arm64-tools"
BUSYBOX="$TOOLS/busybox"
DROPBEAR_TREE="$TOOLS/dropbear/tree"
[ -x "$BUSYBOX/busybox" ] || die "run debian-piano/scripts/fetch-arm64-tools.sh first"
[ -x "$DROPBEAR_TREE/usr/sbin/dropbear" ] || die "run debian-piano/scripts/fetch-arm64-tools.sh first"

mkdir -p "$KERNEL_OUT" "$OUTPUT_DIR"

# Always start from the committed defconfig; the release string must match
# the committed tree before any module is stamped (vermagic).
make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" piano_defconfig
rm -f "$KERNEL_OUT/include/config/kernel.release" \
      "$KERNEL_OUT/include/generated/utsrelease.h" "$KERNEL_OUT/.version"
make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" prepare
find "$KERNEL_OUT" \( -name '*.mod.c' -o -name '*.ko' \) -delete

echo "build-touch-test-image: building kernel modules and Image"
make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" -j"$JOBS" Image modules

KVER=$(sed -n 's/^#define UTS_RELEASE \"\(.*\)\"$/\1/p' \
       "$KERNEL_OUT/include/generated/utsrelease.h")
[ -n "$KVER" ] || die "cannot determine kernel release"
case "$KVER" in *dirty*) die "kernel release $KVER is dirty" ;; esac

# Touch path closure; depmod in build-initramfs.sh resolves the order.
MODULES=()
for rel in \
    drivers/pinctrl/qcom/pinctrl-sm8750.ko \
    drivers/dma/qcom/gpi.ko \
    drivers/spi/spi-geni-qcom.ko \
    drivers/input/touchscreen/nt36532e/nt36532e_ts.ko \
    drivers/input/misc/uinput.ko; do
    path="$KERNEL_OUT/$rel"
    [ -s "$path" ] || die "required module missing: $path"
    [ "$(modinfo -F vermagic "$path")" = "$KVER SMP preempt mod_unload aarch64" ] \
        || die "stale vermagic in $path"
    MODULES+=("$path")
done

rm -rf "$STAGE"
mkdir -p "$STAGE/firmware/novatek"
for name in novatek_nt36532_piano_fw_csot.bin novatek_nt36532_piano_fw_boe.bin; do
    [ -s "$TOUCH_FIRMWARE_SRC/$name" ] || die "missing touch firmware: $TOUCH_FIRMWARE_SRC/$name"
    cp -a "$TOUCH_FIRMWARE_SRC/$name" "$STAGE/firmware/novatek/"
done

make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" headers_install \
    INSTALL_HDR_PATH="$STAGE/uapi"
"$DEBIAN/scripts/build-touch-view.sh" --uapi "$STAGE/uapi" \
    --output "$STAGE/piano-touch-view"

INITRAMFS="$KERNEL_OUT/initramfs.cpio.gz"
echo "build-touch-test-image: building the touch test initramfs"
INITRAMFS_ARGS=(
    "$DEBIAN/scripts/build-initramfs.sh"
    --busybox "$BUSYBOX" --dropbear-tree "$DROPBEAR_TREE"
    --output "$INITRAMFS" --kernel-version "$KVER"
    --firmware-dir "$STAGE/firmware" --touch-view "$STAGE/piano-touch-view"
    --compress gzip
)
for module in "${MODULES[@]}"; do
    INITRAMFS_ARGS+=(--module "$module")
done
"${INITRAMFS_ARGS[@]}"

"$KERNEL/scripts/config" --file "$KERNEL_OUT/.config" \
    --set-str CONFIG_INITRAMFS_SOURCE "$INITRAMFS"
make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" olddefconfig
make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" -j"$JOBS" Image

"$DEBIAN/scripts/build-test-bootimg.sh" \
    --kernel-dir "$KERNEL_OUT" --output-dir "$OUTPUT_DIR" \
    --dtbo-source "$DEBIAN/boot/dtbo-piano-touch-v2.dts"

{
    echo
    echo "touch bring-up sources:"
    echo "  umbrella     $(git -C "$WORKSPACE" rev-parse HEAD)"
    echo "  linux-piano  $(git -C "$KERNEL" rev-parse HEAD) ($KVER)"
    echo "  debian-piano $(git -C "$DEBIAN" rev-parse HEAD)"
    echo "on the device: piano-touch-test (stages 0-4, see --help)"
} >> "$OUTPUT_DIR/MANIFEST.txt"

echo "build-touch-test-image: complete: $OUTPUT_DIR"
