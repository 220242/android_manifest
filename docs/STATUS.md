# Status

Where the port is, what is still open, and the decisions worth not re-deriving.

## Where the build is

**`m` completes.** `#### build completed successfully ####`, 153 of 153 targets on the
incremental run that got there, after 167136 on the first. Every image the flash layout
names now builds, `super.img` included.

Two things then stood between a successful build and a card that boots, and both were
invisible from the build's own output: `super.img` was not produced at all until asked
for, and once produced it was in Android's sparse format, which cannot be written into
a partition. Both are below.

**No image has been written to the board yet**, so nothing here is claimed to boot.
That is the next step and the one that matters.

| Stage | State |
|---|---|
| `repo sync` (AOSP `android-14.0.0_r75` + mainline 6.12.111) | works |
| Kernel: `Image`, `rk3399-khadas-edge-v.dtb` | builds, every fragment symbol verified to take |
| `lunch edge1_tv-trunk_staging-userdebug`, product config | works |
| Soong (100% of `Android.bp`), Kati (all `.mk`) | works |
| Compile — 167136 targets on the first run | works |
| sepolicy: vendor policy, `precompiled_sepolicy`, `treble_sepolicy_tests` 29.0–34.0 | passes |
| VINTF: `vendor_manifest.xml`, `check_vintf_all` | passes at `target-level="7"`, no VNDK requirement, kernel-version check disabled |
| `vendor/build.prop`, `system/build.prop` | generated |
| `boot.img`, `recovery.img`, `dtb.img`, `vbmeta.img` | build |
| `system.img`, `vendor.img`, `product.img`, `system_ext.img`, `odm.img` | build |
| `super.img` | builds, and raw rather than sparse, so it can be written |
| U-Boot (mainline v2026.07 + Android boot image support) | configured and verified; the build needs host packages the pipeline was not installing |
| SD card image (`edge1-sdcard.img`, for Etcher) | new, never written |
| Flash pack (`edge1-flash/` + `flash-emmc.sh`, for eMMC) | assembled, never run |

### super.img, twice

**It is opt-in.** The first build to get all the way through reported success and then
`build.sh` said:

```
expected .../out/target/product/edge/super.img was not produced
```

Both statements were true. `core/Makefile:7307-7315` hangs `super.img` off
`droidcore-unbundled` **only** when `BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT` is true;
otherwise it is built by an explicit `m superimage` or for a dist build. What `droid`
builds unconditionally is `super_empty.img` — the partition metadata with no contents
— because the normal path is fastboot writing that and then flashing each logical
partition individually.

This device is not on that path: both writers here `dd` `super.img` into the super
partition, which is exactly the case the flag exists for. `verify-tree.sh` check 3b
now requires the two to agree — if `partitions.tsv` names `super.img`, BoardConfig
has to build one.

**And then it was sparse, which is worse.** With the flag set the next build produced
one, and the log showed how:

```
lpmake --metadata-size 65536 --super-name super ... --sparse
       --output out/target/product/edge/super.img
```

An Android sparse image is a container, not a filesystem: a 28-byte header with magic
`0xed26ff3a`, then chunks that each say which output blocks they hold.
`tools/releasetools/build_super_image.py:136-137` adds `--sparse` unless
`build_non_sparse_super_partition` is set, and it was not.

Written into a partition verbatim, it is 4.6GiB of the wrong bytes. There is no ext4
superblock where the kernel looks for one and no super metadata where `libdm` looks,
so first-stage init fails to mount `/system` and says nothing about why. Every check
that could have caught it passed: the build succeeded, the file existed, and it was
well under its partition size — it is a fraction of the size of what it expands to,
which is the same fact from the other side.

`core/Makefile:6145-6148` is the only place that sets
`build_non_sparse_super_partition`, and it takes it from
`TARGET_USERIMAGES_SPARSE_EXT_DISABLED` or its f2fs twin. So the fix is one line in
`BoardConfig.mk`, and it is the line AOSP's own GSI targets carry
(`target/board/BoardConfigGsiCommon.mk:19`). It turns the logical partitions' images
raw on the way in too, which costs apparent size in `out/` and nothing else — they are
`lpmake`'s inputs and end up inside super either way.

Three things now hold it:

* `build-sdimage.sh` reads the first four bytes of every image it writes and expands a
  sparse one with `simg2img` rather than copying it through. `build.sh` names
  `simg2img` as a build target for this, because it is otherwise built only as part of
  `otatools` (`core/Makefile:5561`).
* The generated `flash-emmc.sh` carries the same check.
* `verify-tree.sh` check 3d requires the BoardConfig setting *and* the guard in both
  writers, so losing either is a static error.

The size check moved too. It used to measure the file in `out/`; it now measures what
will actually be written, which is the expanded image. A 12KB sparse file that expands
to 2GiB passed the old check and is rejected by the new one.

## The approach

Two routes to Android 14 on this board were on the table. This is the second, taken
after the first had been built far enough to price it.

**Abandoned: Khadas' 4.19 BSP kernel plus the Rockchip Android 10 userspace.** The
kernel built. Everything above it would have had to be forward-ported — the Mali
blob's gralloc integration above all, the largest single unknown in the port — and
none of that work is reusable anywhere else.

**Current: mainline 6.12 LTS plus AOSP's own userspace for it.**

| | driver | userspace, already in AOSP 14 |
|---|---|---|
| GPU | `drivers/gpu/drm/panfrost` | `external/mesa3d` → `libGLES_mesa` |
| Display | `drivers/gpu/drm/rockchip` | `external/drm_hwcomposer` + minigbm |
| Decode | `staging/media/rkvdec` (H.264 only) | `external/v4l2_codec2` |
| Wi-Fi | `brcmfmac` over SDIO | AOSP `wpa_supplicant` |
| Audio | `simple-audio-card` → HDMI | AOSP AIDL audio HAL over ALSA |
| Boot | mainline U-Boot + TF-A | ordinary GPT, images written from Linux |

No proprietary blob is involved. What made this credible rather than hopeful is
that the board is already proven on this kernel: it runs OpenWrt with Linux 6.12.94
and mainline U-Boot (`github.com/220242/khadas_edge-openwrt`), which is also where
the Wi-Fi firmware and board NVRAM in `device/khadas/edge/wifi/firmware/brcm` come
from.

The fact that forced the decision either way: **AOSP 14 ships no software GLES
driver a real device can load.** `libGLES_android` was removed years ago and
swiftshader is packaged for the emulator's host side — the tree defines no
`libEGL_swiftshader`. Without a driver SurfaceFlinger does not start, so "boot
first, GPU later" was never available. panfrost supplies one without a blob; the
Mali blob would have had to be bridged to an IMapper it was never written for.

What the graphics stack costs, stated plainly: minigbm's rockchip backend does not
implement the RK3399's AFBC layouts, so composition moves more bytes than
Rockchip's own gralloc did.

## What is still open

1. **Nothing has been booted.** Everything below is secondary to that. The install
   path is now an SD card written with Balena Etcher rather than the eMMC script: the
   RK3399 BootROM reads the card before the eMMC, so the card boots on its own with
   the eMMC untouched, and removing it puts the board back. That makes the first
   attempt reversible, which the eMMC path is not.
2. **U-Boot and the SD image builder are new and unexercised.** Both are written
   against the real sources — the boot sequence is U-Boot's own from
   `doc/android/boot-image.rst`, the Khadas Edge-V defconfig is upstream, and
   `build-sdimage.sh` is tested end to end against fabricated images, with every
   partition's contents verified at its sector and the sparse path exercised with a
   real sparse image and a reference decoder. But no U-Boot has been compiled all the
   way through yet — the first attempt stopped on missing host packages — and no card
   has been written.
3. **Hardware video decode is not wired up.** `CONFIG_VIDEO_ROCKCHIP_VDEC` is in the
   kernel and `external/v4l2_codec2` is in the tree, with
   `android.hardware.media.c2@1.2-service-v4l2` available — but it is not in
   `PRODUCT_PACKAGES`, and it needs a codec2 store config and a `media_codecs_c2.xml`
   beside it. Until then the software codecs carry playback: 1080p yes, 4K no.
   6.12's rkvdec is H.264 only in any case (`rkvdec-h264.c` and nothing else), so
   HEVC and VP9 stay in software regardless.
