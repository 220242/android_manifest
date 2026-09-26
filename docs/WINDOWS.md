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
* `sepolicy` compilation, `mkbootimg`, `avbtool` and the Rockchip `afptool`
  packaging are all Linux binaries.

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
| `Distro` | Downloads the Ubuntu 22.04 WSL rootfs, imports it onto the target drive, creates the `builder` user |
| `Tune` | Writes `%USERPROFILE%\.wslconfig` sized to your RAM, plus a 32 GB swap file on the target drive |
| `Provision` | Installs AOSP dependencies, clones the device tree, runs `preflight.sh` and `verify-tree.sh` |
| `Sync` | Resolves the newest `android-14.0.0_r*` tag and syncs (100+ GiB) |
| `Aidl` | Dumps the real AIDL method surface of all 22 declared HALs to `aidl-surface.txt` |
| `Kernel` | Builds 4.19.111 with the Android 14 config delta |
| `Build` | `lunch edge1_tv-userdebug`, `m`, then Rockchip `update.img` packaging |

Run one on its own with `-Stage Build`. Re-run a completed stage with `-Force`.

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

A build, not a working ROM. `docs/STATUS.md` has the full picture, but the short
form: the composer3 (display) and audio.core (sound) AIDL HALs are unfinished, so
`EDGE1_ENABLE_INCOMPLETE_HALS` defaults to off and the image is built against
AOSP fallbacks. Flashing it verifies that the tree builds and the device boots
far enough to be debugged over adb — it will not put a picture on the TV.

Finish those two HALs first if a usable image is the goal.

## Caveat on the script itself

`Start-EdgeBuild.ps1` was written on a Linux host with no PowerShell available,
so it has never been executed or parse-checked. Brace/paren balance and a few
specific hazards were checked statically, and four bugs found that way were
fixed, but that is not the same as running it. Read it before running it as
Administrator. Every destructive step prompts for confirmation unless `-Force` is
passed.
