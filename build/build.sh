#!/usr/bin/env bash
#
# Khadas Edge1 - build the Android TV 14 platform and stage the flash pack.
#
#   usage: build.sh [tree-dir] [variant]
#
# This is the script the pipeline's "source build/envsetup.sh; lunch; m" step
# becomes. It is a script rather than three commands because the flash pack has to
# be assembled after m, from the same environment.
#
set -euo pipefail

# shellcheck source=build/lib-tree.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-tree.sh"
readonly TREE="${1:-$(edge1_default_tree)}"
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
#
# CCACHE_DIR has to be set, and has to be inside out/. Without it ccache uses
# $HOME/.cache/ccache, and Android 14 runs ninja with the source tree - and
# everything else outside $OUT_DIR - bind-mounted read-only, so the first
# compile died at target 151 of 167136 with:
#
#   ccache: error: Failed to create directory /home/builder/.cache/ccache/tmp:
#   Read-only file system
#   Write to a read-only file system detected. Possible fixes include
#   1. Generate file directly to out/ which is ReadWrite, #recommend solution
#   2. BUILD_BROKEN_SRC_DIR_RW_ALLOWLIST := ... #discouraged
#   3. BUILD_BROKEN_SRC_DIR_IS_WRITABLE := true #highly discouraged
#
# This is fix 1, the one the build itself recommends: out/ is the one writable
# tree inside the sandbox, so the cache lives there. ccache's temp dir follows
# CCACHE_DIR, so that stops writing to $HOME too.
#
# ccache is a plain compiler wrapper here, not a build-system feature:
# core/ccache.mk only sets CC_WRAPPER/CXX_WRAPPER when CCACHE_EXEC is set, which
# is why both variables are needed - USE_CCACHE alone does nothing since AOSP
# dropped its ccache prebuilt.
if command -v ccache >/dev/null 2>&1; then
    export USE_CCACHE=1
    export CCACHE_EXEC="$(command -v ccache)"
    export CCACHE_DIR="$TREE/out/ccache"
    mkdir -p "$CCACHE_DIR"
    # The same directory written into ccache's own config, in both places ccache
    # looks for it: $CCACHE_DIR/ccache.conf when CCACHE_DIR is set, and the XDG
    # path when it is not. Soong sanitises the environment it hands to ninja, so
    # if CCACHE_DIR does not survive that, the config still keeps the cache out
    # of the read-only $HOME. max_size goes in the file for the same reason -
    # "ccache -M" only writes it to whichever config is primary right now.
    for conf in "$CCACHE_DIR/ccache.conf" "$HOME/.config/ccache/ccache.conf"; do
        mkdir -p "$(dirname "$conf")"
        printf 'cache_dir = %s\nmax_size = 50G\n' "$CCACHE_DIR" > "$conf"
    done
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

# droid plus one host tool. simg2img is built only as part of otatools
# (core/Makefile:5561), so a plain "m" does not produce it - and it is what
# build-images.sh needs if an image ever comes out Android-sparse again. Naming it
# here costs a few seconds of host compile and means the SD image stage can never be
# blocked on a tool that has to be built from inside a lunched shell. An unknown
# target fails at the end of the ninja parse, in seconds, not hours in.
echo "==> building $TARGET"
m -j"$jobs" droid simg2img 2>&1 | tee "$TREE/build-${VARIANT}.log"
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
# Flash pack.
#
# Not update.img. That is Rockchip's format - afptool packs the images listed in
# package-file, then rkImageMaker prepends the header their maskrom loader
# expects - and it needs the BSP u-boot, rkbin's loader and RKTools, none of which
# this path uses. Mainline U-Boot boots an ordinary GPT.
#
# So what gets produced here is the set of images plus a script that writes them,
# meant to run on the board itself from a Linux session - which this board has,
# since it already boots OpenWrt from the same eMMC. That is deliberately the
# lowest-risk way in: no maskrom mode, no vendor flashing tool, and the existing
# bootloader stays untouched.
# ---------------------------------------------------------------------------
readonly PACK="$OUT/edge1-flash"
readonly LAYOUT="$TREE/device/khadas/edge/flash/partitions.tsv"

echo "==> staging the flash pack"
rm -rf "$PACK"
mkdir -p "$PACK"

missing=0
while IFS=$'\t' read -r name size image; do
    case "$name" in ''|\#*) continue ;; esac
    [[ "$image" == "-" ]] && continue
    if [[ -f "$OUT/$image" ]]; then
        cp "$OUT/$image" "$PACK/"
    else
        echo "  missing $image" >&2
        missing=$((missing+1))
    fi
done < "$LAYOUT"
(( missing == 0 )) || { echo "$missing images missing; not writing a flash script" >&2; exit 1; }

