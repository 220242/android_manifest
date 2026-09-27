# Status: what was built, what was not, and why

## The path this tree is on

Two ways to get Android 14 onto this board were on the table. This is the second
one, chosen deliberately after the first had been built far enough to price it.

**Path A, abandoned: Khadas' 4.19 BSP kernel plus the Rockchip Android 10
userspace.** The kernel built. Everything above it would have had to be
forward-ported - the Mali blob's gralloc integration above all, which is the
largest single unknown in the whole port - and none of that work is reusable
anywhere else.

**Path B, current: mainline 6.12 LTS plus AOSP's own userspace for it.**

| | driver | userspace, already in AOSP 14 |
|---|---|---|
| GPU | `drivers/gpu/drm/panfrost` | `external/mesa3d` → `libGLES_mesa` |
| Display | `drivers/gpu/drm/rockchip` | `external/drm_hwcomposer` + minigbm |
| Decode | `staging/media/rkvdec` (H.264 only) | `external/v4l2_codec2` |
| Wi-Fi | `brcmfmac` over SDIO | AOSP `wpa_supplicant` |
| Audio | `simple-audio-card` → HDMI | AOSP AIDL audio HAL over ALSA |
| Boot | mainline U-Boot + TF-A | ordinary GPT, images written from Linux |

No proprietary blob is involved. What made this credible rather than hopeful is
that the board is already proven on this kernel: its owner runs OpenWrt 25.12 on
it with Linux 6.12.94 and mainline U-Boot
(`github.com/220242/khadas_edge-openwrt`), which is also where the Wi-Fi firmware
and the board NVRAM in this tree come from.

The fact that forced the decision either way: **AOSP 14 ships no software GLES
driver a real device can load**, so SurfaceFlinger cannot start without a GPU
driver, and "boot first, GPU later" was never an option. panfrost supplies one
without a blob; the Mali blob would have had to be bridged to an IMapper it was
never written for.

What this costs, stated plainly:

- Hardware decode is H.264 only. 6.12's rkvdec has `rkvdec-h264.c` and nothing
  else, so HEVC and VP9 fall to software - 1080p yes, 4K no.
- Bluetooth is unresolved. The kernel driver and Android's HAL both want to own
  uart0; see `KERNEL.md`.
- Still no certification, on either path: software KeyMint, no attestation,
  Widevine L3 at best. Licensed HD streaming will not work. If that was the goal,
  this is the wrong vehicle and mainline Linux with Kodi on the same board is the
  right one.

## Summary

The port itself — device tree, AIDL HAL migration, Android TV configuration,
kernel delta, SELinux policy, build pipeline — is written and statically
verified. **No `update.img` was produced, and no compilation was attempted**,
because the environment this was authored in cannot sync or build AOSP. The
measurements are below; they are hard blocks, not preferences.

## What blocked the build

### 1. AOSP 14 sources are unreachable

`android.googlesource.com` is refused by this container's network policy:

```
$ git ls-remote https://android.googlesource.com/platform/build
fatal: unable to access '...': CONNECT tunnel failed, response 403

$ curl -sS "$HTTPS_PROXY/__agentproxy/status"
  "recentRelayFailures": [ { "kind": "connect_rejected",
    "detail": "gateway answered 403 to CONNECT (policy denial or upstream failure)",
    "host": "android.googlesource.com:443" } ]
```

A 403 on CONNECT is a policy denial, not a credentials problem, so no retry or
mirror substitution resolves it. `repo init -u https://android.googlesource.com/platform/manifest`
cannot run, so there is no AOSP 14 tree — and therefore no `build/envsetup.sh`
to source, no `lunch`, and no `m`.

`github.com/khadas` **is** reachable over git, which is why the legacy Android 10
sources could be read and the port grounded in them rather than guessed.

### 2. Disk is ~10x short

30GiB available. An AOSP 14 checkout is ~120GiB and one userdebug output tree is
~150GiB, so ~270GiB is needed.

### 3. RAM is below the documented minimum

15GiB, against Android 14's 16GiB minimum and 64GiB recommendation. R8 and
soong's Java steps get OOM-killed below that.

### 4. CPU width

4 cores. A full platform build is roughly 24 hours at that width even when
everything else fits.

