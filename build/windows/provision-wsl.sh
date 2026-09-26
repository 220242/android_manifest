#!/usr/bin/env bash
#
# Khadas Edge1 / Android TV 14 - provisioning inside WSL2.
#
# Called by Start-EdgeBuild.ps1. Kept as a separate bash file rather than inlined
# into the PowerShell script because nesting bash inside `wsl -- bash -lc "..."`
# makes quoting unreadable and is a common source of silent breakage.
#
#   usage: provision-wsl.sh <stage>
#   stages: deps | clone | preflight | sync | aidl | kernel | build | all
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

stage_deps() {
    log "installing AOSP build dependencies"
    export DEBIAN_FRONTEND=noninteractive
    sudo -E apt-get update -qq
    # The canonical AOSP list, plus repo's own needs. python-is-python3 matters:
    # several AOSP scripts still invoke bare `python`.
    sudo -E apt-get install -y -qq \
        git-core gnupg flex bison build-essential zip curl zlib1g-dev \
        libc6-dev-i386 x11proto-dev libx11-dev lib32z1-dev libgl1-mesa-dev \
        libxml2-utils xsltproc unzip fontconfig python3 python3-pip \
        python-is-python3 rsync ccache bc lz4 libssl-dev \
        device-tree-compiler openjdk-17-jdk-headless
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
    log "building the 4.19.111 kernel"
    "$MANIFEST/build/build-kernel.sh" "$TREE" 2>&1 | tee "$LOGS/kernel.log"
}

stage_build() {
    log "building the platform (expect many hours)"
    "$MANIFEST/build/build.sh" "$TREE" userdebug 2>&1 | tee "$LOGS/platform.log"
    local img="$TREE/out/target/product/edge/rockdev/update.img"
    if [[ -f "$img" ]]; then
        mkdir -p "$WORK/output"
        cp "$img" "$WORK/output/"
        log "update.img copied to $WORK/output/"
    else
        echo "no update.img produced; see $LOGS/platform.log" >&2
        return 1
    fi
}

stage_aidl() {
    log "dumping the real AIDL method surface for every declared HAL"
    # This is what unblocks the unwritten composer3 / tv.input / hdmi.cec shims:
    # their signatures could not be verified when the tree was authored, because
    # hardware/interfaces is not in any reachable mirror. Now that a real tree is
    # synced, read them from it.
    "$MANIFEST/build/verify-aidl-surface.sh" "$TREE" > "$WORK/aidl-surface.txt" 2>&1 || true
    log "written to $WORK/aidl-surface.txt ($(wc -l < "$WORK/aidl-surface.txt") lines)"
    echo "From Windows: \\\\wsl.localhost\\Edge1Build\\home\\builder\\android_khadas\\aidl-surface.txt"
}

case "$STAGE" in
    deps)      stage_deps ;;
    clone)     stage_clone ;;
    preflight) stage_preflight ;;
    sync)      stage_sync ;;
    kernel)    stage_kernel ;;
    build)     stage_build ;;
    aidl)      stage_aidl ;;
    all)       stage_deps; stage_clone; stage_preflight; stage_sync
               stage_kernel; stage_build ;;
    *)         echo "unknown stage: $STAGE" >&2; exit 2 ;;
esac
