#!/usr/bin/env bash
#
# Khadas Edge1 - build the mainline 6.12 LTS kernel for Android.
#
#   usage: build-kernel.sh [tree-dir]
#
# Environment:
#   EDGE1_DTB          board dts basename, without .dts
#                      (default rk3399-khadas-edge-v)
#   KERNEL_USE_CLANG=1 build with AOSP's clang instead of the distro cross GCC
#
# This replaced a build of the Khadas 4.19 BSP kernel. What that build needed and
# this one does not, because none of it exists upstream: a bypass for
# scripts/gcc-wrapper.py (which failed the build on any compiler warning), a
# -fcommon workaround for scripts/dtc, a probed list of -Wno- flags for
# 2019-vintage code, and Rockchip's resource.img container. 6.12 compiles clean
# with a current toolchain and Android packs the dtb into boot.img.
set -euo pipefail

# shellcheck source=build/lib-tree.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-tree.sh"
readonly TREE="${1:-$(edge1_default_tree)}"
readonly KERNEL="$TREE/kernel/mainline"
readonly DEVICE_DIR="$TREE/device/khadas/edge"
readonly FRAGMENT="$DEVICE_DIR/kernel/edge1_mainline.config"
# rk3399-khadas-edge-v, not rk3399-khadas-edge.
#
# The three Khadas Edge dts files share rk3399-khadas-edge.dtsi, which carries the
# SoC, the GPU, HDMI with its audio, eMMC, USB and the Wi-Fi SDIO node. What the
# per-board files add is what is wired on that carrier, and the plain "edge" one
# adds nothing at all - it is thirteen lines, a model name and a compatible:
#
#   edge      no gmac, no PCIe
#   edge-v    &gmac okay, &pcie_phy and &pcie0 okay with 4 lanes
#   captain   its own set
#
# So the plain edge dtb would boot this board with no Ethernet and no M.2 slot.
# The Edge-V dtb is also the one this board is known to run: the owner's OpenWrt
# build targets khadas_edge-v and uses Ethernet as its whole reason for existing.
readonly DTB="${EDGE1_DTB:-rk3399-khadas-edge-v}"

# BOARD_PREBUILT_DTBIMAGE_DIR globs *.dtb out of one directory and concatenates
# everything it finds into dtb.img. Pointed at the kernel's own output that would
# be every Rockchip board in the tree - about 90 dtbs - so the board's dtb is
# staged alone in here.
readonly DTB_STAGE="$KERNEL/out/android-dtb"

[[ -d "$KERNEL" ]] || { echo "no kernel at $KERNEL; run sync.sh first" >&2; exit 1; }
[[ -f "$FRAGMENT" ]] || { echo "missing config fragment $FRAGMENT" >&2; exit 1; }

cd "$KERNEL"

readonly CROSS=aarch64-linux-gnu-
if ! command -v "${CROSS}gcc" >/dev/null 2>&1; then
    echo "${CROSS}gcc not found." >&2
    echo "Install it: sudo apt-get install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu" >&2
    exit 1
fi

MAKE_ARGS=( O=out ARCH=arm64 "CROSS_COMPILE=$CROSS" )

if [[ "${KERNEL_USE_CLANG:-0}" == "1" ]]; then
    CLANG_DIR=$(find "$TREE/prebuilts/clang/host/linux-x86" -maxdepth 1 -type d \
                     -name 'clang-r*' 2>/dev/null | sort -V | tail -1)
    [[ -n "$CLANG_DIR" ]] || { echo "no clang prebuilt in $TREE/prebuilts" >&2; exit 1; }
    export PATH="$CLANG_DIR/bin:$PATH"
    echo "==> toolchain: $(basename "$CLANG_DIR") (clang) + $CROSS binutils"
    MAKE_ARGS+=( LLVM=1 "CLANG_TRIPLE=$CROSS" )
else
    echo "==> toolchain: $("${CROSS}gcc" --version | head -1)"
fi

echo "==> kernel: $(make "${MAKE_ARGS[@]}" -s kernelversion 2>/dev/null || echo unknown)"
echo "==> board dtb: $DTB"

readonly JOBS="$(nproc)"

echo "==> base config: arm64 defconfig"
make "${MAKE_ARGS[@]}" defconfig