`build/preflight.sh` checks all four and reports them; run on this container it
exits 1 and names each one.

## What this means for the self-correction loop

The requested loop — build, read compiler errors, patch, rebuild until
`update.img` appears — needs a compiler running over a synced tree. With no tree,
there is nothing to compile and no compiler diagnostics to read. Simulating that
loop would mean inventing plausible error messages and "fixing" them, which
produces confident-looking churn with no relationship to what the build would
actually say.

Instead the same discipline was applied to what *can* be checked without a tree.
`build/verify-tree.sh` validates XML well-formedness, every
`PRODUCT_COPY_FILES` and `BoardConfig.mk` file reference, VINTF consistency
between the device manifest and each shim fragment, shell syntax, and mandatory
kernel symbols. Its first run found **14 real errors** (missing keylayouts, media
configs, Wi-Fi/Bluetooth configs, `parameter.txt`, `package-file`, a
`baseparameter.img` that does not exist in this tree). All 14 were fixed; it now
reports 0 errors. That loop is real and repeatable — it just is not the compiler.

Two self-inflicted correctness bugs were also caught by reading the legacy
sources rather than assuming:

* The audio policy initially declared AC3/E-AC3/DTS/DTS-HD passthrough. The
  legacy HAL handles exactly one format, `AUDIO_FORMAT_PCM_16_BIT`, and does
  passthrough as IEC61937-framed PCM. Declaring those formats would have made
  apps request direct passthrough that `open_output_stream` rejects — silent
  playback rather than a clean PCM fallback. Corrected to PCM 16-bit + IEC61937.
* A boot control HAL was declared alongside a non-A/B partition layout. Removed,
  along with the `bootctrl` project in the manifest.

## What the GitHub AOSP mirror resolved, and what it did not

`github.com/aosp-mirror` is reachable from this container, so it was checked
empirically rather than assumed. It is a **partial reference mirror**, not a
buildable tree.

Present: `platform_manifest` (with real `android-14.0.0_r1`..`r75` branches),
`platform_build`, `platform_frameworks_base`, `platform_system_core`,
`platform_hardware_libhardware`.

Absent, and each one is disqualifying on its own: every `prebuilts/*` repo (so no
clang, no build-tools, no JDK - nothing can compile), `platform_build_soong`,
`platform_hardware_interfaces`, `platform_frameworks_native`,
`platform_frameworks_av`, `device/google/atv`, `packages/apps/TV`. The upstream
manifest lists 1357 projects; the mirror carries a few hundred.

So it cannot be used to build here, and it is irrelevant on a host where
`android.googlesource.com` is reachable - there the mirror would be strictly
worse. What it *did* settle, by reading the real AOSP 14 manifest at
`android-14.0.0_r75`:

* `device/google/atv` **is** in AOSP 14 (project and path both
  `device/google/atv`), so `edge1_tv.mk` inheriting `atv_base.mk` rests on a real
  project rather than an assumption.
* `packages/apps/TV` **is** present, so `LiveTv` is buildable.
* The `android-14.0.0_r*` tag series was confirmed, closing item 4 below.
* **It found a real bug in the overlay.** The manifest was checking the kernel
  out at path `kernel`, which would nest 28 upstream projects inside it -
  `kernel/configs`, `kernel/tests` and 26 `kernel/prebuilts/*` GKI trees - and
  repo rejects overlapping paths. `repo sync` would have failed immediately. The
  Android 10 manifest got away with `path="kernel"` because AOSP 10 had far fewer
  `kernel/*` projects. Fixed by moving to `kernel/khadas/edge`, verified clear in
  the upstream manifest, which needs no `<remove-project>` entries at all.
* `hardware/interfaces` is **not** mirrored, so the AIDL signatures for the
  unwritten shims remain unverifiable. That gap stands.

Also fixed while there: `build-kernel.sh` had a hardcoded clang version
(`clang-r487747c`) that would break on any release shipping a different one. It
now discovers the newest `clang-r*` prebuilt at run time.

## Also worth correcting in the original brief