4. **Bluetooth is unresolved.** uart0 carries the BCM4359 and the DTS has a
   `brcm,bcm43438-bt` node. The kernel's `hci_bcm` would claim the port and do the
   firmware patch itself; Android's Bluetooth HAL expects to open the tty and patch
   from userspace with a vendor tool this tree no longer carries. The kernel
   transport is left out of the config so `/dev/ttyS0` stays free until that is
   decided. See `KERNEL.md`.
5. **The device targets FCM level 7, not 8.** That was forced rather than chosen —
   see below — and it is worth knowing when reading anything that says this is an
   Android 14 device: the vendor image's HAL surface is Android-13-era.
6. **Codec performance numbers are placeholders.** `media/media_codecs_performance.xml`
   holds datasheet ceilings, not measurements from this board.
7. **ART's userfaultfd GC is off, and no longer for the original reason.** It was
   off because the 4.19 BSP kernel lacked the feature; 6.12 has all of it, and by
   AOSP's own rule this board qualifies. It stays off for the first boot on purpose
   — a different garbage collector is an untested variable in the one attempt that
   matters, and it would fail inside ART during zygote startup. Flip
   `PRODUCT_ENABLE_UFFD_GC` to `true` once the device boots; it is a memory win on a
   4GB board, not a requirement.
8. **`kmsro` in `BOARD_GPU_DRIVERS` is confirmed valid but unproven useful.** It is
   in the driver-name list `external/mesa3d/Android.mk` accepts
   (`kmsro.HAVE_GALLIUM_KMSRO`); whether panfrost on this board needs it is a
   question for the first boot.

## Honest expectation

If it boots, it boots to a leanback launcher over HDMI with Ethernet and Wi-Fi.
It will not pass CTS, and that is structural rather than a matter of finishing:
software KeyMint rules out hardware key attestation (see `HAL_MIGRATION.md`),
`PRODUCT_SHIPPING_API_LEVEL` is 29 — correct for an upgrade device, not for
certification as a 14 device — and DRM is clearkey only, so licensed HD streaming
will not work. If certified streaming was the goal, mainline Linux with Kodi on the
same board is the right vehicle and this is not.

## Decisions taken against the real build system

Each of these was wrong in the tree before it was read out of `android-14.0.0_r75`
rather than recalled. They are listed because the reasoning is what does not
survive in a diff.

