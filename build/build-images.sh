#!/usr/bin/env bash
#
# Khadas Edge1 - assemble the whole-disk images.
#
#   usage: build-images.sh [tree-dir] [target...]
#
# Targets (default: all three):
#   sdcard   edge1-sdcard.img   bootable card, written from a desktop with Etcher
#   emmc     edge1-emmc.img     bootable eMMC image
#   nvme     edge1-nvme.img     Android partitions for the M.2 SSD, no bootloader
#
# Environment:
#   EDGE1_SD_SIZE_MIB     total size of the card image   (default 7000, fits "8GB")
#   EDGE1_EMMC_SIZE_MIB   total size of the eMMC image   (default 14400, fits "16GB")
#   EDGE1_NVME_SIZE_MIB   total size of the NVMe image   (default 14400)
#   EDGE1_NO_GZIP=1       skip the compressed copies
#   EDGE1_IMAGE_TAG=x     name the outputs edge1-sdcard-x.img and so on, so two
#                         variants can sit side by side. Set it when A/B-ing
#                         bootloaders: EDGE1_UBOOT_REV=v2025.07 build-uboot.sh, then
#                         EDGE1_IMAGE_TAG=v2025.07 build-images.sh ... sdcard.
#                         The pipeline never sets it, so the stage's own outputs keep
#                         their plain names.
#
# ---------------------------------------------------------------------------
# Why three images, and what is actually different between them
#
# One layout - device/khadas/edge/flash/partitions.tsv - and three media. Only
# three things differ, and only one of them is interesting:
#
#   size         the card image is sized for an 8GB card, the other two for 16GB.
#   file name    so all three can sit in out/ at once.
#   bootloader   the card and the eMMC get u-boot-rockchip.bin at sector 64.
#                The NVMe does not, and cannot.
#
# That last one is a property of the silicon. The RK3399 BootROM's boot sources are
# the enum in U-Boot's arch/arm/include/asm/arch-rockchip/bootrom.h:47-59 - NAND,
# EMMC, SPINOR, SPINAND, SD, UFS, I2C, SPI, USB. PCIe is not among them, so nothing
# written to an NVMe can ever be the first thing that runs. An NVMe install keeps
# U-Boot on the eMMC or on the card and puts only Android's partitions on the SSD;
# build-uboot.sh builds a U-Boot that tries card, then eMMC, then NVMe for exactly
# this reason.
#
# How each one is meant to be written:
#
#   sdcard  Balena Etcher, from the desktop. Needs nothing on the board.
#   emmc    either the on-device installer (see install-to-internal.sh, which does
#           not use this file - it copies the running card partition by partition
#           and sizes the target to the real device), or Etcher onto the eMMC while
#           U-Boot exposes it over USB with "ums 0 mmc 0". CONFIG_CMD_USB_MASS_STORAGE
#           is already in the Edge-V defconfig, so that costs nothing.
#   nvme    the same two ways, "ums 0 nvme 0" for the second.
#
# The installer is the path that does not need a serial console, and it is the one
# to prefer: a fixed-size image leaves the rest of a 128GB SSD unused, while the
# installer gives userdata everything that is there.
# ---------------------------------------------------------------------------
set -euo pipefail

readonly TREE="${1:-$HOME/aosp-14-edge1}"
shift || true
readonly OUT="$TREE/out/target/product/edge"
readonly LAYOUT="$TREE/device/khadas/edge/flash/partitions.tsv"
readonly UBOOT="$TREE/bootloader/u-boot/u-boot-rockchip.bin"

# Sector 64 for the bootloader and 16MiB for the first partition are not arbitrary:
# the BootROM reads the Rockchip ID block from sector 64, and partitions.tsv leaves
# everything below 16MiB free for it. doc/board/rockchip/rockchip.rst:346 is where
# seek=64 comes from.
readonly UBOOT_SEEK_SECTORS=64
readonly FIRST_PART_MIB=16
# 1MiB at the end for the secondary GPT, which sgdisk writes at the very last
# sectors of the image.
readonly GPT_TAIL_MIB=1

