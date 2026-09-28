#!/usr/bin/env bash
#
# Khadas Edge1 Android TV 14 - host preflight.
#
# Run this before sync.sh. An AOSP 14 build fails late and confusingly when the
# host is short of disk or RAM: ninja dies with "no space left on device" after
# several hours, or the JVM is OOM-killed during R8 with no useful message. The
# thresholds below are checked up front so that never happens silently.
#
# Exit 0 = ready, 1 = a hard requirement is unmet, 2 = ready but degraded.

set -uo pipefail

# --- Requirements -------------------------------------------------------------
# Disk is three requirements, not one, because what is still needed depends on
# what is already on the filesystem. The checkout is ~120GiB and the output tree
# for one userdebug target is ~150GiB, so a bare host needs 250GiB free - but once
# both are in place that space is no longer free, by definition. Asking for it
# anyway is a requirement that can never be met again after the work is done, and
# that is not a theoretical objection: a run was stopped by
#
#   FAIL disk  183GiB free, need >= 250GiB
#
# on a host whose tree was synced, whose build had completed, and which only had to
# rebuild a few images. 183GiB was ample for that.
readonly DISK_MIN_GIB=250        # nothing synced yet: checkout plus output
readonly DISK_REC_GIB=350
readonly DISK_SYNCED_GIB=140     # tree present, output still to build
readonly DISK_SYNCED_REC_GIB=200
# An incremental rebuild, the images, the 7GiB card image and its compressed copy.
readonly DISK_BUILT_GIB=40
readonly DISK_BUILT_REC_GIB=80
# Android 14's build needs 16GiB to link and run R8; 64GiB is Google's own
# recommendation for a full platform build.
readonly RAM_MIN_GIB=16
readonly RAM_REC_GIB=64
readonly CORES_REC=8

hard_fail=0
soft_fail=0

pass()  { printf '  \033[32mPASS\033[0m  %-22s %s\n' "$1" "$2"; }
warn()  { printf '  \033[33mWARN\033[0m  %-22s %s\n' "$1" "$2"; soft_fail=1; }
fail()  { printf '  \033[31mFAIL\033[0m  %-22s %s\n' "$1" "$2"; hard_fail=1; }

echo "Khadas Edge1 / Android TV 14 - host preflight"
echo

# --- Disk ---------------------------------------------------------------------
# Checks the filesystem holding the tree, not /, since they are often different.
readonly TREE_DIR="${1:-$PWD}"

# Which of the three requirements applies. The caller passes the parent directory
# (provision-wsl.sh passes $WORK), so the checkout is looked for both there and at
# the conventional path under it; a second argument names it outright.
aosp=
for c in "${2:-}" "$TREE_DIR" "$TREE_DIR/aosp-14-edge1"; do
    [[ -n "$c" && -d "$c/.repo" ]] && aosp="$c"
done
if [[ -z "$aosp" ]]; then
    disk_need=$DISK_MIN_GIB; disk_rec=$DISK_REC_GIB
    disk_why="nothing synced yet: a ~120GiB checkout plus ~150GiB of build output"
elif [[ -f "$aosp/out/target/product/edge/system.img" ]]; then
    disk_need=$DISK_BUILT_GIB; disk_rec=$DISK_BUILT_REC_GIB
    disk_why="tree and a built out/ are already here; this is what an incremental rebuild, the images and the card image still need"
else
    disk_need=$DISK_SYNCED_GIB; disk_rec=$DISK_SYNCED_REC_GIB
    disk_why="tree is synced; this is what the build output still needs"
fi

avail_gib=$(df -BG --output=avail "$TREE_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -z "$avail_gib" ]]; then
    warn "disk" "could not determine free space on $TREE_DIR"
elif (( avail_gib < disk_need )); then
    fail "disk" "${avail_gib}GiB free on $TREE_DIR, need >= ${disk_need}GiB - $disk_why"
elif (( avail_gib < disk_rec )); then
    warn "disk" "${avail_gib}GiB free, >= ${disk_need}GiB needed and ${disk_rec}GiB comfortable - $disk_why"
else
    pass "disk" "${avail_gib}GiB free on $TREE_DIR (needs ${disk_need}GiB: $disk_why)"
fi

# --- RAM ----------------------------------------------------------------------
ram_gib=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null)
if [[ -z "$ram_gib" ]]; then
    warn "ram" "could not read /proc/meminfo"
