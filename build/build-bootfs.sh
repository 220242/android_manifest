#!/usr/bin/env bash
#
# Khadas Edge1 - build bootfs.img, the small FAT partition 1 of every image.
#
#   usage: build-bootfs.sh [tree-dir]
#
# Output: $OUT/bootfs.img, holding boot.scr and the boot.cmd it was made from.
#
# ---------------------------------------------------------------------------
# Why partition 1 is a FAT with a boot script on it
#
# The RK3399 BootROM tries SPI NOR, then the eMMC, then the SD card, and runs the
# first bootloader it finds (the Pine64 RK3399 boot-sequence notes, Khadas's own
# Edge docs: "SPI-Flash > eMMC > TF-Card"). This board ships with something on its
# eMMC - here, Armbian - so the U-Boot on our card never runs. Three cards proved
# that the hard way: valid ID block, valid FIT, and Armbian every time.
#
# What does run is the eMMC's U-Boot, and a distro U-Boot looks at the SD card
# first: boot_targets is "mmc1 mmc0 ...", and for each device it scans partition 1
# (or whichever are flagged bootable) for extlinux/extlinux.conf and boot.scr. The
# owner's OpenWrt card "won" over the eMMC exactly this way - its partition 1
# holds a boot.scr, and Armbian's U-Boot ran it.
#
# So every image gets a partition 1 that any such U-Boot will find, holding a
# script that boots our Android boot image straight out of the boot partition.
# With it the card boots Android on this board as it is, with nothing on the eMMC
# touched and nothing pressed. Without the eMMC's help - TST mode, an empty eMMC,
# U-Boot in SPI NOR - our own U-Boot runs instead and boots boot.img itself.
#
# ---------------------------------------------------------------------------
# Why the offsets are baked in rather than read at boot
#
# The script has to run on whatever U-Boot is on the eMMC, which here is Armbian's
# 2022.07. That rules out abootimg (CONFIG_ANDROID_BOOT_IMAGE is not in the
# khadas-edge-v-rk3399_defconfig Armbian builds it from)
# and makes it unwise to lean on anything newer than part, mmc read, setexpr and
# booti. Parsing a header in hush needs arithmetic on memory reads; reading the
# header here, in Python, needs none. The script still checks at boot that the
# header it finds is the one it was built for - the magic, and the first word of
# the image's SHA1 id - so a boot partition rewritten on its own is reported
# instead of booted with the wrong offsets.
set -euo pipefail

# shellcheck source=build/lib-tree.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-tree.sh"
readonly TREE="${1:-$(edge1_default_tree)}"
readonly OUT="$TREE/out/target/product/edge"
readonly FLASH="$TREE/device/khadas/edge/flash"
readonly LAYOUT="$FLASH/partitions.tsv"
readonly TEMPLATE="$FLASH/boot.cmd"
readonly BOOTIMG="$OUT/boot.img"
readonly RESULT="$OUT/bootfs.img"

[[ -f "$BOOTIMG" ]]  || { echo "no $BOOTIMG; run build.sh first" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "no $TEMPLATE; the device tree in $TREE is stale" >&2; exit 1; }
[[ -f "$LAYOUT" ]]   || { echo "no $LAYOUT" >&2; exit 1; }

# mkimage wraps the script in the legacy header "source" expects. The one U-Boot's
# own build produced is preferred - it is guaranteed to be there after build-uboot.sh
# - and u-boot-tools' is the fallback.
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

# ---------------------------------------------------------------------------
# Read the header. Layout from U-Boot's include/android_image.h
# (andr_boot_img_hdr_v0, packed): magic[8], then ten u32 - kernel_size, kernel_addr,
# ramdisk_size, ramdisk_addr, second_size, second_addr, tags_addr, page_size,
# header_version, os_version - name[16] at 0x30, cmdline[512] at 0x40, id[8 x u32]
# at 0x240, extra_cmdline[1024] at 0x260, recovery_dtbo_size at 0x660,
# recovery_dtbo_offset (u64) at 0x664, header_size at 0x66c, dtb_size at 0x670.
# Every section is padded to page_size, in the order header, kernel, ramdisk,
# second, recovery_dtbo, dtb.
# ---------------------------------------------------------------------------
readonly WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$BOOTIMG" > "$WORK/vars" <<'PY'
import struct, sys