TARGETS=("$@")
(( ${#TARGETS[@]} )) || TARGETS=(sdcard emmc nvme)

for t in sgdisk dd od; do
    command -v "$t" >/dev/null 2>&1 || { echo "$t not found (apt-get install gdisk)" >&2; exit 1; }
done
[[ -f "$LAYOUT" ]] || { echo "no layout at $LAYOUT" >&2; exit 1; }
[[ -d "$OUT" ]]    || { echo "no product output at $OUT; run build.sh first" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Per-target parameters. Kept in one place so a fourth medium is three lines.
# ---------------------------------------------------------------------------
# A tag, if given, goes before the extension rather than after the stem, so the
# files still sort together and still end in .img.
readonly TAG="${EDGE1_IMAGE_TAG:+-$EDGE1_IMAGE_TAG}"
target_file() {
    case "$1" in
        sdcard) echo "$OUT/edge1-sdcard${TAG}.img" ;;
        emmc)   echo "$OUT/edge1-emmc${TAG}.img" ;;
        nvme)   echo "$OUT/edge1-nvme${TAG}.img" ;;
        *) return 1 ;;
    esac
}
target_size() {
    case "$1" in
        sdcard) echo "${EDGE1_SD_SIZE_MIB:-7000}" ;;
        emmc)   echo "${EDGE1_EMMC_SIZE_MIB:-14400}" ;;
        nvme)   echo "${EDGE1_NVME_SIZE_MIB:-14400}" ;;
        *) return 1 ;;
    esac
}
# The one real difference. See the header.
target_wants_bootloader() {
    case "$1" in
        sdcard|emmc) return 0 ;;
        nvme)        return 1 ;;
        *)           return 1 ;;
    esac
}

for t in "${TARGETS[@]}"; do
    target_file "$t" >/dev/null || {
        echo "unknown target '$t'; known: sdcard emmc nvme" >&2; exit 1; }
done

# A bootloader is needed if any requested target wants one.
need_uboot=1
for t in "${TARGETS[@]}"; do target_wants_bootloader "$t" && need_uboot=0; done
if (( need_uboot == 0 )) && [[ ! -f "$UBOOT" ]]; then
    echo "no bootloader at $UBOOT" >&2
    echo >&2
    echo "Run build/build-uboot.sh first. Without it these images would be written" >&2
    echo "to media the board cannot boot from - the BootROM would find no ID block" >&2
    echo "and fall through to whatever is already installed." >&2
    echo >&2
    echo "Only the nvme target can be built without it, because an NVMe never holds" >&2
    echo "the bootloader anyway:  build-images.sh $TREE nvme" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Read the layout and check every image exists before touching anything. A
