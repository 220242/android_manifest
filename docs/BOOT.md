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

The screen stays dark until a kernel starts — Armbian's U-Boot has no video — and then
shows the kernel log on a userdebug build. What happened before that is written to
`edge1-boot.log` on the card, which any PC can read; [Watching it boot](#watching-it-boot)
has the details.

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
distro boot looks at the SD card first. On this board that U-Boot is 2022.07, and its
list comes from `BOOT_TARGET_DEVICES` in that release's
`include/configs/rockchip-common.h` ("First try to boot from SD (index 1), then eMMC
(index 0)"); preprocessed against `khadas-edge-v-rk3399_defconfig` it is

```
boot_targets=mmc1 mmc0 usb0 pxe dhcp sf0
```

On the board Armbian's environment has moved USB to the front — `edge1-boot.log` read
`boot_targets=usb0 mmc1 mmc0 pxe dhcp sf0` — which changes nothing for the card: it is
still ahead of the eMMC. `mmc1` is the card (`&sdmmc`, `mmc@fe320000`), `mmc0` the eMMC. There is no `nvme`: that
config has no `CMD_NVME` (current U-Boot's list does have it). For each device it lists
the partitions flagged bootable and, if there are none, **uses partition 1**
(`include/config_distro_bootcmd.h`, `scan_dev_for_boot_part`); on that partition it
looks for `extlinux/extlinux.conf`, then `boot.scr.uimg`, then `boot.scr`, first in `/`
and then in `/boot/`.

That is how the owner's OpenWrt card "won" over the eMMC: its partition 1 holds a
`boot.scr`, and Armbian's U-Boot ran it. Our first four cards had `misc` — raw, no
filesystem — as partition 1, so distro boot found nothing on the card and went on to the
eMMC.

So every image now begins with **`bootfs`: a 128MiB FAT that is partition 1**. On the
card it is typed *Microsoft basic data* (so Windows mounts it, as `EDGE1BOOT`) and
flagged legacy-BIOS-bootable (so distro boot picks it rather than defaulting to it). It
holds:

| File | |
|---|---|
| `boot.scr`, `boot.cmd` | the boot script, and its source |
| `Image`, `ramdisk.img`, `edge1.dtb` | byte-for-byte copies of what `boot.img` carries, taken out of it in the same build step |
| `edge1-boot.log` | rewritten by the script on every boot: how far it got |
| `README.txt` | the above, for whoever opens the card on a PC |

### What the boot script does

[`device/khadas/edge/flash/boot.cmd`](../device/khadas/edge/flash/boot.cmd) is a template;
[`build/build-bootfs.sh`](../build/build-bootfs.sh) takes `boot.img` apart, fills in its
command line, wraps the script with `mkimage` and builds the FAT. At boot the script:

1. works out which controller it is on from `devtype`/`devnum` — card `fe320000.mmc`,
   eMMC `fe330000.mmc`, NVMe `f8000000.pcie` — for `androidboot.boot_devices`;
2. `load`s `Image`, `edge1.dtb` and `ramdisk.img` from its own partition to
   `0x02200000`, `0x01f00000` and `0x0a200000`;
3. sets `bootargs` to `androidboot.boot_devices=<controller>` plus `boot.img`'s own
   command line;
4. writes `edge1-boot.log` (`edge1_stage=booti`) and runs
   `booti 0x02200000 0x0a200000:<size> 0x01f00000` — a raw ramdisk, `addr:size`.

If anything fails it writes the stage it reached to the log and returns, and distro
boot carries on to the eMMC: the board boots Armbian as if the card were not there.

### What it may use: only what 2022.07 has

The script runs on the eMMC's U-Boot, so it can use only the commands **that** U-Boot
was built with — and `khadas-edge-v-rk3399_defconfig` at v2022.07 is narrow:

* built: `booti`, `bootm`, `load` (`CMD_FS_GENERIC`), `fatwrite` (`FAT_WRITE`),
  `env export`, `part`, `mmc`, `itest`, `source`, and `test` (built with `HUSH_PARSER`),
  plus `LEGACY_IMAGE_FORMAT` for `boot.scr` itself and `SUPPORT_RAW_INITRD` for
  `addr:size`;
* **not built: `setexpr`**, `read`, `gpio`, `nvme`, `abootimg`, `led`; no video, no
  watchdog, no `ver` variable (`VERSION_VARIABLE`).

The first version of the script read the three pieces straight out of the raw `boot`
partition and checked its header, which needed `setexpr` for the arithmetic. On the
board `setexpr` was an unknown command, the header check failed, and the script
declined — every time, with nothing on the screen to say so; the board went on to boot
Armbian. The sandbox run that "verified" it was current U-Boot, which has `setexpr`.

Now the script uses nine commands — `echo test setenv run load env fatwrite itest booti` —
and [`build/check-uboot-script.py`](../build/check-uboot-script.py) refuses anything
else at build time (it is also check 3g of `verify-tree.sh`), along with hush's
`&& … ||` trap. The pieces are files because `load` is what every distro boot script
uses, Armbian's own included; the price is 55MB duplicated on a 7GB card.

It was then run on **U-Boot v2022.07 itself**: a sandbox build with that config's
command set (`setexpr`, `read`, `gpio`, `nvme`, `abootimg`, `led` removed, legacy
images on) and the distro-boot environment preprocessed from the 2022.07 headers for
`khadas-edge-v-rk3399_defconfig`, with the card image from `build-images.sh` as the
first boot target and a stand-in "Armbian" disk as the second. `run distro_bootcmd`
found `/boot.scr` on partition 1, loaded the three files byte-for-byte (compared with
`cmp.b`), set `bootargs`, wrote `edge1-boot.log`, and — `booti` being ARM-only, so
missing in a sandbox — recorded `booti-returned` and fell through to the "Armbian"
disk's script, which is exactly what the board does when the script declines. With a
`poweroff` put where `booti` is, the log on the card read `edge1_stage=booti`; with
`ramdisk.img` deleted, `no-ramdisk` and on to "Armbian". `fsck.vfat` found the FAT
clean after each write. `booti` itself is the one step not exercised; its raw-initrd
parsing (`boot/image-board.c:434-443` in 2022.07) was read, and it is the same call
every extlinux distro makes.

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

No HDMI patch is involved in any of this: the screen is dark during U-Boot because
Armbian's U-Boot has no video at all, and the kernel drives HDMI with the same mainline
dtb Armbian and OpenWrt use (`DRM_ROCKCHIP`, `ROCKCHIP_DW_HDMI` and fbcon are built in).

**The sys LED.** Before HDMI is up it is the kernel's only signal. `sys_led` has the
`heartbeat` trigger in the dtb, and `build-kernel.sh` marks it `panic-indicator`:

| LED | Means |
|---|---|
| heartbeat: two short blinks, a pause | a kernel is running — Armbian's does this too |
| an even blink, about 2.5 per second | **our kernel panicked** (`kernel/panic.c` toggles panic-indicator LEDs every 200ms); the panic text is on HDMI if DRM got that far |
| neither | no kernel started, or it hung before the LED driver probed |

**`edge1-boot.log`.** When the board ends up in Armbian anyway, put the card in a PC
and open `edge1-boot.log` on the `EDGE1BOOT` drive (or, from Armbian itself,
`mount -L EDGE1BOOT /mnt && cat /mnt/edge1-boot.log; umount /mnt`):

| `edge1_stage` | Means |
|---|---|
| file unchanged since the build | the script never ran: the eMMC's U-Boot did not get to the card |
| `no-kernel`, `no-dtb`, `no-ramdisk` | that file could not be loaded |
| `booti-returned` | U-Boot refused to start the kernel |
| `booti` | everything loaded and the kernel was started; from here on it is the kernel's story, on HDMI and the LED |

`edge1_where` is the device and partition the script ran from, `boot_targets` and
`fdtfile` are the eMMC U-Boot's own, and the sizes are hex.

**First results on the board.** Card six: `edge1_stage=booti`, `edge1_where=mmc 1:1` —
the script ran on Armbian's U-Boot, loaded all three files (Image `0x314aa00` bytes,
ramdisk `0x19777c`, dtb `0xf7bd`) and handed over to our kernel. Card seven: the kernel
booted with its log on HDMI, ran `/init`, and first-stage init stopped at its third
mount — `mount("selinuxfs", "/sys/fs/selinux") failed Invalid argument` — because
SELinux was built but not in `CONFIG_LSM` ([`KERNEL.md`](KERNEL.md#the-lsm-list)).
init then rebooted to "bootloader", a warm reset, and the next run of the boot script
saved the whole console log to `edge1-pstore.bin`. Card eight: SELinux up, first-stage init
read the fstab and stopped at `Missing vbmeta partitions` — the fstab's bare `avb` names no
vbmeta partition; it says `avb=vbmeta` now. Card nine: past first stage, through the SELinux
policy load and into second stage, where keystore2 and apexd found no `/data` — the
device's init rc never ran `mount_all`. From here on the log ends in logcat as well:
`edge1-pstore.bin`'s pmsg zone carried 130 lines of it.

**`edge1-pstore.bin`: the previous kernel's log.** The kernel keeps a 1MiB
[ramoops](https://docs.kernel.org/admin-guide/ramoops.html) region at `0x30100000`
(`build-kernel.sh` adds it to the dtb; `PSTORE_RAM`, `PSTORE_CONSOLE` and `PSTORE_PMSG`
are built in): its whole console output — `init:` lines included — the log at a panic,
and on a userdebug build what liblog writes, i.e. logcat. RAM survives a warm reset, and
a userdebug kernel reboots by itself 20 seconds after a panic (`panic=20`). The boot
script, before it loads anything, copies the region to `edge1-pstore.bin` on `bootfs`
and notes in the log whether it held our kernel's signature:

| `edge1_prev` | Means |
|---|---|
| `found` | the console zone carries our kernel's signature — decode it |
| `none` | a cold start, or RAM did not survive the reset; the file is noise |

```sh
build/edge1-pstore.py edge1-pstore.bin        # console, panic records, logcat
```

So the routine after a failed boot is: let it reboot once by itself (it loops while
something panics — the panic stays on screen for 20 seconds), then pull the card and
send both files. A power cut loses the region; only a reset keeps it.

**Measured on the board: RAM survives the reset.** The first capture came back with
the console zone intact — 32KB of log, from `Booting Linux` to `reboot: Restarting
system` — and exactly one word changed: the first, at `0x30000000`, now `0x5aa5f00f`.
That is `PATTERN` from the Rockchip DRAM init's capacity probe
(`arch/arm/include/asm/arch-rockchip/sdram_common.h`), which `sdram_detect_row_3_4()`
writes at 3/4 of a power of two — `0x30000000` for 1GiB. It cost that capture its
`edge1_prev=found` (the check read that word) and would have cost a panic record its
header, so the region now starts at `0x30100000` and the check reads the console
zone's header instead. The board's own capture, replayed through the 2022.07 sandbox at
the new address, came back byte-identical with `edge1_prev=found`.

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
And an NVMe install needs **our** U-Boot somewhere ahead of it — Armbian's 2022.07 has
no NVMe support at all, so its distro boot never looks there. The installer says so.

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

6. **"The boot script works."** It did — on the U-Boot it was tested on, the current
   release. The board's is 2022.07 without `setexpr`, and the script declined silently
   (above). Since then the script is checked against the 2022.07 command set at build
   time and was run on a 2022.07 sandbox, and it leaves `edge1-boot.log` behind, so the
   next failure on the board says where it happened.
