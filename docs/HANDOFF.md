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
   eMMC), and send back from the card's `EDGE1BOOT` drive **`edge1-boot.log`** and
   **`edge1-pstore.bin`**, plus photos of the HDMI screen.
4. Decode: `build/edge1-pstore.py edge1-pstore.bin` → kernel console log, panic
   records, and logcat (pmsg). Find the first fatal thing, fix it, also fix whatever
   else the log shows, verify offline (below), push, reply.

Replies to the owner: **Russian, short, professional** — what broke, what was fixed,
the exact command to run, what to send back. They value a lot of work per round trip:
read the whole log, fix everything visible, and read ahead in AOSP/kernel sources for
the next failure before it costs a cycle.

## Reading what comes back

| Signal | Meaning |
|---|---|
| `edge1_stage=booti` in edge1-boot.log | U-Boot side fine; the kernel was started |
| `edge1_prev=found` | `edge1-pstore.bin` holds the previous attempt's logs |
| `edge1_prev=none`, file is `0xff` with flipped bits | power was cut — RAM decayed, no log |
| sys LED double-blink / even 2.5Hz blink / dark | kernel running / panicked / never started |

The ramoops region (1MiB at `0x30100000`, added to the dtb by `build-kernel.sh`)
survives only a **warm** reset. Things that make one: a panic (`panic=20`), init's own
fatal reboots, and `edge1-bootwatch` (userdebug: reboots warm if
`sys.boot_completed` is not set 600s after `boot`). Tell the owner to let the board
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

## Open, in rough order

* Confirm the allocator now starts and SurfaceFlinger draws (boot animation). Then the
  zygote/system_server restart loop seen on card 9b — its cause was off-screen; the next
  capture's logcat (pmsg) should show it.
* Audio: `com.android.hardware.audio` added conditionally; audioserver was crashing
  (SIGSEGV) with no HAL. If the APEX is absent in this release, find the right package
  from the owner's `module-probe.txt` (Probe stage).
* Wi-Fi: brcmfmac is built in and asks for firmware at 1.8s, before `/vendor` exists.
  Re-probe the SDIO host (`fe310000.mmc`) from init after `/vendor` mounts, or enable the
  firmware sysfs fallback.
* vold: the fstab's `voldmanaged=sdcard1` matches the card we boot from
  (`/devices/platform/fe320000.mmc`); after the first unlock vold will offer it as
  removable storage. Decide before anyone presses "format".
* `prng_seeder` hangs (no `/dev/hw_random`); properties set from vendor that belong to
  system (`ro.adb.secure`, `persist.sys.usb.config`); SELinux enforcing; Bluetooth
  (`BCM4359C0.hcd`); the eMMC installer; our own U-Boot in TST mode.
