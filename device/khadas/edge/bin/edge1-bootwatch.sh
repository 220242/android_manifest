#!/system/bin/sh
#
# Khadas Edge1 - bring-up boot watchdog and log recorder, userdebug only
# (init.edge1.rc starts it on "boot" when ro.debuggable=1).
#
# The board has no serial console. Two things make up for it:
#
# 1. The whole log, on the card. The card's first partition (bootfs) is the FAT that
#    Windows shows as EDGE1BOOT. This script mounts it and, for as long as the board
#    runs, streams into edge1-logs/boot-0/:
#      logcat.txt   main, system, crash and events, from the start of logd's buffers
#      dmesg.txt    the kernel log, from the first line of the boot
#    Both are complete: they start with everything already buffered and follow from
#    there, so nothing scrolls away, however fast a crash loop logs (the tenth card
#    produced 85KB/s of logcat, which filled a 2MiB buffer in 20 seconds). Data is
#    synced every SYNC seconds, so a sudden reset loses at most that much - and the
#    last seconds before a panic are in edge1-pstore.bin anyway.
#    Beside them, a snapshot of the system's state (getprop, ps, mounts, services,
#    SurfaceFlinger) in a subdirectory named for when it was taken:
#      120s       two minutes after "boot", whatever state Android is in
#      completed  30s after sys.boot_completed, if it ever gets there
#      timeout    TIMEOUT (300) seconds after "boot" without sys.boot_completed
#    The boot before is kept as boot-1, so after a watchdog reboot the card holds
#    both the hung boot and the one that followed.
#
# 2. A warm reboot instead of a hang. If Android has not set sys.boot_completed
#    within TIMEOUT seconds, reboot - warm, so ramoops survives and the card's boot
#    script saves it as edge1-pstore.bin. Before this, the only way out of a hung
#    boot was the power switch, which empties RAM and the log with it.
#
# 300s: system_server reaches the package manager about 60s after power-on and the
# first boot of a preopted build completes in a few minutes, so a boot that has not
# finished by then is stuck, and five minutes of its log say why. (It was 600s;
# halving it halves the wait for each card.) For a boot that needs longer - a
# first boot that compiles apps, say - setprop persist.vendor.edge1.bootwatch.timeout
# <seconds>; setprop persist.vendor.edge1.bootwatch 0 disables the reboot (not the
# logs).
TIMEOUT=300
t_prop="$(getprop persist.vendor.edge1.bootwatch.timeout)"
case "$t_prop" in ''|*[!0-9]*) ;; *) [ "$t_prop" -ge 60 ] && TIMEOUT=$t_prop ;; esac
TIMEOUT=$(( (TIMEOUT + 9) / 10 * 10 ))
SYNC=10
DEV=/dev/block/by-name/bootfs
MNT=/mnt/vendor/edge1-bootfs
LOGS=$MNT/edge1-logs
OUT=$LOGS/boot-0
# Below this much free space the streams stop: U-Boot must still be able to rewrite
# edge1-pstore.bin and edge1-boot.log on the next boot. boot-1 goes first.
STOP_FREE_KIB=65536
KEEP_FREE_KIB=131072

log() { echo "edge1-bootwatch: $*" > /dev/kmsg; }

# Free space on the mounted FAT, in KiB; large if df cannot say, so a df problem
# does not cost the logs.
avail_kib() { set -- $(df -k "$MNT" | tail -n 1); echo "${4:-999999}"; }

completed() { [ "$(getprop sys.boot_completed)" = 1 ]; }

streams=
start_streams() {
    logcat -b main,system,crash,events -v threadtime > "$OUT/logcat.txt" 2>&1 &
    streams="$!"
    dmesg -w > "$OUT/dmesg.txt" 2>&1 &
    streams="$streams $!"
}
stop_streams() {
    [ -n "$streams" ] && kill $streams 2>/dev/null
    streams=
}

# $1: subdirectory of boot-0.
snapshot() {
    s="$OUT/$1"
    mkdir -p "$s"
    getprop > "$s/getprop.txt" 2>&1
    ps -A -o PID,PPID,USER,STAT,TIME,LABEL,NAME > "$s/ps.txt" 2>&1
    { cat /proc/uptime; echo; cat /proc/mounts; echo; ls -l /dev/block/by-name; } \
        > "$s/misc.txt" 2>&1
    timeout 20 dumpsys -l > "$s/services.txt" 2>&1
    timeout 20 dumpsys SurfaceFlinger > "$s/surfaceflinger.txt" 2>&1
    sync
    log "state written to EDGE1BOOT:edge1-logs/boot-0/$1"
}

finish() {
    stop_streams
    sync
    umount "$MNT" || log "cannot unmount $MNT"
}
trap 'finish; exit 0' TERM INT

# A few properties the log needs to be read against, in the kernel log too, so
# edge1-pstore.bin has them even when the card does not.
log "sys.use_memfd=$(getprop sys.use_memfd) ro.treble.enabled=$(getprop ro.treble.enabled)" \
    "ro.vndk.version=$(getprop ro.vndk.version) ro.build.fingerprint=$(getprop ro.build.fingerprint)"

mounted=
mkdir -p "$MNT" && mount -t vfat -o rw,noatime "$DEV" "$MNT" && mounted=1
[ -n "$mounted" ] || log "cannot mount $DEV; no logs on the card this boot"

if [ -n "$mounted" ]; then
    # Only a boot that wrote something displaces boot-1, so a boot that dies before
    # this point does not cost the one before it its logs.
    if [ -d "$OUT" ]; then
        rm -rf "$LOGS/boot-1"
        mv "$OUT" "$LOGS/boot-1"
    fi
    [ "$(avail_kib)" -lt "$KEEP_FREE_KIB" ] && rm -rf "$LOGS/boot-1"
    mkdir -p "$OUT"
    if [ "$(avail_kib)" -lt "$STOP_FREE_KIB" ]; then
        log "EDGE1BOOT is nearly full; no logs written"
    else
        start_streams
        log "streaming logcat and dmesg to EDGE1BOOT:edge1-logs/boot-0"
    fi
fi

t=0
done_at=
while :; do
    sleep "$SYNC"
    t=$((t + SYNC))
    if [ -n "$mounted" ]; then
        sync
        if [ -n "$streams" ] && [ "$(avail_kib)" -lt "$STOP_FREE_KIB" ]; then
            stop_streams
            sync
            log "EDGE1BOOT is nearly full; logging to the card stopped"
        fi
        [ $t -eq 120 ] && snapshot 120s
    fi
    if [ -z "$done_at" ] && completed; then
        done_at=$t
    fi
    # Keep streaming after a completed boot: whatever goes wrong next is wanted too.
    if [ -n "$done_at" ]; then
        [ -n "$mounted" ] && [ $t -eq $((done_at + 30)) ] && snapshot completed
        continue
    fi
    [ $t -lt $TIMEOUT ] && continue

    [ -n "$mounted" ] && snapshot timeout
    if [ "$(getprop persist.vendor.edge1.bootwatch)" = 0 ]; then
        log "boot not completed after ${TIMEOUT}s; reboot disabled, still logging"
        done_at=$t
        continue
    fi
    log "boot not completed after ${TIMEOUT}s; rebooting warm so the log survives"
    [ -n "$mounted" ] && finish
    setprop sys.powerctl reboot,edge1-bootwatch
    exit 0
done
