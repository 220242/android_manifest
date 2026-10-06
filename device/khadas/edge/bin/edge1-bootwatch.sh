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
OPTS=$MNT/edge1-options.txt
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
    # Video decoders: the V4L2 nodes and what each one decodes, and how many
    # interrupts each has raised - only a hardware decode raises them, so a count
    # above zero is the proof it ran. docs/HW_DECODE.md.
    { for v in /sys/class/video4linux/*; do echo "$v: $(cat "$v/name" 2>&1)"; done; echo
      grep -E "video-codec|rkvdec|vpu" /proc/interrupts; echo
      getprop persist.vendor.edge1.hwdec; echo
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
    # Power: what the USB-C ports negotiated (kernel patch 0005, pd= in
    # edge1-options.txt) - the Type-C ports, the PD supplies tcpm registers
    # (voltage_now, current_max), and tcpm's and fusb302's own logs of the
    # negotiation in debugfs. Card 24 reset five times on a supply left at 5V.
    { grep -h . /sys/class/typec/*/power_role /sys/class/typec/*/data_role \
          /sys/class/typec/*/power_operation_mode /sys/class/typec/*-partner/usb_power_delivery_revision 2>&1; echo
      for u in /sys/class/power_supply/*/uevent; do echo "$u:"; cat "$u"; done; echo
      grep -q ' /sys/kernel/debug ' /proc/mounts || mount -t debugfs debugfs /sys/kernel/debug
      for l in /sys/kernel/debug/usb/tcpm-*/log /sys/kernel/debug/usb/fusb302-*/log; do
          [ -e "$l" ] && { echo "== $l"; tail -n 200 "$l"; }
      done
      dmesg | grep -iE "fusb|tcpm|typec|power_supply"; } > "$s/power.txt" 2>&1
    # Who signed what: "signatures:[xxxxxxxx]" is the hash Android prints for a
    # certificate. Card 22's Bluetooth app ran in the zygote domain - seinfo
    # "default", its signature matched no mac_permissions signer - since the build
    # signs with its own keys; local-config prints the same hashes for those keys.
    { for p in com.android.bluetooth com.android.networkstack org.edge1.tools \
               com.android.tv.settings com.android.shell; do
          echo "== $p"
          timeout 20 dumpsys package "$p" | grep -E "codePath=|sharedUser=|signatures=|pkgFlags="
      done; } > "$s/packages.txt" 2>&1
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
# Decoder interrupts so far, rkvdec and hantro over all CPUs: one per decoded frame.
dec_irqs() {
    grep 'video-codec' /proc/interrupts | awk '{ for (i = 2; i <= NF; i++) {
        if ($i ~ /^[0-9]+$/) s += $i; else break } } END { print s + 0 }'
}

