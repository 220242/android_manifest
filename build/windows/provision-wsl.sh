#!/usr/bin/env bash
#
# Khadas Edge1 / Android TV 14 - provisioning inside WSL2.
#
# Called by Start-EdgeBuild.ps1. Kept as a separate bash file rather than inlined
# into the PowerShell script because nesting bash inside `wsl -- bash -lc "..."`
# makes quoting unreadable and is a common source of silent breakage.
#
#   usage: provision-wsl.sh <stage>
#   stages: deps | clone | preflight | sync | aidl | probe | kernel | build | all
#           report  - consolidated diagnostics on stdout, for the Windows report
#
set -euo pipefail

readonly STAGE="${1:-all}"
readonly REPO_URL="https://github.com/220242/android_manifest"
readonly BRANCH="claude/determined-johnson-fwwaig"
# Deliberately inside the WSL ext4 filesystem, NOT under /mnt/d.
#
# Two reasons, both fatal otherwise:
#   1. NTFS is case-insensitive. AOSP contains files whose names differ only by
#      case, so a checkout onto /mnt/d silently collapses them and the build
#      fails in ways that look like corrupt source.
#   2. The drvfs bridge to /mnt/* is 10-50x slower for the millions of small
#      file operations a sync and build perform. A build that takes 5 hours on
#      ext4 takes over a day through /mnt/d.
#
# The 2TB SSD is still used - the whole WSL distro's virtual disk lives on it,
# see the Relocate stage in Start-EdgeBuild.ps1.
readonly WORK="$HOME/android_khadas"
readonly MANIFEST="$WORK/android_manifest"
readonly TREE="$WORK/aosp-14-edge1"
# Visible from Windows at D:\android_khadas\logs once the distro is relocated.
readonly LOGS="$WORK/logs"

mkdir -p "$WORK" "$LOGS"

log() { printf '\n=== [%s] %s ===\n' "$(date +%H:%M:%S)" "$*"; }

# Every stage that reads the device tree calls this first. It is idempotent and
# takes under a second, and it is what makes "git pull then build" compile the
# files that were just pulled. It also replaces the old symlink layout, which
# Soong's finder could not see - the reason the first platform build could not
# locate the product.
place_device() {
    [[ -d "$TREE" ]] || return 0
    "$MANIFEST/build/place-device.sh" "$TREE"
}

stage_deps() {
    log "installing AOSP build dependencies"
    export DEBIAN_FRONTEND=noninteractive
    sudo -E apt-get update -qq
    # The canonical AOSP list, plus repo's own needs. python-is-python3 matters:
    # several AOSP scripts still invoke bare `python`.
    sudo -E apt-get install -y -qq \
        git-core git-lfs gnupg flex bison build-essential zip curl zlib1g-dev \
        libc6-dev-i386 x11proto-dev libx11-dev lib32z1-dev libgl1-mesa-dev \
        libxml2-utils xsltproc unzip fontconfig python3 python3-pip \
        python-is-python3 rsync ccache bc lz4 libssl-dev \
        device-tree-compiler openjdk-17-jdk-headless \
        gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libelf-dev
    # repo init is run with --git-lfs, and several AOSP projects (notably the
    # Pixel *-kernel prebuilts) store their binaries in LFS. Without the git-lfs
    # binary those projects fetch fine and then fail at checkout, deterministically
    # and with no mention of LFS in the error - which is exactly how it presented.
    git lfs install --skip-repo >/dev/null 2>&1 || true

    if ! command -v repo >/dev/null 2>&1; then
        log "installing the repo launcher"
        sudo curl -fsSL -o /usr/local/bin/repo \
            https://storage.googleapis.com/git-repo-downloads/repo
        sudo chmod a+x /usr/local/bin/repo
    fi
    # repo refuses to run without an identity, and it fails at the end of a long
    # sync rather than up front, so set it now.
    git config --global --get user.email >/dev/null 2>&1 || \
        git config --global user.email "builder@localhost"
    git config --global --get user.name >/dev/null 2>&1 || \
        git config --global user.name "Edge1 Builder"
    # AOSP's git operations are large; the default 1MB post buffer causes
    # "RPC failed" on slow links.
    git config --global http.postBuffer 524288000
    ccache -M 50G >/dev/null 2>&1 || true
    log "dependencies installed"
}