| Setting | Why |
|---|---|
| `lunch edge1_tv-trunk_staging-userdebug` | 14's `lunch` requires three parts and rejects two outright (`build/envsetup.sh:809-820`). The two-part form never starts a build. |
| `set +eu` around `envsetup.sh` | `envsetup.sh:21` reads `$TOP` before anything sets it; under `set -u` that ended the run before `m`. |
| `PRODUCT_USE_DYNAMIC_PARTITIONS` in the product makefile | Product config runs first and freezes the product variables, so assigning it in `BoardConfig.mk` is `cannot assign to readonly variable`. |
| No `BOARD_SEPOLICY_VERS`, no `<sepolicy>` in the VINTF manifest | `core/config.mk` derives it from `PLATFORM_SEPOLICY_VERSION` (202404) and freezes it, and `assemble_vintf` refuses to override a value the input manifest already carries. Setting it by hand was silently overwritten in one place and fatal in the other. |
| `PRODUCT_COPY_FILES` for the kernel `Image`, not `TARGET_PREBUILT_KERNEL` | The string `PREBUILT_KERNEL` appears nowhere in AOSP 14's `build/make`. `core/Makefile:1018` defines `INSTALLED_KERNEL_TARGET` as `$(PRODUCT_OUT)/kernel` and leaves producing it to the device. |
| `BOARD_BOOT_HEADER_VERSION := 2`, no `vendor_boot` | With a vendor_boot the kernel command line and the dtb move out of `boot.img` into `vendor_boot` (`core/Makefile:1600-1614`), where a bootloader that reads only `boot.img` never looks. See below. |
| `BOARD_USES_FULL_RECOVERY_IMAGE := true`, no `BOARD_INCLUDE_RECOVERY_DTBO` | Boot header v2 and up have no `recovery_dtbo` field worth using here; the flag handed mkbootimg an argument it cannot place. |
| Four AVB recovery variables | `core/Makefile:4460` errors with `BOARD_AVB_RECOVERY_KEY_PATH must be defined` on a non-A/B device with AVB: a discrete recovery image has to be self-signed. |
| `BOARD_GPU_DRIVERS := panfrost kmsro`, not `BOARD_MESA3D_GALLIUM_DRIVERS` | The only mention of `BOARD_MESA3D_*` in the tree is dragonboard's own makefiles, which drive meson themselves. `external/mesa3d/Android.mk` reads `BOARD_GPU_DRIVERS`: `MESA_BUILD_GALLIUM := $(strip $(foreach d, $(BOARD_GPU_DRIVERS), ...))`. |
| `PRODUCT_SOONG_NAMESPACES += external/mesa3d` | Mesa refuses to build without it — `external/mesa3d must be in PRODUCT_SOONG_NAMESPACES`, its `Android.mk:41`. |
| `libGLES_mesa` and `libglapi`, not the six packages dragonboard lists | Nothing in the tree defines `libEGL_mesa`, `libGLESv1_CM_mesa`, `libGLESv2_mesa` or `libgallium_dri`; those names come from the newer meson-based packaging. The EGL loader takes `libGLES_<name>.so` as a complete driver and only falls back to the triplet when it is absent. |
| Four `PRODUCT_*` variables deleted | `PRODUCT_BUILD_PROP_OVERRIDES`, `PRODUCT_HAS_CAMERA`, `PRODUCT_HAVE_OPTEE`, `PRODUCT_TARGET_VNDK_VERSION` appear nowhere in AOSP 14. They were read by `device/rockchip/common`, which this tree does not have, so they were decoration that read like configuration. |
| No `ro.product.first_api_level`, `ro.product.board`, `ro.board.platform` or `ro.sf.lcd_density` set by hand | `core/main.mk:284,332-341` emits all four from product and board variables. Setting one as well produces two assignments in the same `build.prop`, which `post_process_props.py` rejects unless the values happen to be identical. |
| `TARGET_USERIMAGES_SPARSE_EXT_DISABLED := true` | The only switch that makes `lpmake` drop `--sparse` (`core/Makefile:6145-6148` → `build_super_image.py:136`). A sparse `super.img` is a container, not a filesystem, and `dd`ing one leaves a partition with no superblock and no log. |
| `m droid simg2img` rather than `m` | `simg2img` is built only as part of `otatools` (`core/Makefile:5561`), and `build-sdimage.sh` needs it if an image is ever sparse again. An unknown target fails at the end of the ninja parse, in seconds. |
| `CCACHE_DIR=$TREE/out/ccache` | 14 runs ninja with everything outside `$OUT_DIR` bind-mounted read-only, so ccache's default `$HOME/.cache/ccache` is on the wrong side and the first real compile died at target 151 of 167136. The build's own error text names the fix: generate into `out/`. |

Also checked and found clean: none of the 69 `KATI_obsolete_var` names are used
anywhere in the device tree, and the dynamic-partition group naming matches what
`core/config.mk` derives.

## One failure shape, seven times

Seven build failures were variations of one mistake: the tree claims something the
platform does not agree with, and the tool that objects reports one instance per run.
Each now has a gate in the module probe (`build/windows/provision-wsl.sh`, `stage_probe`),
which runs before the build and takes about a minute.

The two rows that say *nothing* are a different and worse shape: there is no error to
gate on, so the only defence is a static check that knows what the build will not say.

| What | The build says | When |
|---|---|---|
| Module in `PRODUCT_PACKAGES` does not exist | nothing — it is dropped silently, unless `PRODUCT_ENFORCE_PACKAGES_EXIST` is set (`core/main.mk:1341`) | never |
| `super.img` in Android sparse format | nothing — the build's job is to produce the image, not to know how it is written | never |
| sepolicy type declared here and in `system/sepolicy` | `checkpolicy`: `Duplicate declaration of type` | ~6 min |
| `file_contexts` specification declared twice | `checkfc`: `Multiple same specifications for ...` | ~9 min |
| Property the build derives from a variable | `post_process_props.py`: `found duplicate sysprop assignments` | ~9 min |
| Property `exact` match labelled twice | `host_init_verifier`: `Duplicate exact match detected` | ~20 min |
| HAL declared at an FCM level that does not list it | `check_vintf`: `INCOMPATIBLE` | ~15 min |
| Device matrix requiring a VNDK version | `check_vintf`: `Vndk version 34 is not supported` | ~10 min |

