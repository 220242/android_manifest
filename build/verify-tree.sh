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
    # "CONFIG_X=n" is not how Kconfig disables a symbol. merge_config.sh reports
    # the line as redefining the value and then keeps the base setting, so the
    # fragment silently has no effect. The correct form is
    # "# CONFIG_X is not set". Three of these were shipped before this check.
    while read -r bad; do
        err "$FRAG uses '$bad'; Kconfig needs '# ${bad%=n} is not set'"
    done < <(grep -oE '^CONFIG_[A-Z0-9_]+=n$' "$FRAG" || true)

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

# --- 8. Lunch combo form ------------------------------------------------------
# Android 14 requires <product>-<release>-<variant> and rejects a two-part combo
# outright, so a wrong form here is not a warning, it is a build that never
# starts. Both places that spell the combo out are checked, and against each
# other: build.sh composes it, AndroidProducts.mk lists it for the menu.
echo "[8] lunch combo form"
readonly PRODUCTS_MK="$DEV/AndroidProducts.mk"
if [[ -f "$PRODUCTS_MK" ]]; then
    combos=$(sed -n '/^COMMON_LUNCH_CHOICES/,/[^\\]$/p' "$PRODUCTS_MK" \
             | grep -oE '[a-z0-9_]+-[a-z0-9_]+(-[a-z0-9_]+)?' || true)
    if [[ -z "$combos" ]]; then
        err "$PRODUCTS_MK declares no COMMON_LUNCH_CHOICES"
    fi
    while read -r c; do
        [[ -n "$c" ]] || continue
        if [[ "$(tr -cd - <<< "$c" | wc -c)" -eq 2 ]]; then
            ok "$c"
        else
            err "'$c' is not <product>-<release>-<variant>; Android 14 lunch rejects it"
        fi
    done <<< "$combos"
fi
if [[ -f "$ROOT/build/build.sh" ]]; then
    if grep -qE 'TARGET="[a-z0-9_]+-\$\{RELEASE\}-\$\{VARIANT\}"' "$ROOT/build/build.sh"; then
        ok "build.sh composes product-release-variant"
    else
        err "build.sh does not compose a three-part lunch target"
    fi
fi
echo

# --- 9. sepolicy self-consistency -------------------------------------------
# Until now none of this was compiled: the device tree was a symlink and Soong's
# finder does not walk into those, so BOARD_VENDOR_SEPOLICY_DIRS pointed at
# something it never read. Now that it does, a type referenced by a *_contexts
# file and declared nowhere is a build failure, and a declared exec type that no
# file_contexts line labels is a service that can never enter its domain - which
# fails silently, as denials at runtime.
echo "[9] sepolicy self-consistency"
readonly SEDIR="$DEV/sepolicy/vendor"
if [[ -d "$SEDIR" ]]; then
    # Two ways a type gets declared, and missing the second one made this check
    # report seven false positives on its first run: 'type foo, ...' and the
    # property macros, which expand to a type declaration plus its attributes.
    declared=$( { grep -h '^type ' "$SEDIR"/*.te 2>/dev/null \
                    | sed -E 's/^type ([a-z0-9_]+).*/\1/'
                  grep -hoE '^[a-z_]*_prop\([a-z0-9_]+' "$SEDIR"/*.te 2>/dev/null \
                    | sed -E 's/.*\(//'
                } | sort -u)
    # Types this tree knowingly takes from AOSP's own policy. Listed rather than
    # matched by pattern: if a release renames one, this is where it surfaces.
    # The module probe checks the same list against the synced system/sepolicy,
    # which is the only place the answer is authoritative.
    aosp_types="gpu_device graphics_device hal_bluetooth_default_exec
                vendor_firmware_file vendor_kernel_modules vendor_file
                vendor_configs_file sysfs_type sysfs_devfreq sysfs_leds
                sysfs_thermal sysfs_devices_system_cpu"
    missing_types=0
    while read -r t; do
        [[ -n "$t" ]] || continue
        grep -qx "$t" <<< "$declared" && continue
        grep -qw "$t" <<< "$aosp_types" && continue
        err "$SEDIR labels '$t', which is declared in no .te file here and is not"
        err "  in the list of AOSP types this tree relies on"
        missing_types=$((missing_types+1))
    done < <(grep -hoE 'u:object_r:[a-z0-9_]+' "$SEDIR"/*_contexts 2>/dev/null \
             | sed 's/u:object_r://' | sort -u)
    (( missing_types )) || ok "every labelled type is declared or a known AOSP type"

    # An exec type nothing labels means the domain transition never happens.
    unused=0
    while read -r t; do
        [[ -n "$t" ]] || continue
        grep -q "$t" "$SEDIR/file_contexts" 2>/dev/null && continue
        err "$t is declared but no file_contexts line labels any binary with it"
        unused=$((unused+1))
    done < <(grep -x '.*_exec' <<< "$declared" || true)
    (( unused )) || ok "every declared exec type labels a binary"
else
    warn "no sepolicy directory at $SEDIR"
fi
echo

# --- 10. variable ownership --------------------------------------------------
# Product config runs before BoardConfig.mk and freezes the product variables, so
# a PRODUCT_* assignment in BoardConfig.mk is fatal:
#
#   BoardConfig.mk:101: error: cannot assign to readonly variable:
#       PRODUCT_USE_DYNAMIC_PARTITIONS
#
# The mirror image is not fatal - a BOARD_* variable set from a product makefile
# is evaluated early enough to survive - but it is an ordering dependency that
# breaks quietly, so it warns.
echo "[10] variable ownership"
if [[ -f "$DEV/BoardConfig.mk" ]]; then
    bad=$(grep -nE '^[[:space:]]*PRODUCT_[A-Z_0-9]+[[:space:]]*[:+?]?=' \
          "$DEV/BoardConfig.mk" || true)
    if [[ -n "$bad" ]]; then
        while read -r l; do
            err "BoardConfig.mk:$l is a product variable; product config already froze it"
        done <<< "$bad"
    else
        ok "BoardConfig.mk assigns no product variables"
    fi
fi
for pmk in "$DEV/edge1_tv.mk" "$DEV/device.mk"; do
    [[ -f "$pmk" ]] || continue
    bad=$(grep -nE '^[[:space:]]*(BOARD|TARGET)_[A-Z_0-9]+[[:space:]]*[:+?]?=' "$pmk" || true)
    if [[ -n "$bad" ]]; then
        while read -r l; do
            warn "$(basename "$pmk"):$l is a board variable in a product makefile"
        done <<< "$bad"
    else
        ok "$(basename "$pmk") assigns no board variables"
    fi
done
echo

echo "=========================================="
echo "errors: $errors   warnings: $warns"
(( errors )) && exit 1
exit 0
