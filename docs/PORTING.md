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
build/sync.sh ~/aosp-14-edge1 android-14.0.0_r75
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
build/build-kernel.sh ~/aosp-14-edge1
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
build/build.sh ~/aosp-14-edge1 userdebug
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
build/build-uboot.sh ~/aosp-14-edge1
```

Mainline U-Boot, `khadas-edge-v-rk3399_defconfig`, plus a five-symbol fragment that
teaches it to read an Android boot image and gives it a shell with conditionals. It
checks its four host requirements first —
`swig`, setuptools, pyelftools and `Python.h`, all of which go into building the SWIG
extension binman needs — and names the package for each, because the failure otherwise
arrives 400 lines in as `command 'swig' failed: No such file or directory` and names
neither. rk3399 needs only `BL31` out of `rkbin` —
U-Boot's own TPL does DDR init on this SoC — and the script finds it rather than
hardcoding a version. Output is `u-boot-rockchip.bin`, one blob containing TPL, SPL
and `u-boot.itb`.

The boot sequence in `CONFIG_BOOTCOMMAND` is U-Boot's own documented one from
`doc/android/boot-image.rst` for a header v2 image with the DTB inside it: read the
`boot` partition raw, `abootimg get dtb --index=0`, copy it to `$fdt_addr_r`, then
`bootm <img> <img> $fdt_addr_r`.

**It is instantiated three times, and tried in order: SD card (`mmc 1`), eMMC
(`mmc 0`), NVMe (`nvme 0`).** `part start` fails when there is no such partition, and
that failure is what moves on to the next medium — which needs
`CONFIG_HUSH_PARSER` for `&&` and `||`, hence the fifth symbol. The card comes first
deliberately: whichever medium the BootROM loaded U-Boot from, a card with an Android
boot partition takes over, so an install on internal storage is always undone by
inserting the card. NVMe is last because it cannot be first — the BootROM has no PCIe.

`mmc0` is the eMMC and `mmc1` the SD slot, which is not a guess:
`arch/arm/dts/rk3399-u-boot.dtsi` aliases them that way and
`arch/arm/mach-rockchip/rk3399/rk3399.c:27-31` states the same mapping from the
BootROM's side — eMMC at `mmc@fe330000`, SD at `mmc@fe320000`. `CONFIG_NVME_PCI` and
`CONFIG_PCI` are already in the Edge-V defconfig and `CONFIG_CMD_NVME` is
`default y if NVME`, so the third target costs no configuration at all.

### A/B-ing two bootloaders

```sh
EDGE1_UBOOT_REV=v2025.07 build/build-uboot.sh ~/aosp-14-edge1
EDGE1_IMAGE_TAG=v2025.07 build/build-images.sh ~/aosp-14-edge1 sdcard
```

Two cards, two mainline tags, everything else identical, and the outputs sit side by
side as `edge1-sdcard.img` and `edge1-sdcard-v2025.07.img`. `repo` owns
`bootloader/u-boot`, so the next `Sync` resets the checkout — the override is for an
experiment; pin the tag in the manifest to make it a decision.

Not a Khadas branch, and `STATUS.md` has the measurements: every Edge/RK3399 branch in
`github.com/khadas/u-boot` is U-Boot 2017.09 with no board defconfig and BSP packaging,
and the one modern branch differs from upstream by two meaningful config lines, both of
which are already accounted for here. Their board DTS overlays are byte-identical to
upstream's.

### What the script refuses, and what it only reports

The script fails rather than building a U-Boot whose Android support silently did not
take — `CONFIG_CMD_ABOOTIMG` depends on `CONFIG_ANDROID_BOOT_IMAGE`, and losing it
would present on the board as `Unknown command 'abootimg'` with no log. It also checks
that all three attempts survived into `.config`: a truncated `bootcmd` would still
build, still boot the card, and silently never fall through to the eMMC or the SSD,
which is exactly the case that cannot be tested without the hardware. Symbols it only
*expects* — `CONFIG_ROCKCHIP_IODOMAIN` and its `DM_REGULATOR` dependency, which should
arrive from a Kconfig default — are printed rather than enforced. Failing a working
build over an expectation that was never asserted is how a green build gets blocked for
nothing.

## 6. The three whole-disk images

```sh
build/build-images.sh ~/aosp-14-edge1               # all three
build/build-images.sh ~/aosp-14-edge1 sdcard        # just the card
```

| Image | Size | Bootloader | Written by |
|---|---|---|---|
| `edge1-sdcard.img` | `EDGE1_SD_SIZE_MIB`, default 7000 | sector 64 | Balena Etcher, from the desktop |
| `edge1-emmc.img` | `EDGE1_EMMC_SIZE_MIB`, default 14400 | sector 64 | the on-device installer, or `ums 0 mmc 0` + Etcher |
| `edge1-nvme.img` | `EDGE1_NVME_SIZE_MIB`, default 14400 | **none** | the on-device installer, or `ums 0 nvme 0` + Etcher |

One layout — `flash/partitions.tsv` — and three media. Each image is a GPT built from
that file with every partition image `dd`'d into place, plus a `.img.gz` beside it that
Etcher reads directly.

**The NVMe image has no bootloader and cannot have one.** The RK3399 BootROM's boot
sources are the enum in U-Boot's `arch/arm/include/asm/arch-rockchip/bootrom.h:47-59` —
NAND, eMMC, SPI NOR, SPI NAND, SD, UFS, I2C, SPI, USB. PCIe is not among them, so
nothing on an M.2 card can ever be the first thing that runs. An NVMe install keeps
U-Boot on the eMMC or on the card and puts only Android's partitions on the SSD.

### The card is the install

Write `edge1-sdcard.img` with Etcher and boot it. Nothing has to be running on the
board, the eMMC is not written to, and pulling the card out puts the board back exactly
as it was — which is what makes the first attempt reversible in a way the eMMC path is
not.

It stays reversible afterwards, too: `build-uboot.sh` builds a `bootcmd` that tries the
**card, then the eMMC, then the NVMe**, so whichever medium the BootROM loaded U-Boot
from, a card with an Android boot partition wins. After installing to internal storage,
remove the card to run from it and put the card back to override it.

### Installing onto the eMMC or the SSD

Neither is removable, so only something already running on the board can write them.
That something ships inside the image:

```sh
adb root
adb shell sh /vendor/bin/edge1-install-internal.sh emmc
adb shell sh /vendor/bin/edge1-install-internal.sh nvme
```

It does not use the image files. It copies the running card partition by partition —
the card already holds every image byte for byte in its own partitions — and it
partitions the target to its **real** size, so `userdata` gets the whole 128GB SSD
rather than the 14GiB a fixed image was built for. That is the one thing
`edge1-emmc.img` and `edge1-nvme.img` cannot do, and it is why the installer is the
path to prefer.

It refuses rather than guessing: it will not write the disk it is running from, it
will not write a disk with anything mounted from it, it finds the eMMC from the
controller address in sysfs rather than trusting `mmcblk2` to be stable, and it asks
for the word `yes` before it writes. It copies neither `userdata` nor `metadata` —
Android formats both on first boot, and copying an encrypted `/data` to another device
would be pointless.

For `nvme` it writes no bootloader, for the reason above, and says so: install to the
eMMC as well if the board is to run from the SSD with no card in it.

The other way in needs a serial console but no Android: from the U-Boot prompt,
`ums 0 mmc 0` or `ums 0 nvme 0` exposes the target as a USB disk and Etcher writes the
matching image to it. `CONFIG_CMD_USB_MASS_STORAGE` is already in the Edge-V defconfig,
so that path costs nothing.

### What the builder refuses

No bootloader when one is needed, an image too big for its partition, a layout that
does not fit the requested size, a `userdata` too small for Android to format, or a
bootloader that would run past the first partition at 16MiB.

It reads the first four bytes of every image, too. An Android sparse image is a
container rather than a filesystem, so writing one into a partition produces a disk
that looks correct and cannot mount anything; the board config makes the build emit raw
images, and this is where that is verified rather than assumed. A sparse image is
expanded with `simg2img` before it is written, and the size check measures what will be
written rather than the file on disk — a 12KB sparse file can expand past its
partition.

### The generated eMMC script, which is not the default

`build.sh` also stages `out/target/product/edge/edge1-flash/` with the same images and
a generated `flash-emmc.sh`. That one partitions and writes the eMMC from a Linux
already booted on the board:

```sh
./flash-emmc.sh /dev/mmcblk2
```

It predates the installer, it erases the eMMC, it has never been run, and it guesses
the device name rather than reading sysfs. Prefer `edge1-install-internal.sh`.

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
  wifi/firmware/brcm/            brcmfmac firmware + board NVRAM (AP6398S)
  kernel/edge1_mainline.config   arm64 defconfig -> Android 14 delta, 6.12
  flash/partitions.tsv           one layout: images, flash script, installer
  bin/edge1-install-internal.sh  installs the running card onto eMMC or NVMe
build/
  verify-tree.sh                 static checks, no tree needed
  preflight.sh                   host requirements
  sync.sh, place-device.sh       tree setup
  build-kernel.sh                mainline 6.12 + the Android config delta
  build-uboot.sh                 mainline U-Boot + Android boot image support
  build.sh                       the platform build and the eMMC flash pack
  build-images.sh                the three whole-disk images
  verify-aidl-surface.sh         dumps the real method list of declared HALs
  windows/                       the WSL2 orchestrator and the in-distro driver
    apt-packages.txt             host packages, hashed so a change re-provisions
docs/                            STATUS, KERNEL, HAL_MIGRATION, WINDOWS, this file
```

`default.xml` is the original Android 10 manifest, left untouched for reference.
