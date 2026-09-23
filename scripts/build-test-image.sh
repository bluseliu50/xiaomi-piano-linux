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
REQUIRED_BRANCH=piano/subsys-bringup

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
    # --- subsystem payload: kernel modules + firmware + pd-locator -----------
    TOOLS="$DEBIAN/out/arm64-tools"
    BUSYBOX="$TOOLS/busybox"
    DROPBEAR_TREE="$TOOLS/dropbear/tree"
    APLAY_TREE="$TOOLS/aplay/tree"
    MUSL_SYSROOT="$TOOLS/musl-sysroot"
    FIRMWARE_DIR="$WORKSPACE/local/firmware"
    [ -x "$BUSYBOX/busybox" ] \
        || die "no staged busybox at $BUSYBOX (run debian-piano/scripts/fetch-arm64-tools.sh)"
    [ -x "$DROPBEAR_TREE/usr/sbin/dropbear" ] \
        || die "no staged dropbear tree at $DROPBEAR_TREE (run fetch-arm64-tools.sh)"
    [ -x "$APLAY_TREE/usr/bin/aplay" ] \
        || die "no staged aplay tree at $APLAY_TREE (run fetch-arm64-tools.sh)"
    [ -f "$MUSL_SYSROOT/usr/lib/libc.a" ] \
        || die "no musl sysroot at $MUSL_SYSROOT (run fetch-arm64-tools.sh)"
    for d in wifi-bt/ath12k/WCN7850 wifi-bt/qca non-hlos/image odm/firmware; do
        [ -d "$FIRMWARE_DIR/$d" ] || die "missing device firmware dir local/firmware/$d"
    done

    echo "build-test-image: building kernel modules"
    make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" -j"$JOBS" modules

    # Kernel release: read AFTER the build — utsrelease.h carries the
    # release of the tree that last built it, and a stale value here
    # silently misdirects modules_install/depmod into a wrong
    # lib/modules/<kver> directory (fatal one turn later).
    KVER=$(sed -n 's/^#define UTS_RELEASE "\(.*\)"$/\1/p' \
        "$KERNEL_OUT/include/generated/utsrelease.h")
    [ -n "$KVER" ] || die "cannot determine kernel release from utsrelease.h"

    # Module closure: install to a staging root, then resolve the curated
    # entry set with modprobe --show-depends so the packed set is always
    # self-contained regardless of Kconfig drift.
    MODSTAGE=$(mktemp -d "${TMPDIR:-/tmp}/piano-mods.XXXXXX")
    FWSTAGE=$(mktemp -d "${TMPDIR:-/tmp}/piano-fw.XXXXXX")
    trap 'rm -rf "$MODSTAGE" "$FWSTAGE"' EXIT
    make -C "$KERNEL" ARCH=arm64 LLVM=1 O="$KERNEL_OUT" \
        INSTALL_MOD_PATH="$MODSTAGE" modules_install >/dev/null
    depmod -b "$MODSTAGE" "$KVER"

    # Entry modules by name (initramfs/init loads them in staged order):
    #   A: qrtr + remoteproc + pmic-glink/battmgr   (adsp/cdsp/battery)
    #   B: spi + nt36532e                            (touch)
    #   C: snd-soc-sc8280xp closure                  (audio/audioreach)
    #   D: pwrseq + hci_uart + btqca                 (bluetooth)
    #   E: qmp-pcie phy + pcie-qcom + ath12k         (wlan, last)
    # NOTE: the audioreach DSP modules (q6apm/q6prm/lpass macros/
    # wcd939x/wsa884x) are DT soft dependencies of the machine driver —
    # modprobe --show-depends cannot see them, they must be listed here.
    # pcie-qcom is a bool symbol built =y; its probe defers on the
    # (modular) QMP phy, so loading the phy in stage E is what brings
    # PCIe up after the debug shell is alive.
    ENTRY_MODULES="ramoops qrtr qrtr-smd qcom_q6v5_pas pmic_glink qcom_battmgr \
                   spi-geni-qcom nt36532e_ts \
                   snd-soc-sc8280xp snd-q6dsp-common snd-q6apm \
                   q6apm-dai q6apm-lpass-dais q6prm q6prm-clocks \
                   snd-soc-lpass-macro-common snd-soc-lpass-rx-macro \
                   snd-soc-lpass-tx-macro snd-soc-lpass-va-macro \
                   snd-soc-lpass-wsa-macro \
                   snd-soc-wcd939x-sdw snd-soc-wsa884x \
                   pwrseq-qcom-wcn hci_uart btqca \
                   phy-qcom-qmp-pcie ath12k"
    MODLIST="$MODSTAGE/list"
    : > "$MODLIST"
    for m in $ENTRY_MODULES; do
        modprobe -S "$KVER" -d "$MODSTAGE" --show-depends "$m" 2>>"$MODSTAGE/modprobe.err" \
            | awk '/^insmod /{print $2}' >> "$MODLIST" \
            || echo "build-test-image: WARNING: modprobe cannot resolve '$m'" >&2
    done
    sort -u "$MODLIST" -o "$MODLIST"
    NMODS=$(wc -l < "$MODLIST")
    [ "$NMODS" -ge 30 ] \
        || die "module closure has only $NMODS modules — expected 30+ (see $MODSTAGE/modprobe.err)"
    echo "build-test-image: module closure: $NMODS modules"
    MOD_ARGS=()
    # build-initramfs.sh strips the "linux-piano/out/" prefix from module
    # paths; translate the staging-root closure paths back to kernel-out
    # form so the packing lands at lib/modules/<kver>/kernel/...
    while IFS= read -r ko; do
        rel=${ko#*/lib/modules/$KVER/kernel/}
        [ "$rel" != "$ko" ] || die "unexpected module path: $ko"
        MOD_ARGS+=(--module "$KERNEL_OUT/$rel")
    done < "$MODLIST"

    # Firmware staging in the layout build-initramfs.sh consumes:
    #   novatek/*.bin  qca/  ath12k/  qcom/sm8750/{adsp,cdsp}*.mbn+bNN
    mkdir -p "$FWSTAGE/novatek" "$FWSTAGE/qcom/sm8750"
    cp "$FIRMWARE_DIR"/odm/firmware/novatek_nt36532_piano_fw_*.bin "$FWSTAGE/novatek/"
    cp -a "$FIRMWARE_DIR/wifi-bt/qca" "$FWSTAGE/"
    cp -a "$FIRMWARE_DIR/wifi-bt/ath12k" "$FWSTAGE/"
    # The stock NON-HLOS names adsp/cdsp segments <name>.mdt + <name>.bNN;
    # the DT asks for qcom/sm8750/<name>.mbn and the kernel MDT loader
    # resolves <name>.mbn + <name>.bNN automatically.
    for f in "$FIRMWARE_DIR"/non-hlos/image/adsp* "$FIRMWARE_DIR"/non-hlos/image/cdsp*; do
        base=$(basename "$f")
        case "$base" in
            *.mdt) install -m 0644 "$f" "$FWSTAGE/qcom/sm8750/${base%.mdt}.mbn" ;;
            *)     install -m 0644 "$f" "$FWSTAGE/qcom/sm8750/$base" ;;
        esac
    done
    echo "build-test-image: staged firmware: $(find "$FWSTAGE" -type f | wc -l) files"

    # piano-pd-locator: static aarch64 build against the staged musl sysroot
    PD_LOCATOR_BIN="$MODSTAGE/piano-pd-locator"
    clang --target=aarch64-linux-musl --sysroot="$MUSL_SYSROOT" -Os -Wall -Wextra \
        -fno-stack-protector -fno-asynchronous-unwind-tables \
        -c "$DEBIAN/initramfs/pd-locator/piano-pd-locator.c" -o "$MODSTAGE/pd-locator.o" \
        || die "pd-locator compile failed"
    ld.lld -o "$PD_LOCATOR_BIN" --sysroot="$MUSL_SYSROOT" -static \
        "$MUSL_SYSROOT/usr/lib/crt1.o" "$MODSTAGE/pd-locator.o" "$MUSL_SYSROOT/usr/lib/libc.a" \
        || die "pd-locator link failed"
    file "$PD_LOCATOR_BIN" | grep -q 'ARM aarch64' \
        || die "pd-locator did not build as an arm64 ELF"
    echo "build-test-image: built piano-pd-locator ($(stat -c%s "$PD_LOCATOR_BIN") bytes)"

    echo "build-test-image: building initramfs -> $INITRAMFS"
    "$DEBIAN/scripts/build-initramfs.sh" \
        --busybox "$BUSYBOX" --dropbear-tree "$DROPBEAR_TREE" \
        --aplay-tree "$APLAY_TREE" --pd-locator "$PD_LOCATOR_BIN" \
        --kernel-version "$KVER" \
        "${MOD_ARGS[@]}" \
        --firmware-dir "$FWSTAGE" \
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