* **There is no `device/khadas/edge` in the khadas-edge-Qt manifest.** The
  Khadas Edge1 ships as product `rk3399_all` inside
  `device/rockchip/rk3399`, with `PRODUCT_MODEL := Edge`,
  `PRODUCT_BRAND := Khadas` and `TARGET_BOARD_PLATFORM_PRODUCT := tablet`.
  `device/khadas/edge` is created by this port; it was not extracted.
* **The kernel is 4.19.111, not a 4.4 vendor kernel.** This is good news: 4.19
  is exactly Android 14's minimum for an *upgrade* device, so the port is viable
  without a kernel rebase. See `KERNEL.md`.
* **The GPU is Mali-T860 (`TARGET_BOARD_PLATFORM_GPU := mali-t860`)**, the
  Midgard family — T864 is the MP4 configuration of the same part. The correct
  gralloc backend is `libgralloc/midgard`; `bifrost` is for G-series and is
  deliberately not synced.
* **Khadas' own `android14` kernel branches are for Edge2 (RK3588S), not
  Edge1.** `khadas-edge2-android14` and `khadas-edge-2l-android14` are RK3588S.
  There is no upstream Khadas Android 14 for the RK3399 Edge1, which is why this
  is a port rather than a rebase.

## What a synced tree changed (android-14.0.0_r75)

Two probes against the real tree replaced most of the guesswork, and one of them
overturned the plan for the largest gap.

**All 21 declared AIDL HALs exist at the declared versions.** `vintf/manifest.xml`
was valid. `IAllocator` V2 has exactly the four methods the shim implements.
`IWifi` V1 is the generic AOSP interface, confirming that shipping no vendor Wi-Fi
HAL was right.

**AOSP 14 already ships the whole graphics stack**, so the two biggest gaps are
gone rather than solved:

| | |
|---|---|
| `android.hardware.graphics.allocator-service.minigbm` | AIDL allocator V2 |
| `mapper.minigbm` | IMapper 5 (stable-c) |
| `gralloc.minigbm` | gralloc0 backend |
| `hwcomposer.drm_minigbm` | drm_hwcomposer HWC2 |
| `android.hardware.graphics.composer@2.4-service` | HIDL passthrough composer |

minigbm has a rockchip backend and drm_hwcomposer is a generic atomic-KMS
composer, which the Rockchip DRM driver supports. That retires the hand-written
allocator shim, the unported `libgralloc_rk3399`, and an unwritten composer3
service whose `IComposerClient` has 48 methods. Audio is the same shape:
`android.hardware.audio.service-aidl.example` is a full ALSA-backed AIDL HAL, and
this board's audio is tinyalsa, so wrapping the Android 10 `audio_hw_device` is no
longer the plan either.

The cost is honest: minigbm's rockchip backend does not implement the RK3399's
AFBC layouts, so composition moves more bytes than Rockchip's own gralloc did.
GLES is Mesa's panfrost rather than the Mali blob - which on a mainline kernel is
not a fallback but the only option, since the blob speaks to a kmod this kernel
does not have.

**Composer is HIDL @2.4, not AIDL composer3.** AOSP 14's drm_hwcomposer snapshot
is HWC2 only - its tree has `hwc2_device/` and no reference to composer3 at all.
That was verified, not assumed, and it is why the manifest declares
`composer@2.4`. If `check_vintf` rejects HIDL composer at FCM level 8, lowering
`target-level` is defensible for an upgrade device at shipping API 29.

**Ten module names were wrong** and would each have failed the build separately:
`audio.effect-service.example` is really `audio.effect.service-aidl.example`;
`keymint-service.nonsecure` is really `keymint-service`;
`tv.hdmi.cec-service.example` is really `tv.hdmi.cec-service`. Four had no AOSP
equivalent at all and were removed: there is no software Gatekeeper (only
`.trusty`/`.remote`), no `light-service.example` (only `.cuttlefish`), no
`c2@1.2-service.software` (the software codecs live in the framework), no
`drm@4.0-service.widevine` (Widevine is not in AOSP), and `libwpa_client` was
deleted with the legacy Wi-Fi path. `brcm_patchram_plus` is a Rockchip vendor
tool, now gated - without it Bluetooth will not come up, though Wi-Fi is
unaffected.

Dropping Gatekeeper means keyguard falls back to framework credential checking:
PIN and pattern work, without hardware-enforced throttling.