elif (( ram_gib < RAM_MIN_GIB )); then
    fail "ram" "${ram_gib}GiB, below the ${RAM_MIN_GIB}GiB minimum; soong/R8 will be OOM-killed"
elif (( ram_gib < RAM_REC_GIB )); then
    warn "ram" "${ram_gib}GiB; ${RAM_REC_GIB}GiB recommended. Cap parallelism (m -j$((ram_gib/4))) to avoid OOM"
else
    pass "ram" "${ram_gib}GiB"
fi

# --- Swap: the usual rescue for a 16-32GiB host -------------------------------
swap_gib=$(awk '/SwapTotal/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null)
if (( ${ram_gib:-0} < RAM_REC_GIB )) && (( ${swap_gib:-0} < 8 )); then
    warn "swap" "${swap_gib:-0}GiB swap with ${ram_gib}GiB RAM; add >= 8GiB or expect OOM kills"
else
    pass "swap" "${swap_gib:-0}GiB"
fi

# --- CPU ----------------------------------------------------------------------
cores=$(nproc 2>/dev/null || echo 0)
if (( cores < CORES_REC )); then
    # Not fatal, just slow: a 4-core host takes 15-25h for a full build.
    warn "cpu" "${cores} cores; a full build takes roughly $(( 96 / (cores>0?cores:1) ))h at this width"
else
    pass "cpu" "${cores} cores"
fi

# --- Tools --------------------------------------------------------------------
for tool in git python3 curl unzip zip rsync bc make; do
    if command -v "$tool" >/dev/null 2>&1; then
        pass "tool:$tool" "$(command -v "$tool")"
    else
        fail "tool:$tool" "not found"
    fi
done

if command -v repo >/dev/null 2>&1; then
    pass "tool:repo" "$(command -v repo)"
else
    fail "tool:repo" "not found; install from https://storage.googleapis.com/git-repo-downloads/repo"
fi

if command -v ccache >/dev/null 2>&1; then
    pass "tool:ccache" "$(command -v ccache) (build.sh sets USE_CCACHE, CCACHE_EXEC and CCACHE_DIR=\$TREE/out/ccache)"
else
    warn "tool:ccache" "not found; rebuilds will be much slower"
fi

# AOSP 14 ships its own JDK in prebuilts/jdk, so a host JDK is not required.
# Noted rather than checked, because people expect to see it.
if command -v java >/dev/null 2>&1; then
    java_ver=$(java -version 2>&1 | grep -viE 'JAVA_TOOL_OPTIONS|Picked up' | head -1)
    pass "tool:java" "${java_ver:-present} (AOSP uses prebuilts/jdk regardless)"
fi

# --- Network ------------------------------------------------------------------
# A blocked AOSP host is the failure that wastes the most time, because repo
# init appears to hang rather than refuse.
#
# Probed with git ls-remote, not curl: what matters is whether git can read the
# remote. A plain HTTPS GET to a git host can return 400 or 403 through a
# corporate or sandbox proxy while git traffic to the same host works, so a curl
# probe produces false failures.
check_git_host() {
    local url="$1" label="$2" out
    if out=$(GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$url" 2>&1 >/dev/null); then
        pass "net:$label" "git read OK"
        return
    fi
    if grep -qiE '403|denied|blocked|tunnel failed' <<<"$out"; then
        fail "net:$label" "refused by a proxy or network policy, not by credentials: ${out##*: }"
    else
        fail "net:$label" "git read failed: ${out##*: }"
    fi
}
check_git_host "https://android.googlesource.com/platform/build" "aosp"
check_git_host "https://github.com/khadas/android_device_rockchip_rk3399" "khadas"

echo
if (( hard_fail )); then
    echo "RESULT: not ready. Resolve every FAIL above before running sync.sh."
    exit 1
elif (( soft_fail )); then
    echo "RESULT: ready, but degraded. The build will work; see the WARNs."
    exit 2
fi
echo "RESULT: ready."
exit 0
