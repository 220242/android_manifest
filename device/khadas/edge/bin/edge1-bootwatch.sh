#!/system/bin/sh
#
# Khadas Edge1 - bring-up boot watchdog and log collector, userdebug only
# (init.edge1.rc starts it on "boot" when ro.debuggable=1).
#
# The board has no serial console. Two things make up for it:
#
# 1. Logs on the card. The card's first partition (bootfs) is the FAT that Windows
#    shows as EDGE1BOOT. This script mounts it for a moment and writes logcat, dmesg,
#    getprop and ps into edge1-logs/boot-0/<when>/:
#      120s       two minutes after "boot", whatever state Android is in
#      completed  30s after sys.boot_completed, if it ever gets there
#      timeout    TIMEOUT seconds after "boot" without sys.boot_completed
#    The directory of the boot before is renamed to boot-1 first, so after a
#    watchdog reboot the card holds both the hung boot and the one that followed.
#    ramoops (edge1-pstore.bin) only keeps the last few seconds; these hold minutes.
#
# 2. A warm reboot instead of a hang. If Android has not set sys.boot_completed
#    within TIMEOUT seconds, reboot - warm, so ramoops survives and the card's boot
#    script saves it as edge1-pstore.bin. Before this, the only way out of a hung
#    boot was the power switch, which empties RAM and the log with it.
#
# 600s is long enough for a first boot that formats /data on an SD card.
# setprop persist.vendor.edge1.bootwatch 0 disables the reboot (not the logs).
TIMEOUT=600
DEV=/dev/block/by-name/bootfs
MNT=/mnt/vendor/edge1-bootfs
MIN_FREE_KIB=16384

log() { echo "edge1-bootwatch: $*" > /dev/kmsg; }

# $1: subdirectory of edge1-logs/boot-0. Never fails the caller.
snapshot() {
    mkdir -p "$MNT" || return
    mount -t vfat -o rw,noatime "$DEV" "$MNT" || { log "cannot mount $DEV"; return; }
    if [ "$1" = rotate ]; then
        # Only a boot that wrote something displaces boot-1, so a boot that dies
        # before its first snapshot does not cost the one before it its logs.
        if [ -d "$MNT/edge1-logs/boot-0" ]; then
            rm -rf "$MNT/edge1-logs/boot-1"
            mv "$MNT/edge1-logs/boot-0" "$MNT/edge1-logs/boot-1"
        fi
    elif [ "$(avail_kib)" -lt "$MIN_FREE_KIB" ] && rm -rf "$MNT/edge1-logs/boot-1" \
         && [ "$(avail_kib)" -lt "$MIN_FREE_KIB" ]; then
        log "EDGE1BOOT is nearly full; no logs written"
    else
        out="$MNT/edge1-logs/boot-0/$1"
        mkdir -p "$out"
        # main, system and crash: the kernel buffer is dmesg.txt, and events is binary
        # noise at this stage. Together they stay under ~8MiB at 2MiB per buffer.
        logcat -b main,system,crash -d -v threadtime > "$out/logcat.txt" 2>&1
        dmesg > "$out/dmesg.txt" 2>&1
        getprop > "$out/getprop.txt" 2>&1
        ps -A -o PID,PPID,USER,STAT,TIME,LABEL,NAME > "$out/ps.txt" 2>&1
        { cat /proc/uptime; echo; cat /proc/mounts; echo; ls -l /dev/block/by-name; } \
            > "$out/misc.txt" 2>&1
        timeout 20 dumpsys -l > "$out/services.txt" 2>&1
        timeout 20 dumpsys SurfaceFlinger > "$out/surfaceflinger.txt" 2>&1
        log "logs written to EDGE1BOOT:edge1-logs/boot-0/$1"
    fi
    sync
    umount "$MNT" || log "cannot unmount $MNT"
}

completed() { [ "$(getprop sys.boot_completed)" = 1 ]; }

# Free space on the mounted FAT, in KiB. The partition is 128MiB and the kernel takes
# most of it; U-Boot must still be able to rewrite edge1-pstore.bin and
# edge1-boot.log, so logs stop well before it fills.
avail_kib() { set -- $(df -k "$MNT" | tail -n 1); echo "${4:-999999}"; }

snapshot rotate

t=0
while [ $t -lt $TIMEOUT ]; do
    sleep 10
    t=$((t + 10))
    [ $t -eq 120 ] && snapshot 120s
    if completed; then
        sleep 30
        snapshot completed
        exit 0
    fi
done

snapshot timeout
[ "$(getprop persist.vendor.edge1.bootwatch)" = 0 ] && exit 0
log "boot not completed after ${TIMEOUT}s; rebooting warm so the log survives"
setprop sys.powerctl reboot,edge1-bootwatch