path = sys.argv[1]
with open(path, "rb") as f:
    hdr = f.read(0x67C)

if hdr[:8] != b"ANDROID!":
    sys.exit(f"{path}: not an Android boot image (magic {hdr[:8]!r})")

(ksz, _kaddr, rsz, _raddr, ssz, _saddr, _tags, page, ver, _osv) = struct.unpack_from("<10I", hdr, 8)
if ver != 2:
    sys.exit(f"{path}: header version {ver}; this script and BoardConfig.mk expect 2")
if page % 512:
    sys.exit(f"{path}: page size {page} is not a whole number of sectors")

cmdline = hdr[0x40:0x240].split(b"\0", 1)[0]
extra = hdr[0x260:0x660].split(b"\0", 1)[0]
cmdline = (cmdline + (b" " + extra if extra else b"")).decode("ascii").strip()
id0 = struct.unpack_from("<I", hdr, 0x240)[0]
(rdtbo_sz,) = struct.unpack_from("<I", hdr, 0x660)
(dtb_sz,) = struct.unpack_from("<I", hdr, 0x670)

if ksz == 0 or rsz == 0 or dtb_sz == 0:
    sys.exit(f"{path}: kernel {ksz}, ramdisk {rsz}, dtb {dtb_sz} bytes - all three are needed")

# The script puts the command line inside double quotes in hush.
for bad in '"$;\\`':
    if bad in cmdline:
        sys.exit(f"{path}: the kernel command line contains {bad!r}, which the boot "
                 "script cannot quote")

def pages(n):
    return (n + page - 1) // page

k_off = 1
r_off = k_off + pages(ksz)
s_off = r_off + pages(rsz)
d_off = s_off + pages(ssz) + pages(rdtbo_sz)

spp = page // 512          # sectors per page
def secs(n):
    return (n + 511) // 512

print(f"KERNEL_OFF=0x{k_off * spp:x}")
print(f"KERNEL_CNT=0x{secs(ksz):x}")
print(f"RAMDISK_OFF=0x{r_off * spp:x}")
print(f"RAMDISK_CNT=0x{secs(rsz):x}")
print(f"RAMDISK_SIZE=0x{rsz:x}")
print(f"DTB_OFF=0x{d_off * spp:x}")
print(f"DTB_CNT=0x{secs(dtb_sz):x}")
# setexpr prints without leading zeros or a 0x, so compare in that form.
print(f"ID0={id0:x}")
print(f"CMDLINE={cmdline}")
# For the summary only.
print(f"KSZ={ksz}")
print(f"RSZ={rsz}")
print(f"DSZ={dtb_sz}")
PY

declare -A V=()
while IFS='=' read -r key value; do V["$key"]="$value"; done < "$WORK/vars"

# Fill the template. Python rather than sed: the command line is free text, and a
# sed replacement would have to escape it for sed first.
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

"$MKIMAGE" -A arm64 -O linux -T script -C none -n "Edge1 Android boot" \
    -d "$WORK/boot.cmd" "$WORK/boot.scr" >/dev/null

rm -f "$RESULT"
# -C creates the file at the given size in KiB. The label is what Windows and a
# Linux automounter show if the card is inserted into a desktop.
mkfs.vfat -n EDGE1BOOT -C "$RESULT" $(( size_mib * 1024 )) >/dev/null
mcopy -i "$RESULT" "$WORK/boot.scr" "$WORK/boot.cmd" ::

echo "==> bootfs.img (${size_mib}MiB FAT): boot.scr for boot.img id ${V[ID0]}"
printf '    kernel  %9s bytes at sector %s of boot\n' "${V[KSZ]}" "${V[KERNEL_OFF]}"
printf '    ramdisk %9s bytes at sector %s\n' "${V[RSZ]}" "${V[RAMDISK_OFF]}"
printf '    dtb     %9s bytes at sector %s\n' "${V[DSZ]}" "${V[DTB_OFF]}"
echo "    cmdline androidboot.boot_devices=<per medium> ${V[CMDLINE]}"
