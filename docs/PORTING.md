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
and `BoardConfig.mk`, the flash layout against `BOARD_*_PARTITION_SIZE`, VINTF
entries against `PRODUCT_PACKAGES`, the kernel config fragment, shell syntax,
sepolicy self-consistency, and the properties the build derives for itself. Every
check in it exists because something it now catches once reached a build.

## 1. Host requirements

```sh
build/preflight.sh /path/to/where/the/tree/will/live
```

Needs ~250GiB free (350 recommended), at least 16GiB RAM (64 recommended), 8+
cores, an `aarch64-linux-gnu-` cross toolchain, and git read access to
`android.googlesource.com` and `github.com/gregkh`. It exits 1 and names each unmet
requirement rather than letting the build fail hours in.

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
at Kati parse time.

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

## 5. Flash

Not `update.img`. That is Rockchip's format and it needs the BSP bootloader plus
RKTools, neither of which this path uses. Mainline U-Boot boots an ordinary GPT, so
`build.sh` stages the images together with a generated `flash-emmc.sh`:

```sh
# on the build host
ls out/target/product/edge/edge1-flash/

# copy that directory to the board, then from the Linux it already boots:
./flash-emmc.sh /dev/mmcblk2
```

It writes a GPT from `device/khadas/edge/flash/partitions.tsv` and `dd`s each image
into its partition. Deliberately the lowest-risk way in: no maskrom mode, no vendor
flashing tool, and the U-Boot already on the board is left alone — it lives in raw
sectors ahead of the first partition, and nothing here writes below 16MiB. Check the
device name first; on this board the eMMC is usually `mmcblk2` and an SD card
`mmcblk1`.

This has never been run. It erases the eMMC.

## Layout

```
manifests/khadas_edge_tv14.xml   repo local-manifest overlay (AOSP 14 + mainline kernel)
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
  build-kernel.sh, build.sh      the two builds
  verify-aidl-surface.sh         dumps the real method list of declared HALs
  windows/                       the WSL2 orchestrator and the in-distro driver
docs/                            STATUS, KERNEL, HAL_MIGRATION, WINDOWS, this file
```

`default.xml` is the original Android 10 manifest, left untouched for reference.
