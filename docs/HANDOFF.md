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
4. Read `edge1-logs/boots.txt` first: one line per boot - when it started, its options,
   how long it lasted, whether it completed, whether its ramoops was saved. Then the
   boot directories, `edge1-logs/boot-NNNNN/` (the last ten): `logcat.txt` and
   `dmesg.txt` are the whole boot, streamed from its first line (main/system/crash/
   events; the kernel log); `alive.txt` is when it was last seen; `pstore/` (copied by
   the next boot from `/sys/fs/pstore`) is its last seconds if it ended in a reset; the
   `120s`, `completed`, `timeout` subfolders hold getprop, ps, mounts, `dumpsys -l`,
   SurfaceFlinger, connectivity and video state at that moment. Then
   `build/edge1-pstore.py edge1-pstore.bin` → the last reset's region as U-Boot saved
   it: kernel console, panic records, logcat (pmsg). Find the first fatal thing, fix
   it, also fix whatever else the log shows, verify offline (below), push, reply.
5. `EDGE1BOOT:edge1-options.txt` is read at every boot (CPU and GPU clock limits): the
   owner can change it in Windows between two boots, without a build. It ships with
   six modes described in Russian - power test (on), full speed, video, games, quiet,
   minimal - each setting all three limits; the lowest one left on wins.

Replies to the owner: **Russian, short, professional** — what broke, what was fixed,
the exact command to run, what to send back. They value a lot of work per round trip:
read the whole log, fix everything visible, and read ahead in AOSP/kernel sources for
the next failure before it costs a cycle.

## Reading what comes back

| Signal | Meaning |
|---|---|
| `edge1-logs/boots.txt` | a line per boot: start, options, last seen, completed or not, ramoops saved |
| `edge1-logs/boot-NNNNN/logcat.txt`, `dmesg.txt` | streamed by `edge1-bootwatch` (userdebug) for the whole boot, synced every 5s; a `thermal` line every 5s in dmesg (temperatures, fan, CPU/GPU clocks, core rail voltages); snapshots of state in `120s`, `completed` (30s after `sys.boot_completed`), `timeout` (300s, `persist.vendor.edge1.bootwatch.timeout`); the last ten boots are kept |
| `boot-NNNNN/pstore/` | that boot's ramoops, saved by the next boot: present when it ended in a reset |
| ramoops readable but every line has bit errors | a hardware reset without a power cut (card 19): the DRAM went unrefreshed for a while - watchdog, PMIC or brown-out, not a kernel panic |
| `edge1_stage=booti` in edge1-boot.log | U-Boot side fine; the kernel was started |
| `edge1_prev=found` | `edge1-pstore.bin` holds the previous attempt's logs |
| `edge1_prev=none`, file is `0xff` with flipped bits | power was cut — RAM decayed, no log |
| sys LED double-blink / even 2.5Hz blink / dark | kernel running / panicked / never started |

