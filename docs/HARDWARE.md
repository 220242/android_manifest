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

## The boot order, and two conclusions that were wrong

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

That relocated the fault, but not to where I then put it. The next inference was:

> The BootROM read our card's ID block — it verifies — and then **fell through to the
> eMMC**. A BootROM falls through when it cannot get a first stage running. So the
> header is fine and the payload it points at is what failed — and the first thing
> that payload does is bring up DRAM.

**That was also wrong, and this time the test settled it.** DDR init was the one link
with no second opinion behind it (`CONFIG_TPL=y` with `CONFIG_RAM_ROCKCHIP_LPDDR4=y`,
so U-Boot's own TPL does it), and `EDGE1_ROCKCHIP_TPL=1` substitutes Rockchip's blob as
a single variable: binman packages `rockchip-tpl` instead of `u-boot-tpl` into the same
`idbloader.img` (`arch/arm/dts/rockchip-u-boot.dtsi:170-184`), same
`u-boot-rockchip.bin`, same sector 64, nothing else changed. Two cards were written,
one each way, and **both boot Armbian**. DRAM is therefore not the fault.

What the inference got wrong was "falls through": the BootROM never had to. Our TPL and
SPL run from the card perfectly well — and then SPL, which loads the *second* stage on
its own, picks the eMMC. See the next section.

Armbian's own choice is worth keeping on record now that it is no longer in question:
its Edge scenario is `tpl-spl-blob`, which passes `BL31=` alone and **no**
`ROCKCHIP_TPL`, so Armbian relies on U-Boot's TPL on this board too — consistent with
what the A/B measured.

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

## Two real defects, found and fixed — and neither was the blocker

Both DDR variants were tested — U-Boot's own TPL and rkbin's 933MHz blob, one card
each — and **both boot Armbian from the eMMC**. That eliminates chain (A), DDR init:
if DRAM were the problem, the rkbin blob would have changed the outcome, and it
changed nothing.

Reading the config then turned up two genuine defects, either of which was enough on
its own to produce exactly what the board does. Both are fixed. **Neither turned out
to be the blocker** — see "Both fixes were built and neither booted the card" below,
and the comparison against a working U-Boot after it. They are written up in full
anyway, because each would have bitten the moment the other was fixed, and because
what they rule out is now part of the evidence.

### 1. SPL loads `u-boot.itb` from the eMMC

`u-boot-rockchip.bin` is two stages in one blob. The BootROM loads the first —
TPL + SPL — from sector 64 of the device it booted from, which the card's valid ID
block proves it does. SPL then loads the second, `u-boot.itb`, **by itself**, from
the first device in `/chosen/u-boot,spl-boot-order` that resolves. Upstream says:

```
u-boot,spl-boot-order = "same-as-spl", &sdhci, &sdmmc;   arch/arm/dts/rk3399-u-boot.dtsi:16
```

On rk3399 `&sdhci` is the eMMC (`mmc@fe330000`) and `&sdmmc` is the card
(`mmc@fe320000`) — `arch/arm/mach-rockchip/rk3399/rk3399.c:27-31`. So after
`same-as-spl`, **the eMMC is tried before the card**.

`same-as-spl` is supposed to make that harmless: `board_spl_was_booted_from()`
(`arch/arm/mach-rockchip/spl.c:51`) reads the BootROM's boot-source ID from
`CFG_IRAM_BASE + 0x10` and maps `BROM_BOOTSOURCE_SD` (5) to `/mmc@fe320000`. But it is
allowed to fail, and `arch/arm/mach-rockchip/spl-boot-order.c:140-144` does not treat
failure as an error — it `continue`s to the next entry, the eMMC.

And this eMMC is not empty at sector 16384. Armbian's rockchip64 family writes
`idbloader.img` to sector 64 and `u-boot.itb` to sector 16384
(`config/sources/families/include/rockchip64_common.inc`, `write_uboot_platform`) —
byte-for-byte the same layout this tree uses. So SPL finds a perfectly valid FIT
there, loads Armbian's U-Boot 2022.07, and the board boots Armbian from a card that
is entirely correct. That matches every observation: no banner from our U-Boot even
with video enabled, `chosen/u-boot,version` reading `2022.07-armbian`, and no
difference between the two DDR variants, because the divergence happens *after* DRAM
is up.

**The fix**, applied by `build/build-uboot.sh` on every build, is to put `&sdmmc`
first:

```
u-boot,spl-boot-order = "same-as-spl", &sdmmc, &sdhci;
```

The card then wins whether or not `same-as-spl` resolves, and the eMMC stays in the
list behind it so an eMMC install still boots with no card in the slot. This is not
an invention: Armbian ships exactly this ordering for the other rk3399 board it boots
from removable media —
`patch/u-boot/v2026.07/board_helios64/dt_uboot/rk3399-kobol-helios64-u-boot.dtsi:17`
reads `"same-as-spl", &spiflash, &sdmmc, &sdhci`.

It is done as an edit in the build script rather than as a patch file because `repo`
owns `bootloader/u-boot` and resets it on every sync, so the edit has to be re-applied
by the thing that builds. The manifest hash therefore invalidates the `Uboot` stage in
`Start-EdgeBuild.ps1`.

### 2. Our U-Boot reads its environment off the eMMC

This one would have taken over the moment the first was fixed. Measured against the
real defconfig rather than inferred — `make khadas-edge-v-rk3399_defconfig` and read
the result:

```
CONFIG_ENV_IS_IN_MMC=y
CONFIG_ENV_MMC_DEVICE_INDEX=0     # mmc 0 on rk3399 is &sdhci, the eMMC
CONFIG_ENV_OFFSET=0x3F8000        # sector 8128
```

Everything that makes this U-Boot ours lives in the environment: `bootcmd` is the
three-target Android sequence, `preboot` is what moves the console onto HDMI. Both are
*defaults*, and `env_load()` replaces the entire default set with a stored one the
moment it finds a valid CRC — it is not a merge. One saved environment on the eMMC
therefore discards our `bootcmd` and our `preboot`, and U-Boot boots whatever that
environment says, with a blank screen because `preboot` never ran. On this board that
is not hypothetical: the eMMC runs Armbian built from *this same defconfig*, so its
U-Boot keeps its environment at exactly that offset on exactly that device.

It also explains the one observation nothing else did — **Ethernet coming up and DHCP
handing the board an address before Armbian loads**. Our `bootcmd` never touches the
network. Armbian's distro `boot_targets` includes `dhcp`.

**The fix** is one line in the config fragment:

```
# CONFIG_ENV_IS_IN_MMC is not set
```

With no `ENV_IS_IN_*` left, `env/Kconfig:71-79` selects `ENV_IS_NOWHERE` through
`ENV_IS_DEFAULT`: the compiled-in environment is used on every boot, from every
medium, and nothing on the internal storage can change what the card does. For an
appliance whose boot sequence is fixed at build time that is what is wanted.

It removes a way to brick the card, too. `ENV_OFFSET 0x3F8000` is sector 8128, inside
the sectors 64–16383 that `u-boot-rockchip.bin` occupies — so had the environment
merely been moved to the card, a `saveenv` would have written 32KB into the middle of
our own bootloader.

### What both fixes leave untouched

The eMMC. Nothing here writes to it, nothing here stops Armbian booting when the card
is out, and pulling the card still puts the board back exactly as it was. The
destructive option — backing up the eMMC's first 16MiB and clearing sector 16384 so
it offers no competing `u-boot.itb` — is no longer needed and has not been done.

### Both fixes were built and neither booted the card

Card written from `2f89b3c`, with `==> SPL boot order: "same-as-spl", &sdmmc, &sdhci`
and `environment: compiled in (ENV_IS_NOWHERE)` in the build log, and `env/nowhere.o`
compiled instead of `env/mmc.o`. Screen blank, Armbian boots, and with that card in
the slot:

```
# cat /proc/device-tree/chosen/u-boot,version
2022.07-armbian-2022.07-Se092-P621f-H5921-V2588-Bb703-R448a
```

So Armbian's U-Boot still did the kernel handoff. Both fixes are right and neither was
the blocker. What they did do is narrow it, because the card is now first in SPL's
search order and our environment cannot be replaced — so whatever is wrong is *upstream*
of SPL's choice of device.

## Compared against a U-Boot that does boot this board

The board's owner built OpenWrt for this same Edge-V earlier, and **that card wins over
the eMMC every time**. Its bootloader is in the tree at
`build/reference/openwrt-u-boot-2025.10/`, with the `.config` it was built from. That is
the single most valuable artifact in this whole exercise: a known-good answer for this
exact board.

### The ID block is structurally identical

| | init_offset | init_size | init_boot_size |
|---|---|---|---|
| OpenWrt (boots) | 4 blocks | 136 blocks | 368 blocks |
| ours | 4 blocks | 136 blocks | 376 blocks |

`init_offset` and `init_size` match exactly; `init_boot_size` differs by 8 blocks, which
is just our SPL being 4KB larger. The BootROM sees the same thing either way.

### The sectors are identical

OpenWrt writes `idbloader.img` at sector 64 and `u-boot.itb` at sector 16384. So does
Armbian (`rockchip64_common.inc`, `write_uboot_platform`). Our `u-boot-rockchip.bin` is
those two pieces already glued together with the pad between them — binman puts the FIT
at `CONFIG_SPL_PAD_TO` = 0x7f8000 = 16320 sectors, written at 64, so 64 + 16320 = 16384.
`build-images.sh` reads the `0xd00dfeed` back out of the blob at that offset rather than
trusting the arithmetic.

### The FIT is the same shape

Dumping OpenWrt's `u-boot.itb`: `u-boot` at 0x200000, `atf-1`..`atf-5` (BL31 split into
segments, the last two landing in SRAM at 0xff8c0000 and 0xff8c2000), `fdt-1`, and
`config-1` with `firmware = "atf-1"` and `loadables = u-boot atf-2 atf-3 atf-4 atf-5`.
**No `tee` image at all** — so the `missing optional external blobs ... tee-os` warning
binman prints on our build is exactly what a working build looks like, and not a fault.

