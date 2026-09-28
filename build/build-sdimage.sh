#!/usr/bin/env bash
#
# Khadas Edge1 - assemble one whole-disk image for an SD card.
#
#   usage: build-sdimage.sh [tree-dir]
#
# Environment:
#   EDGE1_SD_SIZE_MIB   total image size (default 7000, fits any "8GB" card)
#   EDGE1_SD_NO_GZIP=1  skip the compressed copy
#
# Output:
#   out/target/product/edge/edge1-sdcard.img      write this with Balena Etcher
#   out/target/product/edge/edge1-sdcard.img.gz   Etcher reads this directly
#
# Why a whole-disk image rather than the per-partition set: Etcher writes one file
# from sector 0, partition table included. The alternative - flash-emmc.sh, which
# partitions and dds on the board - needs a Linux already running on the board and
# a shell on it. A card written from a desktop needs nothing.
#
# The card is self-booting. The RK3399 BootROM looks at the SD card before the
# eMMC, so a card with a valid bootloader in its raw sectors takes over the boot
# without the eMMC being touched at all - and removing the card puts the board back
# exactly as it was. That is the whole reason this is the safer install path, and it
# is why u-boot-rockchip.bin has to be in the image.
set -euo pipefail

readonly TREE="${1:-$HOME/aosp-14-edge1}"
readonly OUT="$TREE/out/target/product/edge"
readonly LAYOUT="$TREE/device/khadas/edge/flash/partitions.tsv"
readonly UBOOT="$TREE/bootloader/u-boot/u-boot-rockchip.bin"
readonly IMG="$OUT/edge1-sdcard.img"

readonly SIZE_MIB="${EDGE1_SD_SIZE_MIB:-7000}"

# Sector 64 for the bootloader and 16MiB for the first partition are not arbitrary:
# the BootROM reads the Rockchip ID block from sector 64, and partitions.tsv leaves
# everything below 16MiB free for it. doc/board/rockchip/rockchip.rst:346 is where
# seek=64 comes from.
readonly UBOOT_SEEK_SECTORS=64
readonly FIRST_PART_MIB=16

for t in sgdisk dd od; do
    command -v "$t" >/dev/null 2>&1 || { echo "$t not found (apt-get install gdisk)" >&2; exit 1; }
done
[[ -f "$LAYOUT" ]] || { echo "no layout at $LAYOUT" >&2; exit 1; }
[[ -d "$OUT" ]]    || { echo "no product output at $OUT; run build.sh first" >&2; exit 1; }

if [[ ! -f "$UBOOT" ]]; then
    echo "no bootloader at $UBOOT" >&2
    echo >&2
    echo "Run build/build-uboot.sh first. Without it this image would be written to" >&2
    echo "a card the board cannot boot from - the BootROM would find no ID block on" >&2
    echo "the card and fall through to the eMMC, which still has whatever is on it." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Read the layout, resolve "rest", and check every image exists before touching
