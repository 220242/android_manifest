#!/usr/bin/env bash
#
# Print the real method surface of every AIDL HAL this device declares.
#
#   usage: verify-aidl-surface.sh [tree-dir]
#
# Why this exists: the shims in device/khadas/edge/shims must match the AIDL
# definitions in the synced tree exactly, and those signatures moved between
# Android 13, 14 and the 14 QPR releases. Writing a shim against a remembered
# signature produces code that looks right and does not compile. Run this, then
# write the shim.
#
set -euo pipefail

readonly TREE="${1:-$HOME/android_khadas/aosp-14-edge1}"
readonly MANIFEST="$TREE/device/khadas/edge/vintf/manifest.xml"
readonly IFACES="$TREE/hardware/interfaces"

[[ -f "$MANIFEST" ]] || { echo "no manifest at $MANIFEST" >&2; exit 1; }
[[ -d "$IFACES" ]] || { echo "hardware/interfaces not synced at $IFACES" >&2; exit 1; }

# Every AIDL HAL name and version declared by the device manifest.
readonly HALS=$(python3 - "$MANIFEST" <<'PY'
import sys, xml.etree.ElementTree as ET
for hal in ET.parse(sys.argv[1]).getroot().findall('hal'):
    if hal.get('format') != 'aidl':
        continue
    print(hal.findtext('name'), hal.findtext('version') or 'current')
PY
)

# Locate an interface by SEARCHING for its aidl_api directory rather than
# deriving a path from the package name.
#
# Deriving the path produced false negatives that looked like missing
# interfaces: android.hardware.graphics.composer3 lives in
# graphics/composer/aidl, not graphics/composer3/aidl, and
# android.hardware.audio.core lives in audio/aidl, not audio/core/aidl. The
# package name does not track the directory layout. The aidl_api directory,
# however, is always named after the package exactly, so that is the key.
find_iface() {
    local name="$1" ver="$2" src
    src=$(find "$IFACES" -type d -path "*/aidl_api/$name/$ver" 2>/dev/null | head -1)
    if [[ -z "$src" ]]; then
        # Unfrozen interfaces have no numbered snapshot, only 'current'.
        src=$(find "$IFACES" -type d -path "*/aidl_api/$name/current" 2>/dev/null | head -1)
    fi
    if [[ -z "$src" ]]; then
        # Last resort: the package's own source tree, before any snapshot.
        src=$(find "$IFACES" -type d -path "*/${name//.//}" 2>/dev/null | head -1)
    fi
    printf '%s' "$src"
}

while read -r name ver; do
    [[ -n "$name" ]] || continue
    echo "=============================================================="
    echo "$name  (declared version $ver)"

    src=$(find_iface "$name" "$ver")
    if [[ -z "$src" ]]; then
        echo "  !! not found under ${IFACES#$TREE/}"
        echo "     Searched aidl_api/$name/{$ver,current} and the package source."
        echo "     Either the name in vintf/manifest.xml is wrong or the interface"
        echo "     does not exist in this release; check_vintf would reject it."
        continue
    fi
    case "$src" in
        */aidl_api/*/"$ver") ;;
        */aidl_api/*/current) echo "  NOTE: version $ver is not frozen; showing 'current'" ;;
        *)                    echo "  NOTE: no aidl_api snapshot; showing the source tree" ;;
    esac
    echo "  source: ${src#$TREE/}"

    while read -r f; do
        [[ -n "$f" ]] || continue
        echo "  --- $(basename "$f") ---"
        # Method declarations only: lines ending in ');'
        grep -nE '^[[:space:]]+[A-Za-z@].*\);[[:space:]]*$' "$f" | sed 's/^/    /' || true
    done < <(find "$src" -name 'I*.aidl' 2>/dev/null | sort)
done <<< "$HALS"
