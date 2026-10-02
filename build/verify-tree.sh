#!/usr/bin/env bash
#
# Khadas Edge1 - static validation of the device tree.
#
# Catches the errors that otherwise surface as a Soong/Kati failure minutes into
# a build, or worse as a missing file on the image: malformed XML, a
# PRODUCT_COPY_FILES source that does not exist, a HAL declared in the device
# manifest but in no VINTF fragment, or an Android 10 construct that Android 14
# removed.
#
# Runs with no AOSP tree present, which is the point: it is the one check that
# can be run before a 120GiB sync.
#
set -uo pipefail

# shellcheck source=build/lib-tree.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-tree.sh"

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEV="$ROOT/device/khadas/edge"
errors=0
warns=0

err()  { printf '  \033[31mERROR\033[0m %s\n' "$*"; errors=$((errors+1)); }
wrn()  { printf '  \033[33mWARN \033[0m %s\n' "$*"; warns=$((warns+1)); }
ok()   { printf '  \033[32mok   \033[0m %s\n' "$*"; }

echo "Khadas Edge1 device tree verification"
echo "root: $ROOT"
echo

# --- 1. XML well-formedness ---------------------------------------------------
echo "[1] XML well-formedness"
while IFS= read -r f; do
    if python3 -c "import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])" "$f" 2>/dev/null; then
        ok "${f#$ROOT/}"
    else
        msg=$(python3 -c "import sys,xml.etree.ElementTree as ET
try: ET.parse(sys.argv[1])
except Exception as e: print(e)" "$f" 2>&1)
        err "${f#$ROOT/}: $msg"
    fi
done < <(find "$ROOT/device" "$ROOT/manifests" -name '*.xml' 2>/dev/null | sort)
echo

# --- 2. PRODUCT_COPY_FILES sources --------------------------------------------
# Only device-local sources are checked; AOSP-relative ones (frameworks/...,
# device/google/atv/...) cannot exist until a tree is synced.
echo "[2] PRODUCT_COPY_FILES sources inside the device tree"
while IFS= read -r src; do
    # $(LOCAL_PATH) and the literal path both resolve to the device dir.
    rel="${src#\$(LOCAL_PATH)/}"
    rel="${rel#device/khadas/edge/}"
    if [[ -e "$DEV/$rel" ]]; then
        ok "$rel"
    else
        err "PRODUCT_COPY_FILES references a missing file: $rel"
    fi
done < <(grep -hoE '(\$\(LOCAL_PATH\)|device/khadas/edge)/[A-Za-z0-9_./-]+' \
            "$DEV/device.mk" 2>/dev/null | sort -u)
echo

# --- 3. BoardConfig file references -------------------------------------------
echo "[3] BoardConfig.mk file references"
while IFS= read -r ref; do
    if [[ -e "$ROOT/$ref" ]]; then
        ok "${ref#device/khadas/edge/}"
    else
        err "BoardConfig.mk references a missing file: $ref"
    fi
# Comments stripped first. Without that, this check reported
# device/khadas/edge/bluetooth as a missing file - from the comment that explains
# why the directory was deleted. A check that fails on its own explanation trains
# people to ignore it.
done < <(sed 's/#.*//' "$DEV/BoardConfig.mk" 2>/dev/null \
            | grep -hoE 'device/khadas/edge/[A-Za-z0-9_./-]+' \
            | grep -vxE 'device/khadas/edge/(sepolicy/vendor|vintf)' | sort -u)
# Directories referenced for sepolicy/vintf are checked separately since they
# are dirs, not files.
for d in sepolicy/vendor vintf; do
    [[ -d "$DEV/$d" ]] && ok "$d/ (dir)" || err "BoardConfig.mk references missing dir: $d"
done
echo

# --- 3b. flash layout vs the partition sizes the build enforces ----------------
# Two numbers describe each partition and nothing makes them agree:
# BOARD_*_PARTITION_SIZE, which the build checks the image against, and the size
# column in flash/partitions.tsv, which is what the GPT actually gets. If the tsv
# is smaller, an image the build accepted does not fit the partition it is written
# to - and that is discovered by a board that does not boot, with no log.
#
# The other half is images that no longer exist. When BoardConfig.mk moved from
# boot header v4 to v2 the build stopped producing vendor_boot.img, and a
# vendor_boot row in the tsv would have had flash-emmc.sh write a partition from a
# file that was never built.
echo "[3b] flash layout vs BOARD_*_PARTITION_SIZE"
readonly TSV="$DEV/flash/partitions.tsv"
if [[ -f "$TSV" ]]; then
    bc_get() { sed 's/#.*//' "$DEV/BoardConfig.mk" | grep -oE "^[[:space:]]*$1[[:space:]]*:?=[[:space:]]*[0-9]+" \
               | grep -oE '[0-9]+$' | tail -1; }
    layout_bad=0
    while IFS=$'\t' read -r name mib img; do
        [[ -n "$name" && "$name" != \#* ]] || continue
        case "$name" in
            boot)        var=BOARD_BOOTIMAGE_PARTITION_SIZE ;;
            recovery)    var=BOARD_RECOVERYIMAGE_PARTITION_SIZE ;;
            vendor_boot) var=BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE ;;
            init_boot)   var=BOARD_INIT_BOOT_IMAGE_PARTITION_SIZE ;;
            dtbo)        var=BOARD_DTBOIMG_PARTITION_SIZE ;;
            super)       var=BOARD_SUPER_PARTITION_SIZE ;;
            *)           var= ;;
        esac
        [[ -n "$var" ]] || continue
        board=$(bc_get "$var")
        if [[ -z "$board" ]]; then
            if [[ "$img" != "-" ]]; then
                err "$name is in partitions.tsv with an image ($img) but BoardConfig.mk sets no"
                err "  $var, so the build produces no such image"
                layout_bad=$((layout_bad+1))
            fi
            continue
        fi
        tsv=$(( mib * 1024 * 1024 ))
        if (( tsv < board )); then
            err "$name: partitions.tsv gives ${mib}MiB but $var is $board bytes"
            err "  ($(( board / 1024 / 1024 ))MiB); an image the build accepts would not fit the partition"
            layout_bad=$((layout_bad+1))
        else
            ok "$name ${mib}MiB >= $var ($(( board / 1024 / 1024 ))MiB)"
        fi
    done < "$TSV"
    # super.img is the one image in the layout that the default build target does
    # not produce on its own. core/Makefile:7311 hangs it off droidcore-unbundled
    # only when BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT is true; otherwise droid builds
    # super_empty.img - metadata, no contents - and a build that flashes super.img
    # with dd finds nothing there. The first successful build ended that way.
    if grep -qE '^super\s' "$TSV" && grep -qE '[^-]\.img' <<< "$(grep -E '^super\s' "$TSV")"; then
        if sed 's/#.*//' "$DEV/BoardConfig.mk" \
           | grep -qE '^[[:space:]]*BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT[[:space:]]*:?=[[:space:]]*true'; then
            ok "super.img is in the layout and BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT is true"
        else
            err "partitions.tsv flashes super.img but BoardConfig.mk does not set"
            err "  BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT := true, so the default build target"
            err "  produces super_empty.img instead and the file will not exist"
            layout_bad=$((layout_bad+1))
        fi
    fi
    (( layout_bad )) || ok "every sized partition matches the size the build enforces"
else
    err "missing $TSV"
fi
echo

# --- 3c. the boot image's ramdisk must not land inside the kernel ---------------
# U-Boot copies both to the addresses in the boot image header, and it copies the
# ramdisk first (boot/bootm.c:1045 BOOTM_STATE_FINDOTHER, then :1059 LOADOS), so an
# overlap means the kernel is memmoved over a ramdisk that has already been placed.
# The kernel then comes up with a corrupt initramfs and panics with nothing
# pointing at the cause.
#
# mkbootimg's defaults are kernel_offset 0x00008000 and ramdisk_offset 0x01000000 -
# 16MiB apart, which was written when kernels were small. This one is 50MB.
echo "[3c] boot image: ramdisk clear of the kernel"
kbase=$(sed 's/#.*//' "$DEV/BoardConfig.mk" \
        | grep -oE '^[[:space:]]*BOARD_KERNEL_BASE[[:space:]]*:?=[[:space:]]*0x[0-9a-fA-F]+' \
        | grep -oE '0x[0-9a-fA-F]+$' | tail -1)
roff=$(sed 's/#.*//' "$DEV/BoardConfig.mk" \
       | grep -oE -- '--ramdisk_offset[[:space:]]+0x[0-9a-fA-F]+' \
       | grep -oE '0x[0-9a-fA-F]+$' | tail -1)
