#!/usr/bin/env bash
#
# Put the apps that are installed on first boot into the AOSP tree.
#
#   usage: fetch-apps.sh <tree-dir>
#
# Called by place-device.sh, like fetch-fdroid.sh. Two sources:
#
#   1. The apks folder - every *.apk in it, taken as it is (the owner's own
#      choice): EDGE1_APKS_DIR, ~/android_khadas/apks, or <drive>:\android_khadas\apks
#      on Windows (/mnt/<drive>/android_khadas/apks).
#   2. build/apps/apps.tsv - apps downloaded from F-Droid, and from nowhere else.
#      F-Droid's index (index-v1.jar) must carry a valid signature by F-Droid's key
#      and each APK must match the SHA-256 that index gives for it. Downloads are
#      cached in ~/.cache/edge1/apps; EDGE1_APPS_REFRESH=1 fetches current releases.
#
# Both end up under <tree>/vendor/edge1/apps/:
#
#   <name>.apk        each app, byte for byte
#   preinstall.conf   the launcher to make default, and which files came from F-Droid
#   Android.bp        a prebuilt_etc per file, into /system_ext/etc/edge1-preinstall/
#   apps.mk           PRODUCT_PACKAGES for those modules; device.mk pulls it in with
#                     inherit-product-if-exists
#
# They go onto the image as files, not as system apps. Edge1 Tools installs them
# with PackageInstaller on first boot, so they end up as ordinary apps: updatable,
# removable, with their native libraries extracted the usual way. (As prebuilt
# system apps, a third-party APK with compressed native libraries cannot work: the
# build would have to rewrite it, breaking its v2 signature, and Android does not
# extract libraries for an unupdated system app.)
#
# When the folder and F-Droid both supply the same app, the device installs the
# folder's copy: Edge1 Tools compares package names, which it can read and this
# script cannot.
#
# A failure costs that app, never the build: it is reported and left out.
set -euo pipefail

readonly TREE="${1:?usage: fetch-apps.sh <tree-dir>}"
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIST="$HERE/apps/apps.tsv"
readonly APKCERT="$HERE/apk-cert.py"
readonly CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/edge1/apps"
readonly DST="$TREE/vendor/edge1/apps"
readonly FDROID_REPO="${EDGE1_FDROID_REPO:-https://f-droid.org/repo}"
# F-Droid's signing key: the one its client APK is signed with (fetch-fdroid.sh)
# and the one its repository index is signed with. Overridable for a test against
# a local mirror, like the repository URL.
readonly FDROID_KEY="${EDGE1_FDROID_KEY:-43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab}"
readonly REFRESH="${EDGE1_APPS_REFRESH:-0}"

say()  { echo "fetch-apps: $*"; }
warn() { echo "fetch-apps: $*" >&2; }

mkdir -p "$CACHE"

# A zip with an AndroidManifest.xml in it. Not "unzip -l | grep -q": under pipefail
# grep's early exit kills unzip with SIGPIPE on any APK of a few thousand entries,
# and the pipeline then reports failure for a perfectly good file - which is how
# every APK, downloaded or dropped in, was refused the first time this ran.
valid_apk() {
    python3 - "$1" <<'PY'
import sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        z.getinfo("AndroidManifest.xml")
except Exception:
    sys.exit(1)
PY
}
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

# dl <url> <file>: atomically, or not at all.
dl() {
    rm -f "$2.part"
    if curl -fsSL --retry 3 --connect-timeout 20 -o "$2.part" "$1"; then
        mv -f "$2.part" "$2"
    else
        rm -f "$2.part"; return 1
    fi
}

# ---------------------------------------------------------------------------
# F-Droid: one verified index per run.
# ---------------------------------------------------------------------------
FDROID_JSON=""
fdroid_index() {
    [[ -n "$FDROID_JSON" ]] && return 0
    local jar="$CACHE/fdroid-index-v1.jar" json="$CACHE/fdroid-index-v1.json" fp
    # A day-old index is fine for picking a release; a refresh run always re-reads.
    if [[ "$REFRESH" == 1 || ! -s "$json" ]] || [[ -n "$(find "$json" -mmin +1440 2>/dev/null)" ]]; then
        if dl "$FDROID_REPO/index-v1.jar" "$jar.new"; then
            if fp="$(python3 "$APKCERT" verify-jar "$jar.new" index-v1.json)" \
               && [[ "$fp" == "$FDROID_KEY" ]]; then
                mv -f "$jar.new" "$jar"
                unzip -p "$jar" index-v1.json > "$json.new" && mv -f "$json.new" "$json"
            else
                warn "F-Droid's index did not verify (signer ${fp:-none}); not using it"
                rm -f "$jar.new"
            fi
        else
            warn "could not download F-Droid's index"
        fi
    fi
    [[ -s "$json" ]] || return 1
    FDROID_JSON="$json"
}

