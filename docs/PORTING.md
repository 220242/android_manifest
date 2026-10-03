# Running the port end to end

Read [`STATUS.md`](STATUS.md) first: it names where the build actually is and what
is still open.

On a Windows host this is all driven by one script — see
[`WINDOWS.md`](WINDOWS.md). What follows is what that script runs, and what to do on
a Linux host.

## 0. Static check, before syncing anything

```sh
build/verify-tree.sh
```

Needs no AOSP tree, which is the point: it is the one check available before a
120GiB sync. It validates XML well-formedness, every file reference in `device.mk`
and `BoardConfig.mk`, the flash layout against `BOARD_*_PARTITION_SIZE`, that no image
can reach a partition in Android's sparse format, the boot image's ramdisk offset
against the kernel it has to clear, VINTF entries against `PRODUCT_PACKAGES`, the
kernel config fragment, shell syntax, sepolicy self-consistency, and the properties the
build derives for itself. Every check in it exists because something it now catches
once reached a build.

## 1. Host requirements

```sh
build/preflight.sh /path/to/where/the/tree/will/live
```

Needs at least 16GiB RAM (64 recommended), 8+ cores, an `aarch64-linux-gnu-` cross
toolchain, and git read access to `android.googlesource.com` and `github.com/gregkh`.
It exits 1 and names each unmet requirement rather than letting the build fail hours
in.

Disk is three requirements, because what is still needed depends on what is already
there:

| State of the target directory | Free space needed |
|---|---|
| nothing synced | 250GiB (350 comfortable) |
| tree synced, nothing built | 140GiB (200) |
| tree synced and `out/` built | 40GiB (80) |

The middle and last rows exist because the first is unmeetable once the work is done:
a 120GiB checkout and 150GiB of output are not free space any more. A run was stopped
by `FAIL disk 183GiB free, need >= 250GiB` on a host that had only to rebuild a few
images, for which 183GiB was ample.

The packages themselves are in [`build/windows/apt-packages.txt`](../build/windows/apt-packages.txt),
one per line — the AOSP list plus what the kernel, U-Boot and the SD image need. On a
Linux host:

```sh
sed 's/#.*//' build/windows/apt-packages.txt | xargs sudo apt-get install -y
```

It is a file rather than a list inside the provisioning script so that the Windows
orchestrator can hash it and re-run its Provision stage when it changes. Adding a
package to a script that a completed stage no longer runs is how `swig` came to be
"added" and never installed; `STATUS.md` has that one.

## 2. Sync

```sh
build/sync.sh '' android-14.0.0_r75
```

This does `repo init` against **upstream AOSP**, applies
`manifests/khadas_edge_tv14.xml` as a `.repo/local_manifests/` overlay, and copies
`device/khadas/edge` into the tree with `build/place-device.sh`.

A copy, not a symlink, and that is not a style choice — Soong's finder does not
descend into symlinked directories, so with a symlink the product config, every
`Android.bp` and the sepolicy directories are all invisible and `lunch` fails with
`Cannot locate config makefile for product "edge1_tv"`. The copy is refreshed before
every stage that reads it, so a `git pull` followed by a build compiles the files
that were just pulled. `STATUS.md` has the detail.

Why an overlay rather than a forked manifest: the Android 10 manifest forked all 737
AOSP projects into `github.com/khadas`. Carrying that forward means re-forking the
platform and hand-applying every AOSP security patch. Tracking upstream and
overlaying only what is not in it turns a security update into a tag bump. The
overlay is now small — mainline Linux from `gregkh/linux`, the Khadas `rkbin` blobs,
and `<remove-project>` for the Pixel kernel prebuilts that would otherwise be
fetched for nothing.

## 3. Kernel

```sh
build/build-kernel.sh
```