# mkbootimg's own defaults, used when the board does not override them.
koff=0x00008000
: "${roff:=0x01000000}"
if [[ -z "$kbase" ]]; then
    wrn "BoardConfig.mk sets no BOARD_KERNEL_BASE; cannot check the offsets"
else
    kaddr=$(( kbase + koff ))
    raddr=$(( kbase + roff ))
    headroom=$(( raddr - kaddr ))
    printf '  %-6s kernel  0x%08x\n' ' ' "$kaddr"
    printf '  %-6s ramdisk 0x%08x  (%d MiB above the kernel)\n' ' ' "$raddr" \
           "$(( headroom / 1024 / 1024 ))"
    # The real Image if one has been built - EDGE1_TREE points at the AOSP tree.
    image=""
    for cand in "${EDGE1_TREE:-}/kernel/mainline/out/arch/arm64/boot/Image" \
                "$(edge1_default_tree)/kernel/mainline/out/arch/arm64/boot/Image"; do
        [[ -f "$cand" ]] && { image="$cand"; break; }
    done
    if [[ -n "$image" ]]; then
        ksize=$(stat -c %s "$image")
        if (( ksize < headroom )); then
            ok "Image is $(( ksize / 1024 / 1024 ))MiB, headroom is $(( headroom / 1024 / 1024 ))MiB"
        else
            err "Image is $(( ksize / 1024 / 1024 ))MiB but the ramdisk sits only"
            err "  $(( headroom / 1024 / 1024 ))MiB above the kernel; raise --ramdisk_offset"
        fi
    elif (( headroom < 64 * 1024 * 1024 )); then
        # No built Image to measure. 64MiB is the floor this board needs: the Image
        # was 50MB when this was written and nothing about it is shrinking.
        err "the ramdisk is only $(( headroom / 1024 / 1024 ))MiB above the kernel."
        err "  This board's Image is around 50MB, so raise --ramdisk_offset in"
        err "  BOARD_MKBOOTIMG_ARGS to leave at least 64MiB"
    else
        ok "headroom is $(( headroom / 1024 / 1024 ))MiB (no built Image here to measure against)"
    fi
fi
echo

# --- 3d. nothing in the layout may be an Android sparse image -------------------
#
# The build's default is to write Android-sparse filesystem images, and a sparse
# image cannot be dd'd into a partition: it is a container - a 28-byte header with
# magic 0xed26ff3a, then chunks that each say which output blocks they hold - not
# the partition's contents. Written verbatim the partition has no ext4 superblock
# and super has no metadata, and the board fails to mount /system with nothing in
# any log to say why. It is the only failure in this layout that a card cannot be
# inspected for after the fact.
#
# This happened: a build that reported success, with every image present and within
# its partition, produced a sparse super.img, and both writers would have copied it
# through untouched.
#
# tools/releasetools/build_super_image.py:136-137 adds --sparse unless
# build_non_sparse_super_partition is set, and core/Makefile:6145-6148 sets that
# from TARGET_USERIMAGES_SPARSE_EXT_DISABLED or its f2fs twin - so those two
# switches are the only thing that makes super.img raw.
echo "[3d] images are written raw, not Android-sparse"
if [[ -f "$TSV" ]]; then
    sparse_bad=0
    # Anything in the layout with an image that is a filesystem the build sparses.
    # boot/recovery/vbmeta are never sparse - mkbootimg and avbtool write raw.
    if grep -qE '^super[[:space:]].*\.img' "$TSV"; then
        if sed 's/#.*//' "$DEV/BoardConfig.mk" | grep -qE \
           '^[[:space:]]*TARGET_USERIMAGES_SPARSE_(EXT|F2FS)_DISABLED[[:space:]]*:?=[[:space:]]*true'; then
            ok "super.img is flashed and the board disables sparse ext/f2fs images"
        else
            err "partitions.tsv flashes super.img but BoardConfig.mk does not set"
            err "  TARGET_USERIMAGES_SPARSE_EXT_DISABLED := true, so lpmake is given"
            err "  --sparse and super.img comes out as a sparse container that cannot be"
            err "  written into a partition"
            sparse_bad=$((sparse_bad+1))
        fi
    fi
    # And the guard in both writers, which is what catches it if the setting is ever
    # lost. The magic is the on-disk byte order of 0xed26ff3a.
    for w in build/build-images.sh build/build.sh; do
        if grep -q '3aff26ed' "$ROOT/$w"; then
            ok "${w#build/} checks the sparse magic before writing"
        else
            err "$w writes partition images but no longer checks for the sparse magic"
            err "  (3aff26ed). Without it a sparse image is copied through silently."
            sparse_bad=$((sparse_bad+1))
        fi
    done
    (( sparse_bad )) || ok "nothing in the layout can reach a partition sparse"
fi
echo

# --- 3e. the layout's three consumers must agree --------------------------------
#
# flash/partitions.tsv is the single source of truth for the GPT, but two numbers
# that go with it are not in the file, and there are now three places that write
# this layout onto a disk:
#
#   build/build-images.sh                 the three whole-disk images
#   build/build.sh                        the generated flash-emmc.sh
#   device/khadas/edge/bin/edge1-install-internal.sh   the on-device installer
#
# The first partition starts at 16MiB and the bootloader goes at sector 64, and if
# any one of the three disagrees it writes a disk whose bootloader is under a
# partition or whose partitions start where the bootloader ends. Neither shows up
# until the board does not boot.
#
# The installer also reads the layout at run time from the path device.mk installs
# it to. Those two strings are in different files and nothing but this ties them
# together; a rename on one side leaves an installer that cannot find its layout.
echo "[3e] the layout's consumers agree"
readonly INSTALLER="$DEV/bin/edge1-install-internal.sh"
if [[ -f "$INSTALLER" ]]; then
    consumers_bad=0
    # 16MiB, in whatever form each file states it.
    img_first=$(grep -oE '^readonly FIRST_PART_MIB=[0-9]+' "$ROOT/build/build-images.sh" | grep -oE '[0-9]+$')
    ins_first=$(grep -oE '^FIRST_PART_MIB=[0-9]+' "$INSTALLER" | grep -oE '[0-9]+$')
    gen_first=$(grep -oE '^[[:space:]]*start=[0-9]+' "$ROOT/build/build.sh" | grep -oE '[0-9]+$' | head -1)
    if [[ "$img_first" == "$ins_first" && "$img_first" == "$gen_first" && -n "$img_first" ]]; then
        ok "first partition at ${img_first}MiB in all three writers"
    else
        err "the first partition offset differs: build-images.sh=${img_first:-?}"
        err "  installer=${ins_first:-?} build.sh=${gen_first:-?}"
        consumers_bad=$((consumers_bad+1))
    fi
    # sector 64, in the two that write a bootloader and in the one that checks where
    # u-boot.itb lands. build-uboot.sh needs the same number because the blob's second
    # stage sits at a fixed offset inside it: written at seek N the FIT lands at
    # N + CONFIG_SPL_PAD_TO/512, and SPL reads it from a fixed sector. If build-uboot.sh
    # verified that against 64 while build-images.sh wrote at something else, the check
    # would pass and the board would still stop at SPL.
    img_seek=$(grep -oE '^readonly UBOOT_SEEK_SECTORS=[0-9]+' "$ROOT/build/build-images.sh" | grep -oE '[0-9]+$')
    ins_seek=$(grep -oE '^UBOOT_SEEK_SECTORS=[0-9]+' "$INSTALLER" | grep -oE '[0-9]+$')
    ub_seek=$(grep -oE '^readonly UBOOT_SEEK_SECTORS=[0-9]+' "$ROOT/build/build-uboot.sh" | grep -oE '[0-9]+$')
    if [[ -n "$img_seek" && "$img_seek" == "$ins_seek" && "$img_seek" == "$ub_seek" ]]; then
        ok "bootloader at sector $img_seek in all three files that name it"
    else
        err "the bootloader sector differs: build-images.sh=${img_seek:-?}"
        err "  installer=${ins_seek:-?} build-uboot.sh=${ub_seek:-?}"
        consumers_bad=$((consumers_bad+1))
    fi
    # The installer's layout path must be the one device.mk installs.
    ins_path=$(grep -oE '^LAYOUT=[^ ]+' "$INSTALLER" | cut -d= -f2)
    if [[ -z "$ins_path" ]]; then
        err "the installer does not set LAYOUT"
        consumers_bad=$((consumers_bad+1))
    elif grep -q "partitions.tsv:\$(TARGET_COPY_OUT_VENDOR)${ins_path#/vendor}" "$DEV/device.mk"; then
        ok "the installer reads $ins_path, which device.mk installs"
    else
        err "the installer reads $ins_path but device.mk does not install"
        err "  flash/partitions.tsv there, so it would find no layout on the board"
        consumers_bad=$((consumers_bad+1))
    fi
    # And it must be installed itself.
    if grep -q "bin/edge1-install-internal.sh:\$(TARGET_COPY_OUT_VENDOR)/bin/" "$DEV/device.mk"; then
        ok "the installer is installed into /vendor/bin"
    else
        err "device.mk does not install bin/edge1-install-internal.sh, so it would not"
        err "  be on the board at all"
        consumers_bad=$((consumers_bad+1))
    fi
    (( consumers_bad )) || ok "one layout, three writers, no disagreement"
