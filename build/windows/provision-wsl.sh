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
        gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libelf-dev \
        gdisk pigz swig python3-setuptools python3-pyelftools
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
    # ccache's size is set by build.sh, not here: the cache lives in the tree's
    # out/ (the only directory Android 14's build sandbox leaves writable) and
    # the tree does not exist yet at this stage.
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

stage_uboot() {
    # Before the platform build, because it is quick and because a card without a
    # bootloader is not worth producing. See build-uboot.sh for what the Android
    # delta to the upstream defconfig is.
    log "building mainline U-Boot for a self-booting SD card"
    "$MANIFEST/build/build-uboot.sh" "$TREE" 2>&1 | tee "$LOGS/uboot.log"
}

stage_sdimage() {
    place_device
    log "assembling the SD card image"
    "$MANIFEST/build/build-sdimage.sh" "$TREE" 2>&1 | tee "$LOGS/sdimage.log"
    # Copied out to $WORK so it is reachable from Explorer without going through
    # the tree. The compressed copy is the one worth moving: the raw image is 7GiB
    # and \\wsl.localhost is slow.
    local img="$TREE/out/target/product/edge/edge1-sdcard.img"
    if [[ -f "$img.gz" ]]; then
        mkdir -p "$WORK/output"
        cp -f "$img.gz" "$WORK/output/"
        log "SD image copied to $WORK/output/$(basename "$img.gz") ($(du -h "$img.gz" | cut -f1))"
    elif [[ -f "$img" ]]; then
        mkdir -p "$WORK/output"
        cp -f "$img" "$WORK/output/"
        log "SD image copied to $WORK/output/$(basename "$img") ($(du -h "$img" | cut -f1))"
    else
        echo "no SD image produced; see $LOGS/sdimage.log" >&2
        return 1
    fi
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
    # Cleared first: if the diagnostic block below dies early, a stale count from
    # the last run would gate this one - in whichever direction is wrong.
    rm -f "$WORK/.probe-miss-hard" "$WORK/.probe-sepol-dupes" \
          "$WORK/.probe-prop-dupes" "$WORK/.probe-ctx-dupes" "$WORK/.probe-fcm-bad" \
          "$WORK/.probe-vndk-req"

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

    # Everything below runs with errexit and pipefail OFF, in a subshell.
    #
    # This is the third time the same shape of bug has truncated this report: a
    # `grep -r ... | head -n` over a large tree, where head closes the pipe, grep
    # takes SIGPIPE, pipefail turns 141 into failure and errexit ends the block -
    # losing every section after it. Twice it was fixed with a `|| true` on the
    # offending line, and twice a new line brought it back.
    #
    # A diagnostic that aborts is worse than one that prints something odd, so the
    # property is enforced once, here, instead of being re-argued per line.
    (
    set +e +o pipefail
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

        # A name device.mk asks for unconditionally and that matches no module is
        # NOT a build error, which is worse than one. core/main.mk:1341 checks that
        # PRODUCT_PACKAGES exist only when the product sets
        # PRODUCT_ENFORCE_PACKAGES_EXIST; otherwise the name is dropped in
        # silence, the build succeeds, and the library is simply not on the image.
        # Four of those - libEGL_mesa, libGLESv1_CM_mesa, libGLESv2_mesa,
        # libgallium_dri - sat in device.mk for several rounds looking installed.
        #
        # So this count is the gate: the probe exits non-zero on it, before the
        # six-hour build, rather than only printing it.
        #
        # A name behind EDGE1_ENABLE_INCOMPLETE_HALS is a vendor component not yet
        # forward-ported and is expected to be absent, so it does not gate.
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
        # Read back after the subshell: $miss_hard cannot escape it.
        echo "$miss_hard" > "$WORK/.probe-miss-hard"

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
        # The last version of this section said libGLES_mesa was NOT DEFINED
        # ANYWHERE, which was its own bug: it searched only for name: "..." in
        # Android.bp files, and AOSP's mesa3d snapshot is Android.mk-based - the
        # module is a LOCAL_MODULE. The module-name check at the top of this report,
        # which reads both forms, said nothing was missing at the same time. Both
        # forms are searched here now.
        md="$TREE/external/mesa3d"
        echo "  external/mesa3d: $(if [[ -d $md ]]; then echo present; else echo ABSENT; fi)"
        if [[ -d "$md" ]]; then
            echo "    $(find "$md" -type f | wc -l) files; build files at top level:"
            ls "$md" 2>/dev/null | grep -E '^Android|^CleanSpec|meson.build' | sed 's/^/      /'
            echo "    git: $(git -C "$md" log --oneline -1 2>&1 | head -1)"
            echo "  how it selects drivers - every *GPU_DRIVERS* and BOARD_* it reads:"
            grep -rhoE '(BOARD|MESA|TARGET)_[A-Z0-9_]*(GPU_DRIVERS|DRIVERS|MESA3D)[A-Z0-9_]*' "$md" \
                2>/dev/null | sort | uniq -c | sort -rn | head -12 | sed 's/^/    /'
            echo "  the lines that read them:"
            grep -rhnE '^[^#]*\$\((BOARD|MESA)_[A-Z0-9_]*(GPU_DRIVERS|DRIVERS)' "$md" \
                --include='*.mk' --include='*.bp' 2>/dev/null | head -8 | sed 's/^/    /'
            echo "  the driver names it accepts (BOARD_GPU_DRIVERS is matched against these):"
            grep -hA 30 '^gallium_drivers *:=' "$md/Android.mk" 2>/dev/null \
                | head -32 | sed 's/^/    /'
            grep -hA 12 '^classic_drivers *:=' "$md/Android.mk" 2>/dev/null \
                | head -14 | sed 's/^/    /'
            echo "  is panfrost one of the drivers it can build:"
            grep -rlE 'panfrost' "$md"/Android*.mk "$md"/Android*.bp "$md"/src/gallium/Android*.mk \
                2>/dev/null | sed 's/^/    /' | head -5
            grep -rhoE 'panfrost' "$md"/Android.common.mk 2>/dev/null | head -1 | sed 's/^/    Android.common.mk mentions panfrost: /'
            echo "  the EGL/GLES and gallium modules it defines:"
            { grep -rhoE 'name: "lib(EGL|GLES|mesa|gbm)[a-zA-Z0-9_]*"' "$md" --include='*.bp' 2>/dev/null \
                | sed -E 's/name: "([^"]+)"/\1/'
              grep -rhoE 'LOCAL_MODULE *:= *lib[a-zA-Z0-9_]*' "$md" --include='*.mk' 2>/dev/null \
                | sed -E 's/LOCAL_MODULE *:= *//'
            } | sort -u | head -25 | sed 's/^/    /'
        fi
        echo "  the one working Mesa integration in this tree, to copy from:"
        db="$TREE/device/linaro/dragonboard/shared/graphics/mesa"
        if [[ -d "$db" ]]; then
            echo "    $db"
            ls -R "$db" 2>/dev/null | head -20 | sed 's/^/      /'
            for f in "$db"/*.mk; do
                [[ -f "$f" ]] || continue
                echo "    --- $(basename "$f") ---"
                grep -vE '^\s*$|^\s*#' "$f" 2>/dev/null | head -25 | sed 's/^/      /'
            done
        else
            echo "    ABSENT at $db"
        fi
        echo "  ours: $(grep -hE '^BOARD_(MESA3D|GPU)' "$MANIFEST/device/khadas/edge/BoardConfig.mk" | tr '\n' ' ' || echo NONE)"
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
        # Kept for whatever board code this tree grows next. There are no shims at
        # the moment: both existed to bridge to the Rockchip Android 10 HALs, and
        # they went with them - the audio one had started failing the build, since
        # Soong analyses a module whether or not anything installs it.
        if [[ ! -d "$MANIFEST/device/khadas/edge/shims" ]]; then
            echo "  no shims in the device tree"
        fi
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
        KERNEL_CFG="$TREE/kernel/mainline/out/.config"
        FRAGMENT_CFG="$MANIFEST/device/khadas/edge/kernel/edge1_mainline.config"
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
            # What PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false gave up.
            #
            # That check rejected the kernel for its version - the matrices carry
            # <kernel> rows for the 5.10, 5.15, 6.1 and 6.6 LTS branches and none
            # for 6.12, which did not exist when Android 14 was cut, so libvintf
            # found no row to match and said so. The minimums it listed are all
            # below 6.12.111.
            #
            # But the same check also verified the CONFIG_* symbols those rows
            # require, and that half would have worked. So it is done here instead,
            # against the merged .config if the kernel has been built and against
            # the fragment otherwise. Reported, not gated: many of those entries are
            # conditional on a GKI kernel or on another config being set, and
            # deciding which apply to a non-GKI board is a judgement this cannot
            # make.
            echo "  --- FCM kernel config requirements vs this board's kernel ---"
            python3 - "$cm" "$KERNEL_CFG" "$FRAGMENT_CFG" <<'PY_KCFG'
import os, re, sys, xml.etree.ElementTree as ET
cm, merged, fragment = sys.argv[1], sys.argv[2], sys.argv[3]
have = {}
src = merged if os.path.exists(merged) else fragment
if not os.path.exists(src):
    print('    no kernel config to check against (%s)' % src)
    raise SystemExit(0)
print('    checking against %s' % src)
for raw in open(src, errors='replace'):
    line = raw.strip()
    m = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=(.*)$', line)
    if m:
        have[m.group(1)] = m.group(2)
        continue
    m = re.match(r'^# (CONFIG_[A-Za-z0-9_]+) is not set$', line)
    if m:
        have[m.group(1)] = 'n'
# Requirements from the matrices, per LTS branch, deduplicated by symbol.
want = {}
for fn in sorted(os.listdir(cm)):
    if not re.match(r'^compatibility_matrix\.[0-9]+\.xml$', fn):
        continue
    try:
        root = ET.parse(os.path.join(cm, fn)).getroot()
    except Exception:
        continue
    for k in root.findall('kernel'):
        ver = k.get('version', '?')
        for c in k.findall('config'):
            key = c.findtext('key')
            v = c.find('value')
            val = (v.text or '') if v is not None else ''
            typ = v.get('type') if v is not None else ''
            if key:
                want.setdefault(key, set()).add('%s=%s%s' % (ver, val, '' if typ != 'tristate' else ''))
if not want:
    print('    the matrices state no kernel config requirements')
    raise SystemExit(0)
missing = []
for key in sorted(want):
    if key not in have:
        missing.append(key)
print('    %d distinct CONFIG_* required across all <kernel> rows; %d not named by'
      % (len(want), len(missing)))
print('    this board\'s config:')
for key in missing:
    print('      %-44s wanted as %s' % (key, ' '.join(sorted(want[key]))[:60]))
if not missing:
    print('      (none)')
PY_KCFG
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

            # The gate. check_vintf runs 15 minutes into a build and reports this:
            #
            #   The following instances are in the device manifest but not
            #   specified in framework compatibility matrix:
            #       android.hardware.cas@1.2::IMediaCasService/default
            #       android.hardware.graphics.composer@2.4::IComposer/default
            #
            # Every input it needs is already read above: our manifest's
            # target-level and declared HALs, and the matrix at that level. So the
            # same question gets answered here in a second.
            #
            # Only the device manifest's own entries are checked. The instances that
            # come from an installed service's VINTF fragment - the HIDL cas one
            # above arrives with an AOSP apex - are not visible without a built
            # image, so this narrows the answer rather than replacing check_vintf.
            echo "  --- our declared HALs against the matrix at our target-level ---"
            EDGE1_WORK="$WORK" python3 - "$cm" \
                "$MANIFEST/device/khadas/edge/vintf/manifest.xml" <<'PY_FCM'
import os, re, sys, xml.etree.ElementTree as ET
cm, mf = sys.argv[1], sys.argv[2]
root = ET.parse(mf).getroot()
level = root.get('target-level')
print('    target-level: %s' % level)
path = os.path.join(cm, 'compatibility_matrix.%s.xml' % level)
if not os.path.exists(path):
    print('    !! no compatibility_matrix.%s.xml in the tree; check_vintf has no' % level)
    print('       matrix to check against at this level.')
    open(os.path.join(os.environ.get('EDGE1_WORK', '/tmp'), '.probe-fcm-bad'), 'w').write('1\n')
    raise SystemExit(0)
# What the matrix at this level accepts: name -> set of versions, per format.
accept = {}
for hal in ET.parse(path).getroot().findall('hal'):
    name = hal.findtext('name')
    fmt = hal.get('format', 'hidl')
    vers = [v.text for v in hal.findall('version')]
    vers += [(f.text or '').lstrip('@').split('::')[0] for f in hal.findall('fqname')]
    accept.setdefault((name, fmt), []).extend(v for v in vers if v)
def covered(want, ranges):
    # Matrix versions are "major.minor" or "major.minorLow-minorHigh"; AIDL uses a
    # bare integer or "low-high".
    for r in ranges:
        if r == want:
            return True
        m = re.match(r'^(\d+)\.(\d+)-(\d+)$', r)
        if m and re.match(r'^%s\.(\d+)$' % m.group(1), want):
            lo, hi = int(m.group(2)), int(m.group(3))
            if lo <= int(want.split('.')[1]) <= hi:
                return True
        m = re.match(r'^(\d+)-(\d+)$', r)
        if m and want.isdigit() and int(m.group(1)) <= int(want) <= int(m.group(2)):
            return True
    return False
bad = 0
for hal in root.findall('hal'):
    name = hal.findtext('name')
    fmt = hal.get('format', 'hidl')
    want = hal.findtext('version') or (hal.findtext('fqname') or '').lstrip('@')
    ranges = accept.get((name, fmt), [])
    if not ranges:
        print('    %-44s %-5s %-6s NOT IN THE MATRIX AT ALL' % (name, fmt, want))
        bad += 1
    elif not covered(want, ranges):
        print('    %-44s %-5s %-6s matrix has %s' % (name, fmt, want, ','.join(ranges)))
        bad += 1
    else:
        print('    %-44s %-5s %-6s ok (matrix: %s)' % (name, fmt, want, ','.join(ranges)))
if bad:
    print('    !! %d declared HAL(s) the level %s matrix does not accept.' % (bad, level))
    print('       check_vintf will call the device INCOMPATIBLE. Either lower')
    print('       target-level to one that lists them, or provide the version the')
    print('       matrix names.')
open(os.path.join(os.environ.get('EDGE1_WORK', '/tmp'), '.probe-fcm-bad'), 'w').write('%d\n' % bad)
PY_FCM

            # VNDK, which is deprecated in this release and says nothing about it.
            #
            #   ERROR: files are incompatible: Framework manifest and device
            #   compatibility matrix are incompatible: Vndk version 34 is not
            #   supported. Supported versions in framework manifest are: []
            #
            # An empty list, not a mismatched number. core/envsetup.mk:53-58 makes
            # KEEP_VNDK false whenever the release config sets
            # RELEASE_DEPRECATE_VNDK, and core/config.mk:1266-1273 then clears
            # BOARD_VNDK_VERSION and PLATFORM_VNDK_VERSION - assigned empty, no
            # warning. So a board that sets BOARD_VNDK_VERSION has it discarded, and
            # a device matrix that requires a VNDK version requires something the
            # framework no longer provides.
            echo "  --- VNDK: deprecated or kept in this release ---"
            if grep -rqs 'RELEASE_DEPRECATE_VNDK' "$TREE/build/release" 2>/dev/null; then
                grep -rhs -A 3 'RELEASE_DEPRECATE_VNDK' "$TREE/build/release" 2>/dev/null \
                    | grep -E 'RELEASE_DEPRECATE_VNDK|value|true|false' | head -8 | sed 's/^/    /' || true
            else
                echo "    RELEASE_DEPRECATE_VNDK appears nowhere in build/release"
            fi
            # Parsed, not grepped. A grep for '<vendor-ndk>' counted the
            # explanation in that file's own comment - the same trap the kernel
            # fragment had, where a comment naming a setting was read as the
            # setting. ElementTree does not see comments.
            vndk_req=$(python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    r = ET.parse(sys.argv[1]).getroot()
except Exception:
    print(0); raise SystemExit(0)
print(len(r.findall('vendor-ndk')))
" "$MANIFEST/device/khadas/edge/vintf/compatibility_matrix.xml" 2>/dev/null || echo 0)
            vndk_board=$(sed 's/#.*//' "$MANIFEST/device/khadas/edge/BoardConfig.mk" \
                         | grep -cE '^[[:space:]]*BOARD_VNDK_VERSION[[:space:]]*:?=' || true)
            echo "    device matrix requires a VNDK version: $vndk_req"
            echo "    BoardConfig.mk sets BOARD_VNDK_VERSION:  $vndk_board"
            if (( vndk_req > 0 )); then
                echo "    !! The device compatibility matrix requires a VNDK version. If this"
                echo "       release deprecates VNDK the framework provides none, and"
                echo "       check_vintf calls the device INCOMPATIBLE."
                echo "$vndk_req" > "$WORK/.probe-vndk-req"
            else
                echo "0" > "$WORK/.probe-vndk-req"
            fi
            if (( vndk_board > 0 )); then
                echo "    note: BOARD_VNDK_VERSION is set and is a no-op when VNDK is"
                echo "       deprecated - core/config.mk clears it without warning."
            fi
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
            EDGE1_WORK="$WORK" python3 - "$TREE" "$MANIFEST/device/khadas/edge/sepolicy/vendor" <<'PY_SEPOL'
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

# The direction this probe used to be blind to, and the one that cost a build.
#
# "borrowed" subtracts `ours`, so a type that BOTH AOSP and this tree declare
# never appeared anywhere in the output - it just looked locally declared. That is
# the fatal case: checkpolicy rejects a second declaration outright.
#
#   sysfs_types.te:8:ERROR 'Duplicate declaration of type' at token ';'
#   type sysfs_gpu, fs_type, sysfs_type;
#
# sysfs_gpu reads like a board type, so it was declared here; the platform needs
# it too and declares it first. Printing every type this device declares with
# whether AOSP has it makes that visible for all of them at once, rather than one
# per build.
dupes = sorted(t for t in ours if t in plat)
print('  --- every type this device declares ---')
for t in sorted(ours):
    print('    %-28s %s' % (t, 'ALSO IN AOSP - DUPLICATE' if t in plat else 'ours alone, ok'))
if dupes:
    print('  !! %d DUPLICATE declaration(s): %s' % (len(dupes), ' '.join(dupes)))
    print('     checkpolicy fails on each. Delete the local "type" line and keep')
    print('     labelling with it - borrowing a platform type is the normal case.')

# The same collision, one level down: a property this tree labels that the
# platform already labels.
#
#   host_init_verifier: Unable to serialize property contexts:
#   Duplicate exact match detected for 'ro.hardware.gralloc'
#
# ro.hardware.* is inside the prefixes a vendor partition may own, so
# check_prop_prefix passes it - but the platform labels those five properties
# already, because the code that reads them is platform code. Being allowed to own
# a prefix is not the same as the name being free. host_init_verifier stops at the
# first duplicate, so this lists all of them.
def prop_exact(root, skip_prebuilts):
    names = {}
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d != '.git' and not (skip_prebuilts and d == 'prebuilts')]
        if 'property_contexts' not in files:
            continue
        for raw in open(os.path.join(base, 'property_contexts'), errors='replace'):
            line = raw.split('#', 1)[0].split()
            if len(line) < 2 or 'exact' not in line:
                continue
            names.setdefault(line[0], os.path.join(base, 'property_contexts'))
    return names
ctx_dupes = []
plat_props = prop_exact(os.path.join(tree, 'system', 'sepolicy'), True)
our_props = prop_exact(sedir, False)
print('  --- property_contexts exact matches ---')
print('    system/sepolicy declares %d; this device declares %d'
      % (len(plat_props), len(our_props)))
prop_dupes = sorted(n for n in our_props if n in plat_props)
for n in sorted(our_props):
    where = plat_props.get(n)
    print('    %-30s %s' % (n, ('DUPLICATE, also in ' + where) if where else 'ours alone, ok'))
if prop_dupes:
    print('  !! %d DUPLICATE exact match(es): %s' % (len(prop_dupes), ' '.join(prop_dupes)))
    print('     host_init_verifier refuses to serialize the property contexts.')
    print('     Drop the line: the platform already labels it.')

# And once more for file_contexts and genfs_contexts.
#
#   file_contexts.concat.tmp: Multiple same specifications for /dev/video[0-9]*.
#   Error: could not load context file from ...
#
# The platform's file is concatenated with ours and compiled as one, and checkfc
# rejects the same specification twice. "Same specification" means the identical
# regex text, not an overlapping path - two different regexes matching one path is
# normal and the most specific wins - so this compares first fields verbatim.
def spec_first_fields(root, fname, skip_prebuilts):
    names = {}
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d != '.git' and not (skip_prebuilts and d == 'prebuilts')]
        if fname not in files:
            continue
        path = os.path.join(base, fname)
        for raw in open(path, errors='replace'):
            line = raw.split('#', 1)[0].split()
            if len(line) < 2:
                continue
            # genfscon lines are "genfscon <fs> <path> <context>"; the spec is the
            # filesystem and path together, since the same path under two
            # filesystems is not a duplicate.
            key = ' '.join(line[:3]) if line[0] == 'genfscon' else line[0]
            names.setdefault(key, path)
    return names
