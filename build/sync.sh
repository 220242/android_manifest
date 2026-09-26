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
# NOTE: verify this tag exists before relying on it -
#   git ls-remote --tags https://android.googlesource.com/platform/manifest 'android-14.0.0_r*'
# It could not be verified when this script was written because the AOSP host was
# unreachable from that environment (see docs/STATUS.md). Override with argument 2.
readonly AOSP_TAG="${2:-android-14.0.0_r50}"
readonly MANIFEST_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "tree:     $TREE"
echo "aosp tag: $AOSP_TAG"
echo "overlay:  $MANIFEST_REPO_DIR/manifests/khadas_edge_tv14.xml"
echo

mkdir -p "$TREE"
cd "$TREE"

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
# direct fetch and cost extra disk. -j is deliberately modest; android.googlesource
# throttles aggressive clients and the retry loop below costs more than it saves.
for attempt in 1 2 3 4; do
    if repo sync -c --no-clone-bundle --optimized-fetch --prune -j"$(( $(nproc) > 8 ? 8 : $(nproc) ))"; then
        break
    fi
    if (( attempt == 4 )); then
        echo "repo sync failed after 4 attempts" >&2
        exit 1
    fi
    delay=$(( 2 ** attempt ))
    echo "repo sync failed, retrying in ${delay}s (attempt $attempt/4)" >&2
    sleep "$delay"
done

# The device tree lives in this manifest repo rather than in a repo of its own,
# so it is linked into place rather than synced. A symlink (not a copy) keeps
# edits in one place and under version control.
mkdir -p "$TREE/device/khadas"
if [[ ! -e "$TREE/device/khadas/edge" ]]; then
    ln -s "$MANIFEST_REPO_DIR/device/khadas/edge" "$TREE/device/khadas/edge"
    echo "linked device/khadas/edge -> $MANIFEST_REPO_DIR/device/khadas/edge"
fi

# device/google/atv carries atv_base.mk and is what makes this an Android TV
# build. edge1_tv.mk errors out without it, so check now rather than at lunch.
if [[ ! -f "$TREE/device/google/atv/products/atv_base.mk" ]]; then
    echo "WARNING: device/google/atv/products/atv_base.mk is missing." >&2
    echo "         Android TV cannot be built without it. Check that the AOSP" >&2
    echo "         manifest for $AOSP_TAG includes device/google/atv." >&2
fi

echo
echo "synced. next: build/build-kernel.sh $TREE && build/build.sh $TREE"
