# Khadas Edge1: HIDL (Android 10) -> AIDL (Android 14) HAL migration

Every "was" column below was read out of the pinned Android 10 sources
(`manifests/khadas_edge_tv14.xml` records the SHAs), not recalled.

## Matrix

| Android 10 HIDL | Android 14 target | Approach | State |
|---|---|---|---|
| `graphics.allocator@2.0` | `graphics.allocator-V2` (AIDL) | Shim over gralloc0 `alloc_device_t` | **Implemented** |
| `graphics.mapper@{2,3}.0` | `graphics.mapper@4.0` (Gralloc4) | Keep HIDL passthrough | Decision made, see below |
| `graphics.composer@2.{1,2,3}` | `graphics.composer3-V3` (AIDL) | Subclass AOSP, bridge Rockchip drm_hwc | Strategy only |
| `audio@5.0` | `audio.core-V2` (AIDL) | Subclass AOSP `Module`, bridge `audio_hw_device` | Partial |
| `audio.effect@5.0` | `audio.effect-V2` (AIDL) | Use AOSP `-service.example` | **Done (AOSP)** |
| `tv.input@1.0` | `tv.input-V1` (AIDL) | AOSP example (no inputs on this board) | **Done (AOSP)** |
| `tv.cec@1.0` | `tv.hdmi.cec-V1` + `tv.hdmi.connection-V1` | AOSP example over `/dev/cec0` | **Done (AOSP)** |
| `wifi@1.3` | `wifi-V1` (AIDL) | AOSP `android.hardware.wifi-service` | **Done (AOSP)** |
| `wifi.supplicant@1.2` | `wifi.supplicant-V3` (AIDL) | AOSP `wpa_supplicant` | **Done (AOSP)** |
| `wifi.hostapd@1.1` | `wifi.hostapd-V1` (AIDL) | AOSP `hostapd` | **Done (AOSP)** |
| `bluetooth@1.0` | `bluetooth-V1` (AIDL) | AOSP `-service.default` + patchram in init | **Done (AOSP)** |
| `health@2.0` | `health-V2` (AIDL) | AOSP `-service.example` | **Done (AOSP)** |
| `light@2.0` | `light-V2` (AIDL) | AOSP example; Rockchip shim pending | Degraded |
| `power@1.0` | `power-V4` (AIDL) | AOSP example; Rockchip shim pending | Degraded |
| `thermal@1.0` | `thermal-V1` (AIDL) | AOSP `-service.example` | **Done (AOSP)** |
| `memtrack@1.0` | `memtrack-V1` (AIDL) | AOSP example; Rockchip shim pending | Degraded |
| `usb@1.1` | `usb-V1` (AIDL) | AOSP `-service.example` | **Done (AOSP)** |
| `keymaster@4.0` | `security.keymint-V3` (AIDL) | AOSP **nonsecure** (software) | Downgrade, see below |
| `gatekeeper@1.0` | `gatekeeper-V1` (AIDL) | AOSP **nonsecure** (software) | Downgrade |
| `media.c2@1.0` | `media.c2@1.2` | Software store; Rockchip MPP store pending | Degraded |
| `drm@1.2` | `drm@4.0` | Widevine L3 + clearkey | Carried forward |
| `boot@1.1` | — | **Dropped**: non-A/B device | Removed |
| `sensors@1.0` | — | **Dropped**: no sensors on the TV SKU | Removed |
| `gnss@1.1`, `nfc@1.2`, `vibrator@1.0` | — | **Dropped**: absent hardware | Removed |
| `atrace@1.0` | — | Removed from the platform | Removed |

Counting the work: of 24 legacy HIDL interfaces, **7 are deleted** outright
(absent hardware or removed from the platform), **11 are satisfied by AOSP's own
AIDL implementations** with no vendor code at all, and only **6 need
board-specific code**. That ratio is the single most useful result of this
migration, and it is why the port is tractable.

## The three biggest decisions

### 1. Wi-Fi and Bluetooth need no vendor HAL

Rockchip's Android 10 Wi-Fi HAL wrapped nl80211. AOSP's `wifi-service`,
`wpa_supplicant` and `hostapd` AIDL services are already driver-agnostic nl80211
implementations, so the BCM4359 needs only the firmware paths in
`BoardConfig.mk` plus the `bcmdhd` module. Three HIDL components are deleted
rather than ported.

Bluetooth is the same: AOSP's `bluetooth-service.default` speaks H4 over a UART.
The BCM4359 needs its patchram loaded first, which is a one-shot init service
(`init/init.edge1.rc`), not a HAL.

### 2. Mapper stays on Gralloc4 (IMapper 4.0), not IMapper 5

Android 14 introduces IMapper 5.0, a "stable-c" mapper loaded as a plain
library, and `IAllocator::getIMapperLibrarySuffix()` is how a client discovers
it. This port keeps HIDL `mapper@4.0`, because:

* Gralloc4 is still permitted in the Android 14 FCM, so it is not a compliance
  problem.
* Rockchip's gralloc is a **gralloc0** module (`GRALLOC_HARDWARE_MODULE_ID`,
  `drm_mod_alloc_gpu0`). Getting from gralloc0 to IMapper 5 is two rewrites, not
  one; going to Gralloc4 first is a smaller, testable step.

The consequence is coded explicitly: `RkAllocator::getIMapperLibrarySuffix()`
returns `EX_UNSUPPORTED_OPERATION`. Returning a suffix would make `libui` load
an IMapper 5 library that does not exist and fail buffer import at runtime. If
IMapper 5 is added later, that method and `vintf/manifest.xml` must change
together.

### 3. KeyMint and Gatekeeper are software, so attestation is gone

`PRODUCT_HAVE_OPTEE` is false, and the Edge1 has no provisioned TEE. The
`nonsecure` KeyMint and Gatekeeper implementations are therefore used.

Consequences, stated plainly:

* Hardware key attestation is unavailable. **CTS/GTS attestation tests cannot
  pass**, so this build cannot be certified.
* Keystore keys are protected by software only. Do not treat the device as
  meeting the hardware-backed-keystore claims of a retail Android TV.
* StrongBox is absent, which some DRM and payment apps check for.

Widevine is L3 for the same reason: L1 needs an OP-TEE trusted app.

## Per-HAL notes for the unfinished work

The two shims this section used to describe - `shims/audio` and
`shims/graphics/allocator` - have been deleted, and the reason is worth keeping:
both existed to bridge AIDL down to the Rockchip Android 10 HALs, and those left
the tree with `hardware/rockchip`. A bridge to code that is no longer synced cannot
work, and the audio one had gone from useless to harmful - Soong analyses a module
whether or not anything installs it, and it failed the build with

    depends on multiple versions of the same aidl_interface:
    android.media.audio.common.types-V2-ndk-source, ...-V3-ndk-source

because it pinned V2 while the AOSP implementation it linked pulls V3 through
`android.hardware.bluetooth.audio-V4-ndk`. Fixing the version would have kept a
file whose whole purpose had gone.

### Audio

AOSP's own AIDL HAL, `android.hardware.audio.service-aidl.example` from
`hardware/interfaces/audio/aidl/default`, which has both an `alsa/` backend and a
`primary/` module. On a mainline kernel the HDMI audio path is
`simple-audio-card` wiring i2s2 to the HDMI bridge's codec, so this is ALSA all the
way down and the remaining work is configuration: the card and device numbers in
`audio/audio_policy_configuration.xml` and `audio/mixer_paths.xml`.

The legacy constraints that file was written against still hold and are still worth
respecting, because they are properties of the hardware rather than of the old HAL:
PCM 16-bit, up to 8 channels with 8ch@192kHz special-cased, and passthrough only as
IEC61937-framed PCM rather than a compressed format. Declaring AC3/E-AC3/DTS in the
policy before something can produce them gives silence, not a fallback.

### Display and GLES

`hwcomposer.drm_minigbm` (AOSP's drm_hwcomposer, HWC2 behind HIDL composer@2.4)
over `drivers/gpu/drm/rockchip`, with buffers from minigbm. This is why the device
manifest declares composer@2.4 rather than composer3: the drm_hwcomposer snapshot
in AOSP 14 contains `hwc2_device/` and no composer3 code at all.

GLES is Mesa's panfrost driver against `drivers/gpu/drm/panfrost`. Not optional:
AOSP 14 packages no software GLES driver a device can load, so SurfaceFlinger does
not start without one. The open question is only which board variable
`external/mesa3d` reads to select the driver - see `BOARD_GPU_DRIVERS` in
`BoardConfig.mk`, where the evidence so far is written down.

### Video

`android.hardware.media.c2@1.2-service-v4l2` from `external/v4l2_codec2`, over
`staging/media/rkvdec`. H.264 only in 6.12 - that snapshot has `rkvdec-h264.c` and
nothing else - so HEVC and VP9 are software. Not yet wired up; the software codecs
carry playback in the meantime.

### light / power / memtrack

AOSP examples, and each costs something concrete: no LED or backlight control, no
RK3399 big.LITTLE boost hints, and GPU allocations missing from `dumpsys meminfo`.
On a mainline kernel these would be written against sysfs - `/sys/class/leds`,
devfreq, cpufreq - rather than against the Rockchip HIDL libraries.

## Before writing any board HAL code

Run `build/verify-aidl-surface.sh` against a synced tree. It prints the real method
list for every interface this board's HALs speak, and the frozen version of each -
which is the number a `-V<n>-ndk` dependency has to name. AIDL signatures moved
between Android 13, 14 and the 14 QPRs, and a module written from memory compiles
against nothing. The version mismatch above is the same lesson from the other
direction: the number has to match what the rest of the graph already uses.