else
    err "missing $INSTALLER"
fi
echo

# --- 3f. the card must be able to win against the eMMC --------------------------
#
# Two lines in build-uboot.sh decide whether the U-Boot we build is the one that
# actually runs, and both of them were missing on the first three cards. The
# symptom was the same each time and said nothing: the board booted the Armbian
# that lives on the eMMC, from a card whose ID block, GPT and partitions were all
# correct.
#
#   the SPL boot order    SPL loads u-boot.itb by itself, from the first device in
#                         /chosen/u-boot,spl-boot-order that resolves. Upstream
#                         lists &sdhci (eMMC) before &sdmmc (card), and the eMMC
#                         holds another valid u-boot.itb at the same sector 16384 -
#                         Armbian writes it there too. So SPL loads Armbian's
#                         bootloader and ours never runs.
#
#   the environment       CONFIG_ENV_IS_IN_MMC with device index 0 reads the
#                         environment off the eMMC, and a stored environment
#                         replaces bootcmd and preboot entirely rather than
#                         merging - so the eMMC would decide what the card boots.
#
# Neither is visible in any log, on any screen, or in the image. Both are cheap to
# assert, so they are asserted here rather than trusted to stay.
echo "[3f] the card's bootloader cannot be displaced by the eMMC"
uboot_sh="$ROOT/build/build-uboot.sh"
if [[ -f "$uboot_sh" ]]; then
    card_bad=0
    if grep -q 'u-boot,spl-boot-order' "$uboot_sh"; then
        ok "build-uboot.sh sets SPL's boot order (card before eMMC)"
    else
        err "build-uboot.sh no longer touches u-boot,spl-boot-order, so SPL would use"
        err "  upstream's order and load u-boot.itb from the eMMC"
        card_bad=$((card_bad+1))
    fi
    if grep -q '^# CONFIG_ENV_IS_IN_MMC is not set$' "$uboot_sh"; then
        ok "the environment is compiled in, not read from the eMMC"
    else
        err "build-uboot.sh no longer disables CONFIG_ENV_IS_IN_MMC; a stored"
        err "  environment on the eMMC would replace bootcmd and preboot"
        card_bad=$((card_bad+1))
    fi
    (( card_bad )) || ok "nothing on the internal storage can take the boot over"
else
    err "missing $uboot_sh"
fi
echo

# --- 3g. the card has to boot from an eMMC that is not empty ------------------
#
# The RK3399 BootROM tries the eMMC before the SD card, so on a board with
# anything bootable on its eMMC the card's own U-Boot never runs. What runs is the
# eMMC's U-Boot, whose distro boot looks at the card's partition 1 for boot.scr.
# That script (flash/boot.cmd, filled in by build/build-bootfs.sh) is the only way
# the card boots on such a board, so the pieces it depends on are asserted here.
echo "[3g] bootfs: partition 1, and the script that lives on it"
bootfs_bad=0
first_row="$(awk -F'\t' '$1 !~ /^#/ && NF >= 3 { print $1; exit }' "$TSV")"
if [[ "$first_row" == bootfs ]]; then
    ok "bootfs is partition 1 (flagged bootable on the card; distro boot defaults to 1 anyway)"
else
    err "the first row of partitions.tsv is '$first_row', not bootfs; distro boot on the"
    err "  eMMC's U-Boot would not find the boot script"
    bootfs_bad=$((bootfs_bad+1))
