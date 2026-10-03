#!/usr/bin/env bash
#
# Put the apps that are installed on first boot into the AOSP tree.
#
#   usage: fetch-apps.sh <tree-dir>
#
# Called by place-device.sh, like fetch-fdroid.sh. The list is build/apps/apps.tsv
# (what each column means is written there). For every entry this script finds an
# APK - from the cache, or by downloading it - and writes, under
# <tree>/vendor/edge1/apps/:
#
#   <name>.apk        the app, byte for byte as published
#   preinstall.conf   which of them becomes the default launcher
#   Android.bp        a prebuilt_etc per file, into /system_ext/etc/edge1-preinstall/
#   apps.mk           PRODUCT_PACKAGES for those modules; device.mk pulls it in with
#                     inherit-product-if-exists
#
# They go onto the image as files, not as system apps. Edge1 Tools installs them
# with PackageInstaller on first boot, so they end up as ordinary apps: updatable,
# removable, with their native libraries extracted the usual way. As prebuilt
# system apps, a third-party APK with compressed native libraries cannot work:
# the build would have to rewrite it (and break its v2 signature), and Android does
# not extract libraries for an unupdated system app.
#
# Downloads are cached in ~/.cache/edge1/apps and reused; EDGE1_APPS_REFRESH=1
# fetches the current release of each again. Integrity:
#   F-Droid  the index (index-v1.jar) must carry a valid signature by F-Droid's
#            key, and each APK must match the SHA-256 that index gives for it.
#   others   HTTPS from the project's own GitHub release; the signing certificate
#            of the first download is pinned in the cache (<name>.cert), and a later
#            one signed by a different key is refused, keeping the cached copy.
#
# Plus anything dropped into an apks/ folder: EDGE1_APKS_DIR, ~/android_khadas/apks,
# or <drive>:\android_khadas\apks on Windows (/mnt/<drive>/android_khadas/apks).
# A dropped file is taken as it is - it is the owner's own choice - and one named
# like a list entry (Projectivy.apk, say) replaces that entry.
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
# and the one its repository index is signed with.
# (Both can be pointed elsewhere for a test against a local mirror.)
readonly FDROID_KEY="${EDGE1_FDROID_KEY:-43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab}"
readonly REFRESH="${EDGE1_APPS_REFRESH:-0}"

say()  { echo "fetch-apps: $*"; }
warn() { echo "fetch-apps: $*" >&2; }

mkdir -p "$CACHE"

valid_apk() { unzip -l "$1" 2>/dev/null | grep -qE '[[:space:]]AndroidManifest\.xml$'; }
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
    mv -f "$2.new" "$2"
    echo "F-Droid $1 $ver"
}

# github_asset <owner/repo> <regex>: download URL of the best-matching asset of the
# latest release.
github_asset() {
    local rel
    rel="$(curl -fsSL --retry 2 --connect-timeout 20 \
               -H 'Accept: application/vnd.github+json' \
               "https://api.github.com/repos/$1/releases/latest")" || return 1
    printf '%s' "$rel" | python3 -c '
import json, re, sys
rel = json.load(sys.stdin)
pat = re.compile(sys.argv[1], re.I)
def rank(n):
    n = n.lower()
    return 3 if ("arm64" in n or "aarch64" in n) else 2 if "universal" in n \
        else 0 if re.search(r"x86|armeabi|armv7", n) else 1
assets = [a for a in rel.get("assets", []) if pat.search(a["name"])]
if not assets:
    sys.exit(1)
best = max(assets, key=lambda a: rank(a["name"]))
print(best["browser_download_url"], rel.get("tag_name", "?"))
' "$2"
}

# pin_ok <name> <apk>: the TOFU certificate check for non-F-Droid sources.
pin_ok() {
    local fp pin="$CACHE/$1.cert"
    fp="$(python3 "$APKCERT" cert "$2")" || { warn "$1: no readable signature"; return 1; }
    if [[ -s "$pin" && "$(cat "$pin")" != "$fp" ]]; then
        warn "$1: signed by $fp, but $(cat "$pin") was pinned on the first download;"
        warn "  refusing it. Delete $pin if the developer really changed keys."
        return 1
    fi
    [[ -s "$pin" ]] || echo "$fp" > "$pin"
}

