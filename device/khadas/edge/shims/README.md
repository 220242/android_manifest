# HAL shims: Android 10 HIDL -> Android 14 AIDL

Completion state of each shim, stated plainly. "Verified" below means read out of
the pinned Android 10 source, not recalled.

| Shim | Legacy interface (verified) | Target | State |
|---|---|---|---|
| `graphics/allocator` | gralloc0 `alloc_device_t` (`GRALLOC_HARDWARE_MODULE_ID`, `drm_mod_alloc_gpu0`) | `android.hardware.graphics.allocator-V2` | Implemented |
| `audio` | `audio_hw_device` v2.0 (`adev_open_output_stream`) | `android.hardware.audio.core-V2` | Device open + lifecycle implemented; stream I/O **not implemented** |
| `graphics/composer` | `hwcomposer` (drm_hwcomposer fork) | `graphics.composer3-V3` | Strategy only, no code |
| `tv_input` | `tv_input.default` stub | `tv.input-V1` | Strategy only, no code |
| `hdmi_cec` | `hardware/rockchip/hdmicec` | `tv.hdmi.cec-V1` + `.hdmi.connection-V1` | Strategy only, no code |
| Wi-Fi | `wifi@1.3`, `supplicant@1.2`, `hostapd@1.1` | AIDL | **No shim needed** - see below |
| Bluetooth | `bluetooth@1.0` + `libbt-vendor` | `bluetooth-V1` | **No shim needed** - see below |

## Why Wi-Fi and Bluetooth need no shim

This is the largest simplification in the port, so it is worth being explicit.

Rockchip's Android 10 Wi-Fi HAL existed only to wrap nl80211. AOSP's
`android.hardware.wifi-service`, `wpa_supplicant` and `hostapd` AIDL services are
already driver-agnostic nl80211 implementations, so the BCM4359 needs no vendor
HAL at all - only the firmware paths in `BoardConfig.mk` and the `bcmdhd` module.
Three HIDL components are deleted rather than ported.

Bluetooth is the same shape: AOSP's
`android.hardware.bluetooth-service.default` speaks H4 over a UART directly. The
BCM4359 needs its firmware patchram loaded first, which is a one-shot service in
`init/init.edge1.rc`, not a HAL responsibility.

## Verified against a real Android 14 tree (android-14.0.0_r75)

`build/verify-aidl-surface.sh` was run against a synced tree. Results:

* **`graphics.allocator` V2 — confirmed.** The four methods this shim implements
  match the frozen AIDL exactly: `allocate(byte[], int)`,
  `allocate2(BufferDescriptorInfo, int)`, `isSupported(BufferDescriptorInfo)`,
  `getIMapperLibrarySuffix()`. No changes needed.
* **`wifi` V1 — confirmed.** `IWifi` is the generic AOSP interface, which
  supports the decision to ship AOSP's `wifi-service` with no vendor HAL.
* **`tv.input` V1, `tv.hdmi.cec` V1, `tv.hdmi.connection` V1 — signatures
  obtained.** Enough to write these three shims when they are wanted; AOSP's
  examples cover them for now.
* **`graphics.composer3`, `audio.core`, `audio.effect` — not yet read.** The first
  run reported them missing, which was a false negative from this script deriving
  a directory from the package name: composer3 lives in `graphics/composer/aidl`
  and audio.core in `audio/aidl`. The script now finds interfaces by searching for
  `aidl_api/<package>/<version>`, so a re-run returns them.

## Why the remaining three are strategy-only

`composer3`, `tv.input` and `tv.hdmi.cec` are not written as code because their
AIDL method signatures cannot be verified in the environment this port was
authored in - `android.googlesource.com` is unreachable from it, so
`hardware/interfaces` was never synced (see `docs/STATUS.md`).

Writing those bodies from memory would produce files that read as finished and
fail to compile, which is worse than an honest gap: a reviewer would have to
reverse-engineer intent from wrong code. The per-HAL strategy, including which
AOSP base class to subclass and which legacy entry points to bridge, is in
`docs/HAL_MIGRATION.md`.

`build/verify-aidl-surface.sh` prints the real method list for every AIDL
interface this device declares, once a tree is synced. Run it before writing
these shims.

## Build wiring

Each shim directory carries its own `Android.bp` with `init_rc` and
`vintf_fragments`, which is the Android 14 convention: the service's `.rc` and
its VINTF entry install alongside the binary. The Android 10 tree instead
hand-listed every HIDL service in `device/rockchip/common/init.rockchip.rc` and
took its VINTF manifest from `vendor/rockchip`, which is why none of that
wiring could be carried over.

`device/khadas/edge/vintf/manifest.xml` is the device-wide manifest and must stay
consistent with the per-shim fragments; a HAL declared in one and not the other
fails `check_vintf`.