fi
bootcmd_tpl="$DEV/flash/boot.cmd"
bootfs_sh="$ROOT/build/build-bootfs.sh"
if [[ -f "$bootcmd_tpl" && -f "$bootfs_sh" ]]; then
    # Every @PLACEHOLDER@ in the template has to be one the generator prints.
    emitted="$(grep -oE 'print\(f"[A-Z0-9_]+=' "$bootfs_sh" | sed -E 's/print\(f"//; s/=$//' | sort -u)"
    unfilled=0
    while read -r ph; do
        [[ -n "$ph" ]] || continue
        grep -qx "$ph" <<< "$emitted" || { err "boot.cmd uses @$ph@, which build-bootfs.sh never sets"; unfilled=$((unfilled+1)); }
    done < <(grep -oE '@[A-Z0-9_]+@' "$bootcmd_tpl" | tr -d @ | sort -u)
    (( unfilled )) && bootfs_bad=$((bootfs_bad+unfilled)) || ok "every placeholder in boot.cmd is filled from boot.img"
    # The script runs on the eMMC's U-Boot - Armbian's 2022.07 on this board - so
    # it may use only what that U-Boot has. The first version used setexpr, which
    # 2022.07's khadas-edge-v config does not build, and declined to boot on the
    # board every time. The checker also refuses hush's '&& ... ||' trap.
    if chk_out="$(python3 "$ROOT/build/check-uboot-script.py" "$bootcmd_tpl" 2>&1)"; then
        ok "boot.cmd: ${chk_out#*: }"
    else
        while IFS= read -r l; do err "$l"; done <<< "$chk_out"
        bootfs_bad=$((bootfs_bad+1))
    fi
else
    err "missing $bootcmd_tpl or $bootfs_sh"
    bootfs_bad=$((bootfs_bad+1))
fi
# Windows gives a drive letter only to a "Microsoft basic data" partition, and the
# boot script's log on bootfs is read back on a PC.
if grep -q 'typecode=1:0700' "$ROOT/build/build-images.sh"; then
    ok "the card image types bootfs 0700, so a PC mounts it and edge1-boot.log is readable"
else
    err "build-images.sh no longer types partition 1 as 0700; Windows would hide bootfs"
    bootfs_bad=$((bootfs_bad+1))
fi
for caller in build/build.sh build/build-images.sh; do
    if grep -q 'build-bootfs.sh' "$ROOT/$caller"; then
        ok "$caller builds bootfs.img"
    else
        err "$caller does not run build-bootfs.sh, so bootfs.img would be missing or stale"
        bootfs_bad=$((bootfs_bad+1))
    fi
done
(( bootfs_bad )) || ok "the card can be booted by the U-Boot already on the eMMC"
echo

# --- 3h. what first-stage init needs from whoever boots it ---------------------
#
# Two command-line arguments without which first-stage init stops, whichever
# bootloader starts the kernel. BoardConfig.mk has the AOSP source lines for both.
#
#   androidboot.boot_devices   per medium, so it must come from the bootloader and
#                              must NOT be fixed in boot.img: both boot paths set it.
#   androidboot.verifiedbootstate=orange
#                              no bootloader here supplies vbmeta digests, and the
#                              avb fstab flags need either those or "unlocked".
echo "[3h] kernel command line: boot_devices and the verified-boot state"
cl_bad=0
if sed 's/#.*//' "$DEV/BoardConfig.mk" | grep -q 'androidboot.boot_devices'; then
    err "BoardConfig.mk puts androidboot.boot_devices in boot.img; it differs per medium"
    err "  (card fe320000.mmc, eMMC fe330000.mmc) and has to come from the bootloader"
    cl_bad=$((cl_bad+1))
fi
if sed 's/#.*//' "$DEV/BoardConfig.mk" | grep -q 'androidboot.verifiedbootstate=orange'; then
    ok "BoardConfig.mk declares the device unlocked (verifiedbootstate=orange)"
else
    err "BoardConfig.mk does not pass androidboot.verifiedbootstate=orange; with no vbmeta"
    err "  digest from the bootloader, the avb-flagged mounts in the fstab fail"
    cl_bad=$((cl_bad+1))
fi
uboot_sh="$ROOT/build/build-uboot.sh"
for dev in fe320000.mmc fe330000.mmc f8000000.pcie; do
    for f in "$uboot_sh" "$DEV/flash/boot.cmd"; do
        grep -q "$dev" "$f" || { err "$(basename "$f") never names $dev for androidboot.boot_devices"; cl_bad=$((cl_bad+1)); }
    done
done
(( cl_bad )) || ok "both boot paths set boot_devices for the card, the eMMC and the NVMe"
# Second stage mounts what first stage did not - /metadata, and /data (latemount) -
# only when the device's init rc says mount_all; rootdir/init.rc just triggers the
# stages. Without it the eighth card ran with no /data: keystore2 aborted and apexd
# rebooted the board.
init_rc="$DEV/init/init.edge1.rc"
for mode in early late; do
    if grep -vE '^\s*#' "$init_rc" | grep -qE "^\s*mount_all\s+/vendor/etc/fstab\.\\\$\{ro\.hardware\}\s+--$mode"; then
        ok "init.edge1.rc runs mount_all --$mode on the fstab"
    else
        err "init.edge1.rc has no 'mount_all /vendor/etc/fstab.\${ro.hardware} --$mode'; /data"
        err "  (and /metadata) would never be mounted"
        cl_bad=$((cl_bad+1))
    fi
done
# drm_hwcomposer must be DRM master of card0, which the kernel gives to the first
# process to open it. minigbm opens card0 as well and its allocator starts first in
# class hal, so card 12 ran headless ("DRM/KMS master access required"). The device rc
# starts the composer at late-fs, ahead of everything that opens card0.
if awk '/^on late-fs$/ {f=1; next} /^on / {f=0} f && /^[[:space:]]+start vendor\.hwcomposer-2-4[[:space:]]*$/ {found=1} END {exit !found}' "$init_rc"; then
    ok "init.edge1.rc starts the composer at late-fs, so it is first to open card0"
else
    err "init.edge1.rc does not start vendor.hwcomposer-2-4 at late-fs; the minigbm allocator"
    err "  opens card0 first, holds DRM master, and the composer runs headless"
    cl_bad=$((cl_bad+1))
fi
# First-stage init takes the vbmeta partitions to read from the DT's
# /firmware/android/vbmeta/parts or from "avb=<partition>" in the fstab; a bare "avb"
# names nothing. With avb on a first_stage_mount entry and no name anywhere, it stops
# with "Missing vbmeta partitions" - which is what the board did.
fstab_f="$DEV/fstab.edge1"
if grep -vE '^\s*#' "$fstab_f" | grep -E 'first_stage_mount' | grep -qE '(^|[ ,])avb([ ,=]|$)'; then
    if grep -vE '^\s*#' "$fstab_f" | grep -E 'first_stage_mount' | grep -qE '(^|[ ,])avb=[a-z_]+'; then
        ok "fstab names its vbmeta partition (avb=...), as first-stage init needs"
    else
        err "fstab.edge1 uses a bare 'avb' on first_stage_mount entries and names no"
        err "  vbmeta partition (avb=vbmeta); first-stage init stops: Missing vbmeta partitions"
        cl_bad=$((cl_bad+1))
    fi
fi
# What the tenth card (the first to run zygote) died of or crash-looped on.
dmk="$DEV/device.mk"; tvmk="$DEV/edge1_tv.mk"
# zygote preloads CamcorderProfile, and MediaProfiles CHECKs that the XML names a camera.
mp_src=$(grep -oE '\$\(LOCAL_PATH\)/[^ :]+:\$\(TARGET_COPY_OUT_VENDOR\)/etc/media_profiles_V1_0\.xml' "$dmk" | head -1 | sed -E 's#^\$\(LOCAL_PATH\)/##; s#:.*##')
if [[ -n "$mp_src" ]] && ! grep -q '<CamcorderProfiles' "$DEV/$mp_src"; then
    err "$mp_src has no CamcorderProfiles; zygote aborts in MediaProfiles"
    err "  (CHECK(cameraIds.size() > 0)) while preloading android.media.CamcorderProfile"
    cl_bad=$((cl_bad+1))
else
    ok "media profiles name a camera, as MediaProfiles requires"
fi
# 6.12 has no ashmem; libcutils uses memfd only when sys.use_memfd is true.
if ! grep -qE '^CONFIG_ASHMEM=y' "$DEV/kernel/edge1_mainline.config" \
   && ! { grep -qE '^PRODUCT_PRODUCT_PROPERTIES \+= sys\.use_memfd=true' "$dmk" \
          && grep -qE 'init\.edge1\.memfd\.rc:\$\(TARGET_COPY_OUT_PRODUCT\)/etc/init/' "$dmk" \
          && grep -qE '^\s+setprop sys\.use_memfd true' "$DEV/init/init.edge1.memfd.rc"; }; then
    err "no ashmem in the kernel, and sys.use_memfd is not forced true after init.rc's"
    err "  post-fs-data resets it (product property + /product init.edge1.memfd.rc);"
    err "  every ashmem region fails, and SurfaceFlinger cannot talk to the composer"
    cl_bad=$((cl_bad+1))
else
    ok "shared memory: memfd (sys.use_memfd=true) on a kernel without ashmem"
fi
# PRODUCT_PROPERTY_OVERRIDES lands in /vendor/build.prop, loaded as vendor_init,
# which may not set these system properties.
vendor_sys=$(python3 - "$dmk" "$tvmk" <<'EOF'
import re, sys
bad = {"ro.adb.secure", "persist.sys.usb.config", "sys.use_memfd", "ro.logd.size",
       "service.adb.tcp.port"}
for f in sys.argv[1:]:
    block = False
    for line in open(f):
        code = line.split("#", 1)[0].rstrip()
        if re.match(r"\s*PRODUCT_PROPERTY_OVERRIDES\s*\+?=", code):
            block = True
            code = code.split("=", 1)[1]
        elif not block:
            continue
        for word in code.replace("\\", " ").split():
            if word.split("=", 1)[0] in bad:
                print(f.rsplit("/", 1)[-1] + ": " + word)
        block = code.endswith("\\") or line.rstrip().endswith("\\")
EOF
)
if [[ -n "$vendor_sys" ]]; then
    err "system properties set through PRODUCT_PROPERTY_OVERRIDES (vendor_init may not"
    err "  set them; use PRODUCT_PRODUCT_PROPERTIES): $(echo $vendor_sys)"
    cl_bad=$((cl_bad+1))
else
    ok "no system-owned property is set from /vendor/build.prop"
fi
# The AIDL effect HAL exits without audio_effects_config.xml, taking audioserver along.
if grep -q 'android.hardware.audio.effect.service-aidl' "$dmk" \
   && ! grep -q 'TARGET_COPY_OUT_VENDOR)/etc/audio_effects_config.xml' "$dmk"; then
    err "the AIDL effect HAL is installed but no /vendor/etc/audio_effects_config.xml"
    cl_bad=$((cl_bad+1))
else
    ok "the AIDL audio effect HAL has its audio_effects_config.xml"
fi
# Shipping level <= 29 installs configstore, which no manifest declares.
ship=$(sed -nE 's/^PRODUCT_SHIPPING_API_LEVEL\s*:?=\s*([0-9]+).*/\1/p' "$tvmk" | head -1)
if [[ -n "$ship" ]] && (( ship <= 29 )); then
    if grep -qE '^LOCAL_OVERRIDES_MODULES\s*:=.*android\.hardware\.configstore@1\.1-service' "$DEV/Android.mk" 2>/dev/null \
       && grep -qE '^PRODUCT_PACKAGES \+= edge1_no_configstore' "$dmk"; then
        ok "configstore (installed for shipping level $ship) is overridden away"
    else
        err "shipping level $ship installs android.hardware.configstore@1.1-service, which no"
        err "  VINTF manifest declares; it crash-loops. Android.mk's edge1_no_configstore removes it."
        cl_bad=$((cl_bad+1))
    fi
fi
# vold must not manage the card Android boots from.
if grep -vE '^\s*#' "$fstab_f" | grep -E 'voldmanaged=' | grep -q 'fe320000\.mmc'; then
    err "fstab.edge1 hands the SD slot (fe320000.mmc), the boot card, to vold"
    cl_bad=$((cl_bad+1))
else
    ok "vold does not manage the boot card"
fi
# The bootcmd's attempts are joined with ';'. '||' there made every fallback dead.
if grep -qE '^BOOTCMD="\$BOOTCMD \|\| ' "$uboot_sh"; then
    err "build-uboot.sh joins boot attempts with '||'; hush then skips every later attempt"
    err "  when an earlier one fails before bootm. Join them with ';'."
    cl_bad=$((cl_bad+1))
else
    ok "bootcmd attempts are joined with ';', so each one runs if the last failed"
fi
echo

# --- 4. VINTF: fragments must NOT duplicate the device manifest ----------------
#
# This check used to assert the opposite - that every HAL in a fragment also
# appeared in vintf/manifest.xml - and that was backwards. Soong's
# vintf_fragments: installs each service's fragment into
# /vendor/etc/vintf/manifest/, and VINTF merges those into the device manifest at
# build time, so a HAL declared in both places is declared twice.
#
# This tree now has no fragments of its own: every HAL service on it comes from
# AOSP and carries its own. The check stays because the moment one is added, the
# question comes back - and it excludes vintf/manifest.xml itself, which would
# otherwise be read as a fragment duplicating every HAL in it.
echo "[4] VINTF: device fragments vs device manifest (duplicates are the error)"
manifest_hals=$(python3 - "$DEV/vintf/manifest.xml" <<'PYX'
import sys, xml.etree.ElementTree as ET
for hal in ET.parse(sys.argv[1]).getroot().findall("hal"):
    print(hal.findtext("name"))
PYX
)
frag_total=0
while IFS= read -r frag; do
    while IFS= read -r name; do
        frag_total=$((frag_total+1))
        if grep -qxF "$name" <<<"$manifest_hals"; then
            err "$name is declared in BOTH ${frag#$ROOT/} and vintf/manifest.xml"
        else
            ok "$name (from ${frag##*/}, not duplicated)"
        fi
    done < <(python3 - "$frag" <<'PYX'
import sys, xml.etree.ElementTree as ET
for hal in ET.parse(sys.argv[1]).getroot().findall("hal"):
    print(hal.findtext("name"))
PYX
)
done < <(find "$DEV" -name '*.xml' -path '*vintf*' ! -name 'manifest.xml' \
              ! -name 'compatibility_matrix.xml' 2>/dev/null | sort)
(( frag_total == 0 )) && ok "no device-side VINTF fragments (every HAL service is AOSP's)"
echo "  device manifest declares $(grep -c '<hal ' "$DEV/vintf/manifest.xml") HAL(s) directly"
echo

# --- 4b. VINTF: every manifest entry must be backed by an installed service ----
#
# A device manifest is a promise: this device provides this HAL at this version.
# Nothing in the build checks it. check_vintf asks whether the framework's
# requirements are met, not whether our own declarations are kept, and
# assemble_vintf just copies the entries through - so an entry for a service that
# was never installed reaches the image and surfaces as a client waiting on a HAL
# that never registers.
#
# This tree shipped one: HIDL android.hardware.drm@4.0 with clearkey instances,
# while device.mk installs android.hardware.drm-service.clearkey - the AIDL
# service, which carries its own fragment. The HIDL @4.0 clearkey service does not
# exist in AOSP 14 at all.
#
# The format matters as much as the name, which is why this does not just grep for
# the HAL name: a HIDL entry needs a package named <hal>@<version>..., an AIDL one
# needs <hal>-service... or <hal>-V<n>..., and those are different binaries.
echo "[4b] VINTF: manifest entries vs installed packages"
# Module names device.mk asks for, with continuations stripped so a name followed
# by " \" still matches.
pkgs=$(tr -d '\\' < "$DEV/device.mk" | grep -oE '^[[:space:]]*[A-Za-z0-9._@+-]+[[:space:]]*$' \
       | tr -d '[:blank:]' | sort -u)
unbacked=0
while IFS='|' read -r name fmt ver; do
    [[ -n "$name" ]] || continue
    case "$fmt" in
        hidl) want="${name}@${ver}" ;;
        *)    want="${name}-service|${name}-V" ;;
    esac
    if grep -qE "^(${want})" <<< "$pkgs"; then
        ok "$name ($fmt $ver) <- $(grep -E "^(${want})" <<< "$pkgs" | head -1)"
    else
        err "$name ($fmt $ver) is declared in vintf/manifest.xml but device.mk installs"
        err "  no package matching '${want}'; the manifest promises a service that is not there"
        unbacked=$((unbacked+1))
    fi
