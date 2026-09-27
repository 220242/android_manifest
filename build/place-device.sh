#!/usr/bin/env bash
#
# Put device/khadas/edge into the AOSP tree as a real directory.
#
#   usage: place-device.sh <tree-dir>
#
# This used to be a symlink, and the symlink is why the first platform build
# never started:
#
#   build/make/core/product_config.mk:226: error: Cannot locate config makefile
#       for product "edge1_tv".
#
# AOSP does not glob for AndroidProducts.mk at make time. It reads
# out/.module_paths/AndroidProducts.mk.list, which Soong's finder writes by
# walking the source tree - and that walk does not descend into symlinked
# directories. So device/khadas/edge existed, lunch found the combo, and the
# product inside it was invisible. The same applies to Android.bp files and to
# the sepolicy directories, which Soong globs the same way: none of the device
# tree was being seen.
#
# The device tree still lives in this manifest repo, which stays the single
# source of truth. It is copied in before every stage that reads it, so a pull
# followed by a build always compiles the pulled files. Nothing edits the copy.
set -euo pipefail

readonly TREE="${1:?usage: place-device.sh <tree-dir>}"
readonly SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/device/khadas/edge"
readonly DST="$TREE/device/khadas/edge"

[[ -d "$SRC" ]] || { echo "no device tree at $SRC" >&2; exit 1; }

mkdir -p "$(dirname "$DST")"

changed=0
if [[ -L "$DST" ]]; then
    # The old layout. Always replace, whatever it points at.
    rm -f "$DST"
    changed=1
fi

rm -rf "$DST.tmp"
cp -a "$SRC" "$DST.tmp"

if [[ -d "$DST" ]] && diff -rq "$DST" "$DST.tmp" >/dev/null 2>&1; then
    rm -rf "$DST.tmp"
else
    rm -rf "$DST"
    mv "$DST.tmp" "$DST"
    changed=1
fi

if (( changed )); then
    # Soong's finder caches the tree walk. A changed device tree that the cache
    # predates would be found only on the second build, which is the kind of
    # thing that reads as a flaky build system.
    rm -rf "$TREE/out/.module_paths"
    echo "device/khadas/edge: placed as a real directory (finder cache cleared)"
else
    echo "device/khadas/edge: already current"
fi