# fdroid_pick <package>: "apkName sha256 versionName" of the release to install -
# F-Droid's suggested version, in the arm64-v8a build where it is split per ABI.
fdroid_pick() {
    python3 - "$FDROID_JSON" "$1" <<'PY'
import json, sys
idx = json.load(open(sys.argv[1]))
pkg = sys.argv[2]
apks = idx.get("packages", {}).get(pkg) or []
app = next((a for a in idx.get("apps", []) if a.get("packageName") == pkg), {})
def abi_rank(a):
    nc = a.get("nativecode") or []
    if not nc: return 2                      # no native code: runs anywhere
    if "arm64-v8a" in nc: return 3
    if "armeabi-v7a" in nc: return 1
    return -1                                # x86 only
ok = [a for a in apks if abi_rank(a) >= 0 and int(a.get("minSdkVersion", 1)) <= 34
      and a.get("hashType", "sha256") == "sha256"]
if not ok:
    sys.exit(1)
sugg = str(app.get("suggestedVersionCode", ""))
name = next((a.get("versionName") for a in ok if str(a.get("versionCode")) == sugg), None)
pool = [a for a in ok if a.get("versionName") == name] if name else ok
best = max(pool, key=lambda a: (abi_rank(a), int(a.get("versionCode", 0))))
print(best["apkName"], best["hash"], best.get("versionName", "?"))
PY
}

fetch_fdroid() {   # <package> <out>
    fdroid_index || return 1
    local pick apk hash ver
    pick="$(fdroid_pick "$1")" || { warn "$1: not in F-Droid's index"; return 1; }
    read -r apk hash ver <<< "$pick"
    dl "$FDROID_REPO/$apk" "$2.new" || { warn "$1: download of $apk failed"; return 1; }
    if [[ "$(sha256sum "$2.new" | cut -d' ' -f1)" != "$hash" ]]; then
        warn "$1: $apk does not match the SHA-256 in F-Droid's index"
        rm -f "$2.new"; return 1
    fi
    if ! valid_apk "$2.new"; then
        warn "$1: $apk is not an APK"
        rm -f "$2.new"; return 1
    fi
    mv -f "$2.new" "$2"
    echo "F-Droid $1 $ver" > "$CACHE/$(basename "$2" .apk).from"
}

# ---------------------------------------------------------------------------
# The folder first, then the F-Droid list.
# ---------------------------------------------------------------------------
declare -A PICK=() FROM=() FETCHED=()
declare -a ORDER=()

add() {   # <name> <file> <from>
    [[ -n "${PICK[$1]:-}" ]] || ORDER+=("$1")
    PICK[$1]="$2"; FROM[$1]="$3"
}

dropdirs=()
[[ -n "${EDGE1_APKS_DIR:-}" ]] && dropdirs+=("$EDGE1_APKS_DIR")
dropdirs+=("$HOME/android_khadas/apks")
for d in /mnt/?/android_khadas/apks; do [[ -d "$d" ]] && dropdirs+=("$d"); done
for d in "${dropdirs[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*.apk "$d"/*.APK; do
        [[ -f "$f" ]] || continue
        if ! valid_apk "$f"; then
            warn "$f is not an APK (no AndroidManifest.xml in it); skipped"; continue
        fi
        add "$(safe_name "$(basename "${f%.*}")")" "$f" "$f"
    done
done