One useful side effect of reading that FIT: `atf-4` loads 0x2000 bytes at **0xff8c0000**,
which is `CFG_IRAM_BASE`. So BL31 overwrites the BootROM's boot-source id at
`CFG_IRAM_BASE + 0x10` before Linux ever runs, and reading that address from Linux
cannot tell us which device the board booted from.

### Only fifteen config symbols differ, and eleven are ours

Normalising both `.config` files and comparing the symbols present in both:

| symbol | OpenWrt 2025.10 (boots) | ours 2026.07 |
|---|---|---|
| `CONFIG_TEXT_BASE` | `0x00200000` | `0x00800000` |
| `CONFIG_SYS_UBOOT_START` | `0x00200000` | `0x00800000` |
| `CONFIG_LNX_KRNL_IMG_TEXT_OFFSET_BASE` | `0x00200000` | `0x00800000` |
| `CONFIG_SPL_LOAD_FIT_ADDRESS` | `0x0` | `0x00200000` |
| `CONFIG_SYS_BOOTM_LEN` | `0x4000000` | `0x8000000` |
| `CONFIG_SYS_CONSOLE_IS_IN_ENV` | `y` | `n` |
| `CONFIG_BOOTM_NETBSD`, `CONFIG_CMD_CLS`, `CONFIG_CYCLIC`, `CONFIG_DEVRES` | — | version noise |