fetch_one() {   # <name> <sources>; fills $CACHE/<name>.apk
    local name="$1" out="$CACHE/$1.apk" src kind arg url tag info
    IFS='|' read -r -a srcs <<< "$2"
    for src in "${srcs[@]}"; do
        kind="${src%%:*}"; arg="${src#*:}"
        case "$kind" in
            fdroid)
                info="$(fetch_fdroid "$arg" "$out")" || continue ;;
            github)
                read -r url tag < <(github_asset "${arg%%:*}" "${arg#*:}") \
                    || { warn "$name: no matching asset in ${arg%%:*}'s latest release"; continue; }
                dl "$url" "$out.new" || { warn "$name: download failed: $url"; continue; }
                valid_apk "$out.new" && pin_ok "$name" "$out.new" || { rm -f "$out.new"; continue; }
                mv -f "$out.new" "$out"; info="GitHub ${arg%%:*} $tag" ;;
            url)
                dl "$arg" "$out.new" || { warn "$name: download failed: $arg"; continue; }
                valid_apk "$out.new" && pin_ok "$name" "$out.new" || { rm -f "$out.new"; continue; }
                mv -f "$out.new" "$out"; info="$arg" ;;
            *)  warn "$name: unknown source kind '$kind'"; continue ;;
        esac
        valid_apk "$out" || { warn "$name: not an APK"; rm -f "$out"; continue; }
        echo "$info" > "$CACHE/$name.from"
        return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# The list, then the drop-in folders.
# ---------------------------------------------------------------------------
declare -A PICK=() ROLE=() FROM=()
declare -a ORDER=()

while IFS=$'\t' read -r name sources role; do
    case "$name" in ''|\#*) continue ;; esac
    name="$(safe_name "$name")"
    ROLE[$name]="${role:--}"
    if [[ "$REFRESH" == 1 || ! -s "$CACHE/$name.apk" ]]; then
        say "$name: fetching"
        if ! fetch_one "$name" "$sources"; then
            if [[ -s "$CACHE/$name.apk" ]]; then
                warn "$name: every source failed; using the cached copy"
            else
                warn "$name: every source failed; the image is built without it"
                continue
            fi
        fi
    fi
    PICK[$name]="$CACHE/$name.apk"
    FROM[$name]="$(cat "$CACHE/$name.from" 2>/dev/null || echo cache)"
    ORDER+=("$name")
done < "$LIST"

dropdirs=()
[[ -n "${EDGE1_APKS_DIR:-}" ]] && dropdirs+=("$EDGE1_APKS_DIR")
dropdirs+=("$HOME/android_khadas/apks")
for d in /mnt/?/android_khadas/apks; do [[ -d "$d" ]] && dropdirs+=("$d"); done
for d in "${dropdirs[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*.apk "$d"/*.APK; do
        [[ -f "$f" ]] || continue
        name="$(safe_name "$(basename "${f%.*}")")"
        if ! valid_apk "$f"; then
            warn "$f is not an APK; skipped"; continue
        fi
        [[ -n "${PICK[$name]:-}" ]] || ORDER+=("$name")
        PICK[$name]="$f"; FROM[$name]="$f (dropped in)"
        ROLE[$name]="${ROLE[$name]:--}"
    done
done

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

keep=" "
total=0
for name in "${ORDER[@]}"; do
    cmp -s "${PICK[$name]}" "$DST/$name.apk" || cp -f "${PICK[$name]}" "$DST/$name.apk"
    keep+="$name.apk "
    bytes=$(stat -c %s "$DST/$name.apk"); total=$(( total + bytes ))
    say "$(printf '%-14s %6s  %s' "$name" "$(numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes")" "${FROM[$name]}")"
done
for f in "$DST"/*.apk; do
    [[ -f "$f" && "$keep" != *" $(basename "$f") "* ]] && rm -f "$f"
done

home=""
for name in "${ORDER[@]}"; do [[ "${ROLE[$name]}" == home ]] && home="$name.apk"; done
{
    echo "# Generated by build/fetch-apps.sh in the edge1 manifest repo. Do not edit."
    [[ -n "$home" ]] && echo "home=$home"
    true
} | write_if_changed "$DST/preinstall.conf"

{
    echo "// Generated by build/fetch-apps.sh in the edge1 manifest repo. Do not edit."
    for name in "${ORDER[@]}"; do
        mod="edge1_preinstall_$(printf '%s' "$name" | tr -c 'A-Za-z0-9_' '_')"
        cat <<EOF

prebuilt_etc {
    name: "$mod",
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
        echo "    edge1_preinstall_$(printf '%s' "$name" | tr -c 'A-Za-z0-9_' '_') \\"
    done
    echo "    edge1_preinstall_conf"
} | write_if_changed "$DST/apps.mk"

say "${#ORDER[@]} app(s), $(numfmt --to=iec "$total" 2>/dev/null || echo "$total") -> vendor/edge1/apps${home:+ (launcher: ${home%.apk})}"