while IFS=$'\t' read -r name pkg; do
    case "$name" in ''|\#*) continue ;; esac
    name="$(safe_name "$name")"
    # The folder supplies it already: a file named like the entry, or starting
    # with its name ("VLC-Android-3.6.5-arm64-v8a.apk" for VLC).
    key="$(printf '%s' "$name" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')"
    have=""
    for n in "${ORDER[@]}"; do
        k="$(printf '%s' "$n" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')"
        [[ "$k" == "$key"* ]] && { have="$n"; break; }
    done
    if [[ -n "$have" ]]; then
        say "$name: the folder has it ($have.apk); not downloading"
        continue
    fi
    if [[ "$REFRESH" == 1 || ! -s "$CACHE/$name.apk" ]] || ! valid_apk "$CACHE/$name.apk"; then
        say "$name: fetching $pkg from F-Droid"
        if ! fetch_fdroid "$pkg" "$CACHE/$name.apk"; then
            if [[ -s "$CACHE/$name.apk" ]] && valid_apk "$CACHE/$name.apk"; then
                warn "$name: download failed; using the cached copy"
            else
                warn "$name: download failed; the image is built without it"
                continue
            fi
        fi
    fi
    add "$name" "$CACHE/$name.apk" "$(cat "$CACHE/$name.from" 2>/dev/null || echo "F-Droid $pkg")"
    FETCHED[$name]=1
done < "$LIST"

# ---------------------------------------------------------------------------
# Write vendor/edge1/apps, touching only what changed.
# ---------------------------------------------------------------------------
if (( ${#ORDER[@]} == 0 )); then
    warn "no apps to preinstall"
    rm -rf "$DST"
    exit 0
fi
mkdir -p "$DST"

write_if_changed() {   # $1 file; content on stdin
    local tmp; tmp="$(mktemp)"; cat > "$tmp"
    if cmp -s "$tmp" "$1"; then rm -f "$tmp"; else mv -f "$tmp" "$1"; fi
}

# Soong module names allow fewer characters than file names do, so two files can
# map to one module ("a-b.apk", "a_b.apk"); a repeat gets a number.
declare -A MOD=() SEEN=()
for name in "${ORDER[@]}"; do
    m="edge1_preinstall_$(printf '%s' "$name" | tr -c 'A-Za-z0-9_' '_')"
    base="$m"; i=2
    while [[ -n "${SEEN[$m]:-}" ]]; do m="${base}_$i"; i=$((i + 1)); done
    SEEN[$m]=1; MOD[$name]="$m"
done

keep=" "
total=0
for name in "${ORDER[@]}"; do
    cmp -s "${PICK[$name]}" "$DST/$name.apk" || cp -f "${PICK[$name]}" "$DST/$name.apk"
    keep+="$name.apk "
    bytes=$(stat -c %s "$DST/$name.apk"); total=$(( total + bytes ))
    say "$(printf '%-28s %6s  %s' "$name" "$(numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes")" "${FROM[$name]}")"
done
for f in "$DST"/*.apk; do
    [[ -f "$f" && "$keep" != *" $(basename "$f") "* ]] && rm -f "$f"
done

{
    echo "# Generated by build/fetch-apps.sh in the edge1 manifest repo. Do not edit."
    for name in "${ORDER[@]}"; do
        [[ -n "${FETCHED[$name]:-}" ]] && echo "fetched=$name.apk"
    done
    true
} | write_if_changed "$DST/preinstall.conf"

{
    echo "// Generated by build/fetch-apps.sh in the edge1 manifest repo. Do not edit."
    for name in "${ORDER[@]}"; do
        cat <<EOF

prebuilt_etc {
    name: "${MOD[$name]}",
    src: "$name.apk",
    filename: "$name.apk",
    sub_dir: "edge1-preinstall",
    system_ext_specific: true,
}
EOF
    done
    cat <<'EOF'

prebuilt_etc {
    name: "edge1_preinstall_conf",
    src: "preinstall.conf",
    sub_dir: "edge1-preinstall",
    system_ext_specific: true,
}
EOF
} | write_if_changed "$DST/Android.bp"

{
    echo "# Generated by build/fetch-apps.sh in the edge1 manifest repo. Do not edit."
    echo "PRODUCT_PACKAGES += \\"
    for name in "${ORDER[@]}"; do
        echo "    ${MOD[$name]} \\"
    done
    echo "    edge1_preinstall_conf"
} | write_if_changed "$DST/apps.mk"

say "${#ORDER[@]} app(s), $(numfmt --to=iec "$total" 2>/dev/null || echo "$total") -> vendor/edge1/apps"
