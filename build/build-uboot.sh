#!/usr/bin/env bash
#
# Khadas Edge1 - build mainline U-Boot so an SD card can boot Android by itself.
#
#   usage: build-uboot.sh [tree-dir]
#
# Output: $TREE/bootloader/u-boot/u-boot-rockchip.bin, one blob containing the
# TPL, the SPL and u-boot.itb, written to sector 64 of the card by
# build-sdimage.sh. That single-image packaging is binman's, and is what
# doc/board/rockchip/rockchip.rst:346 says to dd at seek=64.
#
# Why this exists at all: the board is installed by writing one whole-disk image
# to an SD card, so the card needs its own bootloader. The RK3399 BootROM looks at
# the SD card before the eMMC, which is what makes this safe - the eMMC install is
# never touched and removing the card restores the board exactly.
set -euo pipefail

readonly TREE="${1:-$HOME/aosp-14-edge1}"
readonly UB="$TREE/bootloader/u-boot"
readonly RKBIN="$TREE/rkbin"
readonly DEFCONFIG=khadas-edge-v-rk3399_defconfig

[[ -d "$UB" ]]    || { echo "no U-Boot at $UB; run sync.sh first" >&2; exit 1; }
[[ -d "$RKBIN" ]] || { echo "no rkbin at $RKBIN; run sync.sh first" >&2; exit 1; }
[[ -f "$UB/configs/$DEFCONFIG" ]] || {
    echo "$DEFCONFIG is not in this U-Boot; the board name may have changed" >&2
    echo "available:" >&2; ls "$UB/configs" | grep -i khadas >&2; exit 1; }

readonly CROSS=aarch64-linux-gnu-
command -v "${CROSS}gcc" >/dev/null 2>&1 || {
    echo "${CROSS}gcc not found; apt-get install gcc-aarch64-linux-gnu" >&2; exit 1; }

# BL31 is the only thing rk3399 needs out of rkbin. U-Boot's own TPL does DDR init
# on this SoC - the defconfig has CONFIG_TPL=y with CONFIG_RAM_ROCKCHIP_LPDDR4=y -
# so there is no ROCKCHIP_TPL blob in this build, unlike rk356x/rk3588.
# doc/board/rockchip/rockchip.rst:279-285 is the recipe.
#
# Searched for rather than hardcoded: rkbin's file carries a version in its name
# (rk3399_bl31_v1.35.elf and so on) and it moves between rkbin revisions.
BL31="$(find "$RKBIN" -name 'rk3399_bl31*.elf' 2>/dev/null | sort -V | tail -1)"
[[ -n "$BL31" ]] || {
    echo "no rk3399_bl31*.elf under $RKBIN - U-Boot cannot be built without it" >&2
    echo "what is there:" >&2
    find "$RKBIN" -name '*bl31*' 2>/dev/null | head -20 >&2
    exit 1; }
echo "==> BL31: ${BL31#$TREE/}"

cd "$UB"
echo "==> U-Boot $(make -s ubootversion 2>/dev/null || echo '(version unknown)')"
echo "==> base config: $DEFCONFIG"
make "CROSS_COMPILE=$CROSS" "$DEFCONFIG"