for fname in ('file_contexts', 'genfs_contexts'):
    plat_specs = spec_first_fields(os.path.join(tree, 'system', 'sepolicy'), fname, True)
    our_specs = spec_first_fields(sedir, fname, False)
    both = sorted(n for n in our_specs if n in plat_specs)
    print('  --- %s ---' % fname)
    print('    system/sepolicy declares %d specs; this device declares %d'
          % (len(plat_specs), len(our_specs)))
    for n in sorted(our_specs):
        print('    %-46s %s' % (n, 'DUPLICATE SPEC' if n in plat_specs else 'ours alone, ok'))
    if both:
        print('  !! %d DUPLICATE spec(s) in %s: %s' % (len(both), fname, ' '.join(both)))
        if fname == 'file_contexts':
            print('     checkfc refuses to load the concatenated file. Drop the line;')
            print('     the platform already labels it.')
        else:
            print('     Not gated on: a vendor genfscon is compiled into')
            print('     vendor_sepolicy.cil separately, and the run where checkfc')
            print('     rejected a file_contexts duplicate linked precompiled_sepolicy')
            print('     without complaining about any of these. Reported because a')
            print('     duplicate label is still redundant, and worth reading.')
    # Only file_contexts gates the run - that is the one this has been observed to
    # be fatal for.
    if fname == 'file_contexts':
        ctx_dupes += both