plus the five that are the Android delta (`ANDROID_BOOT_IMAGE`, `BOOTCOMMAND`,
`USE_PREBOOT`, `ENV_IS_IN_MMC`, `ENV_IS_NOWHERE`).

The load addresses are not ours: `arch/arm/mach-rockchip/Kconfig:823-826` derives
`TEXT_BASE` from `SPL_TEXT_BASE`, and v2026.07 moved the rk3399 value from 0x00200000 to
0x00800000. **That is the only substantive difference between a U-Boot that boots this
board and one that does not.**

Two other things this comparison settles:

- **`CONFIG_ENV_IS_IN_MMC=y` with `ENV_MMC_DEVICE_INDEX=0` is in the working OpenWrt
  build too.** So there is evidently no valid environment at eMMC sector 8128 on this
  board, and turning it off was hygiene rather than the fix. It stays off: an appliance
  should not let the internal storage decide what the card boots.
- **OpenWrt does not touch `u-boot,spl-boot-order`** and still wins over the eMMC. So
  `same-as-spl` does resolve on this board, and the reordering was insurance rather than
  the fix. It also stays.

### The two cards that separate what is left

1. **`EDGE1_UBOOT_REV=v2025.10`** — the one version known to boot this board, with our
   Android delta on top. If this boots, v2026.07's load addresses are the fault.
2. **OpenWrt's own bootloader, our partitions** — `EDGE1_UBOOT_IDB` and
   `EDGE1_UBOOT_ITB` in `build-images.sh` write the pair at sectors 64 and 16384. This
   one cannot fail to inform: if `U-Boot 2025.10` appears on HDMI, the BootROM boots
   this card layout and everything left is in our U-Boot; if the screen stays blank and
   Armbian boots, the BootROM is not running the card at all and no U-Boot change will
   ever help — the path forward is then the SPI NOR, which is erased, or the eMMC.

Card 2 will not boot Android: its `bootcmd` is `bootflow scan -lb`, which knows nothing
about Android boot images. Its prompt, or its "no bootflow" message, is the result.

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