The ramoops region (3.25MiB at `0x30100000`: 1MiB console, 2MiB pmsg; added to the dtb
by `build-kernel.sh`; the decoder also reads the 1MiB layout of cards 6–10)
survives only a **warm** reset. Things that make one: a panic (`panic=20`), init's own
fatal reboots, and `edge1-bootwatch` (userdebug: writes `edge1-logs`, then reboots warm
if `sys.boot_completed` is not set 300s after `boot`). Tell the owner to let the board
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
| `build/dev/check-kernel-fragment.sh <linux-6.12>` | the kernel patches apply, and every symbol in the kernel fragment takes, via the kernel's own defconfig + merge_config + olddefconfig and `scripts/dummy-tools` (seconds, no cross compiler). A miss stops the owner's Kernel stage. |
| `build/dev/check-edge1tools.sh <android-all-14.jar>` | Edge1 Tools' resources link (aapt2) and its Java compiles against the R that comes out - what the build does to the app; Robolectric's android-all 14 stands in for the framework (the script says where to get it) |
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
| 13 | audio HAL up; audioserver waited for `IModule/bluetooth` (declared by the APEX's VINTF, no module in our XML) → AudioService hung, watchdog ×6; composer still headless | bluetooth module added, usb removed (exactly the APEX's declared set; verify-tree checks); the composer opens card0 only when SurfaceFlinger registers (52.98s, after the allocator) → kernel patch: no implicit DRM master on open, `SET_MASTER` for whoever asks while none exists; kernel patch mechanism in build-kernel.sh; bootwatch timeout 300s |
| 14 | **boot completed** (`sys.boot_completed=1`); boot animation on HDMI at 1920x1080@60 (Samsung EDID) - the DRM-master patch worked; then black: FallbackHome, "no home" | no launcher/setup wizard/IME in AOSP's atv_base → TvSampleLeanbackLauncher, TvProvision, LeanbackIME, DocumentsUI (+ allowlists); SystemUI crash loop = minigbm mapper could not open card0 (0660) in app processes → card0/card1 0666 + gpu_device; Bluetooth crash loop (no HAL) → BT features off; cgroup v1 moves by system_server EACCES → kernel patch 0002 (CAP_SYS_NICE); /dev/rfkill for the BT HAL; images: SD card only |
| 15 | leanback launcher found ("real home found"), TvProvision ran; launcher and SystemUI still crash-looped: "Failed to initialize driver" only in app-uid processes | init.edge1.rc chmod'ed `/dev/dri/card0` back to 0660 at `boot`, after ueventd set 0666 → chmod removed (ueventd alone owns node modes; verify-tree guards it); F-Droid preinstalled via `build/fetch-fdroid.sh`; snapshots list `/dev` node modes; HDMI-CEC investigated and dropped by the owner |
| 16 | **in the launcher** on HDMI, SystemUI up, F-Droid installed (signature matched), TvSettings works; no network (Ethernet unplugged), no Wi-Fi, no Bluetooth; TvSettings died in "Add accessory" (`BluetoothAdapter` null) | Wi-Fi: brcmfmac (built in) asked for firmware at 1.4s, before /vendor → firmware also in the ramdisk's `/lib/firmware/brcm`; `wpa_supplicant`/`hostapd` were never built (`WPA_SUPPLICANT_VERSION` unset; the probe cannot see Make guards) → set, with the module's own rc and our `wpa_supplicant.conf`; `android.hardware.wifi-service` had no legacy HAL and blocked Wi-Fi → removed, framework runs HAL-less. Bluetooth: kernel `hci_bcm` (`BT_HCIUART=y`, `POWER_SEQUENCING=y`) + Armbian's `BCM4359C0.hcd` (ramdisk + vendor) → hci0; the AOSP HAL binds it as an HCI user channel; `/dev/rfkill` back to root-only (the HAL soft-blocks hci0 if it can, then cannot bind); BT features back; A2DP source off (no BT audio provider). UI sounds (`AudioTv.mk`); `has_HDR_display=false`; snapshots add `connectivity.txt`; verify-tree [11] |
| 17 | **Bluetooth works** (hci0 patched with BCM4359C0.hcd, HAL bound, adapter ON); Wi-Fi up (wlan0, supplicant, scans) but every association with the owner's WPA/WPA2 AP failed 4s in, `status_code=16`; developer options crash; userdata 1.6GiB | `brcmfmac.feature_disable=0x82000` (no firmware 4-way handshake/SAE; status 16 is brcmfmac's catch-all); bootwatch turns on Wi-Fi verbose logging; kernel patch 0003 (`/sys/class/android_usb` - UsbService needs it or `getCurrentFunctions()` throws in TvSettings); userdata 16GiB, image file ends 64MiB into it; USB Wi-Fi/BT adapter drivers + linux-firmware blobs (ramdisk + vendor), `persist.vendor.edge1.wifi.iface`; Edge1 Tools app (performance overlay + first-boot installer); bundled apps via `build/fetch-apps.sh` (the owner's `D:\android_khadas\apks` folder + VLC/Material Files/Aurora Store from F-Droid; Projectivy `com.spocky.projengmenu` made HOME) |
| 18 | **Wi-Fi connected** (the MikroTik, 5GHz 11ac), developer options open, the overlay works (40-45C), nine apps installed from Edge1 Tools; then a **reset loop**: hard resets (no shutdown logged, boot reason plain "reboot") about 10s after each boot completed, once the overlay was set to start at boot; a panfrost job fault (DATA_INVALID_FAULT) the moment the overlay started; system_server ran with a 16MB Java heap | Java heap: nothing set `dalvik.vm.heap*`, so every process had AndroidRuntime's 16MB default → `phone-xhdpi-4096-dalvik-heap.mk`. Overlay: its EGL probe (the GPU fault) replaced by the sysfs driver name; at boot it waits 30s, and two boots in a row that do not last 3 minutes after it turn its autostart off. No automatic HOME (Edge1 Tools has a "Default launcher" button). Preinstall runs 3 minutes after boot; Edge1 Tools is not "stopped" at first boot (sysconfig). Fan: `pwm-fan` was `=m`, the fan never ran → `=y`. dex2oat on the A53s. Bootwatch: temperatures, fan and clocks in the kernel log every 5s, sync every 5s (was 10). Video: hantro built in, `/dev/video*` `/dev/media*` wildcards, `edge1-v4l2-probe` → `video.txt`, `docs/HW_DECODE.md` |
| 19 | resets at different moments every boot: ~3s after the first boot completed, and on opening Edge1 Tools in the second; 40-57C; the ramoops region came back readable but with bit errors on every line - a hardware reset (unrefreshed DRAM), not a panic. Also: the PCIe controller stuck in deferred probe (its PHY was a module) and re-probed whenever any device bound | A log per boot (`boot-NNNNN`, ten kept, `boots.txt`, `alive.txt`, each boot's ramoops saved into its own folder by the next); `edge1-options.txt` on EDGE1BOOT with CPU/GPU clock limits, shipped at A72 1416MHz / GPU 600MHz as a power test; core rail voltages and GPU clock in the thermal line; PCIe PHY built in. Owner: no IR remote (driver not built). Toward a release build: SELinux rules for every non-bootwatch denial of cards 18-19 (bootwatch permissive + unaudited), checked offline with `build/dev/check-sepolicy.sh`; A2DP (the BT audio provider's VINTF fragment); exFAT + USB 3 disks; zram; standby without suspend; adb needs authorization; the builder's language/time zone; private signing keys (dev-keys) - docs/RELEASE.md |
| 20 | first build stopped at the module probe (a false sepolicy duplicate, fixed); the second came back with edge1-boot.log (`booti`, `edge1_prev=none`), a ramoops region cleared as by a power cut, the default edge1-options.txt, and **no edge1-logs** - Android apparently never got as far as its log recorder. The owner: **a black screen from the start, no "android" text** - so not even the kernel console came up, i.e. the kernel stopped before the display driver (~1.1s), where the PCIe probe runs. Power: a **Baseus 100W GaN power bank** (USB-C PD) | The PCIe controller out of the kernel: building its PHY in was the build's one change that runs early in the kernel and can hang it (mainline's RK3399 PCIe PHY is what Armbian patches; the slot is empty). The bootwatch itself was run under mksh, Android's shell, and works. Bundled apps: offered one by one in Edge1 Tools, installed only on request |
| 21 | **Android up again**: boot completed at 111s, ran 833s with the power-test clocks (A72 1416MHz, GPU 600MHz) and no reset - one boot in `boots.txt`; SmartTube played. `video.txt` exactly as planned: rkvdec `S264` up to 4096x2560 and `VP9F` 4096x2304, hantro `MG2S` 1920x1088 and `VP8F` 3840x2160, `/dev/media0` hantro, `/dev/media1` rkvdec. The owner could not tell whether there was sound, and an Xbox pad has no volume keys: the HAL opened ALSA card 0 36 times, so it played - at **media volume 2 of 15** (`volume_changed` in the logcat), about -40 dB | `ro.config.media_vol_default=15`, and the TV volume curve for "Speaker" (the HDMI output). **Settings > Sound & display**: Edge1 Tools' `SoundActivity` handles `com.android.tv.settings.SOUND`, so TvSettings lists it on its main screen - volume -/+, a left/right test tone, where the sound goes, and a button to TvSettings' Display & Sound (which Device Preferences hides once a Sound handler exists). Bootwatch: `audio.txt` (ALSA state, `dumpsys audio`, `dumpsys media.audio_flinger`) |
| 22 | Sound at 15 of 15 on the HDMI "speaker"; Settings' new **Sound & display** entry opened SoundActivity, and TvSettings' Display & Sound twice. 593s, no reset (the power-test clocks); the session ended in a restart chosen in Settings, after which no boot-00002 and an edge1-boot.log still from the cold start - either the card was pulled, or the warm reboot never reached boot.scr (ask). **com.android.bluetooth ran in the zygote domain**: `seapp_context_lookup: No match ... seinfo default`, as on card 21 - since the build signs with its own keys (card 18, test keys: `bluetooth` domain) | Bluetooth: no cause found in the sources (Soong signs Bluetooth.apk with `<keys>/bluetooth`, keys.conf's @BLUETOOTH is the same file); `packages.txt` now has each package's signature hash and local-config prints the keys' - AOSP's test bluetooth key is `d77294ce`. **logs=0** in edge1-options.txt stops every write to the card: boot.scr reads it with `env import -t -r ... logs` (tested on the 2022.07 sandbox), the bootwatch only applies the clocks and leaves the partition read-only. **edge1-ctl** (vendor, root, own domain): Edge1 Tools' modes and logs switch, through sys.edge1.ctl / persist.sys.edge1.perf and init.edge1.ctl.rc on /product; it writes the picked mode into the card's file. **Edge1 Tools in Material 3** (platform widgets, M3 dark scheme, focus ring), runs as the system user; the six modes, overlay, sound, launcher, logs switch, bundled apps |

## Lessons that cost a card each (check these first next time)

* **Device node modes belong to `ueventd.edge1.rc` only.** It is parsed (imported
  from `/system/etc/ueventd.rc`) and works; an rc `chmod` at `boot` silently overrode it.
* **Graphics on this board:** rockchip-drm has no render node, so minigbm opens
  `/dev/dri/card0` in *every* process (allocator, mapper in each app) - it must be 0666
  and `gpu_device`. drm_hwcomposer opens card0 only when SurfaceFlinger registers, so
  it cannot win the implicit-master race; kernel patch 0001 makes master explicit.
* **The AIDL audio HAL builds its modules from `audio_policy_configuration.xml`**: v7
  format, no xi:include, built-in devices only in `<attachedDevices>` (HDMI is a
  "Speaker" on ALSA card 0), and exactly the IModule set the APEX declares (default,
  r_submix, bluetooth). verify-tree validates against `build/schema/` and the HAL rules.
* **init.rc resets `sys.use_memfd` to false in post-fs-data**; the `/product` rc sets it
  back. There is no ashmem in 6.12.
* **AOSP's TV base has no launcher, setup wizard or keyboard** - device.mk adds the AOSP
  ones. Check the installed app list (logcat paths) against the tree's module list.
* **Mainline vs Android common kernel gaps** are fixed as patches in
  `device/khadas/edge/kernel/patches/` (applied by build-kernel.sh; check-kernel-fragment.sh
  checks they apply): 0001 DRM master, 0002 cgroup v1 CAP_SYS_NICE.
* **F-Droid** comes from `build/fetch-fdroid.sh` (run by place-device.sh): downloaded
  on the owner's machine (f-droid.org is not reachable from this sandbox), accepted only
  with F-Droid's signing certificate (SHA-256 43238d51...a9c9ccab; card 16's F-Droid
  was accepted, so the pinned value matches what f-droid.org serves),
  cached in `~/.cache/edge1`; on failure the image is built without it.