work = os.environ.get('EDGE1_WORK', '/tmp')
open(os.path.join(work, '.probe-sepol-dupes'), 'w').write('%d\n' % len(dupes))
open(os.path.join(work, '.probe-prop-dupes'), 'w').write('%d\n' % len(prop_dupes))
open(os.path.join(work, '.probe-ctx-dupes'), 'w').write('%d\n' % len(ctx_dupes))
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
    )

    log "written to $out ($(wc -l < "$out") lines)"
    # "MISSING AOSP" was the heading in an earlier version of this probe, so this
    # printed nothing at all - the one summary the pipeline shows on screen.
    sed -n '/^--- MISSING AND REQUESTED/,/^missing:/p' "$out"

    # The gates. Both of these are things the probe can answer in seconds and the
    # build answers in hours, so they stop the run here.
    local rc=0

    # A missing module is not a build error (see the note above), so it has to be
    # one here or it reaches the image as an absence.
    local miss_hard=0
    [[ -f "$WORK/.probe-miss-hard" ]] && miss_hard=$(cat "$WORK/.probe-miss-hard")
    if (( miss_hard > 0 )); then
        echo >&2
        echo "$miss_hard module(s) device.mk requests unconditionally do not exist in the tree." >&2
        echo "The build will not fail on them - it will drop them and produce an image without" >&2
        echo "them. Fix the names, or gate them behind EDGE1_ENABLE_INCOMPLETE_HALS, then re-run." >&2
        echo "Full probe: $out" >&2
        rc=1
    fi

    # A type this tree declares that system/sepolicy already declares. checkpolicy
    # stops on the first one, so a build only ever reveals one per run.
    local sepol_dupes=0
    [[ -f "$WORK/.probe-sepol-dupes" ]] && sepol_dupes=$(cat "$WORK/.probe-sepol-dupes")
    if (( sepol_dupes > 0 )); then
        echo >&2
        echo "$sepol_dupes sepolicy type(s) are declared both here and in system/sepolicy." >&2
        echo "checkpolicy calls that a duplicate declaration and fails the policy build." >&2
        sed -n '/DUPLICATE declaration/,+2p' "$out" >&2
        echo "Full probe: $out" >&2
        rc=1
    fi

    # A property this tree labels that the platform already labels exactly.
    # host_init_verifier stops at the first one, so the build reveals them one per
    # run - and it runs 20 minutes in, after sepolicy compiles.
    local prop_dupes=0
    [[ -f "$WORK/.probe-prop-dupes" ]] && prop_dupes=$(cat "$WORK/.probe-prop-dupes")
    if (( prop_dupes > 0 )); then
        echo >&2
        echo "$prop_dupes property name(s) are labelled both here and by system/sepolicy." >&2
        echo "host_init_verifier refuses to serialize the merged property contexts." >&2
        sed -n '/DUPLICATE exact match/,+2p' "$out" >&2
        echo "Full probe: $out" >&2
        rc=1
    fi

    # A file_contexts or genfs_contexts specification the platform already has.
    # checkfc stops at the first one, twenty minutes in.
    local ctx_dupes=0
    [[ -f "$WORK/.probe-ctx-dupes" ]] && ctx_dupes=$(cat "$WORK/.probe-ctx-dupes")
    if (( ctx_dupes > 0 )); then
        echo >&2
        echo "$ctx_dupes context specification(s) are declared both here and by system/sepolicy." >&2
        echo "checkfc refuses to load the concatenated context file." >&2
        sed -n '/DUPLICATE spec/,+2p' "$out" >&2
        echo "Full probe: $out" >&2
        rc=1
    fi

    # A HAL declared in the device manifest that the framework matrix at our
    # target-level does not list. check_vintf calls that INCOMPATIBLE, 15 minutes
    # into a build, and names the instances rather than the reason.
    local fcm_bad=0
    [[ -f "$WORK/.probe-fcm-bad" ]] && fcm_bad=$(cat "$WORK/.probe-fcm-bad")
    if (( fcm_bad > 0 )); then
        echo >&2
        echo "$fcm_bad HAL(s) in vintf/manifest.xml are not accepted by the framework" >&2
        echo "compatibility matrix at this manifest's target-level." >&2
        sed -n '/declared HAL(s) the level/,+3p' "$out" >&2
        echo "Full probe: $out" >&2
        rc=1
    fi

    # A VNDK version required by the device compatibility matrix. The framework
    # provides none while VNDK is deprecated, and check_vintf says so 10 minutes in.
    local vndk_req=0
    [[ -f "$WORK/.probe-vndk-req" ]] && vndk_req=$(cat "$WORK/.probe-vndk-req")
    if (( vndk_req > 0 )); then
        echo >&2
        echo "The device compatibility matrix requires a VNDK version." >&2
        echo "VNDK is deprecated in this release: BOARD_VNDK_VERSION and" >&2
        echo "PLATFORM_VNDK_VERSION are cleared by core/config.mk:1266-1273 and the" >&2
        echo "framework manifest provides no version to match. Drop the <vendor-ndk>" >&2
        echo "requirement from vintf/compatibility_matrix.xml." >&2
        echo "Full probe: $out" >&2
        rc=1
    fi

    return $rc
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
    for t in git git-lfs repo python3 java make ccache aarch64-linux-gnu-gcc \
             sgdisk pigz dtc; do
        printf '%-8s %s\n' "$t" "$(command -v $t 2>/dev/null || echo MISSING)"
    done
    echo "ninja:      $([[ -x $TREE/prebuilts/build-tools/linux-x86/bin/ninja ]] \
        && echo 'tree prebuilt (the one the build uses)' || echo 'tree prebuilt MISSING')"
    echo "git-lfs:    $(git lfs version 2>&1 | head -1)"
    echo "repo ver:   $(repo --version 2>&1 | head -2 | tr '\n' ' ')"
    # Read the cache build.sh actually uses ($TREE/out/ccache), not ccache's
    # default $HOME/.cache/ccache - which is empty, and unwritable under the
    # build sandbox.
    echo "ccache dir: $TREE/out/ccache $([[ -d $TREE/out/ccache ]] && echo present || echo '(not created yet)')"
    echo "ccache:     $(CCACHE_DIR="$TREE/out/ccache" ccache -s 2>/dev/null | head -4 | tr '\n' ' ')"
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
    echo "--- kernel checkout ---"
    # In the report rather than in the probe, because the probe is what died last
    # run and this is the fact the whole stage depends on. A manifest can sync
    # "successfully" without the project having landed where the build looks.
    local kdir="$TREE/kernel/mainline"
    if [[ -d "$kdir/.git" ]]; then
        echo "path:       $kdir"
        echo "revision:   $(git -C "$kdir" describe --tags --always 2>&1 | head -1)"
        echo "version:    $(grep -hE '^(VERSION|PATCHLEVEL|SUBLEVEL) =' "$kdir/Makefile" 2>/dev/null | tr -d ' ' | tr '\n' ' ')"
        echo "board dts:  $(ls "$kdir/arch/arm64/boot/dts/rockchip/" 2>/dev/null | grep -c khadas) khadas dts files"
        echo "Image:      $([[ -f $kdir/out/arch/arm64/boot/Image ]] && du -h "$kdir/out/arch/arm64/boot/Image" | cut -f1 || echo 'not built')"
        echo "staged dtb: $(ls "$kdir/out/android-dtb/" 2>/dev/null | tr '\n' ' ' || echo 'none')"
    elif [[ -d "$kdir" ]]; then
        echo "$kdir exists but is not a git checkout - the sync did not land it"
    else
        echo "ABSENT at $kdir - repo sync did not fetch it"
    fi
    echo
    # Both of these used to be files the user had to find and send separately,
    # which is why a round went by with a stale probe and no one noticed. The
    # report is the one thing that gets sent, so the answers belong in it.
    echo "##### MODULE PROBE #####"
    if [[ -f "$WORK/module-probe.txt" ]]; then
        # 400 used to be the cap, and the sections that gate the run - the sepolicy
        # type and property collisions - are the last thing the probe writes, so
        # the report cut off exactly the part that answered the question twice in
        # a row. The whole file goes in; it is 500 lines, not 50000.
        echo "($(wc -l < "$WORK/module-probe.txt") lines total)"
        cat "$WORK/module-probe.txt" 2>&1 || true
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
        # The age matters: a stage that did not run leaves its log from the last time
        # it did, and two reports running were read as if a fixed error had come
        # back.
        echo "===== $(basename "$f")  (${total} lines, written $(date -r "$f" '+%H:%M:%S' 2>/dev/null), $(( ( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || date +%s) ) / 60 )) min ago) ====="
        # The pattern list earns its keep only if it catches the FIRST real
        # error. It missed the kernel's actual failure once already: Rockchip's
        # gcc-wrapper.py prints "error, forbidden warning:file.c:398" - a comma,
        # not a colon - and make prints "*** [...] Error 1", so a 2727-line log
        # reported a single unrelated grep warning and nothing else.
        # One flat pattern list with one budget failed on a 143k-line platform
        # log: "ERROR" matched the ALOGE macro echoed in every -Wall warning
        # context, "error[:,]" matched the crate name "thiserror:", and the
        # 200-line budget was spent by line 6000 - so the report never reached the
        # one FAILED: line at 143395 and said nothing about the real failure.
        #
        # Three tiers with their own budgets instead, decisive markers first, and
        # the word patterns anchored so they cannot match inside an identifier.
        echo "--- [1] the verdict: what ninja, kati or make actually refused ---"
        grep -nE '^FAILED:|^ninja: build stopped|ninja failed with|failed to build some targets|\*\*\* No rule to make target|^make(\[[0-9]+\])?: \*\*\* |error, forbidden warning' \
            "$f" 2>/dev/null | head -60 || true
        # The tool output that explains a FAILED: line follows it. Print that
        # window for the first one - it is almost always the whole diagnosis.
        local first_failed
        first_failed=$(grep -nE '^FAILED:' "$f" 2>/dev/null | head -1 | cut -d: -f1)
        if [[ -n "${first_failed:-}" ]]; then
            echo "--- [1a] context around the first FAILED: (line $first_failed) ---"
            sed -n "$((first_failed > 3 ? first_failed - 3 : 1)),$((first_failed + 30))p" "$f" 2>/dev/null
        fi
        echo "--- [2] compiler and tool errors (first 40, last 40) ---"
        # Every part of this pattern is load-bearing:
        #   (^|[^[:alnum:]_])  keeps "thiserror:" out - a real diagnostic has a
        #                      space, a colon or a line start in front.
        #   error: / ERROR:    with the colon. Bare "ERROR" matched the ALOGE
        #                      macro in every warning context, and aidl's
        #                      -Wredundant-name warnings quote enumerators like
        #                      'ERROR_UNKNOWN' hundreds of times.
        # The filter then drops lines that announce themselves as warnings, which
        # is how "WARNING: ... has a redundant substring 'ERROR'" stops competing
        # with the failure for the budget.
        local tier2
        tier2=$(grep -nE '(^|[^[:alnum:]_])(fatal )?error:|(^|[^[:alnum:]_])ERROR:|internal compiler error|multiple definition|collect2:|undefined reference' \
                "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*(WARNING|Warning)[:[:space:]]' || true)
        if [[ -n "$tier2" ]]; then
            local n2; n2=$(wc -l <<< "$tier2")
            head -40 <<< "$tier2"
            if (( n2 > 80 )); then
                echo "    ... $(( n2 - 80 )) more ..."
                tail -40 <<< "$tier2"
            elif (( n2 > 40 )); then
                tail -n "$(( n2 - 40 ))" <<< "$tier2"
            fi
        else
            echo "(none)"
        fi
        echo "--- [3] environment: the build dying rather than rejecting code ---"
        grep -nE 'Killed|[Oo]ut of memory|No space left|Read-only file system|Permission denied|Segmentation fault|Cannot allocate memory|Bus error' \
            "$f" 2>/dev/null | head -40 || true
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
    uboot)     stage_uboot ;;
    build)     stage_build ;;
    sdimage)   stage_sdimage ;;
    aidl)      stage_aidl ;;
    probe)     stage_probe ;;
    report)    stage_report ;;
    all)       stage_deps; stage_clone; stage_preflight; stage_sync
               stage_kernel; stage_uboot; stage_build; stage_sdimage ;;
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
