# Building on a Windows host

## The short version

AOSP cannot be compiled on Windows, and Android Studio has no part in it.
`build/windows/Start-EdgeBuild.ps1` therefore does not build anything itself: it
prepares a WSL2 Ubuntu environment on your 2TB drive and runs the Linux build
scripts inside it.

```powershell
# Administrator PowerShell
cd D:\android_khadas
git clone -b claude/determined-johnson-fwwaig https://github.com/220242/android_manifest
.\android_manifest\build\windows\Start-EdgeBuild.ps1
```

It is resumable. Every stage records completion in
`D:\android_khadas\.build-state.json`, so if it stops — or you reboot, which WSL
often needs on first install — just run it again.

## Why not natively on Windows

* There is no Windows host toolchain in `prebuilts/`. Soong, Kati and the blueprint
  tooling ship for `linux-x86` and `darwin-x86` only.
* The build generates ext4 and EROFS images, applies POSIX modes, and creates
  symlinks in the output tree. None of that works through Win32 file APIs.
* `sepolicy` compilation, `mkbootimg` and `avbtool` are Linux binaries.

Android Studio builds *apps*. A platform build is a different thing entirely.

## Why the tree cannot live on D:\ directly

This is the part that catches people out, and the script is built around it.

**NTFS is case-insensitive.** AOSP contains files whose names differ only by
case. Checked out onto NTFS they collapse into a single file, and the build then
fails in ways that look like corrupted source rather than a filesystem problem.
Per-directory case sensitivity (`fsutil file setCaseSensitiveInfo`) exists but
must be set before any file is created, is not inherited reliably by every tool,
and does not survive some archive extraction paths. It is not safe for a 120 GiB
checkout.

**`/mnt/d` is slow.** WSL2 reaches Windows drives through a 9p/drvfs bridge. For
the millions of small stat and open calls a `repo sync` and a `ninja` run
perform, it is 10-50x slower than ext4. A build that takes 5 hours on ext4 takes
over a day through `/mnt/d`.

**So the SSD is used a different way.** The script imports the Ubuntu distro with
its virtual disk placed at `D:\android_khadas\wsl\ext4.vhdx`. That file is on the
2TB SSD, and its *contents* are a real ext4 filesystem — case-sensitive and at
native speed. The tree lives at `~/android_khadas/aosp-14-edge1` inside it.

Reach it from Explorer at `\\wsl.localhost\Edge1Build\home\builder\android_khadas`.

## What each stage does