`arm64 defconfig` plus `device/khadas/edge/kernel/edge1_mainline.config`, merged with
`scripts/kconfig/merge_config.sh`, then `Image` and one dtb. It **exits non-zero if
any symbol in the fragment did not take** — the fragment is a contract, and a symbol
that silently reverted to `m` is a driver that does not exist in this layout.
`EDGE1_ALLOW_CONFIG_MISS=1` overrides that for a one-off experiment;
`KERNEL_USE_CLANG=1` builds with AOSP's clang instead of the distro cross GCC.
[`KERNEL.md`](KERNEL.md) has the rest.

The kernel has to be built before `m`: both the `Image` and the staged dtb are read
at Kati parse time. U-Boot does not, but building it early is free and a card with
no bootloader is not worth producing.

## 4. Platform

```sh
build/build.sh '' userdebug
```

Which is `source build/envsetup.sh; lunch edge1_tv-trunk_staging-userdebug; m -jN`,
plus the flash pack, which has to be assembled after `m` from the same environment.

Three details in that line were each wrong once:

* **The combo is three-part.** Android 14's `lunch` splits on `-` and requires
  `<product>-<release>-<variant>` (`build/envsetup.sh:809-820`), so a two-part combo
  never starts a build. `trunk_staging` is the release AOSP's own products use;
  `build.sh` takes it as an optional third argument.
* **`N` comes from RAM, not core count.** Soong's Java steps take about 2GiB each,
  and `-j$(nproc)` on a RAM-poor host is the most common cause of a build dying
  hours in with a bare `Killed`.
* **ccache writes into `out/`.** Android 14 runs ninja with everything outside
  `$OUT_DIR` bind-mounted read-only, so the default `$HOME/.cache/ccache` fails on
  the first compiled file.

## 5. Bootloader

```sh
build/build-uboot.sh
```

Mainline U-Boot `v2026.07`, `khadas-edge-v-rk3399_defconfig`, plus a fragment that adds
Android boot image support, a shell with `&&`, an HDMI console and a compiled-in
environment. It checks its host requirements first — `swig`, setuptools, pyelftools and
`Python.h`, which go into the SWIG extension binman needs — and names the package for
each. rk3399 needs only `BL31` from `rkbin`; U-Boot's own TPL does DDR init. Output is
`u-boot-rockchip.bin`: TPL, SPL and `u-boot.itb` in one blob, written at sector 64.

**Where this U-Boot runs is decided by the BootROM, not by us.** The RK3399 tries SPI
NOR, then the eMMC, then the card. On a board with anything bootable on the eMMC — this
one has Armbian — the card's U-Boot does not run, and the card is booted by the eMMC's
U-Boot through `bootfs` instead (step 6). Ours runs from an empty eMMC, in TST mode, or
from SPI NOR. [`BOOT.md`](BOOT.md) is the whole story; this section is how to build it.

The `bootcmd` tries the card, the eMMC and the NVMe in that order — U-Boot's documented
Android sequence from `doc/android/boot-image.rst`: read `boot` raw, `abootimg get dtb`,
copy it to `$fdt_addr_r`, `bootm` — and sets `androidboot.boot_devices` for each medium,
which first-stage init needs to find its partitions. Then it falls back to
`bootflow scan -lb`. The attempts are joined with `;`, never `||`: U-Boot's hush skips
`||` branches when the `&&` side fails, which made the old fallback dead code.

`mmc0` is the eMMC and `mmc1` the SD slot — `arch/arm/dts/rk3399-u-boot.dtsi` aliases
them so, and `arch/arm/mach-rockchip/rk3399/rk3399.c:27-31` gives the same mapping from
the BootROM's side. `CONFIG_NVME_PCI`, `CONFIG_PCI` and `CONFIG_CMD_NVME` come with the
Edge-V defconfig.

### What the script refuses, and what it only reports

It fails rather than building a U-Boot whose Android support silently did not take —
every line of the fragment, including the `# ... is not set` ones, is checked against the
resulting `.config`, and the `bootcmd` is checked for all three attempts, all three
`boot_devices` and the distro fallback. It also checks that `u-boot.itb` lands on the
sector SPL reads it from (64 + `SPL_PAD_TO`/512 = 16384). Symbols it only *expects* —
`CONFIG_ROCKCHIP_IODOMAIN` and its `DM_REGULATOR` dependency — are printed, not enforced.

