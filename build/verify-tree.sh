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
# Comments stripped first. Without that, this check reported
# device/khadas/edge/bluetooth as a missing file - from the comment that explains
# why the directory was deleted. A check that fails on its own explanation trains
# people to ignore it.
done < <(sed 's/#.*//' "$DEV/BoardConfig.mk" 2>/dev/null \
            | grep -hoE 'device/khadas/edge/[A-Za-z0-9_./-]+' \
            | grep -vxE 'device/khadas/edge/(sepolicy/vendor|vintf)' | sort -u)
# Directories referenced for sepolicy/vintf are checked separately since they
# are dirs, not files.
for d in sepolicy/vendor vintf; do
    [[ -d "$DEV/$d" ]] && ok "$d/ (dir)" || err "BoardConfig.mk references missing dir: $d"
done
echo

# --- 3b. flash layout vs the partition sizes the build enforces ----------------
# Two numbers describe each partition and nothing makes them agree:
# BOARD_*_PARTITION_SIZE, which the build checks the image against, and the size
# column in flash/partitions.tsv, which is what the GPT actually gets. If the tsv
# is smaller, an image the build accepted does not fit the partition it is written
# to - and that is discovered by a board that does not boot, with no log.
#
# The other half is images that no longer exist. When BoardConfig.mk moved from
# boot header v4 to v2 the build stopped producing vendor_boot.img, and a
# vendor_boot row in the tsv would have had flash-emmc.sh write a partition from a
# file that was never built.
echo "[3b] flash layout vs BOARD_*_PARTITION_SIZE"
readonly TSV="$DEV/flash/partitions.tsv"
if [[ -f "$TSV" ]]; then
    bc_get() { sed 's/#.*//' "$DEV/BoardConfig.mk" | grep -oE "^[[:space:]]*$1[[:space:]]*:?=[[:space:]]*[0-9]+" \
               | grep -oE '[0-9]+$' | tail -1; }
    layout_bad=0
    while IFS=$'\t' read -r name mib img; do
        [[ -n "$name" && "$name" != \#* ]] || continue
        case "$name" in
            boot)        var=BOARD_BOOTIMAGE_PARTITION_SIZE ;;
            recovery)    var=BOARD_RECOVERYIMAGE_PARTITION_SIZE ;;
            vendor_boot) var=BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE ;;
            init_boot)   var=BOARD_INIT_BOOT_IMAGE_PARTITION_SIZE ;;
            dtbo)        var=BOARD_DTBOIMG_PARTITION_SIZE ;;
            super)       var=BOARD_SUPER_PARTITION_SIZE ;;
            *)           var= ;;
        esac
        [[ -n "$var" ]] || continue
        board=$(bc_get "$var")
        if [[ -z "$board" ]]; then
            if [[ "$img" != "-" ]]; then
                err "$name is in partitions.tsv with an image ($img) but BoardConfig.mk sets no"
                err "  $var, so the build produces no such image"
                layout_bad=$((layout_bad+1))
            fi
            continue
        fi
        tsv=$(( mib * 1024 * 1024 ))
        if (( tsv < board )); then
            err "$name: partitions.tsv gives ${mib}MiB but $var is $board bytes"
            err "  ($(( board / 1024 / 1024 ))MiB); an image the build accepts would not fit the partition"
            layout_bad=$((layout_bad+1))
        else
            ok "$name ${mib}MiB >= $var ($(( board / 1024 / 1024 ))MiB)"
        fi
    done < "$TSV"
    # super.img is the one image in the layout that the default build target does
    # not produce on its own. core/Makefile:7311 hangs it off droidcore-unbundled
    # only when BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT is true; otherwise droid builds
    # super_empty.img - metadata, no contents - and a build that flashes super.img
    # with dd finds nothing there. The first successful build ended that way.
    if grep -qE '^super\s' "$TSV" && grep -qE '[^-]\.img' <<< "$(grep -E '^super\s' "$TSV")"; then
        if sed 's/#.*//' "$DEV/BoardConfig.mk" \
           | grep -qE '^[[:space:]]*BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT[[:space:]]*:?=[[:space:]]*true'; then
            ok "super.img is in the layout and BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT is true"
        else
            err "partitions.tsv flashes super.img but BoardConfig.mk does not set"
            err "  BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT := true, so the default build target"
            err "  produces super_empty.img instead and the file will not exist"
            layout_bad=$((layout_bad+1))
        fi
    fi
    (( layout_bad )) || ok "every sized partition matches the size the build enforces"