Two of those are worth spelling out because the rule is not the obvious one:

* **`checkfc` rejects the identical regex, not an overlapping path.** Two different
  regexes matching one path is normal and the most specific wins, which is why
  `/dev/dri/card0` sits happily beside AOSP's `/dev/dri/card[0-9]*`. Only
  `/dev/video[0-9]*` copied verbatim was fatal.
* **An allowed prefix is not the same as a free name.** `check_prop_prefix` rejected
  a `sys.hwc.` label because a vendor partition may only own `vendor.`, `odm.`,
  `ro.vendor.`, `ro.odm.`, `ro.hardware.`, `ro.boot.`, `persist.vendor.`,
  `persist.odm.`, `persist.camera.`, the `ctl.` and `init.svc.` forms of the first
  two. The five `ro.hardware.*` labels that replaced it were inside those prefixes
  and still failed, because the platform labels those five properties already — the
  code that reads them is platform code.

`verify-tree.sh` covers the offline half of each of these with a hand-kept list of
what the platform declares. The probe resolves the same questions against the
synced tree, which is the authoritative answer, and gates on it.

## FCM level 7, because the composer is HIDL

`check_vintf_all` runs when `PRODUCT_ENFORCE_VINTF_MANIFEST` is true, which it is in
this build, and it called the device INCOMPATIBLE:

```
The following instances are in the device manifest but not specified in
framework compatibility matrix:
    android.hardware.cas@1.2::IMediaCasService/default
    android.hardware.graphics.composer@2.4::IComposer/default
```

Both HALs are real and both are provided. What changed at level 8 is that the
framework stopped listing their HIDL versions — read out of the matrices in the
synced tree:

| | level 7 | level 8 |
|---|---|---|
| `android.hardware.cas` | hidl 1.1-2 | aidl only |
| `android.hardware.graphics.composer` | hidl 2.1-4 | — |
| `android.hardware.graphics.composer3` | aidl 1 | aidl 2 |

Neither instance is something to remove. The composer is HIDL because AOSP 14's
drm_hwcomposer snapshot is HWC2 only, and the HIDL cas service is installed by AOSP
itself: `base_vendor.mk:90` puts `android.hardware.cas@1.2-service` in
`PRODUCT_PACKAGES_SHIPPING_API_LEVEL_33`, and this device ships at API 29. AOSP's own
configuration assumes a device like this one sits below level 8.

So `target-level` is 7. That is permitted because this is an upgrade device rather
than a launch device — an upgrade device keeps the FCM level it launched with and may
raise it, and API 29 is level 4, so 7 is already a raise. The floor in practice is 5,
the oldest matrix AOSP 14 still installs. The honest reading is that the vendor image
is Android-13-era in its HAL surface, and level 7 says so.

The probe now answers this before the build: it reads `target-level` and each
declared HAL out of `vintf/manifest.xml`, checks them against the matrix at that
level, and fails the run naming the ones that are not accepted. It covers the device
manifest's own entries only — instances that arrive with an installed service's VINTF
fragment, like the cas one, are not visible without a built image — so it narrows
`check_vintf` rather than replacing it.

## VNDK, deprecated in silence

With the FCM levels agreed, `check_vintf` moved on to the next line of the same
file:

```
All HALs in device manifest are declared in FCM <= level 7
ERROR: files are incompatible: Framework manifest and device compatibility
matrix are incompatible: Vndk version 34 is not supported. Supported versions
in framework manifest are: []
```

An empty list, not a mismatched number. VNDK is deprecated in this release, and AOSP
wires that up in two steps neither of which says anything:

* `core/envsetup.mk:53-58` — `KEEP_VNDK` defaults to **false** when the release
  config sets `RELEASE_DEPRECATE_VNDK`, and true otherwise.
* `core/config.mk:1266-1273` — when `KEEP_VNDK` is not true, `BOARD_VNDK_VERSION`
  and `PLATFORM_VNDK_VERSION` are assigned empty. No warning, no error.

So `BOARD_VNDK_VERSION := current` in `BoardConfig.mk` was discarded before anything
read it, the framework manifest listed no versions at all, and the device
compatibility matrix was requiring something that no longer exists. Both are gone.
Nothing replaces them: if a future release keeps VNDK, `envsetup.mk:64` sets
`BOARD_VNDK_VERSION := current` itself when the board has not — the same value that
line used to state.

