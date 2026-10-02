# Handoff: how this port is being brought up, and where it stands

For whoever picks the work up next — a new session, or the same one after its context
was compacted. Everything needed to continue without re-deriving it. The other docs
explain *why*; this one is the working state and the loop.

## The loop

The owner builds on Windows 11 (`D:\android_khadas`, WSL2 distro `Edge1Build`) and has
the board; there is **no serial adapter**. One iteration:

1. A fix is committed and pushed to `claude/determined-johnson-fwwaig` (the only branch).
2. The owner runs, in PowerShell:
   ```powershell
   cd D:\android_khadas\android_manifest; git pull; cd ..; .\Start-EdgeBuild.ps1
   ```
   Stages re-run by themselves when their inputs change (`TrackedInputs` and `Feeds` in
   `build/windows/Start-EdgeBuild.ps1`); nothing needs `-Force`.
3. They write `edge1-sdcard.img.gz` with Etcher, boot the board (Armbian stays on the
   eMMC), and send back from the card's `EDGE1BOOT` drive **`edge1-boot.log`**,
   **`edge1-pstore.bin`** and the **`edge1-logs`** folder, plus photos of the HDMI screen.
4. Read `edge1-logs/boot-*/<stage>/` first (plain text: logcat main/system/crash,
   dmesg, getprop, ps, `dumpsys -l`, SurfaceFlinger), then decode
   `build/edge1-pstore.py edge1-pstore.bin` → the last seconds' kernel console, panic
   records and logcat (pmsg). Find the first fatal thing, fix it, also fix whatever
   else the log shows, verify offline (below), push, reply.

Replies to the owner: **Russian, short, professional** — what broke, what was fixed,
the exact command to run, what to send back. They value a lot of work per round trip:
read the whole log, fix everything visible, and read ahead in AOSP/kernel sources for
the next failure before it costs a cycle.

## Reading what comes back

| Signal | Meaning |
|---|---|
| `edge1-logs/boot-0/120s`, `/completed`, `/timeout` | written by `edge1-bootwatch` (userdebug) 120s after `boot`, 30s after `sys.boot_completed`, or at the 600s timeout; `boot-1` is the boot before. Minutes of log, not seconds. |
| `edge1_stage=booti` in edge1-boot.log | U-Boot side fine; the kernel was started |
| `edge1_prev=found` | `edge1-pstore.bin` holds the previous attempt's logs |
| `edge1_prev=none`, file is `0xff` with flipped bits | power was cut — RAM decayed, no log |
| sys LED double-blink / even 2.5Hz blink / dark | kernel running / panicked / never started |

The ramoops region (1MiB at `0x30100000`, added to the dtb by `build-kernel.sh`)
survives only a **warm** reset. Things that make one: a panic (`panic=20`), init's own
fatal reboots, and `edge1-bootwatch` (userdebug: writes `edge1-logs`, then reboots warm
if `sys.boot_completed` is not set 600s after `boot`). Tell the owner to let the board
reboot by itself once, then pull the card — never to cut power while it is stuck.

## The boot chain (settled — do not re-litigate)

RK3399 BootROM: SPI NOR → eMMC → SD. Armbian's U-Boot **2022.07** on the eMMC runs,
its distro boot scans the card first (`boot_targets=usb0 mmc1 mmc0 ...`), finds
`boot.scr` on partition 1 (`bootfs`, FAT, 128MiB), which `load`s `Image`,
`ramdisk.img`, `edge1.dtb` and `booti`s with `androidboot.boot_devices=fe320000.mmc`.
That U-Boot has **no setexpr** (and no read/gpio/nvme/abootimg/led): the script may
use only `echo test setenv run load env fatwrite itest booti`
(`build/check-uboot-script.py`, enforced at build and by `verify-tree.sh`). Our own
mainline U-Boot on the card has never run on this board (needs TST mode). `docs/BOOT.md`
has the full story.

## Offline verification (run before every push)

