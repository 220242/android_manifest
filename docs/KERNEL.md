# Kernel: mainline 6.12 LTS on the Khadas Edge1

## Why not the 4.19 BSP

The port started on Khadas' own 4.19.111, which was the obvious choice: every
Rockchip driver the board needs was already in it and known to work under Android
10. It built, too - `Image`, the DTB and five modules.

The problem was never the kernel, it was everything above it. The BSP's value is
its drivers; the Android 10 userspace that talked to those drivers is what would
have had to be forward-ported, piece by piece:

| piece | what porting it meant |
|---|---|
| `libGLES_mali` r18 | the blob talks to the BSP's midgard kmod *and* to gralloc. Android 14 uses Gralloc4/IMapper 5. Bridging that is the single largest unknown in the whole port. |
| `libgralloc_rk3399` | build against the 14 VNDK, against an IMapper it was never written for |
| `librockchip_mpp`, `libcodec2_rk` | a Codec2 store for Android 14 |
| `hwcomposer` | HWC2 against a composer3 world |

Mainline inverts the trade. The drivers are upstream, and AOSP already ships the
userspace for them:

| | driver | userspace, already in AOSP 14 |
|---|---|---|
| GPU | `drivers/gpu/drm/panfrost` | `external/mesa3d`, `libmesa_pipe_panfrost` → `libGLES_mesa` |
| Display | `drivers/gpu/drm/rockchip` | `external/drm_hwcomposer` + minigbm |
| Decode | `drivers/staging/media/rkvdec` | `external/v4l2_codec2` |
| Wi-Fi | `brcmfmac` over SDIO | AOSP `wpa_supplicant` |
| Audio | `simple-audio-card` → HDMI codec | AOSP AIDL audio HAL over ALSA |

Not one proprietary blob is required, and nothing in `hardware/rockchip` or
`vendor/rockchip` is used - which is why the manifest no longer syncs them.

The decisive detail: **AOSP 14 has no software GLES driver a real device can
load.** `libGLES_android` was removed years ago and swiftshader is packaged for
the emulator's host side - the tree defines no `libEGL_swiftshader`. Without a
driver, SurfaceFlinger does not start. So "boot on software rendering and sort the
GPU out later" was never available, and the GPU question had to be answered before
first boot either way. panfrost answers it without a blob.

## What is pinned, and why that version

`v6.12.111`, the newest point release of the 6.12 LTS series, from
`github.com/gregkh/linux` with `clone-depth="1"` - the full history is about 5 GiB
and nothing here needs it.

The series is not arbitrary. This board already runs 6.12 in its owner's OpenWrt
build (`github.com/220242/khadas_edge-openwrt`, Linux 6.12.94, mainline U-Boot +
TF-A), so HDMI, eMMC, Ethernet and Wi-Fi are known good on this kernel before
Android is added on top. That build is also where the Wi-Fi firmware and the board
NVRAM in `device/khadas/edge/wifi/firmware/brcm` come from.

Board DTS: `arch/arm64/boot/dts/rockchip/rk3399-khadas-edge-v.dts`.

All three Khadas Edge boards share `rk3399-khadas-edge.dtsi`, which is where
everything this port depends on lives: `&gpu` (panfrost), `&hdmi` with
`&hdmi_sound`, the `wifi@1` SDIO node with its power sequence, eMMC and USB. The
per-board files only add what that carrier wires up, and the plain `edge` one adds
nothing - thirteen lines, a model name and a compatible string:

| dts | adds |
|---|---|
| `rk3399-khadas-edge.dts` | nothing: no Ethernet, no PCIe |
| `rk3399-khadas-edge-v.dts` | `&gmac`, and `&pcie0` with four lanes |
| `rk3399-khadas-edge-captain.dts` | its own carrier's set |

So "Edge1 and Edge-V are the same board" is right about the hardware that matters
here and wrong in one expensive way: building the plain `edge` dtb would produce a
device with no Ethernet and no M.2 slot. `EDGE1_DTB` defaults to the Edge-V dtb,
which is also the one this board is known to run - the owner's OpenWrt build
targets `khadas_edge-v` and exists to route Ethernet.

