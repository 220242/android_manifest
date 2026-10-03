#!/system/bin/sh
#
# Khadas Edge1 - bring-up boot watchdog and log recorder, userdebug only
# (init.edge1.rc starts it on "boot" when ro.debuggable=1).
#
# The board has no serial console. Two things make up for it:
#
# 1. The whole log, on the card. The card's first partition (bootfs) is the FAT that
#    Windows shows as EDGE1BOOT. This script mounts it and gives every boot a
#    directory of its own, edge1-logs/boot-NNNNN (numbered on from
#    edge1-logs/last-boot, the last MAX_BOOTS kept), and for as long as the board
#    runs streams into it:
#      logcat.txt   main, system, crash and events, from the start of logd's buffers
#      dmesg.txt    the kernel log, from the first line of the boot
#      alive.txt    how long this boot has run and whether it completed, rewritten
#                   every SYNC seconds: after a reset it says when the boot died
#    Both logs are complete: they start with everything already buffered and follow
#    from there, so nothing scrolls away, however fast a crash loop logs (the tenth
#    card produced 85KB/s of logcat, which filled a 2MiB buffer in 20 seconds).
#    Data is synced every SYNC seconds, so a sudden reset loses at most that much.
#    The seconds before a reset are not lost either: the kernel keeps them in RAM
#    (ramoops), and the next boot copies them from /sys/fs/pstore into the dead
#    boot's directory as pstore/ - so every boot that ended in a reset carries its
#    own last words. edge1-logs/boots.txt has one line per boot: when it started,
#    how long it lasted, whether it completed. (Card 19 reset at a different moment
#    every time, and two directories were not enough to see a pattern.)
#    Beside the logs, a snapshot of the system's state (getprop, ps, mounts,
#    services, SurfaceFlinger, Wi-Fi/Bluetooth, video decoders) in a subdirectory
#    named for when it was taken:
#      120s       two minutes after "boot", whatever state Android is in
#      completed  30s after sys.boot_completed, if it ever gets there
#      timeout    TIMEOUT (300) seconds after "boot" without sys.boot_completed
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
# 5s, not 10: card 18 reset about ten seconds after each boot completed, and a
# 10s sync lost exactly the seconds that mattered.
SYNC=5
DEV=/dev/block/by-name/bootfs
MNT=/mnt/vendor/edge1-bootfs
LOGS=$MNT/edge1-logs
OUT=
MAX_BOOTS=10
# Below this much free space the streams stop: U-Boot must still be able to rewrite
# edge1-pstore.bin and edge1-boot.log on the next boot. The oldest boots go first.
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

# $1: subdirectory of this boot's directory.
snapshot() {
    s="$OUT/$1"
    mkdir -p "$s"
    getprop > "$s/getprop.txt" 2>&1
    ps -A -o PID,PPID,USER,STAT,TIME,LABEL,NAME > "$s/ps.txt" 2>&1
    # Device node modes and labels too: card 15's display bug was a node mode that
    # a log could only hint at.
    # And the sysfs paths SELinux labels are written against: wakeup sources and
    # extcon devices differ by board, and each unlabelled one is a denial.
    { cat /proc/uptime; echo; cat /proc/mounts; echo; ls -l /dev/block/by-name; echo
      ls -lZ /dev/dri /dev/snd /dev/cec* /dev/video* /dev/media* /dev/rfkill; echo
      getenforce; cat /proc/swaps; echo
      ls -l /sys/class/wakeup /sys/class/extcon; } > "$s/misc.txt" 2>&1
    timeout 20 dumpsys -l > "$s/services.txt" 2>&1
    timeout 20 dumpsys SurfaceFlinger > "$s/surfaceflinger.txt" 2>&1
    # Wi-Fi and Bluetooth: interfaces, rfkill switches, and what the framework
    # made of them.
    { ip addr; echo; ls -l /sys/class/bluetooth; echo
      for r in /sys/class/rfkill/rfkill*; do
          echo "$r: $(cat "$r/name" "$r/type" "$r/soft" "$r/hard" 2>&1 | tr '\n' ' ')"
      done; echo
      timeout 20 dumpsys wifi | head -n 400; echo
      timeout 20 dumpsys bluetooth_manager | head -n 300; } > "$s/connectivity.txt" 2>&1
    # Video decoders: the V4L2 nodes and what each one decodes. docs/HW_DECODE.md.
    { for v in /sys/class/video4linux/*; do echo "$v: $(cat "$v/name" 2>&1)"; done; echo
      timeout 20 edge1-v4l2-probe; } > "$s/video.txt" 2>&1
    # Sound: the ALSA side (hw_params is "closed" unless something plays) and the
    # framework's - volumes per stream and device, the output in use. Card 21 played
    # at 2 of 15, which only a volume_changed line in the logcat gave away.
    { cat /proc/asound/cards /proc/asound/pcm; echo
      for f in /proc/asound/card*/pcm*p/sub0/hw_params /proc/asound/card*/pcm*p/sub0/status; do
          echo "$f:"; cat "$f"
      done; echo
      timeout 20 dumpsys audio | head -n 600; echo
      timeout 20 dumpsys media.audio_flinger | head -n 300; } > "$s/audio.txt" 2>&1
    sync
    log "state written to EDGE1BOOT:edge1-logs/${OUT##*/}/$1"
}