# The script is generated rather than committed so that the layout lives in one
# place: partitions.tsv. sgdisk sizes are in MiB and the first partition starts at
# 16MiB, leaving the raw sectors mainline U-Boot occupies alone.
{
    echo '#!/bin/sh'
    echo '# Generated by build/build.sh from device/khadas/edge/flash/partitions.tsv'
    echo '#'
    echo '# Run this ON THE BOARD, from a Linux userspace (the OpenWrt/Armbian install'
    echo '# it already boots), with this directory present. It repartitions the eMMC and'
    echo '# writes the Android images. Everything on the eMMC is lost.'
    echo '#'
    echo '# The bootloader area (sectors 64 and 16384) is not touched: the U-Boot that is'
    echo '# already there is what boots this.'
    echo 'set -e'
    echo 'DEV="${1:-/dev/mmcblk2}"'
    echo '[ -b "$DEV" ] || { echo "no such block device: $DEV" >&2; exit 1; }'
    echo 'command -v sgdisk >/dev/null || { echo "sgdisk not found" >&2; exit 1; }'
    echo 'echo "This erases everything on $DEV. Ctrl-C now if that is not what you want."'
    echo 'sleep 5'
    echo 'sgdisk --zap-all "$DEV"'
    n=1
    start=16
    while IFS=$'\t' read -r name size image; do
        case "$name" in ''|\#*) continue ;; esac
        if [[ "$size" == "rest" ]]; then
            echo "sgdisk --new=$n:${start}M:0 --change-name=$n:$name \"\$DEV\""
        else
            echo "sgdisk --new=$n:${start}M:+${size}M --change-name=$n:$name \"\$DEV\""
            start=$(( start + size ))
        fi
        n=$(( n + 1 ))
    done < "$LAYOUT"
    echo 'partprobe "$DEV" 2>/dev/null || blockdev --rereadpt "$DEV" 2>/dev/null || true'
    echo 'sleep 2'
    # Nothing Android-sparse may be dd'd into a partition. The images here are
    # raw because BoardConfig.mk sets TARGET_USERIMAGES_SPARSE_EXT_DISABLED, but
    # that is checked rather than trusted: a sparse image is a container (28-byte
    # header, magic 0xed26ff3a, then chunks saying where each belongs), so writing
    # one verbatim leaves the partition with no filesystem in it and the board
    # fails to mount with nothing in any log. build-images.sh carries the same
    # guard, and the same magic, for the same reason.
    echo 'sparse_check() {'
    echo '  [ "$(od -An -tx1 -N4 -- "$1" | tr -d " \n")" = "3aff26ed" ] || return 0'
    echo '  echo "$1 is an Android sparse image and cannot be written raw." >&2'
    echo '  if command -v simg2img >/dev/null 2>&1; then'
    echo '    echo "  expanding it with simg2img" >&2'
    echo '    simg2img "$1" "$1.raw" && mv -f "$1.raw" "$1" && return 0'
    echo '  fi'
    echo '  echo "  no simg2img here to expand it (Debian: android-sdk-libsparse-utils)." >&2'
    echo '  echo "  Rebuild with TARGET_USERIMAGES_SPARSE_EXT_DISABLED := true, or expand" >&2'
    echo '  echo "  it on the build host before copying this pack over." >&2'
    echo '  exit 1'
    echo '}'
    # The partition number is known here, at generation time, because this script
    # wrote the table two lines up. Resolving it at run time by parsing sgdisk
    # output was the first version of this and there is no reason to.
    n=1
    while IFS=$'\t' read -r name size image; do
        case "$name" in ''|\#*) continue ;; esac
        if [[ "$image" != "-" ]]; then
            echo "echo '  writing $name -> \${DEV}p$n'"
            echo "[ -b \"\${DEV}p$n\" ] || { echo \"\${DEV}p$n does not exist\" >&2; exit 1; }"
            echo "sparse_check $image"
            echo "dd if=$image of=\"\${DEV}p$n\" bs=4M conv=fsync"
        fi
        n=$(( n + 1 ))
    done < "$LAYOUT"
    echo 'echo "done. userdata and metadata are left empty; Android formats them on first boot."'
} > "$PACK/flash-emmc.sh"
chmod +x "$PACK/flash-emmc.sh"

echo
echo "flash pack: $PACK"
ls -la "$PACK" | sed 's/^/  /'
echo
echo "To install, copy that directory to the board and run ./flash-emmc.sh /dev/mmcblkN"
echo "from the Linux it already boots. Check the device name first - on this board"
echo "the eMMC is usually mmcblk2 and the SD card mmcblk1."
