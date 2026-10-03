# Toward a release build

What separates this userdebug bring-up image from something to give someone as
their TV box, what is done, and the order the rest goes in.

## What a release build is here

| | bring-up (now) | release |
|---|---|---|
| Variant | `userdebug` | `user`: no root, adb off until enabled in Developer options |
| SELinux | permissive (`androidboot.selinux=permissive`) | enforcing - `user` builds ignore the switch |
| Signing | the builder's own keys (dev-keys) | the same, kept |
| adb | needs authorization (pairing) | off by default, authorization |
| Logs on the card | `edge1-bootwatch` (debuggable builds only) | none |
| Verified boot | orange (unlocked, no bootloader verification) | orange: no bootloader on this path verifies AVB |

## Done

* **Signing keys.** `build/local-config.sh` makes a key set of the build machine's own
  (`~/android_khadas/keys` in the WSL distro, once) and the product signs with it:
  `ro.build.tags=dev-keys`. AOSP's test keys are public, so with them anyone could sign
  an app as "platform". Back up that directory; a fresh flash works with any set.
* **adb authorization** on every variant (`ro.adb.secure=1`). Pairing: Settings >
  Device Preferences > Developer options > Wireless debugging > "Pair device with
  pairing code", then `adb pair <ip>:<port>`; afterwards `adb connect <ip>:5555`.
* **SELinux policy** for everything the board logged as denied in normal use (cards
  18-19): graphics clients (the IMapper 5 service name, `/dev/dri`, the display and GPU
  sysfs nodes), memfd sharing between audio, media and system_server, the composer,
  storage, the console, zram, Edge1 Tools, Wi-Fi without a vendor HAL.
  `build/dev/check-sepolicy.sh` compiles it with AOSP's policy before a build.
* **TV-box basics:** standby that the remote can wake (screen off, no suspend),
  A2DP Bluetooth audio, exFAT and USB 3 drives, zram, the builder's language and time
  zone as the defaults.
* **Sound settings:** Settings > Sound & display (Edge1 Tools): media volume, a test
  sound, the output in use. The volume starts at the top, so the TV's remote sets the
  loudness - it started at 2-3 of 15 before, which was near silence over HDMI.

## Left, in order

1. **Stability.** Cards 18-19 reset at random under load; nothing goes out like that.
   Card 21 ran 14 minutes without a reset at lower clocks (`edge1-options.txt`); next
   longer sessions, then full clocks, to tell whether it is power.
2. **SELinux enforcing on userdebug.** With the denials of a full permissive card at
   (near) zero, take `androidboot.selinux=permissive` out of the userdebug command line
   (BoardConfig.mk) for one card. Whatever is still missing shows as a denial with
   the bootwatch still writing logs, and the build can go back in one line.
3. **A `user` build.** The variant is a parameter of `build/build.sh` already
   (`provision-wsl.sh` passes `userdebug`); the Windows script needs the switch, and
   the image stage nothing (it packs whatever `out/` holds). On a user build there is
   no log on the card, so it comes only after 1 and 2.
4. **Install to the eMMC.** The installer travels in the image
   (`/vendor/bin/edge1-install-internal.sh`) and has never been run on the board.
   An SD card is fine to run from but slower and wears.
5. **Factory reset.** Settings > Reset reboots with a wipe request in the misc
   partition; nothing on this boot path acts on it (Armbian's U-Boot runs our boot
   script, which boots Android normally). The script could check misc and erase
   userdata's first blocks - `mount_all` reformats an unreadable `/data` - but it runs
   on a U-Boot with a short command list, so it waits until the rest is settled.
6. **Hardware video decoding** - docs/HW_DECODE.md.

Not reachable on this hardware and AOSP: Widevine (vendor code, and L1 needs a TEE),
Google apps and Play certification, hardware-backed keys (no TEE).
