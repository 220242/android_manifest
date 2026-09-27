#!/usr/bin/env bash
#
# Khadas Edge1 Android TV 14 - sync an AOSP 14 tree with the Khadas overlay.
#
# Run preflight.sh first.
#
#   usage: sync.sh [tree-dir] [aosp-tag]
#
set -euo pipefail

readonly TREE="${1:-$HOME/aosp-14-edge1}"
# Verified to exist: the android-14.0.0_r* series runs r1..r75, confirmed by
# listing aosp-mirror/platform_manifest (a GitHub mirror of the AOSP manifest)
# because android.googlesource.com was unreachable from the authoring
# environment. r75 was the newest at the time.
#
# build/windows/provision-wsl.sh resolves the newest tag at run time instead of
# using this default; override here with argument 2.
readonly AOSP_TAG="${2:-android-14.0.0_r75}"
readonly MANIFEST_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "tree:     $TREE"
echo "aosp tag: $AOSP_TAG"
echo "overlay:  $MANIFEST_REPO_DIR/manifests/khadas_edge_tv14.xml"
echo

mkdir -p "$TREE"
cd "$TREE"

# Before repo touches anything: the projects this manifest used to carry on the
# Android 10 BSP path.
#
# Order matters here, and getting it wrong was the first version of this. repo
# deletes a project that has left the manifest only if its checkout is clean, and
# the old kernel is not - it has an out/ directory from having been built - so a
# sync would have stopped on "cannot remove project: uncommitted changes are
# present" for the one path that most needed removing. Doing it first also frees
# 20-odd GiB before the new kernel is fetched rather than after.
for stale in kernel/khadas hardware/rockchip vendor/rockchip u-boot RKTools; do
    if [[ -e "$TREE/$stale" ]]; then
        echo "removing $stale ($(du -sh "$TREE/$stale" 2>/dev/null | cut -f1), Android 10 BSP path, no longer in the manifest)"
        rm -rf "$TREE/$stale"
    fi
done

# repo init against upstream AOSP, not a Khadas fork of the whole platform.
# The Android 10 manifest forked all 737 projects; tracking upstream instead
# means AOSP security patches arrive with a tag bump rather than 737 merges.
repo init -u https://android.googlesource.com/platform/manifest \
          -b "$AOSP_TAG" \
          --depth=1 \
          --git-lfs

mkdir -p .repo/local_manifests
cp "$MANIFEST_REPO_DIR/manifests/khadas_edge_tv14.xml" .repo/local_manifests/

# -c: current branch only. --no-clone-bundle: the bundles are often slower than a
# direct fetch and cost extra disk.
#
# -j4, not -j$(nproc): android.googlesource.com rate-limits aggressive clients and
# answers HTTP 429 / RESOURCE_EXHAUSTED. At -j8 that reliably knocked out a
# handful of projects per pass. Sync is network-bound anyway, so a wider -j buys
# nothing once the server starts refusing.
#
# --force-sync: after a failed pass some projects are left with a checkout that
# does not match the manifest, and plain sync then refuses to touch them. Without
# it, one bad project blocks every later attempt.
readonly SYNC_JOBS=4

for attempt in 1 2 3 4; do
    jobs=$SYNC_JOBS
    extra=()
    if (( attempt == 4 )); then
        # Last pass: serial and stop at the first error, so the log names one
        # real cause instead of a list of rate-limit casualties.
        jobs=1
        extra+=(--fail-fast)
        echo "final attempt: -j1 --fail-fast for a single clear error" >&2
    fi
    if repo sync -c --no-clone-bundle --optimized-fetch --prune --force-sync \
                 -j"$jobs" "${extra[@]}"; then
        break
    fi
    if (( attempt == 4 )); then
        echo "repo sync failed after 4 attempts" >&2
        exit 1
    fi
    # Longer backoff than the usual 2/4/8: a 429 is a rate limit with a cooldown,
    # and retrying after two seconds just collects another one.
    delay=$(( 30 * attempt ))
    echo "repo sync failed, retrying in ${delay}s (attempt $attempt/4)" >&2
    sleep "$delay"
done


# The device tree lives in this manifest repo rather than in a repo of its own,
# so it is placed into the tree rather than synced. This was a symlink, which is
# exactly why the first build could not find the product: Soong's finder writes
# out/.module_paths/AndroidProducts.mk.list by walking the tree and does not
# descend into symlinked directories, so nothing in the device tree was visible
# to it. See build/place-device.sh.
"$MANIFEST_REPO_DIR/build/place-device.sh" "$TREE"

# device/google/atv carries atv_base.mk and is what makes this an Android TV
# build. edge1_tv.mk errors out without it, so check now rather than at lunch.
if [[ ! -f "$TREE/device/google/atv/products/atv_base.mk" ]]; then
    echo "WARNING: device/google/atv/products/atv_base.mk is missing." >&2
    echo "         Android TV cannot be built without it. Check that the AOSP" >&2
    echo "         manifest for $AOSP_TAG includes device/google/atv." >&2
fi

echo
echo "synced. next: build/build-kernel.sh $TREE && build/build.sh $TREE"