# ---------------------------------------------------------------------------
# The Android delta.
#
# khadas-edge-v-rk3399_defconfig builds a U-Boot that boots a distro - extlinux,
# a boot script, EFI. It cannot read an Android boot image, so these four things
# are added.
#
# The boot sequence is not invented. It is the one in U-Boot's own
# doc/android/boot-image.rst:110-133, for exactly this case: a boot image with
# header v2 whose DTB travels inside it, and no dtbo partition to merge.
#
#   mmc dev 1                          the SD card. arch/arm/dts/rk3399-u-boot.dtsi
#                                      aliases mmc0 = &sdhci (eMMC) and
#                                      mmc1 = &sdmmc (the card slot), so the card
#                                      is 1. Hardcoded rather than probed: this
#                                      image is built to boot from the card, and
#                                      U-Boot's simple parser has no conditionals
#                                      to fall back with (CONFIG_HUSH_PARSER and
#                                      CONFIG_CMD_SETEXPR are both off in this
#                                      defconfig). Change it to 0 to boot the same
#                                      layout from eMMC.
#   part start/size mmc 1 boot         by partition name, which cmd/part.c resolves
#                                      with part_get_info_by_name. The boot
#                                      partition is raw - there is no filesystem to
#                                      load from.
#   mmc read 0x20000000 ...            the whole boot.img into RAM at 512MB, clear
#                                      of everywhere bootm will copy things to.
#   abootimg get dtb --index=0         the board dtb out of the image's DTB area.
#   cp.b ... ${fdt_addr_r}             to 0x12000000, which
#                                      include/configs/rk3399_common.h sets.
#   bootm <img> <img> ${fdt_addr_r}    the documented Android form: kernel address,
#                                      ramdisk address, DTB address. bootm reads
#                                      the ANDROID! magic and unpacks it.
#
# CONFIG_CMD_ADTIMG is not enabled: it merges DTBO overlays, and this device has no
# dtbo partition - the one dtb is inside boot.img.
# ---------------------------------------------------------------------------
readonly BOOTCMD='mmc dev 1; part start mmc 1 boot ba; part size mmc 1 boot bs; mmc read 0x20000000 ${ba} ${bs}; abootimg addr 0x20000000; abootimg get dtb --index=0 da ds; cp.b ${da} ${fdt_addr_r} ${ds}; bootm 0x20000000 0x20000000 ${fdt_addr_r}'

readonly FRAGMENT=.config-android-fragment
cat > "$FRAGMENT" <<EOF
CONFIG_ANDROID_BOOT_IMAGE=y
CONFIG_CMD_ABOOTIMG=y
CONFIG_USE_BOOTCOMMAND=y
CONFIG_BOOTCOMMAND="$BOOTCMD"
EOF

echo "==> merging the Android boot delta"
./scripts/kconfig/merge_config.sh -m -O . .config "$FRAGMENT" >/dev/null
make "CROSS_COMPILE=$CROSS" olddefconfig >/dev/null

# Every symbol in the fragment has to survive olddefconfig, the same contract
# build-kernel.sh holds the kernel fragment to. CONFIG_CMD_ABOOTIMG depends on
# CONFIG_ANDROID_BOOT_IMAGE (cmd/Kconfig:534), so one missing dependency silently
# takes the command with it and the boot sequence dies at "Unknown command
# 'abootimg'" - on the board, with no log.
echo "==> verifying the delta took"
missing=0
for sym in CONFIG_ANDROID_BOOT_IMAGE CONFIG_CMD_ABOOTIMG CONFIG_USE_BOOTCOMMAND; do
    grep -qx "${sym}=y" .config || { echo "  NOT SET: $sym" >&2; missing=$((missing+1)); }
done
if ! grep -q '^CONFIG_BOOTCOMMAND=' .config; then
    echo "  NOT SET: CONFIG_BOOTCOMMAND" >&2; missing=$((missing+1))
fi
if (( missing )); then
    echo "==> $missing symbol(s) did not take. U-Boot would build and then not boot" >&2
    echo "    Android. Fix the fragment before flashing anything." >&2
    exit 1
fi
echo "  bootcmd: $(sed -n 's/^CONFIG_BOOTCOMMAND="\(.*\)"$/\1/p' .config)"

echo "==> building ($(nproc) jobs)"
make "CROSS_COMPILE=$CROSS" "BL31=$BL31" -j"$(nproc)"

readonly OUT="$UB/u-boot-rockchip.bin"
[[ -f "$OUT" ]] || {
    echo "u-boot-rockchip.bin was not produced. binman builds it for Rockchip" >&2
    echo "boards; if this U-Boot is too old for that, idbloader.img and u-boot.itb" >&2
    echo "have to be written separately at sectors 64 and 16384." >&2
    exit 1; }

echo
echo "u-boot-rockchip.bin: $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "build-sdimage.sh writes this at sector 64 of the card image, ahead of the"
echo "first partition - which flash/partitions.tsv starts at 16MiB for this reason."
