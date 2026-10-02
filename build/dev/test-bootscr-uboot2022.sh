#!/usr/bin/env bash
#
# Run a card image's boot.scr through distro boot on U-Boot v2022.07 - the release
# Armbian put on this board's eMMC - in U-Boot's sandbox, with that board's
# command set and environment.
#
#   usage: build/dev/test-bootscr-uboot2022.sh <u-boot-v2022.07-src> <edge1-sdcard.img> [workdir]
#
#   EDGE1_PRELOAD=<file>@<addr>   load a file into RAM first, e.g. a saved
#                                 edge1-pstore.bin at the ramoops address, to
#                                 stand in for what a warm reset leaves behind
#
# What it builds, once, in the workdir:
#   sb/       the v2022.07 sandbox with setexpr, read, gpio, nvme, abootimg and led
#             removed and legacy images on - khadas-edge-v-rk3399_defconfig's
#             command set as far as the script is concerned
#   env.txt   the default environment of khadas-edge-v-rk3399_defconfig, taken from
#             the 2022.07 headers with the C preprocessor, boot_targets pointed at
#             host0 (the card, mmc1 on the board) and host1 (a stand-in eMMC whose
#             boot.scr just says "ARMBIAN")
# then runs "run distro_bootcmd" and prints edge1-boot.log as a PC would read it.
# booti is ARM-only, so a script that gets that far ends at booti-returned and
# distro boot carries on to the "eMMC" - exactly what the board does when the
# script declines. Needs: make, gcc, bison, flex, swig-free sandbox deps, sgdisk,
# mtools, dosfstools, python3.
set -euo pipefail
SRC="$(cd "${1:?usage: $0 <u-boot-v2022.07-src> <card.img> [workdir]}" && pwd)"
CARD="$(realpath "${2:?card image}")"
W="$(mkdir -p "${3:-$PWD/uboot2022-test}" && cd "${3:-$PWD/uboot2022-test}" && pwd)"
grep -q '^VERSION = 2022$' "$SRC/Makefile" && grep -q '^PATCHLEVEL = 07$' "$SRC/Makefile" \
    || { echo "$SRC is not U-Boot v2022.07" >&2; exit 1; }

# 1. the sandbox
if [[ ! -x "$W/sb/u-boot" ]]; then
    echo "==> building the v2022.07 sandbox (once)"
    make -C "$SRC" O="$W/sb" NO_SDL=1 sandbox_defconfig >/dev/null
    for c in SETEXPR READ GPIO NVME ABOOTIMG LED; do
        sed -i "s/^CONFIG_CMD_${c}=y$/# CONFIG_CMD_${c} is not set/" "$W/sb/.config"
    done
    sed -i 's/^# CONFIG_LEGACY_IMAGE_FORMAT is not set$/CONFIG_LEGACY_IMAGE_FORMAT=y/' "$W/sb/.config"
    # 1GiB of sandbox RAM so the ramoops address (0x30100000) exists; no
    # mkeficapsule, which needs gnutls headers and has nothing to do with this.
    sed -i 's/^CONFIG_SANDBOX_RAM_SIZE_MB=.*/CONFIG_SANDBOX_RAM_SIZE_MB=1024/;
            s/^CONFIG_TOOLS_MKEFICAPSULE=y$/# CONFIG_TOOLS_MKEFICAPSULE is not set/' "$W/sb/.config"
    make -C "$SRC" O="$W/sb" NO_SDL=1 olddefconfig >/dev/null
    make -C "$SRC" O="$W/sb" NO_SDL=1 -j"$(nproc)" >"$W/sb-build.log" 2>&1 \
        || { tail -20 "$W/sb-build.log" >&2; exit 1; }
fi
MKIMAGE="$W/sb/tools/mkimage"

