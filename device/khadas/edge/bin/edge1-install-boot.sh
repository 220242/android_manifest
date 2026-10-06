#!/vendor/bin/sh
#
# Khadas Edge1 - the installer card: copy the system this card has just booted onto
# the eMMC or the M.2 NVMe, without a PC and without adb.
#
#   edge1-install-boot.sh <emmc|nvme>
#
# Started by init.edge1.rc once the boot has completed, when boot.scr saw
# "install=emmc" or "install=nvme" in the card's edge1-options.txt and passed it as
# androidboot.edge1.install. build-images.sh makes cards with the line already in
# (edge1-install-emmc.img, edge1-install-nvme.img); on any other card it can be
# typed into the file on a PC. The copy itself is edge1-install-internal.sh's - the
# same as "adb shell sh /vendor/bin/edge1-install-internal.sh emmc" - this script
# is what runs it unattended:
#
#   1. a minute's warning on the screen: everything on the target disk goes;
#   2. the line in the card's edge1-options.txt is commented out BEFORE anything is
#      written, so a failed or interrupted install is not repeated on every boot;
#   3. the installer runs, its output into edge1-install.log on the card;
#   4. eMMC: the board powers off - take the card out and switch it on, and the
#      eMMC's U-Boot boots the copy. NVMe: "system=nvme" goes into the card's file
#      and the board reboots: no U-Boot on this board can read an NVMe, so the
#      kernel keeps coming from the card and boot.scr points Android at the SSD.
#
# A failure leaves the system running from the card, says so on the screen and in
# edge1-install.log. Nothing on the card is touched apart from that file and the log.

T="${1:-none}"
MNT=/mnt/vendor/edge1-bootfs
DEV=/dev/block/by-name/bootfs
OPTS=$MNT/edge1-options.txt
LOG=$MNT/edge1-install.log
OUT=/data/local/tmp/edge1-install.out
WAIT_S=60

case "$T" in
    emmc) NAME="eMMC" ;;
    nvme) NAME="NVMe SSD" ;;
    *) exit 0 ;;
esac

kmsg() { echo "edge1-install: $*" > /dev/kmsg; }
log() {
    kmsg "$*"
    [ -w "$MNT" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}
# The screen. Android TV has no status bar, but the notification is in the
# launcher's notification panel and stays there; best effort either way.
notify() {
    cmd notification post -S bigtext -t "Edge1: установка на $NAME" edge1_install "$1" \
        > /dev/null 2>&1
}

# The card's FAT: edge1-bootwatch mounts it on a userdebug build, and is stopped
# first - it streams logcat into it, and the partition is about to be copied byte
# for byte. A FAT copied in the middle of a write is a FAT with a broken file.
setprop ctl.stop edge1_bootwatch
sleep 2
if ! grep -q " $MNT " /proc/mounts; then
    mkdir -p "$MNT"
    mount -t vfat -o rw,noatime "$DEV" "$MNT" || kmsg "cannot mount $DEV"
fi
mount -o remount,rw "$MNT" 2> /dev/null

log "install to $T requested (androidboot.edge1.install=$T)"

# 1. The warning.
i=$WAIT_S
while [ "$i" -gt 0 ]; do
    notify "Через $i с всё содержимое $NAME будет стёрто, и на него установится эта система с карты. Отменить: выключите питание, на ПК закомментируйте строку install= в edge1-options.txt на карте."
    sleep 10
    i=$((i - 10))
done

# 2. Not again on the next boot, whatever happens below.
if [ -f "$OPTS" ]; then
    sed -i 's/^install=/#install=/' "$OPTS" && log "install= commented out in edge1-options.txt"
fi
sync
mount -o remount,ro "$MNT" 2> /dev/null || log "could not remount $MNT read-only; copying anyway"

# 3. The copy. Its output goes to /data first: the card's FAT is read-only now,
# and is itself one of the partitions being copied.
notify "Идёт установка на $NAME. Не выключайте плату: копирование занимает несколько минут."
kmsg "running edge1-install-internal.sh $T --yes"
sh /vendor/bin/edge1-install-internal.sh "$T" --yes > "$OUT" 2>&1
rc=$?

mount -o remount,rw "$MNT" 2> /dev/null
cat "$OUT" >> "$LOG" 2> /dev/null
log "edge1-install-internal.sh $T exited $rc"

if [ "$rc" != 0 ]; then
    why="$(grep '^error:' "$OUT" | tail -1)"
    notify "Установка на $NAME не удалась: ${why:-код $rc}. Система работает с карты; подробности в edge1-install.log на карте."
    sync
    exit 1
fi

# 4.
if [ "$T" = nvme ]; then
    # The line keeps the file's CRLF if Notepad gave it one.
    cr=""
    grep -q "$(printf '\r')\$" "$OPTS" && cr="$(printf '\r')"
    sed -i 's/^system=/#system=/' "$OPTS"
    printf '\n# Android на NVMe (установлено с этой карты). Закомментируйте, чтобы снова%s\n# грузить систему с карты.%s\nsystem=nvme%s\n' \
        "$cr" "$cr" "$cr" >> "$OPTS"
    log "system=nvme added to edge1-options.txt; rebooting"
    sync
    notify "Установлено на $NAME. Перезагрузка: ядро грузится с этой карты, система - с SSD. Карту не вынимайте."
    sleep 15
    setprop sys.powerctl reboot
else
    log "done; powering off"
    sync
    notify "Установлено на eMMC. Плата сейчас выключится: выньте карту и включите её снова."
    sleep 15
    setprop sys.powerctl shutdown
fi