done < <(python3 - "$DEV/vintf/manifest.xml" <<'PYX'
import sys, xml.etree.ElementTree as ET
for hal in ET.parse(sys.argv[1]).getroot().findall("hal"):
    fmt = hal.get("format", "hidl")
    ver = hal.findtext("version") or (hal.findtext("fqname") or "").lstrip("@") or "-"
    print("%s|%s|%s" % (hal.findtext("name"), fmt, ver))
PYX
)
(( unbacked )) || ok "every manifest entry has a package behind it"
echo

# --- 5. Android 10 constructs Android 14 removed ------------------------------
echo "[5] obsolete Android 10 constructs"
declare -A obsolete=(
    [BUILD_EMULATOR]="deleted from build/make in Android 11"
    [TARGET_USES_64_BIT_BINDER]="binder has been 64-bit unconditionally since 8.0"
    [OVERRIDE_RS_DRIVER]="RenderScript was removed from the platform in Android 12"
    [BOARD_OVERRIDE_RS_CPU_VARIANT]="RenderScript was removed in Android 12"
    [ro.sys.sdcardfs]="sdcardfs was replaced by FUSE in Android 11"
    [PRODUCT_AAPT_PREF_CONFIG=hdpi]="a TV product should prefer tvdpi"
    [BOARD_SEPOLICY_DIRS]="split per-partition in Android 11; use BOARD_VENDOR_SEPOLICY_DIRS"
    [TARGET_CPU_SMP]="unused since Android 5"
    [libstagefright_soft_]="the soft codec modules were removed after Android 9"
    [DefaultContainerService]="removed after Android 9"
    [local_time.default]="removed after Android 9"
)
for pat in "${!obsolete[@]}"; do
    hits=$(grep -rln -- "$pat" "$DEV" 2>/dev/null | grep -vE '/(docs|README)' || true)
    if [[ -n "$hits" ]]; then
        while IFS= read -r h; do
            # A mention inside a comment is documentation, not usage.
            if grep -n -- "$pat" "$h" | grep -qvE '^\s*[0-9]+:\s*(#|//|\*|<!--)'; then
                err "$pat used in ${h#$ROOT/} - ${obsolete[$pat]}"
            fi
        done <<<"$hits"
    fi
done
(( errors == 0 )) && ok "none found"
echo

# --- 6. Shell script syntax ---------------------------------------------------
echo "[6] shell script syntax"
while IFS= read -r s; do
    if bash -n "$s" 2>/dev/null; then ok "${s#$ROOT/}"; else err "${s#$ROOT/} has a syntax error"; fi
done < <(find "$ROOT/build" "$DEV" -name '*.sh' 2>/dev/null | sort)
echo