* **The module probe greps `LOCAL_MODULE`/`name:` text; it cannot see Make guards.**
  `wpa_supplicant` and `hostapd` passed it for 16 cards while
  `external/wpa_supplicant_8/Android.mk` skipped them (no `WPA_SUPPLICANT_VERSION`), and
  PRODUCT_PACKAGES drops unknown names silently. When a HAL "is not there", check the
  module's guard before anything else.
* **Built-in drivers load firmware before `/vendor` exists.** brcmfmac and hci_bcm ask
  within 2s of power-on; their firmware goes to the ramdisk's `/lib/firmware` as well
  (verify-tree [11] checks every `/vendor/firmware` file has a ramdisk twin).
* **No vendor Wi-Fi HAL on brcmfmac.** A declared IWifi that cannot start blocks Wi-Fi;
  undeclared, the framework runs HAL-less (wificond + wpa_supplicant), as GloDroid does.
* **Bluetooth = kernel hci_bcm + AOSP's default AIDL HAL over an HCI user channel**, and
  `/dev/rfkill` must stay root-only (the HAL soft-blocks hci0 when it can, and the kernel
  then refuses the bind with -ERFKILL).
* **Third-party APKs are not system prebuilts.** The build rewrites a PRESIGNED APK
  with compressed native libraries (breaking its v2 signature) or, with an SDK
  version set, refuses it; and Android extracts no libraries for an unupdated system
  app. They ship as files and Edge1 Tools installs them on first boot.