# 2. the board's distro-boot environment
if [[ ! -f "$W/env.txt" ]]; then
    echo "==> deriving khadas-edge-v-rk3399_defconfig's default environment"
    make -C "$SRC" O="$W/kh" khadas-edge-v-rk3399_defconfig >/dev/null
    mkdir -p "$W/kh/inc/generated"
    awk -F= '/^CONFIG_/ { k=$1; v=substr($0, length($1)+2); if (v=="y") print "#define " k " 1"; else print "#define " k " " v }' \
        "$W/kh/.config" > "$W/kh/inc/generated/autoconf.h"
    printf '#include <linux/kconfig.h>\n#include <configs/rk3399_common.h>\nENVSTART CONFIG_EXTRA_ENV_SETTINGS ENVEND\n' > "$W/kh/env.c"
    cpp -P -nostdinc -I "$W/kh/inc" -I "$SRC/include" -I "$SRC/arch/arm/include" "$W/kh/env.c" \
        | tr -d '\n' | sed 's/.*ENVSTART\(.*\)ENVEND.*/\1/' > "$W/kh/env.cstr"
    python3 - "$W/kh/env.cstr" "$W/env.txt" <<'PY'
import ast, re, sys
s = open(sys.argv[1]).read()
blob = "".join(ast.literal_eval('"' + l + '"') for l in re.findall(r'"((?:[^"\\]|\\.)*)"', s))
env = [e for e in blob.split("\0") if e and not e.startswith(("boot_targets=", "bootcmd_"))]
env += ["boot_targets=host0 host1",
        "bootcmd_host0=devnum=0; if host dev ${devnum}; then devtype=host; run scan_dev_for_boot_part; fi",
        "bootcmd_host1=devnum=1; if host dev ${devnum}; then devtype=host; run scan_dev_for_boot_part; fi"]
open(sys.argv[2], "w").write("\n".join(env) + "\n")
PY
fi

# 3. a stand-in eMMC: GPT, FAT partition 1, a boot.scr that says it is Armbian
if [[ ! -f "$W/emmc.img" ]]; then
    truncate -s 64M "$W/emmc.img"
    sgdisk -q -o -n 1:2048:+60M -t 1:0700 "$W/emmc.img"
    mkfs.vfat -C "$W/emmc-p1.img" $((60*1024)) >/dev/null
    echo 'echo "ARMBIAN boot.scr ran on ${devtype} ${devnum}:${distro_bootpart} - where the board ends up when Android declines"' > "$W/armbian.cmd"
    "$MKIMAGE" -A arm64 -O linux -T script -C none -d "$W/armbian.cmd" "$W/armbian.scr" >/dev/null
    mcopy -i "$W/emmc-p1.img" "$W/armbian.scr" ::boot.scr
    dd if="$W/emmc-p1.img" of="$W/emmc.img" bs=512 seek=2048 conv=notrunc status=none
fi

# 4. run
cp --sparse=always "$CARD" "$W/card.img"
{
    if [[ -n "${EDGE1_PRELOAD:-}" ]]; then
        echo "load hostfs - ${EDGE1_PRELOAD##*@} $(realpath "${EDGE1_PRELOAD%@*}")"
    fi
    echo "host bind 0 $W/card.img"
    echo "host bind 1 $W/emmc.img"
    echo "load hostfs - 0x100000 $W/env.txt"
    echo 'env import -t 0x100000 ${filesize}'
    echo 'run distro_bootcmd'
} > "$W/driver.cmd"
"$MKIMAGE" -A sandbox -O linux -T script -C none -d "$W/driver.cmd" "$W/driver.scr" >/dev/null
echo "==> distro boot on U-Boot v2022.07"
( cd "$W/sb" && timeout 120 ./u-boot -c "load hostfs - 0x1000000 $W/driver.scr; source 0x1000000" 2>&1 ) \
    | tr -d '\r' | sed -n '/Scanning host/,$p' \
    | grep -av 'erofs superblock\|RNG device\|EFI system partition\|ACPI table\|BootOrder\|EFI boot manager\|^.\[' || true
echo "==> edge1-boot.log on the card afterwards"
mtype -i "$W/card.img@@16M" ::edge1-boot.log | tr -d '\0'
dd if="$W/card.img" of="$W/p1.img" bs=1M skip=16 count=128 status=none
fsck.vfat -n "$W/p1.img" >/dev/null 2>&1 && echo "==> fsck.vfat: bootfs clean" || echo "==> fsck.vfat: PROBLEMS"