## Remaining work before this boots

Ordered by what blocks what.

1. **composer3 AIDL service.** No display output without it, and no AOSP
   fallback exists. Largest single gap.
2. **audio.core `createOutputStream`.** No sound without it.
3. **Forward-port `libgralloc_rk3399`** (the gralloc0 module the allocator shim
   loads) and `audio.primary.rk3399` to build against the 14 VNDK.
4. ~~**Verify the AOSP tag.**~~ Resolved: the `android-14.0.0_r*` series runs
   r1..r75, confirmed from `aosp-mirror/platform_manifest`. `sync.sh` now
   defaults to r75, and `provision-wsl.sh` resolves the newest at run time.
5. ~~**Run `check_vintf`.**~~ Partly resolved, and the resolution is a warning
   rather than good news. `--check-compat` - the pass that checks the device
   manifest against the framework matrix, including the required-HAL list and the
   kernel requirements - runs only when `PRODUCT_ENFORCE_VINTF_MANIFEST` is true
   (`build/make/core/Makefile:5303`), and nothing in this product sets it. So the
   build will **not** fail on `target-level="8"`, on a missing required HAL, or on
   the 4.19.111 kernel being below any LTS minimum a recent FCM names. Those
   become first-boot and VTS problems instead of build problems. What does still
   run is `--check-one` on the vendor manifest, which only checks that manifest's
   own validity. Turning enforcement on is the hardening step after first boot,
   and it is expected to fail on the kernel version first.
6. **Confirm AIDL versions before naming one.** Soong resolves dependencies for
   modules it never builds, and it also refuses two versions of the same
   `aidl_interface` in one module - which is what killed the audio shim: it pinned
   `media.audio.common.types-V2-ndk` while the AOSP implementation it linked pulls
   V3 in through `bluetooth.audio-V4-ndk`. Both shims are now deleted, since they
   bridged to Rockchip HALs that left the tree, but the lesson stands for any board
   code that follows. Frozen versions read off the tree: `graphics.composer3`
   V1,2,3; `graphics.allocator` V1,2; `graphics.common` V1-5; `audio.core` V1,2;
   `audio.common` V1,2,3; `media.audio.common.types` V1,2,3; `tv.input` V1,2;
   `tv.hdmi.cec` V1; `tv.hdmi.connection` V1; `bluetooth` V1; `wifi` V1,2.
7. ~~**Kernel config merge.**~~ The kernel builds: `Image`, the DTB and five
   modules, with the config delta merged and verified symbol by symbol. What is
   still open there is `resource.img`, which the Rockchip `<dts>.img` target
   produces and `BOARD_PREBUILT_DTBOIMAGE` needs.
8. **Replace the invented codec performance numbers** in
   `media/media_codecs_performance.xml` with measurements from real hardware.

## The symlink that made the device tree invisible

`device/khadas/edge` was a symlink into this manifest repo - one place to edit,
under version control, and it looked right. It is why the first platform build
could not start:

    build/make/core/product_config.mk:226: error: Cannot locate config makefile
        for product "edge1_tv".

AOSP does not glob for `AndroidProducts.mk` at make time. It reads
`out/.module_paths/AndroidProducts.mk.list`, which Soong's finder writes by
walking the source tree, and that walk does not descend into symlinked
directories. The product existed, `lunch` parsed the combo, and the makefile
naming the product was invisible.

The same applies to everything else Soong globs, which is the part worth
recording: no `Android.bp` under the device tree had ever been parsed, so the
shim blueprints were not being analysed at all, and `BOARD_VENDOR_SEPOLICY_DIRS`
pointed into a directory Soong could not see. The first build that gets past
product config is therefore also the first one that will have an opinion about
those files.

`build/place-device.sh` now copies the device tree in as a real directory before
every stage that reads it, and clears the finder cache when the content changed.
The manifest repo stays the single source of truth; the copy is a build artefact.

## The Mesa integration, and where it came from

Not designed - copied, from `device/linaro/dragonboard/shared/graphics/mesa`, the
one working Mesa integration in the AOSP tree. Three rounds went into finding it,
and the detour is worth recording because each wrong turn had the same shape: a
plausible name that nothing reads.