else
    err "missing $TSV"
fi
echo

# --- 4. VINTF: fragments must NOT duplicate the device manifest ----------------
#
# This check used to assert the opposite - that every HAL in a fragment also
# appeared in vintf/manifest.xml - and that was backwards. Soong's
# vintf_fragments: installs each service's fragment into
# /vendor/etc/vintf/manifest/, and VINTF merges those into the device manifest at
# build time, so a HAL declared in both places is declared twice.
#
# This tree now has no fragments of its own: every HAL service on it comes from
# AOSP and carries its own. The check stays because the moment one is added, the
# question comes back - and it excludes vintf/manifest.xml itself, which would
# otherwise be read as a fragment duplicating every HAL in it.
echo "[4] VINTF: device fragments vs device manifest (duplicates are the error)"
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
done < <(find "$DEV" -name '*.xml' -path '*vintf*' ! -name 'manifest.xml' \
              ! -name 'compatibility_matrix.xml' 2>/dev/null | sort)
(( frag_total == 0 )) && ok "no device-side VINTF fragments (every HAL service is AOSP's)"
echo "  device manifest declares $(grep -c '<hal ' "$DEV/vintf/manifest.xml") HAL(s) directly"
echo

# --- 4b. VINTF: every manifest entry must be backed by an installed service ----
#
# A device manifest is a promise: this device provides this HAL at this version.
# Nothing in the build checks it. check_vintf asks whether the framework's
# requirements are met, not whether our own declarations are kept, and
# assemble_vintf just copies the entries through - so an entry for a service that
# was never installed reaches the image and surfaces as a client waiting on a HAL
# that never registers.
#
# This tree shipped one: HIDL android.hardware.drm@4.0 with clearkey instances,
# while device.mk installs android.hardware.drm-service.clearkey - the AIDL
# service, which carries its own fragment. The HIDL @4.0 clearkey service does not
# exist in AOSP 14 at all.
#
# The format matters as much as the name, which is why this does not just grep for
# the HAL name: a HIDL entry needs a package named <hal>@<version>..., an AIDL one
# needs <hal>-service... or <hal>-V<n>..., and those are different binaries.
echo "[4b] VINTF: manifest entries vs installed packages"
# Module names device.mk asks for, with continuations stripped so a name followed
# by " \" still matches.
pkgs=$(tr -d '\\' < "$DEV/device.mk" | grep -oE '^[[:space:]]*[A-Za-z0-9._@+-]+[[:space:]]*$' \
       | tr -d '[:blank:]' | sort -u)
unbacked=0
while IFS='|' read -r name fmt ver; do
    [[ -n "$name" ]] || continue
    case "$fmt" in
        hidl) want="${name}@${ver}" ;;
        *)    want="${name}-service|${name}-V" ;;
    esac
    if grep -qE "^(${want})" <<< "$pkgs"; then
        ok "$name ($fmt $ver) <- $(grep -E "^(${want})" <<< "$pkgs" | head -1)"
    else
        err "$name ($fmt $ver) is declared in vintf/manifest.xml but device.mk installs"
        err "  no package matching '${want}'; the manifest promises a service that is not there"
        unbacked=$((unbacked+1))
    fi