# merge_config.sh warns about every symbol it could not set, which is how a
# missing backport or an unmet dependency is caught here rather than as a boot
# failure. The verification loop below then fails loudly on the ones that matter.
echo "==> merging the Android 14 delta"
ARCH=arm64 CROSS_COMPILE=$CROSS ./scripts/kconfig/merge_config.sh -m -O out \
    out/.config "$FRAGMENT"
make "${MAKE_ARGS[@]}" olddefconfig

echo "==> verifying the delta actually took"
missing=0
while read -r line; do
    if [[ "$line" =~ ^#\ CONFIG_([A-Z0-9_]+)\ is\ not\ set$ ]]; then
        sym="${BASH_REMATCH[1]}"
        if grep -qx "CONFIG_${sym}=y" out/.config || grep -qx "CONFIG_${sym}=m" out/.config; then
            echo "  STILL SET: CONFIG_${sym} (the fragment asks for it to be off)" >&2
            missing=$((missing+1))
        fi
        continue
    fi
    [[ "$line" =~ ^CONFIG_([A-Z0-9_]+)=(.*)$ ]] || continue
    sym="${BASH_REMATCH[1]}"; want="${BASH_REMATCH[2]}"
    [[ "$want" == '""' ]] && continue
    if ! grep -qx "CONFIG_${sym}=${want}" out/.config; then
        echo "  NOT SET: CONFIG_${sym}=${want}" >&2
        missing=$((missing+1))
    fi
done < "$FRAGMENT"
if (( missing )); then
    echo "==> $missing symbols did not take. Each is either unavailable in this" >&2
    echo "    kernel or blocked by an unmet dependency; several are boot-critical." >&2
    echo "    See docs/KERNEL.md." >&2
    # This used to be a warning and the build carried on. It printed
    # "NOT SET: CONFIG_DWMAC_ROCKCHIP=y" - no Ethernet - and the six-hour platform
    # build ran anyway, because nothing downstream reads this output. Four symbols
    # were in that list and the two that were noise (one needing GCC 12, one
    # needing hardware this board does not have) are what made it easy to skim
    # past the two that were not.
    #
    # So the fragment is a contract now: every symbol in it has to take, and the
    # noise was removed from the fragment rather than tolerated in the check.
    # EDGE1_ALLOW_CONFIG_MISS=1 is for trying a symbol out, not for the pipeline.
    if [[ "${EDGE1_ALLOW_CONFIG_MISS:-0}" != "1" ]]; then
        echo >&2
        echo "    Stopping here. Fix the fragment - add the missing dependency, or drop" >&2
        echo "    the symbol with a comment saying why it cannot be set - rather than" >&2
        echo "    building a kernel that is missing what the fragment asked for." >&2
        echo "    EDGE1_ALLOW_CONFIG_MISS=1 overrides this for a one-off experiment." >&2
        exit 1
    fi
    echo "    EDGE1_ALLOW_CONFIG_MISS=1 is set; continuing anyway." >&2
fi

echo "==> building Image and $DTB.dtb ($JOBS jobs)"
make "${MAKE_ARGS[@]}" -j"$JOBS" Image "rockchip/${DTB}.dtb"

# One dtb, staged alone. Android concatenates every *.dtb in this directory into
# dtb.img and packs it into boot.img, via BOARD_INCLUDE_DTB_IN_BOOTIMG and
# BOARD_PREBUILT_DTBIMAGE_DIR - see BoardConfig.mk, which explains why this board
# uses boot header v2 and no vendor_boot.
echo "==> staging the dtb for dtb.img"
rm -rf "$DTB_STAGE"
mkdir -p "$DTB_STAGE"
cp "out/arch/arm64/boot/dts/rockchip/${DTB}.dtb" "$DTB_STAGE/"

# sys_led as a panic indicator, in the staged copy (the kernel tree is not touched).
# The board is brought up without a UART adapter, and until HDMI is up the LED is all
# the kernel can say: heartbeat, its DT default, while it runs; with panic-indicator,
# an even 2.5Hz blink once it has panicked (kernel/panic.c toggles those LEDs every
# 200ms while it waits). Mainline sets it on rock960, pinebook-pro and puma, not on
# the Edge. The fragment's LEDS_TRIGGER_PANIC is what acts on it.
readonly SYS_LED=/leds/led-0
staged="$DTB_STAGE/${DTB}.dtb"
command -v fdtput >/dev/null 2>&1 || {
    echo "fdtput not found - it is in device-tree-compiler, which build/windows/" >&2
    echo "apt-packages.txt lists; re-run the Provision stage, or apt-get install it." >&2
    exit 1; }
if [[ "$(fdtget "$staged" "$SYS_LED" label 2>/dev/null)" == "sys_led" ]]; then
    fdtput "$staged" "$SYS_LED" panic-indicator
    fdtget "$staged" "$SYS_LED" panic-indicator >/dev/null
    echo "    $SYS_LED (sys_led): panic-indicator set"
else
    echo "==> WARNING: ${DTB}.dtb has no sys_led at $SYS_LED any more; the LED will" >&2
    echo "    not signal a kernel panic. Find the node with: fdtget -l $staged /leds" >&2
fi

# A ramoops region (Documentation/devicetree/bindings/reserved-memory/ramoops.yaml),
# so the kernel's log - and, through pmsg, Android's - survives a reset in RAM. The
# boot script on bootfs copies it to the card before it loads the next kernel; it
# finds the address in this same dtb (build-bootfs.sh reads it back), so the two
# cannot disagree. 768MiB is clear of everything U-Boot 2022.07 touches on the way:
# its own relocation and the relocated FDT and ramdisk sit at the top of RAM, the
# boot script's loads below 0x0a400000, BL31 below 2MiB - on the 2GB board and the
# 4GB one alike. Not AT 768MiB, though: the first capture showed the word at
# 0x30000000 overwritten across the reset with 0x5aa5f00f, the PATTERN the Rockchip
# DRAM init writes when it probes capacity (U-Boot has the same constant in
# arch/arm/include/asm/arch-rockchip/sdram_common.h, and sdram_detect_row_3_4()
# writes it at 3/4 of a power of two - 0x30000000 for 1GiB). Everything else
# survived, so the region starts 1MiB higher, off every address that probe uses
# (the next ones are 0x40000000 and up, far above the 3.25MiB it spans). Layout, in
# the order ram.c lays the zones out: 2 x 128KiB dmesg records (the log at a panic),
# 1MiB console, 2MiB pmsg. ram.c rounds each zone down to a power of two, so those
# are the sizes that hold. pmsg was 256KiB until the tenth card, where a crash loop
# logged 85KB/s and the capture held three seconds of logcat. No ECC: a flipped bit
# costs a character, and the decoder stays simple. build/edge1-pstore.py knows this
# layout and the old 1MiB one.
readonly RAMOOPS_NODE=/reserved-memory/ramoops@30100000
if ! fdtget -l "$staged" / | grep -qx reserved-memory; then
    fdtput -c "$staged" /reserved-memory
    fdtput -t i "$staged" /reserved-memory '#address-cells' 2
    fdtput -t i "$staged" /reserved-memory '#size-cells' 2
    fdtput "$staged" /reserved-memory ranges
fi
cells="$(fdtget "$staged" /reserved-memory '#address-cells' 2>/dev/null) $(fdtget "$staged" /reserved-memory '#size-cells' 2>/dev/null)"
if [[ "$cells" != "2 2" ]]; then
    echo "==> /reserved-memory in ${DTB}.dtb is not 2/2 cells; not adding ramoops." >&2
    echo "    The kernel log will not survive a reset. Fix this block." >&2
else
    fdtget -l "$staged" /reserved-memory | grep -qx "${RAMOOPS_NODE##*/}" \
        || fdtput -c "$staged" "$RAMOOPS_NODE"
    fdtput -t s "$staged" "$RAMOOPS_NODE" compatible ramoops
    fdtput -t x "$staged" "$RAMOOPS_NODE" reg 0 30100000 0 340000
    fdtput -t x "$staged" "$RAMOOPS_NODE" record-size 20000
    fdtput -t x "$staged" "$RAMOOPS_NODE" console-size 100000
    fdtput -t x "$staged" "$RAMOOPS_NODE" pmsg-size 200000
    echo "    $RAMOOPS_NODE: 3.25MiB ramoops (1MiB console, 2MiB pmsg, 2 panic records)"
fi

echo
echo "Image:  $KERNEL/out/arch/arm64/boot/Image  ($(du -h out/arch/arm64/boot/Image | cut -f1))"
echo "dtb:    $DTB_STAGE/${DTB}.dtb  ($(du -h "$DTB_STAGE/${DTB}.dtb" | cut -f1))"
echo
echo "The platform build copies the Image to \$(PRODUCT_OUT)/kernel and packs the"
echo "dtb into boot.img. Both are read at Kati parse time, so the kernel has to"
echo "be built before m - which is the order the pipeline runs them in."
