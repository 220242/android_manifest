# Measured facts about this board

Everything here was read off the **real** Khadas Edge-V, not inferred from a datasheet
or a device tree. Source: the board running Armbian with kernel
`6.12.47-current-rockchip64`, 2026-09-28, while bringing up the first SD card.

It exists because most of these were assumptions in this tree, and several were wrong.
Each row says what it confirms or corrects. How the board boots is in
[`BOOT.md`](BOOT.md); this file keeps the measurements it rests on.

## Identity and memory

| | Measured | Bearing on the tree |
|---|---|---|
| model | `Khadas Edge-V` | — |
| compatible | `khadas,edge-v`, `rockchip,rk3399` | confirms `TARGET_KERNEL_DTS := rk3399-khadas-edge-v` |
| RAM | `MemTotal: 3945072 kB` → a 4GB board | confirms what `edge1_tv.mk` sizes for; the Edge also ships in 2GB |
| kernel in use | `6.12.47-current-rockchip64` | we build `6.12.111` — same series |

## Boot order: SPI NOR, then eMMC, then SD card

Measured with `build/rk-idb-check.py`, which decrypts the RC4-scrambled Rockchip ID
block before checking it (a valid block looks like noise in a hexdump):

| Where | Sector | Result |
|---|---|---|
| SPI NOR (`mtd0`, `spi1.0`, 16MB) | 0 | **erased, all `0xff` — no bootloader** |
| eMMC (`mmcblk2`) | 64 | valid Rockchip ID block (Armbian's U-Boot 2022.07) |
| SD card (`mmcblk1`) | 64 | valid Rockchip ID block (ours) |

With both valid and SPI empty, the board boots the eMMC:
`/proc/device-tree/chosen/u-boot,version` reads
`2022.07-armbian-2022.07-Se092-P621f-H5921-V2588-Bb703-R448a` with every card this tree
has produced in the slot, including the ones with the SPL order and environment fixes.

That is the RK3399 BootROM's documented order — SPI NOR, SPI NAND, eMMC, SD — and
Khadas's for the Edge. A bootloader on the card runs only if nothing ahead of it is
bootable, or in TST mode (FUNCTION pressed three times within two seconds). The card
still boots Android on this board, but through the eMMC's U-Boot, whose distro boot
scans `mmc1` (the card) before `mmc0` and runs `boot.scr` from the card's partition 1.
[`BOOT.md`](BOOT.md) has the whole mechanism, the sources, and a short account of the
four rounds spent believing the card came first.

### Both ID blocks are valid

Read off both devices with `build/rk-idb-check.py`. The eMMC's is a **known-working**
bootloader, which makes it the reference:

| Field | our card | eMMC (Armbian, works) |
|---|---|---|
| `init_offset` | 4 blocks (2048 B) | 4 blocks (2048 B) |
| `init_size` (TPL) | 136 blocks (69,632 B) | 140 blocks (71,680 B) |
| `init_boot_size` | 376 blocks (192,512 B) | 1164 blocks (595,968 B) |
| ⇒ SPL size | 240 blocks (122,880 B) | 1024 blocks (524,288 B) |

**The header is not the fault.** `init_offset` is identical, the two TPLs are within 2KB
of each other, and ours is internally consistent: 136 + 240 = 376, which is exactly the
TPL and SPL our build produces.

The one difference is explained and benign. 1024 blocks is 512KiB is exactly
`RK_MAX_BOOT_SIZE` (`tools/rkcommon.h:14`), and `rkcommon.c:334-337` uses that as a
placeholder when mkimage is given no separate boot file:

```c
if (spl_params.boot_file)
    init_boot_size = spl_params.init_size + spl_params.boot_size;
else
    init_boot_size = spl_params.init_size + RK_MAX_BOOT_SIZE;
```

So Armbian's 2022.07 built its `idbloader.img` from one concatenated file and got the
placeholder; ours uses binman's `multiple-data-files` (TPL and SPL separately) and gets
the real size. Ours is the more precise of the two.

### A U-Boot config to compare against

The owner's OpenWrt build for this board carries mainline U-Boot **2025.10**,
`khadas-edge-v-rk3399_defconfig` plus four HDMI symbols; its binaries and `.config` are in
[`build/reference/openwrt-u-boot-2025.10/`](../build/reference/openwrt-u-boot-2025.10).
Whether that U-Boot ever ran from a card is now doubtful — the OpenWrt card, too, was
almost certainly started by the eMMC's U-Boot through its `boot.scr` — but as a config
for this exact board it is still the best reference there is.

Against what `build-uboot.sh` produces on v2026.07: the ID block has the same
`init_offset` (4) and `init_size` (136) and differs only in SPL size; the FIT has the same
shape (`u-boot`, `atf-1`..`atf-5`, `fdt-1`, and no `tee` image — so binman's *missing
optional external blobs: tee-os* is normal); and of the config symbols present in both,
fifteen differ — eleven are our Android delta, and four are load addresses v2026.07 moved
(`TEXT_BASE` 0x00200000 → 0x00800000, `SPL_LOAD_FIT_ADDRESS` 0x0 → 0x00200000, with
`SYS_BOOTM_LEN` and `LNX_KRNL_IMG_TEXT_OFFSET_BASE` following). Its `ENV_IS_IN_MMC=y`
with device 0 and its untouched `spl-boot-order` are what showed the environment and SPL
fixes were not what stood in the way.

One detail from reading its FIT: `atf-4` loads over `CFG_IRAM_BASE` (0xff8c0000), so BL31
overwrites the BootROM's boot-source id at `+0x10` before Linux runs. Reading that
address from Linux cannot say which device the BootROM used.

## Storage, by controller address

`mmcblk` numbering is probe order and not stable; the controller address is the board.

| Device | Controller | What it is |
|---|---|---|
| `mmcblk1` | `fe320000.mmc` | the SD card slot (`sdmmc`) |
| `mmcblk2` | `fe330000.mmc` | the eMMC (`sdhci`), 29.1GiB, one partition |
| `mmcblk2boot0`, `boot1` | — | the eMMC's own 4MB boot partitions |
| — | `fe310000` | `sdio0`, the Wi-Fi module |

Confirms `fstab.edge1`'s `/devices/platform/fe320000.mmc/mmc_host*` for vold, the
`genfs_contexts` line for the same path, and `edge1-install-internal.sh` finding the
eMMC by `fe330000.*` rather than by number. The same two names are what
`androidboot.boot_devices` has to carry for first-stage init to find the partitions —
`fe320000.mmc` when booted from the card, `fe330000.mmc` from the eMMC — so this row is
also the measurement behind [`BOOT.md`](BOOT.md#what-the-kernel-has-to-be-told).

## DRM: card0 is the display, card1 is the GPU

```
card0       -> /devices/platform/display-subsystem/drm/card0   + card0-HDMI-A-1
card1       -> /devices/platform/ff9a0000.gpu/drm/card1
renderD128  -> /devices/platform/ff9a0000.gpu/drm/renderD128
```

`panfrost ff9a0000.gpu: mali-t860 id 0x860 major 0x2 minor 0x0`, then
`[drm] Initialized panfrost 1.2.0 for ff9a0000.gpu on minor 1`. So panfrost binds
cleanly on a mainline 6.12 kernel, and the GPU's sysfs path really is
`/devices/platform/ff9a0000.gpu` — which is what our `genfs_contexts` labels
`sysfs_gpu`.

**Open item this raises:** our `file_contexts` labels `/dev/dri/card0` and
`/dev/dri/renderD128` but not `/dev/dri/card1`, and card1 is the GPU's primary node.
AOSP's own `file_contexts` is believed to carry generic `/dev/dri/card[0-9]*` and
`/dev/dri/renderD[0-9]*` specs, which would cover it — but "believed" is not measured,
and an unlabelled render-adjacent node is exactly the kind of thing that fails silently
inside gralloc. The module probe should print AOSP's `/dev/dri` specs so this is settled
rather than assumed.

Note also that the display controller is `display-subsystem`, not `ff940000.hdmi`. Our
`genfs_contexts` labels `ff940000.hdmi` as `sysfs_hdmi`; that is the HDMI encoder node
and plausibly right, but the DRM device itself lives elsewhere.

## Audio: simple-card on HDMI, as assumed

```
 0 [hdmisound      ]: simple-card - hdmi-sound
```

Confirms the whole audio approach: `simple-audio-card` bound to the HDMI codec, no
Rockchip codec HAL. The card is id `hdmisound`, name `hdmi-sound`.

## Our kernel on the board

From the first boot of this tree's kernel (card seven), read out of `edge1-pstore.bin`:

| | Measured | Bearing on the tree |
|---|---|---|
| memory as the kernel sees it | `0x00200000-0xf7ffffff`, from U-Boot's fixup | 4GB board; the first 2MiB is BL31's |
| HDMI | the kernel log on screen through fbcon | Rockchip DRM, dw-hdmi and fbcon work built in |
| SDIO Wi-Fi | `BCM4359/9` on `fe310000.mmc`, SDR104; firmware load -2 at 1.8s | the chip is the one we ship firmware for; built-in brcmfmac asks before `/vendor` exists |
| LSM | `lsm=capability` | SELinux was not in `CONFIG_LSM`; fixed |
| RAM across a warm reset | kept, except one word at `0x30000000` (`0x5aa5f00f`, the DRAM probe's pattern) | ramoops works; the region moved to `0x30100000` |

## Wi-Fi firmware names are exactly ours — and there is a Bluetooth one

`/lib/firmware/brcm/` on the working board:

| File | Bearing |
|---|---|
| `brcmfmac4359-sdio.bin` | **the same name this tree installs** |
| `brcmfmac4359-sdio.txt` | **the same name this tree installs** |
| `BCM4359C0.hcd` | the Bluetooth patchram firmware. **We do not ship this.** |

`wlan0` is up, so brcmfmac works with those files. Two things settled:

* The board-suffixed NVRAM name (`brcmfmac4359-sdio.khadas,edge-v.txt`) that
  `wifi/firmware/brcm/README.md` raised as a possibility is **not** what this board
  uses. The plain `.txt` is. Our naming is correct as it stands.
* Bluetooth needs `BCM4359C0.hcd`, which is a fact we did not have.

## Bluetooth: there is no /dev/ttyS0

```
/dev/ttyS1  /dev/ttyS2  /dev/ttyS3  /dev/ttyS4  /dev/ttyS5  /dev/ttyS6  /dev/ttyS7
```

**`/dev/ttyS0` does not exist** on this board with a mainline 6.12 kernel. Bluetooth
core registers (`Bluetooth: Core ver 2.22`, L2CAP/SCO layers up) but no `hci_bcm` or
`hci_uart` binding appears, so uart0 is not presented as a tty at all.

This **corrects** the open question in `STATUS.md`, which framed it as the kernel's
`hci_bcm` and Android's HAL both wanting `/dev/ttyS0`. They cannot both want it: it is
not there. Whatever the Bluetooth answer turns out to be, it starts from the serdev
node and `BCM4359C0.hcd`, not from a tty.

`/dev/ttyS2` does exist, which confirms `console=ttyS2,1500000n8`.

## Ethernet works, and confirms the config fix

`rk_gmac-dwmac fe300000.ethernet`, interface up with a DHCP lease. This is the pair the
kernel fragment had to force to `y` together — `CONFIG_DWMAC_ROCKCHIP` inside
`if STMMAC_PLATFORM` — so it confirms that fix was the right one.

Benign noise from the same driver, worth recognising rather than chasing:
`IRQ eth_wake_irq not found`, `IRQ eth_lpi not found`, `IRQ sfty not found`,
`Deprecated MDIO bus assumption used`, `PTP uses main clock`.

## Thermal and devfreq

* `/sys/class/thermal/`: `thermal_zone0`, `thermal_zone1`, `cooling_device0..3` — so
  the `sysfs_thermal` label on `/class/thermal` is on something real.
* `/sys/class/devfreq/`: **`ff9a0000.gpu` only.** The GPU has a devfreq; the memory
  controller does not. That confirms both halves of an earlier decision — labelling
  `/class/devfreq` was right, and dropping `ARM_RK3399_DMC_DEVFREQ` and the
  `dmc_ondemand` governor write from `init.edge1.rc` was right, because there is no
  `dmc` devfreq to write to.

## PCIe: the M.2 slot is empty

No `/dev/nvme*`. The host bridge probes:

```
rockchip-pcie f8000000.pcie: host bridge /pcie@f8000000 ranges: ...
phy phy-ff770000.syscon:pcie-phy.1: pll relock timeout!
```

The PLL relock timeout with nothing in the slot is what an empty slot looks like, not a
driver bug — note this kernel is Armbian's, which already carries their
`rk3399-fix-pci-phy.patch`, and the message appears anyway.

So `edge1-nvme.img` and the installer's `nvme` target are **untestable until an SSD is
fitted**. Everything about them is reasoned from the silicon, not observed.

## One benign message to expect

```
GPT:14335999 != 125042687
```

Our card image is 7000MiB and the card is 59.6GB, so the GPT does not span the device
and the kernel says so. Harmless — `EDGE1_SD_SIZE_MIB` is deliberately sized for the
smallest card worth using.