### Trying another U-Boot

```sh
EDGE1_UBOOT_REV=v2025.10 build/build-uboot.sh
EDGE1_IMAGE_TAG=u2510 build/build-images.sh sdcard
```

Builds from another tag in the same checkout (fetched from the checkout's own remote,
which `repo` names `u-boot`, not `origin`) and puts the manifest's revision back when it
finishes, so the next ordinary build does not quietly build the experiment. `v2025.10`
because it is what the owner's OpenWrt build for this board uses.

Or a bootloader someone else built, by name:

```sh
EDGE1_UBOOT_REFERENCE=openwrt-u-boot-2025.10 EDGE1_IMAGE_TAG=owboot build/build-images.sh sdcard
```

writes `build/reference/openwrt-u-boot-2025.10/`'s `idbloader.img` and `u-boot.itb` at
sectors 64 and 16384 instead of ours. Either card only means anything in TST mode —
without it, the BootROM runs the eMMC's bootloader whatever the card holds.

From PowerShell, run these as
`wsl -d Edge1Build -e bash -lc 'cd ~/android_khadas/android_manifest && …'` — with
`-e`, and with no `$` and no `""` in the command: PowerShell 5.1 hands `$VAR` to a shell
that expands it before the intended one sees it, and does not pass an empty `""` through
at all. Both forms above need neither.

## 6. The whole-disk images

```sh
build/build-images.sh                # all three
build/build-images.sh sdcard         # just the card
```

| Image | Size | Bootloader | Written by |
|---|---|---|---|
| `edge1-sdcard.img` | fixed partitions + `EDGE1_USERDATA_MIB` (16GiB): needs a 32GB card | sector 64 | Balena Etcher, from the desktop |
| `edge1-emmc.img` | the same; `EDGE1_EMMC_SIZE_MIB` overrides | sector 64 | the on-device installer, or `ums 0 mmc 0` + Etcher |
| `edge1-nvme.img` | the same; `EDGE1_NVME_SIZE_MIB` overrides | **none** | the on-device installer, or `ums 0 nvme 0` + Etcher |

