#!/usr/bin/env bash
#
# Patches on top of synced projects, from device/khadas/edge/patches/<path>/*.patch,
# where <path> is the project's path in the tree (external/ffmpeg, ...). Each patch
# says in its header why it exists; the project is used as pinned in the manifest
# apart from them. Kept as patches because this repository is the only one the
# build owns - the projects are other people's.
#
# Same scheme as the kernel's (build-kernel.sh): applied to the working tree in
# name order, with a copy of the applied set in <project>/.edge1-patches/, so a
# changed or removed patch is first reverted from its old copy and the project is
# always the pinned commit plus exactly the current set. Nothing happens while the
# set is unchanged. A patch that does not apply stops here - the build would only
# fail later, further from the cause.
#
# Moving a project to another pinned revision in the manifest: repo sync will not
# check out over the patched working tree, so first put it back -
#   git -C <tree>/<path> checkout . && git -C <tree>/<path> clean -fdx
# - and refresh the patches against the new revision.
#
#   usage: build/apply-patches.sh <tree-dir>        (place-device.sh runs it)
set -euo pipefail
readonly TREE="${1:?usage: apply-patches.sh <tree-dir>}"
readonly PATCHES="$TREE/device/khadas/edge/patches"

[[ -d "$PATCHES" ]] || exit 0

# Every directory under patches/ that holds .patch files is a project path.
while IFS= read -r dir; do
    rel="${dir#"$PATCHES"/}"
    project="$TREE/$rel"
    if ! git -C "$project" rev-parse --git-dir > /dev/null 2>&1; then
        echo "apply-patches: $rel is not in the tree (not synced?); its patches are skipped"
        continue
    fi
    applied="$project/.edge1-patches"
    want=() have=()
    while IFS= read -r p; do want+=("$p"); done < <(find "$dir" -maxdepth 1 -name '*.patch' | sort)
    [[ -d "$applied" ]] && while IFS= read -r p; do have+=("$p"); done \
        < <(find "$applied" -maxdepth 1 -name '*.patch' | sort)

    same=1
    if (( ${#want[@]} != ${#have[@]} )); then
        same=0
    else
        for i in "${!want[@]}"; do
            [[ "$(basename "${want[$i]}")" == "$(basename "${have[$i]}")" ]] \
                && cmp -s "${want[$i]}" "${have[$i]}" || same=0
        done
    fi
    if (( same )); then
        echo "apply-patches: $rel: ${#want[@]} applied, unchanged"
        continue
    fi

    for (( i=${#have[@]}-1; i>=0; i-- )); do
        echo "apply-patches: $rel: reverting $(basename "${have[$i]}")"
        git -C "$project" apply -R "${have[$i]}" || {
            echo "apply-patches: could not revert ${have[$i]}; restore it with" \
                 "git -C $project checkout . && git -C $project clean -fd" >&2
            exit 1; }
    done
    rm -rf "$applied"
    mkdir -p "$applied"
    for p in "${want[@]}"; do
        echo "apply-patches: $rel: applying $(basename "$p")"
        git -C "$project" apply "$p" || {
            echo "apply-patches: $(basename "$p") does not apply to $rel" >&2
            exit 1; }
        cp "$p" "$applied/"
    done
done < <(find "$PATCHES" -name '*.patch' -printf '%h\n' | sort -u)
