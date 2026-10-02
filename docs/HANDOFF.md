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
   **`edge1-pstore.bin`** and the whole **`edge1-logs`** folder (zipped), plus photos
   of the HDMI screen.
4. Read `edge1-logs/boot-0/` first: `logcat.txt` and `dmesg.txt` are the whole boot,
   streamed from its first line (main/system/crash/events; the kernel log); the
   `120s`, `completed`, `timeout` subfolders hold getprop, ps, mounts, `dumpsys -l` and
   SurfaceFlinger at that moment. `boot-1` is the boot before. Then
   `build/edge1-pstore.py edge1-pstore.bin` → the last seconds before the reset:
   kernel console, panic records, logcat (pmsg). Find the first fatal thing, fix it,
   also fix whatever else the log shows, verify offline (below), push, reply.

Replies to the owner: **Russian, short, professional** — what broke, what was fixed,
the exact command to run, what to send back. They value a lot of work per round trip:
read the whole log, fix everything visible, and read ahead in AOSP/kernel sources for
the next failure before it costs a cycle.

## Reading what comes back

| Signal | Meaning |
|---|---|
| `edge1-logs/boot-0/logcat.txt`, `dmesg.txt` | streamed by `edge1-bootwatch` (userdebug) for the whole boot, synced every 10s; snapshots of state in `120s`, `completed` (30s after `sys.boot_completed`), `timeout` (600s); `boot-1` is the boot before |
| `edge1_stage=booti` in edge1-boot.log | U-Boot side fine; the kernel was started |
| `edge1_prev=found` | `edge1-pstore.bin` holds the previous attempt's logs |
| `edge1_prev=none`, file is `0xff` with flipped bits | power was cut — RAM decayed, no log |
| sys LED double-blink / even 2.5Hz blink / dark | kernel running / panicked / never started |

The ramoops region (3.25MiB at `0x30100000`: 1MiB console, 2MiB pmsg; added to the dtb
by `build-kernel.sh`; the decoder also reads the 1MiB layout of cards 6–10)
survives only a **warm** reset. Things that make one: a panic (`panic=20`), init's own
fatal reboots, and `edge1-bootwatch` (userdebug: writes `edge1-logs`, then reboots warm
if `sys.boot_completed` is not set 600s after `boot`). Tell the owner to let the board
reboot by itself once, then pull the card — never to cut power while it is stuck.

## The boot chain (settled — do not re-litigate)

RK3399 BootROM: SPI NOR → eMMC → SD. Armbian's U-Boot **2022.07** on the eMMC runs,
its distro boot scans the card first (`boot_targets=usb0 mmc1 mmc0 ...`), finds
`boot.scr` on partition 1 (`bootfs`, FAT, 512MiB: boot files plus `edge1-logs`), which `load`s `Image`,
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
| 11 | system_server runs, but the watchdog kills it (67s, ×3) in `AudioService` | `sys.use_memfd` was reset to false by `init.rc` post-fs-data → `/product` rc sets it back; the AIDL audio HAL rejected `audio_policy_configuration.xml` (HIDL format, `halVersion="AIDL"`, unresolvable `xi:include`s) and registered no `IModule/default` → self-contained v7 file validated against the HAL's XSD (`build/schema/`); bootwatch streams the whole logcat/dmesg; bootfs 512MiB; ramoops 3.25MiB |
| 12 | memfd on (no ashmem errors), whole-boot logs on the card; audio HAL aborted 129× and system_server was killed 6×; display headless | the HAL forbids an external device (HDMI, `connection: hdmi`) in `<attachedDevices>` and ModulePrimary cannot connect external ones → the primary output is a built-in "Speaker" that plays to ALSA card 0 = `hdmi-sound`; the minigbm allocator opened card0 first and held DRM master, so drm_hwcomposer made a null display → composer started at `late-fs`; verify-tree checks both |

## Open, in rough order

* Card 13: the audio HAL stays up (no `convertModuleConfigToAidl` abort), audioserver
  and system_server get past `AudioService`; the composer logs pipelines instead of
  "DRM/KMS master access required", and SurfaceFlinger's display 0 has the monitor's
  mode rather than the null display's 1024x768 (which is what card 11 showed); boot
  animation on HDMI. Then whatever system_server meets next.
* Real HDMI audio (hotplug, AUDIO_DEVICE_OUT_HDMI, passthrough) needs a HAL module that
  connects external devices; ModulePrimary does not. "Speaker" on card 0 until then.
* system_server's `LowMemDetector` PSI trigger fails with EINVAL (unprivileged
  triggers need a 2s-multiple window on 6.x); `libprocessgroup` AddTidToCgroup EACCES
  on `foreground`; idmap2 fails one auto-generated RRO. None fatal so far.
* Wi-Fi: brcmfmac is built in and asks for firmware at 1.8s, before `/vendor` exists.
  Re-probe the SDIO host (`fe310000.mmc`) from init after `/vendor` mounts, or enable the
  firmware sysfs fallback.
* vold: the boot card is no longer voldmanaged (fstab). When the system moves to the
  eMMC, the installer has to put the `sdcard1` line back for that install.
* `prng_seeder` (no `/dev/hw_random`: the 6.12 rockchip-rng driver knows only rk3568);
  `flags_health_check` floods the console with permissive denials whenever an
  "updatable" process crash-loops; SELinux enforcing; Bluetooth (`BCM4359C0.hcd`); the
  eMMC installer; our own U-Boot in TST mode.