done < <(python3 - "$DEV/vintf/manifest.xml" <<'PYX'
import sys, xml.etree.ElementTree as ET
for hal in ET.parse(sys.argv[1]).getroot().findall("hal"):
    fmt = hal.get("format", "hidl")
    ver = hal.findtext("version") or (hal.findtext("fqname") or "").lstrip("@") or "-"
    print("%s|%s|%s" % (hal.findtext("name"), fmt, ver))
PYX
)
(( unbacked )) || ok "every manifest entry has a package behind it"
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
readonly FRAG="$DEV/kernel/edge1_mainline.config"
if [[ -f "$FRAG" ]]; then
    # Symbols that are mandatory for Android 14 to boot at all.
    # The first six are Android's; the rest are what Path B rests on - panfrost
    # for GLES, Rockchip DRM for KMS, brcmfmac for Wi-Fi, rkvdec for decode. A
    # module rather than a built-in would be just as fatal here: this layout has
    # no vendor_dlkm and loads nothing in first-stage init.
    for must in CONFIG_ANDROID_BINDERFS CONFIG_BPF_SYSCALL CONFIG_PSI \
                CONFIG_FS_ENCRYPTION CONFIG_DM_VERITY CONFIG_USERFAULTFD \
                CONFIG_DRM_PANFROST CONFIG_DRM_ROCKCHIP CONFIG_ROCKCHIP_DW_HDMI \
                CONFIG_BRCMFMAC CONFIG_BRCMFMAC_SDIO CONFIG_VIDEO_ROCKCHIP_VDEC \
                CONFIG_SND_SIMPLE_CARD CONFIG_DRM_DW_HDMI_I2S_AUDIO; do
        grep -qE "^${must}=y" "$FRAG" && ok "$must=y" || err "$FRAG is missing ${must}=y"
    done
    # "CONFIG_X=n" is not how Kconfig disables a symbol. merge_config.sh reports
    # the line as redefining the value and then keeps the base setting, so the
    # fragment silently has no effect. The correct form is
    # "# CONFIG_X is not set". Three of these were shipped before this check.
    while read -r bad; do
        err "$FRAG uses '$bad'; Kconfig needs '# ${bad%=n} is not set'"
    done < <(grep -oE '^CONFIG_[A-Z0-9_]+=n$' "$FRAG" || true)

    # Comments must not shadow a symbol the fragment sets, and must not look like a
    # directive.
    #
    # merge_config.sh collects what to merge with two sed patterns:
    #
    #   s/^\(CONFIG_[a-zA-Z0-9_]*\)=.*/\1/p
    #   s/^# \(CONFIG_[a-zA-Z0-9_]*\) is not set$/\1/p
    #
    # and then reads the value back with "grep -w $CFG $MERGE_FILE". So a comment
    # that mentions a symbol the fragment also sets makes that grep return two
    # lines, and the override warning prints the comment as the new value:
    #
    #   New value: # ... "NOT SET: CONFIG_DWMAC_ROCKCHIP=y". CONFIG_DWMAC_ROCKCHIP=y
    #
    # The merge itself is unaffected - it appends the whole fragment and runs
    # olddefconfig - but the one report that says whether a symbol took becomes
    # unreadable, and without -m the same artifact makes merge_config claim the
    # value is missing from the final .config. Write the bare name in prose.
    #
    # The second pattern is the sharper edge: "# CONFIG_X is deliberately absent"
    # is inert, but it is four words away from being read as a directive to turn X
    # off. Only the exact "is not set" form may start a comment with CONFIG_.
    set_syms=$(grep -oE '^CONFIG_[A-Z0-9_]+' "$FRAG" | sed 's/^CONFIG_//' | sort -u)
    shadowed=0
    while read -r sym; do
        [[ -n "$sym" ]] || continue
        while IFS= read -r n; do
            err "$FRAG:$n mentions CONFIG_${sym} in a comment, and the fragment sets it;"
            err "  merge_config.sh's value lookup is a grep, so its report becomes unreadable"
            shadowed=$((shadowed+1))
        done < <(grep -nE "^[[:space:]]*#.*CONFIG_${sym}([^A-Z0-9_]|$)" "$FRAG" | cut -d: -f1)
    done <<< "$set_syms"
    while IFS= read -r line; do
        n="${line%%:*}"
        err "$FRAG:$n starts a comment with '# CONFIG_' but is not the exact"
        err "  '# CONFIG_X is not set' form; that is one edit away from silently disabling it"
        shadowed=$((shadowed+1))
    done < <(grep -nE '^# CONFIG_[A-Za-z0-9_]+' "$FRAG" \
             | grep -vE '^[0-9]+:# CONFIG_[A-Za-z0-9_]+ is not set$' || true)
    (( shadowed )) || ok "no comment shadows a symbol the fragment sets"

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
    # Types this tree knowingly takes from AOSP's own policy - borrowed, never
    # declared here. Listed rather than matched by pattern: if a release renames
    # one, this is where it surfaces.
    #
    # This list is a claim, not evidence, and it has been wrong in both directions.
    # sysfs_devfreq and vendor_firmware_file were on it and AOSP 14 defines
    # neither, so both are declared in this tree now and both came off the list.
    # sysfs_gpu was the other direction: it was declared here, AOSP declares it
    # too, and checkpolicy rejected the second declaration six minutes into a
    # build. The module probe resolves this list against the synced
    # system/sepolicy and prints every type this device declares with whether AOSP
    # already has it - that is the authoritative answer, and it gates the run.
    aosp_types="gpu_device graphics_device hal_bluetooth_default_exec
                vendor_kernel_modules vendor_file
                vendor_configs_file sysfs_type sysfs_gpu sysfs_leds
                sysfs_thermal sysfs_devices_system_cpu video_device"
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

    # The other direction. A type declared here that AOSP also declares is a
    # duplicate declaration, which checkpolicy treats as fatal - and it fails on
    # the first one only, so the build reveals them one per run.
    dupe_types=0
    while read -r t; do
        [[ -n "$t" ]] || continue
        if grep -qw "$t" <<< "$aosp_types"; then
            err "$t is declared in $SEDIR and is an AOSP type; checkpolicy calls that"
            err "  a duplicate declaration. Drop the local 'type' line and keep labelling with it."
            dupe_types=$((dupe_types+1))
        fi
    done <<< "$declared"
    (( dupe_types )) || ok "no locally declared type collides with a known AOSP type"

    # Specifications AOSP's own file_contexts already has. The platform file and
    # ours are concatenated and compiled as one, and checkfc rejects the same
    # specification twice:
    #
    #   file_contexts.concat.tmp: Multiple same specifications for /dev/video[0-9]*.
    #   Error: could not load context file from ...
    #
    # "Same specification" is the identical regex text, not an overlapping path:
    # /dev/dri/card0 next to AOSP's /dev/dri/card[0-9]* is fine and the more
    # specific one wins. So this list holds exact spellings, and like aosp_types it
    # is a claim - the module probe resolves ours against the synced
    # system/sepolicy and gates the run on it.
    plat_specs="/dev/video[0-9]*"
    dupe_specs=0
    while IFS= read -r spec; do
        [[ -n "$spec" ]] || continue
        if grep -qxF "$spec" <<< "$plat_specs"; then
            err "$SEDIR/file_contexts declares '$spec', which AOSP's file_contexts also"
            err "  declares verbatim; checkfc refuses to load the concatenated file"
            dupe_specs=$((dupe_specs+1))
        fi
    done < <(sed 's/#.*//' "$SEDIR/file_contexts" 2>/dev/null | awk 'NF>=2 {print $1}' | sort -u)
    (( dupe_specs )) || ok "no file_contexts spec collides with a known AOSP one"

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

