# Khadas Edge1 (RK3399) — Android TV 14

A port of the Khadas Edge1 from its Android 10 (`khadas-edge-Qt`) configuration to
Android TV 14, on a mainline kernel and with no proprietary blobs.

**The build completes**, and produces a card image built to boot on this board as it
is. Android has not booted yet: five earlier cards all came up in the Armbian installed
on the eMMC — four because the RK3399 BootROM tries the **eMMC before the SD card** and so
never ran the card's bootloader, the fifth because the boot script that works around that
used `setexpr`, which Armbian's U-Boot 2022.07 does not have. The script now uses only
what 2022.07 has (checked at build time, and run on a 2022.07 sandbox), and the three
things that would have stopped first-stage init once it got there are fixed.
[`docs/HANDOFF.md`](docs/HANDOFF.md) is the working loop and where it stands,
[`docs/STATUS.md`](docs/STATUS.md) has the state, [`docs/BOOT.md`](docs/BOOT.md) the boot
path, [`docs/HARDWARE.md`](docs/HARDWARE.md) what was measured on the real board.

**How the card boots.** Partition 1 of every image is `bootfs`, a FAT holding a
`boot.scr` and the kernel, ramdisk and dtb out of `boot.img`. The U-Boot already on the
eMMC — Armbian's here — scans the card first and runs it, and the script loads those
three and starts the kernel, telling Android which controller it booted from. It leaves
`edge1-boot.log` on that partition, readable on any PC. Nothing on the eMMC is written;
pull the card and the board is as it was. The card also carries our own mainline U-Boot, which
runs from an empty eMMC, in Khadas's TST mode (FUNCTION pressed three times within two
seconds) or, later, from SPI NOR.

**Three media, one layout.**

| | Bootloader | How it is written |
|---|---|---|
| `edge1-sdcard.img` | ours at sector 64, plus `bootfs` for the eMMC's | Balena Etcher, from the desktop |
| `edge1-emmc.img` | ours at sector 64, plus `bootfs` | from the card, by `edge1-install-internal.sh` — which keeps the eMMC's working bootloader unless ours has been seen to run |
| `edge1-nvme.img` | none possible, `bootfs` only | from the card, by `edge1-install-internal.sh` |

The NVMe never holds the bootloader: the RK3399 BootROM can start from NAND, eMMC, SPI or
SD, but not from PCIe. An SSD install keeps U-Boot on the eMMC or the card and puts only
Android's partitions on the SSD.

## The shape of the port

**No Rockchip vendor code.** The port originally targeted Khadas' 4.19.111 BSP and
its Android 10 HALs. It now builds against mainline Linux 6.12 LTS, because AOSP 14
already ships the userspace for the mainline drivers and forward-porting the
Rockchip HIDL stack meant re-writing all of it:

| | driver | userspace, from AOSP 14 |
|---|---|---|
| GPU | `drivers/gpu/drm/panfrost` | `external/mesa3d` → `libGLES_mesa` |
| Display | `drivers/gpu/drm/rockchip` | `external/drm_hwcomposer` + minigbm |
| Decode | `drivers/staging/media/rkvdec` | `external/v4l2_codec2` (not wired up yet) |
| Wi-Fi | `brcmfmac` over SDIO | AOSP `wpa_supplicant` |
| Bluetooth | `hci_bcm` over uart0 | AOSP AIDL Bluetooth HAL |
| Audio | `simple-audio-card` → HDMI codec | AOSP AIDL audio HAL over ALSA |

Nothing in `hardware/rockchip` or `vendor/rockchip` is used, and the manifest no
longer syncs them. [`docs/KERNEL.md`](docs/KERNEL.md) covers the kernel side of that
decision, [`docs/HAL_MIGRATION.md`](docs/HAL_MIGRATION.md) the HAL side.

**Product.** The Edge1 was `rk3399_all` in `device/rockchip/rk3399`, sharing
Rockchip's tablet configuration. It becomes `edge1_tv` in `device/khadas/edge`,
inheriting `device/google/atv` for leanback, at tvdpi, with the absent sensors and
camera declared unavailable so the framework does not wait on HALs that never
publish.

**Kernel.** `v6.12.111`, the newest 6.12 LTS point release, built from source with
every driver the board needs compiled in — there is no `vendor_dlkm` and nothing is
loaded at first stage. `PRODUCT_SHIPPING_API_LEVEL` is 29, not 34: declaring 34
would assert launch-device status and demand a 5.15 kernel and 64-bit-only
userspace.

**Partitions.** A 512MiB `bootfs` first (a boot script, and the kernel, ramdisk and dtb
as files, for a distro U-Boot), then one
96MiB `boot` carrying kernel, ramdisk and dtb together (boot image header v2, no
`vendor_boot`), a 96MiB `recovery`, and a 4608MiB `super` holding
system/system_ext/product/vendor/odm as logical partitions, plus `misc`, `vbmeta`,
`metadata` and `userdata`. Non-A/B. The layout is
[`device/khadas/edge/flash/partitions.tsv`](device/khadas/edge/flash/partitions.tsv),
and it is the single source for all three images, the eMMC flash script and the
on-device installer — not a Rockchip `update.img`, which needs the BSP bootloader this
path does not use.

**Bootloader.** Mainline U-Boot at `v2026.07`, `khadas-edge-v-rk3399_defconfig` plus
Android boot image support, an HDMI console and a compiled-in environment, with `BL31`
from `rkbin`. It sits in the raw sectors ahead of the first partition, and tries the
card, then the eMMC, then the NVMe, then distro boot. Or the eMMC's own U-Boot boots the
card through `bootfs` — on a board whose eMMC is not empty, that is what actually runs.