`BOARD_MESA3D_GALLIUM_DRIVERS` came from Mesa's upstream Android documentation and
was set here first. The probe then found that the only mention of `BOARD_MESA3D_*`
anywhere in the tree is dragonboard's own makefiles, which set it alongside
`BOARD_MESA3D_USES_MESON_BUILD` and drive meson themselves. `external/mesa3d` never
reads those names. The variable it does read is `BOARD_GPU_DRIVERS`, and the proof
is in its `Android.mk`:

    MESA_BUILD_GALLIUM := $(strip $(foreach d, $(BOARD_GPU_DRIVERS), ...))

What dragonboard's `device.mk` then supplied, none of which was obvious:

* `PRODUCT_SOONG_NAMESPACES += external/mesa3d`. Mesa refuses to build without it -
  "external/mesa3d must be in PRODUCT_SOONG_NAMESPACES", `Android.mk:41`.
* Six packages, not one. `libGLES_mesa` is the loader's entry point; `libEGL_mesa`,
  `libGLESv1_CM_mesa` and `libGLESv2_mesa` are the rest of it, and the driver
  itself is `libgallium_dri` over `libglapi`.
* `ro.opengles.version`. The framework reports what this property says, not what
  the driver can do.

Two things were deliberately *not* copied. Vulkan: dragonboard ships
`vulkan.freedreno` and the Vulkan permissions, while panvk on Midgard is not
something to depend on. And `android.hardware.opengles.aep.xml`, which this tree
had been copying since the BSP days - AEP needs GLES 3.1 and a specific extension
set, and panfrost on Midgard delivers 3.0, so declaring it tells applications to
ask for what is not there.

## Decisions taken against the real build system

These came out of reading `android-14.0.0_r75` rather than from memory, after
`aosp-mirror/platform_build` turned out to be clonable from this environment.
Each one was wrong in the tree before it was checked.

| Setting | Why |
|---|---|
| `lunch edge1_tv-trunk_staging-userdebug` | 14's `lunch` requires three parts and rejects two outright. The two-part form would never have started a build. |
| `set +eu` around `envsetup.sh` | `envsetup.sh:21` reads `$TOP` before anything sets it; under `set -u` that ended the run before `m`. |
| `PRODUCT_ENABLE_UFFD_GC := false` | The default makes the build decide from the kernel version. 4.19.111 has neither the userfaultfd feature set nor `MREMAP_DONTUNMAP`, so the answer is no - stated directly rather than inferred. |
| `BOARD_USES_FULL_RECOVERY_IMAGE := true`, no `BOARD_INCLUDE_RECOVERY_DTBO` | Boot header v3 and v4 have no `recovery_dtbo` field, so the flag handed mkbootimg an argument it cannot place. |
| Four `PRODUCT_*` variables deleted | `PRODUCT_BUILD_PROP_OVERRIDES`, `PRODUCT_HAS_CAMERA`, `PRODUCT_HAVE_OPTEE`, `PRODUCT_TARGET_VNDK_VERSION` appear nowhere in AOSP 14. They were read by `device/rockchip/common`, which this tree does not have, so they were decoration that read like configuration. |
| No `ro.product.first_api_level` override | `core/main.mk:284` already emits it from `PRODUCT_SHIPPING_API_LEVEL`. Setting both worked only while they agreed, and `post_process_props.py` rejects duplicates that disagree - so raising the shipping level later would have failed the build. |
| `CCACHE_DIR=$TREE/out/ccache` | 14 runs ninja with everything outside `$OUT_DIR` bind-mounted read-only. ccache's default `$HOME/.cache/ccache` is on the wrong side of that, so the first real compile died at target 151 of 167136 on `Failed to create directory ...: Read-only file system`. The build's own error text names the fix it wants: generate into `out/`. The directory is also written into `ccache.conf` in both places ccache looks, in case Soong strips the variable out of the environment it hands ninja. |

Also checked and found clean: none of the 69 `KATI_obsolete_var` names are used
anywhere in the device tree, and the dynamic-partition group naming matches what
`core/config.mk` derives (`BOARD_ROCKCHIP_DYNAMIC_PARTITIONS_SIZE` and
`_PARTITION_LIST` are exactly what `to-upper` of the group name asks for).