# A video playing (the decoders' interrupts climbing): what the board does with it.
# The decode rate from the interrupts, the clocks, the threads' CPU, how
# SurfaceFlinger composed the video layer (DEVICE: on a display plane; CLIENT: by
# the GPU), and the codec's own per-frame timings. Up to three per boot.
playing_snapshot() {
    local f="$OUT/playing-$1.txt" a b
    a=$(dec_irqs); sleep 2; b=$(dec_irqs)
    { echo "uptime $(uptime_s)s, decoder interrupts $(( (b - a) / 2 ))/s (one per frame)"
      echo "cpu: little $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq)" \
           "big $(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq) kHz," \
           "gpu $(cat /sys/class/devfreq/ff9a0000.gpu/cur_freq) Hz"
      cat /sys/class/devfreq/ff9a0000.gpu/load 2>/dev/null; echo
      # The decoders' clocks (kernel patch 0007 sets rkvdec's core and CABAC).
      grep -q ' /sys/kernel/debug ' /proc/mounts || mount -t debugfs debugfs /sys/kernel/debug
      grep -E 'vdu|vcodec|cpll|gpll|npll' /sys/kernel/debug/clk/clk_summary; echo
      # What the display controller shows: which CRTC (VOP) drives HDMI, and each
      # plane's framebuffer - NV12 on a plane is the video without the GPU.
      cat /sys/kernel/debug/dri/0/state 2> /dev/null; echo
      timeout 10 top -H -b -n 1 -m 30; echo
      logcat -d -v time -s C2FFMPEGVideoDecodeComponent:I FFMPEG:I | tail -n 30; echo
      timeout 20 dumpsys SurfaceFlinger | head -n 700; } > "$f" 2>&1
    sync
    log "video playing: state written to EDGE1BOOT:edge1-logs/${OUT##*/}/${f##*/}"
}
played=0
playing=0
irq_prev=

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
#   logs, zram, sd_readahead_kb, sd_write_delay_s   logs and memory (below)
#   video_hw, video_nv12, video_threads, video_copy_threads   the FFmpeg Codec2
#                      decoder's properties
#   hdmi_audio         0: sound stays on the audio HAL's "Speaker" (Edge1 Tools
#                      does not connect "HDMI Out"; audio_policy_configuration.xml)
#   pd, vop            boot.scr's (USB PD, the VOP on HDMI): recorded here only
# The image ships one with ready-made modes, commented in Russian, full speed
# switched on (build/build-bootfs.sh has the file and the reasons).
apply_options() {
    local f="$OPTS" key val applied="" bom big="" little="" gpu="" readahead="" wdelay="" q
    local vhw="" vnv12="" vthreads="" vcopy="" hdmia=""
    [ -f "$f" ] || return
    # The file is edited in Notepad: it may come back with a UTF-8 BOM ahead of the
    # first line, CRLF endings, tabs, or a "# note" after a value.
    bom=$(printf '\357\273\277')
    while IFS='=' read -r key val; do
        key=$(echo "${key#"$bom"}" | tr -d ' \t\r'); val=$(echo "${val%%#*}" | tr -d ' \t\r')
        case "$key" in ''|\#*) continue ;; esac
        # boot.scr's: which display controller drives HDMI (big or lit).
        case "$key" in vop) applied="$applied vop=$val"; continue ;; esac
        case "$val" in ''|*[!0-9]*) log "options: $key: not a number"; continue ;; esac
        case "$key" in
            cpu_big_max_mhz) big=$val ;;
            cpu_little_max_mhz) little=$val ;;
            gpu_max_mhz) gpu=$val ;;
            logs) LOGS_ON=$val ;;
            pd) applied="$applied pd=$val" ;;     # boot.scr's: the dtb it boots
            zram) ZRAM_PCT=$val ;;
            sd_readahead_kb) readahead=$val ;;
            sd_write_delay_s) wdelay=$val ;;
            video_hw) vhw=$val ;;
            video_nv12) vnv12=$val ;;
            video_threads) vthreads=$val ;;
            video_copy_threads) vcopy=$val ;;
            hdmi_audio) hdmia=$val ;;
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
    # Memory and the card (the "Память" section of the file). Read-ahead: per
    # disk - the card, the eMMC, and the dm devices of super (system, vendor...).
    if [ -z "$readahead" ]; then :
    elif [ "$readahead" -ge 16 ] && [ "$readahead" -le 8192 ]; then
        for q in /sys/block/mmcblk*/queue/read_ahead_kb /sys/block/dm-*/queue/read_ahead_kb; do
            [ -e "$q" ] && echo "$readahead" > "$q"
        done
        applied="$applied sd_readahead_kb=$readahead"
    else
        log "options: sd_readahead_kb=$readahead is outside 16..8192, ignored"
    fi
    # Write delay: how old unsaved data may get in RAM before the kernel writes it
    # (Linux: 30s). fsync() - an app saving its database - still writes at once.
    if [ -z "$wdelay" ]; then :
    elif [ "$wdelay" -ge 5 ] && [ "$wdelay" -le 600 ]; then
        echo $((wdelay * 100)) > /proc/sys/vm/dirty_expire_centisecs \
            && applied="$applied sd_write_delay_s=$wdelay"
    else
        log "options: sd_write_delay_s=$wdelay is outside 5..600, ignored"
    fi
    # The video decoder (the FFmpeg Codec2 service reads these when a video
    # starts). Set on every boot, to the default when the line is out of the file,
    # so taking a line out undoes it - they are persist properties.
    case "$vhw" in ''|0|1) ;; *) log "options: video_hw=$vhw is not 0 or 1, ignored"; vhw= ;; esac
    case "$vnv12" in ''|0|1) ;; *) log "options: video_nv12=$vnv12 is not 0 or 1, ignored"; vnv12= ;; esac
    case "$vthreads" in ''|1|2|3|4) ;; *) log "options: video_threads=$vthreads is outside 1..4, ignored"; vthreads= ;; esac
    case "$vcopy" in ''|1|2|3|4) ;; *) log "options: video_copy_threads=$vcopy is outside 1..4, ignored"; vcopy= ;; esac
    case "$hdmia" in ''|0|1) ;; *) log "options: hdmi_audio=$hdmia is not 0 or 1, ignored"; hdmia= ;; esac
    setprop_changed persist.vendor.edge1.hwdec "${vhw:-1}"
    setprop_changed persist.vendor.edge1.hwdec_nv12 "${vnv12:-1}"
    setprop_changed persist.vendor.edge1.hwdec_threads "${vthreads:-2}"
    setprop_changed persist.vendor.edge1.hwdec_copy_threads "${vcopy:-2}"
    setprop_changed persist.sys.edge1.hdmi_audio "${hdmia:-1}"
    [ -n "$vhw" ] && applied="$applied video_hw=$vhw"
    [ -n "$vnv12" ] && applied="$applied video_nv12=$vnv12"
    [ -n "$vthreads" ] && applied="$applied video_threads=$vthreads"
    [ -n "$vcopy" ] && applied="$applied video_copy_threads=$vcopy"
    [ -n "$hdmia" ] && applied="$applied hdmi_audio=$hdmia"
    if [ -z "$ZRAM_PCT" ]; then :
    elif [ "$ZRAM_PCT" -le 75 ]; then
        applied="$applied zram=$ZRAM_PCT"
    else
        log "options: zram=$ZRAM_PCT is above 75, ignored"
        ZRAM_PCT=
    fi
    [ -n "$applied" ] && log "options applied:$applied"
    OPTIONS="$applied"
}
OPTIONS=
# A persist property is written to /data each time it is set; only on a change.
setprop_changed() {
    [ "$(getprop "$1")" = "$2" ] || setprop "$1" "$2"
}
# "logs=0" in edge1-options.txt (the owner, on a PC or in Edge1 Tools): no logs.
LOGS_ON=1
# "zram=N": compressed swap in RAM, N% of it (fstab: 50); 0 turns it off.
ZRAM_PCT=

