#!/system/bin/sh
#
# Khadas Edge1 - bring-up boot watchdog, userdebug only (init.edge1.rc starts it).
#
# The board has no serial console. What it does have is a ramoops region that keeps
# the kernel log and logcat across a WARM reset, which the boot script on the card
# saves to edge1-pstore.bin before it starts the next kernel. A panic reboots warm by
# itself (panic=20); a boot that simply never finishes does not, and the only way out
# was the power switch - which empties RAM, and the log with it. The ninth card's
# capture came back exactly like that: decayed DRAM, nothing to read.
#
# So: if Android has not set sys.boot_completed within TIMEOUT seconds of "boot",
# write a line to the kernel log and reboot, warm. The next boot script run saves
# everything the hung boot printed. 600s is long enough for a first boot that
# formats /data on an SD card; setprop persist.vendor.edge1.bootwatch 0 disables it.
TIMEOUT=600

sleep "$TIMEOUT"
[ "$(getprop sys.boot_completed)" = 1 ] && exit 0
[ "$(getprop persist.vendor.edge1.bootwatch)" = 0 ] && exit 0
echo "edge1-bootwatch: boot not completed after ${TIMEOUT}s; rebooting warm so the log survives" > /dev/kmsg
setprop sys.powerctl reboot,edge1-bootwatch