# Temperatures, fan level, CPU and GPU clocks and the core rails' voltages, one
# kernel log line every SYNC seconds, so dmesg.txt - and the ramoops copy that
# survives a reset - show them right up to the end. Cards 18 and 19 reset with
# nothing logged at 40-57C, far from the tsadc's 95C shutdown; card 19's ramoops
# came back with bits flipped all through it, which a software reboot does not do.
# The clocks and voltages at the last line are what says whether it is power.
# Local variables only: the main loop's t is a global, and a "t" here once set it
# to a temperature in millidegrees - past TIMEOUT, so the watchdog would reboot.
thermal_line() {
    local line="" z mc c p
    for z in /sys/class/thermal/thermal_zone*; do
        mc=$(cat "$z/temp" 2>/dev/null) || continue
        case "$mc" in ''|*[!0-9-]*) continue ;; esac
        line="$line $(cat "$z/type" 2>/dev/null | sed 's/-thermal//')=$((mc / 1000))C"
    done
    for c in /sys/class/thermal/cooling_device*; do
        [ "$(cat "$c/type" 2>/dev/null)" = pwm-fan ] || continue
        line="$line fan=$(cat "$c/cur_state" 2>/dev/null)/$(cat "$c/max_state" 2>/dev/null)"
    done
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        mc=$(cat "$p/scaling_cur_freq" 2>/dev/null) || continue
        case "$mc" in ''|*[!0-9]*) continue ;; esac
        line="$line ${p##*/}=$((mc / 1000))MHz"
    done
    mc=$(cat /sys/class/devfreq/ff9a0000.gpu/cur_freq 2>/dev/null)
    case "$mc" in ''|*[!0-9]*) ;; *) line="$line gpu=$((mc / 1000000))MHz" ;; esac
    # The rails the big cores and the GPU run on, and the SoC's centre rail:
    # what a reset under load would be about if it is about power.
    for c in $RAILS; do
        mc=$(cat "${c#*=}/microvolts" 2>/dev/null)
        case "$mc" in ''|*[!0-9]*) ;; *) line="$line ${c%%=*}=$((mc / 1000))mV" ;; esac
    done
    log "thermal$line"
}

# name=sysfs-dir for each regulator thermal_line reports, found once.
RAILS=
for r in /sys/class/regulator/regulator.*; do
    case "$(cat "$r/name" 2>/dev/null)" in
        vdd_cpu_b|vdd_gpu|vdd_center|vdd_log) RAILS="$RAILS $(cat "$r/name")=$r" ;;
    esac
done

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

# boot-NNNNN, five digits so that a plain ls lists them oldest first.
boot_dir() { printf '%s/boot-%05d' "$LOGS" "$1"; }

# The boots on the card, oldest first.
boot_dirs() { ls -d "$LOGS"/boot-[0-9][0-9][0-9][0-9][0-9] 2>/dev/null; }