The device matrix now requires nothing, which is correct rather than lazy: nothing on
the vendor side of this board calls into a framework HAL, because every HAL here is
an AOSP one talking to a mainline driver.

Writing the gate for this reproduced the kernel-fragment trap exactly. A
`grep -c '<vendor-ndk>'` over the matrix counted the explanation in that file's own
comment and reported a requirement on a clean tree. The gate parses the XML instead,
since ElementTree does not see comments — and the test that caught it was the one
that checked the *passing* case, not the failing one.

## The one check that is disabled rather than satisfied

Everything else in this tree was made to pass. This one cannot be:

```
Runtime info and framework compatibility matrix are incompatible: No kernel
entry found for kernel version 6.12 at kernel FCM version 7. The following
kernel requirements are checked:
  Minimum LTS: 5.10.107 ... 5.15.41 ... 6.1.0 ... 6.6.0
```

Read what it lists. Those are minimums, and 6.12.111 is above every one of them. The
failure is not that the kernel is too old — it is that libvintf matches the LTS
*branch* exactly, the matrices in this release carry `<kernel>` rows for 5.10, 5.15,
6.1 and 6.6, and 6.12 LTS did not exist when Android 14 was cut. There is no row to
match and no mechanism for a device to add one.

So `PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false`, which is AOSP's own
remedy — option (4) in the warning it prints at `core/Makefile:5259`. The variable was
true only because `PRODUCT_SHIPPING_API_LEVEL` is 29, and 29 ≥ 29
(`core/product_config.mk:523-528`).

What is genuinely lost is worth naming rather than glossing: the same check also
verified the `CONFIG_*` symbols those rows require, and that half would have worked.
The probe does it instead — it collects every `<config>` requirement across all
`<kernel>` rows in every matrix and lists the ones this board's config does not name,
checking the merged `.config` when the kernel has been built and the fragment
otherwise. Reported rather than gated: many of those entries are conditional on a GKI
kernel or on another config, and deciding which apply to a non-GKI board is not a
judgement a script can make. The enforcement is gone; the information is not.

This is also the first failure in the run that was not the tree's fault. The previous
seven were all the same mistake — claiming something the platform does not agree with.
This one is a version table that ends before the kernel this board runs.

## The vendor_boot that had nothing to carry

`recovery.img` built, `system.img` started, and then:

```
panic: lstat out/target/product/edge/vendor_ramdisk: no such file or directory
    build/soong/cmd/fileslist/fileslist.go:130
```

`INTERNAL_VENDOR_RAMDISK_FILES` is whatever is installed under
`$(TARGET_VENDOR_RAMDISK_OUT)` (`core/Makefile:1559`). Nothing was, so the directory
was never created, and the rule that lists it walks it anyway. `mkbootfs` would have
failed next for the same reason.

Filling the directory would have been the wrong repair. Header v4 with a separate
`vendor_boot` is what Android 13+ expects of devices that ship a GKI kernel and load
vendor modules from the vendor ramdisk. This board is not one: the kernel is built
from source with every driver compiled in, `BOARD_USES_GENERIC_KERNEL_IMAGE` is
unset, there is no `vendor_dlkm`. The vendor ramdisk had nothing to hold.

What `vendor_boot` costs is not an empty directory. With `BUILDING_VENDOR_BOOT_IMAGE`
the kernel command line moves out of `boot.img` into `vendor_boot`'s `vendor_cmdline`
(`core/Makefile:1614`) and the dtb moves with it (`1600-1606`); without it both go
into `boot.img` (`1303-1311`). This board is booted by mainline U-Boot, not by a
vendor bootloader written against `vendor_boot`, so `console=ttyS2,1500000n8` and
`androidboot.hardware=edge1` were sitting in a field a bootloader that reads only
`boot.img` never looks at. A board that boots to nothing with no console is the
hardest failure to diagnose on a board whose only output is that console.

So: header v2, one `boot.img` with kernel + ramdisk + dtb, no `vendor_boot`
partition. v0/v1/v2 share the classic `andr_img_hdr` in U-Boot, its best-tested
path. If the board ever gets a GKI kernel and loadable modules, v4 is right again.

## Paths that were still the BSP's