| Stage | Action |
|---|---|
| `Check` | Windows build >= 19041, hypervisor, RAM, >= 320 GiB free on the target drive |
| `Wsl` | Installs the WSL2 platform with `--no-distribution` (keeps Store Ubuntu off C:) |
| `Distro` | Resolves and downloads the Ubuntu 22.04 WSL rootfs (checksum-verified), imports it onto the target drive, creates the `builder` user |
| `Tune` | Writes `%USERPROFILE%\.wslconfig` sized to your RAM, plus a 32 GB swap file on the target drive |
| `Provision` | Installs the packages in `build/windows/apt-packages.txt`, clones the device tree, runs `preflight.sh` and `verify-tree.sh` |
| `Sync` | Resolves the newest `android-14.0.0_r*` tag and syncs (100+ GiB) |
| `Aidl` | Dumps the real AIDL method surface of every HAL this board speaks to `aidl-surface.txt` |
| `Probe` | Checks the device tree against the synced tree and **stops the run** on anything it can answer in a minute that the build would take hours to reach |
| `Kernel` | Builds mainline 6.12 LTS with the Android 14 config delta, and stages the board dtb |
| `Uboot` | Builds mainline U-Boot with Android boot image support, for the card, the eMMC and SPI NOR (the BootROM runs it only when nothing on the eMMC is bootable - see `BOOT.md`) |
| `Build` | `lunch edge1_tv-trunk_staging-userdebug`, `m`, then the eMMC flash pack |
| `Images` | Builds `bootfs.img` (partition 1, the boot script the eMMC's U-Boot runs) from `boot.img`, assembles the three whole-disk images (SD card, eMMC, NVMe) and copies them to `android_khadas\output` |

Run one on its own with `-Stage Build`. Re-run a completed stage with `-Force`.

Seven inputs are hashed into the state file, and a stage whose input moved is
un-completed by itself:

| Input | Un-completes | Because |
|---|---|---|
| `manifests/khadas_edge_tv14.xml` | `Sync`, `Kernel`, `Uboot` | a tree synced against a different manifest is not synced; a sync also resets the U-Boot checkout the Uboot stage edits |
| `build/windows/apt-packages.txt` | `Provision` | a distro provisioned against a shorter package list is missing packages |
| `device/khadas/edge/**` | `Build` | images built from an older device tree are stale |
| `build/build-kernel.sh` | `Kernel` | a stage's own script is an input to it |
| `device/khadas/edge/kernel/edge1_mainline.config` | `Kernel`, `Build` | the device tree hash re-runs only `Build`, which packs whatever `Image` the `Kernel` stage left - so a fragment change used to ship the old kernel |
| `build/build-uboot.sh` | `Uboot` | the same |
| `build/build.sh` | `Build` | the same |

The device tree's hash is the sorted hash of every file under it, so any edit counts.
Re-running `Build` with `out/` intact and ccache warm is an incremental rebuild, not a
fresh one - and the alternative is what happened with `super.img`: a `BoardConfig.mk`
change that makes the build produce a raw image does nothing at all while `Build` is
still marked complete.

The package list one exists because `swig` was added to the dependency list and never
installed: `Provision` was already marked complete, so apt never ran again, and the
`Uboot` stage failed on the missing package after an eight-hour platform build. The
package list is a file rather than a list inside `provision-wsl.sh` so that it can be
hashed on its own - hashing the whole script would re-run `Provision` on every
unrelated edit.

`Aidl` and `Probe` ignore the state file and always run: they are verification
passes whose output is the point, and gating them meant a changed check silently
never ran again. Their output is folded into the report, so there is only ever one
file to send.

`Probe` is the one stage that can fail on purpose. Five consecutive build failures
were the same mistake — declaring something the platform already declares — and each
was reported by a different tool between six and twenty minutes into a build, one
name per run. `Probe` answers all of them against the synced tree in about a minute
and exits non-zero, naming every collision at once. `STATUS.md` has the list.

## When something fails: one file to send

Every run is transcribed to `D:\android_khadas\logs\session-<timestamp>.log`,
and **on any failure the script writes a consolidated report automatically** and
prints its path:

```
D:\android_khadas\edge1-report-<timestamp>.txt
```

That single file contains the Windows environment (OS build, CPU, RAM, volumes,
WSL version, `.wslconfig`), the failure with its script stack trace, the Linux
environment from inside the distro (toolchain versions, disk, tree state), error
lines with context pulled out of every build log, and the tail of the
transcript. Send that one file.

Build logs run to gigabytes of ninja output, so the report greps them for error
patterns and takes the tail rather than including them whole — it stays
pasteable. The full logs remain at
`\\wsl.localhost\Edge1Build\home\builder\android_khadas\logs\`.

Generate one on demand without running anything:

```powershell
.\Start-EdgeBuild.ps1 -Stage Report
```

## Notes

The rootfs filename is resolved from Canonical's directory index at run time
rather than hardcoded — the published artefact has been renamed before
(`...-amd64-wsl.rootfs.tar.gz` became `...-amd64-ubuntu22.04lts.rootfs.tar.gz`),
and a hardcoded URL fails with a bare 404. The download is verified against the
published `SHA256SUMS`, and a pre-existing file is only reused if it passes.

Ubuntu 22.04 (jammy), not 24.04: AOSP 14's host prebuilts are built against the
older glibc, and 22.04 is what Google's own build images use.

`-DistroName` points the script at a different WSL distribution. Only useful for
reusing one you already have — a distro created any other way almost certainly
has its virtual disk on `C:`, which defeats the point of putting the tree on the
large drive.

## Memory

`Tune` gives WSL `(total RAM - ReserveGB)` and a swap file of `2x RAM`, floored
at 32 GB and capped at 128 GB. Override either:

```powershell
.\Start-EdgeBuild.ps1 -Stage Tune -SwapGB 96 -ReserveGB 8 -Force
```

WSL2's default is half your RAM, which on a 16 GiB machine leaves 8 GiB and gets
R8 OOM-killed several hours into a build — hence setting it explicitly.

**Swap is insurance, not capacity.** `build/build.sh` derives `-j` from physical
RAM and deliberately ignores swap. A large swap file stops one R8 or linker spike
from killing a six-hour build. It does not let you run a wider build: if ninja's
working set spills to swap, throughput drops by an order of magnitude even on a
fast NVMe, because the access pattern becomes random 4 KiB page faults. Raising
`-j` to "use" the swap makes the build slower, not faster.

On a 30 GiB host the defaults give WSL 24 GiB, 60 GiB of swap, and `-j12` from
`build.sh` — comfortably above Android 14's 16 GiB minimum.

`.wslconfig` changes need `wsl --shutdown` to take effect; the script does that.

## Two things that will bite you

**Reboot after the first WSL install.** `wsl --install` enables Windows features
that need a restart. The script warns and the state file means re-running it
resumes from where it stopped.

**Do not let the machine sleep during `Sync` or `Build`.** WSL2 does not survive
S3 gracefully mid-build:

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
```

## What you get at the end

`android_khadas\output\edge1-sdcard.img.gz` — one file, written to an SD card with
Balena Etcher, which reads `.gz` directly. The raw `.img` is beside it in the tree if you
want that instead; the compressed copy exists because 7GiB over `\\wsl.localhost` is slow.

**Insert it and power on; the eMMC is not written.** The RK3399 BootROM tries the eMMC
before the card, so with Armbian (or anything bootable) on the eMMC it is the eMMC's
U-Boot that runs — and it scans the card first and runs the `boot.scr` on the card's
partition 1, which boots our Android. Pull the card and the board is as it was.
[`BOOT.md`](BOOT.md) has the mechanism, what each stage looks like on HDMI, and TST
mode for running the card's own U-Boot.

`out/target/product/edge/edge1-flash/` also exists — the same images plus a generated
`flash-emmc.sh` that partitions and writes the **eMMC** from a Linux already running on
the board. It erases the eMMC, it has never been run, and the on-device installer
supersedes it. `PORTING.md` step 6 has both.

Every HAL in the image is an AOSP one talking to a mainline driver rather than a
half-ported Rockchip HIDL one:

* display: drm_hwcomposer over `drivers/gpu/drm/rockchip`, buffers from minigbm;
* GLES: Mesa's panfrost over `drivers/gpu/drm/panfrost`;
* audio: AOSP's AIDL audio HAL over ALSA, HDMI codec through `simple-audio-card`;
* Wi-Fi: brcmfmac with the firmware from this board's own OpenWrt build.

What is not there yet: hardware video decode is unwired, so software codecs carry
playback at 1080p rather than 4K; Bluetooth is unresolved because the kernel driver
and Android's HAL both want the same UART; and nothing about this can be certified —
software KeyMint, no attestation, clearkey DRM only. `STATUS.md` is the full picture.

The honest test of the first image is whether it boots to a leanback launcher on HDMI
with a working remote and network. Everything after that is configuration.

## Running one command by hand

Some steps — trying another bootloader, rebuilding one image — are run directly in the
distro rather than as a stage. From PowerShell:

```powershell
wsl -d Edge1Build -e bash -lc 'cd ~/android_khadas/android_manifest && build/build-images.sh sdcard'
```

Three things make that reliable, and each was a failed command first:

* **`-e`** runs `bash` directly. Without it wsl hands the line to a shell of its own,
  which expands `$VAR` before the `bash -lc` it was meant for ever runs — a `$R` set
  earlier in the same line arrives empty.
* **No `""`.** PowerShell 5.1 does not pass an empty quoted argument to a native program.
  `build-images.sh` takes the target as its first argument for this reason, and the
  tree is found without being named.
* **No `~/aosp-14-edge1`.** The tree is `~/android_khadas/aosp-14-edge1`; the scripts
  find it themselves (`build/lib-tree.sh`) when no path is given.

## Caveat on the script itself

It runs as Administrator and it repartitions nothing on Windows, but it does import
a WSL distribution, write `%USERPROFILE%\.wslconfig` and create a large swap file on
the target drive. Every destructive step prompts for confirmation unless `-Force` is
passed.

The earlier version of this note said the script had never been executed, because it
was written on a Linux host with no PowerShell available. That is no longer true — it
has driven every build in `STATUS.md`. What is still worth knowing is that it is
`Set-StrictMode -Version Latest`, so a property that does not exist is an error
rather than `$null`, and one of the bugs that cost a round was exactly that: a
missing hash in the state file surfaced as a device-tree warning instead of the
state-file problem it was.
