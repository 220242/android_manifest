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

# The F-Droid prebuilt lives outside the device tree (a copy that is replaced
# wholesale whenever it differs), in vendor/edge1/fdroid - see fetch-fdroid.sh. Its
# appearing or disappearing is a change for the finder too.
fdroid_mk="$TREE/vendor/edge1/fdroid/Android.mk"
had_fdroid=0; [[ -f "$fdroid_mk" ]] && had_fdroid=1
"$(dirname "${BASH_SOURCE[0]}")/fetch-fdroid.sh" "$TREE" || echo "fetch-fdroid.sh failed; continuing without F-Droid" >&2
has_fdroid=0; [[ -f "$fdroid_mk" ]] && has_fdroid=1
(( had_fdroid == has_fdroid )) || changed=1

# The same for the apps Edge1 Tools offers to install (fetch-apps.sh, vendor/edge1/apps).
apps_bp="$TREE/vendor/edge1/apps/Android.bp"
had_apps=0; [[ -f "$apps_bp" ]] && had_apps=1
"$(dirname "${BASH_SOURCE[0]}")/fetch-apps.sh" "$TREE" || echo "fetch-apps.sh failed; continuing without the bundled apps" >&2
has_apps=0; [[ -f "$apps_bp" ]] && has_apps=1
(( had_apps == has_apps )) || changed=1

# This board's patches on synced projects (FFmpeg's V4L2 request hwaccels, the
# FFmpeg Codec2 service): device/khadas/edge/patches/<project path>/. A patch that
# does not apply stops the build here rather than in the middle of it.
"$(dirname "${BASH_SOURCE[0]}")/apply-patches.sh" "$TREE" || {
    echo "apply-patches.sh failed: a patch in device/khadas/edge/patches does not apply" >&2
    exit 1
}

# The builder's own settings: language, time zone, signing keys. Product config
# reads them; they hold no module, so the finder cache is not concerned.
"$(dirname "${BASH_SOURCE[0]}")/local-config.sh" "$TREE" || echo "local-config.sh failed; continuing with Android's defaults and the test keys" >&2

if (( changed )); then
    # Soong's finder caches the tree walk. A changed device tree that the cache
    # predates would be found only on the second build, which is the kind of
    # thing that reads as a flaky build system.
    rm -rf "$TREE/out/.module_paths"
    echo "device/khadas/edge: placed as a real directory (finder cache cleared)"
else
    echo "device/khadas/edge: already current"
fi
