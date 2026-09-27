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
`manifests/khadas_edge_tv14.xml` as a `.repo/local_manifests/` overlay and
symlinks `device/khadas/edge` into the tree.

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
m -jN`, plus the Rockchip `update.img` packaging that has to follow `m` in the
same environment.

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

### Building with the unfinished HALs

`device.mk` gates the incomplete Rockchip HALs behind a flag, defaulting off so
the tree builds to completion using AOSP's generic implementations:

```sh
EDGE1_ENABLE_INCOMPLETE_HALS=true m
```

Turn it on as each shim is finished. `shims/README.md` has the per-HAL state.

## 5. Flash

```sh
upgrade_tool uf out/target/product/edge/rockdev/update.img
```

Board in maskrom mode: hold the FUNCTION button, plug USB-C, release.
`update.img` is Rockchip's full-image format, not an OTA — this is a non-A/B
device and there are no slots.

## Layout

```
manifests/khadas_edge_tv14.xml   repo local-manifest overlay (AOSP 14 + Khadas)
device/khadas/edge/              the device tree
  edge1_tv.mk                    TV product, inherits device/google/atv
  BoardConfig.mk                 arch, dynamic partitions, AVB, kernel
  device.mk                      HAL packages, TV features, overlays
  vintf/manifest.xml             22 AIDL HAL declarations, target-level 8
  fstab.edge1                    logical partitions, FBE v1
  init/, sepolicy/vendor/        board bring-up and SELinux
  audio/, media/, wifi/, bluetooth/, input/
  kernel/edge1_android14.config  4.19 -> Android 14 config delta
  shims/                         HIDL -> AIDL shim layers
  parameter.txt, package-file    Rockchip update.img inputs
build/                           preflight, sync, kernel, build, verifiers
docs/                            STATUS, HAL_MIGRATION, KERNEL, this file
```

`default.xml` is the original Android 10 manifest, left untouched for reference.