# half-written image is worse than no image: it looks like a product.
# ---------------------------------------------------------------------------
declare -a NAMES=() FIXED=() IMAGES=()
fixed_mib=0
rest_index=-1
while IFS=$'\t' read -r name size image; do
    case "$name" in ''|\#*) continue ;; esac
    NAMES+=("$name"); FIXED+=("$size"); IMAGES+=("$image")
    if [[ "$size" == "rest" ]]; then
        rest_index=$(( ${#NAMES[@]} - 1 ))
    else
        fixed_mib=$(( fixed_mib + size ))
    fi
done < "$LAYOUT"

(( ${#NAMES[@]} )) || { echo "$LAYOUT has no partitions" >&2; exit 1; }

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

readonly TMP="$OUT/image-tmp"
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
# file in $OUT would have passed an image that does not fit. Checked once: every
# partition with an image has a fixed size, the same on all three media.
for i in "${!NAMES[@]}"; do
    [[ "${RAW[$i]}" == "-" ]] && continue
    bytes=$(stat -c %s "${RAW[$i]}")
    if (( bytes > FIXED[i] * 1024 * 1024 )); then
        echo "${IMAGES[$i]} is $bytes bytes and does not fit ${NAMES[$i]} (${FIXED[$i]}MiB)" >&2
        exit 1
    fi
done

ub_bytes=0
if [[ -f "$UBOOT" ]]; then
    ub_bytes=$(stat -c %s "$UBOOT")
    # The blob has to actually start with a Rockchip ID block, or the BootROM will
    # not look past it. Checked with rk-idb-check.py rather than by eye, because the
    # block is RC4-scrambled and a correct one is indistinguishable from garbage in
    # a hexdump - which is exactly how a first hardware attempt got misread.
    IDB_CHECK="$(dirname "${BASH_SOURCE[0]}")/rk-idb-check.py"
    if [[ -x "$IDB_CHECK" ]] && command -v python3 >/dev/null 2>&1; then
        if ! "$IDB_CHECK" "$UBOOT" 0 | sed 's/^/    /'; then
            echo "u-boot-rockchip.bin does not begin with a valid Rockchip ID block." >&2
            echo "The BootROM would not recognise it. Rebuild with build-uboot.sh." >&2
            exit 1
        fi
    fi

    # And the second stage, which until now was only ever arithmetic.
    #
    # SPL reads u-boot.itb from a fixed raw sector - CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR,
    # 0x4000 = 16384 on Rockchip. binman places the FIT at CONFIG_SPL_PAD_TO
    # (0x7f8000 = 16320 sectors) inside the blob, and the blob goes to sector 64, so
    # 64 + 16320 = 16384 and the two meet. build-uboot.sh checks that those numbers
    # agree; this checks that the FIT is actually THERE, by looking for the
    # 0xd00dfeed magic at that offset.
    #
    # Worth doing separately because the two can disagree in a way no arithmetic
    # catches: a blob whose FIT is missing or at a different offset still has a valid
    # ID block, still has the right size, and still passes every other check here -
    # and SPL then finds nothing at sector 16384. On a board whose eMMC carries
    # another u-boot.itb at that same sector, the search simply moves on to that one.
    FIT_OFF=$(( 0x7f8000 ))
    fit_magic="$(od -An -tx1 -N4 -j "$FIT_OFF" -- "$UBOOT" 2>/dev/null | tr -d ' \n')"
    if [[ "$fit_magic" == "d00dfeed" ]]; then
        printf '    u-boot.itb: FIT magic at 0x%x, so sector %d once written at %d\n' \
               "$FIT_OFF" "$(( UBOOT_SEEK_SECTORS + FIT_OFF / 512 ))" "$UBOOT_SEEK_SECTORS"
    else
        echo "no FIT at offset $FIT_OFF of u-boot-rockchip.bin (found '${fit_magic:-nothing}'," >&2
        echo "expected d00dfeed). SPL reads u-boot.itb from sector 16384 and would find" >&2
        echo "nothing there - and on this board the eMMC has another one at that sector," >&2
        echo "so the search would silently move on to it. Rebuild with build-uboot.sh." >&2
        exit 1
    fi
    # The bootloader has to fit between sector 64 and the first partition, or writing
    # the partitions would overwrite it.
    if (( UBOOT_SEEK_SECTORS * 512 + ub_bytes > FIRST_PART_MIB * 1024 * 1024 )); then
        echo "u-boot-rockchip.bin is ${ub_bytes} bytes and would run past the first" >&2
        echo "partition at ${FIRST_PART_MIB}MiB. Move the first partition later in" >&2
        echo "flash/partitions.tsv." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Build one image.
# ---------------------------------------------------------------------------
build_target() {
    local target="$1"
    local img size_mib
    img="$(target_file "$target")"
    size_mib="$(target_size "$target")"

    local used_mib=$(( FIRST_PART_MIB + fixed_mib + GPT_TAIL_MIB ))
    if (( used_mib > size_mib )); then
        echo "$target: the layout needs ${used_mib}MiB but the requested size is ${size_mib}MiB" >&2
        echo "  raise it, or shrink super in flash/partitions.tsv" >&2
        return 1
    fi
    local rest_mib=$(( size_mib - used_mib ))
    if (( rest_index >= 0 )) && (( rest_mib < 512 )); then
        echo "$target: ${NAMES[$rest_index]} would be only ${rest_mib}MiB, which is too" >&2
        echo "  small for Android to format and use. Raise the size for this target." >&2
        return 1
    fi

    echo
    echo "=========================================================================="
    echo "  $target -> $(basename "$img")"
    echo "=========================================================================="
    echo "==> total:      ${size_mib}MiB"
    if target_wants_bootloader "$target"; then
        echo "==> bootloader: ${ub_bytes} bytes at sector ${UBOOT_SEEK_SECTORS}"
    else
        echo "==> bootloader: none - the RK3399 BootROM cannot boot from PCIe, so"
        echo "                U-Boot stays on the eMMC or the card"
    fi

    rm -f "$img" "$img.gz"
    # Sparse: the file reads as size_mib but only the written extents take disk, so
    # userdata's gigabytes of zeros cost nothing here.
    truncate -s "${size_mib}M" "$img"

    echo "==> partition table"
    sgdisk --zap-all "$img" >/dev/null
    local start=$FIRST_PART_MIB n=1 i name size
    for i in "${!NAMES[@]}"; do
        name="${NAMES[$i]}"; size="${FIXED[$i]}"
        if (( i == rest_index )); then
            size=$rest_mib
            sgdisk --new="$n:${start}M:0" --change-name="$n:$name" "$img" >/dev/null
        else
            sgdisk --new="$n:${start}M:+${size}M" --change-name="$n:$name" "$img" >/dev/null
            start=$(( start + size ))
        fi
        printf '    %-12s %6sMiB  part %d\n' "$name" "$size" "$n"
        n=$(( n + 1 ))
    done

    if target_wants_bootloader "$target"; then
        echo "==> bootloader at sector $UBOOT_SEEK_SECTORS"
        dd if="$UBOOT" of="$img" bs=512 seek="$UBOOT_SEEK_SECTORS" \
           conv=notrunc,fsync status=none
    fi

    echo "==> partition contents"
    start=$FIRST_PART_MIB
    for i in "${!NAMES[@]}"; do
        name="${NAMES[$i]}"; size="${FIXED[$i]}"
        if [[ "${RAW[$i]}" != "-" ]]; then
            # seek in MiB blocks so the arithmetic matches the table exactly; notrunc
            # so each write lands inside the file rather than truncating it; sparse so
            # a raw 4.6GiB super.img whose free blocks are zeros does not turn a 7GiB
            # sparse file into 7GiB on disk. sparse is only safe because the file was
            # just created by truncate and every byte of it is already zero.
            local bytes; bytes=$(stat -c %s "${RAW[$i]}")
            dd if="${RAW[$i]}" of="$img" bs=1M seek="$start" \
               conv=notrunc,sparse,fsync status=none
            printf '    %-12s <- %-16s %s\n' "$name" "${IMAGES[$i]}" \
                   "$(numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B")"
        fi
        (( i == rest_index )) || start=$(( start + size ))
    done

    echo "==> verifying the table reads back"
    sgdisk --print "$img" | sed -n '/Number/,$p' | sed 's/^/    /'

    if [[ "${EDGE1_NO_GZIP:-0}" != "1" ]]; then
        echo "==> compressing"
        if command -v pigz >/dev/null 2>&1; then
            pigz -1 -k -f "$img"
        else
            gzip -1 -k -f "$img"
        fi
    fi
    printf '    %s  (%s apparent, %s on disk)\n' "$(basename "$img")" \
        "$(du -h --apparent-size "$img" | cut -f1)" "$(du -h "$img" | cut -f1)"
    [[ -f "$img.gz" ]] && printf '    %s  (%s)\n' "$(basename "$img.gz")" \
        "$(du -h "$img.gz" | cut -f1)"
    return 0
}

for t in "${TARGETS[@]}"; do
    build_target "$t"
done

echo
echo "=========================================================================="
echo "  How to write each of these"
echo "=========================================================================="
cat <<'EOF'
  edge1-sdcard.img   Balena Etcher, straight onto the card, from the desktop.
                     Nothing has to be running on the board. The eMMC is not
                     touched, so pulling the card out puts the board back.

  edge1-emmc.img     Not writable from a desktop on its own - the eMMC is not
  edge1-nvme.img     removable. Two ways in:

                     1. Boot the card, then from Android:
                          adb root
                          adb shell sh /vendor/bin/edge1-install-internal.sh emmc
                          adb shell sh /vendor/bin/edge1-install-internal.sh nvme
                        This does not use the image files at all. It copies the
                        running card partition by partition and sizes the target
                        to the real device, so userdata gets the whole SSD.

                     2. With a serial console, from the U-Boot prompt:
                          ums 0 mmc 0     the eMMC as a USB disk
                          ums 0 nvme 0    the SSD as a USB disk
                        then write the matching image with Etcher from the desktop.
EOF