Moving to a mainline kernel changed every sysfs and device path the board config
names, and a stale one does not fail a build — it fails silently on the device. Each
of these was checked against `rk3399-base.dtsi`, `rk3399-khadas-edge.dtsi` and
`rk3399-khadas-edge-v.dts` at v6.12.111. A platform device is named
`<address>.<node name>`, and the BSP renamed several of those nodes.

| Was | Is | What it broke |
|---|---|---|
| `fstab`: `/devices/platform/fe320000.dwmmc/mmc_host*` | `fe320000.mmc` | vold matches this against the block device's sysfs path. No SD card, ever. |
| `fstab`: `/devices/platform/usb*` | `/devices/platform/*.usb*` | Every USB controller is a `usb@<address>` node, so nothing sits at `platform/usb*`. No USB storage. |
| `fstab`: `fileencryption=...:v1` | `:v2` | v1 was pinned because 4.19 lacked the fscrypt v2 backports. 6.12 has had them since 5.4. |
| `fstab`: `/dev/block/by-name/baseparameter` | removed | A Rockchip partition read by their hwcomposer. `flash/partitions.tsv` does not create it. |
| `genfs_contexts`: `fe380000.dwmmc/mmc_host` | `fe320000.mmc/mmc_host` | `fe380000` is `usb@fe380000`, an EHCI controller. The label was on nothing. |
| `genfs_contexts`: `/devices/platform/dmc` | removed | `dmc: memory-controller` is `status = "disabled"` and no Khadas dts enables it. |
| `genfs_contexts`: `/class/backlight` | removed | No backlight device on an HDMI board. |
| `init.edge1.rc`: `write /sys/class/devfreq/dmc/governor dmc_ondemand` | removed | Device does not exist, and `dmc_ondemand` is a BSP governor upstream does not have. Two init errors per boot. |
| `init.edge1.rc`: a bare `oneshot`, `start brcm_patchram` | removed | Left over from a deleted service stanza; init read `oneshot` as a command inside `on boot`. |
| `init.edge1.usb.rc`: `/sys/class/android_usb/android0/...` | `sys.usb.controller=fe800000.usb` | `android_usb` is the pre-configfs gadget. The dts gives `usbdrd_dwc3_0` (`usb@fe800000`) `dr_mode = "otg"`, so that is the UDC. |
| fragment: `CONFIG_DWMAC_ROCKCHIP=y` alone | `+ CONFIG_STMMAC_PLATFORM=y` | `DWMAC_ROCKCHIP` is inside `if STMMAC_PLATFORM`, a tristate. While the parent was `m` the child could not be `y`, so `olddefconfig` demoted it — no Ethernet, on a board whose dts enables `&gmac`. |

## Four traps in the tooling itself

**The device tree cannot be a symlink.** It was one — one place to edit, under
version control — and that is why the first platform build could not start:

```
build/make/core/product_config.mk:226: error: Cannot locate config makefile
    for product "edge1_tv".
```

AOSP does not glob for `AndroidProducts.mk` at make time. It reads
`out/.module_paths/AndroidProducts.mk.list`, which Soong's finder writes by walking
the source tree, and that walk does not descend into symlinked directories. The same
applies to everything else Soong globs: no `Android.bp` under the device tree had
ever been parsed and `BOARD_VENDOR_SEPOLICY_DIRS` pointed into a directory Soong
could not see. `build/place-device.sh` now copies the tree in as a real directory
before every stage that reads it, and clears the finder cache when the content
changed. The manifest repo stays the single source of truth; the copy is a build
artefact.

**A comment in the kernel fragment can be a directive.** `merge_config.sh` picks the
symbols to merge with two `sed` patterns and then reads each value back with
`grep -w $CFG`, so a comment mentioning a symbol the fragment also sets makes that
`grep` return two lines and the override report print the comment as the value. The
merge itself is unaffected, but the one output that says whether a symbol took
becomes unreadable — and `# CONFIG_X is deliberately absent` is four words from
matching the second pattern, `# CONFIG_X is not set`, and turning the symbol off.
Comments name symbols without the `CONFIG_` prefix now, and `verify-tree.sh` check 7
enforces both halves.

**A completed stage is only as good as its inputs.** `swig` was added to the WSL
dependency list, pushed, and never installed. The next run printed
`skipping Provision (already complete; -Force to redo)`, built the platform for eight
hours, and then failed the U-Boot stage on

