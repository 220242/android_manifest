#!/usr/bin/env bash
#
# Khadas Edge1 - build the Android TV 14 platform and pack update.img.
#
#   usage: build.sh [tree-dir] [variant]
#
# This is the script the pipeline's "source build/envsetup.sh; lunch; m" step
# becomes. It is a script rather than three commands because the Rockchip
# update.img packaging has to run after m and needs the same environment.
#
set -euo pipefail

readonly TREE="${1:-$HOME/aosp-14-edge1}"
readonly VARIANT="${2:-userdebug}"
# Android 14's lunch takes <product>-<release>-<variant> and rejects anything
# else outright:
#
#   IFS="-" read -r product release variant <<< "$selection"
#   if [[ -z "$product" ]] || [[ -z "$release" ]] || [[ -z "$variant" ]]
#   then ... "Valid combos must be of the form <product>-<release>-<variant>"
#
# (build/envsetup.sh in android-14.0.0_r75, lines 809-820.) The release names
# come from build/release/release_config_map.mk; trunk_staging is the one AOSP's
# own products use, and core/release_config.mk falls back to it.
readonly RELEASE="${3:-trunk_staging}"
readonly TARGET="edge1_tv-${RELEASE}-${VARIANT}"

cd "$TREE"

# ccache pays for itself on the second build onwards.
if command -v ccache >/dev/null 2>&1; then
    export USE_CCACHE=1
    export CCACHE_EXEC="$(command -v ccache)"
    ccache -M 50G >/dev/null
fi

# Parallelism from available RAM, not just core count. Soong's Java steps take
# ~2GiB each; -j$(nproc) on a RAM-poor host is the most common cause of a build
# dying hours in with a bare "Killed" and no other message.
ram_gib=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
cores=$(nproc)
jobs=$(( ram_gib / 2 ))
(( jobs > cores )) && jobs=$cores
(( jobs < 1 )) && jobs=1
echo "==> ${cores} cores, ${ram_gib}GiB RAM -> -j${jobs}"

# AOSP's envsetup.sh, and the shell functions it defines, are not written to run
# under 'set -u'. It reads $TOP before anything assigns it, so the whole build
# ended on the very first line it sourced:
#
#   build/envsetup.sh: line 21: TOP: unbound variable
#
# -u stays off from here to the end: lunch and m are that same code. -e goes off
# too, because the build's exit status is wanted - a bare abort would lose the
# chance to point at the log.
set +eu
# shellcheck disable=SC1091
source build/envsetup.sh

lunch "$TARGET"
lunch_rc=$?
if [ "$lunch_rc" -ne 0 ]; then
    echo "lunch $TARGET failed (exit $lunch_rc)" >&2
    echo "the product is defined in device/khadas/edge/edge1_tv.mk and named by" >&2
    echo "device/khadas/edge/AndroidProducts.mk; both must be reachable from $TREE" >&2
    exit 1
fi

echo "==> building $TARGET"
m -j"$jobs" 2>&1 | tee "$TREE/build-${VARIANT}.log"
build_rc=${PIPESTATUS[0]}
if [ "$build_rc" -ne 0 ]; then
    echo "m failed (exit $build_rc); the errors are in $TREE/build-${VARIANT}.log" >&2
    exit "$build_rc"
fi
set -e

readonly OUT="$TREE/out/target/product/edge"
for img in system.img vendor.img super.img boot.img; do
    if [[ ! -f "$OUT/$img" ]]; then
        echo "expected $OUT/$img was not produced; check build-${VARIANT}.log" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# update.img
#
# Rockchip's flashable format, not an AOSP artifact: afptool packs the images
# listed in package-file into update.img, then rkImageMaker prepends the
# bootloader header that maskrom/loader mode expects. Both come from RKTools.
# ---------------------------------------------------------------------------
readonly RKTOOLS="$TREE/RKTools/linux/Linux_Pack_Firmware/rockdev"
if [[ ! -x "$RKTOOLS/afptool" ]]; then
    echo "afptool not found under $RKTOOLS; skipping update.img" >&2
    echo "images are in $OUT" >&2
    exit 0
fi

echo "==> packing update.img"
readonly PACK="$TREE/out/target/product/edge/rockdev"
mkdir -p "$PACK/Image"
cp "$TREE/device/khadas/edge/package-file" "$PACK/"
cp "$TREE/device/khadas/edge/parameter.txt" "$PACK/Image/"
for img in super.img boot.img vendor_boot.img recovery.img dtbo.img vbmeta.img misc.img; do
    [[ -f "$OUT/$img" ]] && cp "$OUT/$img" "$PACK/Image/"
done
cp "$TREE/rkbin/"*"MiniLoaderAll.bin" "$PACK/Image/MiniLoaderAll.bin" 2>/dev/null || true
cp "$TREE/u-boot/uboot.img" "$PACK/Image/uboot.img" 2>/dev/null || true

cd "$PACK"
"$RKTOOLS/afptool" -pack ./ ./update.raw.img
"$RKTOOLS/rkImageMaker" -RK330C ./Image/MiniLoaderAll.bin ./update.raw.img ./update.img -os_type:androidos
rm -f ./update.raw.img

echo
echo "update.img: $PACK/update.img ($(du -h ./update.img | cut -f1))"
echo "flash with: upgrade_tool uf $PACK/update.img   (board in maskrom mode)"
