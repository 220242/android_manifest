#!/usr/bin/env bash
#
# Khadas Edge1 - build the 4.19.111 kernel with the Android 14 config delta.
#
#   usage: build-kernel.sh [tree-dir]
#
set -euo pipefail

readonly TREE="${1:-$HOME/aosp-14-edge1}"
readonly KERNEL="$TREE/kernel"
readonly DEVICE_DIR="$TREE/device/khadas/edge"
readonly DEFCONFIG="kedge_defconfig"
readonly DTS="rk3399-khadas-edge-android"
readonly FRAGMENT="$DEVICE_DIR/kernel/edge1_android14.config"

[[ -d "$KERNEL" ]] || { echo "no kernel at $KERNEL; run sync.sh first" >&2; exit 1; }
[[ -f "$FRAGMENT" ]] || { echo "missing config fragment $FRAGMENT" >&2; exit 1; }

cd "$KERNEL"

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-android-
# AOSP's own clang, so the kernel and platform agree on toolchain. The Android 10
# BSP built this kernel with GCC 6.3; 4.19 builds clean with AOSP clang and the
# platform no longer ships a GCC prebuilt.
export PATH="$TREE/prebuilts/clang/host/linux-x86/clang-r487747c/bin:$PATH"
export CC=clang
export CLANG_TRIPLE=aarch64-linux-gnu-

readonly JOBS="$(nproc)"

echo "==> base defconfig: $DEFCONFIG"
make O=out "$DEFCONFIG"

# merge_config.sh applies the Android 14 delta on top and, importantly, warns on
# any symbol it could not set - which is how a missing backport (for example
# CONFIG_ANDROID_BINDERFS on a kernel too old for it) is caught here rather than
# as a boot hang.
echo "==> merging Android 14 config delta"
ARCH=arm64 ./scripts/kconfig/merge_config.sh -m -O out \
    out/.config "$FRAGMENT"
make O=out olddefconfig

echo "==> verifying the delta actually took"
missing=0
while read -r line; do
    [[ "$line" =~ ^CONFIG_([A-Z0-9_]+)=(.*)$ ]] || continue
    sym="${BASH_REMATCH[1]}"; want="${BASH_REMATCH[2]}"
    [[ "$want" == '""' ]] && continue
    if ! grep -qx "CONFIG_${sym}=${want}" out/.config; then
        echo "  NOT SET: CONFIG_${sym}=${want}" >&2
        missing=$((missing+1))
    fi
done < "$FRAGMENT"
if (( missing )); then
    echo "==> $missing config symbols did not take." >&2
    echo "    Each is either unavailable on 4.19 or depends on an unmet symbol." >&2
    echo "    See docs/KERNEL.md; do not ignore these, several are boot-critical." >&2
fi

echo "==> building Image + dtbs ($JOBS jobs)"
make O=out -j"$JOBS" Image "rockchip/${DTS}.dtb"
make O=out -j"$JOBS" modules

# resource.img packs the DTB plus the boot logo; the Rockchip bootloader expects
# it rather than a bare dtbo.
echo "==> packing resource.img"
if [[ -x scripts/mkmultidtb.py ]]; then
    ./scripts/mkmultidtb.py "$DTS" || true
fi
./scripts/resource_tool --dtbname "out/arch/arm64/boot/dts/rockchip/${DTS}.dtb" \
    logo.bmp logo_kernel.bmp 2>/dev/null || \
    echo "  note: resource_tool not present; pack resource.img with the Rockchip BSP tooling"

echo
echo "kernel: $KERNEL/out/arch/arm64/boot/Image"
echo "dtb:    $KERNEL/out/arch/arm64/boot/dts/rockchip/${DTS}.dtb"