# anything. A half-written image is worse than no image: it looks like a product.
# ---------------------------------------------------------------------------
declare -a NAMES=() SIZES=() IMAGES=()
fixed_mib=0
rest_index=-1
while IFS=$'\t' read -r name size image; do
    case "$name" in ''|\#*) continue ;; esac
    NAMES+=("$name"); SIZES+=("$size"); IMAGES+=("$image")
    if [[ "$size" == "rest" ]]; then
        rest_index=$(( ${#NAMES[@]} - 1 ))
    else
        fixed_mib=$(( fixed_mib + size ))
    fi
done < "$LAYOUT"

(( ${#NAMES[@]} )) || { echo "$LAYOUT has no partitions" >&2; exit 1; }

# 1MiB at the end for the secondary GPT, which sgdisk writes at the very last
# sectors of the image.
readonly GPT_TAIL_MIB=1
used_mib=$(( FIRST_PART_MIB + fixed_mib + GPT_TAIL_MIB ))
if (( used_mib > SIZE_MIB )); then
    echo "the layout needs ${used_mib}MiB but EDGE1_SD_SIZE_MIB is ${SIZE_MIB}" >&2
    echo "raise it, or shrink super in flash/partitions.tsv" >&2
    exit 1
fi
rest_mib=$(( SIZE_MIB - used_mib ))
if (( rest_index >= 0 )); then
    SIZES[$rest_index]=$rest_mib
    (( rest_mib >= 512 )) || {
        echo "${NAMES[$rest_index]} would be only ${rest_mib}MiB, which is too small" >&2
        echo "for Android to format and use. Raise EDGE1_SD_SIZE_MIB." >&2
        exit 1; }
fi

missing=0
for i in "${!NAMES[@]}"; do
    [[ "${IMAGES[$i]}" == "-" ]] && continue
    [[ -f "$OUT/${IMAGES[$i]}" ]] || { echo "  missing ${IMAGES[$i]}" >&2; missing=$((missing+1)); }
done
(( missing == 0 )) || { echo "$missing image(s) missing; run build.sh first" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Nothing Android-sparse may be dd'd.
#
# An Android sparse image is a container, not a filesystem: a 28-byte header
# (magic 0xed26ff3a) followed by chunks that each say which output blocks they
# hold. Written verbatim into a partition it is 4GiB of the wrong bytes - no ext4
# superblock, no super metadata - and the board fails to mount /system with
# nothing in any log to say why. It is the one failure here that cannot be seen by
# looking at the card.
#
# BoardConfig.mk sets TARGET_USERIMAGES_SPARSE_EXT_DISABLED so super.img comes out
# raw, which is the real fix. This is the check that the real fix is in force,
# because it went wrong once in the other direction: the build reported success,
# every image was present and the right size, and super.img was a sparse container.
# So the format is read from the file rather than assumed from the config, and if
# it is sparse it gets converted rather than written.
# ---------------------------------------------------------------------------
readonly SPARSE_MAGIC=3aff26ed   # 0xed26ff3a, little-endian, as the first 4 bytes
is_sparse() {
    [[ "$(od -An -tx1 -N4 -- "$1" | tr -d ' \n')" == "$SPARSE_MAGIC" ]]
}

readonly TMP="$OUT/sdimage-tmp"
rm -rf "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

find_simg2img() {
    # The build produces it only as part of otatools (core/Makefile:5561), and
    # build.sh asks for it by name for this reason.
    local candidates=(
        "$TREE/out/host/linux-x86/bin/simg2img"
        "$TREE/out/soong/host/linux-x86/bin/simg2img"
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    command -v simg2img 2>/dev/null && return 0
    return 1
}

declare -a RAW=()
for i in "${!NAMES[@]}"; do
    img="${IMAGES[$i]}"
    if [[ "$img" == "-" ]]; then RAW+=("-"); continue; fi
    if ! is_sparse "$OUT/$img"; then RAW+=("$OUT/$img"); continue; fi

    echo "==> $img is Android-sparse and has to be expanded before it can be written"
    simg2img="$(find_simg2img)" || {
        echo "  no simg2img to expand it with." >&2
        echo >&2
        echo "  This should not happen: device/khadas/edge/BoardConfig.mk sets" >&2
        echo "  TARGET_USERIMAGES_SPARSE_EXT_DISABLED := true so the build writes raw" >&2
        echo "  images. If $img is sparse, that setting is not reaching the build -" >&2
        echo "  check that place-device.sh has copied the current BoardConfig.mk into" >&2
        echo "  the tree, then rebuild." >&2
        echo >&2
        echo "  To expand it instead, build the tool and re-run this script:" >&2
        echo "    cd $TREE && source build/envsetup.sh && lunch edge1_tv-trunk_staging-userdebug && m simg2img" >&2
        exit 1; }
    mkdir -p "$TMP"
    echo "    $simg2img -> $TMP/$img"
    "$simg2img" "$OUT/$img" "$TMP/$img"
    RAW+=("$TMP/$img")
done

# Sizes are checked against the raw image, which is the one that gets written. The
# sparse file is a fraction of the size of what it expands to, so checking the
# file in $OUT would have passed an image that does not fit.
for i in "${!NAMES[@]}"; do
    [[ "${RAW[$i]}" == "-" ]] && continue
    bytes=$(stat -c %s "${RAW[$i]}")
    if (( bytes > SIZES[i] * 1024 * 1024 )); then
        echo "${IMAGES[$i]} is $bytes bytes and does not fit ${NAMES[$i]} (${SIZES[$i]}MiB)" >&2
        exit 1
    fi
done

# The bootloader has to fit between sector 64 and the first partition, or writing
# the partitions would overwrite it.
ub_bytes=$(stat -c %s "$UBOOT")
ub_end_bytes=$(( UBOOT_SEEK_SECTORS * 512 + ub_bytes ))
if (( ub_end_bytes > FIRST_PART_MIB * 1024 * 1024 )); then
    echo "u-boot-rockchip.bin is ${ub_bytes} bytes and would run past the first" >&2
    echo "partition at ${FIRST_PART_MIB}MiB. Move the first partition later in" >&2
    echo "flash/partitions.tsv." >&2
    exit 1
fi

echo "==> image:      $IMG"
echo "==> total:      ${SIZE_MIB}MiB"
echo "==> bootloader: ${ub_bytes} bytes at sector ${UBOOT_SEEK_SECTORS}"
echo

# ---------------------------------------------------------------------------
# Build it.
# ---------------------------------------------------------------------------
rm -f "$IMG" "$IMG.gz"
# Sparse: the file reads as SIZE_MIB but only the written extents take disk, so
# userdata's couple of gigabytes of zeros cost nothing here.
truncate -s "${SIZE_MIB}M" "$IMG"

echo "==> partition table"
sgdisk --zap-all "$IMG" >/dev/null
start=$FIRST_PART_MIB
n=1
for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"; size="${SIZES[$i]}"
    if (( i == rest_index )); then
        sgdisk --new="$n:${start}M:0" --change-name="$n:$name" "$IMG" >/dev/null
    else
        sgdisk --new="$n:${start}M:+${size}M" --change-name="$n:$name" "$IMG" >/dev/null
        start=$(( start + size ))
    fi
    printf '    %-12s %6sMiB  part %d\n' "$name" "$size" "$n"
    n=$(( n + 1 ))
done

echo "==> bootloader at sector $UBOOT_SEEK_SECTORS"
dd if="$UBOOT" of="$IMG" bs=512 seek="$UBOOT_SEEK_SECTORS" conv=notrunc,fsync status=none

echo "==> partition contents"
start=$FIRST_PART_MIB
for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"; size="${SIZES[$i]}"; image="${IMAGES[$i]}"
    if [[ "$image" != "-" ]]; then
        # seek in MiB blocks so the arithmetic matches the table exactly; notrunc so
        # each write lands inside the file rather than truncating it; sparse so a
        # raw 4.6GiB super.img whose free blocks are zeros does not turn a 7GiB
        # sparse file into 7GiB on disk. sparse is only safe because the file was
        # just created by truncate and every byte of it is already zero.
        bytes=$(stat -c %s "${RAW[$i]}")
        dd if="${RAW[$i]}" of="$IMG" bs=1M seek="$start" \
           conv=notrunc,sparse,fsync status=none
        printf '    %-12s <- %-16s %s\n' "$name" "$image" \
               "$(numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B")"
    fi
    (( i == rest_index )) || start=$(( start + size ))
done

echo
echo "==> verifying the table reads back"
sgdisk --print "$IMG" | sed -n '/Number/,$p' | sed 's/^/    /'

if [[ "${EDGE1_SD_NO_GZIP:-0}" != "1" ]]; then
    echo
    echo "==> compressing (Etcher reads .gz directly, and it is a much smaller copy"
    echo "    out of WSL than the raw image)"
    if command -v pigz >/dev/null 2>&1; then
        pigz -1 -k -f "$IMG"
    else
        gzip -1 -k -f "$IMG"
    fi
    echo "    $IMG.gz  ($(du -h "$IMG.gz" | cut -f1))"
fi

echo
echo "Raw:        $IMG  ($(du -h --apparent-size "$IMG" | cut -f1) apparent, $(du -h "$IMG" | cut -f1) on disk)"
[[ -f "$IMG.gz" ]] && echo "Compressed: $IMG.gz  ($(du -h "$IMG.gz" | cut -f1))"
echo
echo "Write either one to the SD card with Balena Etcher. The eMMC is not touched:"
echo "the RK3399 BootROM reads the card first, so the card boots and pulling it out"
echo "puts the board back on whatever is installed on the eMMC."
