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

### Audio (`shims/audio`) — partial

Device open, version check and lifecycle are implemented. `createOutputStream`
is not. Verified legacy constraints the bridge must respect:

* the only format handled is `AUDIO_FORMAT_PCM_16_BIT`;
* output accepts up to 8 channels, with 8ch@192kHz special-cased;
* passthrough is `SPDIF_PASSTHROUGH_MODE`, i.e. IEC61937-framed PCM
  (`setChanSta` / `fill_hdmi_bitstream_buf`), **not** a compressed format.

`audio/audio_policy_configuration.xml` matches this exactly and declares only
PCM 16-bit and IEC61937. Adding real AC3/E-AC3/DTS passthrough means teaching
the HAL new formats; the IEC61937 framing helper is the starting point. Declaring
those formats in the policy before the HAL accepts them produces silent playback,
not a fallback.

Steps: map `StreamContext`'s port config to `struct audio_config`, call
`open_output_stream`, wrap the returned `audio_stream_out_t` in a
`DriverInterface` whose `transfer()` calls `stream->write()`, and reject configs
outside the constraints above.

### Composer3 (`graphics.composer3-V3`) — the largest gap

No usable AOSP fallback exists for real display output, so without this the
image cannot composite. Subclass AOSP's composer3 `ComposerClient` and bridge
Rockchip's `hardware/rockchip/hwcomposer` (a drm_hwcomposer fork). The
RGA 2D engine is the fallback path for layers no DRM plane can handle, which is
why `hal_graphics_composer_rk3399.te` grants `rga_device`.

### light / power / memtrack

AOSP examples are wired in so the build completes. Each fallback costs
something concrete, listed in `device.mk` beside the `else` branch: no LED or
backlight control, no RK3399 big.LITTLE boost hints (worse UI latency), and Mali
allocations missing from `dumpsys meminfo`.

## Before writing any remaining shim

Run `build/verify-aidl-surface.sh` against a synced tree. It prints the real
method list for every AIDL interface `vintf/manifest.xml` declares. AIDL
signatures moved between Android 13, 14 and the 14 QPRs; a shim written from
memory compiles against nothing.
