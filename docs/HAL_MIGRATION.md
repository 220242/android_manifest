# HAL migration: Android 10 HIDL → Android 14 AIDL

Every "Android 10" entry below was read out of the pinned `khadas-edge-Qt` sources,
and every Android 14 module name was checked against a synced `android-14.0.0_r75`
tree by `build/windows/provision-wsl.sh probe`, which fails the run on a name that
matches no module. Ten names in an earlier revision of this file were wrong and each
would have failed the build separately.

## The result in one line

Of the 27 HIDL interfaces the Android 10 tree declared, **26 need no vendor code**:
7 are deleted outright (absent hardware, no TEE, or removed from the platform) and 19
are satisfied by an AOSP implementation talking to a mainline driver. The one that is
board-specific is the codec2 service, and it is not wired up yet.

That ratio is what makes the port tractable, and it is a consequence of the move to
a mainline kernel rather than of anything clever here. On the 4.19 BSP the same table
had six entries needing board code, because the drivers were Rockchip's and so was
the userspace that spoke to them.

## Matrix

| Android 10 HIDL | Android 14 | How | State |
|---|---|---|---|
| `graphics.allocator@2.0` | `graphics.allocator-V2` (AIDL) | `android.hardware.graphics.allocator-service.minigbm` | AOSP |
| `graphics.mapper@{2,3}.0` | IMapper 5 (stable-c) | `mapper.minigbm` | AOSP |
| — | gralloc0 backend | `gralloc.minigbm` | AOSP |
| `graphics.composer@2.{1,2,3}` | `graphics.composer@2.4` (HIDL) | `android.hardware.graphics.composer@2.4-service` loading `hwcomposer.drm_minigbm` | AOSP, sets FCM level 7 |
| `audio@5.0` | `audio.core-V2` (AIDL) | AOSP AIDL audio HAL, ALSA backend | AOSP, needs config |
| `audio.effect@5.0` | `audio.effect-V2` (AIDL) | `audio.effect.service-aidl.example` | AOSP |
| `tv.input@1.0` | `tv.input-V1` (AIDL) | AOSP example — no tuner inputs on this board | AOSP |
| `tv.cec@1.0` | `tv.hdmi.cec-V1` + `tv.hdmi.connection-V1` | AOSP service over `/dev/cec0` | AOSP |
| `wifi@1.3` | none | the framework runs HAL-less over brcmfmac | see below |
| `wifi.supplicant@1.2` | `wifi.supplicant-V3` (AIDL) | AOSP `wpa_supplicant` | AOSP |
| `wifi.hostapd@1.1` | `wifi.hostapd-V2` (AIDL) | AOSP `hostapd` | AOSP |
| `bluetooth@1.0` | `bluetooth-V1` (AIDL) | AOSP `-service.default` over the kernel's hci0 | AOSP, see below |
| `health@2.0` | `health-V2` (AIDL) | AOSP `-service.example` | AOSP |
| `light@2.0` | `light-V2` (AIDL) | AOSP example | AOSP, degraded |
| `power@1.0` | `power-V4` (AIDL) | AOSP example | AOSP, degraded |
| `thermal@1.0` | `thermal-V1` (AIDL) | AOSP `-service.example` | AOSP |
| `memtrack@1.0` | `memtrack-V1` (AIDL) | AOSP example | AOSP, degraded |
| `usb@1.1` | `usb-V1` (AIDL) | AOSP `-service.example` | AOSP |
| `keymaster@4.0` | `security.keymint-V3` (AIDL) | AOSP **software** implementation | downgrade, see below |
| `gatekeeper@1.0` | `gatekeeper-V1` (AIDL) | none in AOSP for a device with no TEE | dropped, see below |
| `media.c2@1.0` | `media.c2@1.2` | software codecs from the framework | **open**: `-service-v4l2` not installed |
| `drm@1.2` | `drm` (AIDL) | `android.hardware.drm-service.clearkey` | AOSP, clearkey only |
| `boot@1.1` | — | dropped: non-A/B device | removed |
| `sensors@1.0` | — | dropped: no sensors on the TV SKU | removed |
| `gnss@1.1`, `nfc@1.2`, `vibrator@1.0` | — | dropped: absent hardware | removed |
| `atrace@1.0` | — | removed from the platform | removed |

