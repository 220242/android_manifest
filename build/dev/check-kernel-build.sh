#!/usr/bin/env bash
#
# Compile chosen kernel objects and dtbs for arm64 with clang (LLVM=1), with the
# device's patches applied and its config - what build-kernel.sh would build, a
# few files at a time, in minutes rather than the owner's hour.
#
#   usage: build/dev/check-kernel-build.sh <linux-6.12-tree> <outdir> <target>...
#   e.g.   ... drivers/staging/media/rkvdec/rkvdec.o rockchip/rk3399-khadas-edge-v.dtb
#
# The tree needs the directories the targets and "make prepare" read (a sparse
# checkout grows with `git sparse-checkout add`). The patches are applied for the
# build and taken off again; the tree must have none of them applied to start
# with. CHECK_DTBS=y validates a dtb against the bindings (pip install dtschema).
#
# This is how patch 0005's FUSB302 nodes were validated and patch 0004 compiled
# with W=1; it does not run anything - card 24's ENOMEM from 0004 was a runtime
# argument check, which no build sees.
set -euo pipefail
L="$(cd "${1:?usage: $0 <linux-tree> <outdir> <target>...}" && pwd)"
O="$(mkdir -p "${2:?outdir}" && cd "$2" && pwd)"
shift 2
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="$HERE/device/khadas/edge/kernel/edge1_mainline.config"

applied=()
cleanup() {
    for (( i=${#applied[@]}-1; i>=0; i-- )); do git -C "$L" apply -R "${applied[$i]}"; done
}
trap cleanup EXIT
for p in "$HERE"/device/khadas/edge/kernel/patches/*.patch; do
    git -C "$L" apply "$p"
    applied+=("$p")
done

if [[ ! -f "$O/.config" || "$F" -nt "$O/.config" ]]; then
    make -s -C "$L" O="$O" ARCH=arm64 LLVM=1 defconfig
    "$L/scripts/kconfig/merge_config.sh" -m -O "$O" "$O/.config" "$F" > /dev/null
    make -s -C "$L" O="$O" ARCH=arm64 LLVM=1 olddefconfig
fi
make -s -C "$L" O="$O" ARCH=arm64 LLVM=1 -j"$(nproc)" prepare
make -C "$L" O="$O" ARCH=arm64 LLVM=1 -j"$(nproc)" W=1 "$@" 2>&1 \
    | grep -v "^make\[\|^  [A-Z]" || true
for t in "$@"; do
    [[ -e "$O/$t" || -e "$O/arch/arm64/boot/dts/$t" ]] && echo "built: $t" || { echo "NOT BUILT: $t" >&2; exit 1; }
done
