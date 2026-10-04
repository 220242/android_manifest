#!/usr/bin/env bash
#
# Offline check of the kernel config fragment: does every symbol in it take?
#
#   usage: build/dev/check-kernel-fragment.sh <linux-6.12-tree> [fragment]
#   (also checks that device/khadas/edge/kernel/patches/ applies to the tree)
#
# The same merge build-kernel.sh does - make defconfig, merge_config.sh -m,
# olddefconfig - and the same contract check, but with scripts/dummy-tools instead
# of a cross compiler, so it runs in seconds on any Linux box with make, gcc, flex
# and bison. A sparse kernel checkout is enough if it has the top-level Makefile,
# arch/arm64/{Makefile,configs}, scripts/, include/ and every Kconfig file.
#
# This is how CONFIG_LSM was caught being computed without selinux at defconfig
# time, and how the Android base block was filtered to what 6.12 can take. Run it
# before pushing any fragment change: a symbol that does not take stops the Kernel
# stage on the build host, hours into a pipeline run.
set -uo pipefail
L="$(cd "${1:?usage: $0 <linux-tree> [fragment]}" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="$(realpath "${2:-$HERE/device/khadas/edge/kernel/edge1_mainline.config}")"
DT="$L/scripts/dummy-tools/"

# The kernel patches build-kernel.sh applies must apply to this tree (or already be
# applied to it) - in name order, each on top of the ones before, as build-kernel.sh
# applies them (0007 edits what 0005 added). They are applied for the check and
# taken off again at the end.
bad_patch=0
applied=()
for p in "$HERE"/device/khadas/edge/kernel/patches/*.patch; do
    [[ -f "$p" ]] || continue
    if git -C "$L" apply --reverse --check "$p" 2>/dev/null; then
        echo "patch $(basename "$p"): already applied here"
    elif git -C "$L" apply "$p" 2>/dev/null; then
        echo "patch $(basename "$p"): applies"
        applied+=("$p")
    else
        echo "patch $(basename "$p"): DOES NOT APPLY" >&2
        bad_patch=1
    fi
done
for (( i=${#applied[@]}-1; i>=0; i-- )); do git -C "$L" apply -R "${applied[$i]}"; done
K="$(mktemp -d)"; trap 'rm -rf "$K"' EXIT
cd "$L"
make ARCH=arm64 CROSS_COMPILE="$DT" O="$K" defconfig >/dev/null 2>&1 || { echo "defconfig failed" >&2; exit 2; }
ARCH=arm64 CROSS_COMPILE="$DT" ./scripts/kconfig/merge_config.sh -m -O "$K" "$K/.config" "$F" >/dev/null 2>&1
make ARCH=arm64 CROSS_COMPILE="$DT" O="$K" olddefconfig >/dev/null 2>&1 || { echo "olddefconfig failed" >&2; exit 2; }
miss=0
while IFS= read -r line; do
    if [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
        if grep -q "^CONFIG_${BASH_REMATCH[1]}=[ym]" "$K/.config"; then
            echo "STILL SET: CONFIG_${BASH_REMATCH[1]}"; miss=$((miss+1)); fi
        continue
    fi
    [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)=(.*)$ ]] || continue
    sym="${BASH_REMATCH[1]}"; want="${BASH_REMATCH[2]}"
    [[ "$want" == '""' ]] && continue
    if ! grep -qx "CONFIG_${sym}=${want}" "$K/.config"; then
        echo "NOT SET: CONFIG_${sym}=${want} (got: $(grep -E "^(# )?CONFIG_${sym}[= ]" "$K/.config" | head -1))"
        miss=$((miss+1))
    fi
done < "$F"
echo "$miss symbol(s) did not take"
(( miss == 0 && bad_patch == 0 ))