# Drops the oldest boots beyond MAX_BOOTS, then more while space is short - never
# the one just created.
prune() {
    set -- $(boot_dirs)
    while [ $# -gt "$MAX_BOOTS" ]; do rm -rf "$1"; shift; done
    while [ $# -gt 1 ] && [ "$(avail_kib)" -lt "$KEEP_FREE_KIB" ]; do rm -rf "$1"; shift; done
}

# alive.txt: rewritten every tick, so it holds the last moment this boot was seen.
# Kernel uptime, so the numbers line up with dmesg.txt.
uptime_s() { cut -d. -f1 /proc/uptime; }
done_up=
alive() {
    [ -n "$OUT" ] || return
    if [ -n "$done_up" ]; then
        echo "up $(uptime_s)s, boot completed at ${done_up}s" > "$OUT/alive.txt"
    else
        echo "up $(uptime_s)s, boot not completed" > "$OUT/alive.txt"
    fi
}

# edge1-options.txt on EDGE1BOOT: settings the owner can change in Windows between
# two boots, without a rebuild. key=value lines, # for comments, CRLF allowed:
#   cpu_big_max_mhz    top clock of the A72s (408..1800)
#   cpu_little_max_mhz top clock of the A53s (408..1416)
#   gpu_max_mhz        top clock of the Mali (200..800)
# The image ships one with ready-made modes, commented in Russian, the power test
# switched on (build/build-bootfs.sh has the file and the reasons).
apply_options() {
    local f="$MNT/edge1-options.txt" key val applied="" bom big="" little="" gpu=""
    [ -f "$f" ] || return
    # The file is edited in Notepad: it may come back with a UTF-8 BOM ahead of the
    # first line, CRLF endings, tabs, or a "# note" after a value.
    bom=$(printf '\357\273\277')
    while IFS='=' read -r key val; do
        key=$(echo "${key#"$bom"}" | tr -d ' \t\r'); val=$(echo "${val%%#*}" | tr -d ' \t\r')
        case "$key" in ''|\#*) continue ;; esac
        case "$val" in ''|*[!0-9]*) log "options: $key: not a number"; continue ;; esac
        case "$key" in
            cpu_big_max_mhz) big=$val ;;
            cpu_little_max_mhz) little=$val ;;
            gpu_max_mhz) gpu=$val ;;
            *) log "options: unknown key $key" ;;
        esac
    done < "$f"
    # The last value of each key counts: of two modes left on, the lower one in the
    # file. Each is written once, and only what was written is reported.
    [ -n "$big" ] && echo $((big * 1000)) > /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq \
        && applied="$applied cpu_big_max_mhz=$big"
    [ -n "$little" ] && echo $((little * 1000)) > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq \
        && applied="$applied cpu_little_max_mhz=$little"
    [ -n "$gpu" ] && echo $((gpu * 1000000)) > /sys/class/devfreq/ff9a0000.gpu/max_freq \
        && applied="$applied gpu_max_mhz=$gpu"
    [ -n "$applied" ] && log "options applied:$applied"
    OPTIONS="$applied"
}
OPTIONS=

n=
if [ -n "$mounted" ]; then
    apply_options
    mkdir -p "$LOGS"
    # The two fixed directories of the old layout.
    rm -rf "$LOGS/boot-0" "$LOGS/boot-1"
    n=$(cat "$LOGS/last-boot" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    prev=$(boot_dir "$n")
    n=$((n + 1))
    [ "$n" -gt 99999 ] && n=1
    echo "$n" > "$LOGS/last-boot"
    OUT=$(boot_dir "$n")
    mkdir -p "$OUT"
    # The previous boot's end, as the kernel kept it in RAM through the reset. It
    # belongs to that boot, so it goes into that boot's directory.
    if [ -d "$prev" ] && [ -n "$(ls /sys/fs/pstore 2>/dev/null)" ]; then
        mkdir -p "$prev/pstore"
        cp /sys/fs/pstore/* "$prev/pstore/" 2>/dev/null
    fi
    if [ -d "$prev" ]; then
        echo "${prev##*/}: $(cat "$prev/alive.txt" 2>/dev/null || echo 'no record')$( \
            [ -d "$prev/pstore" ] && echo ', pstore saved')" >> "$LOGS/boots.txt"
    fi
    echo "${OUT##*/}: started, clock $(date '+%Y-%m-%d %H:%M:%S')," \
        "boot reason $(getprop ro.boot.bootreason), options:${OPTIONS:- none}" \
        >> "$LOGS/boots.txt"
    prune
    if [ "$(avail_kib)" -lt "$STOP_FREE_KIB" ]; then
        log "EDGE1BOOT is nearly full; no logs written"
    else
        start_streams
        log "streaming logcat and dmesg to EDGE1BOOT:edge1-logs/${OUT##*/}"
    fi
fi

t=0
done_at=
while :; do
    sleep "$SYNC"
    t=$((t + SYNC))
    thermal_line
    if [ -n "$mounted" ]; then
        alive
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
        done_up=$(uptime_s)
        # Wi-Fi verbose logging: wpa_supplicant's own debug lines in logcat. Card
        # 17's failed associations said no more than "status_code=16" without it.
        cmd wifi set-verbose-logging enabled > /dev/null 2>&1 \
            && log "Wi-Fi verbose logging on"
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