# --- 9b. dangling line continuations ------------------------------------------
# A make line ending in a backslash swallows the next line. When editing removed
# the items from a list but left the "VAR += \" behind, the following comment
# became the value - which make accepts silently and which no other check here
# would notice.
echo "[9b] dangling line continuations"
dangling=0
for mk in "$DEV"/*.mk; do
    while IFS= read -r n; do
        err "$(basename "$mk"):$n ends in a backslash and the next line is a comment or blank"
        dangling=$((dangling+1))
    done < <(awk '/\\$/ { c=NR; if ((getline nxt) > 0 && nxt ~ /^[[:space:]]*(#|$)/) print c }' "$mk")
done
(( dangling )) || ok "no list continues into a comment or a blank line"
echo

# --- 9c. audio policy includes ------------------------------------------------
# Every xi:include in the audio policy has to resolve on the device, or the parse
# fails and takes the whole policy with it - not just the section that could not be
# found. So each href must be either a file this tree installs or one of the AOSP
# modules device.mk asks for, under the name that module installs.
#
# This is not hypothetical: bluetooth_audio_policy_configuration.xml was included
# under that name while AOSP's file is bluetooth_audio_policy_configuration_7_0.xml,
# and it only resolved because a PRODUCT_COPY_FILES line renamed it on the way in.
# Installing the module instead would have kept the suffix and broken the include.
echo "[9c] audio policy xi:include targets"
readonly APC="$DEV/audio/audio_policy_configuration.xml"
if [[ -f "$APC" ]]; then
    # Names AOSP modules install, as filenames. Extend this when adding a module.
    aosp_installed="r_submix_audio_policy_configuration.xml
usb_audio_policy_configuration.xml
default_volume_tables.xml
audio_policy_engine_configuration.xml"
    bad_inc=0
    while read -r href; do
        [[ -n "$href" ]] || continue
        if [[ -f "$DEV/audio/$href" ]]; then
            ok "$href (ours)"
        elif grep -qxF "$href" <<< "$aosp_installed"; then
            # And the module that provides it must actually be requested.
            mod="${href%.xml}"
            # Backslashes stripped first: these are continuation lines in a
            # PRODUCT_PACKAGES list, so the module name is followed by " \\" and a
            # pattern anchored at end-of-line never matches it.
            if tr -d '\\' < "$DEV/device.mk" | grep -qxE "[[:space:]]*$mod[[:space:]]*"; then
                ok "$href (AOSP module $mod, installed)"
            else
                err "$href is an AOSP config but device.mk does not install $mod"
                bad_inc=$((bad_inc+1))
            fi
        else
            err "$href resolves to nothing this tree installs; the policy parse will fail"
            bad_inc=$((bad_inc+1))
        fi
    done < <(grep -oE 'xi:include href="[^"]+"' "$APC" | sed -E 's/.*href="([^"]+)"/\1/')
fi
echo

# --- 9d. vendor property namespace --------------------------------------------
# A vendor partition may only own properties under a fixed set of prefixes.
# system/sepolicy's check_prop_prefix enforces it on the merged vendor
# property_contexts, and VTS enforces the same list on device
# (test/vts-testcase/security/system_property/vts_treble_sys_prop_test.py).
#
# The check runs at 71% of a full build. A "sys.hwc." line here cost six hours to
# find out that Rockchip's hwcomposer properties are not ours to label - so the
# same rule is applied here, where it costs a second.
echo "[9d] vendor property namespace"
readonly PCTX="$DEV/sepolicy/vendor/property_contexts"
# The list check_prop_prefix prints when it rejects a file. Order matters only for
# readability; every entry is a literal prefix.
readonly ALLOWED_PREFIXES=(
    'ctl.odm.' 'ctl.vendor.' 'ctl.start$odm.' 'ctl.start$vendor.'
    'ctl.stop$odm.' 'ctl.stop$vendor.' 'init.svc.odm.' 'init.svc.vendor.'
    'ro.boot.' 'ro.hardware.' 'ro.odm.' 'ro.vendor.' 'odm.'
    'persist.odm.' 'persist.vendor.' 'vendor.' 'persist.camera.'
)
# The file is absent as of now, and its absence is the correct state - see
# sepolicy/vendor/README.md. The check stays because the next vendor property that
# does need a label has to satisfy this rule, and because the two rules it encodes
# are not obvious: an allowed prefix is necessary and not sufficient. The second
# half - the name must not be one system/sepolicy already matches exactly - needs
# the synced tree, so it lives in the module probe and gates the run there.
if [[ -f "$PCTX" ]]; then
    while read -r name _rest; do
        [[ -n "$name" ]] || continue
        [[ "$name" == \#* ]] && continue
        allowed=0
        for pre in "${ALLOWED_PREFIXES[@]}"; do
            [[ "$name" == "$pre"* ]] && { allowed=1; break; }
        done
        if (( allowed )); then
            ok "$name"
        else
            err "$name is not a prefix a vendor partition may own; check_prop_prefix will fail the build"
        fi
    done < "$PCTX"
    # Every type used here has to be declared, and every declared type used - an
    # unused vendor_*_prop is dead policy, and an undeclared one fails the compile.
    used=$(grep -v '^[[:space:]]*#' "$PCTX" | grep -oE 'u:object_r:[a-z0-9_]+:s0' \
           | sed -E 's/u:object_r:([a-z0-9_]+):s0/\1/' | sort -u)
    declared=$(grep -hoE '^[[:space:]]*vendor_(internal|restricted|public)_prop\([a-z0-9_]+\)' \
               "$DEV/sepolicy/vendor/property.te" 2>/dev/null \
               | sed -E 's/.*\(([a-z0-9_]+)\)/\1/' | sort -u)
    for t in $used; do
        grep -qxF "$t" <<< "$declared" || err "$t is labelled in property_contexts but declared in no property.te"
    done
    for t in $declared; do
        if grep -qxF "$t" <<< "$used"; then
            ok "$t declared and used"
        else
            wrn "$t is declared in property.te but labels nothing"
        fi
    done
else
    ok "no vendor property labels (see sepolicy/vendor/README.md), nothing to check"
fi
echo

# --- 9e. properties the build already emits -----------------------------------
# core/main.mk derives a set of properties from board and product variables and
# appends them to ADDITIONAL_VENDOR_PROPERTIES / ADDITIONAL_SYSTEM_PROPERTIES.
# Setting one of those by hand as well produces two assignments in the same
# build.prop, and post_process_props.py stops the build unless the two values are
# identical (tools/post_process_props.py:112-117):
#
#   error: found duplicate sysprop assignments:
#   ro.product.board=
#   ro.product.board=rk3399
#
# That empty one is what the build emitted, from an unset
# TARGET_BOOTLOADER_BOARD_NAME. The identical-values escape is what makes this
# worth a check rather than a comment: ro.board.platform was also set twice and
# passed, so it sat there as an error waiting for the two to diverge.
#
# The variable to set instead is in the right-hand column. Line numbers are from
# android-14.0.0_r75.
echo "[9e] properties core/main.mk already emits"
# property|the variable that feeds it|where
readonly DERIVED_PROPS=(
    'ro.product.board|TARGET_BOOTLOADER_BOARD_NAME|main.mk:335'
    'ro.board.platform|TARGET_BOARD_PLATFORM|main.mk:336'
    'ro.hwui.use_vulkan|TARGET_USES_VULKAN|main.mk:337'
    'ro.sf.lcd_density|TARGET_SCREEN_DENSITY|main.mk:341'
    'ro.product.first_api_level|PRODUCT_SHIPPING_API_LEVEL|main.mk:284'
    'ro.vendor.api_level|PRODUCT_SHIPPING_VENDOR_API_LEVEL|main.mk:289'
    'ro.board.first_api_level|BOARD_SHIPPING_API_LEVEL|main.mk:304'
    'ro.board.api_level|BOARD_API_LEVEL|main.mk:311'
    'ro.boot.dynamic_partitions|PRODUCT_USE_DYNAMIC_PARTITIONS|main.mk:274'
    'ro.build.ab_update|AB_OTA_UPDATER|main.mk:346'
    'ro.vendor.build.security_patch|VENDOR_SECURITY_PATCH|main.mk:334'
    'ro.product.cpu.pagesize.max|TARGET_MAX_PAGE_SIZE_SUPPORTED|main.mk:370'
    'ro.minui.default_rotation|TARGET_RECOVERY_DEFAULT_ROTATION|main.mk:261'
    'ro.minui.pixel_format|TARGET_RECOVERY_PIXEL_FORMAT|main.mk:269'
)
derived=0
# Comments are stripped before matching: these property names are discussed in the
# comments here and in the makefiles on purpose, and a comment is not a setting.
for mkfile in "$DEV"/*.mk; do
    for entry in "${DERIVED_PROPS[@]}"; do
        IFS='|' read -r prop var where <<< "$entry"
        while IFS= read -r n; do
            err "$(basename "$mkfile"):$n sets ${prop} by hand; the build emits it from"
            err "  ${var} (${where}). Set that variable instead."
            derived=$((derived+1))
        done < <(sed 's/#.*//' "$mkfile" | grep -nE "(^|[[:space:]])${prop}=" | cut -d: -f1)
    done
done
(( derived )) || ok "no product makefile sets a property core/main.mk derives"
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
