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

Needs ~250GiB free (350 recommended), at least 16GiB RAM (64 recommended), 8+
cores, an `aarch64-linux-gnu-` cross toolchain, and git read access to
`android.googlesource.com` and `github.com/gregkh`. It exits 1 and names each unmet
requirement rather than letting the build fail hours in.

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

Mainline U-Boot, `khadas-edge-v-rk3399_defconfig`, plus a four-symbol fragment that
teaches it to read an Android boot image. It checks its four host requirements first —
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
`bootm <img> <img> $fdt_addr_r`. The script fails rather than building a U-Boot whose
Android support silently did not take — `CONFIG_CMD_ABOOTIMG` depends on
`CONFIG_ANDROID_BOOT_IMAGE`, and losing it would present on the board as
`Unknown command 'abootimg'` with no log.

## 6. The SD card image

```sh
build/build-sdimage.sh ~/aosp-14-edge1
```

One whole-disk image, `edge1-sdcard.img` and a `.img.gz` beside it, both of which
Balena Etcher writes directly. It contains the bootloader at sector 64, a GPT built
from `flash/partitions.tsv`, and each partition image `dd`'d into place. Sizes:
`EDGE1_SD_SIZE_MIB` defaults to 7000, which fits any card sold as 8GB and leaves
about 2.1GiB of `userdata`.

**This is the safe install path, and the reason is the boot order.** The RK3399
BootROM looks at the SD card before the eMMC, so a card with a valid bootloader in
its raw sectors takes over the boot. The eMMC is never written to — whatever is
installed there stays — and pulling the card out puts the board back exactly as it
was. Nothing needs to be running on the board first, either: Etcher writes the card
from a desktop.

The script refuses rather than producing something misleading: no bootloader, an
image too big for its partition, a layout that does not fit the requested size, or a
`userdata` too small for Android to format. It also checks that the bootloader fits
between sector 64 and the first partition at 16MiB.

It reads the first four bytes of every image, too. An Android sparse image is a
container rather than a filesystem, so writing one into a partition produces a card
that looks correct and cannot mount anything; the board config makes the build emit raw
images, and this is where that is verified rather than assumed. A sparse image is
expanded with `simg2img` before it is written, and the size check measures what will be
written rather than the file on disk — a 12KB sparse file can expand past its
partition.

### The other way in, which is not the default

`build.sh` also stages `out/target/product/edge/edge1-flash/` with the same images
and a generated `flash-emmc.sh`. That one partitions and writes the **eMMC**, runs on
the board itself, and needs a Linux already booted there:

```sh
./flash-emmc.sh /dev/mmcblk2
```

It erases the eMMC, it has never been run, and it is not how this is installed. It
exists for the point where the card boots reliably and the install should become
permanent.

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
  flash/partitions.tsv           the GPT build.sh turns into a flash script
build/
  verify-tree.sh                 static checks, no tree needed
  preflight.sh                   host requirements
  sync.sh, place-device.sh       tree setup
  build-kernel.sh                mainline 6.12 + the Android config delta
  build-uboot.sh                 mainline U-Boot + Android boot image support
  build.sh                       the platform build and the eMMC flash pack
  build-sdimage.sh               one whole-disk image for Etcher
  verify-aidl-surface.sh         dumps the real method list of declared HALs
  windows/                       the WSL2 orchestrator and the in-distro driver
    apt-packages.txt             host packages, hashed so a change re-provisions
docs/                            STATUS, KERNEL, HAL_MIGRATION, WINDOWS, this file
```

`default.xml` is the original Android 10 manifest, left untouched for reference.
