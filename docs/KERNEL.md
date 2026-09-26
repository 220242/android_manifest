# Kernel: 4.19.111 on Android 14

## Why this is viable

The Khadas Edge1 kernel (`khadas/linux`, branch `khadas-edge-Qt`, pinned at
`a82a1a9`) is **4.19.111**, verified from its `Makefile`:

```
VERSION = 4
PATCHLEVEL = 19
SUBLEVEL = 111
```

Board support is present: `arch/arm64/configs/kedge_defconfig`, and
`arch/arm64/boot/dts/rockchip/rk3399-khadas-edge-android.dts` with
`rk3399-khadas-edge.dtsi`. The GPU driver is `drivers/gpu/arm/midgard`, correct
for Mali-T860.

4.19 is the minimum kernel an Android 14 **upgrade** device may ship. Launch
devices need 5.15. This is why `edge1_tv.mk` sets
`PRODUCT_SHIPPING_API_LEVEL := 29` rather than 34: declaring 34 would assert
launch-device status and make VTS demand a 5.15 kernel, 64-bit-only userspace and
the 14 GKI ABI, none of which this board can offer. Declaring 29 keeps the
upgrade rules, under which 4.19 and 32-bit vendor code are both legal.

No kernel rebase is required. That is the single biggest reason this port is
tractable.

## What the config delta covers

`device/khadas/edge/kernel/edge1_android14.config`, merged onto
`kedge_defconfig`. Grouped by the Android release that introduced the
requirement, because the Android 10 defconfig predates all of them:

| Group | Why | Introduced |
|---|---|---|
| `ANDROID_BINDERFS` | init creates binder nodes via binderfs, not `ANDROID_BINDER_DEVICES`. Without it every AIDL HAL fails to register. | 11 |
| eBPF (`BPF_SYSCALL`, `CGROUP_BPF`, `NET_CLS_BPF`, …) | netd's accounting, per-UID firewall and data saver are eBPF programs. netd aborts on boot without them. | 13 |
| `PSI` + drop `ANDROID_LOW_MEMORY_KILLER` | lmkd moved to pressure stall info; the in-kernel LMK driver was removed from the platform and fights lmkd if left on. | 11 |
| `USERFAULTFD` | Android 14's default ART collector is the userfaultfd compacting GC. | 14 |
| `DM_BOW`, `DM_SNAPSHOT`, dynamic partitions | super/logical partitions and checkpointed updates. | 11 |
| Drop `SDCARD_FS` | sdcardfs was replaced by FUSE. The legacy product set `ro.sys.sdcardfs=true`; this tree does not. | 11 |
| `UCLAMP_TASK*` | Android 14 task profiles express priority through uclamp. | 12 |
| `MEDIA_CEC_SUPPORT`, `DRM_DW_HDMI_CEC` | `/dev/cec0` for the HDMI-CEC AIDL HAL — a TV device requirement. | — |

`build/build-kernel.sh` merges the fragment with `merge_config.sh`, then
re-reads `.config` and reports every symbol that did **not** take. Do not ignore
that list: a symbol silently dropping out is how a 4.19 kernel produces an image
that builds and then hangs at boot.

## Known gaps on 4.19

### fscrypt v2 is unavailable, so the fstab pins v1

fscrypt v2 policies landed in mainline 5.4. They exist on 4.19 only via the ACK
`android-4.19-stable` backports, which the Khadas branch does not carry.
`fstab.edge1` therefore specifies:

```
fileencryption=aes-256-xts:aes-256-cts:v1
```

Legal here only because `PRODUCT_SHIPPING_API_LEVEL` is 29 — a launch device
must use v2. To move to v2, rebase onto `android-4.19-stable` (or 5.10) and pick
up the fscrypt and inline-crypt backports, then change the fstab and re-run VTS.

### Metadata encryption is off

`dm-default-key` does not exist in this kernel, so no `keydirectory=` is set.
`/metadata` is present and mounted (dynamic partitions need it), but it is not
itself encrypted.

### `DEBUG_INFO_BTF` may not build

The fragment enables it for eBPF CO-RE. On 4.19 with AOSP clang, `pahole` may be
too old to emit BTF; if the build fails there, drop `CONFIG_DEBUG_INFO_BTF` — the
eBPF programs Android ships are compiled against the kernel's own headers and do
not require CO-RE.

### Not GKI

This is a vendor kernel, not a GKI image with vendor modules. `gki_defconfig`
exists in the tree but `kedge_defconfig` is the board config and is monolithic.
No `vendor_dlkm` partition is configured. That is consistent with an upgrade
device and with the non-A/B layout, but it means no kernel updates independent of
the vendor image.

## Toolchain

The Android 10 BSP built this kernel with GCC 6.3. `build-kernel.sh` uses AOSP's
clang instead, since the platform no longer ships a GCC prebuilt and 4.19 builds
cleanly with clang. The clang path in that script is pinned
(`clang-r487747c`) and must be updated to whatever the synced tree actually
contains.
