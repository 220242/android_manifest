#!/usr/bin/env bash
# Compiles this device's vendor SELinux policy together with AOSP 14's platform
# policy, the way the build's monolithic "sepolicy.conf" step does, and runs
# checkpolicy over it: unknown types and attributes, syntax, and every neverallow
# in the platform policy. It does not replace the build (no treble split, no
# mapping files, no file_contexts compile), but it catches in seconds what would
# otherwise stop a build hours in.
#
#   usage: build/dev/check-sepolicy.sh <system/sepolicy> [userdebug|user]
#
# <system/sepolicy> is AOSP 14's (LineageOS 21's android_system_sepolicy is the
# same policy). Needs m4 and checkpolicy (apt-get install checkpolicy).
set -euo pipefail
SEP="$(cd "${1:?usage: $0 <system/sepolicy> [userdebug|user]}" && pwd)"
VARIANT="${2:-userdebug}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
DEV="$HERE/device/khadas/edge/sepolicy/vendor"
command -v checkpolicy >/dev/null || { echo "checkpolicy missing (apt-get install checkpolicy)" >&2; exit 2; }

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# $1: name of the pass; the rest: the policy directories, in order.
compile() {
    local pass="$1"; shift
    local dirs=("$@") files=() flags=() name d f
    for name in security_classes initial_sids access_vectors global_macros neverallow_macros \
                mls_macros mls_decl mls policy_capabilities te_macros attributes ioctl_defines \
                ioctl_macros '*.te' roles_decl roles users initial_sid_contexts fs_use \
                genfs_contexts port_contexts; do
        for d in "${dirs[@]}"; do
            for f in $d/$name; do [[ -f "$f" ]] && files+=("$f"); done
        done
        # The release-flag macros (is_flag_enabled) come right after te_macros.
        [[ "$name" == te_macros && -f "$SEP/flagging/te_macros" ]] && files+=("$SEP/flagging/te_macros")
    done
    # Every release flag the policy tests, off: the conservative side for a build
    # that does not set them.
    for f in $(grep -rhoE 'is_flag_(en|dis)abled\(RELEASE_[A-Z0-9_]+' "${dirs[@]}" \
               | sed 's/.*(//' | sort -u); do
        flags+=(-D "target_flag_$f=false")
    done
    m4 --fatal-warnings -D mls_num_sens=1 -D mls_num_cats=1024 \
       -D target_build_variant="$VARIANT" -D target_with_dexpreopt=true \
       -D target_arch=arm64 -D target_with_asan=false -D target_with_native_coverage=false \
       -D target_full_treble=true -D target_compatible_property=true \
       -D target_treble_sysprop_neverallow=true -D target_exclude_build_test=false \
       -D target_requires_insecure_execmem_for_swiftshader=false \
       -D target_enforce_debugfs_restriction=true -D target_recovery=false \
       "${flags[@]}" -s "${files[@]}" > "$out/$pass.conf"
    # The vendor view is checked for names only (-C writes CIL without expanding,
    # so no neverallow runs): public neverallows over a policy missing its private
    # half fail by the thousand, all of them about grants that half makes.
    local mode=()
    [[ "$pass" == vendor-view ]] && mode=(-C)
    if ! checkpolicy -M "${mode[@]}" -c 30 -o "$out/$pass.out" "$out/$pass.conf" > "$out/$pass.log" 2>&1; then
        echo "sepolicy ($VARIANT, $pass): FAILED" >&2
        tail -n 8 "$out/$pass.log" >&2
        return 1
    fi
    echo "sepolicy ($VARIANT, $pass): compiles"
}

# Labels in the device's context files must name types the vendor policy can see.
bad=0
for t in $(cat "$DEV"/file_contexts "$DEV"/genfs_contexts "$DEV"/service_contexts 2>/dev/null \
           | grep -v '^\s*#' | grep -o 'u:object_r:[a-z_0-9]*' | cut -d: -f3 | sort -u); do
    if ! grep -qE "^type $t[,;]" "$SEP"/public/*.te "$SEP"/vendor/*.te "$DEV"/*.te; then
        echo "label type not defined for vendor policy: $t" >&2; bad=1
    fi
done
# And no file_contexts specification AOSP already has verbatim: the two files are
# concatenated and checkfc refuses a specification twice.
for spec in $(sed 's/#.*//' "$DEV/file_contexts" | awk 'NF>=2 {print $1}'); do
    if awk '{print $1}' "$SEP/private/file_contexts" "$SEP/vendor/file_contexts" | grep -qxF -- "$spec"; then
        echo "file_contexts: $spec is already in AOSP's file_contexts" >&2; bad=1
    fi
done
(( bad == 0 )) || exit 1

compile whole "$SEP/public" "$SEP/private" "$SEP/vendor" "$DEV"
compile vendor-view "$SEP/reqd_mask" "$SEP/public" "$SEP/vendor" "$DEV"
echo "sepolicy ($VARIANT): neverallows hold, no private type used by vendor policy"