One HAL not in the table above also ends up in the image and matters for
compatibility: `android.hardware.cas@1.2-service`, the HIDL conditional access
service. Nothing here asks for it — `base_vendor.mk:90` puts it in
`PRODUCT_PACKAGES_SHIPPING_API_LEVEL_33`, and this device ships at API 29. It arrives
with its own VINTF fragment, and together with the HIDL composer it is why the device
manifest targets FCM level 7.

Only two HALs are declared in `vintf/manifest.xml` directly — in fact only one now.
Every AIDL service above installs its own VINTF fragment next to its binary, and
declaring the same HAL in the device manifest as well declares it twice.
`verify-tree.sh` check 4 enforces that, and check 4b enforces the other direction:
an entry in the manifest must have a package behind it, matched by format, because a
HIDL entry needs `<hal>@<version>...` and an AIDL one `<hal>-service...` and those
are different binaries. A HIDL `drm@4.0` entry that survived from the BSP days was
found that way.

## Four decisions worth the detail

### Graphics is AOSP's, and that retired the two largest gaps

The BSP plan needed a hand-written allocator shim over Rockchip's gralloc0 module, a
forward-ported `libgralloc_rk3399`, and an unwritten composer3 service whose
`IComposerClient` has 48 methods. A synced tree made all three unnecessary: minigbm
has a rockchip backend, and drm_hwcomposer is a generic atomic-KMS composer that the
Rockchip DRM driver supports.

The composer is HIDL `@2.4`, not AIDL composer3, and that was verified rather than
assumed: AOSP 14's drm_hwcomposer snapshot contains `hwc2_device/` and not one
reference to composer3. HWC2 is reached through the HIDL passthrough service
`android.hardware.graphics.composer@2.4-service`, which dlopens
`hwcomposer.$(ro.hardware.hwcomposer).so` — here `hwcomposer.drm_minigbm`.

`check_vintf` did reject it at FCM level 8, which lists only `composer3` AIDL. Level
7 lists `graphics.composer` HIDL 2.1-4, so `vintf/manifest.xml` targets level 7 —
permitted for an upgrade device, and an honest description of a vendor image whose
composer is HIDL. `STATUS.md` has the matrices and the reasoning. The alternative is
to write the composer3 service, which means implementing `IComposerClient`'s 48
methods against a drm_hwcomposer that has no composer3 code.

GLES is Mesa's panfrost against `drivers/gpu/drm/panfrost`, and it is not optional:
AOSP 14 packages no software GLES driver a real device can load, so SurfaceFlinger
does not start without one. `BOARD_GPU_DRIVERS := panfrost kmsro` is the variable
`external/mesa3d` actually reads — see `STATUS.md` for the three wrong names that
preceded it.

What this costs: minigbm's rockchip backend does not implement the RK3399's AFBC
layouts, so composition moves more bytes than Rockchip's own gralloc did.

### Wi-Fi needs no vendor HAL, and Bluetooth needs no vendor tool

AOSP's `wpa_supplicant` and `hostapd` are driver-agnostic nl80211 implementations,
so the AP6398S needs only brcmfmac and its firmware. `android.hardware.wifi-service`
is not: it sits on a legacy HAL (libwifi-hal) chosen by `BOARD_WLAN_DEVICE`, and every
choice speaks a vendor driver's private commands. Installed without one (until card
16) it failed every start and the framework would not bring Wi-Fi up while IWifi was
declared. Not installed, the framework runs HAL-less: wificond scans, the supplicant
associates. Two build details matter: `WPA_SUPPLICANT_VERSION := VER_0_8_X` in
BoardConfig.mk, without which external/wpa_supplicant_8 defines neither binary, and
the firmware in the ramdisk as well as `/vendor`, because the built-in driver asks
for it before `/vendor` is mounted.