* **`cmd | grep -q` under `set -o pipefail` is a bug, every time.** grep exits on the
  first match, the writer dies of SIGPIPE (141), and the pipeline "fails". The first
  fetch-apps run refused every APK this way (`unzip -l | grep -q`); provision-wsl.sh
  hit the same class three times. Test with a real-sized input, or don't pipe.
* **brcmfmac reports every connect failure as status 16.** Card 17's associations
  failed inside the firmware's own WPA handshake; `brcmfmac.feature_disable=0x82000`
  moves it to wpa_supplicant, where a wrong key says so.
* **Nothing sets the Java heap unless the device does.** Without `dalvik.vm.heapsize`
  every Java process, system_server included, gets AndroidRuntime's built-in 16MB
  ("Clamp target GC heap from 40MB to 16MB" in logcat). Device trees inherit one of
  `frameworks/native/build/*-dalvik-heap.mk`; this one did not until card 18.
* **Android 14 installs system apps "stopped"** (`config_stopSystemPackagesByDefault`):
  no BOOT_COMPLETED until the app is opened once. A system app that must run at first
  boot needs `<initial-package-state package=".." stopped="false"/>` in a sysconfig
  file (Edge1 Tools: `edge1-tools.xml`).
* **defconfig's `=m` is "off" here** (no modules are shipped): the fan driver
  (`SENSORS_PWM_FAN`) sat at `=m` until card 18. check-kernel-fragment only proves
  what the fragment names; anything the board needs that it does not name, check.