stage_clone() {
    if [[ -d "$MANIFEST/.git" ]]; then
        log "manifest repo present, fetching"
        git -C "$MANIFEST" fetch --quiet origin "$BRANCH"
        git -C "$MANIFEST" checkout --quiet "$BRANCH"
        git -C "$MANIFEST" reset --hard --quiet "origin/$BRANCH"
    else
        log "cloning the device tree / manifest repo"
        git clone --quiet --branch "$BRANCH" "$REPO_URL" "$MANIFEST"
    fi
    chmod +x "$MANIFEST"/build/*.sh
    log "manifest repo ready at $MANIFEST"
}

stage_preflight() {
    log "host preflight"
    # Does not abort the run: exit 2 means "degraded but workable", and on a
    # desktop the CPU-count warning is expected and not worth stopping for.
    "$MANIFEST/build/preflight.sh" "$WORK" || {
        rc=$?
        if (( rc == 1 )); then
            echo "preflight found a hard blocker. Fix it before syncing." >&2
            return 1
        fi
        echo "preflight reported warnings only; continuing." >&2
    }
    log "static tree verification"
    "$MANIFEST/build/verify-tree.sh"
}

stage_sync() {
    # The overlay now drops the 11 Pixel *-kernel projects, but repo leaves the
    # directories of removed projects on disk. device/google/bluejay-kernel in
    # particular is left half checked out from the runs that failed on it, and a
    # stale directory for a project no longer in the manifest makes repo complain.
    if compgen -G "$TREE/device/google/*-kernel" >/dev/null 2>&1; then
        log "removing directories for projects the overlay drops"
        rm -rf "$TREE"/device/google/*-kernel
    fi

    log "syncing AOSP 14 + Khadas overlay (this is the long one: 100+ GiB)"
    # Resolve the newest android-14 tag rather than trusting the hardcoded
    # default in sync.sh, which could not be verified when it was written.
    local tag
    tag=$(git ls-remote --tags --refs \
            https://android.googlesource.com/platform/manifest \
            'refs/tags/android-14.0.0_r*' 2>/dev/null \
          | awk -F/ '{print $NF}' \
          | sort -V | tail -1)
    if [[ -z "$tag" ]]; then
        echo "could not list android-14.0.0_r* tags; check network access to" >&2
        echo "android.googlesource.com, then pass a tag explicitly." >&2
        return 1
    fi
    log "using AOSP tag $tag"
    "$MANIFEST/build/sync.sh" "$TREE" "$tag" 2>&1 | tee "$LOGS/sync.log"
}

stage_kernel() {
    place_device
    log "building the mainline 6.12 kernel"
    "$MANIFEST/build/build-kernel.sh" "$TREE" 2>&1 | tee "$LOGS/kernel.log"
}

stage_build() {
    place_device
    log "building the platform (expect many hours)"
    "$MANIFEST/build/build.sh" "$TREE" userdebug 2>&1 | tee "$LOGS/platform.log"
    # The flash pack, not update.img: that was Rockchip's format and needed the BSP
    # bootloader and RKTools, neither of which this path uses. build.sh stages the
    # images plus a generated flash-emmc.sh that runs on the board itself.
    local pack="$TREE/out/target/product/edge/edge1-flash"
    if [[ -d "$pack" ]]; then
        rm -rf "$WORK/output"
        mkdir -p "$WORK/output"
        cp -a "$pack/." "$WORK/output/"
        log "flash pack copied to $WORK/output/ ($(du -sh "$WORK/output" | cut -f1))"
    else
        echo "no flash pack produced; see $LOGS/platform.log" >&2
        return 1
    fi
}

stage_aidl() {
    place_device
    log "dumping the real AIDL method surface for every declared HAL"
    # This is what unblocks the unwritten composer3 / tv.input / hdmi.cec shims:
    # their signatures could not be verified when the tree was authored, because
    # hardware/interfaces is not in any reachable mirror. Now that a real tree is
    # synced, read them from it.
    "$MANIFEST/build/verify-aidl-surface.sh" "$TREE" > "$WORK/aidl-surface.txt" 2>&1 || true
    log "written to $WORK/aidl-surface.txt ($(wc -l < "$WORK/aidl-surface.txt") lines)"
    echo "From Windows: \\\\wsl.localhost\\Edge1Build\\home\\builder\\android_khadas\\aidl-surface.txt"
}

stage_probe() {
    # Validates every module name device.mk asks for against the synced tree, and
    # dumps what the generic implementations actually provide.
    #
    # Why: device.mk names around fifty PRODUCT_PACKAGES, many of them AOSP
    # "-service.example" / "-service.default" modules written down from memory.
    # A wrong name fails the build at Kati with "module not found", one name per
    # attempt. Checking them all in a single pass turns a long fix-fail loop into
    # one answer.
    place_device
    local out="$WORK/module-probe.txt"
    local dmk="$MANIFEST/device/khadas/edge/device.mk"

    [[ -d "$TREE/hardware/interfaces" ]] || {
        echo "tree not synced at $TREE" >&2; return 1; }

    log "probing the tree for the modules device.mk requests"

    local pats="$WORK/.probe-patterns"
    # Two columns: the module name, and whether device.mk asks for it
    # unconditionally or only behind EDGE1_ENABLE_INCOMPLETE_HALS. Without the
    # second column the report cried wolf - it listed brcm_patchram_plus under
    # "wrong name, must be fixed" when it is a vendor tool deliberately parked
    # behind the gate.
    python3 - "$dmk" > "$pats" <<'PY_INNER'
import re, sys
GATE = 'EDGE1_ENABLE_INCOMPLETE_HALS'
stack = []          # one entry per open conditional: True if it is the gate
names = {}
in_pkgs = False
for raw in open(sys.argv[1]):
    line = raw.split('#', 1)[0].rstrip('\n')
    st = line.strip()
    if re.match(r'if(eq|neq|def|ndef)\b', st):
        stack.append(GATE in st)
        in_pkgs = False
        continue
    if st.startswith('endif'):
        if stack:
            stack.pop()
        in_pkgs = False
        continue
    if st.startswith('else'):
        # The else of the gate is the default branch, not the gated one. An
        # 'else ifeq' keeps one entry on the stack, which is what we want.
        if stack:
            stack[-1] = GATE in st
        in_pkgs = False
        continue
    if re.match(r'PRODUCT_PACKAGES\s*\+?=', st):
        st = st.split('=', 1)[1]
        in_pkgs = True
    elif not in_pkgs:
        continue
    cont = st.endswith('\\')
    for tok in st.rstrip('\\').split():
        if tok.startswith('$'):
            continue
        gated = 'gated' if any(stack) else 'always'
        # A name asked for in both places is unconditional.
        if names.get(tok) != 'always':
            names[tok] = gated
    in_pkgs = cont
for n in sorted(names):
    print(n, names[n])
PY_INNER

    {
        echo "##### MODULE PROBE #####"
        echo "tree: $TREE"
        echo "device.mk requests $(wc -l < "$pats") modules"
        echo

        # One grep pass over the directories that can define a module. Searching
        # the whole tree per name would take hours.
        local dirs=(hardware frameworks system device external packages vendor build prebuilts)
        local found="$WORK/.probe-found"
        : > "$found"
        ( cd "$TREE" && grep -rhoE 'name: "[^"]+"|LOCAL_MODULE *:= *[A-Za-z0-9._@+-]+' \
              --include=Android.bp --include=Android.mk "${dirs[@]}" 2>/dev/null \
          | sed -E 's/name: "([^"]+)"/\1/; s/LOCAL_MODULE *:= *//' \
          | sort -u ) > "$found" || true
        echo "tree defines $(wc -l < "$found") module names"
        echo

        # Only one of these two buckets can break a build. A name device.mk asks
        # for unconditionally has to exist or Kati stops with "module not found";
        # a name behind EDGE1_ENABLE_INCOMPLETE_HALS is a vendor component not yet
        # forward-ported, and is expected to be absent.
        local miss_hard=0 miss_gated=0
        local hard_list="" gated_list=""
        while read -r n gate; do
            [[ -n "$n" ]] || continue
            grep -qxF "$n" "$found" && continue
            if [[ "$gate" == gated ]]; then
                gated_list+="  $n"$'\n'; miss_gated=$((miss_gated+1))
            else
                hard_list+="  $n"$'\n'; miss_hard=$((miss_hard+1))
            fi
        done < "$pats"

        echo "--- MISSING AND REQUESTED UNCONDITIONALLY (breaks the build) ---"
        if (( miss_hard )); then printf '%s' "$hard_list"; else echo "  (none)"; fi
        echo
        echo "--- MISSING BEHIND EDGE1_ENABLE_INCOMPLETE_HALS (expected) ---"
        if (( miss_gated )); then printf '%s' "$gated_list"; else echo "  (none)"; fi
        echo
        echo "missing: $miss_hard unconditional, $miss_gated gated"
        echo

        echo "##### drm_hwcomposer (generic DRM composer3) #####"
        if [[ -d "$TREE/external/drm_hwcomposer" ]]; then
            echo "present. top level:"
            ls "$TREE/external/drm_hwcomposer" | sed 's/^/  /'
            echo "modules it defines:"
            grep -rhoE 'name: "[^"]+"' "$TREE/external/drm_hwcomposer" \
                --include=Android.bp 2>/dev/null | sed -E 's/name: "([^"]+)"/  \1/' | sort -u
            echo "hwc3 / composer3 references:"
            # '|| true' matters: under set -euo pipefail a grep that finds nothing
            # exits 1, head closing the pipe makes it a pipeline failure, and the
            # whole { } block aborts - truncating the report right before the
            # sections that were the point of running it. That is exactly what
            # happened, and the absence of matches was itself the answer: AOSP 14's
            # drm_hwcomposer is HWC2 only.
            grep -rl 'composer3' "$TREE/external/drm_hwcomposer" 2>/dev/null \
                | head -10 | sed 's/^/  /' || echo "  (none - this snapshot is HWC2 only)"
        else
            echo "ABSENT at $TREE/external/drm_hwcomposer"
        fi
        echo

        echo "##### audio AIDL reference implementation #####"
        local ad="$TREE/hardware/interfaces/audio/aidl/default"
        if [[ -d "$ad" ]]; then
            echo "present. top level:"
            ls "$ad" | sed 's/^/  /'
            echo "modules it defines:"
            grep -rhoE 'name: "[^"]+"' "$ad" --include=Android.bp 2>/dev/null \
                | sed -E 's/name: "([^"]+)"/  \1/' | sort -u
        else
            echo "ABSENT at $ad"
        fi
        echo
        echo "##### MESA / PANFROST (the GLES driver) #####"
        # Last run this section printed "present at external/mesa3d" and then three
        # empty lists, which answers nothing: either the directory is a stub, or the
        # greps were looking in the wrong place. Since libGLES_mesa and
        # libmesa_pipe_panfrost do appear in the tree-wide module list, something
        # defines them - so this now goes looking for where, rather than assuming.
        md="$TREE/external/mesa3d"
        echo "  external/mesa3d: $(if [[ -d $md ]]; then echo present; else echo ABSENT; fi)"
        if [[ -d "$md" ]]; then
            echo "    files: $(find "$md" -type f 2>/dev/null | wc -l), of which Android.bp/mk: $(find "$md" -name 'Android.bp' -o -name 'Android.mk' 2>/dev/null | wc -l)"
            echo "    top level:"
            ls -A "$md" 2>/dev/null | head -20 | sed 's/^/      /'
            echo "    git: $(git -C "$md" log --oneline -1 2>&1 | head -1)"
        fi
        echo "  where the tree defines the modules this port needs:"
        for m in libGLES_mesa libmesa_pipe_panfrost libmesa_winsys_panfrost libgbm_mesa; do
            hit=$(cd "$TREE" && grep -rl "name: \"$m\"" --include=Android.bp \
                  external hardware device vendor frameworks 2>/dev/null | head -2 | tr '\n' ' ')
            printf '    %-28s %s\n' "$m" "${hit:-NOT DEFINED ANYWHERE}"
        done
        echo "  every BOARD_MESA3D_* the tree mentions, and where:"
        (cd "$TREE" && grep -rn 'BOARD_MESA3D_[A-Z_]*' \
             --include=Android.bp --include=*.mk --include=*.py --include=*.md \
             external build device 2>/dev/null | head -20 | sed 's/^/    /') || true
        echo "  soong_config namespaces mesa declares:"
        (cd "$TREE" && grep -rhA 3 'soong_config_module_type\|soong_config_string_variable' \
             external/mesa3d --include=Android.bp 2>/dev/null | grep -E 'name:|namespace:' \
             | head -14 | sed 's/^/    /') || true
        echo "  ours: $(grep -h '^BOARD_MESA3D' "$MANIFEST/device/khadas/edge/BoardConfig.mk" || echo NONE)"
        echo

        echo "##### V4L2 CODEC2 (hardware decode via rkvdec) #####"
        vd="$TREE/external/v4l2_codec2"
        if [[ -d "$vd" ]]; then
            echo "  present. modules:"
            grep -rhoE 'name: "[^"]+"' "$vd" --include=Android.bp 2>/dev/null \
                | sed -E 's/name: "([^"]+)"/    \1/' | sort -u || true
            echo "  the Codec2 service to put in PRODUCT_PACKAGES:"
            grep -rhoE 'name: "android\.hardware\.media\.c2[^"]*"' "$vd" --include=Android.bp 2>/dev/null \
                | sed -E 's/name: "([^"]+)"/    \1/' | sort -u || echo "    (none found)"
            echo "  what it needs configured (its own README / board vars):"
            grep -rhoE '(BOARD|TARGET)_[A-Z0-9_]*(V4L2|CODEC2)[A-Z0-9_]*' "$vd" 2>/dev/null \
                | sort -u | head -10 | sed 's/^/    /' || true
            ls "$vd" 2>/dev/null | grep -iE 'readme|doc' | sed 's/^/    file: /' || true
        else
            echo "  ABSENT at $vd"
        fi
        echo

        echo "##### WI-FI HAL options for brcmfmac #####"
        # android.hardware.wifi-service wants a legacy HAL underneath, and the one
        # in the tree is written for bcmdhd's private nl80211 commands. This is
        # what the tree actually offers.
        for d in hardware/interfaces/wifi/aidl/default hardware/broadcom/wlan; do
            if [[ -d "$TREE/$d" ]]; then
                echo "  $d:"
                ls "$TREE/$d" | sed 's/^/    /' | head -12
            else
                echo "  $d: ABSENT"
            fi
        done
        echo "  wifi_hal-ish modules in the tree:"
        grep -xE 'lib?wifi[-_]hal.*|.*wifi_hal.*' "$found" 2>/dev/null | sed 's/^/    /' | head -10 || true
        echo

        echo "##### KERNEL CONFIG FRAGMENT vs THE KERNEL #####"
        # Every symbol in the fragment has to exist in this kernel's Kconfig files.
        # On the 4.19 BSP three rounds went on symbols that simply were not there -
        # merge_config.sh mentions them in passing and the build continues.
        kdir="$TREE/kernel/mainline"
        frag="$MANIFEST/device/khadas/edge/kernel/edge1_mainline.config"
        if [[ -d "$kdir" && -f "$frag" ]]; then
            echo "  kernel: $(cd "$kdir" && git describe --tags 2>/dev/null || echo unknown)"
            python3 - "$kdir" "$frag" <<'PY_KCONFIG'
import os, re, sys
kdir, frag = sys.argv[1], sys.argv[2]
have = set()
for base, dirs, files in os.walk(kdir):
    dirs[:] = [d for d in dirs if d not in ('.git', 'out')]
    for fn in files:
        if not fn.startswith('Kconfig'):
            continue
        try:
            body = open(os.path.join(base, fn), errors='replace').read()
        except OSError:
            continue
        have |= set(re.findall(r'^\s*(?:menu)?config\s+([A-Za-z0-9_]+)', body, re.M))
wanted = []
for line in open(frag):
    m = re.match(r'(?:# )?CONFIG_([A-Z0-9_]+)', line.strip())
    if m:
        wanted.append(m.group(1))
missing = sorted({w for w in wanted if w not in have})
print('  %d Kconfig symbols in the kernel; the fragment names %d distinct'
      % (len(have), len(set(wanted))))
if missing:
    print('  !! %d NOT DEFINED IN THIS KERNEL:' % len(missing))
    for w in missing:
        print('       CONFIG_%s' % w)
else:
    print('  every symbol in the fragment exists in this kernel')
PY_KCONFIG
        else
            echo "  kernel not synced at $kdir, or fragment missing"
        fi
        echo

        echo "##### FROZEN AIDL VERSIONS #####"
        # Why this matters more than it looks: Soong turns each frozen
        # aidl_api/<package>/<N> directory into a module named
        # <package>-V<N>-<backend>, and a blueprint that names a version which was
        # never frozen fails analysis with "depends on undefined module" - which
        # stops the whole tree, not just that module, and not just when the module
        # is installed. Writing those suffixes from memory is how the audio shim
        # ended up disabled.
        python3 - "$TREE" "$WORK/.probe-aidl-versions" <<'PY_AIDL'
import os, re, sys
tree, outmap = sys.argv[1], sys.argv[2]
skip = {'.repo', 'out', '.git'}
vers = {}
for root, dirs, files in os.walk(tree):
    dirs[:] = [d for d in dirs if d not in skip]
    if os.path.basename(root) != 'aidl_api':
        continue
    dirs[:] = []                      # nothing of interest below a version dir
    for pkg in sorted(os.listdir(root)):
        pdir = os.path.join(root, pkg)
        if not os.path.isdir(pdir):
            continue
        v = sorted(d for d in os.listdir(pdir) if re.fullmatch(r'[0-9]+', d))
        if v:
            vers.setdefault(pkg, set()).update(int(x) for x in v)
            vers[pkg + '\0src'] = {os.path.relpath(pdir, tree)}
print('%d packages with frozen versions' % len([k for k in vers if '\0' not in k]))
print()
want = ('android.hardware.graphics', 'android.hardware.audio',
        'android.media.audio', 'android.hardware.tv',
        'android.hardware.bluetooth', 'android.hardware.wifi')
for pkg in sorted(k for k in vers if '\0' not in k):
    if pkg.startswith(want):
        v = sorted(vers[pkg])
        print('  %-52s V%s   (latest: -V%d-ndk)' % (pkg, ','.join(map(str, v)), v[-1]))
print()
print('  full map written to %s' % outmap)
with open(outmap, 'w') as f:
    for pkg in sorted(k for k in vers if '\0' not in k):
        f.write('%s %s\n' % (pkg, ','.join(str(x) for x in sorted(vers[pkg]))))
PY_AIDL
        echo

        echo "##### SHIM BLUEPRINT DEPENDENCIES #####"
        # Resolves every shared_libs/static_libs entry in the device shims against
        # the tree: a plain name has to be a declared module, and a
        # <package>-V<N>-<backend> name has to have aidl_api/<package>/<N> frozen.
        python3 - "$MANIFEST/device/khadas/edge/shims" "$found" \
                  "${WORK}/.probe-aidl-versions" <<'PY_DEPS'
import os, re, sys
shims, found, aidl = sys.argv[1], sys.argv[2], sys.argv[3]
declared = set(open(found).read().split('\n'))
frozen = {}
if os.path.exists(aidl):
    for line in open(aidl):
        pkg, v = line.split()
        frozen[pkg] = set(v.split(','))
bad = 0
for root, _, files in os.walk(shims):
    for fn in sorted(files):
        if not fn.startswith('Android.bp'):
            continue
        path = os.path.join(root, fn)
        body = open(path).read()
        # Strip // comments first. Without this, a quoted phrase inside a comment
        # in a shared_libs block is read as a dependency: the allocator
        # blueprint's own note about "depends on undefined module" was reported
        # as an undefined module.
        body = re.sub(r'//[^\n]*', '', body)
        print('  %s%s' % (os.path.relpath(path, shims),
                          '   (NOT seen by Soong)' if fn != 'Android.bp' else ''))
        deps = set()
        for m in re.finditer(r'(?:shared_libs|static_libs|header_libs)\s*:\s*\[(.*?)\]',
                             body, re.S):
            for q in re.finditer(r'"([^"]+)"', m.group(1)):
                deps.add(q.group(1))
        for d in sorted(deps):
            m = re.fullmatch(r'(.+)-V([0-9]+)-(ndk|cpp|java|rust)', d)
            if m:
                pkg, ver = m.group(1), m.group(2)
                if pkg not in frozen:
                    verdict = 'NO SUCH AIDL PACKAGE'
                elif ver not in frozen[pkg]:
                    verdict = 'WRONG VERSION - frozen: ' + ','.join(sorted(frozen[pkg]))
                else:
                    verdict = 'ok'
            else:
                verdict = 'ok' if d in declared else 'NOT A DECLARED MODULE'
            if verdict != 'ok':
                bad += 1
            print('      %-50s %s' % (d, verdict))
print()
print('  %d unresolved dependenc%s' % (bad, 'y' if bad == 1 else 'ies'))
PY_DEPS
        echo

        echo "##### VINTF: what the framework requires of us #####"
        # check_vintf fails the build if a HAL the framework compatibility matrix
        # marks optional="false" is missing from the device manifest. Level 8 is
        # the Android 14 FCM, which is what target-level in
        # device/khadas/edge/vintf/manifest.xml claims.
        cm="$TREE/hardware/interfaces/compatibility_matrices"
        if [[ -d "$cm" ]]; then
            ls "$cm" | grep -E 'compatibility_matrix\.[0-9]+\.xml' | sed 's/^/  /' || true
            for lvl in 8 7; do
                f="$cm/compatibility_matrix.$lvl.xml"
                [[ -f "$f" ]] || continue
                echo "  --- level $lvl: HALs with optional=false ---"
                python3 - "$f" <<'PY_VINTF' || true
import sys, xml.etree.ElementTree as ET
# Report the raw optional attribute rather than a verdict.
#
# Two guesses have now been wrong here. Filtering on optional=="false" printed
# "0 required"; treating a missing attribute as required printed 86, including
# the radio and automotive HALs, which no TV device provides - so that reading
# cannot be right either. What the entries actually say is the only thing worth
# printing until the semantics are confirmed against libvintf.
root = ET.parse(sys.argv[1]).getroot()
buckets = {'false': [], 'true': [], 'absent': []}
for hal in root.findall('hal'):
    key = hal.get('optional', 'absent')
    if key not in buckets:
        key = 'absent'
    name = hal.findtext('name', '?')
    vers = ','.join(v.text for v in hal.findall('version')) or \
           ','.join(v.text for v in hal.findall('fqname')) or '-'
    buckets[key].append('    %-46s %-8s %s' % (name, hal.get('format', 'hidl'), vers))
print('    %d entries: optional=false %d, optional=true %d, no attribute %d'
      % (sum(len(v) for v in buckets.values()), len(buckets['false']),
         len(buckets['true']), len(buckets['absent'])))
for key in ('false', 'absent'):
    if not buckets[key]:
        continue
    print('    --- optional=%s ---' % key)
    for line in buckets[key][:40]:
        print(line)
    if len(buckets[key]) > 40:
        print('    ... and %d more' % (len(buckets[key]) - 40))
PY_VINTF
            done
            echo "  --- level 8 kernel requirements (6.12 LTS is what we have) ---"
            python3 - "$cm/compatibility_matrix.8.xml" <<'PY_KERNEL' || true
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception as e:
    print('    could not parse: %s' % e); raise SystemExit(0)
ks = root.findall('kernel')
if not ks:
    print('    (the matrix states no kernel requirement)')
for k in ks:
    cfgs = k.findall('config')
    print('    version %-12s level=%-4s %d required configs'
          % (k.get('version'), k.get('level', '-'), len(cfgs)))
PY_KERNEL
            echo "  --- our device manifest declares ---"
            grep -E '<name>|target-level' \
                 "$MANIFEST/device/khadas/edge/vintf/manifest.xml" | sed 's/^/    /' || true
        else
            echo "  ABSENT at $cm"
        fi
        echo

        echo "##### sepolicy versions BOARD_SEPOLICY_VERS may name #####"
        # A value that is no longer in the platform's compat set is a hard Kati
        # error, and the set shrinks with every release. BoardConfig.mk currently
        # says 29.0.
        if [[ -d "$TREE/system/sepolicy/prebuilts/api" ]]; then
            echo "  prebuilt policy APIs in the tree:"
            ls "$TREE/system/sepolicy/prebuilts/api" | tr '\n' ' ' | sed 's/^/    /' || true
            echo
            grep -rhoE 'PLATFORM_SEPOLICY_COMPAT_VERSIONS *:=.*' \
                 "$TREE/system/sepolicy/Android.mk" 2>/dev/null | sed 's/^/  /' || true
            grep -rhA 12 'PLATFORM_SEPOLICY_COMPAT_VERSIONS' \
                 "$TREE/system/sepolicy/Android.bp" 2>/dev/null | head -20 | sed 's/^/  /' || true
        else
            echo "  ABSENT at $TREE/system/sepolicy/prebuilts/api"
        fi
        # Not grepped out of BoardConfig.mk any more: the variable is not set there,
        # it is derived by core/config.mk from the release config, and grepping for
        # it printed the comment explaining that instead of a value.
        echo "  ours: not set by the board - core/config.mk:877 derives it from"
        echo "        PLATFORM_SEPOLICY_VERSION and freezes it (202404 in this release)"
        echo

        echo "##### sepolicy types our *_contexts files rely on #####"
        # verify-tree.sh keeps a hand-maintained list of the AOSP types this tree
        # labels files with. This is where that list is checked against reality:
        # a type AOSP renamed or dropped fails the policy build, and until this
        # round none of the device sepolicy was compiled at all (the device tree
        # was a symlink, invisible to Soong's finder).
        if [[ -d "$TREE/system/sepolicy" ]]; then
            python3 - "$TREE" "$MANIFEST/device/khadas/edge/sepolicy/vendor" <<'PY_SEPOL'
import os, re, sys
tree, sedir = sys.argv[1], sys.argv[2]
def types_in(root):
    found = set()
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in ('.git', 'prebuilts')]
        for fn in files:
            if not fn.endswith('.te'):
                continue
            try:
                body = open(os.path.join(base, fn), errors='replace').read()
            except OSError:
                continue
            found |= set(re.findall(r'^type\s+([a-z0-9_]+)', body, re.M))
            found |= set(re.findall(r'^[a-z_]*_prop\(([a-z0-9_]+)', body, re.M))
    return found