**Kernel command line.** `androidboot.boot_devices` comes from whichever bootloader runs,
per medium (`fe320000.mmc` card, `fe330000.mmc` eMMC); `boot.img` carries
`androidboot.verifiedbootstate=orange`, since no bootloader here supplies a vbmeta
digest. A userdebug build adds the kernel log on HDMI, a panic instead of a silent reboot
on an init failure, and permissive SELinux — this board is being brought up without a
serial adapter.

## What is here

| | |
|---|---|
| [`manifests/khadas_edge_tv14.xml`](manifests/khadas_edge_tv14.xml) | `repo` local-manifest overlay: upstream AOSP 14, the mainline kernel and U-Boot |
| [`device/khadas/edge/`](device/khadas/edge) | the device tree — TV product, board config, VINTF, fstab, init, SELinux, audio/media/input config, kernel delta, flash layout and boot script, Wi-Fi firmware |
| [`build/`](build) | preflight, sync, kernel/U-Boot/platform builds, the image builder, the verifiers |
| [`build/windows/`](build/windows) | the WSL2 orchestrator this is actually driven from |
| [`build/reference/`](build/reference) | a U-Boot built elsewhere for this board, for comparison |
| [`docs/`](docs) | see below |
| `default.xml` | the original Android 10 manifest, untouched for reference |

| Document | |
|---|---|
| [`docs/BOOT.md`](docs/BOOT.md) | power-on to first-stage init: BootROM order, both boot paths, what the kernel needs, TST mode, installing |
| [`docs/STATUS.md`](docs/STATUS.md) | where it is, what is open, and the build-system decisions worth not re-deriving |
| [`docs/HARDWARE.md`](docs/HARDWARE.md) | what was measured on the real board |
| [`docs/PORTING.md`](docs/PORTING.md) | the runbook, step by step, on Linux |
| [`docs/WINDOWS.md`](docs/WINDOWS.md) | the same, driven from Windows through WSL2 |
| [`docs/KERNEL.md`](docs/KERNEL.md), [`docs/HAL_MIGRATION.md`](docs/HAL_MIGRATION.md) | why mainline, and what replaced each Android 10 HAL |
| [`docs/HW_DECODE.md`](docs/HW_DECODE.md) | hardware video decoding: what the mainline decoders do and the plan to reach them from Android |
| [`docs/RELEASE.md`](docs/RELEASE.md) | from this bring-up image to a release build: what is done, what is left, in order |

## Running it

On a Windows host — which is how this tree is built — see
[`docs/WINDOWS.md`](docs/WINDOWS.md):

```powershell
cd D:\android_khadas
powershell -ExecutionPolicy Bypass -File .\android_manifest\build\windows\Start-EdgeBuild.ps1
```

Directly on a Linux host:

```sh
build/verify-tree.sh       # static check, needs no AOSP tree
build/preflight.sh         # disk, RAM, cores, toolchain, git access
build/sync.sh              # AOSP 14 + the mainline kernel
build/build-kernel.sh      # 6.12.111 + the Android 14 config delta
build/build-uboot.sh       # mainline U-Boot, Android boot support
build/build.sh userdebug
build/build-images.sh      # the three whole-disk images
```

Each takes the tree as an optional first argument and otherwise finds it:
`~/android_khadas/aosp-14-edge1`, which is where the Windows pipeline puts it, then
`~/aosp-14-edge1` for a tree laid out by hand (`build/lib-tree.sh`). Naming the wrong
one presents as `run sync.sh first` on a tree that is fully synced and built, which is
why it is resolved rather than assumed.

Write `out/.../edge1-sdcard.img.gz` (or `~/android_khadas/output/` on the Windows
pipeline) with Etcher, insert it, power on. Then, once the card boots, to move it onto
internal storage:

```sh
adb root && adb shell sh /vendor/bin/edge1-install-internal.sh emmc   # or nvme
```

The kernel has to be built before `m`: both the `Image` and the dtb are read at
Kati parse time. Step by step in [`docs/PORTING.md`](docs/PORTING.md).

## Known limitations

* **Hardware video decode is not wired up.** `rkvdec` is in the kernel and
  `external/v4l2_codec2` is in the tree, but no Codec2 service is installed, so the
  software codecs carry playback — 1080p rather than 4K.
* **Bluetooth works; Wi-Fi scans but had not yet associated** (card 17; the firmware
  handshake offload is off from card 18). The kernel drivers load their firmware from
  the ramdisk; Wi-Fi runs without a vendor HAL, Bluetooth through the kernel's
  `hci_bcm` and AOSP's HAL. Bluetooth audio (A2DP) is not there yet.
* **Verified boot is `orange` and SELinux is permissive on userdebug.** No bootloader
  in the chain computes a vbmeta digest yet (`avb verify` in U-Boot is the fix), and the
  first boot of a new port is not the moment to enforce policy that has never met a
  running system.
* **Our own U-Boot has not run on this board.** The card boots through the eMMC's U-Boot;
  ours is to be tested in TST mode before it goes onto the eMMC or into SPI NOR.
* **Not CTS-certifiable.** No TEE is provisioned, so KeyMint and Gatekeeper are the
  software `nonsecure` implementations and hardware key attestation is unavailable.
  Widevine is absent entirely; DRM is clearkey only.
* Codec performance numbers in `media/media_codecs_performance.xml` are datasheet
  ceilings, not measurements.

The honest test of the first image is whether it boots to a leanback launcher on
HDMI with a working remote and network. Everything after that is configuration.