* **A hard reset with nothing logged is not necessarily heat.** Card 18's overlay
  showed 40-45C; the resets came right as the overlay started (and with it a GPU job
  fault). Read the temperatures before blaming them - bootwatch now logs them.
* **A module in defconfig can leave a built-in driver probing forever.** The PCIe
  controller was `=y`, its PHY `=m`: the controller deferred and was re-probed every
  time any other device bound, for the whole boot. A "deferred probe pending" line in
  dmesg names the driver to look at.
* **Ramoops with bit errors is a hardware reset.** A software reboot (panic, watchdog
  in init, bootwatch) leaves it clean (card 16); a power cut leaves nothing (card 17);
  card 19's was all there and flipped throughout - the DRAM lost refresh without losing
  power. Look at power and voltages, not at the last log line.
* **Product rc files run as init; vendor ones as vendor_init.** /sys/power/wake_lock
  and swapon are init's (`init.edge1.standby.rc` is on /product for that), and
  `swapon_all`/`mount_all` run in init itself even from a vendor file.
* **AOSP's `development/tools/make_key` exits 1 whatever happens** (its EXIT trap ends
  in `exit 1`): judge it by the files it leaves, never by its status.
* **Warnings for the owner go to stdout.** The Windows transcript (the report) keeps a
  native command's stdout, not its stderr - local-config's key failure was invisible.
* **SELinux before a build:** `build/dev/check-sepolicy.sh <system/sepolicy>` compiles
  the vendor policy with AOSP's - every neverallow, and public types only for vendor.
* **Volume on a TV box.** AudioService starts a television's media volume at a quarter
  (`MAX/4`, 3 of 15) and keeps only real HDMI/ARC devices at full volume. This board's
  HDMI is the HAL's "Speaker", so Android's volume scales the signal: near silence
  that looks like no sound. `ro.config.media_vol_default` sets the start; the volume
  itself is in `dumpsys audio` (`audio.txt`).
* **Other people's projects are patched, not forked.** This repository is the only
  one the build can push to, so changes to synced projects live in
  `device/khadas/edge/patches/<path>/` and `build/apply-patches.sh` applies them
  (kernel: build-kernel.sh, same scheme). Export with `git format-patch`; a commit
  whose message swallowed a diff (an empty-bodied original) makes a patch that
  applies its hunks twice and fails - check `grep -c '^@@'` against the commit.
* **A seccomp policy is part of a codec's ABI.** Code new to a media service (here
  FFmpeg's request hwaccels: select() is pselect6) needs its syscalls in the
  service's policy, or the first use kills the process with SIGSYS.