plat = types_in(os.path.join(tree, 'system', 'sepolicy'))
ours = types_in(sedir)
refs = set()
for fn in ('file_contexts', 'genfs_contexts', 'property_contexts'):
    path = os.path.join(sedir, fn)
    if os.path.exists(path):
        refs |= set(re.findall(r'u:object_r:([a-z0-9_]+)', open(path).read()))
print('  system/sepolicy declares %d types; this device declares %d' % (len(plat), len(ours)))
unknown = sorted(t for t in refs if t not in plat and t not in ours)
borrowed = sorted(t for t in refs if t in plat and t not in ours)
print('  borrowed from AOSP (%d): %s' % (len(borrowed), ' '.join(borrowed)))
if unknown:
    print('  !! UNKNOWN (%d) - these fail the policy build:' % len(unknown))
    for t in unknown:
        print('       %s' % t)
else:
    print('  every labelled type resolves')
PY_SEPOL
        else
            echo "  ABSENT at $TREE/system/sepolicy"
        fi
        echo

        echo "##### release config (lunch needs it) #####"
        if [[ -f "$TREE/build/release/release_config_map.mk" ]]; then
            echo "  build/release/release_config_map.mk present; configs declared:"
            grep -hoE 'declare-release-config, *[a-z_0-9]+' \
                 "$TREE/build/release/release_config_map.mk" \
                 | sed 's/.*, *//' | sort -u | sed 's/^/    /' || true
        else
            echo "  MISSING $TREE/build/release/release_config_map.mk"
            echo "  lunch <product>-<release>-<variant> has no valid release without it"
        fi
        echo
        echo "##### END MODULE PROBE #####"
    } > "$out" 2>&1

    log "written to $out ($(wc -l < "$out") lines)"
    sed -n '/^--- MISSING AOSP/,/^missing:/p' "$out"
}