```
error: command 'swig' failed: No such file or directory
make[2]: *** [scripts/dtc/pylibfdt/Makefile:33: rebuild] Error 1
```

The state file records which stages finished. It said Provision had, which was true of
the Provision that ran — against a shorter package list. An input that changes has to
un-complete the stage that consumes it, and the orchestrator already did exactly that
for one input: the manifest overlay is hashed, and `Sync` and `Kernel` are un-completed
when it moves. The dependency list was not hashed because it was not a file; it was a
list inside `provision-wsl.sh`, and hashing that whole script would re-run Provision on
every unrelated edit.

So the list became `build/windows/apt-packages.txt`, and the invalidation became a
table of (file, state key, stages):

| Input | Un-completes |
|---|---|
| `manifests/khadas_edge_tv14.xml` | `Sync`, `Kernel` |
| `build/windows/apt-packages.txt` | `Provision` |
| `device/khadas/edge/**` | `Build` |

The third row is the same lesson applied to the expensive stage, and it is the one that
would have saved the `super.img` cycle: a `BoardConfig.mk` change that makes the build
emit a raw image does nothing while `Build` is still marked complete. Any edit under the
device tree now un-completes it, and re-running `Build` with `out/` intact is an
incremental rebuild.

Adding a package now re-runs Provision by itself, and apt on an already-provisioned
distro takes seconds. `build-uboot.sh` also checks its four host requirements up front
— `swig`, setuptools, pyelftools and `Python.h` — and names the package for each,
because the error the build gives names neither the package nor what wanted it. U-Boot
builds a SWIG Python extension (`scripts/dtc/pylibfdt`) before it can run binman, and
binman is what packs `u-boot-rockchip.bin`.

**A diagnostic must never abort on the thing it is diagnosing.** The report is one
file, and the build log section is the part that explains a failure. It stopped
mid-sentence on a run whose whole purpose was to explain a failure, on this line:

```sh
first_failed=$(grep -nE '^FAILED:' "$f" | head -1 | cut -d: -f1)
```

A log with no `FAILED:` line - a kernel that built fine, or a stage that died in a
shell script rather than in ninja - makes `grep` exit 1, `pipefail` makes the pipeline
exit 1, and under `errexit` an assignment from a failing command substitution ends the
function. The report ended after printing the first log's first heading, so the logs of
the stage that actually failed never reached it.

This was the fourth occurrence of that shape, and the first three were each fixed on
whichever line happened to trip, with a `|| true`. The module probe had already drawn
the right conclusion and enforced the property once for its whole body; the report now
does the same - `set +e +o pipefail` inside a subshell, so the rest of the script keeps
both. A diagnostic printing something odd is always better than a diagnostic stopping.

Adjacent, and the same kind of mistake in a different tool: `preflight.sh` asked for
250GiB of free disk on every run. That is right before a sync and impossible after one,
because the 120GiB checkout and 150GiB of output it is sizing for are exactly what is
no longer free. It stopped a run that had only to rebuild a few images. The requirement
is now tiered by what is already on the filesystem - 250GiB bare, 140GiB synced, 40GiB
with a built `out/` - and `PORTING.md` has the table.

## How this tree got here

Worth one paragraph, because it explains the workflow. The port was written in an
environment that could not build it: `android.googlesource.com` is refused by that
container's network policy and the disk is roughly a tenth of what a build needs. So
the device tree, the HAL migration, the kernel delta, the SELinux policy and the
build pipeline were written and statically verified there, and `build/verify-tree.sh`
exists because it was the only check available — it validates XML, every file
reference in `device.mk` and `BoardConfig.mk`, VINTF consistency, shell syntax and
the mandatory kernel symbols without an AOSP tree present. Its first run found 14
real errors. Compilation happens on the board owner's Windows host through
`build/windows/Start-EdgeBuild.ps1`, which is why the diagnostics in this repo are
shaped around producing one pasteable report per run rather than a live terminal.
`github.com/aosp-mirror` was checked as a way out and is a partial reference mirror,
not a buildable tree — every `prebuilts/*` repo is absent, so nothing can compile —
but reading `platform_build` and `platform_manifest` from it is where most of the
decision table above comes from.