Bluetooth: uart0 is a serdev controller in the DTS, so the kernel's `hci_bcm` owns
it, loads `BCM4359C0.hcd` and registers hci0. AOSP's `bluetooth-service.default`
tries an HCI user channel on hci0 before any tty (`net_bluetooth_mgmt.cpp`), so it
needs neither `libbt-vendor` nor `brcm_patchram_plus`. It does soft-block rfkill
before binding, which makes the kernel refuse the bind, so `/dev/rfkill` stays
root-only and the HAL skips that step.

### KeyMint is software, so attestation is gone

The Edge1 has no provisioned TEE, so KeyMint is AOSP's software implementation and
there is no Gatekeeper at all — AOSP ships only `.trusty` and `.remote`, neither of
which applies. Stated plainly:

* Hardware key attestation is unavailable, so **CTS/GTS attestation tests cannot
  pass** and this build cannot be certified.
* Keystore keys are protected by software only. Do not treat the device as meeting
  the hardware-backed-keystore claims of a retail Android TV.
* StrongBox is absent, which some DRM and payment apps check for.
* Dropping Gatekeeper means keyguard falls back to framework credential checking:
  PIN and pattern work, without hardware-enforced throttling.

DRM is clearkey only. Widevine is not part of AOSP — `drm-service.widevine` comes
from `vendor/widevine`, which this overlay does not sync — and L1 would need an
OP-TEE trusted app on top of that.

### light, power and memtrack are AOSP examples, and that is a real cost

No LED or backlight control, no RK3399 big.LITTLE boost hints, and GPU allocations
missing from `dumpsys meminfo`. On a mainline kernel these would be written against
sysfs — `/sys/class/leds`, devfreq, cpufreq — rather than against the Rockchip HIDL
libraries, which is a smaller job than it was, but it is still a job and nothing
depends on it booting.

## Audio: what remains is configuration

The HAL is AOSP's `android.hardware.audio.service-aidl.example` from
`hardware/interfaces/audio/aidl/default`, which has both an `alsa/` backend and a
`primary/` module. On a mainline kernel the HDMI audio path is `simple-audio-card`
wiring i2s2 to the HDMI bridge's codec, so this is ALSA all the way down and what is
left is the card and device numbers in `audio/audio_policy_configuration.xml` and
`audio/mixer_paths.xml`.

Two constraints from the legacy HAL still hold, because they are properties of the
hardware rather than of the old code: PCM 16-bit, up to 8 channels with 8ch@192kHz
special-cased, and passthrough only as IEC61937-framed PCM rather than a compressed
format. Declaring AC3/E-AC3/DTS in the policy before something can produce them
gives silence, not a fallback — that was in this tree once and was corrected by
reading the legacy HAL rather than the legacy policy.

One structural trap in that file: every `xi:include` has to resolve on the device, or
the parse fails and takes the whole policy with it, not just the section that could
not be found. Each `href` must be a file this tree installs or an AOSP module
`device.mk` asks for, **under the name that module installs** —
`bluetooth_audio_policy_configuration.xml` was included here while AOSP's file is
`..._7_0.xml`, and it only resolved because a `PRODUCT_COPY_FILES` line renamed it on
the way in. `verify-tree.sh` check 9c enforces it.

## Two shims that were deleted, and why that is the lesson

`shims/audio` and `shims/graphics/allocator` both existed to bridge AIDL down to the
Rockchip Android 10 HALs, and those left the tree with `hardware/rockchip`. A bridge
to code that is no longer synced cannot work — but the audio one had gone from
useless to harmful, because Soong analyses a module whether or not anything installs
it:

```
depends on multiple versions of the same aidl_interface:
android.media.audio.common.types-V2-ndk-source, ...-V3-ndk-source
```

It pinned V2 while the AOSP implementation it linked pulls V3 in through
`android.hardware.bluetooth.audio-V4-ndk`. Bumping the version would have kept a
file whose whole purpose had gone.

The lesson stands for any board HAL code that follows: **confirm the frozen AIDL
version before naming one.** Run `build/verify-aidl-surface.sh` against a synced
tree; it prints the real method list for every interface this board's HALs speak and
the frozen version of each, which is the number a `-V<n>-ndk` dependency has to
name. AIDL signatures moved between Android 13, 14 and the 14 QPRs, and a module
written from memory compiles against nothing.