# --- 7. Kernel config sanity --------------------------------------------------
echo "[7] kernel config fragment"
readonly FRAG="$DEV/kernel/edge1_mainline.config"
if [[ -f "$FRAG" ]]; then
    # Symbols that are mandatory for Android 14 to boot at all.
    # The first six are Android's; the rest are what Path B rests on - panfrost
    # for GLES, Rockchip DRM for KMS, brcmfmac for Wi-Fi, rkvdec for decode. A
    # module rather than a built-in would be just as fatal here: this layout has
    # no vendor_dlkm and loads nothing in first-stage init.
    for must in CONFIG_ANDROID_BINDERFS CONFIG_BPF_SYSCALL CONFIG_PSI \
                CONFIG_FS_ENCRYPTION CONFIG_DM_VERITY CONFIG_USERFAULTFD \
                CONFIG_DRM_PANFROST CONFIG_DRM_ROCKCHIP CONFIG_ROCKCHIP_DW_HDMI \
                CONFIG_BRCMFMAC CONFIG_BRCMFMAC_SDIO CONFIG_VIDEO_ROCKCHIP_VDEC \
                CONFIG_SND_SIMPLE_CARD CONFIG_DRM_DW_HDMI_I2S_AUDIO \
                CONFIG_SECURITY_SELINUX CONFIG_PSTORE_RAM; do
        grep -qE "^${must}=y" "$FRAG" && ok "$must=y" || err "$FRAG is missing ${must}=y"
    done
    # Built is not enabled. make defconfig fixes the LSM list before the fragment is
    # merged, without selinux, and olddefconfig keeps it; the first kernel on the
    # board printed "LSM: initializing lsm=capability" and first-stage init died
    # mounting selinuxfs. So the fragment must state the list, with selinux in it.
    # binderfs creates, at each mount, exactly the devices this names; init.rc only
    # symlinks /dev/binder, /dev/hwbinder and /dev/vndbinder into it. Empty, all three
    # dangle and no service manager can start.
    bdev="$(sed -n 's/^CONFIG_ANDROID_BINDER_DEVICES="\(.*\)"$/\1/p' "$FRAG")"
    missing_b=""
    for b in binder hwbinder vndbinder; do [[ ",$bdev," == *,$b,* ]] || missing_b+=" $b"; done
    if [[ -z "$missing_b" ]]; then
        ok "CONFIG_ANDROID_BINDER_DEVICES lists binder, hwbinder and vndbinder"
    else
        err "$FRAG: CONFIG_ANDROID_BINDER_DEVICES=\"$bdev\" lacks$missing_b; binderfs would"
        err "  not create them and init.rc's /dev symlinks would dangle"
    fi
    lsm="$(sed -n 's/^CONFIG_LSM="\(.*\)"$/\1/p' "$FRAG")"
    if [[ ",$lsm," == *,selinux,* ]]; then
        ok "CONFIG_LSM names selinux ($lsm)"
    else
        err "$FRAG does not set CONFIG_LSM with selinux in it; SELinux would be built"
        err "  but never initialised, and first-stage init cannot mount selinuxfs"
    fi
    # "CONFIG_X=n" is not how Kconfig disables a symbol. merge_config.sh reports
    # the line as redefining the value and then keeps the base setting, so the
    # fragment silently has no effect. The correct form is
    # "# CONFIG_X is not set". Three of these were shipped before this check.
    while read -r bad; do
        err "$FRAG uses '$bad'; Kconfig needs '# ${bad%=n} is not set'"
    done < <(grep -oE '^CONFIG_[A-Z0-9_]+=n$' "$FRAG" || true)

    # Comments must not shadow a symbol the fragment sets, and must not look like a
    # directive.
    #
    # merge_config.sh collects what to merge with two sed patterns:
    #
    #   s/^\(CONFIG_[a-zA-Z0-9_]*\)=.*/\1/p
    #   s/^# \(CONFIG_[a-zA-Z0-9_]*\) is not set$/\1/p
    #
    # and then reads the value back with "grep -w $CFG $MERGE_FILE". So a comment
    # that mentions a symbol the fragment also sets makes that grep return two
    # lines, and the override warning prints the comment as the new value:
    #
    #   New value: # ... "NOT SET: CONFIG_DWMAC_ROCKCHIP=y". CONFIG_DWMAC_ROCKCHIP=y
    #
    # The merge itself is unaffected - it appends the whole fragment and runs
    # olddefconfig - but the one report that says whether a symbol took becomes
    # unreadable, and without -m the same artifact makes merge_config claim the
    # value is missing from the final .config. Write the bare name in prose.
    #
    # The second pattern is the sharper edge: "# CONFIG_X is deliberately absent"
    # is inert, but it is four words away from being read as a directive to turn X
    # off. Only the exact "is not set" form may start a comment with CONFIG_.
    set_syms=$(grep -oE '^CONFIG_[A-Z0-9_]+' "$FRAG" | sed 's/^CONFIG_//' | sort -u)
    shadowed=0
    while read -r sym; do
        [[ -n "$sym" ]] || continue
        while IFS= read -r n; do
            err "$FRAG:$n mentions CONFIG_${sym} in a comment, and the fragment sets it;"
            err "  merge_config.sh's value lookup is a grep, so its report becomes unreadable"
            shadowed=$((shadowed+1))
        done < <(grep -nE "^[[:space:]]*#.*CONFIG_${sym}([^A-Z0-9_]|$)" "$FRAG" | cut -d: -f1)
    done <<< "$set_syms"
    while IFS= read -r line; do
        n="${line%%:*}"
        err "$FRAG:$n starts a comment with '# CONFIG_' but is not the exact"
        err "  '# CONFIG_X is not set' form; that is one edit away from silently disabling it"
        shadowed=$((shadowed+1))
    done < <(grep -nE '^# CONFIG_[A-Za-z0-9_]+' "$FRAG" \
             | grep -vE '^[0-9]+:# CONFIG_[A-Za-z0-9_]+ is not set$' || true)
    (( shadowed )) || ok "no comment shadows a symbol the fragment sets"

    # Contradictions: a symbol both set and unset.
    while read -r sym; do
        if grep -qE "^CONFIG_${sym}=" "$FRAG" && grep -qE "^# CONFIG_${sym} is not set" "$FRAG"; then
            err "CONFIG_${sym} is both set and unset in the fragment"
        fi
    done < <(grep -oE '^CONFIG_[A-Z0-9_]+' "$FRAG" | sed 's/^CONFIG_//' | sort -u)
else
    err "missing $FRAG"
fi
echo

# --- 8. Lunch combo form ------------------------------------------------------
# Android 14 requires <product>-<release>-<variant> and rejects a two-part combo
# outright, so a wrong form here is not a warning, it is a build that never
# starts. Both places that spell the combo out are checked, and against each
# other: build.sh composes it, AndroidProducts.mk lists it for the menu.
echo "[8] lunch combo form"
readonly PRODUCTS_MK="$DEV/AndroidProducts.mk"
if [[ -f "$PRODUCTS_MK" ]]; then
    combos=$(sed -n '/^COMMON_LUNCH_CHOICES/,/[^\\]$/p' "$PRODUCTS_MK" \
             | grep -oE '[a-z0-9_]+-[a-z0-9_]+(-[a-z0-9_]+)?' || true)
    if [[ -z "$combos" ]]; then
        err "$PRODUCTS_MK declares no COMMON_LUNCH_CHOICES"
    fi
    while read -r c; do
        [[ -n "$c" ]] || continue
        if [[ "$(tr -cd - <<< "$c" | wc -c)" -eq 2 ]]; then
            ok "$c"
        else
            err "'$c' is not <product>-<release>-<variant>; Android 14 lunch rejects it"
        fi
    done <<< "$combos"
fi
if [[ -f "$ROOT/build/build.sh" ]]; then
    if grep -qE 'TARGET="[a-z0-9_]+-\$\{RELEASE\}-\$\{VARIANT\}"' "$ROOT/build/build.sh"; then
        ok "build.sh composes product-release-variant"
    else
        err "build.sh does not compose a three-part lunch target"
    fi
fi
echo

