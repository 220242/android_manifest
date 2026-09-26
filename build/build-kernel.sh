#!/usr/bin/env bash
#
# Khadas Edge1 - build the 4.19.111 kernel with the Android 14 config delta.
#
#   usage: build-kernel.sh [tree-dir]
#
set -euo pipefail

readonly TREE="${1:-$HOME/aosp-14-edge1}"
readonly KERNEL="$TREE/kernel/khadas/edge"
readonly DEVICE_DIR="$TREE/device/khadas/edge"
readonly DEFCONFIG="kedge_defconfig"
readonly DTS="rk3399-khadas-edge-android"
readonly FRAGMENT="$DEVICE_DIR/kernel/edge1_android14.config"

[[ -d "$KERNEL" ]] || { echo "no kernel at $KERNEL; run sync.sh first" >&2; exit 1; }
[[ -f "$FRAGMENT" ]] || { echo "missing config fragment $FRAGMENT" >&2; exit 1; }

cd "$KERNEL"

# ---------------------------------------------------------------------------
# Toolchain.
#
# Two bugs were fixed here.
#
# 1. CROSS_COMPILE pointed at aarch64-linux-android-, which does not exist:
#    AOSP 14 ships no aarch64 GCC prebuilt (only host x86_64 and mingw). With no
#    compiler, scripts/gcc-version.sh printed "Is your PATH set correctly?" where
#    a version number was expected, GCC_VERSION's $(shell,...) default got that
#    text, and Kconfig died with "init/Kconfig:17: syntax error".
#
# 2. The toolchain was exported as environment variables. The kernel Makefile
#    assigns CC = $(CROSS_COMPILE)gcc with '=', and an environment variable does
#    not override a variable assigned inside a makefile - only a command-line
#    assignment does. So CC=clang was silently ignored.
#
# Default is the Ubuntu aarch64 cross GCC, a complete and self-consistent
# toolchain (compiler plus binutils) installed by provision-wsl.sh. Rockchip's
# 4.19 tree is GCC-oriented, and mixing a very new clang with a 2019 kernel
# invites unrelated failures.
#
# Set KERNEL_USE_CLANG=1 to build with AOSP's clang instead, keeping GNU binutils
# for as/ld via CROSS_COMPILE.
# ---------------------------------------------------------------------------
readonly CROSS=aarch64-linux-gnu-

if ! command -v "${CROSS}gcc" >/dev/null 2>&1; then
    echo "${CROSS}gcc not found." >&2
    echo "Install it: sudo apt-get install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu" >&2
    echo "Or re-run the Provision stage, which now installs it." >&2
    exit 1
fi

MAKE_ARGS=(
    O=out
    ARCH=arm64
    "CROSS_COMPILE=$CROSS"
)

if [[ "${KERNEL_USE_CLANG:-0}" == "1" ]]; then
    # The version directory is discovered rather than hardcoded: it changes with
    # every AOSP release, and a stale pinned path fails only after defconfig has
    # already run.
    CLANG_DIR=$(find "$TREE/prebuilts/clang/host/linux-x86" -maxdepth 1 -type d \
                     -name 'clang-r*' 2>/dev/null | sort -V | tail -1)
    if [[ -z "$CLANG_DIR" ]]; then
        echo "no clang prebuilt under $TREE/prebuilts/clang/host/linux-x86" >&2
        exit 1
    fi
    export PATH="$CLANG_DIR/bin:$PATH"
    echo "==> toolchain: $(basename "$CLANG_DIR") (clang) + $CROSS binutils"
    MAKE_ARGS+=(
        CC=clang
        HOSTCC=clang
        HOSTCXX=clang++
        "CLANG_TRIPLE=$CROSS"
    )
else
    echo "==> toolchain: $("${CROSS}gcc" --version | head -1)"
fi

# HOSTCFLAGS=-fcommon is not optional on any modern distro compiler.
#
# GCC 10 changed the default from -fcommon to -fno-common, so tentative
# definitions of the same symbol in two translation units no longer merge.
# scripts/dtc has exactly that shape: yylloc is defined in both dtc-lexer.lex.c
# and dtc-parser.tab.c, and the host link fails with
#   multiple definition of `yylloc'
# Upstream fixed it by adding extern, but not in 4.19. -fcommon restores the old
# behaviour for host tools only; it does not affect the kernel itself.
#
# 4.19's Makefile appends $(HOSTCFLAGS) to KBUILD_HOSTCFLAGS, so setting it on
# the command line adds to the flags rather than replacing them.
MAKE_ARGS+=( "HOSTCFLAGS=-fcommon" )

# GCC 11 and clang 17+ both raise warnings on 2019 kernel code that 4.19 never
# saw. None are set -Werror by 4.19 itself, but subsystem makefiles that do add
# -Werror would stop the build on code that is not ours to fix.
MAKE_ARGS+=(
    "KCFLAGS=-Wno-error -Wno-attribute-alias -Wno-stringop-truncation -Wno-stringop-overflow -Wno-array-bounds -Wno-maybe-uninitialized -Wno-misleading-indentation -Wno-zero-length-bounds -Wno-dangling-pointer"
)

readonly JOBS="$(nproc)"

echo "==> base defconfig: $DEFCONFIG"
make "${MAKE_ARGS[@]}" "$DEFCONFIG"

# merge_config.sh applies the Android 14 delta on top and, importantly, warns on
# any symbol it could not set - which is how a missing backport (for example
# CONFIG_ANDROID_BINDERFS on a kernel too old for it) is caught here rather than
# as a boot hang.
echo "==> merging Android 14 config delta"
ARCH=arm64 CROSS_COMPILE=$CROSS ./scripts/kconfig/merge_config.sh -m -O out \
    out/.config "$FRAGMENT"
make "${MAKE_ARGS[@]}" olddefconfig

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
make "${MAKE_ARGS[@]}" -j"$JOBS" Image "rockchip/${DTS}.dtb"
make "${MAKE_ARGS[@]}" -j"$JOBS" modules

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