# zram is set up by init's swapon_all at sys.boot_completed from fstab's 50%; a
# different size means taking it down and setting it up again, after that. Waits
# for the swap to appear (up to a minute), so it can run from either path below.
apply_zram() {
    local total want cur i=0
    [ -n "$ZRAM_PCT" ] && [ -e /sys/block/zram0/disksize ] || return 0
    while ! grep -q '^/dev/block/zram0 ' /proc/swaps && [ $i -lt 60 ]; do
        sleep 1; i=$((i + 1))
    done
    total=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    want=$((total * ZRAM_PCT / 100 * 1024))
    cur=$(cat /sys/block/zram0/disksize)
    # fs_mgr's 50% and ours differ by rounding at most.
    if [ "$want" -gt 0 ] && [ $(( (cur - want) * 100 / want )) -eq 0 ]; then
        log "zram: ${ZRAM_PCT}% is what fstab set up"
        return 0
    fi
    swapoff /dev/block/zram0 2> /dev/null
    echo 1 > /sys/block/zram0/reset
    if [ "$ZRAM_PCT" -eq 0 ]; then
        log "zram: off (zram=0)"
        return 0
    fi
    echo "$want" > /sys/block/zram0/disksize && mkswap /dev/block/zram0 > /dev/null \
        && swapon /dev/block/zram0 && log "zram: ${ZRAM_PCT}% of RAM, $((want / 1048576)) MiB" \
        || log "zram: could not set ${ZRAM_PCT}%"
}

# Has "logs=0" turned up in the file since this boot started? Edge1 Tools writes
# it through bin/edge1-ctl.sh while the bootwatch runs.
logs_turned_off() {
    grep -q '^logs=0' "$OPTS" 2> /dev/null
}

n=
if [ -n "$mounted" ]; then
    apply_options
    # For Edge1 Tools' logs switch: what the card says, and that there is a card.
    setprop sys.edge1.logs "$LOGS_ON"
    # logs=0: the clock limits are all there is to do. No logs, no snapshots, no
    # thermal lines, no reboot on a boot that does not complete - the build is
    # trusted. The partition stays mounted, read-only, for Edge1 Tools' changes to
    # edge1-options.txt (edge1-ctl remounts it for each one). boot.scr has saved
    # nothing either.
    if [ "$LOGS_ON" = 0 ]; then
        mount -o remount,ro "$MNT" || log "cannot remount $MNT read-only"
        log "logs=0 in edge1-options.txt: options:${OPTIONS:- none}, nothing written"
        # zram=: after the boot completes, which nothing else here waits for.
        if [ -n "$ZRAM_PCT" ]; then
            i=0
            while ! completed && [ $i -lt "$TIMEOUT" ]; do sleep 5; i=$((i + 5)); done
            completed && apply_zram
        fi
        exit 0
    fi
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
    # Turned off in Edge1 Tools while running: stop writing now, and leave the
    # partition mounted read-only as a boot with logs=0 does.
    if [ -n "$mounted" ] && logs_turned_off; then
        stop_streams
        [ -n "$done_at" ] && cmd wifi set-verbose-logging disabled > /dev/null 2>&1
        sync
        mount -o remount,ro "$MNT" || log "cannot remount $MNT read-only"
        log "logs turned off in Edge1 Tools; nothing more written"
        exit 0
    fi
    thermal_line
    # Video: two checks in a row with at least 10 decoded frames a second.
    if [ -n "$mounted" ] && [ -n "$streams" ] && [ "$played" -lt 3 ]; then
        irq=$(dec_irqs)
        if [ -n "$irq_prev" ] && [ $((irq - irq_prev)) -ge $((10 * SYNC)) ]; then
            playing=$((playing + 1))
            if [ "$playing" -eq 2 ]; then
                played=$((played + 1))
                playing_snapshot "$played"
                irq=$(dec_irqs)
            fi
        else
            playing=0
        fi
        irq_prev=$irq
    fi
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
        apply_zram
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
