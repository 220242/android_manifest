#!/usr/bin/env bash
#
# Khadas Edge1 - static validation of the device tree.
#
# Catches the errors that otherwise surface as a Soong/Kati failure minutes into
# a build, or worse as a missing file on the image: malformed XML, a
# PRODUCT_COPY_FILES source that does not exist, a HAL declared in the device
# manifest but in no VINTF fragment, or an Android 10 construct that Android 14
# removed.
#
# Runs with no AOSP tree present, which is the point: it is the one check that
# can be run before a 120GiB sync.
#
set -uo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEV="$ROOT/device/khadas/edge"
errors=0
warns=0

err()  { printf '  \033[31mERROR\033[0m %s\n' "$*"; errors=$((errors+1)); }
wrn()  { printf '  \033[33mWARN \033[0m %s\n' "$*"; warns=$((warns+1)); }
ok()   { printf '  \033[32mok   \033[0m %s\n' "$*"; }

echo "Khadas Edge1 device tree verification"
echo "root: $ROOT"
echo

# --- 1. XML well-formedness ---------------------------------------------------
echo "[1] XML well-formedness"
while IFS= read -r f; do
    if python3 -c "import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])" "$f" 2>/dev/null; then
        ok "${f#$ROOT/}"
    else
        msg=$(python3 -c "import sys,xml.etree.ElementTree as ET
try: ET.parse(sys.argv[1])
except Exception as e: print(e)" "$f" 2>&1)
        err "${f#$ROOT/}: $msg"
    fi
done < <(find "$ROOT/device" "$ROOT/manifests" -name '*.xml' 2>/dev/null | sort)
echo

# --- 2. PRODUCT_COPY_FILES sources --------------------------------------------
# Only device-local sources are checked; AOSP-relative ones (frameworks/...,
# device/google/atv/...) cannot exist until a tree is synced.
echo "[2] PRODUCT_COPY_FILES sources inside the device tree"
while IFS= read -r src; do
    # $(LOCAL_PATH) and the literal path both resolve to the device dir.
    rel="${src#\$(LOCAL_PATH)/}"
    rel="${rel#device/khadas/edge/}"
    if [[ -e "$DEV/$rel" ]]; then
        ok "$rel"
    else
        err "PRODUCT_COPY_FILES references a missing file: $rel"
    fi
done < <(grep -hoE '(\$\(LOCAL_PATH\)|device/khadas/edge)/[A-Za-z0-9_./-]+' \
            "$DEV/device.mk" 2>/dev/null | sort -u)
echo

# --- 3. BoardConfig file references -------------------------------------------
echo "[3] BoardConfig.mk file references"
while IFS= read -r ref; do
    if [[ -e "$ROOT/$ref" ]]; then
        ok "${ref#device/khadas/edge/}"
    else
        err "BoardConfig.mk references a missing file: $ref"
    fi
done < <(grep -hoE 'device/khadas/edge/[A-Za-z0-9_./-]+' "$DEV/BoardConfig.mk" 2>/dev/null \
            | grep -vxE 'device/khadas/edge/(sepolicy/vendor|vintf)' | sort -u)
# Directories referenced for sepolicy/vintf are checked separately since they
# are dirs, not files.
for d in sepolicy/vendor vintf; do
    [[ -d "$DEV/$d" ]] && ok "$d/ (dir)" || err "BoardConfig.mk references missing dir: $d"
done
echo

# --- 4. VINTF: fragments must NOT duplicate the device manifest ----------------
#
# This check used to assert the opposite - that every HAL in a shim fragment also
# appeared in vintf/manifest.xml - and that was backwards. Soong's
# vintf_fragments: installs each service's fragment into
# /vendor/etc/vintf/manifest/, and VINTF merges those into the device manifest at
# build time, so a HAL declared in both places is declared twice.
echo "[4] VINTF: shim fragments vs device manifest (duplicates are the error)"
manifest_hals=$(python3 - "$DEV/vintf/manifest.xml" <<'PYX'
import sys, xml.etree.ElementTree as ET
for hal in ET.parse(sys.argv[1]).getroot().findall("hal"):
    print(hal.findtext("name"))
PYX
)
frag_total=0
while IFS= read -r frag; do
    while IFS= read -r name; do
        frag_total=$((frag_total+1))
        if grep -qxF "$name" <<<"$manifest_hals"; then
            err "$name is declared in BOTH ${frag#$ROOT/} and vintf/manifest.xml"
        else
            ok "$name (from ${frag##*/}, not duplicated)"
        fi
    done < <(python3 - "$frag" <<'PYX'
import sys, xml.etree.ElementTree as ET
for hal in ET.parse(sys.argv[1]).getroot().findall("hal"):
    print(hal.findtext("name"))
PYX
)
done < <(find "$DEV/shims" -name '*.xml' 2>/dev/null | sort)
(( frag_total == 0 )) && ok "no shim fragments found"
echo "  device manifest declares $(grep -c '<hal ' "$DEV/vintf/manifest.xml") HAL(s) directly"
echo

# --- 5. Android 10 constructs Android 14 removed ------------------------------
echo "[5] obsolete Android 10 constructs"
declare -A obsolete=(
    [BUILD_EMULATOR]="deleted from build/make in Android 11"
    [TARGET_USES_64_BIT_BINDER]="binder has been 64-bit unconditionally since 8.0"
    [OVERRIDE_RS_DRIVER]="RenderScript was removed from the platform in Android 12"
    [BOARD_OVERRIDE_RS_CPU_VARIANT]="RenderScript was removed in Android 12"
    [ro.sys.sdcardfs]="sdcardfs was replaced by FUSE in Android 11"
    [PRODUCT_AAPT_PREF_CONFIG=hdpi]="a TV product should prefer tvdpi"
    [BOARD_SEPOLICY_DIRS]="split per-partition in Android 11; use BOARD_VENDOR_SEPOLICY_DIRS"
    [TARGET_CPU_SMP]="unused since Android 5"
    [libstagefright_soft_]="the soft codec modules were removed after Android 9"
    [DefaultContainerService]="removed after Android 9"
    [local_time.default]="removed after Android 9"
)
for pat in "${!obsolete[@]}"; do
    hits=$(grep -rln -- "$pat" "$DEV" 2>/dev/null | grep -vE '/(docs|README)' || true)
    if [[ -n "$hits" ]]; then
        while IFS= read -r h; do
            # A mention inside a comment is documentation, not usage.
            if grep -n -- "$pat" "$h" | grep -qvE '^\s*[0-9]+:\s*(#|//|\*|<!--)'; then
                err "$pat used in ${h#$ROOT/} - ${obsolete[$pat]}"
            fi
        done <<<"$hits"
    fi
done
(( errors == 0 )) && ok "none found"
echo

# --- 6. Shell script syntax ---------------------------------------------------
echo "[6] shell script syntax"
while IFS= read -r s; do
    if bash -n "$s" 2>/dev/null; then ok "${s#$ROOT/}"; else err "${s#$ROOT/} has a syntax error"; fi
done < <(find "$ROOT/build" "$DEV" -name '*.sh' 2>/dev/null | sort)
echo

# --- 7. Kernel config sanity --------------------------------------------------
echo "[7] kernel config fragment"
readonly FRAG="$DEV/kernel/edge1_android14.config"
if [[ -f "$FRAG" ]]; then
    # Symbols that are mandatory for Android 14 to boot at all.
    for must in CONFIG_ANDROID_BINDERFS CONFIG_BPF_SYSCALL CONFIG_PSI \
                CONFIG_FS_ENCRYPTION CONFIG_DM_VERITY CONFIG_USERFAULTFD; do
        grep -qE "^${must}=y" "$FRAG" && ok "$must=y" || err "$FRAG is missing ${must}=y"
    done
    # Contradictions: a symbol both set and unset.
    while read -r sym; do
        if grep -qE "^CONFIG_${sym}=" "$FRAG" && grep -qE "^# CONFIG_${sym} is not set" "$FRAG"; then
            err "CONFIG_${sym} is both set and unset in the fragment"
        fi
    done < <(grep -oE '^CONFIG_[A-Z0-9_]+' "$FRAG" | sed 's/^CONFIG_//' | sort -u)
else
    err "missing $FRAG"
fi
echo

echo "=========================================="
echo "errors: $errors   warnings: $warns"
(( errors )) && exit 1
exit 0
