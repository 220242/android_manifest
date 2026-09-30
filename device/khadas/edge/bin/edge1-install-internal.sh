#!/system/bin/sh
#
# Khadas Edge1 - install the running SD card onto the eMMC or the M.2 NVMe.
#
#   sh /vendor/bin/edge1-install-internal.sh <emmc|nvme> [--yes]
#                                             [--with-bootloader|--keep-bootloader]
#
# Run it on the board, as root, from the Android that is running off the card:
#
#   adb root
#   adb shell sh /vendor/bin/edge1-install-internal.sh emmc
#
# ---------------------------------------------------------------------------
# Why this exists rather than an image file
#
# out/target/product/edge/ also holds edge1-emmc.img and edge1-nvme.img, and either
# can be written with Etcher while U-Boot exposes the target over USB ("ums 0 mmc 0").
# That needs a serial console to reach the U-Boot prompt. This script needs nothing
# but adb, and it has one property the fixed images cannot have: it partitions the
# target to its real size, so userdata gets the whole 128GB SSD instead of the 14GB
# the image was built for.
#
# It copies partition by partition out of the running card. The card already holds
# every image byte for byte in its own partitions, so there is nothing to carry and
# nothing to unpack.
#
# ---------------------------------------------------------------------------
# What it does NOT do
#
#   - It does not touch the card it is running from.
#   - It does not copy userdata or metadata. Android formats both on first boot;
#     copying an encrypted /data to another device would be pointless and wrong.
#   - For nvme it does not write a bootloader, because it cannot. The RK3399
#     BootROM's boot sources are NAND, eMMC, SPI NOR, SPI NAND, SD, UFS, I2C, SPI
#     and USB - PCIe is not one of them. An NVMe install therefore still needs
#     U-Boot on the eMMC or on the card. Install to the eMMC first if the board is
#     to run from the SSD with no card in it.
#
#   - It does not replace a working bootloader with an untried one. See below.
#
# After an eMMC install the card still wins on the next boot, whichever U-Boot is on
# the eMMC: ours tries the card before the eMMC before the NVMe, and a distro U-Boot
# (Armbian's) scans the card first and runs its bootfs script. Remove the card to
# boot what was just installed; put it back to get the card again.
#
# ---------------------------------------------------------------------------
# The bootloader, and why it is not always copied
#
# The RK3399 BootROM prefers the eMMC to the card. So on a board whose eMMC already
# boots something, the Android running now was very likely started by THAT U-Boot,
# through the boot script on the card's partition 1 - and the U-Boot on the card has
# never run on this board at all. Copying it onto the eMMC would replace a
# bootloader that is known to work with one that is not, on the one medium the
# board cannot boot around without TST mode or a maskrom tool.
#
# So the U-Boot that started this system decides, read from
# /proc/device-tree/chosen/u-boot,version, which every U-Boot writes:
#
#   the card's own     it has run here, so it is copied. This is also the case on
#                      a board with an empty eMMC, or with U-Boot in SPI NOR.
#   anything else      the eMMC's bootloader area (sectors 64 up to 16MiB) is left
#                      exactly as it is. That U-Boot's distro boot finds bootfs on
#                      the eMMC's partition 1 and boots the installed Android the
#                      same way it booted the card. sgdisk --zap-all rewrites only
#                      the GPT at the start and end of the disk, so it is not
#                      touched by repartitioning either.
#
# --with-bootloader and --keep-bootloader override the choice.
# ---------------------------------------------------------------------------

set -u

LAYOUT=/vendor/etc/edge1-partitions.tsv
FIRST_PART_MIB=16
UBOOT_SEEK_SECTORS=64

die() { echo "error: $*" >&2; exit 1; }

