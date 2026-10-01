#!/usr/bin/env bash
#
# Khadas Edge1 - build bootfs.img, the FAT that is partition 1 of every image.
#
#   usage: build-bootfs.sh [tree-dir]
#
# Output: $OUT/bootfs.img, holding
#
#   boot.scr         the boot script, for whichever U-Boot finds this partition
#   boot.cmd         its source, readable
#   Image            the kernel      \
#   ramdisk.img      the ramdisk      > byte-for-byte out of boot.img
#   edge1.dtb        the board dtb   /
#   edge1-boot.log   written by the boot script at boot: how far it got
#   README.txt       what all this is, for whoever opens the card on a PC
#
# ---------------------------------------------------------------------------
# Why partition 1 is a FAT with a boot script on it
#
# The RK3399 BootROM tries SPI NOR, then the eMMC, then the SD card, and runs the
# first bootloader it finds (Pine64's RK3399 boot-sequence notes; Khadas: "SPI-Flash >
# eMMC > TF-Card"). This board has Armbian on its eMMC, so the U-Boot on our card never
# runs. What does run is the eMMC's U-Boot, and a distro U-Boot looks at the SD card
# first: boot_targets is "mmc1 mmc0 ...", and for each device it scans partition 1 (or
# whichever are flagged bootable) for extlinux/extlinux.conf and boot.scr. The owner's
# OpenWrt card "won" over the eMMC exactly this way.
#
# ---------------------------------------------------------------------------
# Why the kernel, ramdisk and dtb are files here rather than read out of boot.img
#
# The script runs on the eMMC's U-Boot, which on this board is Armbian's 2022.07 built
# from khadas-edge-v-rk3399_defconfig. The first version of this script read the three
# straight out of the raw boot partition, which needs sector arithmetic - and that
# U-Boot has no setexpr (CONFIG_CMD_SETEXPR is not set in that config). On the board
# the header check could not run, the script declined to boot, and distro boot went on
# to Armbian. Every time, with nothing on the screen to say so.
#
# Files and "load" are what every distro boot script uses, Armbian's and OpenWrt's
# included, so they are what is guaranteed to work. The cost is 55MB of duplication on
# a 7GB card. The three are extracted from the same boot.img in the same run, so they
# cannot disagree with the boot partition our own U-Boot reads. build/
# check-uboot-script.py refuses any command in the script that 2022.07 does not have.
set -euo pipefail

# shellcheck source=build/lib-tree.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-tree.sh"
readonly TREE="${1:-$(edge1_default_tree)}"
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OUT="$TREE/out/target/product/edge"
readonly FLASH="$TREE/device/khadas/edge/flash"
readonly LAYOUT="$FLASH/partitions.tsv"
readonly TEMPLATE="$FLASH/boot.cmd"
readonly BOOTIMG="$OUT/boot.img"
readonly RESULT="$OUT/bootfs.img"

[[ -f "$BOOTIMG" ]]  || { echo "no $BOOTIMG; run build.sh first" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "no $TEMPLATE; the device tree in $TREE is stale" >&2; exit 1; }
[[ -f "$LAYOUT" ]]   || { echo "no $LAYOUT" >&2; exit 1; }

