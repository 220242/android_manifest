#!/usr/bin/env bash
#
# Khadas Edge1 - build mainline U-Boot so an SD card can boot Android by itself.
#
#   usage: build-uboot.sh [tree-dir]
#
# Output: $TREE/bootloader/u-boot/u-boot-rockchip.bin, one blob containing the
# TPL, the SPL and u-boot.itb, written to sector 64 of the card by
# build-images.sh. That single-image packaging is binman's, and is what
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

# ---------------------------------------------------------------------------
# Building a second bootloader to A/B against, without editing anything.
#
#   EDGE1_UBOOT_REV=v2025.07 build/build-uboot.sh ~/aosp-14-edge1
#   build/build-images.sh ~/aosp-14-edge1 sdcard
#
# Two cards, two mainline tags, everything else identical. That is the A/B worth
# running if the first card does not boot, and it is worth saying why it is this and
# not a Khadas branch.
#
# Every Edge/RK3399 branch in github.com/khadas/u-boot is U-Boot 2017.09 - Rockchip's
# BSP fork - including the ones with 2024 dates in their names. None of them carries
# an Edge defconfig at all: only the generic rk3399_defconfig and evb-rk3399_defconfig.
# They build with their own make.sh into idbloader.img + uboot.img + trust.img at
# Rockchip's offsets, needing rkbin's miniloader; that is a different raw layout from
# binman's single u-boot-rockchip.bin at sector 64, so swapping one in is a second
# port, not a substitution.
#
# The one modern branch, khadas-u-boot-v2024.07, does carry
# khadas-edge-v-rk3399_defconfig - and it differs from upstream by exactly
# CONFIG_ROCKCHIP_IODOMAIN=y, CONFIG_SPL_PAD_TO=0x7f8000 and a SYS_/ENV_ rename.
# Its rk3399-khadas-edge-v-u-boot.dtsi and rk3399-khadas-edge-u-boot.dtsi are
# byte-identical to upstream's. Both of those config lines are accounted for below.
# There is nothing else in that fork for this board.
#
# Caveat: repo owns bootloader/u-boot, so the next Sync resets this checkout. That is
# the right behaviour - the manifest is the source of truth for what gets built - and
# it means an override is for an experiment, not for a decision. Pin a different tag
# in manifests/khadas_edge_tv14.xml to make it one.
# ---------------------------------------------------------------------------
readonly UBOOT_REV="${EDGE1_UBOOT_REV:-}"

[[ -d "$UB" ]]    || { echo "no U-Boot at $UB; run sync.sh first" >&2; exit 1; }
[[ -d "$RKBIN" ]] || { echo "no rkbin at $RKBIN; run sync.sh first" >&2; exit 1; }
[[ -f "$UB/configs/$DEFCONFIG" ]] || {
    echo "$DEFCONFIG is not in this U-Boot; the board name may have changed" >&2
    echo "available:" >&2; ls "$UB/configs" | grep -i khadas >&2; exit 1; }