stage_report() {
    # Emits a consolidated diagnostic to stdout. Start-EdgeBuild.ps1 captures it
    # into the Windows-side report, so this must stay quiet on stderr and never
    # exit non-zero: a diagnostic that fails to run is worse than useless.
    echo "##### LINUX ENVIRONMENT #####"
    echo "uname:      $(uname -a 2>&1)"
    echo "distro:     $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
    echo "nproc:      $(nproc 2>&1)"
    echo "user:       $(id 2>&1)"
    echo
    echo "--- memory (what build.sh derives -j from) ---"
    free -h 2>&1 || true
    echo
    echo "--- disk ---"
    df -h "$HOME" /tmp 2>&1 || true
    echo
    echo "--- toolchain ---"
    # git-lfs is listed because its absence, combined with repo init --git-lfs,
    # is what broke checkout of the LFS-backed projects - and nothing in the
    # failure said so.
    # ninja and soong come from the tree's own prebuilts, so a host ninja is not
    # part of this list - it read as "ninja MISSING" and looked like a problem.
    for t in git git-lfs repo python3 java make ccache aarch64-linux-gnu-gcc; do
        printf '%-8s %s\n' "$t" "$(command -v $t 2>/dev/null || echo MISSING)"
    done
    echo "ninja:      $([[ -x $TREE/prebuilts/build-tools/linux-x86/bin/ninja ]] \
        && echo 'tree prebuilt (the one the build uses)' || echo 'tree prebuilt MISSING')"
    echo "git-lfs:    $(git lfs version 2>&1 | head -1)"
    echo "repo ver:   $(repo --version 2>&1 | head -2 | tr '\n' ' ')"
    echo "ccache:     $(ccache -s 2>/dev/null | head -4 | tr '\n' ' ')"
    echo
    echo "--- tree ---"
    echo "manifest:   $MANIFEST $([[ -d $MANIFEST/.git ]] && git -C "$MANIFEST" log --oneline -1 2>&1 || echo MISSING)"
    echo "tree:       $TREE $([[ -d $TREE/.repo ]] && echo '(.repo present)' || echo '(not synced)')"
    if [[ -d "$TREE/.repo" ]]; then
        echo "aosp ref:   $(cat "$TREE/.repo/manifests.git/HEAD" 2>/dev/null || echo unknown)"
        echo "projects:   $(ls "$TREE" 2>/dev/null | wc -l) top-level entries"
        echo "local_manifests: $(ls "$TREE/.repo/local_manifests" 2>/dev/null || echo NONE)"
    fi
    echo
    # Both of these used to be files the user had to find and send separately,
    # which is why a round went by with a stale probe and no one noticed. The
    # report is the one thing that gets sent, so the answers belong in it.
    echo "##### MODULE PROBE #####"
    if [[ -f "$WORK/module-probe.txt" ]]; then
        echo "($(wc -l < "$WORK/module-probe.txt") lines total; first 400 below)"
        head -400 "$WORK/module-probe.txt" 2>&1 || true
    else
        echo "(the probe has not run)"
    fi
    echo
    echo "##### AIDL SURFACE (summary) #####"
    if [[ -f "$WORK/aidl-surface.txt" ]]; then
        grep -E '\(declared version' "$WORK/aidl-surface.txt" | sed 's/^/  /' || true
        echo "  full file: $WORK/aidl-surface.txt ($(wc -l < "$WORK/aidl-surface.txt") lines)"
    else
        echo "(the aidl stage has not run)"
    fi
    echo
    echo "##### LOGS #####"
    # Full build logs run to gigabytes of ninja output, which is unpastable. Pull
    # the error lines with context, then the tail, and say how much was skipped.
    for f in "$LOGS"/*.log; do
        [[ -f "$f" ]] || continue
        local total; total=$(wc -l < "$f")
        echo
        echo "===== $(basename "$f")  (${total} lines) ====="
        # The pattern list earns its keep only if it catches the FIRST real
        # error. It missed the kernel's actual failure once already: Rockchip's
        # gcc-wrapper.py prints "error, forbidden warning:file.c:398" - a comma,
        # not a colon - and make prints "*** [...] Error 1", so a 2727-line log
        # reported a single unrelated grep warning and nothing else.
        echo "--- matches for error patterns (max 200 lines) ---"
        grep -nE 'error[:,]|ERROR|FAILED:|fatal error|forbidden warning|internal compiler error|multiple definition|collect2:|\*\*\* \[|\*\*\* No rule|ninja: build stopped|No such file|Killed|out of memory|cannot find|undefined reference|Permission denied|Segmentation fault' \
            "$f" 2>/dev/null | head -200 || echo "(none)"
        echo "--- last 120 lines ---"
        tail -120 "$f" 2>/dev/null
    done
    echo
    echo "##### END LINUX REPORT #####"
}

case "$STAGE" in
    deps)      stage_deps ;;
    clone)     stage_clone ;;
    preflight) stage_preflight ;;
    sync)      stage_sync ;;
    kernel)    stage_kernel ;;
    build)     stage_build ;;
    aidl)      stage_aidl ;;
    probe)     stage_probe ;;
    report)    stage_report ;;
    all)       stage_deps; stage_clone; stage_preflight; stage_sync
               stage_kernel; stage_build ;;
    *)
        # A stage this copy does not know about almost always means the in-distro
        # clone is behind the one the instructions were written for, so say which
        # commit this is rather than only refusing.
        echo "unknown stage: $STAGE" >&2
        echo "this copy is at: $(git -C "$(dirname "${BASH_SOURCE[0]}")/../.." log --oneline -1 2>&1)" >&2
        echo "if the stage should exist, update it:" >&2
        echo "  git -C ~/android_khadas/android_manifest fetch origin $BRANCH" >&2
        echo "  git -C ~/android_khadas/android_manifest reset --hard origin/$BRANCH" >&2
        echo "or just run Start-EdgeBuild.ps1, which updates it automatically." >&2
        exit 2 ;;
esac
