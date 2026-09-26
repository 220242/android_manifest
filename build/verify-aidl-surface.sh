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

readonly TREE="${1:-$HOME/aosp-14-edge1}"
readonly MANIFEST="$TREE/device/khadas/edge/vintf/manifest.xml"
readonly IFACES="$TREE/hardware/interfaces"

[[ -f "$MANIFEST" ]] || { echo "no manifest at $MANIFEST" >&2; exit 1; }
[[ -d "$IFACES" ]] || { echo "hardware/interfaces not synced at $IFACES" >&2; exit 1; }

# Pull every AIDL HAL name out of the device manifest.
python3 - "$MANIFEST" <<'PY' | while read -r name ver; do
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for hal in root.findall('hal'):
    if hal.get('format') != 'aidl':
        continue
    n = hal.findtext('name')
    v = hal.findtext('version') or '?'
    print(n, v)
PY
    # android.hardware.graphics.allocator -> hardware/interfaces/graphics/allocator/aidl
    rel="${name#android.hardware.}"
    path="$IFACES/${rel//.//}/aidl"
    echo "=============================================================="
    echo "$name  (declared version $ver)"
    if [[ ! -d "$path" ]]; then
        echo "  !! no AIDL definition at ${path#$TREE/}"
        echo "     Either the name is wrong or this interface does not exist in"
        echo "     this AOSP release. check_vintf will reject the manifest."
        continue
    fi
    # Frozen versions live under aidl/aidl_api/<pkg>/<ver>/; current is the source.
    api="$path/aidl_api/$name/$ver"
    src="$api"
    [[ -d "$api" ]] || src="$path/android/hardware/${rel//.//}"
    echo "  source: ${src#$TREE/}"
    find "$src" -name 'I*.aidl' 2>/dev/null | sort | while read -r f; do
        echo "  --- $(basename "$f") ---"
        # Method declarations only: lines ending in ');'
        grep -nE '^\s+[A-Za-z@].*\);\s*$' "$f" | sed 's/^/    /'
    done
done
