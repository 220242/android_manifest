# Khadas Edge1 (RK3399) — Android TV 14

A port of the Khadas Edge1 from its Android 10 (`khadas-edge-Qt`) configuration to
Android TV 14, on a mainline kernel and with no proprietary blobs.

**The build completes** and produces every image the flash layout names, `super.img`
included and in raw rather than sparse form, so it can actually be written. The last
stage assembles those into three whole-disk images — one per medium — and has not yet
run to the end: the bootloader it needs has still to build. Nothing has been booted, so
nothing here is claimed to work. [`docs/STATUS.md`](docs/STATUS.md) has the state in
detail.

**Three media, one layout.**

| | Bootloader | How it is written |
|---|---|---|
| `edge1-sdcard.img` | sector 64 | Balena Etcher, from the desktop |
| `edge1-emmc.img` | sector 64 | from the card, by `edge1-install-internal.sh` |
| `edge1-nvme.img` | none possible | from the card, by `edge1-install-internal.sh` |

The card is the install, and it stays the escape hatch. It carries its own mainline
U-Boot, and that U-Boot tries the **card, then the eMMC, then the NVMe** — so a card
with an Android boot partition always wins, and pulling it out puts the board back on
whatever is on internal storage. The first attempt is reversible and so is every one
after it.

The NVMe never holds the bootloader: the RK3399 BootROM can start from NAND, eMMC, SPI
or SD, but not from PCIe. An SSD install keeps U-Boot on the eMMC or the card and puts
only Android's partitions on the SSD.

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

**Partitions.** One 96MiB `boot` carrying kernel, ramdisk and dtb together (boot
image header v2, no `vendor_boot`), a 96MiB `recovery`, and a 4608MiB `super`
holding system/system_ext/product/vendor/odm as logical partitions, plus `misc`,
`vbmeta`, `metadata` and `userdata`. Non-A/B. The layout is
[`device/khadas/edge/flash/partitions.tsv`](device/khadas/edge/flash/partitions.tsv),
and it is the single source for all three images, the eMMC flash script and the
on-device installer — not a Rockchip `update.img`, which needs the BSP bootloader this
path does not use.

**Bootloader.** Mainline U-Boot at `v2026.07`, `khadas-edge-v-rk3399_defconfig` plus
Android boot image support, with `BL31` from `rkbin`. It sits in the card's raw
sectors ahead of the first partition.

## What is here

| | |
|---|---|
| [`manifests/khadas_edge_tv14.xml`](manifests/khadas_edge_tv14.xml) | `repo` local-manifest overlay: upstream AOSP 14 plus the mainline kernel |
| [`device/khadas/edge/`](device/khadas/edge) | the device tree — TV product, board config, VINTF, fstab, init, SELinux, audio/media/input config, kernel delta, flash layout, Wi-Fi firmware |
| [`build/`](build) | preflight, sync, kernel build, platform build, and the verifiers |
| [`build/windows/`](build/windows) | the WSL2 orchestrator this is actually driven from |
| [`docs/`](docs) | status, kernel, HAL migration, the end-to-end runbook, the Windows host notes |
| `default.xml` | the original Android 10 manifest, untouched for reference |

## Running it

On a Windows host — which is how this tree is built — see
[`docs/WINDOWS.md`](docs/WINDOWS.md):

```powershell
cd D:\android_khadas
powershell -ExecutionPolicy Bypass -File .\android_manifest\build\windows\Start-EdgeBuild.ps1
```

Directly on a Linux host:

```sh
build/verify-tree.sh                        # static check, needs no AOSP tree
build/preflight.sh    ~/aosp-14-edge1       # disk, RAM, cores, toolchain, git access
build/sync.sh         ~/aosp-14-edge1       # AOSP 14 + the mainline kernel
build/build-kernel.sh  ~/aosp-14-edge1      # 6.12.111 + the Android 14 config delta
build/build-uboot.sh   ~/aosp-14-edge1      # mainline U-Boot, Android boot support
build/build.sh         ~/aosp-14-edge1 userdebug
build/build-images.sh  ~/aosp-14-edge1      # the three whole-disk images
```

Then, once the card boots, to move it onto internal storage:

```sh
adb root && adb shell sh /vendor/bin/edge1-install-internal.sh emmc   # or nvme
```

The kernel has to be built before `m`: both the `Image` and the dtb are read at
Kati parse time. Step by step in [`docs/PORTING.md`](docs/PORTING.md).

## Known limitations

* **Hardware video decode is not wired up.** `rkvdec` is in the kernel and
  `external/v4l2_codec2` is in the tree, but no Codec2 service is installed, so the
  software codecs carry playback — 1080p rather than 4K.
* **Bluetooth is unresolved.** The kernel's `hci_bcm` and Android's Bluetooth HAL
  both want to own `/dev/ttyS0`. The kernel transport is left out of the config so
  the port stays free until that is decided.
* **Not CTS-certifiable.** No TEE is provisioned, so KeyMint and Gatekeeper are the
  software `nonsecure` implementations and hardware key attestation is unavailable.
  Widevine is absent entirely; DRM is clearkey only.
* Codec performance numbers in `media/media_codecs_performance.xml` are datasheet
  ceilings, not measurements.

The honest test of the first image is whether it boots to a leanback launcher on
HDMI with a working remote and network. Everything after that is configuration.
