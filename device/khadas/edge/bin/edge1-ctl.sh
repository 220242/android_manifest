#!/vendor/bin/sh
#
# edge1-ctl: what Edge1 Tools needs root for - the CPU and GPU clock limits (the
# "modes" of edge1-options.txt) and the bring-up logs on the card.
#
#   edge1-ctl.sh request <nonce>:perf:<big>:<little>:<gpu>   a mode picked in the app (MHz)
#   edge1-ctl.sh request <nonce>:logs-off | logs-on | logs-clear
#   edge1-ctl.sh boot <big>:<little>:<gpu>                   the app's last mode, at boot
#
# Edge1 Tools runs as the system user, which may set sys.* and persist.sys.*
# properties and nothing of the vendor's; init/init.edge1.ctl.rc (on /product, so
# that it may watch them) starts the services in init.edge1.rc, and init expands
# the property into the arguments. The nonce makes every request a new value, so a
# repeated one is a property change too.
#
# The card's EDGE1BOOT partition: edge1-bootwatch (debuggable builds) mounts it at
# boot. Its edge1-options.txt stays the one source of the clock limits when it is
# there - the bootwatch applies it at boot, so "boot" then leaves it alone (a mode
# edited on a PC wins over the app's last pick) and "perf" writes the app's pick
# into it, so the PC sees what the box runs. Without it (an eMMC install, a user
# build) "boot" sets the app's last pick.
#
# Logs off is "logs=0" in edge1-options.txt, as the owner may also write it on a
# PC: boot.scr then saves no edge1-pstore.bin and no edge1-boot.log, and the
# bootwatch writes no edge1-logs - it applies the clock limits and leaves the
# partition mounted read-only. A running bootwatch sees the line within seconds and
# stops writing.
MNT=/mnt/vendor/edge1-bootfs
OPTS=$MNT/edge1-options.txt
CPU=/sys/devices/system/cpu/cpufreq
GPU=/sys/class/devfreq/ff9a0000.gpu

log() { echo "edge1-ctl: $*" > /dev/kmsg; }

# The card's partition, writable for one change and read-only again when the logs
# are off (nothing else writes it then).
card() { [ -f "$OPTS" ]; }
card_rw() { mount -o remount,rw "$MNT" 2> /dev/null || grep -q " $MNT vfat rw" /proc/mounts; }
logs_off() { grep -q '^logs=0' "$OPTS"; }
card_done() {
    sync
    logs_off && mount -o remount,ro "$MNT" 2> /dev/null
    return 0
}

# The "logs=" line set to $1, in place, keeping the file's line ends. A file from
# before the option has none: it goes in after the header, at the first blank line.
write_logs() {
    local line crlf="" have="" put=""
    grep -q "$CR\$" "$OPTS" && crlf=$CR
    grep -q '^#*logs=' "$OPTS" && have=1
    {
        while IFS= read -r line || [ -n "$line" ]; do
            if [ -n "$have" ]; then
                case "$line" in
                    logs=*|'#'logs=*|'##'logs=*)
                        if [ -z "$put" ]; then
                            printf 'logs=%s%s\n' "$1" "$crlf"
                            put=1
                        fi
                        continue ;;
                esac
            elif [ -z "$put" ] && [ -z "${line%"$CR"}" ]; then
                printf '%s\n' "$line" "logs=$1$crlf"
                put=1
                continue
            fi
            printf '%s\n' "$line"
        done < "$OPTS"
        if [ -z "$put" ]; then
            printf 'logs=%s%s\n' "$1" "$crlf"
        fi
    } > "$OPTS.new" && mv "$OPTS.new" "$OPTS"
}

# "big:little:gpu" into $big $little $gpu; false unless three numbers.
split3() {
    local rest n
    big="${1%%:*}" rest="${1#*:}"
    little="${rest%%:*}" gpu="${rest#*:}"
    for n in "$big" "$little" "$gpu"; do
        case "$n" in ''|*[!0-9]*) return 1 ;; esac
    done
}

set_clocks() {
    echo $((big * 1000)) > $CPU/policy4/scaling_max_freq
    echo $((little * 1000)) > $CPU/policy0/scaling_max_freq
    echo $((gpu * 1000000)) > $GPU/max_freq
}

# The key and value of a key line of edge1-options.txt, commented or not, as
# "key value"; nothing for any other line.
keyline() {
    local l="${1%"$CR"}"
    while :; do
        case "$l" in
            '#'*|' '*) l="${l#?}" ;;
            *) break ;;
        esac
    done
    case "$l" in
        cpu_big_max_mhz=*|cpu_little_max_mhz=*|gpu_max_mhz=*)
            case "${l#*=}" in
                ''|*[!0-9]*) ;;
                *) printf '%s %s\n' "${l%%=*}" "${l#*=}" ;;
            esac ;;
    esac
}