TARGET="${1:-}"
ASSUME_YES=0
BOOTLOADER=auto
[ $# -gt 0 ] && shift
for arg in "$@"; do
    case "$arg" in
        --yes)             ASSUME_YES=1 ;;
        --with-bootloader) BOOTLOADER=copy ;;
        --keep-bootloader) BOOTLOADER=keep ;;
        *) echo "unknown option: $arg" >&2; TARGET= ;;
    esac
done

case "$TARGET" in
    emmc|nvme) ;;
    *) echo "usage: $0 <emmc|nvme> [--yes] [--with-bootloader|--keep-bootloader]" >&2; exit 1 ;;
esac

[ "$(id -u)" = "0" ] || die "must run as root (adb root, or su)"
[ -f "$LAYOUT" ] || die "no partition layout at $LAYOUT"

for t in sgdisk dd; do
    command -v "$t" >/dev/null 2>&1 || die "$t is not on this image; cannot partition the target"
done

# ---------------------------------------------------------------------------
# Find the target, from sysfs rather than by guessing a device name.
#
# mmcblk numbering depends on probe order and is not stable, so "the eMMC is
# mmcblk2" is a guess that silently becomes wrong. The controller address is not a
# guess: rk3399-base.dtsi names the eMMC controller sdhci@fe330000 and the SD slot
# mmc@fe320000, and U-Boot's arch/arm/mach-rockchip/rk3399/rk3399.c:27-31 states
# the same mapping from the BootROM's side. So the eMMC is whatever block device
# hangs off fe330000.
# ---------------------------------------------------------------------------
find_emmc() {
    for d in /sys/devices/platform/fe330000.*/mmc_host/mmc*/mmc*/block/*; do
        [ -d "$d" ] || continue
        echo "/dev/block/$(basename "$d")"
        return 0
    done
    return 1
}
find_nvme() {
    for d in /sys/class/block/nvme*n1; do
        [ -e "$d" ] || continue
        echo "/dev/block/$(basename "$d")"
        return 0
    done
    return 1
}

if [ "$TARGET" = emmc ]; then
    DEV="$(find_emmc)" || die "no eMMC found under /sys/devices/platform/fe330000.*
Either this board has none, or the controller did not probe - check dmesg for sdhci."
else
    DEV="$(find_nvme)" || die "no NVMe found. Check that the M.2 card is seated and that
dmesg shows the PCIe link coming up; the rk3399 pcie driver has to bring it up."
fi
[ -b "$DEV" ] || die "$DEV is not a block device"

# ---------------------------------------------------------------------------
# Refuse to write the disk we are running from. This is the one mistake that
# cannot be undone, so it is checked rather than assumed: resolve where
# /dev/block/by-name/super actually lives and compare the parent disk.
# ---------------------------------------------------------------------------
SRC_PART="$(readlink -f /dev/block/by-name/super 2>/dev/null || true)"
[ -n "$SRC_PART" ] || die "no /dev/block/by-name/super - is this the Android built by this tree?"
SRC_SYS="$(readlink -f "/sys/class/block/$(basename "$SRC_PART")" 2>/dev/null || true)"
SRC_DISK="/dev/block/$(basename "$(dirname "$SRC_SYS")")"
if [ "$SRC_DISK" = "$DEV" ]; then
    die "the running system is already on $DEV. There is nothing to install,
and writing it would destroy the system doing the writing."
fi

# Anything mounted from the target has to go first, or the copy races the filesystem.
# wc -l rather than grep -c: grep -c prints 0 AND exits 1 when it matches nothing,
# so "grep -c ... || echo 0" appends a second 0 and the count reads "0\n0" - which is
# not "0", so the check fired on every run and no install could ever start. wc always
# exits 0 and prints one number.
MOUNTED="$(grep "^${DEV}" /proc/mounts 2>/dev/null | wc -l | tr -d ' ')"
if [ "$MOUNTED" != "0" ]; then
    echo "these are mounted from $DEV and must be unmounted first:" >&2
    grep "^${DEV}" /proc/mounts | sed 's/^/  /' >&2
    die "unmount them (or 'sm forget all' if vold adopted the disk) and re-run"
fi

DEV_BYTES="$(cat "/sys/class/block/$(basename "$DEV")/size" 2>/dev/null)"
[ -n "$DEV_BYTES" ] || die "cannot read the size of $DEV"
DEV_BYTES=$(( DEV_BYTES * 512 ))
DEV_MIB=$(( DEV_BYTES / 1024 / 1024 ))

# ---------------------------------------------------------------------------
# Plan the layout: the fixed partitions from the tsv, and the last one takes
# whatever is left on this particular disk. 1MiB at the end for the secondary GPT.
# ---------------------------------------------------------------------------
FIXED_MIB=0
REST_NAME=
while IFS="$(printf '\t')" read -r name size image; do
    case "$name" in ''|\#*) continue ;; esac
    if [ "$size" = rest ]; then REST_NAME="$name"
    else FIXED_MIB=$(( FIXED_MIB + size )); fi
done < "$LAYOUT"

NEED_MIB=$(( FIRST_PART_MIB + FIXED_MIB + 1 ))
[ "$DEV_MIB" -gt "$NEED_MIB" ] || die "$DEV is only ${DEV_MIB}MiB; the layout needs more than ${NEED_MIB}MiB"
REST_MIB=$(( DEV_MIB - NEED_MIB ))
[ "$REST_MIB" -ge 512 ] || die "$REST_NAME would be ${REST_MIB}MiB, too small for Android to format"

# ---------------------------------------------------------------------------
# Which U-Boot started this system, and is it the one on the card? The property is
# the bare version ("2026.07", "2022.07-armbian-..."); the card's U-Boot carries its
# banner, "U-Boot <version> (<date> ...)", inside u-boot.itb at sector 16384.
# ---------------------------------------------------------------------------
RUNNING_UB="$(tr -d '\000' < /proc/device-tree/chosen/u-boot,version 2>/dev/null)"
CARD_UB="$(dd if="$SRC_DISK" bs=512 skip=16384 count=4096 2>/dev/null \
           | strings 2>/dev/null | grep '^U-Boot 20' | head -1)"
UB_PROVEN=0
case "$CARD_UB" in "U-Boot $RUNNING_UB "*) [ -n "$RUNNING_UB" ] && UB_PROVEN=1 ;; esac
if [ "$TARGET" = emmc ] && [ "$BOOTLOADER" = auto ]; then
    if [ "$UB_PROVEN" = 1 ]; then BOOTLOADER=copy; else BOOTLOADER=keep; fi
fi

echo "=========================================================================="
echo "  Install the running system onto the $TARGET"
echo "=========================================================================="
echo "  from:   $SRC_DISK  (running system)"
echo "  to:     $DEV  (${DEV_MIB}MiB)"
echo
printf '  %-12s %10s  %s\n' PARTITION SIZE SOURCE
start=$FIRST_PART_MIB
while IFS="$(printf '\t')" read -r name size image; do
    case "$name" in ''|\#*) continue ;; esac
    if [ "$size" = rest ]; then size=$REST_MIB; fi
    if [ "$image" = "-" ]; then src="(left empty, Android formats it)"
    else src="/dev/block/by-name/$name"; fi
    printf '  %-12s %7sMiB  %s\n' "$name" "$size" "$src"
done < "$LAYOUT"
echo "  running U-Boot: ${RUNNING_UB:-unknown}"
echo "  card's U-Boot:  ${CARD_UB:-none found at sector 16384}"
if [ "$TARGET" = emmc ] && [ "$BOOTLOADER" = copy ]; then
    echo "  bootloader   sector $UBOOT_SEEK_SECTORS, copied from $SRC_DISK"
    [ "$UB_PROVEN" = 1 ] || echo "               (forced: the card's U-Boot did not start this system)"
elif [ "$TARGET" = emmc ]; then
    echo "  bootloader   KEPT as it is on $DEV - it started this system, the card's"
    echo "               U-Boot did not. It will boot the installed Android through"
    echo "               bootfs, as it booted the card. --with-bootloader to replace it."
else
    echo "  bootloader   none - the BootROM cannot boot from PCIe. U-Boot has to stay"
    echo "               on the eMMC or the card; install to the eMMC too if you want"
    echo "               the board to run with no card in it."
fi
echo
echo "  EVERYTHING ON $DEV WILL BE LOST."
echo

if [ "$ASSUME_YES" != "1" ]; then
    printf 'Type the word yes to continue: '
    read -r answer
    [ "$answer" = yes ] || die "not confirmed; nothing was written"
fi

# ---------------------------------------------------------------------------
# Write it.
#
# The partition table first, then the contents at computed offsets on the whole
# disk - not through /dev/block/<dev>pN. Those nodes appear only after the kernel
# re-reads the table, which is a race, and the offsets are already known exactly
# because this script just laid them out. One less thing to wait for.
# ---------------------------------------------------------------------------
echo "==> partition table"
sgdisk --zap-all "$DEV" >/dev/null 2>&1 || die "sgdisk could not clear $DEV"
n=1
start=$FIRST_PART_MIB
while IFS="$(printf '\t')" read -r name size image; do
    case "$name" in ''|\#*) continue ;; esac
    if [ "$size" = rest ]; then
        sgdisk --new="$n:${start}M:0" --change-name="$n:$name" "$DEV" >/dev/null \
            || die "sgdisk failed on $name"
    else
        sgdisk --new="$n:${start}M:+${size}M" --change-name="$n:$name" "$DEV" >/dev/null \
            || die "sgdisk failed on $name"
        start=$(( start + size ))
    fi
    n=$(( n + 1 ))
done < "$LAYOUT"

if [ "$TARGET" = emmc ] && [ "$BOOTLOADER" = copy ]; then
    # Sectors 64 up to the first partition, straight off the running disk. That
    # region is the Rockchip ID block plus u-boot.itb, and it is the same
    # u-boot-rockchip.bin build-images.sh wrote to the card.
    count=$(( FIRST_PART_MIB * 2048 - UBOOT_SEEK_SECTORS ))
    echo "==> bootloader: $count sectors from $SRC_DISK at sector $UBOOT_SEEK_SECTORS"
    dd if="$SRC_DISK" of="$DEV" bs=512 skip="$UBOOT_SEEK_SECTORS" \
       seek="$UBOOT_SEEK_SECTORS" count="$count" conv=notrunc,fsync \
        || die "could not copy the bootloader"
fi

echo "==> partition contents"
start=$FIRST_PART_MIB
while IFS="$(printf '\t')" read -r name size image; do
    case "$name" in ''|\#*) continue ;; esac
    if [ "$size" = rest ]; then size=$REST_MIB; fi
    if [ "$image" != "-" ]; then
        src="/dev/block/by-name/$name"
        if [ -e "$src" ]; then
            printf '    %-12s %sMiB\n' "$name" "$size"
            dd if="$src" of="$DEV" bs=1048576 seek="$start" count="$size" \
               conv=notrunc,fsync || die "copy of $name failed"
        else
            echo "    $name: no $src on the running system, skipped" >&2
        fi
    fi
    if [ "$name" != "$REST_NAME" ]; then start=$(( start + size )); fi
done < "$LAYOUT"

sync
echo
echo "done."
if [ "$TARGET" = emmc ]; then
    echo "Remove the card and reboot to run from the eMMC. Put the card back to get"
    echo "the card again - U-Boot tries the card first, so this is reversible."
else
    echo "The SSD now holds the system, but nothing can boot it on its own: install"
    echo "to the eMMC as well, or keep the card in. U-Boot tries card, then eMMC,"
    echo "then NVMe, so with an empty eMMC and no card the SSD is what runs."
fi
