# Measured facts about this board

Everything here was read off the **real** Khadas Edge-V, not inferred from a datasheet
or a device tree. Source: the board running Armbian with kernel
`6.12.47-current-rockchip64`, 2026-09-28, while bringing up the first SD card.

It exists because most of these were assumptions in this tree, and three of them were
wrong. Each row says what it confirms or corrects.

## Identity and memory

| | Measured | Bearing on the tree |
|---|---|---|
| model | `Khadas Edge-V` | — |
| compatible | `khadas,edge-v`, `rockchip,rk3399` | confirms `TARGET_KERNEL_DTS := rk3399-khadas-edge-v` |
| RAM | `MemTotal: 3945072 kB` → a 4GB board | confirms what `edge1_tv.mk` sizes for; the Edge also ships in 2GB |
| kernel in use | `6.12.47-current-rockchip64` | we build `6.12.111` — same series |

## The boot order, and a conclusion that was wrong

Measured with `build/rk-idb-check.py`:

| Where | Sector | Result |
|---|---|---|
| SPI NOR (`mtd0`, `spi1.0`, 16MB) | 0 | **erased, all `0xff` — no bootloader** |
| eMMC (`mmcblk2`) | 64 | valid Rockchip ID block |
| SD card (`mmcblk1`) | 64 | valid Rockchip ID block |

With a valid bootloader on both the eMMC and the card, and SPI empty, the board boots
the eMMC: `/proc/device-tree/chosen/u-boot,version` reads `2022.07-armbian-...`, which
is Armbian's, not the `2026.07` this tree builds.

**I first read that as "the BootROM prefers the eMMC to the SD card". That was wrong,
and the counter-evidence is stronger than the inference:** on this same board, an
OpenWrt SD card always won over the eMMC — it never reached Armbian. So the BootROM
*does* read the card first.

Which relocates the fault entirely, and for the better:

> The BootROM read our card's ID block — it verifies — and then **fell through to the
> eMMC**. A BootROM falls through when it cannot get a first stage running. So the
> header is fine and the **payload it points at** is what failed.

The first thing that payload does is bring up DRAM, and DDR init is the one link in
this chain with no second opinion behind it: `CONFIG_TPL=y` with
`CONFIG_RAM_ROCKCHIP_LPDDR4=y`, so U-Boot's own TPL does it. If that does not work on
this board's particular LPDDR4 part, the BootROM gets nothing runnable and moves to the
next device — exactly the observed behaviour.

Rockchip's DDR blob is the other opinion, and substituting it is one variable:
`EDGE1_ROCKCHIP_TPL=1 build/build-uboot.sh`. binman then packages `rockchip-tpl`
instead of `u-boot-tpl` into the same `idbloader.img`
(`arch/arm/dts/rockchip-u-boot.dtsi:170-184`), so the output is the same
`u-boot-rockchip.bin` at the same sector 64 and nothing else about the image changes.
Armbian picks `rk3399_ddr_933MHz_v1.25.bin` for rk3399; the script searches for it
rather than hardcoding a version.

Worth keeping in mind about Armbian's own choice here: its Edge scenario is
`tpl-spl-blob`, which passes `BL31=` alone and **no** `ROCKCHIP_TPL` — so Armbian
relies on U-Boot's TPL on this board too. That is either a point in favour of U-Boot's
TPL working, or a sign that Armbian's Edge support (`.csc`,
`BOARD_MAINTAINER=""`) is not exercised on 4GB LPDDR4 parts. The A/B is what tells the
two apart.

### The ID blocks, decoded and compared

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

## So where the fault has to be

`chosen/u-boot,version` reading `2022.07-armbian` says precisely one thing: the U-Boot
that handed off to the kernel was **Armbian's**, not the `2026.07` this tree builds.
Combined with everything above, two chains survive:

**(A) Our TPL fails to bring up DRAM.** The BootROM cannot get a first stage running off
the card and falls through to the eMMC, where Armbian's TPL, SPL and U-Boot all run.
This is the hypothesis `EDGE1_ROCKCHIP_TPL=1` tests, and DDR init is the only link in
our chain with no second opinion behind it.

**(B) Our TPL and SPL run, but SPL loads `u-boot.itb` from the eMMC.** The search order
is `u-boot,spl-boot-order = "same-as-spl", &sdhci, &sdmmc`
(`arch/arm/dts/rk3399-u-boot.dtsi:16`) — and `&sdhci` is the **eMMC**, ahead of the card.
`same-as-spl` should resolve to the card: rk3399 implements
`board_spl_was_booted_from()` (`arch/arm/mach-rockchip/spl.c:51`), which reads the
BootROM's boot-source ID from `CFG_IRAM_BASE + 0x10` and maps `BROM_BOOTSOURCE_SD` to
`/mmc@fe320000` (`rk3399/rk3399.c:27-31`). But if that value does not survive to SPL,
`same-as-spl` yields NULL, the loop `continue`s, and the next entry is the eMMC — whose
`u-boot.itb` at sector 16384 is Armbian's.

A third chain is ruled out: our U-Boot proper running and its `bootcmd` failing would
leave it at a prompt, and even if `CONFIG_ENV_IS_IN_MMC` pulled Armbian's saved
environment and its `bootcmd`, the handoff would still be done by 2026.07. The version
string says otherwise.

### Which to test first, and why in this order

1. **`EDGE1_ROCKCHIP_TPL=1`, one card write, nothing destructive.** If (A), this fixes
   it outright. It is also the only test here that risks nothing.
2. **Only if that fails, (B).** The fix is to stop the eMMC offering a competing
   `u-boot.itb` — back up the eMMC's first 16MiB, then clear the region at sector 16384.
   In *both* chains that makes some SPL fall through to the card and load ours, so it
   fixes as well as diagnoses; the cost is that Armbian stops booting until the backup
   is restored.

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
eMMC by `fe330000.*` rather than by number.

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
