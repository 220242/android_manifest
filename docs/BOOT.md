# How the Edge1 boots this Android

Everything about getting from power-on to Android's first-stage init: what the SoC
does, which bootloader actually runs, what the kernel has to be told, and how to test
each step on a board with no serial adapter. It replaces a diagnosis that was wrong for
four rounds; [the last section](#how-this-was-got-wrong) says how, briefly, so it is not
made again.

## The short version

**Write `edge1-sdcard.img.gz` to a card with Etcher, put it in the board, power on.**
On this board as it is — Armbian on the eMMC — that boots the Android on the card, and
nothing on the eMMC is written. Pull the card and the board boots Armbian again.

It works because of partition 1 of the card, not because of the bootloader on it:

| What is on the eMMC | What starts the card's Android |
|---|---|
| Anything bootable (here: Armbian) | **the eMMC's own U-Boot**, running `boot.scr` from the card's partition 1 |
| Nothing, or TST mode is used | **our U-Boot**, from the card's sector 64 |
| Our U-Boot in SPI NOR (not done yet) | **our U-Boot**, from SPI |

The kernel log appears on HDMI on a userdebug build, so each stage can be watched.

## The BootROM goes SPI NOR, then eMMC, then SD card

The RK3399's mask ROM tries its boot sources in a fixed order and runs the first
bootloader it finds: **SPI NOR, SPI NAND, eMMC, SD card**, then USB maskrom. A source
counts as bootable when it has a valid Rockchip ID block at sector 64 (sector 0 for SPI).

This is not an inference. It is:

* the RK3399 boot sequence as Pine64 documents it
  ([RK3399 boot sequence](https://pine64.org/documentation/General/RK3399_boot_sequence));
* Khadas's own documentation, which gives the Edge's priority as SPI flash, then eMMC,
  then TF card, and describes TST mode (below) as the way past a bootloader on the eMMC
  ([OOWOW on Edge](https://docs.khadas.com/software/oowow/devices/edge),
  [Edge boot sequence](https://docs.khadas.com/products/sbc/edge2/development/boot-sequence));
* written in the owner's own OpenWrt notes for this very board
  (`khadas_edge-openwrt/boards/khadas-edge-v/README.md:38-40`: *"with the factory
  Android / Ubuntu on the eMMC an SD card is ignored"*);
* and what four cards did here: each had a valid ID block at sector 64 (decoded with
  `build/rk-idb-check.py`) and a valid FIT at sector 16384, and each booted the eMMC's
  Armbian — whose U-Boot, `2022.07-armbian`, was the one that handed off to the kernel
  every time.

Measured on this board: SPI NOR (`mtd0`, 16MB) is **erased**; the eMMC and the card
both carry a valid ID block. So the eMMC wins, and a bootloader on the card never runs.

## Path A: the eMMC's U-Boot boots the card

What the eMMC's U-Boot does after it starts is run *distro boot*, and on Rockchip
distro boot looks at the SD card first:

```
include/configs/rockchip-common.h:17    #define BOOT_TARGETS "mmc1 mmc0 nvme scsi usb pxe dhcp spi"
```

`mmc1` is the card (`&sdmmc`, `mmc@fe320000`), `mmc0` the eMMC. For each device it
lists the partitions flagged bootable and, if there are none, **uses partition 1**
(`include/config_distro_bootcmd.h`, `scan_dev_for_boot_part`); on that partition it
looks for `extlinux/extlinux.conf`, then `boot.scr`.

That is how the owner's OpenWrt card "won" over the eMMC: its partition 1 holds a
`boot.scr`, and Armbian's U-Boot ran it. Our first four cards had `misc` — raw, no
filesystem — as partition 1, so distro boot found nothing on the card and went on to the
eMMC.

So every image now begins with **`bootfs`: a 4MiB FAT that is partition 1**, holding
`boot.scr` and the `boot.cmd` it was made from.

### What the boot script does

[`device/khadas/edge/flash/boot.cmd`](../device/khadas/edge/flash/boot.cmd) is a template;
[`build/build-bootfs.sh`](../build/build-bootfs.sh) fills it from `boot.img`'s header,
wraps it with `mkimage` and builds the FAT. At boot the script:

1. works out which controller it is on from `devtype`/`devnum` — card `fe320000.mmc`,
   eMMC `fe330000.mmc`, NVMe `f8000000.pcie` — for `androidboot.boot_devices`;
2. finds the `boot` partition by name (`part start`) and reads its first page;
3. checks the header: magic `ANDROID!`, and the first word of the SHA1 `id` against the
   one it was built for — a `boot` partition rewritten on its own is reported, not
   booted with stale offsets;
4. reads the kernel, the ramdisk and the dtb straight out of the `boot` partition to
   `0x02200000`, `0x0a200000` and `0x01f00000`;
5. sets `bootargs` to `androidboot.boot_devices=<controller>` plus `boot.img`'s own
   command line, and runs `booti`.

It uses only `part`, `mmc read`/`nvme read`, `setexpr` and `booti`, because it has to
run on Armbian's U-Boot 2022.07, which almost certainly has no `abootimg`:
`CONFIG_ANDROID_BOOT_IMAGE` is not in `khadas-edge-v-rk3399_defconfig`, which Armbian
builds it from (`config/boards/khadas-edge.csc`). That is also why the offsets are baked in by the build rather
than parsed at boot.

It was run in U-Boot's own sandbox (the same source tree, the old hush parser that
2022.07 has) against a real card image built by `build-images.sh`, with the real Edge-V
dtb in `boot.img`: distro-boot discovery found it on partition 1, the kernel, ramdisk
and dtb landed byte-for-byte at their addresses, `bootargs` came out right, and the
id-mismatch and not-a-boot-image paths stopped with their messages.

## Path B: our own U-Boot

Mainline U-Boot `v2026.07`, `khadas-edge-v-rk3399_defconfig` plus a fragment
([`build/build-uboot.sh`](../build/build-uboot.sh)), `BL31` from `rkbin`, packaged by
binman as `u-boot-rockchip.bin` and written at sector 64 of the card and eMMC images.
It runs when nothing ahead of the card in the BootROM's order is bootable: an empty
eMMC, TST mode, or — later — from SPI NOR.

**It has not run on this board yet.** Every card so far lost to the eMMC before it could.

Its `bootcmd` tries three Android boot partitions, then hands over to distro boot:

```
card  (mmc 1):  part start/size mmc 1 boot -> mmc read -> abootimg get dtb
                -> setenv bootargs androidboot.boot_devices=fe320000.mmc -> bootm
eMMC  (mmc 0):  the same, fe330000.mmc
NVMe  (nvme 0): nvme scan; the same, f8000000.pcie
then:           echo "NO ANDROID BOOT PARTITION ..."; bootflow scan -lb
```

`bootm` prepends the `bootargs` variable to the image's own command line
(`boot/image-android.c:396-433`), so one argument per medium is all that has to be set.
The final `bootflow scan -lb` boots whatever the eMMC holds when no card is in — which
matters once this U-Boot lives in SPI NOR.

### The attempts are joined with `;`, not `||`

U-Boot's hush (the old parser — the default, and what this config has) does not group
`a && b || c` like a POSIX shell. When a command followed by `&&` fails, it skips
everything up to the next `;`, **including the `||` branches**. Measured in the sandbox:

```
false && echo A || echo B          -> prints nothing
true && false || echo B            -> B
false && echo A; true && echo B    -> B
```

The `bootcmd` used to join its attempts with `||`, so a card with no `boot` partition —
or no card — stopped the whole thing at the first `part start`, and the eMMC and NVMe
attempts were dead code. Each attempt is now its own `;`-separated list; a successful
`bootm` never returns, so the next one runs only if the last failed.
`build/verify-tree.sh` (checks 3g and 3h) refuses `&& … ||` in either the `bootcmd` or
the boot script.

### What else the fragment carries

* **HDMI console**: `CONFIG_VIDEO`, `DISPLAY`, `VIDEO_ROCKCHIP`, `DISPLAY_ROCKCHIP_HDMI`,
  `CONSOLE_MUX` and a `preboot` that adds `vidconsole` — the banner `U-Boot 2026.07`
  on the screen is how to tell this U-Boot ran.
* **Compiled-in environment** (`# CONFIG_ENV_IS_IN_MMC is not set`, so
  `ENV_IS_NOWHERE`): the defconfig reads the environment from `mmc 0`, the eMMC, and a
  stored one there would replace `bootcmd` and `preboot` wholesale.
* **SPL boot order** `"same-as-spl", &sdmmc, &sdhci`: a card-started SPL stays on the
  card, and an SPI-started one falls back to the card before the eMMC.

## What the kernel has to be told

Two arguments without which first-stage init stops, whichever bootloader starts it. Both
are read from the AOSP 14 sources (`android-14.0.0_r75`), not assumed.

**`androidboot.boot_devices=<controller>`** — per medium, so set by the bootloader.
`/dev/block/by-name/<name>` is created only for partitions of a listed boot device
(`system/core/init/devices.cpp:410-421`). Without the argument the boot devices are
derived from fstab entries of the form `/dev/block/platform/<dev>/by-name/…`, and this
fstab uses `/dev/block/by-name/…`, which that fallback explicitly skips
(`fs_mgr/libfstab/fstab.cpp:452-460, 868-904`) — so no `super`, `metadata` or `misc`
would ever be found. GloDroid's RK3399 port (PinePhone Pro) passes exactly
`fe320000.mmc` and `fe330000.mmc` from its U-Boot script
([`platform/uboot/bootscript.cpp`](https://github.com/GloDroid/glodroid_device/blob/master/platform/uboot/bootscript.cpp)).

**`androidboot.verifiedbootstate=orange`** — in `BoardConfig.mk`. The fstab mounts the
logical partitions with `avb`, and first-stage init then wants a vbmeta digest from the
bootloader (`androidboot.vbmeta.size`, `.hash_alg`, `.digest`) unless the device is
unlocked: `AvbVerifier::Create` fails without them (`fs_mgr/libfs_avb/fs_avb.cpp:114-118`)
and `AvbHandle::Open` refuses the failure (`:412-420`) unless `IsAvbPermissive()`, which
is `verifiedbootstate == "orange"` (`libfs_avb/util.cpp:109-116`). No bootloader here
computes a digest. dm-verity is still set up from vbmeta; what is skipped is the
attestation no bootloader in this chain can provide. Real AVB (`avb verify` in U-Boot)
is open work.

On a **userdebug** build three more, for bring-up without a UART:

| | |
|---|---|
| `console=tty0` | the kernel log on HDMI (fbcon over DRM); `ttyS2` stays `/dev/console` |
| `androidboot.init_fatal_panic=true` | a fatal init error panics instead of rebooting (`init/reboot_utils.cpp:50-57`), so the reason stays on screen |
| `androidboot.selinux=permissive` | a new port's first SELinux denial does not stop boot; init honours it only on non-user builds (`init/selinux.cpp:98-108`) |

## Watching it boot

What the screen shows on a userdebug card, in order:

1. **Path A**: nothing from U-Boot (Armbian's has no video), then kernel text.
   **Path B**: `U-Boot 2026.07`, the banner, then kernel text.
2. Kernel messages scrolling (`console=tty0`).
3. Either the Android boot animation, or a kernel panic that stays on screen. A panic
   whose last lines mention `first_stage_mount`, `fs_mgr` or `avb` is the part of this
   document that failed; photograph it.

To tell afterwards which U-Boot started a running system (Armbian or Android):

```sh
cat /proc/device-tree/chosen/u-boot,version     # 2022.07-armbian-... = path A
```

## TST mode: making the BootROM take the card

Khadas boards can be told to skip internal storage for one boot: with the board powered,
**press FUNCTION three times within two seconds**. The power LED blinks for about three
seconds; the board then boots from the TF card, or — with no bootable card — enters
maskrom (LED off). Khadas documents it as the universal way to start OOWOW from a card on
an Edge whose eMMC holds a bootloader.

That is how our own U-Boot gets tested without touching the eMMC: TST mode with the card
in, and the `U-Boot 2026.07` banner on HDMI means path B works. It is worth doing before
anything writes our U-Boot to the eMMC or SPI NOR.

One caution from Khadas users: a similar-looking key sequence is used to erase the eMMC.
Use exactly three short presses, not a hold. Backing up the eMMC's first 32MiB from
Armbian first costs nothing:

```sh
dd if=/dev/mmcblk2 of=/root/emmc-head.img bs=1M count=32
```

## Installing onto the eMMC or the NVMe

From the Android running off the card:

```sh
adb root
adb shell sh /vendor/bin/edge1-install-internal.sh emmc     # or nvme
```

It repartitions the target to its real size and copies the card partition by partition,
`bootfs` included. What it does with the **bootloader** depends on who started the
running system, read from `/proc/device-tree/chosen/u-boot,version`:

* the card's own U-Boot — proven on this board — is copied to the eMMC;
* anything else, such as Armbian's, is **left in place** on the eMMC. It booted the card
  through `bootfs`, and it will boot the installed Android through the eMMC's `bootfs`
  the same way. Repartitioning does not touch it: `sgdisk --zap-all` rewrites only the
  GPT at the start and end of the disk.

`--with-bootloader` and `--keep-bootloader` override the choice. The NVMe never gets a
bootloader: the BootROM has no PCIe (`arch/arm/include/asm/arch-rockchip/bootrom.h:47-59`).

## SPI NOR, later

The erased 16MB SPI NOR is ahead of everything in the BootROM's order. Our U-Boot there
(`u-boot-rockchip-spi.bin` is already built) would boot a card if one is in, the eMMC's
Android if not, and otherwise the eMMC's own system through distro boot — a board that
no longer depends on what is on the eMMC. It is reversible (`flash_erase /dev/mtd0 0 0`
from Linux, or TST mode to get past it), but it should wait until path B has been seen
working in TST mode.

## How this was got wrong

For the record, compressed. Each step was a reasonable reading of the evidence then in
hand; the evidence that would have settled it was the boot order, which was available
and was dismissed.

1. **"The BootROM prefers the eMMC."** The first conclusion, and the correct one — then
   retracted, because an OpenWrt card on this board "always won". That card won through
   Armbian's U-Boot running its `boot.scr`, which was not considered.
2. **"The card's first stage fails DRAM init."** Tested with rkbin's DDR blob instead of
   U-Boot's TPL. Both cards behaved identically — as they had to, since neither TPL ran.
3. **"SPL loads `u-boot.itb` from the eMMC."** The SPL boot order was reordered to put the
   card first. No change: SPL never ran either.
4. **"Our U-Boot reads Armbian's environment."** `ENV_IS_IN_MMC` was turned off. Correct
   in itself; no change.
5. **"U-Boot 2026.07's load addresses."** A diff against OpenWrt's 2025.10 config found
   only moved load addresses, and an A/B was prepared. Superseded.

What finally settled it was re-reading Khadas's and Pine64's documentation and the
owner's own OpenWrt notes, and noticing that the only card that ever "booted" was one
the eMMC's U-Boot could read. The fixes from steps 3 and 4 stay — each is right for when
our U-Boot does run. The three things that would have stopped Android even with the
bootloader solved — `boot_devices`, the verified-boot state, and the `&& ||` fallback —
were found on the way.