readonly CROSS=aarch64-linux-gnu-
command -v "${CROSS}gcc" >/dev/null 2>&1 || {
    echo "${CROSS}gcc not found; apt-get install gcc-aarch64-linux-gnu" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Host tools, checked here rather than found by the build.
#
# U-Boot builds a SWIG Python extension (scripts/dtc/pylibfdt) before it can run
# binman, and binman is what packs u-boot-rockchip.bin. When swig is missing the
# build gets 400 lines in and stops with
#
#   error: command 'swig' failed: No such file or directory
#   make[2]: *** [scripts/dtc/pylibfdt/Makefile:33: rebuild] Error 1
#
# which names neither swig-the-package nor what wanted it. Four checks up front
# cost nothing and each names the package that satisfies it. The list is upstream's
# own, from doc/build/gcc.rst.
# ---------------------------------------------------------------------------
declare -a need=()
command -v swig >/dev/null 2>&1 || need+=("swig (apt-get install swig)")
python3 -c 'import setuptools' >/dev/null 2>&1 || \
    need+=("python3 setuptools (apt-get install python3-setuptools)")
python3 -c 'import elftools' >/dev/null 2>&1 || \
    need+=("python3 pyelftools, which binman imports (apt-get install python3-pyelftools)")
# The extension is compiled, so Python.h has to be on disk - python3 alone does
# not bring it. sysconfig names the directory the interpreter was built to look in.
pyinc="$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["include"])' 2>/dev/null || true)"
[[ -n "$pyinc" && -f "$pyinc/Python.h" ]] || \
    need+=("Python.h${pyinc:+ (looked in $pyinc)} (apt-get install libpython3-dev)")

if (( ${#need[@]} )); then
    echo "U-Boot cannot be built here; ${#need[@]} host requirement(s) missing:" >&2
    printf '  %s\n' "${need[@]}" >&2
    echo >&2
    echo "All of them are in build/windows/apt-packages.txt. On the WSL pipeline" >&2
    echo "that list is hashed, so the fix is to re-run the Provision stage:" >&2
    echo "  .\\build\\windows\\Start-EdgeBuild.ps1 -Stage Provision -Force" >&2
    exit 1
fi

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
if [[ -n "$UBOOT_REV" ]]; then
    echo "==> EDGE1_UBOOT_REV=$UBOOT_REV: checking out a different U-Boot"
    git fetch --depth 1 origin "refs/tags/$UBOOT_REV:refs/tags/$UBOOT_REV" 2>/dev/null \
        || git fetch origin "$UBOOT_REV" 2>/dev/null || true
    git checkout -q --detach "$UBOOT_REV" 2>/dev/null || {
        echo "  no such tag or branch in bootloader/u-boot: $UBOOT_REV" >&2
        echo "  what is there:" >&2
        git tag | tail -5 | sed 's/^/    /' >&2
        exit 1; }
    # The build is otherwise identical, so the only way to tell two cards apart later
    # is this line and the version printed next. Both go into the stage log.
    echo "  HEAD is now $(git describe --tags --always)"
fi
echo "==> U-Boot $(make -s ubootversion 2>/dev/null || echo '(version unknown)')"
echo "==> base config: $DEFCONFIG"
make "CROSS_COMPILE=$CROSS" "$DEFCONFIG"

# ---------------------------------------------------------------------------
# The Android delta.
#
# khadas-edge-v-rk3399_defconfig builds a U-Boot that boots a distro - extlinux,
# a boot script, EFI. It cannot read an Android boot image, and it has no shell
# with conditionals, so these five symbols are added.
#
# The boot sequence itself is not invented. It is the one in U-Boot's own
# doc/android/boot-image.rst:110-133, for exactly this case: a boot image with
# header v2 whose DTB travels inside it, and no dtbo partition to merge.
#
#   part start/size <if> <dev> boot   by partition name, which cmd/part.c resolves
#                                     with part_get_info_by_name, and which FAILS
#                                     if there is no such partition - that failure
#                                     is what makes the fallback below work. The
#                                     boot partition is raw; there is no
#                                     filesystem to load from.
#   <if> read 0x20000000 ...          the whole boot.img into RAM at 512MB, clear
#                                     of everywhere bootm will copy things to.
#   abootimg get dtb --index=0        the board dtb out of the image's DTB area.
#   cp.b ... ${fdt_addr_r}            to 0x12000000, which
#                                     include/configs/rk3399_common.h sets.
#   bootm <img> <img> ${fdt_addr_r}   the documented Android form: kernel address,
#                                     ramdisk address, DTB address. bootm reads
#                                     the ANDROID! magic and unpacks it.
#
# CONFIG_CMD_ADTIMG is not enabled: it merges DTBO overlays, and this device has no
# dtbo partition - the one dtb is inside boot.img.
#
# ---------------------------------------------------------------------------
# Three media, tried in order: SD card, eMMC, NVMe.
#
# This used to be one hardcoded "mmc dev 1", which boots only the card. Three
# media are wanted, and the order is what makes the whole install story work, so
# it is worth stating why this order and not another.
#
#   mmc 1   the SD card.  arch/arm/dts/rk3399-u-boot.dtsi aliases mmc0 = &sdhci
#           and mmc1 = &sdmmc; arch/arm/mach-rockchip/rk3399/rk3399.c:27-31 is the
#           same fact from the BootROM's side - EMMC is mmc@fe330000 (sdhci) and
#           SD is mmc@fe320000 (sdmmc). The card is 1.
#   mmc 0   the eMMC.
#   nvme 0  the M.2 SSD. CONFIG_NVME_PCI=y and CONFIG_PCI=y are already in the
#           Edge-V defconfig, and CONFIG_CMD_NVME is "default y if NVME", so the
#           nvme command comes for free. "nvme scan" has to run first because
#           PCIe enumeration is not automatic.
#
# The card first, and that is the single most useful property here: whichever
# medium the BootROM loaded U-Boot from, a card with an Android boot partition
# takes over. So an install on the eMMC or the NVMe is always recoverable by
# inserting the card - no serial console, no maskrom button, nothing to undo.
#
# NVMe is last because it cannot be first: the BootROM has no PCIe. Its boot
# sources are the enum in arch/arm/include/asm/arch-rockchip/bootrom.h:47-59 -
# NAND, EMMC, SPINOR, SPINAND, SD, UFS, I2C, SPI, USB - and PCIe is not among
# them. An NVMe install therefore always leaves U-Boot on the eMMC or the card;
# only Android's own partitions live on the SSD. That is a property of the
# silicon, not a choice, and it is why flash/partitions.tsv has no bootloader row
# for the NVMe image.
#
# The sequence is written once, here, and instantiated three times: the three
# copies in CONFIG_BOOTCOMMAND differ only in the interface, the device number
# and how the device is selected.
# ---------------------------------------------------------------------------
readonly IMGADDR=0x20000000

# $1 the command that selects the device, $2 the interface, $3 the device number
boot_one() {
    printf '%s && part start %s %s boot ba && part size %s %s boot bs' "$1" "$2" "$3" "$2" "$3"
    printf ' && %s read %s ${ba} ${bs}' "$2" "$IMGADDR"
    printf ' && abootimg addr %s && abootimg get dtb --index=0 da ds' "$IMGADDR"
    printf ' && cp.b ${da} ${fdt_addr_r} ${ds}'
    printf ' && bootm %s %s ${fdt_addr_r}' "$IMGADDR" "$IMGADDR"
}

BOOTCMD="$(boot_one 'mmc dev 1' mmc 1)"
BOOTCMD="$BOOTCMD || $(boot_one 'mmc dev 0' mmc 0)"
BOOTCMD="$BOOTCMD || $(boot_one 'nvme scan && nvme device 0' nvme 0)"
BOOTCMD="$BOOTCMD || echo NO ANDROID BOOT PARTITION ON CARD, eMMC OR NVMe"
readonly BOOTCMD

readonly FRAGMENT=.config-android-fragment
# CONFIG_HUSH_PARSER is what makes the fallback possible at all: without it the
# parser has no && or ||, so the three attempts could not be chained and a missing
# card would be a dead board rather than the next medium. cmd/Kconfig:14-20.
#
# CONFIG_SPL_PAD_TO is pinned rather than left to its Kconfig default, and the value
# is not ours: it is the one Khadas pins in their own khadas-edge-v-rk3399_defconfig
# on the khadas-u-boot-v2024.07 branch. It is also what the default already gives
# (common/spl/Kconfig:91, "default 0x7f8000 if ARCH_ROCKCHIP"), so this changes
# nothing today - it stops it changing tomorrow. The offset of u-boot.itb inside
# u-boot-rockchip.bin is exactly this number, so it is half of the seek=64
# arithmetic checked below; pinning it means the check can only ever fail because
# the OTHER half moved.
cat > "$FRAGMENT" <<EOF
CONFIG_ANDROID_BOOT_IMAGE=y
CONFIG_CMD_ABOOTIMG=y
CONFIG_HUSH_PARSER=y
CONFIG_SPL_PAD_TO=0x7f8000
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
#
# CONFIG_CMD_NVME is not in the fragment because it is not ours to set - it is
# "default y if NVME" and the defconfig already has CONFIG_NVME_PCI=y. It is
# checked anyway: if it ever stops coming for free, the third boot target
# silently becomes "Unknown command 'nvme'", which is the same class of failure.
echo "==> verifying the delta took"
missing=0
# Two lists, and the split is the point: this one is what the build ASSERTS, so a
# missing symbol is fatal. Everything in it is either in the fragment or is a
# functional dependency of something in the fragment - CONFIG_CMD_NVME and CONFIG_PCI
# are what make the third boot target exist at all, and without
# CONFIG_CMD_USB_MASS_STORAGE the documented "ums 0 mmc 0" escape hatch is not there.
for sym in CONFIG_ANDROID_BOOT_IMAGE CONFIG_CMD_ABOOTIMG CONFIG_HUSH_PARSER \
           CONFIG_USE_BOOTCOMMAND CONFIG_CMD_NVME CONFIG_PCI \
           CONFIG_CMD_USB_MASS_STORAGE; do
    grep -qx "${sym}=y" .config || { echo "  NOT SET: $sym" >&2; missing=$((missing+1)); }
done
if ! grep -q '^CONFIG_BOOTCOMMAND=' .config; then
    echo "  NOT SET: CONFIG_BOOTCOMMAND" >&2; missing=$((missing+1))
fi
# The three attempts have to survive into .config intact. A truncated bootcmd
# would still build, still boot the card, and silently not fall through to the
# eMMC or the SSD - which is precisely the case that cannot be tested without
# the hardware.
got="$(sed -n 's/^CONFIG_BOOTCOMMAND="\(.*\)"$/\1/p' .config)"
for want in 'mmc dev 1' 'mmc dev 0' 'nvme device 0'; do
    case "$got" in
        *"$want"*) ;;
        *) echo "  BOOTCOMMAND lost the '$want' attempt" >&2; missing=$((missing+1)) ;;
    esac
done
if (( missing )); then
    echo "==> $missing symbol(s) did not take. U-Boot would build and then not boot" >&2
    echo "    Android. Fix the fragment before flashing anything." >&2
    exit 1
fi
echo "  bootcmd tries, in order: SD card (mmc 1), eMMC (mmc 0), NVMe (nvme 0)"

# And this list is what the build EXPECTS: symbols we do not set, whose defaults
# should give us what we want. They are reported, never fatal - failing a working
# build over an expectation that was never asserted is how a green build gets
# blocked for nothing.
#
# CONFIG_ROCKCHIP_IODOMAIN is here because of where the Khadas fork differs from
# upstream. drivers/misc/Kconfig:114-125 makes it "default y if ROCKCHIP_RK3399", so
# it should come for free - but it "depends on DM_REGULATOR", and a dependency that
# goes away takes the default with it in silence, which is the same shape as the
# kernel's DWMAC_ROCKCHIP being demoted to m because its tristate parent was m.
#
# It matters more than the name suggests. The board DTS carries
#
#   &io_domains { ... sdmmc-supply = <&vccio_sd>; status = "okay"; };
#
# (dts/upstream/src/arm64/rockchip/rk3399-khadas-edge.dtsi:568-574) - the SD card's
# IO voltage domain, on a board whose whole install path is an SD card. Khadas name
# it explicitly in their own khadas-edge-v-rk3399_defconfig; upstream leaves it to
# the default. Reporting it is how we find out which of those is true here.
for sym in CONFIG_ROCKCHIP_IODOMAIN CONFIG_DM_REGULATOR CONFIG_SPL_ROCKCHIP_IODOMAIN; do
    if grep -qx "${sym}=y" .config; then
        printf '  %-34s y\n' "$sym"
    else
        printf '  %-34s not set (expected from a Kconfig default; see the comment above)\n' "$sym"
    fi
done

# ---------------------------------------------------------------------------
# u-boot.itb has to land on the sector SPL reads it from.
#
# u-boot-rockchip.bin is one blob with two stages in it: idbloader (the rksd
# header, TPL and SPL) at offset 0, and u-boot.itb at CONFIG_SPL_PAD_TO
# (arch/arm/dts/rockchip-u-boot.dtsi:166-195 - the simple-bin image node). Written
# at sector 64, the itb therefore lands at 64 + SPL_PAD_TO/512. SPL looks for it at
# CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR, and nothing makes those two agree.
#
# Today they do, exactly: SPL_PAD_TO defaults to 0x7f8000 for ARCH_ROCKCHIP
# (common/spl/Kconfig:91) which is 16320 sectors, the sector defaults to 0x4000
# (common/spl/Kconfig:590) which is 16384, and 64 + 16320 = 16384. That is why
# doc/board/rockchip/rockchip.rst says seek=64 and why the blob is ~9.6MB rather
# than ~1MB - most of it is the pad between the two stages.
#
# It is checked because the failure is silent and expensive: if either default ever
# moves, the image builder writes a bootloader whose second stage is some sectors
# off, SPL finds no FIT, and the board stops before there is any console to say so.
# ---------------------------------------------------------------------------
# The same 64 build-images.sh and the on-device installer use. verify-tree check 3e
# requires all three to agree.
readonly UBOOT_SEEK_SECTORS=64
pad_hex="$(sed -n 's/^CONFIG_SPL_PAD_TO=//p' .config)"
sec_hex="$(sed -n 's/^CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=//p' .config)"
if [[ -n "$pad_hex" && -n "$sec_hex" ]]; then
    pad_sectors=$(( pad_hex / 512 ))
    want=$(( UBOOT_SEEK_SECTORS + pad_sectors ))
    if (( want == sec_hex )); then
        printf '  u-boot.itb: sector %d at seek=%d (SPL reads sector %d) - agree\n' \
               "$want" "$UBOOT_SEEK_SECTORS" "$(( sec_hex ))"
    else
        echo "==> u-boot.itb would land on the wrong sector." >&2
        echo "    CONFIG_SPL_PAD_TO=$pad_hex is $pad_sectors sectors, so written at" >&2
        echo "    seek=$UBOOT_SEEK_SECTORS the FIT lands at sector $want - but SPL reads it from" >&2
        echo "    sector $(( sec_hex )) (CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=$sec_hex)." >&2
        echo "    SPL would find no FIT and the board would stop before any console." >&2
        echo "    Change UBOOT_SEEK_SECTORS in build-images.sh, the installer and here" >&2
        echo "    to $(( sec_hex - pad_sectors )), or pin CONFIG_SPL_PAD_TO." >&2
        exit 1
    fi
elif ! grep -qx 'CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_USE_SECTOR=y' .config; then
    echo "  note: SPL does not load u-boot.itb from a raw sector in this config, so the" >&2
    echo "        seek=64 packaging could not be checked. If the board stops at SPL, this" >&2
    echo "        is the first thing to look at." >&2
else
    echo "  note: CONFIG_SPL_PAD_TO or CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR is not in" >&2
    echo "        .config, so where u-boot.itb lands could not be verified." >&2
fi

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
echo "build-images.sh writes this at sector 64 of the card image, ahead of the"
echo "first partition - which flash/partitions.tsv starts at 16MiB for this reason."