* **aapt2: a dotted style name is a child.** `<style name="Text.Body">` without
  `parent=` inherits `Text`, and a missing `Text` stops the link (the first build
  of the Material 3 screens, at 11%). A regex check of `@style/` references does
  not see it; `build/dev/check-edge1tools.sh` runs the real aapt2.
* **Images:** only the SD card is built during bring-up (`stage_images` in
  provision-wsl.sh, build-images.sh default); eMMC/NVMe are commented out.

## Open, in rough order

* Card 23, hardware decoding (docs/HW_DECODE.md, phases 2-3, built and never
  run): the first build syncs external/ffmpeg, ffmpeg_codec2 and libudev-zero and
  place-device.sh applies patches/ - a patch that does not apply stops it there.
  On the board: the overlay's "HW decode:" names c2.ffmpeg.h264/vp9/mpeg2/vp8;
  a video in SmartTube or VLC raises the decoders' interrupts (video.txt) and logs
  `ffmpeg_hwaccel_init: ... hw device = drm`. If the codec service crash-loops,
  logcat's SIGSYS line names a syscall for media/c2-ffmpeg-extended.policy; if it
  plays black or garbled, persist.vendor.edge1.hwdec=0 is software for comparison.
  4K is expected to drop frames until zero copy (the frame copy from uncached
  V4L2 buffers).
* Card 23: Edge1 Tools' new screen - a mode picked there changes the clocks at
  once (the header shows them) and the active block in EDGE1BOOT:edge1-options.txt;
  the logs switch writes logs=0 and the next boot leaves the card alone (no new
  boot folder, edge1-boot.log unchanged). `packages.txt`: Bluetooth's signature hash
  against the report's "keys: bluetooth signature hash" - equal means the signing
  is right and mac_permissions is not; d77294ce means it was signed with AOSP's
  test key. Ask whether the restart from Settings on card 22 came back.
  Power: card 21 ran 833s and card 22 593s at the test clocks without a reset, from
  the Baseus power bank. Next: full speed (the mode in Edge1 Tools), and a longer
  session; resets coming back at full speed mean power at the top OPPs.
* Hardware video decode: docs/HW_DECODE.md. Phase 1 confirmed on card 21 (both
  decoders and their formats in `video.txt`); next the FFmpeg Codec2 service
  (software), then v4l2-request for H.264 and VP9. HEVC needs a newer kernel.
* Bluetooth pairing of a remote/gamepad not yet tried by the owner.
* Bluetooth audio (A2DP source): the provider factory registers since the card 19 round
  (`android.hardware.bluetooth.audio-impl`); not tried with headphones yet.
* HDMI-CEC (owner: not needed now). Findings for later: every AOSP 14 CEC HAL
  (`tv.hdmi.cec`, `tv.hdmi.connection`, `tv.cec@1.1`) is a mock that reads/writes FIFOs,
  and `CONFIG_DRM_DW_HDMI_CEC` is `=m` (modules are not loaded), so there is no
  `/dev/cec0`. It needs `=y` plus a HAL implementing IHdmiCec and IHdmiConnection over
  the Linux CEC API (CEC_ADAP_S_LOG_ADDRS, CEC_TRANSMIT/RECEIVE, CEC_DQEVENT state
  changes as hotplug + physical address); the mocks in
  hardware/interfaces/tv/hdmi/{cec,connection}/aidl/default are the template.
* init.rc's blkio.weight / cpuctl uclamp.latency_sensitive writes fail (ACK-only
  files); harmless.
* Real HDMI audio (hotplug, AUDIO_DEVICE_OUT_HDMI, passthrough) needs a HAL module that
  connects external devices; ModulePrimary does not. "Speaker" on card 0 until then.
* system_server's `LowMemDetector` PSI trigger fails with EINVAL (unprivileged
  triggers need a 2s-multiple window on 6.x); `libprocessgroup` AddTidToCgroup EACCES
  on `foreground`; idmap2 fails one auto-generated RRO. None fatal so far.
* vold: the boot card is no longer voldmanaged (fstab). When the system moves to the
  eMMC, the installer has to put the `sdcard1` line back for that install.
* `prng_seeder` (no `/dev/hw_random`: the 6.12 rockchip-rng driver knows only rk3568);
  `flags_health_check` floods the console with permissive denials whenever an
  "updatable" process crash-loops; SELinux enforcing; the
  eMMC installer; our own U-Boot in TST mode.