## Paths that were still the BSP's

Moving to a mainline kernel changed every sysfs and device path the board config
names, and a stale one of those does not fail a build - it fails silently on the
device. The platform build reaching 71% is what made this worth sweeping: the next
failure will be at boot, where there is no log to grep.

Each of these was checked against `rk3399-base.dtsi`, `rk3399-khadas-edge.dtsi`
and `rk3399-khadas-edge-v.dts` at v6.12.111, not from memory. A platform device is
named `<address>.<node name>`, and the BSP renamed several of those nodes.

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
| `init.edge1.rc`: `write /sys/class/backlight/backlight/brightness` | removed | Same missing device. |
| `init.edge1.usb.rc`: `/sys/class/android_usb/android0/...` | `sys.usb.controller=fe800000.usb` | `android_usb` is the pre-configfs gadget. The dts gives `usbdrd_dwc3_0` (`usb@fe800000`) `dr_mode = "otg"`, so that is the UDC. |
| `init.edge1.rc`: a bare `oneshot`, `start brcm_patchram` | removed | Left over from a deleted service stanza; init read `oneshot` as a command inside `on boot`. |
| fragment: `CONFIG_DWMAC_ROCKCHIP=y` alone | `+ CONFIG_STMMAC_PLATFORM=y` | `DWMAC_ROCKCHIP` is inside `if STMMAC_PLATFORM`, a tristate. While the parent was `m` the child could not be `y`, so `olddefconfig` demoted it - no Ethernet, on a board whose dts enables `&gmac`. |

One more of the same shape, found the run after: `sysfs_gpu`. It was declared in
`sepolicy/vendor/sysfs_types.te` because the GPU is the board's - but the platform
declares it too (surfaceflinger, gpuservice and the composer HAL all have rules
against it), and `checkpolicy` treats a second declaration as fatal:

```
sysfs_types.te:8:ERROR 'Duplicate declaration of type' at token ';'
type sysfs_gpu, fs_type, sysfs_type;
```

The probe had been blind to exactly this: its "borrowed from AOSP" list is
`referenced ∩ platform − ours`, so a type both sides declare was subtracted out
and read as locally declared. It now prints every type this device declares with
whether AOSP already has it, and fails the run on a collision - which answers the
same question for `sysfs_hdmi`, `sysfs_mmc_host`, `sysfs_devfreq`,
`hdmi_cec_device`, `lirc_device` and `vendor_firmware_file` in one go instead of
one per build. `verify-tree.sh` check 9 checks the offline half of it.

And once more the run after, one level down:

```
host_init_verifier: Unable to serialize property contexts:
Duplicate exact match detected for 'ro.hardware.gralloc'
```

`ro.hardware.*` is inside the prefixes a vendor partition may own, so
`check_prop_prefix` passed it - but the platform already labels those five
properties, because the code that reads them is platform code: the EGL loader
resolves `ro.hardware.egl`, the gralloc and composer loaders resolve
`ro.hardware.gralloc` and `ro.hardware.hwcomposer`, and libaudiohal resolves
`ro.hardware.audio.primary`. Being allowed to own a prefix is not the same as the
name being free. `property_contexts` and `property.te` are both gone
(`sepolicy/vendor/README.md` records why); `device.mk` still sets the values,
which needs no label. The probe gained the matching gate, so this question is
answered for every name at once rather than one per build, and the report no longer
truncates the probe at 400 lines - which is what hid both of the last two answers.

Then the same shape a third time, in VINTF:

```
assemble_vintf: Cannot override existing value 29.0 with BOARD_SEPOLICY_VERS
(which is 202404).
```

`vintf/manifest.xml` carried `<sepolicy><version>29.0</version></sepolicy>`, set to
match `PRODUCT_SHIPPING_API_LEVEL`. The build passes `BOARD_SEPOLICY_VERS` into
`assemble_vintf` as an environment override and refuses to overwrite a value the
input already has. 202404 is the right number and 29.0 was not: `core/config.mk`
derives `BOARD_SEPOLICY_VERS` from `PLATFORM_SEPOLICY_VERSION`, the version the
vendor policy is compiled against, which has nothing to do with the shipping API
level. The field is left for the build to fill, the same way `BOARD_SEPOLICY_VERS`
itself already was.