| Tool | Checks |
|---|---|
| `build/verify-tree.sh` | the whole tree's consistency checks; must end `errors: 0` |
| `build/dev/check-kernel-fragment.sh <linux-6.12>` | every symbol in the kernel fragment takes, via the kernel's own defconfig + merge_config + olddefconfig and `scripts/dummy-tools` (seconds, no cross compiler). A miss stops the owner's Kernel stage. |
| `build/dev/test-bootscr-uboot2022.sh <u-boot-v2022.07> <card.img>` | runs the card's boot.scr through distro boot on a v2022.07 sandbox with the board's command set and environment; `EDGE1_PRELOAD=edge1-pstore.bin@0x30100000` replays a capture |
| `build/build-images.sh <fake-tree> sdcard` | builds a card from a synthetic `boot.img` (see the test script's notes) |

Reference sources used in this work: the Linux v6.12.111 tree; U-Boot v2022.07 and
v2026.07; `system/core` of Android 14 (`24Q2-release`, sparse); GloDroid's
`glodroid_device` (Android 14 on mainline RK3399 — the best reference for kernel config,
fstab, sepolicy, init). The sandbox's network proxy refuses `android.googlesource.com`,
and the `aosp-mirror` GitHub copies of `system/sepolicy` and `hardware/interfaces` are
not reachable from it.

## Progress, card by card

| Card | Got to | Fixed |
|---|---|---|
| 1–4 | Armbian booted | the BootROM prefers the eMMC; added `bootfs` + `boot.scr` |
| 5 | script ran, declined | `setexpr` not in 2022.07; files + `load` instead |
| 6 | `booti` | — (added ramoops capture, LED panic indicator) |
| 7 | kernel + HDMI console, `/init` | SELinux built but not in `CONFIG_LSM` |
| 8 | first stage, fstab | `avb=vbmeta` in fstab; found ahead: `ANDROID_BINDER_DEVICES=""`, Android base kernel config (netfilter, IPv6) |
| 9 | second stage: keystore2, apexd | no `mount_all` in init.edge1.rc; `CPUSETS_V1`; `printk.devkmsg=on` |
| 9b | `/data` mounted (FBE), apexd, netbpfload, zygote; restart loop | allocator had no SELinux exec label (init refuses even permissive); task_profiles_29 → schedtune (vendor task_profiles.json); audio HAL APEX; bootwatch |
| 10 | first capture of Android itself (bootwatch rebooted warm): zygote aborts, SurfaceFlinger cannot present | zygote: `MediaProfiles CHECK(cameraIds.size() > 0)` → camera-0 profiles; no ashmem in 6.12 → `sys.use_memfd=true` (product prop) fixes the HWC FMQ; effect HAL needs `audio_effects_config.xml`; configstore (API-29 package) overridden away; `CONFIG_FTRACE`; system props moved off vendor; vold off the boot card; bootwatch writes `edge1-logs` to bootfs; `log_buf_len=4M`, `ro.logd.size` 2MiB |

## Open, in rough order

* Card 11: does zygote get past preload and system_server start? Does SurfaceFlinger
  present (boot animation on HDMI)? `edge1-logs/boot-0/120s/logcat.txt` answers both;
  `surfaceflinger.txt` shows the display and composer state.
* Audio: the APEX is in (`vendor.audio-hal-aidl` ran on card 10); the effect HAL
  should now stay up with `audio_effects_config.xml`. If its libraries are not found
  (`lib*aidl.so`), it logs and skips them - check, and point the paths at the APEX.
* Wi-Fi: brcmfmac is built in and asks for firmware at 1.8s, before `/vendor` exists.
  Re-probe the SDIO host (`fe310000.mmc`) from init after `/vendor` mounts, or enable the
  firmware sysfs fallback.
* vold: the boot card is no longer voldmanaged (fstab). When the system moves to the
  eMMC, the installer has to put the `sdcard1` line back for that install.
* `prng_seeder` (no `/dev/hw_random`: the 6.12 rockchip-rng driver knows only rk3568);
  `flags_health_check` floods the console with permissive denials whenever an
  "updatable" process crash-loops; SELinux enforcing; Bluetooth (`BCM4359C0.hcd`); the
  eMMC installer; our own U-Boot in TST mode.