## The config

`arch/arm64/configs/defconfig` plus `device/khadas/edge/kernel/edge1_mainline.config`,
merged by `scripts/kconfig/merge_config.sh`. All 121 symbols in the fragment were
checked to exist in v6.12.111's Kconfig files, and the module probe re-checks them
against the synced tree on every run - on the 4.19 BSP three rounds were spent on
symbols that simply did not exist, because `merge_config.sh` mentions those in
passing and carries on.

Two things about the fragment are worth knowing:

**Everything is built in, nothing is a module.** arm64 `defconfig` builds DRM,
panfrost and brcmfmac as modules. This layout has no `vendor_dlkm` and loads
nothing in first-stage init, so a module here is a driver that does not exist.

**Bluetooth has no transport.** `CONFIG_BT` is on, `BT_HCIUART_BCM` is not. uart0
carries the BCM4359 and the DTS has a `brcm,bcm43438-bt` node, so the kernel driver
would claim the port and do the firmware patch itself - while Android's Bluetooth
HAL expects to open the tty and patch it from userspace. Leaving the transport out
keeps `/dev/ttyS0` free until that is decided. See `STATUS.md`.

## Toolchain

The distro cross GCC, `aarch64-linux-gnu-` from Ubuntu's
`gcc-aarch64-linux-gnu`. `KERNEL_USE_CLANG=1` switches to AOSP's clang with
`LLVM=1`.

Everything the 4.19 build needed here is gone, because none of it exists upstream:
the bypass for `scripts/gcc-wrapper.py` (which failed the build on any compiler
warning from a file not in its allowlist), `HOSTCFLAGS=-fcommon` for
`scripts/dtc`'s `yylloc`, a probed list of `-Wno-` flags for 2019-vintage code, and
Rockchip's `resource.img` container. 6.12 compiles clean with a current toolchain.

## How the kernel reaches the image

Two files, both read by Kati at parse time, which is why the kernel is built
before `m`:

- `Image` → `$(PRODUCT_OUT)/kernel`, via `PRODUCT_COPY_FILES` in `device.mk`.
  AOSP 14 has no `TARGET_PREBUILT_KERNEL`: the string `PREBUILT_KERNEL` appears
  nowhere in `build/make`. `core/Makefile:1018` defines `INSTALLED_KERNEL_TARGET`
  as that path and leaves producing it to the device.
- the board dtb → `dtb.img` inside `boot.img` (header v2), via
  `BOARD_INCLUDE_DTB_IN_BOOTIMG` and `BOARD_PREBUILT_DTBIMAGE_DIR`. That variable
  is globbed for `*.dtb` and everything found is concatenated, so it points at a
  directory `build-kernel.sh` stages with exactly one dtb - not at the kernel's
  own dts output, which holds about ninety.

## The command line

`BOARD_KERNEL_CMDLINE` in `BoardConfig.mk` goes into `boot.img`'s header:
`console=ttyS2,1500000n8`, `androidboot.hardware=edge1`, `firmware_class.path`, and
`androidboot.verifiedbootstate=orange`, without which the `avb` mounts in the fstab refuse
to proceed with no vbmeta digest from the bootloader. A userdebug build adds
`console=tty0` — the kernel log on HDMI through fbcon, which the fragment states
explicitly (`CONFIG_VT`, `CONFIG_VT_CONSOLE`, `CONFIG_FRAMEBUFFER_CONSOLE`) rather than
trusting to defaults — plus `androidboot.init_fatal_panic=true` and
`androidboot.selinux=permissive`.

What `boot.img` must **not** carry is `androidboot.boot_devices`: it names the storage
controller the system booted from, differs per medium, and is added by whichever
bootloader starts the kernel. [`BOOT.md`](BOOT.md#what-the-kernel-has-to-be-told) has the
AOSP source lines behind both arguments.

A change to `kernel/edge1_mainline.config` re-runs both the `Kernel` and the `Build`
stage; before that was tracked, a fragment change re-packed the old `Image`.