# --- 9. sepolicy self-consistency -------------------------------------------
# Until now none of this was compiled: the device tree was a symlink and Soong's
# finder does not walk into those, so BOARD_VENDOR_SEPOLICY_DIRS pointed at
# something it never read. Now that it does, a type referenced by a *_contexts
# file and declared nowhere is a build failure, and a declared exec type that no
# file_contexts line labels is a service that can never enter its domain - which
# fails silently, as denials at runtime.
echo "[9] sepolicy self-consistency"
readonly SEDIR="$DEV/sepolicy/vendor"
if [[ -d "$SEDIR" ]]; then
    # Two ways a type gets declared, and missing the second one made this check
    # report seven false positives on its first run: 'type foo, ...' and the
    # property macros, which expand to a type declaration plus its attributes.
    declared=$( { grep -h '^type ' "$SEDIR"/*.te 2>/dev/null \
                    | sed -E 's/^type ([a-z0-9_]+).*/\1/'
                  grep -hoE '^[a-z_]*_prop\([a-z0-9_]+' "$SEDIR"/*.te 2>/dev/null \
                    | sed -E 's/.*\(//'
                } | sort -u)
    # Types this tree knowingly takes from AOSP's own policy - borrowed, never
    # declared here. Listed rather than matched by pattern: if a release renames
    # one, this is where it surfaces.
    #
    # This list is a claim, not evidence, and it has been wrong in both directions.
    # sysfs_devfreq and vendor_firmware_file were on it and AOSP 14 defines
    # neither, so both are declared in this tree now and both came off the list.
    # sysfs_gpu was the other direction: it was declared here, AOSP declares it
    # too, and checkpolicy rejected the second declaration six minutes into a
    # build. The module probe resolves this list against the synced
    # system/sepolicy and prints every type this device declares with whether AOSP
    # already has it - that is the authoritative answer, and it gates the run.
    #
    # The six *_block_device types label the boot medium's partitions. GloDroid's
    # RK3399 vendor file_contexts uses five of them (not recovery_block_device)
    # against AOSP 14; all six are public/device.te types.
    aosp_types="gpu_device graphics_device hal_bluetooth_default_exec
                vendor_kernel_modules vendor_file
                vendor_configs_file sysfs_type sysfs_gpu sysfs_leds
                sysfs_thermal sysfs_devices_system_cpu video_device
                super_block_device metadata_block_device userdata_block_device
                misc_block_device boot_block_device recovery_block_device
                hal_graphics_allocator_default_exec same_process_hal_file"
    missing_types=0
    while read -r t; do
        [[ -n "$t" ]] || continue
        grep -qx "$t" <<< "$declared" && continue
        grep -qw "$t" <<< "$aosp_types" && continue
        err "$SEDIR labels '$t', which is declared in no .te file here and is not"
        err "  in the list of AOSP types this tree relies on"
        missing_types=$((missing_types+1))
    done < <(grep -hoE 'u:object_r:[a-z0-9_]+' "$SEDIR"/*_contexts 2>/dev/null \
             | sed 's/u:object_r://' | sort -u)
    (( missing_types )) || ok "every labelled type is declared or a known AOSP type"

    # The other direction. A type declared here that AOSP also declares is a
    # duplicate declaration, which checkpolicy treats as fatal - and it fails on
    # the first one only, so the build reveals them one per run.
    dupe_types=0
    while read -r t; do
        [[ -n "$t" ]] || continue
        if grep -qw "$t" <<< "$aosp_types"; then
            err "$t is declared in $SEDIR and is an AOSP type; checkpolicy calls that"
            err "  a duplicate declaration. Drop the local 'type' line and keep labelling with it."
            dupe_types=$((dupe_types+1))
        fi
    done <<< "$declared"
    (( dupe_types )) || ok "no locally declared type collides with a known AOSP type"

    # Specifications AOSP's own file_contexts already has. The platform file and
    # ours are concatenated and compiled as one, and checkfc rejects the same
    # specification twice:
    #
    #   file_contexts.concat.tmp: Multiple same specifications for /dev/video[0-9]*.
    #   Error: could not load context file from ...
    #
    # "Same specification" is the identical regex text, not an overlapping path:
    # /dev/dri/card0 next to AOSP's /dev/dri/card[0-9]* is fine and the more
    # specific one wins. So this list holds exact spellings, and like aosp_types it
    # is a claim - the module probe resolves ours against the synced
    # system/sepolicy and gates the run on it.
    plat_specs="/dev/video[0-9]*"
    dupe_specs=0
    while IFS= read -r spec; do
        [[ -n "$spec" ]] || continue
        if grep -qxF "$spec" <<< "$plat_specs"; then
            err "$SEDIR/file_contexts declares '$spec', which AOSP's file_contexts also"
            err "  declares verbatim; checkfc refuses to load the concatenated file"
            dupe_specs=$((dupe_specs+1))
        fi
    done < <(sed 's/#.*//' "$SEDIR/file_contexts" 2>/dev/null | awk 'NF>=2 {print $1}' | sort -u)
    (( dupe_specs )) || ok "no file_contexts spec collides with a known AOSP one"

    # An exec type nothing labels means the domain transition never happens.
    unused=0
    while read -r t; do
        [[ -n "$t" ]] || continue
        grep -q "$t" "$SEDIR/file_contexts" 2>/dev/null && continue
        err "$t is declared but no file_contexts line labels any binary with it"
        unused=$((unused+1))
    done < <(grep -x '.*_exec' <<< "$declared" || true)
    (( unused )) || ok "every declared exec type labels a binary"
else
    warn "no sepolicy directory at $SEDIR"
fi
echo

# --- 9b. dangling line continuations ------------------------------------------
# A make line ending in a backslash swallows the next line. When editing removed
# the items from a list but left the "VAR += \" behind, the following comment
# became the value - which make accepts silently and which no other check here
# would notice.
echo "[9b] dangling line continuations"
dangling=0
for mk in "$DEV"/*.mk; do
    while IFS= read -r n; do
        err "$(basename "$mk"):$n ends in a backslash and the next line is a comment or blank"
        dangling=$((dangling+1))
    done < <(awk '/\\$/ { c=NR; if ((getline nxt) > 0 && nxt ~ /^[[:space:]]*(#|$)/) print c }' "$mk")
done
(( dangling )) || ok "no list continues into a comment or a blank line"
echo

# --- 9c. audio policy: self-contained, valid against the HAL's schema -------
# The AIDL audio HAL builds its modules from /vendor/etc/audio_policy_configuration.xml
# and treats a file it cannot parse as having none: no IModule/default, audioserver
# waits for it forever, system_server's AudioService waits for audioserver, and the
# watchdog kills system_server (the tenth card, three times). The file it rejected was
# in the old HIDL format and leaned on xi:include for files from AOSP modules whose
# install location this tree does not control.
#
# So: no xi:include at all, and the file must validate against the HAL's own schema
# (build/schema/audio_policy_configuration.xsd, from
# hardware/interfaces/audio/aidl/default/config/audioPolicy).
echo "[9c] audio policy: self-contained and schema-valid"
readonly APC="$DEV/audio/audio_policy_configuration.xml"
readonly APC_XSD="$ROOT/build/schema/audio_policy_configuration.xsd"
if [[ -f "$APC" ]]; then
    if grep -q '<xi:include' "$APC"; then
        err "audio_policy_configuration.xml uses xi:include; an include that does not resolve on"
        err "  the device makes the HAL reject the whole file. Inline it."
    else
        ok "audio_policy_configuration.xml includes nothing"
    fi
    if ! command -v xmllint >/dev/null; then
        wrn "xmllint not installed; audio_policy_configuration.xml not checked against the schema"
    elif xmlerr=$(xmllint --noout --schema "$APC_XSD" "$APC" 2>&1); then
        ok "audio_policy_configuration.xml validates against the AIDL HAL's schema"
    else
        err "audio_policy_configuration.xml does not validate against $(basename "$APC_XSD"):"
        while IFS= read -r l; do err "  $l"; done < <(grep -v 'fails to validate' <<< "$xmlerr" | head -5)
    fi
    # What the schema cannot say but the HAL's converter enforces with an abort
    # (XsdcConversion.cpp, convertDevicePortsInModuleToAidl / getSourcePortIds), and
    # what its primary module cannot do (ModulePrimary connects no external device).
    # Card 12 aborted on the first of these 129 times.
    if apc_rules=$(python3 - "$APC" <<'EOF'
import re, sys
import xml.etree.ElementTree as ET
# AIDL device types with an empty connection: the only ones <attachedDevices> may
# hold. Everything external has a connection (hdmi, usb, analog, bt-*, ...).
BUILTIN = {"AUDIO_DEVICE_OUT_EARPIECE", "AUDIO_DEVICE_OUT_SPEAKER",
           "AUDIO_DEVICE_OUT_SPEAKER_SAFE", "AUDIO_DEVICE_OUT_TELEPHONY_TX",
           "AUDIO_DEVICE_IN_BUILTIN_MIC", "AUDIO_DEVICE_IN_BACK_MIC",
           "AUDIO_DEVICE_IN_ECHO_REFERENCE", "AUDIO_DEVICE_IN_TELEPHONY_RX"}
EXTERNAL = re.compile(r"HDMI|AUX_DIGITAL|USB|WIRED|LINE|SPDIF|BLUETOOTH|BLE_|_IP$|"
                      r"HEARING_AID|REMOTE_SUBMIX|DOCK|BUS$")
bad = []
# The IModule instances com.android.hardware.audio declares in its VINTF fragment
# (hardware/interfaces/audio/aidl/default/android.hardware.audio.service-aidl.xml).
# audioserver waits for each declared one, the HAL creates only the modules this
# file names, and servicemanager refuses to register an undeclared one - so the
# two sets have to match. Card 13 hung on a missing bluetooth.
DECLARED = {"default", "r_submix", "bluetooth"}
have = {("default" if m.get("name") == "primary" else m.get("name"))
        for m in ET.parse(sys.argv[1]).getroot().iter("module")}
for n in sorted(DECLARED - have):
    bad.append(f"no module for IModule/{n}, which the APEX declares; audioserver waits for it forever")
for n in sorted(have - DECLARED):
    bad.append(f"module {n} is not declared by the APEX; servicemanager will not register IModule/{n}")
for m in ET.parse(sys.argv[1]).getroot().iter("module"):
    name = m.get("name")
    if name == "r_submix":
        continue                       # the HAL ignores its XML (built-in config)
    attached = {i.text.strip() for i in m.iter("item")}
    ports = {}
    for d in m.iter("devicePort"):
        t = d.get("type")
        if t in BUILTIN:
            ext = False
        elif EXTERNAL.search(t):
            ext = True
        else:
            bad.append(f"{name}: device type {t} is not classified in verify-tree 9c")
            continue
        ports[d.get("tagName")] = ext
        if (d.get("tagName") in attached) == ext:
            bad.append(f"{name}: \"{d.get('tagName')}\" ({t}) is "
                       + ("external but listed in <attachedDevices>" if ext
                          else "built-in but not in <attachedDevices>"))
        if ext and name == "primary":
            bad.append(f"{name}: external device \"{d.get('tagName')}\" ({t}); the primary"
                       " module cannot connect external devices")
    names = set(ports) | {x.get("name") for x in m.iter("mixPort")}
    for r in m.iter("route"):
        for end in [r.get("sink")] + [x.strip() for x in r.get("sources").split(",")]:
            if end not in names:
                bad.append(f"{name}: route names \"{end}\", which is no port of this module")
    dflt = m.find("defaultOutputDevice")
    if dflt is not None and dflt.text.strip() not in attached:
        bad.append(f"{name}: defaultOutputDevice \"{dflt.text.strip()}\" is not attached")
print("\n".join(bad))
sys.exit(1 if bad else 0)
EOF
    ); then
        ok "audio policy obeys the HAL's module, attached-device and route rules"
    else
        err "audio_policy_configuration.xml breaks what the AIDL HAL and audioserver need:"
        while IFS= read -r l; do err "  $l"; done <<< "$apc_rules"
    fi
fi
echo

# --- 9d. vendor property namespace --------------------------------------------
# A vendor partition may only own properties under a fixed set of prefixes.
# system/sepolicy's check_prop_prefix enforces it on the merged vendor
# property_contexts, and VTS enforces the same list on device
# (test/vts-testcase/security/system_property/vts_treble_sys_prop_test.py).
#
# The check runs at 71% of a full build. A "sys.hwc." line here cost six hours to
# find out that Rockchip's hwcomposer properties are not ours to label - so the
# same rule is applied here, where it costs a second.
echo "[9d] vendor property namespace"
readonly PCTX="$DEV/sepolicy/vendor/property_contexts"
# The list check_prop_prefix prints when it rejects a file. Order matters only for
# readability; every entry is a literal prefix.
readonly ALLOWED_PREFIXES=(
    'ctl.odm.' 'ctl.vendor.' 'ctl.start$odm.' 'ctl.start$vendor.'
    'ctl.stop$odm.' 'ctl.stop$vendor.' 'init.svc.odm.' 'init.svc.vendor.'
    'ro.boot.' 'ro.hardware.' 'ro.odm.' 'ro.vendor.' 'odm.'
    'persist.odm.' 'persist.vendor.' 'vendor.' 'persist.camera.'
)
# The file is absent as of now, and its absence is the correct state - see
# sepolicy/vendor/README.md. The check stays because the next vendor property that
# does need a label has to satisfy this rule, and because the two rules it encodes
# are not obvious: an allowed prefix is necessary and not sufficient. The second
# half - the name must not be one system/sepolicy already matches exactly - needs
# the synced tree, so it lives in the module probe and gates the run there.
if [[ -f "$PCTX" ]]; then
    while read -r name _rest; do
        [[ -n "$name" ]] || continue
        [[ "$name" == \#* ]] && continue
        allowed=0
        for pre in "${ALLOWED_PREFIXES[@]}"; do
            [[ "$name" == "$pre"* ]] && { allowed=1; break; }
        done
        if (( allowed )); then
            ok "$name"
        else
            err "$name is not a prefix a vendor partition may own; check_prop_prefix will fail the build"
        fi
    done < "$PCTX"
    # Every type used here has to be declared, and every declared type used - an
    # unused vendor_*_prop is dead policy, and an undeclared one fails the compile.
    used=$(grep -v '^[[:space:]]*#' "$PCTX" | grep -oE 'u:object_r:[a-z0-9_]+:s0' \
           | sed -E 's/u:object_r:([a-z0-9_]+):s0/\1/' | sort -u)
    declared=$(grep -hoE '^[[:space:]]*vendor_(internal|restricted|public)_prop\([a-z0-9_]+\)' \
               "$DEV/sepolicy/vendor/property.te" 2>/dev/null \
               | sed -E 's/.*\(([a-z0-9_]+)\)/\1/' | sort -u)
    for t in $used; do
        grep -qxF "$t" <<< "$declared" || err "$t is labelled in property_contexts but declared in no property.te"
    done
    for t in $declared; do
        if grep -qxF "$t" <<< "$used"; then
            ok "$t declared and used"
        else
            wrn "$t is declared in property.te but labels nothing"
        fi
    done
else
    ok "no vendor property labels (see sepolicy/vendor/README.md), nothing to check"
fi
echo

# --- 9e. properties the build already emits -----------------------------------
# core/main.mk derives a set of properties from board and product variables and
# appends them to ADDITIONAL_VENDOR_PROPERTIES / ADDITIONAL_SYSTEM_PROPERTIES.
# Setting one of those by hand as well produces two assignments in the same
# build.prop, and post_process_props.py stops the build unless the two values are
# identical (tools/post_process_props.py:112-117):
#
#   error: found duplicate sysprop assignments:
#   ro.product.board=
#   ro.product.board=rk3399
#
# That empty one is what the build emitted, from an unset
# TARGET_BOOTLOADER_BOARD_NAME. The identical-values escape is what makes this
# worth a check rather than a comment: ro.board.platform was also set twice and
# passed, so it sat there as an error waiting for the two to diverge.
#
# The variable to set instead is in the right-hand column. Line numbers are from
# android-14.0.0_r75.
echo "[9e] properties core/main.mk already emits"
# property|the variable that feeds it|where
readonly DERIVED_PROPS=(
    'ro.product.board|TARGET_BOOTLOADER_BOARD_NAME|main.mk:335'
    'ro.board.platform|TARGET_BOARD_PLATFORM|main.mk:336'
    'ro.hwui.use_vulkan|TARGET_USES_VULKAN|main.mk:337'
    'ro.sf.lcd_density|TARGET_SCREEN_DENSITY|main.mk:341'
    'ro.product.first_api_level|PRODUCT_SHIPPING_API_LEVEL|main.mk:284'
    'ro.vendor.api_level|PRODUCT_SHIPPING_VENDOR_API_LEVEL|main.mk:289'
    'ro.board.first_api_level|BOARD_SHIPPING_API_LEVEL|main.mk:304'
    'ro.board.api_level|BOARD_API_LEVEL|main.mk:311'
    'ro.boot.dynamic_partitions|PRODUCT_USE_DYNAMIC_PARTITIONS|main.mk:274'
    'ro.build.ab_update|AB_OTA_UPDATER|main.mk:346'
    'ro.vendor.build.security_patch|VENDOR_SECURITY_PATCH|main.mk:334'
    'ro.product.cpu.pagesize.max|TARGET_MAX_PAGE_SIZE_SUPPORTED|main.mk:370'
    'ro.minui.default_rotation|TARGET_RECOVERY_DEFAULT_ROTATION|main.mk:261'
    'ro.minui.pixel_format|TARGET_RECOVERY_PIXEL_FORMAT|main.mk:269'
)
derived=0
# Comments are stripped before matching: these property names are discussed in the
# comments here and in the makefiles on purpose, and a comment is not a setting.
for mkfile in "$DEV"/*.mk; do
    for entry in "${DERIVED_PROPS[@]}"; do
        IFS='|' read -r prop var where <<< "$entry"
        while IFS= read -r n; do
            err "$(basename "$mkfile"):$n sets ${prop} by hand; the build emits it from"
            err "  ${var} (${where}). Set that variable instead."
            derived=$((derived+1))
        done < <(sed 's/#.*//' "$mkfile" | grep -nE "(^|[[:space:]])${prop}=" | cut -d: -f1)
    done
done
(( derived )) || ok "no product makefile sets a property core/main.mk derives"
echo

# --- 10. variable ownership --------------------------------------------------
# Product config runs before BoardConfig.mk and freezes the product variables, so
# a PRODUCT_* assignment in BoardConfig.mk is fatal:
#
#   BoardConfig.mk:101: error: cannot assign to readonly variable:
#       PRODUCT_USE_DYNAMIC_PARTITIONS
#
# The mirror image is not fatal - a BOARD_* variable set from a product makefile
# is evaluated early enough to survive - but it is an ordering dependency that
# breaks quietly, so it warns.
echo "[10] variable ownership"
if [[ -f "$DEV/BoardConfig.mk" ]]; then
    bad=$(grep -nE '^[[:space:]]*PRODUCT_[A-Z_0-9]+[[:space:]]*[:+?]?=' \
          "$DEV/BoardConfig.mk" || true)
    if [[ -n "$bad" ]]; then
        while read -r l; do
            err "BoardConfig.mk:$l is a product variable; product config already froze it"
        done <<< "$bad"
    else
        ok "BoardConfig.mk assigns no product variables"
    fi
fi
for pmk in "$DEV/edge1_tv.mk" "$DEV/device.mk"; do
    [[ -f "$pmk" ]] || continue
    bad=$(grep -nE '^[[:space:]]*(BOARD|TARGET)_[A-Z_0-9]+[[:space:]]*[:+?]?=' "$pmk" || true)
    if [[ -n "$bad" ]]; then
        while read -r l; do
            warn "$(basename "$pmk"):$l is a board variable in a product makefile"
        done <<< "$bad"
    else
        ok "$(basename "$pmk") assigns no board variables"
    fi
done
echo

echo "=========================================="
echo "errors: $errors   warnings: $warns"
(( errors )) && exit 1
exit 0