Reading that file turned up something the build would never have reported. It
declared HIDL `android.hardware.drm@4.0` with clearkey instances, while `device.mk`
installs `android.hardware.drm-service.clearkey` - the AIDL service, which carries
its own fragment. The HIDL 4.0 clearkey service does not exist in AOSP 14. A device
manifest is a promise that the device provides a HAL, and nothing at build time
checks it: `check_vintf` asks whether the *framework's* requirements are met, and
`assemble_vintf` copies our entries through. It would have shown up as the media
framework waiting on a hwbinder DRM HAL that never registers. `verify-tree.sh`
check 4b now requires every manifest entry to have a package behind it, matched by
format - a HIDL entry needs `<hal>@<version>...`, an AIDL one `<hal>-service...` or
`<hal>-V<n>...`, because those are different binaries.

VINTF assembly then passed, and the next one was in `build.prop`:

```
error: found duplicate sysprop assignments:
ro.product.board=
ro.product.board=rk3399
```

`core/main.mk:332-341` appends `ro.product.board`, `ro.board.platform`,
`ro.hwui.use_vulkan` and `ro.sf.lcd_density` to `ADDITIONAL_VENDOR_PROPERTIES`,
from `TARGET_BOOTLOADER_BOARD_NAME`, `TARGET_BOARD_PLATFORM`,
`TARGET_USES_VULKAN` and `TARGET_SCREEN_DENSITY`. `device.mk` set the first two by
hand and `TARGET_BOOTLOADER_BOARD_NAME` was unset, so the build emitted an empty
assignment beside ours. All three now come from their board variables.

What makes this worth a check rather than a one-line fix is the escape hatch:
`tools/post_process_props.py:112-117` allows duplicates when every value is
identical, so `ro.board.platform=rk3399` was also set twice and passed - an error
waiting for `TARGET_BOARD_PLATFORM` to change. `verify-tree.sh` check 9e lists the
fourteen properties `main.mk` derives and names the variable to set instead.

Reading `core/sysprop.mk` to find where the duplicate met also corrected a
standing assumption about this tree: with `property_overrides_split_enabled` - any
device with a vendor partition - `PRODUCT_PROPERTY_OVERRIDES` goes to
`/vendor/build.prop` and is dropped from `/system/build.prop`
(`core/sysprop.mk:368-380`). Every property line in `device.mk` and `edge1_tv.mk`
is a vendor property. Properties are global at run time so nothing was broken by
it, but it is why the failure surfaced in `vendor/build.prop`.

The same run turned up a booby trap in the kernel fragment. `merge_config.sh`
picks the symbols to merge with two `sed` patterns and then reads each value back
with `grep -w $CFG`, so a comment that mentions a symbol the fragment also sets
makes that `grep` return two lines and the override report print the comment as
the value. The merge is unaffected, but the one output that says whether a symbol
took becomes unreadable - and `# CONFIG_X is deliberately absent` is four words
away from matching the second pattern, `# CONFIG_X is not set`, and turning the
symbol off. Comments name symbols without the `CONFIG_` prefix now, and check 7
enforces both halves.

Two gates were added so this class of thing stops being found by reading:
`build-kernel.sh` now exits non-zero when any symbol in the fragment did not take
(it printed `NOT SET: CONFIG_DWMAC_ROCKCHIP=y` and the build went ahead anyway),
and the module probe exits non-zero when `device.mk` requests a module that does
not exist. The second matters because `core/main.mk:1341` only checks
`PRODUCT_PACKAGES` names when a product sets `PRODUCT_ENFORCE_PACKAGES_EXIST` -
otherwise a name that matches nothing is dropped in silence, which is how four
Mesa libraries sat in `device.mk` looking installed.

## Honest expectation

With items 1-3 done this should boot to a leanback launcher over HDMI. It will
not pass CTS: software KeyMint rules out attestation (see `HAL_MIGRATION.md`),
`PRODUCT_SHIPPING_API_LEVEL` is 29 which is correct for an upgrade but not for
certification as a 14 device, and the codec performance points are placeholders.
