#!/usr/bin/env bash
#
# Print the real method surface of the AIDL HALs this port has to implement.
#
#   usage: verify-aidl-surface.sh [tree-dir]
#
# Why this exists: the shims in device/khadas/edge/shims must match the AIDL
# definitions in the synced tree exactly, and those signatures moved between
# Android 13, 14 and the 14 QPR releases. Writing a shim against a remembered
# signature produces code that looks right and does not compile. Run this, then
# write the shim.
#
# The list used to come from the device manifest alone. That stopped working the
# moment the manifest was cut down to the two HALs this device declares directly
# - every AOSP HAL service installs its own VINTF fragment, so duplicating them
# in the device manifest is the error - and the script silently produced an empty
# file. An empty diagnostic is worse than none, because it reads as a pass.
#
# So the list is now the union of three sources, and it says which is which.
set -euo pipefail

readonly TREE="${1:-$HOME/android_khadas/aosp-14-edge1}"
readonly DEV="$TREE/device/khadas/edge"
readonly MANIFEST="$DEV/vintf/manifest.xml"
readonly IFACES="$TREE/hardware/interfaces"

[[ -d "$IFACES" ]] || { echo "hardware/interfaces not synced at $IFACES" >&2; exit 1; }

# 1. The HALs this port implements, bridges or plans to. This is the part that
#    does not depend on what the device happens to declare today: these are the
#    interfaces the shims are written against.
readonly WANTED=(
    android.hardware.graphics.allocator
    android.hardware.graphics.composer3
    android.hardware.graphics.common
    android.hardware.audio.core
    android.hardware.audio.effect
    android.hardware.audio.common
    android.media.audio.common.types
    android.hardware.tv.input
    android.hardware.tv.hdmi.cec
    android.hardware.tv.hdmi.connection
    android.hardware.power
    android.hardware.memtrack
    android.hardware.light
    android.hardware.bluetooth
    android.hardware.drm
    android.hardware.wifi
    android.hardware.wifi.supplicant
)

# 2. Anything the device manifest declares as AIDL, and 3. anything the shims'
#    own VINTF fragments declare. Both are listed even if they duplicate the
#    built-in list; the union is deduplicated below.
collect_xml_names() {
    local f
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        python3 - "$f" <<'PY' || true
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    raise SystemExit(0)
for hal in root.findall('hal'):
    if hal.get('format') == 'aidl':
        n = hal.findtext('name')
        if n:
            print(n)
PY
    done
}

names=$(printf '%s\n' "${WANTED[@]}" \
        | cat - <(collect_xml_names "$MANIFEST" "$DEV"/shims/*/*.xml "$DEV"/shims/*/*/*.xml) \
        | sed '/^$/d' | sort -u)

echo "=============================================================="
echo "AIDL surface for $(wc -l <<< "$names") interfaces"
echo "  tree:     $TREE"
echo "  built-in: ${#WANTED[@]} interfaces this port implements or bridges"
echo "  manifest: $MANIFEST"
echo

# The device manifest's HIDL entries, for the record: they are the two HALs this
# device declares directly, and neither has an AIDL surface to dump.
if [[ -f "$MANIFEST" ]]; then
    echo "device manifest declares, as HIDL:"
    python3 - "$MANIFEST" <<'PY' || true
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
n = 0
for hal in root.findall('hal'):
    if hal.get('format') != 'aidl':
        v = ','.join(x.text for x in hal.findall('version')) or '-'
        print('  %-48s %s' % (hal.findtext('name', '?'), v))
        n += 1
if not n:
    print('  (none)')
PY
    echo
fi

# Locate an interface by SEARCHING for its aidl_api directory rather than
# deriving a path from the package name.
#
# Deriving the path produced false negatives that looked like missing
# interfaces: android.hardware.graphics.composer3 lives in
# graphics/composer/aidl, not graphics/composer3/aidl, and
# android.hardware.audio.core lives in audio/aidl, not audio/core/aidl. The
# package name does not track the directory layout. The aidl_api directory,
# however, is always named after the package exactly, so that is the key.
#
# The version is not asked for either: the newest frozen one is what a shim has
# to build against, and it is also the number in the -V<n>-ndk module name.
find_iface() {
    local name="$1" api="" src="" r
    # Only existing roots, and '|| true' on every find: pipefail is on, and a
    # find that walks a missing directory exits non-zero even when it found
    # everything it was asked for. Under set -e that ends the script mid-report.
    local roots=()
    for r in "$IFACES" "$TREE/system/hardware/interfaces" "$TREE/frameworks" \
             "$TREE/hardware/libhardware"; do
        [[ -d "$r" ]] && roots+=( "$r" )
    done
    (( ${#roots[@]} )) || { printf ''; return 0; }

    api=$(find "${roots[@]}" -type d -path "*/aidl_api/$name" 2>/dev/null | head -1) || true
    if [[ -n "$api" ]]; then
        src=$(find "$api" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' 2>/dev/null \
              | sort -V | tail -1) || true
        [[ -n "$src" ]] || src="$api/current"
        [[ -d "$src" ]] || src=""
    fi
    if [[ -z "$src" ]]; then
        src=$(find "${roots[@]}" -type d -path "*/${name//.//}" 2>/dev/null | head -1) || true
    fi
    printf '%s' "$src"
}

while read -r name; do
    [[ -n "$name" ]] || continue
    echo "=============================================================="
    src=$(find_iface "$name")
    if [[ -z "$src" ]]; then
        echo "$name"
        echo "  !! no aidl_api directory and no package source in this tree."
        echo "     The name is wrong, or the interface does not exist in this"
        echo "     release - a shim naming it would fail Soong analysis."
        continue
    fi
    case "$src" in
        */aidl_api/*/current) echo "$name  (NOT frozen; showing 'current')" ;;
        */aidl_api/*)         echo "$name  (frozen V$(basename "$src") -> ${name}-V$(basename "$src")-ndk)" ;;
        *)                    echo "$name  (no aidl_api snapshot; showing the source tree)" ;;
    esac
    echo "  source: ${src#$TREE/}"

    while read -r f; do
        [[ -n "$f" ]] || continue
        echo "  --- $(basename "$f") ---"
        # Method declarations only: lines ending in ');'
        grep -nE '^[[:space:]]+[A-Za-z@].*\);[[:space:]]*$' "$f" | sed 's/^/    /' || true
    done < <(find "$src" -name 'I*.aidl' 2>/dev/null | sort)
done <<< "$names"