# mkimage wraps the script in the legacy header "source" expects. The one U-Boot's own
# build produced is preferred - it is there after build-uboot.sh - and u-boot-tools'
# is the fallback.
MKIMAGE="$TREE/bootloader/u-boot/tools/mkimage"
[[ -x "$MKIMAGE" ]] || MKIMAGE="$(command -v mkimage || true)"
declare -a need=()
[[ -n "$MKIMAGE" ]] || need+=("mkimage (run build-uboot.sh, or apt-get install u-boot-tools)")
command -v mkfs.vfat >/dev/null 2>&1 || need+=("mkfs.vfat (apt-get install dosfstools)")
command -v mcopy >/dev/null 2>&1     || need+=("mcopy (apt-get install mtools)")
if (( ${#need[@]} )); then
    echo "bootfs.img cannot be built; missing:" >&2
    printf '  %s\n' "${need[@]}" >&2
    echo "dosfstools and mtools are in build/windows/apt-packages.txt; on the WSL" >&2
    echo "pipeline re-run the Provision stage to install them." >&2
    exit 1
fi

# The partition's size comes from the layout, so the FAT always fills it exactly.
size_mib="$(awk -F'\t' '$1 == "bootfs" { print $2 }' "$LAYOUT")"
[[ "$size_mib" =~ ^[0-9]+$ ]] || {
    echo "partitions.tsv has no fixed-size bootfs row (got '${size_mib}')" >&2; exit 1; }
first="$(awk -F'\t' '$1 !~ /^#/ && NF >= 3 { print $1; exit }' "$LAYOUT")"
[[ "$first" == "bootfs" ]] || {
    echo "bootfs must be the FIRST row of partitions.tsv, not '$first': distro boot" >&2
    echo "scans partition 1 when no partition is flagged bootable." >&2
    exit 1; }

readonly WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Take boot.img apart. Header layout from U-Boot's include/android_image.h
# (andr_boot_img_hdr_v0, packed): magic[8], then ten u32 - kernel_size, kernel_addr,
# ramdisk_size, ramdisk_addr, second_size, second_addr, tags_addr, page_size,
# header_version, os_version - name[16] at 0x30, cmdline[512] at 0x40, id at 0x240,
# extra_cmdline[1024] at 0x260, recovery_dtbo_size at 0x660, dtb_size at 0x670. Each
# section is padded to page_size: header, kernel, ramdisk, second, recovery_dtbo, dtb.
# ---------------------------------------------------------------------------
python3 - "$BOOTIMG" "$WORK" > "$WORK/vars" <<'PY'
import os, struct, sys

path, work = sys.argv[1], sys.argv[2]
img = open(path, "rb").read()
hdr = img[:0x67C]
if hdr[:8] != b"ANDROID!":
    sys.exit(f"{path}: not an Android boot image (magic {hdr[:8]!r})")

(ksz, _ka, rsz, _ra, ssz, _sa, _tags, page, ver, _osv) = struct.unpack_from("<10I", hdr, 8)
if ver != 2:
    sys.exit(f"{path}: header version {ver}; BoardConfig.mk builds 2")
(rdtbo_sz,) = struct.unpack_from("<I", hdr, 0x660)
(dsz,) = struct.unpack_from("<I", hdr, 0x670)
if not (ksz and rsz and dsz):
    sys.exit(f"{path}: kernel {ksz}, ramdisk {rsz}, dtb {dsz} bytes - all three are needed")

def pages(n):
    return (n + page - 1) // page

k_off = page
r_off = k_off + pages(ksz) * page
d_off = r_off + pages(rsz) * page + pages(ssz) * page + pages(rdtbo_sz) * page
kernel = img[k_off:k_off + ksz]
ramdisk = img[r_off:r_off + rsz]
dtb = img[d_off:d_off + dsz]
if len(kernel) != ksz or len(ramdisk) != rsz or len(dtb) != dsz:
    sys.exit(f"{path}: truncated - the header describes more than the file holds")

# What booti will check, checked here: the arm64 Image magic "ARM\x64" at 0x38
# (U-Boot arch/arm/lib/image.c, booti_setup), and the dtb's own magic.
if kernel[0x38:0x3C] != b"ARM\x64":
    sys.exit(f"{path}: the kernel has no arm64 Image magic at 0x38; booti would refuse it")
if dtb[:4] != b"\xd0\x0d\xfe\xed":
    sys.exit(f"{path}: the dtb section does not start with an FDT header")

cmdline = hdr[0x40:0x240].split(b"\0", 1)[0]
extra = hdr[0x260:0x660].split(b"\0", 1)[0]
cmdline = (cmdline + (b" " + extra if extra else b"")).decode("ascii").strip()
# The script puts the command line inside double quotes in hush.
for bad in '"$;\\`\'':
    if bad in cmdline:
        sys.exit(f"{path}: the kernel command line contains {bad!r}, which the boot script "
                 "cannot quote")
if "androidboot.boot_devices" in cmdline:
    sys.exit(f"{path}: boot.img carries androidboot.boot_devices; it is per medium and "
             "the boot script adds it")

for name, blob in (("Image", kernel), ("ramdisk.img", ramdisk), ("edge1.dtb", dtb)):
    open(os.path.join(work, name), "wb").write(blob)
(image_size,) = struct.unpack_from("<Q", kernel, 0x10)
print(f"CMDLINE={cmdline}")
print(f"KSZ={ksz}")
print(f"KIMAGE={image_size}")
print(f"RSZ={rsz}")
print(f"DSZ={dsz}")
PY

declare -A V=()
while IFS='=' read -r key value; do V["$key"]="$value"; done < "$WORK/vars"

# The kernel's in-memory size (image_size in the Image header: text plus BSS) must end
# below where the script puts the ramdisk, or booti refuses with "RD image overlaps OS
# image". The addresses are the script's own; they are read back out of it so the two
# cannot drift.
kaddr=$(sed -n 's/^setenv edge1_kaddr \(0x[0-9a-fA-F]*\)$/\1/p' "$TEMPLATE")
raddr=$(sed -n 's/^setenv edge1_raddr \(0x[0-9a-fA-F]*\)$/\1/p' "$TEMPLATE")
[[ -n "$kaddr" && -n "$raddr" ]] || { echo "boot.cmd sets no edge1_kaddr/edge1_raddr" >&2; exit 1; }
if (( kaddr + ${V[KIMAGE]} > raddr )); then
    printf 'the kernel occupies 0x%x..0x%x in memory, past the ramdisk at %s\n' \
           "$kaddr" "$(( kaddr + ${V[KIMAGE]} ))" "$raddr" >&2
    echo "Move edge1_raddr up in device/khadas/edge/flash/boot.cmd." >&2
    exit 1
fi

# Fill the template. Python rather than sed: the command line is free text.
python3 - "$TEMPLATE" "$WORK/boot.cmd" "$WORK/vars" <<'PY'
import re, sys
src, dst, varfile = sys.argv[1:4]
vals = {}
for line in open(varfile):
    k, _, v = line.rstrip("\n").partition("=")
    vals[k] = v
text = re.sub(r"@([A-Z0-9_]+)@", lambda m: vals.get(m.group(1), m.group(0)), open(src).read())
left = sorted(set(re.findall(r"@[A-Z0-9_]+@", text)))
if left:
    sys.exit("placeholder(s) in boot.cmd with no value from boot.img: " + ", ".join(left))
open(dst, "w").write(text)
PY

# Nothing the eMMC's U-Boot does not have. This is the check that would have caught
# setexpr before a card was written.
python3 "$HERE/check-uboot-script.py" "$WORK/boot.cmd" | sed 's/^/    /'

"$MKIMAGE" -A arm64 -O linux -T script -C none -n "Edge1 Android boot" \
    -d "$WORK/boot.cmd" "$WORK/boot.scr" >/dev/null

# Pre-created so the first fatwrite at boot replaces a file rather than allocating
# one, the simplest thing U-Boot's FAT writer does.
printf 'No boot attempt recorded yet. The boot script rewrites this file each time it\nruns: edge1_stage says how far it got.\n' > "$WORK/edge1-boot.log"
cat > "$WORK/README.txt" <<'EOF'
Khadas Edge1 - Android TV 14, boot partition
============================================

This small partition is how the card boots on a board whose eMMC already holds a
system (the RK3399 tries the eMMC before the card). The U-Boot on the eMMC looks
here first, runs boot.scr, and that starts Android from Image, ramdisk.img and
edge1.dtb. Nothing on the eMMC is written.

edge1-boot.log is rewritten by boot.scr on every boot. If Android does not start,
the edge1_stage line in it says how far the script got (edge1_where is the
device and partition it ran from; the sizes are hex):

  started         the script ran and stopped before loading anything
  no-kernel       Image could not be loaded
  no-dtb          edge1.dtb could not be loaded
  no-ramdisk      ramdisk.img could not be loaded
  booti           everything loaded and the kernel was started - from here on
                  it is the kernel's story, which is on the HDMI screen
  booti-returned  U-Boot refused to start the kernel

Do not edit these files on a PC; rebuild the image instead.
EOF

rm -f "$RESULT"
# -C creates the file at the given size in KiB. The label is what Windows and a Linux
# automounter show when the card is plugged into a desktop.
mkfs.vfat -n EDGE1BOOT -C "$RESULT" $(( size_mib * 1024 )) >/dev/null
mcopy -i "$RESULT" "$WORK/boot.scr" "$WORK/boot.cmd" "$WORK/Image" "$WORK/ramdisk.img" \
      "$WORK/edge1.dtb" "$WORK/edge1-boot.log" "$WORK/README.txt" ::

echo "==> bootfs.img (${size_mib}MiB FAT)"
printf '    Image        %9s bytes (%s in memory with BSS)\n' "${V[KSZ]}" "${V[KIMAGE]}"
printf '    ramdisk.img  %9s bytes\n' "${V[RSZ]}"
printf '    edge1.dtb    %9s bytes\n' "${V[DSZ]}"
echo "    cmdline      androidboot.boot_devices=<per medium> ${V[CMDLINE]}"
