# Running the port end to end

Read `STATUS.md` first: this tree is not finished, and it names exactly what is
missing.

## 0. Host requirements

```sh
build/preflight.sh /path/to/where/the/tree/will/live
```

Needs ~250GiB free (350 recommended), >=16GiB RAM (64 recommended), 8+ cores, and
git read access to both `android.googlesource.com` and `github.com/khadas`.
It exits 1 and names each unmet requirement rather than letting the build fail
hours in.

## 1. Static check, before syncing anything

```sh
build/verify-tree.sh
```

Runs without an AOSP tree — that is the point, it is the one check available
before a 120GiB sync. Validates XML, every file reference in `device.mk` and
`BoardConfig.mk`, VINTF consistency, shell syntax and mandatory kernel symbols.

## 2. Sync

```sh
build/sync.sh ~/aosp-14-edge1 android-14.0.0_r50
```

Verify the tag first; the default could not be confirmed when this was written:

```sh
git ls-remote --tags https://android.googlesource.com/platform/manifest 'android-14.0.0_r*'
```

This does `repo init` against **upstream AOSP**, then applies
`manifests/khadas_edge_tv14.xml` as a `.repo/local_manifests/` overlay and copies
`device/khadas/edge` into the tree with `build/place-device.sh`.

A copy, not a symlink, and that is not a style choice: Soong's finder writes
`out/.module_paths/AndroidProducts.mk.list` by walking the source tree and does
not descend into symlinked directories, so with a symlink the product config,
every `Android.bp` and the sepolicy directories were all invisible and `lunch`
failed with `Cannot locate config makefile for product "edge1_tv"`. The copy is
refreshed before every stage that reads it, so a `git pull` followed by a build
compiles the files that were just pulled.

Why an overlay rather than a forked manifest: the Android 10 manifest forked all
737 AOSP projects into `github.com/khadas`. Carrying that forward means
re-forking the platform and hand-applying every AOSP security patch. Tracking
upstream and forking only the ~15 projects that actually contain board support
turns a security update into a tag bump.

## 3. Kernel

```sh
build/build-kernel.sh ~/aosp-14-edge1
```

Read the "config symbols did not take" list it prints. See `KERNEL.md`.

## 4. Platform

```sh
build/build.sh ~/aosp-14-edge1 userdebug
```

Which is `source build/envsetup.sh; lunch edge1_tv-trunk_staging-userdebug;
m -jN`, plus the flash pack that has to be assembled after `m`, from the same
environment.

`N` is derived from RAM, not core count: soong's Java steps take ~2GiB each, and
`-j$(nproc)` on a RAM-poor host is the most common cause of a build dying hours
in with a bare `Killed`.

The combo is three-part, `<product>-<release>-<variant>`. This was wrong here
until it was checked against the release: Android 14's `lunch` splits the string
on `-` and requires all three parts,

    Invalid lunch combo: edge1_tv-userdebug
    Valid combos must be of the form <product>-<release>-<variant>

(`build/envsetup.sh:809-820` in `android-14.0.0_r75`), so a two-part combo never
starts a build. `trunk_staging` is the release AOSP's own products use, declared
in `build/release/release_config_map.mk`; `core/release_config.mk` also falls
back to it. `build.sh` takes it as an optional third argument.

### There is no longer a flag for unfinished HALs

`EDGE1_ENABLE_INCOMPLETE_HALS` and every package it gated are gone. They selected
the Rockchip Android 10 HALs, which this port no longer forward-ports; on a
mainline kernel they could not work even if they built, since the Mali blob talks
to the BSP's midgard kmod and this kernel has panfrost. Every HAL in the build is
now an AOSP one, and `docs/HAL_MIGRATION.md` says what each costs.

## 5. Flash

Not `update.img`. That is Rockchip's format, and it needs the BSP bootloader plus
RKTools — neither of which this path uses. Mainline U-Boot boots an ordinary GPT,
so `build/build.sh` stages the images together with a generated `flash-emmc.sh`:

```sh
# on the build host
ls out/target/product/edge/edge1-flash/

# copy that directory to the board, then from the Linux it already boots:
./flash-emmc.sh /dev/mmcblk2
```

It writes a GPT from `device/khadas/edge/flash/partitions.tsv` and `dd`s each
image into its partition. Deliberately the lowest-risk way in: no maskrom mode, no
vendor flashing tool, and the U-Boot already on the board is left untouched — the
bootloader lives in raw sectors ahead of the first partition and nothing here
touches them. Check the device name first; on this board the eMMC is usually
`mmcblk2` and an SD card `mmcblk1`.

## Layout

```
manifests/khadas_edge_tv14.xml   repo local-manifest overlay (AOSP 14 + Khadas)
device/khadas/edge/              the device tree
  edge1_tv.mk                    TV product, inherits device/google/atv
  BoardConfig.mk                 arch, dynamic partitions, AVB, kernel
  device.mk                      HAL packages, TV features, overlays
  vintf/manifest.xml             the 2 HALs declared directly, target-level 8
  fstab.edge1                    logical partitions, FBE v1
  init/, sepolicy/vendor/        board bring-up and SELinux
  audio/, media/, wifi/, bluetooth/, input/
  wifi/firmware/brcm/            brcmfmac firmware + board NVRAM (AP6398S)
  kernel/edge1_mainline.config   arm64 defconfig -> Android 14 delta, 6.12
  flash/partitions.tsv           the GPT build.sh turns into a flash script
build/                           preflight, sync, kernel, build, verifiers
docs/                            STATUS, HAL_MIGRATION, KERNEL, this file
```

`default.xml` is the original Android 10 manifest, left untouched for reference.
