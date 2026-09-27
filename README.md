# Khadas Edge1 (RK3399) — Android TV 14

A port of the Khadas Edge1 from its Android 10 (`khadas-edge-Qt`) configuration
to Android TV 14.

**Read [`docs/STATUS.md`](docs/STATUS.md) first.** The port is written and
statically verified, but it has not been compiled: the environment it was
authored in cannot reach `android.googlesource.com` (HTTP 403 from the network
policy) and has 30GiB of disk against the ~270GiB a build needs. `STATUS.md`
lists the measured blockers and exactly what remains before the image boots.

## What is here

| | |
|---|---|
| [`manifests/khadas_edge_tv14.xml`](manifests/khadas_edge_tv14.xml) | repo local-manifest overlay: upstream AOSP 14 + the ~15 Khadas/Rockchip projects that hold board support |
| [`device/khadas/edge/`](device/khadas/edge) | the device tree — TV product, board config, VINTF, fstab, init, SELinux, audio/media/input config, kernel delta, HAL shims |
| [`build/`](build) | preflight, sync, kernel build, platform build + `update.img`, and two verifiers |
| [`docs/`](docs) | status, HAL migration matrix, kernel notes, how to run it (incl. [Windows/WSL2](docs/WINDOWS.md)) |
| `default.xml` | the original Android 10 manifest, untouched for reference |

## Quick start

```sh
build/preflight.sh  ~/aosp-14-edge1     # host check: disk, RAM, cores, git access
build/verify-tree.sh                    # static check, needs no AOSP tree
build/sync.sh       ~/aosp-14-edge1     # AOSP 14 + Khadas overlay
build/build-kernel.sh ~/aosp-14-edge1   # 4.19.111 + Android 14 config delta
build/build.sh      ~/aosp-14-edge1 userdebug
```

Full detail in [`docs/PORTING.md`](docs/PORTING.md).

## The shape of the port

**Product.** The Edge1 was product `rk3399_all` in `device/rockchip/rk3399`,
sharing Rockchip's tablet config (`TARGET_BOARD_PLATFORM_PRODUCT := tablet`,
hdpi-preferred, sensors and camera enabled). It becomes `edge1_tv` in
`device/khadas/edge`, inheriting `device/google/atv` for leanback, at tvdpi, with
the absent sensors and camera declared unavailable so the framework does not wait
on HALs that never publish.

The Android 10 tree's `device/rockchip/common/tv/tv_base.mk` is **not** reused —
it still lists `libstagefright_soft_*`, `PicoTts`, `Browser` and
`DefaultContainerService`, none of which survive past Android 9.

**HALs.** Of 24 legacy HIDL interfaces: 7 are deleted (absent hardware or removed
from the platform), 11 are satisfied by AOSP's own AIDL implementations with no
vendor code, and 6 need board-specific work. Notably Wi-Fi and Bluetooth need no
vendor HAL at all — AOSP's nl80211 and H4 services cover the AP6398S once the
firmware paths and patchram are wired up. Matrix and rationale in
[`docs/HAL_MIGRATION.md`](docs/HAL_MIGRATION.md).

**Kernel.** 4.19.111, which is exactly Android 14's minimum for an *upgrade*
device, so no rebase is needed. `PRODUCT_SHIPPING_API_LEVEL` is deliberately 29,
not 34: declaring 34 would assert launch-device status and demand a 5.15 kernel
and 64-bit-only userspace. [`docs/KERNEL.md`](docs/KERNEL.md).

**Partitions.** Fixed Android 10 partitions become a 4608MiB `super` holding
system/system_ext/product/vendor/odm as logical partitions, plus `metadata`,
`misc`, `vbmeta` and one 96MiB `boot` that carries the kernel, the ramdisk and the
dtb together - boot image header v2, no `vendor_boot`. Non-A/B, written as an
ordinary GPT by the generated `flash-emmc.sh`, not as a Rockchip `update.img`. The
layout is `device/khadas/edge/flash/partitions.tsv`.

## Known limitations

* **Not CTS-certifiable.** No TEE is provisioned, so KeyMint and Gatekeeper are
  the software `nonsecure` implementations and hardware key attestation is
  unavailable. Widevine is L3.
* **Incomplete HALs are gated off** behind `EDGE1_ENABLE_INCOMPLETE_HALS` so the
  tree builds to completion on AOSP fallbacks. `composer3` (display) and
  `audio.core` stream I/O are the two that must be finished before the device is
  usable.
* Codec performance numbers in `media/media_codecs_performance.xml` are datasheet
  ceilings, not measurements.
