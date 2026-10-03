#!/usr/bin/env bash
#
# Regenerate device/khadas/edge/firmware/usb-adapters.mk from the files under
# device/khadas/edge/firmware/usb/ (LICENSES/ excepted): one PRODUCT_COPY_FILES line
# per file into /vendor/firmware and one into the ramdisk's /lib/firmware.
#
#   usage: build/dev/gen-usb-firmware-mk.sh
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly DIR="$ROOT/device/khadas/edge/firmware/usb"
readonly MK="$ROOT/device/khadas/edge/firmware/usb-adapters.mk"

mapfile -t files < <(cd "$DIR" && find . -type f ! -path './LICENSES/*' | sed 's#^\./##' | LC_ALL=C sort)
(( ${#files[@]} )) || { echo "no firmware under $DIR" >&2; exit 1; }
{
    cat <<'EOF'
# Khadas Edge1 - firmware for USB Wi-Fi and Bluetooth adapters.
#
# Included from device.mk. The drivers are built into the kernel (see the kernel
# config fragment, "USB Wi-Fi and Bluetooth adapters"), and a built-in USB driver
# probes an adapter that is plugged in at power-on within the first two seconds -
# before /vendor is mounted - so every file goes into the ramdisk's /lib/firmware
# as well as /vendor/firmware, like the AP6398S's. The files are linux-firmware's;
# usb/README.md says which commit and under which licences.
#
# Generated from the directory listing; regenerate rather than edit by hand:
#   build/dev/gen-usb-firmware-mk.sh
PRODUCT_COPY_FILES += \
EOF
    for f in "${files[@]}"; do
        printf '    device/khadas/edge/firmware/usb/%s:$(TARGET_COPY_OUT_VENDOR)/firmware/%s \\\n' "$f" "$f"
    done
    last=$(( ${#files[@]} - 1 ))
    for i in "${!files[@]}"; do
        f="${files[$i]}"; tail=' \'; (( i == last )) && tail=''
        printf '    device/khadas/edge/firmware/usb/%s:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/%s%s\n' "$f" "$f" "$tail"
    done
} > "$MK"
echo "$MK: ${#files[@]} files"
