#!/usr/bin/env bash
# Build the isolated ADSP trial image from the milestone-1 descendants.
#
# This deliberately has its own entry point: the milestone-1 USB image keeps
# its original no-module/no-firmware behavior, while this image stages only
# the PAS driver closure and the extracted ADSP firmware.

set -euo pipefail

die() {
    echo "build-adsp-test-image: error: $*" >&2
    exit 1
}

JOBS=$(nproc)
while [ $# -gt 0 ]; do
    case "$1" in
        --jobs) JOBS=${2-}; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done
case "$JOBS" in ''|*[!0-9]*) die "--jobs must be a positive integer" ;; esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"

WORKSPACE=$(cd "$(dirname "$0")/.." && pwd)
KERNEL="$WORKSPACE/linux-piano"
DEBIAN="$WORKSPACE/debian-piano"
KERNEL_OUT="$KERNEL/out/adsp-m1"
OUTPUT_DIR="$DEBIAN/out/adsp-m1"
FIRMWARE_SRC="$WORKSPACE/local/firmware/non-hlos/image"
FIRMWARE_DIR="$KERNEL_OUT/firmware"

[ "$(git -C "$KERNEL" branch --show-current)" = piano/adsp-m1 ] \
    || die "linux-piano must be on piano/adsp-m1"
[ "$(git -C "$DEBIAN" branch --show-current)" = bp/adsp-m1 ] \
    || die "debian-piano must be on bp/adsp-m1"
[ -z "$(git -C "$KERNEL" status --porcelain)" ] \
    || die "linux-piano has uncommitted changes"
[ -z "$(git -C "$DEBIAN" status --porcelain)" ] \
    || die "debian-piano has uncommitted changes"
[ -d "$FIRMWARE_SRC" ] || die "missing extracted firmware: $FIRMWARE_SRC"

TOOLS="$DEBIAN/out/arm64-tools"
BUSYBOX="$TOOLS/busybox"
DROPBEAR_TREE="$TOOLS/dropbear/tree"
[ -x "$BUSYBOX/busybox" ] || die "run fetch-arm64-tools.sh first"
[ -x "$DROPBEAR_TREE/usr/sbin/dropbear" ] || die "run fetch-arm64-tools.sh first"

mkdir -p "$KERNEL_OUT" "$OUTPUT_DIR" "$FIRMWARE_DIR/qcom/sm8750"

if [ ! -s "$KERNEL_OUT/.config" ]; then
    make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" piano_defconfig
fi

echo "build-adsp-test-image: building kernel modules and Image"
make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" -j"$JOBS" Image modules

KVER=$(sed -n 's/^#define UTS_RELEASE \"\(.*\)\"$/\1/p' \
       "$KERNEL_OUT/include/generated/utsrelease.h")
[ -n "$KVER" ] || die "cannot determine kernel release"

# qcom_q6v5_pas is a module. Keep its provider closure explicit and small;
# depmod in build-initramfs.sh resolves the inter-module ordering.
MODULES=()
for rel in \
    drivers/remoteproc/qcom_common.ko \
    drivers/remoteproc/qcom_q6v5.ko \
    drivers/remoteproc/qcom_q6v5_pas.ko \
    drivers/remoteproc/qcom_pil_info.ko \
    drivers/remoteproc/qcom_sysmon.ko \
    drivers/rpmsg/qcom_glink_smem.ko \
    drivers/soc/qcom/qcom_pd_mapper.ko \
    drivers/soc/qcom/qcom_pdr_msg.ko \
    drivers/soc/qcom/pdr_interface.ko \
    drivers/soc/qcom/qmi_helpers.ko \
    net/qrtr/qrtr.ko \
    net/qrtr/qrtr-smd.ko; do
    path="$KERNEL_OUT/$rel"
    [ -s "$path" ] || die "required module missing: $path"
    MODULES+=("$path")
done

for name in adsp.mdt adsp_dtb.mdt; do
    [ -s "$FIRMWARE_SRC/$name" ] || die "missing ADSP firmware: $FIRMWARE_SRC/$name"
done
cp -a "$FIRMWARE_SRC"/adsp.mdt "$FIRMWARE_SRC"/adsp.b* \
      "$FIRMWARE_SRC"/adsp_dtb.mdt "$FIRMWARE_SRC"/adsp_dtb.b* \
      "$FIRMWARE_DIR/qcom/sm8750/"

INITRAMFS="$KERNEL_OUT/initramfs.cpio.gz"
echo "build-adsp-test-image: building ADSP-only initramfs"
INITRAMFS_ARGS=(
    "$DEBIAN/scripts/build-initramfs.sh"
    --busybox "$BUSYBOX" --dropbear-tree "$DROPBEAR_TREE"
    --output "$INITRAMFS" --kernel-version "$KVER"
    --firmware-dir "$FIRMWARE_DIR" --compress gzip
)
for module in "${MODULES[@]}"; do
    INITRAMFS_ARGS+=(--module "$module")
done
"${INITRAMFS_ARGS[@]}"

"$KERNEL/scripts/config" --file "$KERNEL_OUT/.config" \
    --set-str CONFIG_INITRAMFS_SOURCE "$INITRAMFS"
make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" -j"$JOBS" Image

"$DEBIAN/scripts/build-test-bootimg.sh" \
    --kernel-dir "$KERNEL_OUT" --output-dir "$OUTPUT_DIR"

echo "build-adsp-test-image: complete: $OUTPUT_DIR"