# Into the card's file: the mode block with exactly these values is switched on and
# every other one off; a set no block has goes into a "Свой" (own) block, which is
# rewritten in place or added at the end. Lines keep their CRLF if the file has
# them (Notepad), and nothing but the three keys' lines changes.
CUSTOM="# === Свой (выбран в Edge1 Tools) ======================================"
OWN="# === Свой"
CR=$(printf '\r')
write_options() {
    local match="" own="" blk=0 b="" l="" g="" line kv k val target crlf=""
    # Pass 1: the first block whose three values are these, else the own block.
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '# ==='*)
                [ -z "$match" ] && [ "$b:$l:$g" = "$big:$little:$gpu" ] && match=$blk
                blk=$((blk + 1)) b="" l="" g=""
                case "$line" in "$OWN"*) own=$blk ;; esac
                continue ;;
        esac
        kv=$(keyline "$line")
        case "$kv" in
            cpu_big_max_mhz\ *) b=${kv#* } ;;
            cpu_little_max_mhz\ *) l=${kv#* } ;;
            gpu_max_mhz\ *) g=${kv#* } ;;
        esac
    done < "$OPTS"
    [ -z "$match" ] && [ "$b:$l:$g" = "$big:$little:$gpu" ] && match=$blk
    target=${match:-$own}

    # Pass 2.
    grep -q "$CR\$" "$OPTS" && crlf=$CR
    blk=0
    {
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                '# ==='*) blk=$((blk + 1)); printf '%s\n' "$line"; continue ;;
            esac
            kv=$(keyline "$line")
            if [ -z "$kv" ]; then
                printf '%s\n' "$line"
                continue
            fi
            k=${kv%% *} val=${kv#* }
            if [ "$blk" = "$target" ]; then
                [ -z "$match" ] && case $k in
                    cpu_big_max_mhz) val=$big ;;
                    cpu_little_max_mhz) val=$little ;;
                    gpu_max_mhz) val=$gpu ;;
                esac
                printf '%s=%s%s\n' "$k" "$val" "$crlf"
            else
                printf '#%s=%s%s\n' "$k" "$val" "$crlf"
            fi
        done < "$OPTS"
        if [ -z "$target" ]; then
            printf '%s\n' "$crlf" "$CUSTOM$crlf" "# A72 $big, A53 $little, GPU $gpu.$crlf" \
                "cpu_big_max_mhz=$big$crlf" "cpu_little_max_mhz=$little$crlf" "gpu_max_mhz=$gpu$crlf"
        fi
    } > "$OPTS.new" && mv "$OPTS.new" "$OPTS"
}

case "$1" in
    boot)
        case "$2" in none|'') exit 0 ;; esac
        split3 "$2" || { log "boot: not three numbers: '$2'"; exit 1; }
        if card; then
            log "boot: EDGE1BOOT:edge1-options.txt is in charge (edge1-bootwatch applied it)"
            exit 0
        fi
        set_clocks
        log "boot: A72 $big, A53 $little, GPU $gpu MHz"
        ;;
    request)
        r="${2#*:}"
        case "$r" in
            perf:*)
                split3 "${r#perf:}" || { log "perf: not three numbers: '$r'"; exit 1; }
                set_clocks
                log "perf: A72 $big, A53 $little, GPU $gpu MHz"
                if card && card_rw; then
                    write_options && log "perf: written to EDGE1BOOT:edge1-options.txt"
                    card_done
                fi
                ;;
            logs-off|logs-on)
                card || { log "$r: no EDGE1BOOT partition mounted"; exit 1; }
                v=0; [ "$r" = logs-on ] && v=1
                card_rw && write_logs $v && log "$r: logs=$v in edge1-options.txt"
                card_done
                ;;
            logs-clear)
                card || { log "logs-clear: no EDGE1BOOT partition mounted"; exit 1; }
                # Only with the logs off: a running bootwatch writes into the folder.
                logs_off || { log "logs-clear: the logs are on; turn them off first"; exit 1; }
                card_rw && rm -rf "$MNT/edge1-logs" && log "logs-clear: edge1-logs deleted"
                card_done
                ;;
            none|'') ;;
            *) log "unknown request '$2'"; exit 1 ;;
        esac
        ;;
    *)
        log "usage: edge1-ctl.sh boot <big:little:gpu> | request <nonce>:<what>"
        exit 1
        ;;
esac