userdata gets its full size in the partition table, but the image file ends 64MiB
into it (zeros, which wipe the previous build's f2fs superblocks): Android formats
it on first boot, so writing 16GiB of zeros would only cost Etcher a quarter of an
hour. `EDGE1_FULL_IMAGE=1` keeps the whole thing.

One layout — `flash/partitions.tsv` — and three media. Each image is a GPT built from that
file with every partition image `dd`'d into place, plus a `.img.gz` beside it that Etcher
reads directly.

**Partition 1 of every image is `bootfs`**, a 512MiB FAT (boot files, and room for `edge1-logs`) built by `build/build-bootfs.sh`
from `boot.img` (it runs again on every `build-images.sh`, so it always matches). It holds
`boot.scr` and copies of the kernel, ramdisk and dtb out of `boot.img`, which the script
`load`s and `booti`s. A distro U-Boot — Armbian's, on this board's eMMC — scans the card
first and runs it; that is how the card boots on a board whose eMMC is not empty. The
script may use only what Armbian's U-Boot 2022.07 has (no `setexpr`, among others):
`build/check-uboot-script.py` enforces the list. It writes `edge1-boot.log` next to
itself on every attempt, and on the card the partition is typed so Windows mounts it.

**The NVMe image has no bootloader and cannot have one**: the BootROM's boot sources
(`arch/arm/include/asm/arch-rockchip/bootrom.h:47-59`) do not include PCIe.

### Booting the card

Write `edge1-sdcard.img.gz` with Etcher, insert it, power on. With Armbian (or any
mainline or Armbian U-Boot) on the eMMC, that U-Boot runs the card's `boot.scr` and
Android starts; the eMMC is only read. Pull the card and the board is as it was.

To run **our** U-Boot from the card instead — the way to test it before it goes anywhere
permanent — use TST mode: with the board on and the card in, press FUNCTION three times
within two seconds. `U-Boot 2026.07` on HDMI means it runs. [`BOOT.md`](BOOT.md) has the
details and what to look for on screen.

### Installing onto the eMMC or the SSD

```sh
adb root
adb shell sh /vendor/bin/edge1-install-internal.sh emmc
adb shell sh /vendor/bin/edge1-install-internal.sh nvme
```

It copies the running card partition by partition and partitions the target to its real
size, so `userdata` gets the whole SSD. It will not write the disk it runs from or a disk
with anything mounted, finds the eMMC by controller address rather than `mmcblk` number,
and asks for `yes` first. It copies neither `userdata` nor `metadata`.

**The bootloader**: it copies the card's U-Boot to the eMMC only if that U-Boot started
the running system (read from `/proc/device-tree/chosen/u-boot,version`). Otherwise it
leaves the eMMC's bootloader in place — on this board, Armbian's, which booted the card and
will boot the installed Android the same way through the eMMC's `bootfs`.
`--with-bootloader` / `--keep-bootloader` override. For `nvme` there is no bootloader to
write.

### What the builder refuses

No bootloader when one is needed, an image too big for its partition, a layout that does
not fit, a `userdata` too small to format, a bootloader running past 16MiB, a `boot.img`
that is not header v2, a command line the boot script cannot quote — and any image in
Android's sparse format, which is expanded with `simg2img` before it is written because
a sparse image `dd`'d into a partition mounts nothing.

### The generated eMMC script, which is not the default

`build.sh` also stages `out/target/product/edge/edge1-flash/` with the images and a
generated `flash-emmc.sh`, to partition and write the eMMC from a Linux already booted on
the board. It predates the installer, erases the eMMC, has never been run and guesses the
device name. Prefer `edge1-install-internal.sh`.

## Layout

```
manifests/khadas_edge_tv14.xml   repo local-manifest overlay (AOSP 14, kernel, U-Boot)
device/khadas/edge/              the device tree
  edge1_tv.mk                    TV product, inherits device/google/atv
  BoardConfig.mk                 arch, dynamic partitions, AVB, boot image, kernel
  device.mk                      HAL packages, TV features, overlays, properties
  vintf/manifest.xml             the one HAL declared directly, target-level 8
  fstab.edge1                    logical partitions, FBE v2
  init/, sepolicy/vendor/        board bring-up and SELinux
  audio/, media/, input/, permissions/, overlay/
  wifi/firmware/brcm/            AP6398S firmware: Wi-Fi + NVRAM, Bluetooth patchram
  kernel/edge1_mainline.config   arm64 defconfig -> Android 14 delta, 6.12
  flash/partitions.tsv           one layout: images, flash script, installer
  flash/boot.cmd                 the bootfs boot script, filled from boot.img
  bin/edge1-install-internal.sh  installs the running card onto eMMC or NVMe
build/
  verify-tree.sh                 static checks, no tree needed
  preflight.sh                   host requirements
  sync.sh, place-device.sh       tree setup
  build-kernel.sh                mainline 6.12 + the Android config delta
  build-uboot.sh                 mainline U-Boot + Android boot image support
  build.sh                       the platform build and the eMMC flash pack
  build-bootfs.sh                bootfs.img: partition 1, boot.scr for the eMMC's U-Boot
  build-images.sh                the three whole-disk images
  lib-tree.sh                    finds the AOSP tree when no path is given
  verify-aidl-surface.sh         dumps the real method list of declared HALs
  rk-idb-check.py                verifies a Rockchip ID block (RC4, so not by eye)
  reference/                     a U-Boot built elsewhere for this board, for A/B
  windows/                       the WSL2 orchestrator and the in-distro driver
    apt-packages.txt             host packages, hashed so a change re-provisions
docs/                            BOOT, STATUS, HARDWARE, KERNEL, HAL_MIGRATION, WINDOWS, this file
```

`default.xml` is the original Android 10 manifest, left untouched for reference.
