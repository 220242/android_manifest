# Status

Where the port is, what is still open, and the decisions worth not re-deriving.

## Where the build is

**`m` completes, and the card is built to boot on this board as it is.** Nothing has
booted Android yet.

Five cards went onto the hardware before this, and all five booted the Armbian on the
eMMC. For the first four the reason was the RK3399 BootROM's order — SPI NOR, then eMMC,
then SD card — which means a bootloader on the card never runs while the eMMC holds one.
The card now carries a FAT as partition 1 with a `boot.scr` that the eMMC's own U-Boot
finds and runs. On the fifth card that script did run, and declined: it used `setexpr`,
which Armbian's U-Boot 2022.07 is not built with. It now loads `Image`, `ramdisk.img`
and `edge1.dtb` as files with commands that U-Boot has, was run on a U-Boot 2022.07
sandbox with this board's command set and distro-boot environment, and writes
`edge1-boot.log` to the card at every attempt. [`BOOT.md`](BOOT.md) has the mechanism,
the sources and how to read the log and the LED.

On the way, three things turned up that would have stopped Android even with the
bootloader solved, none visible from the build's own output: no
`androidboot.boot_devices` (first-stage init would find no partitions), no verified-boot
state (the `avb` mounts would refuse), and a U-Boot `bootcmd` whose card → eMMC → NVMe
fallback could never run (its hush does not do `a && b || c`). All three are fixed and
guarded by `verify-tree.sh`.

| Stage | State |
|---|---|
| `repo sync` (AOSP `android-14.0.0_r75` + mainline 6.12.111) | works |
| Kernel: `Image`, `rk3399-khadas-edge-v.dtb` | builds, every fragment symbol verified to take; the staged dtb marks `sys_led` as panic indicator |
| `lunch edge1_tv-trunk_staging-userdebug`, product config | works |
| Soong, Kati, compile (167136 targets first run) | works |
| sepolicy, VINTF, `build.prop` | pass / generated (VINTF at `target-level="7"`) |
| `boot.img`, `recovery.img`, `vbmeta.img`, `super.img` (raw, not sparse) | build |
| Kernel command line | now carries `verifiedbootstate=orange`; userdebug adds `console=tty0`, `init_fatal_panic`, `selinux=permissive`. Needs a rebuild to reach `boot.img` |
| `bootfs.img` (partition 1: `boot.scr` + `Image`/`ramdisk.img`/`edge1.dtb` for the eMMC's U-Boot) | 128MiB; script limited to 2022.07's commands (checked at build time) and run through distro boot on a v2022.07 sandbox: files byte-exact, `bootargs` right, log written, fallback to the eMMC intact. **On the board: reached `booti`** (`edge1-boot.log`). Now also saves the previous kernel's ramoops region as `edge1-pstore.bin` |
| U-Boot (mainline v2026.07) | builds; `bootcmd` rewritten with per-medium `boot_devices` and `;`-joined attempts, tested in the sandbox. **Never run on this board** — see TST mode in `BOOT.md` |
| Images: `edge1-sdcard.img`, `edge1-emmc.img`, `edge1-nvme.img` | build, now with `bootfs` first |
| On-device installer (card → eMMC or NVMe) | keeps the eMMC's bootloader unless the card's own U-Boot started the system; never run on hardware |
| Flash pack (`edge1-flash/` + `flash-emmc.sh`) | superseded by the installer, never run |

### What the hardware attempts established

Measured on the board — [`HARDWARE.md`](HARDWARE.md) has the readings:

* SPI NOR is erased; the eMMC and each card carry a valid Rockchip ID block at sector 64,
  and the FIT sits at sector 16384 as intended. The card's bootloader was correct and was
  simply never run.
* The U-Boot that handed off to the kernel was `2022.07-armbian` every time, with every
  variant of the card in the slot.
* The controllers are `fe320000.mmc` (card) and `fe330000.mmc` (eMMC) — the names
  `androidboot.boot_devices` needs.
* **The boot script works on Armbian's U-Boot.** The sixth card's `edge1-boot.log` read
  `edge1_stage=booti` from `mmc 1:1`: all three files loaded and the kernel was started.
* **Our kernel boots, and HDMI works.** The seventh card showed the kernel log on the
  screen through fbcon, reached `Run /init as init process`, and first-stage init died at
  its selinuxfs mount: SELinux was built but not in `CONFIG_LSM` (`KERNEL.md`, "The LSM
  list"). Fixed. The whole log came back in `edge1-pstore.bin` — RAM survives the warm
  reset, so every failed boot from now on reports itself.
* **First-stage init runs.** Card eight: `lsm=capability,selinux`, selinuxfs mounted,
  init read `/fstab.edge1` from the ramdisk and stopped at `Missing vbmeta partitions`:
  the fstab said a bare `avb`, and first-stage init only learns which partition holds
  vbmeta from `avb=<partition>` (or the DT). Now `avb=vbmeta`, guarded by `verify-tree`.
  Found while reading ahead, before the board could hit them: the kernel fragment set
  `CONFIG_ANDROID_BINDER_DEVICES=""`, which would have left `/dev/binder` dangling, and
  arm64 defconfig leaves IPv6, iptables and conntrack as modules netd cannot use. The
  fragment now carries Android's own base requirements (`KERNEL.md`), every line checked
  to take on 6.12.
* **Second-stage init runs.** Card nine: AVB passed, super's five logical partitions
  mounted, the SELinux policy loaded, ueventd, apexd, servicemanager, logd, vold, KeyMint
  and keystore2 all started — and `edge1-pstore.bin` brought back logcat as well as the
  kernel log. Then keystore2 aborted (`unable to open database:
  /data/misc/keystore/persistent.sqlite`) and apexd rebooted the board (`apexd-failed`):
  nothing had mounted `/data`, because `init.edge1.rc` never ran `mount_all`. It does
  now, `--early` on `fs` and `--late` on `late-fs`, guarded by `verify-tree`. Same log:
  Android's cpuset cgroup is v1, mounted as filesystem type `cpuset`, which 6.12 builds
  only with `CPUSETS_V1` (added); init's own log lines were being rate-limited away
  (`printk.devkmsg=on` on userdebug now); and `ro.hdmi.cec.source.send_standby_on_sleep`
  is an enum (`to_tv`), not a boolean.
* **Known next: Wi-Fi.** brcmfmac is built in, so it asks for
  `brcm/brcmfmac4359-sdio.bin` 1.8s into boot, long before `/vendor` is mounted, and
  gets -2. Armbian loads it as a module, after its rootfs is up. Not a boot blocker;
  the fix is to re-probe the SDIO host from init once `/vendor` is there.

What they did not establish, because none of the card's code ever ran: whether our U-Boot,
our TPL's DDR init, or our SPL work on this board. The DDR-blob A/B, the SPL boot-order
change and the environment change all tested code that never executed. Those changes
stay, because each is right for when our U-Boot does run; the account of how the
diagnosis went wrong is at the end of `BOOT.md`.

### super.img, twice

**It is opt-in.** The first build to get all the way through reported success and then
`build.sh` said:

```
expected .../out/target/product/edge/super.img was not produced
```

Both statements were true. `core/Makefile:7307-7315` hangs `super.img` off
`droidcore-unbundled` **only** when `BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT` is true;
otherwise it is built by an explicit `m superimage` or for a dist build. What `droid`
builds unconditionally is `super_empty.img` — the partition metadata with no contents
— because the normal path is fastboot writing that and then flashing each logical
partition individually.

This device is not on that path: both writers here `dd` `super.img` into the super
partition, which is exactly the case the flag exists for. `verify-tree.sh` check 3b
now requires the two to agree — if `partitions.tsv` names `super.img`, BoardConfig
has to build one.

**And then it was sparse, which is worse.** With the flag set the next build produced
one, and the log showed how:

```
lpmake --metadata-size 65536 --super-name super ... --sparse
       --output out/target/product/edge/super.img
```

An Android sparse image is a container, not a filesystem: a 28-byte header with magic
`0xed26ff3a`, then chunks that each say which output blocks they hold.
`tools/releasetools/build_super_image.py:136-137` adds `--sparse` unless
`build_non_sparse_super_partition` is set, and it was not.

Written into a partition verbatim, it is 4.6GiB of the wrong bytes. There is no ext4
superblock where the kernel looks for one and no super metadata where `libdm` looks,
so first-stage init fails to mount `/system` and says nothing about why. Every check
that could have caught it passed: the build succeeded, the file existed, and it was
well under its partition size — it is a fraction of the size of what it expands to,
which is the same fact from the other side.

`core/Makefile:6145-6148` is the only place that sets
`build_non_sparse_super_partition`, and it takes it from
`TARGET_USERIMAGES_SPARSE_EXT_DISABLED` or its f2fs twin. So the fix is one line in
`BoardConfig.mk`, and it is the line AOSP's own GSI targets carry
(`target/board/BoardConfigGsiCommon.mk:19`). It turns the logical partitions' images
raw on the way in too, which costs apparent size in `out/` and nothing else — they are
`lpmake`'s inputs and end up inside super either way.

Three things now hold it:

* `build-images.sh` reads the first four bytes of every image it writes and expands a
  sparse one with `simg2img` rather than copying it through. `build.sh` names
  `simg2img` as a build target for this, because it is otherwise built only as part of
  `otatools` (`core/Makefile:5561`).
* The generated `flash-emmc.sh` carries the same check.
* `verify-tree.sh` check 3d requires the BoardConfig setting *and* the guard in both
  writers, so losing either is a static error.

The size check moved too. It used to measure the file in `out/`; it now measures what
will actually be written, which is the expanded image. A 12KB sparse file that expands
to 2GiB passed the old check and is rejected by the new one.

### Three media, and what the silicon decides

The install targets are the SD card, the eMMC and an M.2 NVMe. One layout —
`flash/partitions.tsv` — covers all three; only the total size and the bootloader
differ. Two facts shape the whole story, and both come from the SoC rather than from
preference:

**The BootROM cannot boot from PCIe.** Its boot sources are the enum in U-Boot's
`arch/arm/include/asm/arch-rockchip/bootrom.h:47-59`: NAND, eMMC, SPI NOR, SPI NAND,
SD, UFS, I2C, SPI, USB. So nothing on an M.2 card can ever be the first thing that
runs, `edge1-nvme.img` has no bootloader, and an SSD install always leaves U-Boot on
the eMMC or the card. There is no configuration that changes this.

**mmc0 is the eMMC and mmc1 is the SD slot.** `arch/arm/dts/rk3399-u-boot.dtsi`
aliases them that way, and `arch/arm/mach-rockchip/rk3399/rk3399.c:27-31` gives the
same mapping from the BootROM's side — eMMC at `mmc@fe330000`, SD at `mmc@fe320000`.
The installer uses the controller address rather than the `mmcblk` number for exactly
this reason: `mmcblk2` is probe order, `fe330000` is the board.

From those two, the boot order follows: **card, then eMMC, then NVMe**, instantiated
three times in one `CONFIG_BOOTCOMMAND`. `part start` fails when there is no such
partition, and that failure is what moves to the next medium — which is why
`CONFIG_HUSH_PARSER` is in the fragment; without `&&` and `||` there is no fallback
and a missing card is a dead board.

Putting the card first is still the most useful property of our `bootcmd`: whichever
medium the BootROM loaded our U-Boot from, a card with an Android boot partition takes
over. But this paragraph used to add that the port "does not depend on knowing the
BootROM's own preference between SD and eMMC". It did depend on it, completely: the
BootROM prefers the eMMC, so with anything on the eMMC our U-Boot does not run at all.
The card boots on such a board only because partition 1 carries a script the eMMC's
U-Boot runs. [`BOOT.md`](BOOT.md).

The `||` that joined the three attempts was also wrong, differently: U-Boot's hush skips
`||` branches when the `&&` side fails, so the fallback never ran. The attempts are now
separated with `;`.

`CONFIG_NVME_PCI`, `CONFIG_PCI`, `CONFIG_CMD_NVME` and `CONFIG_CMD_USB_MASS_STORAGE`
all turned out to be in the Edge-V defconfig already, so the third medium and the
`ums 0 mmc 0` escape hatch cost no configuration at all.

### The 9.6MB bootloader, and why seek=64

`u-boot-rockchip.bin` is about 9.6MB, not the ~1MB the two stages in it add up to, and
that is correct. It is one blob with idbloader (the rksd header, TPL and SPL) at offset
0 and `u-boot.itb` at `CONFIG_SPL_PAD_TO` — `arch/arm/dts/rockchip-u-boot.dtsi:166-195`,
the `simple-bin` image node. Most of the file is the pad between the two.

The numbers close exactly, which is the whole reason `seek=64` is the documented value:

| | |
|---|---|
| `CONFIG_SPL_PAD_TO` | `0x7f8000` = 16320 sectors (`common/spl/Kconfig:91`, the ARCH_ROCKCHIP default) |
| written at | sector 64 |
| so the FIT lands at | 64 + 16320 = **16384** |
| `CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR` | `0x4000` = **16384** (`common/spl/Kconfig:590`) |

Nothing in the build makes those agree, so `build-uboot.sh` now does the arithmetic and
refuses on a mismatch. If either default ever moves, the image builder would write a
bootloader whose second stage is some sectors off, SPL would find no FIT, and the board
would stop before there is any console to say so — and the blob would still be present
and the right size. `verify-tree` check 3e keeps the 64 the same in all three files that
name it, `build-uboot.sh` included, since verifying against one number while writing at
another would pass and still not boot.

### What the Khadas U-Boot fork has for this board

Nothing, as it turns out, and that is worth recording so it is not re-investigated.

`github.com/khadas/u-boot` has 35 branches. Every one that concerns the Edge or the
RK3399 is **U-Boot 2017.09** — Rockchip's BSP fork — including branches with 2024 dates
in their names (`khadas-edges-6.1.y-v1.1.1_20240920` is 2017.09). `khadas-edge2-*` is a
different SoC: Edge2 is RK3588S.

Two things rule those out as a bootloader for this port:

* **No board defconfig exists in them.** The 2017.09 branches carry only the generic
  `rk3399_defconfig` and `evb-rk3399_defconfig`. There is no Edge-tuned configuration
  to mine.
* **Different packaging.** They build through their own `make.sh` into
  `idbloader.img` + `uboot.img` + `trust.img` at Rockchip's offsets, needing rkbin's
  miniloader. That is not the single `u-boot-rockchip.bin` at sector 64 that binman
  produces and that `flash/partitions.tsv` reserves space for, so substituting one is
  a second port rather than a swap.

The one modern branch, `khadas-u-boot-v2024.07`, does carry
`khadas-edge-v-rk3399_defconfig`. Diffed against upstream v2026.07 it comes to three
lines, and only two are real:

| | |
|---|---|
| `CONFIG_SPL_PAD_TO=0x7f8000` | the same value upstream's Kconfig default already gives. **Taken** — pinned in the fragment, because it is half of the `seek=64` arithmetic and pinning it means the check can only fail if the other half moves. |
| `CONFIG_ROCKCHIP_IODOMAIN=y` | `default y if ROCKCHIP_RK3399` upstream, so it should come for free — but it `depends on DM_REGULATOR`. **Reported** by `build-uboot.sh`, not asserted. |
| `CONFIG_SYS_RELOC_GD_ENV_ADDR` vs `CONFIG_ENV_RELOC_GD_ENV_ADDR` | a rename between versions. Nothing. |

And their `rk3399-khadas-edge-v-u-boot.dtsi` and `rk3399-khadas-edge-u-boot.dtsi` are
**byte-identical** to upstream's. Upstream already has everything Khadas has for this
board.

The IODOMAIN line is the only one with a story. The board DTS carries
`&io_domains { ... sdmmc-supply = <&vccio_sd>; status = "okay"; }`
(`dts/upstream/src/arm64/rockchip/rk3399-khadas-edge.dtsi:568-574`) — the SD card's IO
voltage domain, on a board whose whole install path is an SD card. Which is why
`build-uboot.sh` now reports it rather than assuming it.

**Building several cards with different bootloaders to try in turn is not the cheap
experiment it looks like.** Without a serial console a failed boot yields one bit, and
if every card fails it does not say whether the bootloader, `boot.img`, the dtb or the
kernel is at fault. The A/B that is worth running is two *mainline* tags, which is
`EDGE1_UBOOT_REV=v2025.07 build-uboot.sh` plus
`EDGE1_IMAGE_TAG=v2025.07 build-images.sh ... sdcard` — same packaging, same scripts,
two files side by side. A console is worth more than any number of variants.

### What Armbian has for this board

Armbian is mainline-based, so unlike the Khadas fork its work is portable here. Checked
`armbian/build@main`, and it is worth recording both what it confirms and what it does
not have.

**It independently corroborates every substantive bootloader choice.**
`config/boards/khadas-edge.csc` and `config/sources/families/include/rockchip64_common.inc`
give:

| | Armbian | here |
|---|---|---|
| defconfig | `BOOTCONFIG="khadas-edge-v-rk3399_defconfig"` | the same |
| BL31 | `rk3399_bl31_v1.35.elf` | the same file our search picks |
| DDR init | `BOOT_SCENARIO="tpl-spl-blob"` → `BL31=<blob>` and no `ROCKCHIP_TPL` | the same: U-Boot's own TPL |

That third row is the one that could have gone either way. `rockchip64_common.inc` does
pass `ROCKCHIP_TPL=<rkbin DDR blob>` — but only in its `binman` and `vendor-spl-blobs`
scenarios, which other SoCs use. The Edge's `tpl-spl-blob` passes `BL31=` alone, so
Armbian relies on U-Boot's own TPL for DDR bring-up on this board, exactly as this tree
does.

Their packaging differs and agrees anyway: they emit `idbloader.img` and `u-boot.itb`
separately and write them at sectors 64 and 16384, where we write binman's single
`u-boot-rockchip.bin` at sector 64. Those are the same bytes in the same places — an
independent check of the `SPL_PAD_TO` arithmetic above.

Caveat on authority: the board file is `.csc` with `BOARD_MAINTAINER=""`, which in
Armbian's taxonomy is community-supported and currently unmaintained.

**It has no Edge or RK3399 board patches at all.** Every `khadas-edge` hit in Armbian's
whole patch tree is `khadas-edge2`, which is RK3588 — a different SoC. So Armbian runs
this board on bare upstream DTS, the same as this tree.

**What it does have is a shortlist of SoC-wide rk3399 patches**, and
`patch/kernel/archive/rockchip64-6.12/` is the same kernel series we build. None of them
is needed to boot, and this tree has no kernel patch mechanism at all — adding one is a
small change to `build-kernel.sh` if a symptom ever calls for it. Kept here as a
symptom-to-patch map rather than applied, because adding an unnecessary DTS change
before the first boot adds a variable to the one attempt that matters:

| Symptom | Patch | What it does |
|---|---|---|
| SD card unreliable at speed, read errors under load | `rk3399-sd-drive-level-8ma.patch` | raises `sdmmc` bus pins to `pull_up_8ma` and clk to `pull_none_12ma` in `rk3399-base.dtsi`. In Armbian since 2019. The most relevant one, since the whole install path is a card. |
| USB-C/adb does not enumerate | `rk3399-fix-usb-phy.patch` | one line: longer Type-C PHY init timeout in `phy-rockchip-typec.c` |
| NVMe not detected, PCIe link does not train | `rk3399-fix-pci-phy.patch`, `rk3399-fix-pci-lanes.patch` | PHY reset on probe, and not disabling `PHY_LANE_IDLE_OFF` per lane, in `phy-rockchip-pcie.c` |
| Thermal throttling too early | `rk3399-unlock-temperature.patch` | raises trip points in the DTS |

Two others exist and do not apply: `rk3399-add-sclk-i2sout-src-clock.patch` is for the
rt5651 codec on an OrangePi (we use HDMI audio), and `rk3399-sd-pwr-pinctrl.patch` only
*defines* an `sdmmc_pwr` pinctrl group that nothing on this board references.

### Why the installer rather than the eMMC and NVMe images

Neither the eMMC nor the SSD is removable, so only something already running on the
board can write them. `edge1-install-internal.sh` ships inside the image it installs
and copies the running card partition by partition — the card already holds every
image byte for byte in its own partitions, so there is nothing to carry and nothing
to unpack.

It also partitions the target to its **real** size, which the fixed images cannot:
`userdata` gets all of a 128GB SSD instead of the 14GiB `edge1-nvme.img` was built
for. The two image files remain useful for the other route — `ums 0 mmc 0` from the
U-Boot prompt exposes the target as a USB disk and Etcher writes it — which needs a
serial console but no Android.

It does not replace a working bootloader with an untried one. On this board the Android
it runs from was started by the eMMC's U-Boot through `bootfs`, so the card's U-Boot has
never run here; copying it onto the eMMC would swap a known-good bootloader for an
unknown one on the medium that is hardest to recover. The installer reads
`/proc/device-tree/chosen/u-boot,version` and copies the card's bootloader only if that
is the U-Boot that started the system; otherwise it leaves the eMMC's in place, and that
U-Boot boots the installed Android through the eMMC's own `bootfs`.

The offsets are the part that had to be right, since a wrong one puts `super` where
nothing looks for it. They are checked against the layout's own arithmetic, in a
sandbox with `sgdisk` and `dd` stubbed to log rather than write: the partition
starts and the `dd` offsets all match, and they match what the generated
`flash-emmc.sh` produces. That test also caught the installer's one real bug —
`grep -c ... || echo 0` prints `0` **and** exits 1 when nothing matches, so the count
read `0\n0`, the "something is mounted" check fired on every run, and no install
could ever have started.

## The approach

Two routes to Android 14 on this board were on the table. This is the second, taken
after the first had been built far enough to price it.

**Abandoned: Khadas' 4.19 BSP kernel plus the Rockchip Android 10 userspace.** The
kernel built. Everything above it would have had to be forward-ported — the Mali
blob's gralloc integration above all, the largest single unknown in the port — and
none of that work is reusable anywhere else.

**Current: mainline 6.12 LTS plus AOSP's own userspace for it.**

| | driver | userspace, already in AOSP 14 |
|---|---|---|
| GPU | `drivers/gpu/drm/panfrost` | `external/mesa3d` → `libGLES_mesa` |
| Display | `drivers/gpu/drm/rockchip` | `external/drm_hwcomposer` + minigbm |
| Decode | `staging/media/rkvdec` (H.264 only) | `external/v4l2_codec2` |
| Wi-Fi | `brcmfmac` over SDIO | AOSP `wpa_supplicant` |
| Audio | `simple-audio-card` → HDMI | AOSP AIDL audio HAL over ALSA |
| Boot | mainline U-Boot + TF-A, or the eMMC's own U-Boot via `boot.scr` | ordinary GPT, Android boot image v2 |

No proprietary blob is involved. What made this credible rather than hopeful is
that the board is already proven on this kernel: it runs OpenWrt with Linux 6.12.94
and mainline U-Boot (`github.com/220242/khadas_edge-openwrt`), which is also where
the Wi-Fi firmware and board NVRAM in `device/khadas/edge/wifi/firmware/brcm` come
from.

The fact that forced the decision either way: **AOSP 14 ships no software GLES
driver a real device can load.** `libGLES_android` was removed years ago and
swiftshader is packaged for the emulator's host side — the tree defines no
`libEGL_swiftshader`. Without a driver SurfaceFlinger does not start, so "boot
first, GPU later" was never available. panfrost supplies one without a blob; the
Mali blob would have had to be bridged to an IMapper it was never written for.

What the graphics stack costs, stated plainly: minigbm's rockchip backend does not
implement the RK3399's AFBC layouts, so composition moves more bytes than
Rockchip's own gralloc did.

## What is still open

1. **The first boot of Android.** Rebuild (the command line and sepolicy changed, so
   `Build` re-runs), write the card, power on with the eMMC as it is. On a userdebug
   build the kernel log is on HDMI and an init failure stays on screen; `BOOT.md` has
   what each stage looks like.
2. **Our own U-Boot has never run on this board.** It runs only from an empty eMMC, in
   TST mode, or from SPI NOR. TST mode with the card in is the test; the
   `U-Boot 2026.07` banner on HDMI is the pass. Nothing should write our U-Boot to the
   eMMC or SPI NOR before that — which is why the installer keeps the eMMC's bootloader.
3. **Verified boot is `orange`.** No bootloader in the chain computes a vbmeta digest,
   so the device declares itself unlocked; dm-verity still runs. Lifting that for a
   `user` build means `CONFIG_AVB_VERIFY` and `avb verify` in U-Boot, and a bootfs
   script that does the same or is retired in favour of our U-Boot in SPI NOR.
4. **SELinux is permissive on userdebug.** Deliberately, for the first boot: the denials
   are logged and can be collected with `adb shell dmesg | grep avc` and fixed. The
   boot medium's partitions are now labelled; nothing else in the policy has met a
   running system yet.
5. **Hardware video decode is not wired up.** `CONFIG_VIDEO_ROCKCHIP_VDEC` is in the
   kernel and `external/v4l2_codec2` is in the tree, with
   `android.hardware.media.c2@1.2-service-v4l2` available — but it is not in
   `PRODUCT_PACKAGES`, and it needs a codec2 store config and a `media_codecs_c2.xml`
   beside it. Until then the software codecs carry playback: 1080p yes, 4K no.
   6.12's rkvdec is H.264 only in any case, so HEVC and VP9 stay in software regardless.
6. **Bluetooth is unresolved.** Measured on the board: there is no `/dev/ttyS0` —
   `ttyS1` through `ttyS7` exist and uart0 is not presented as a tty. The firmware name
   is `BCM4359C0.hcd`, which this tree does not ship. See [`HARDWARE.md`](HARDWARE.md).
7. **The device targets FCM level 7, not 8.** Forced rather than chosen — see below.
   The vendor image's HAL surface is Android-13-era.
8. **Codec performance numbers are placeholders.** `media/media_codecs_performance.xml`
   holds datasheet ceilings, not measurements from this board.
9. **ART's userfaultfd GC is off for the first boot.** 6.12 supports it and the board
   qualifies; it stays off so the one attempt that matters has one variable fewer. Flip
   `PRODUCT_ENABLE_UFFD_GC` to `true` once the device boots.
10. **`/dev/dri/card1` is not labelled by our `file_contexts`.** It is panfrost's primary
    node. AOSP is believed to carry a generic `/dev/dri/card[0-9]*` spec that covers it;
    the probe should settle it. `kmsro` in `BOARD_GPU_DRIVERS` is confirmed valid and is
    the right shape for this `card0` (display) / `card1` (GPU) split.
11. **The M.2 slot is empty**, so `edge1-nvme.img`, the installer's `nvme` target and the
    `f8000000.pcie` boot device cannot be tested yet.
12. **SPI NOR is empty and unused.** Our U-Boot there would make the board independent
    of what is on the eMMC. After item 2.

## Honest expectation

If it boots, it boots to a leanback launcher over HDMI with Ethernet and Wi-Fi.
It will not pass CTS, and that is structural rather than a matter of finishing:
software KeyMint rules out hardware key attestation (see `HAL_MIGRATION.md`),
`PRODUCT_SHIPPING_API_LEVEL` is 29 — correct for an upgrade device, not for
certification as a 14 device — and DRM is clearkey only, so licensed HD streaming
will not work. If certified streaming was the goal, mainline Linux with Kodi on the
same board is the right vehicle and this is not.

## Decisions taken against the real build system

Each of these was wrong in the tree before it was read out of `android-14.0.0_r75`
rather than recalled. They are listed because the reasoning is what does not
survive in a diff.

| Setting | Why |
|---|---|
| `lunch edge1_tv-trunk_staging-userdebug` | 14's `lunch` requires three parts and rejects two outright (`build/envsetup.sh:809-820`). The two-part form never starts a build. |
| `set +eu` around `envsetup.sh` | `envsetup.sh:21` reads `$TOP` before anything sets it; under `set -u` that ended the run before `m`. |
| `PRODUCT_USE_DYNAMIC_PARTITIONS` in the product makefile | Product config runs first and freezes the product variables, so assigning it in `BoardConfig.mk` is `cannot assign to readonly variable`. |
| No `BOARD_SEPOLICY_VERS`, no `<sepolicy>` in the VINTF manifest | `core/config.mk` derives it from `PLATFORM_SEPOLICY_VERSION` (202404) and freezes it, and `assemble_vintf` refuses to override a value the input manifest already carries. Setting it by hand was silently overwritten in one place and fatal in the other. |
| `PRODUCT_COPY_FILES` for the kernel `Image`, not `TARGET_PREBUILT_KERNEL` | The string `PREBUILT_KERNEL` appears nowhere in AOSP 14's `build/make`. `core/Makefile:1018` defines `INSTALLED_KERNEL_TARGET` as `$(PRODUCT_OUT)/kernel` and leaves producing it to the device. |
| `BOARD_BOOT_HEADER_VERSION := 2`, no `vendor_boot` | With a vendor_boot the kernel command line and the dtb move out of `boot.img` into `vendor_boot` (`core/Makefile:1600-1614`), where a bootloader that reads only `boot.img` never looks. See below. |
| `BOARD_USES_FULL_RECOVERY_IMAGE := true`, no `BOARD_INCLUDE_RECOVERY_DTBO` | Boot header v2 and up have no `recovery_dtbo` field worth using here; the flag handed mkbootimg an argument it cannot place. |
| Four AVB recovery variables | `core/Makefile:4460` errors with `BOARD_AVB_RECOVERY_KEY_PATH must be defined` on a non-A/B device with AVB: a discrete recovery image has to be self-signed. |
| `BOARD_GPU_DRIVERS := panfrost kmsro`, not `BOARD_MESA3D_GALLIUM_DRIVERS` | The only mention of `BOARD_MESA3D_*` in the tree is dragonboard's own makefiles, which drive meson themselves. `external/mesa3d/Android.mk` reads `BOARD_GPU_DRIVERS`: `MESA_BUILD_GALLIUM := $(strip $(foreach d, $(BOARD_GPU_DRIVERS), ...))`. |
| `PRODUCT_SOONG_NAMESPACES += external/mesa3d` | Mesa refuses to build without it — `external/mesa3d must be in PRODUCT_SOONG_NAMESPACES`, its `Android.mk:41`. |
| `libGLES_mesa` and `libglapi`, not the six packages dragonboard lists | Nothing in the tree defines `libEGL_mesa`, `libGLESv1_CM_mesa`, `libGLESv2_mesa` or `libgallium_dri`; those names come from the newer meson-based packaging. The EGL loader takes `libGLES_<name>.so` as a complete driver and only falls back to the triplet when it is absent. |
| Four `PRODUCT_*` variables deleted | `PRODUCT_BUILD_PROP_OVERRIDES`, `PRODUCT_HAS_CAMERA`, `PRODUCT_HAVE_OPTEE`, `PRODUCT_TARGET_VNDK_VERSION` appear nowhere in AOSP 14. They were read by `device/rockchip/common`, which this tree does not have, so they were decoration that read like configuration. |
| No `ro.product.first_api_level`, `ro.product.board`, `ro.board.platform` or `ro.sf.lcd_density` set by hand | `core/main.mk:284,332-341` emits all four from product and board variables. Setting one as well produces two assignments in the same `build.prop`, which `post_process_props.py` rejects unless the values happen to be identical. |
| `TARGET_USERIMAGES_SPARSE_EXT_DISABLED := true` | The only switch that makes `lpmake` drop `--sparse` (`core/Makefile:6145-6148` → `build_super_image.py:136`). A sparse `super.img` is a container, not a filesystem, and `dd`ing one leaves a partition with no superblock and no log. |
| `m droid simg2img` rather than `m` | `simg2img` is built only as part of `otatools` (`core/Makefile:5561`), and `build-images.sh` needs it if an image is ever sparse again. An unknown target fails at the end of the ninja parse, in seconds. |
| `CCACHE_DIR=$TREE/out/ccache` | 14 runs ninja with everything outside `$OUT_DIR` bind-mounted read-only, so ccache's default `$HOME/.cache/ccache` is on the wrong side and the first real compile died at target 151 of 167136. The build's own error text names the fix: generate into `out/`. |

Also checked and found clean: none of the 69 `KATI_obsolete_var` names are used
anywhere in the device tree, and the dynamic-partition group naming matches what
`core/config.mk` derives.

## One failure shape, seven times

Seven build failures were variations of one mistake: the tree claims something the
platform does not agree with, and the tool that objects reports one instance per run.
Each now has a gate in the module probe (`build/windows/provision-wsl.sh`, `stage_probe`),
which runs before the build and takes about a minute.

The two rows that say *nothing* are a different and worse shape: there is no error to
gate on, so the only defence is a static check that knows what the build will not say.

| What | The build says | When |
|---|---|---|
| Module in `PRODUCT_PACKAGES` does not exist | nothing — it is dropped silently, unless `PRODUCT_ENFORCE_PACKAGES_EXIST` is set (`core/main.mk:1341`) | never |
| `super.img` in Android sparse format | nothing — the build's job is to produce the image, not to know how it is written | never |
| sepolicy type declared here and in `system/sepolicy` | `checkpolicy`: `Duplicate declaration of type` | ~6 min |
| `file_contexts` specification declared twice | `checkfc`: `Multiple same specifications for ...` | ~9 min |
| Property the build derives from a variable | `post_process_props.py`: `found duplicate sysprop assignments` | ~9 min |
| Property `exact` match labelled twice | `host_init_verifier`: `Duplicate exact match detected` | ~20 min |
| HAL declared at an FCM level that does not list it | `check_vintf`: `INCOMPATIBLE` | ~15 min |
| Device matrix requiring a VNDK version | `check_vintf`: `Vndk version 34 is not supported` | ~10 min |

Two of those are worth spelling out because the rule is not the obvious one:

* **`checkfc` rejects the identical regex, not an overlapping path.** Two different
  regexes matching one path is normal and the most specific wins, which is why
  `/dev/dri/card0` sits happily beside AOSP's `/dev/dri/card[0-9]*`. Only
  `/dev/video[0-9]*` copied verbatim was fatal.
* **An allowed prefix is not the same as a free name.** `check_prop_prefix` rejected
  a `sys.hwc.` label because a vendor partition may only own `vendor.`, `odm.`,
  `ro.vendor.`, `ro.odm.`, `ro.hardware.`, `ro.boot.`, `persist.vendor.`,
  `persist.odm.`, `persist.camera.`, the `ctl.` and `init.svc.` forms of the first
  two. The five `ro.hardware.*` labels that replaced it were inside those prefixes
  and still failed, because the platform labels those five properties already — the
  code that reads them is platform code.

`verify-tree.sh` covers the offline half of each of these with a hand-kept list of
what the platform declares. The probe resolves the same questions against the
synced tree, which is the authoritative answer, and gates on it.

## FCM level 7, because the composer is HIDL

`check_vintf_all` runs when `PRODUCT_ENFORCE_VINTF_MANIFEST` is true, which it is in
this build, and it called the device INCOMPATIBLE:

```
The following instances are in the device manifest but not specified in
framework compatibility matrix:
    android.hardware.cas@1.2::IMediaCasService/default
    android.hardware.graphics.composer@2.4::IComposer/default
```

Both HALs are real and both are provided. What changed at level 8 is that the
framework stopped listing their HIDL versions — read out of the matrices in the
synced tree:

| | level 7 | level 8 |
|---|---|---|
| `android.hardware.cas` | hidl 1.1-2 | aidl only |
| `android.hardware.graphics.composer` | hidl 2.1-4 | — |
| `android.hardware.graphics.composer3` | aidl 1 | aidl 2 |

Neither instance is something to remove. The composer is HIDL because AOSP 14's
drm_hwcomposer snapshot is HWC2 only, and the HIDL cas service is installed by AOSP
itself: `base_vendor.mk:90` puts `android.hardware.cas@1.2-service` in
`PRODUCT_PACKAGES_SHIPPING_API_LEVEL_33`, and this device ships at API 29. AOSP's own
configuration assumes a device like this one sits below level 8.

So `target-level` is 7. That is permitted because this is an upgrade device rather
than a launch device — an upgrade device keeps the FCM level it launched with and may
raise it, and API 29 is level 4, so 7 is already a raise. The floor in practice is 5,
the oldest matrix AOSP 14 still installs. The honest reading is that the vendor image
is Android-13-era in its HAL surface, and level 7 says so.

The probe now answers this before the build: it reads `target-level` and each
declared HAL out of `vintf/manifest.xml`, checks them against the matrix at that
level, and fails the run naming the ones that are not accepted. It covers the device
manifest's own entries only — instances that arrive with an installed service's VINTF
fragment, like the cas one, are not visible without a built image — so it narrows
`check_vintf` rather than replacing it.

## VNDK, deprecated in silence

With the FCM levels agreed, `check_vintf` moved on to the next line of the same
file:

```
All HALs in device manifest are declared in FCM <= level 7
ERROR: files are incompatible: Framework manifest and device compatibility
matrix are incompatible: Vndk version 34 is not supported. Supported versions
in framework manifest are: []
```

An empty list, not a mismatched number. VNDK is deprecated in this release, and AOSP
wires that up in two steps neither of which says anything:

* `core/envsetup.mk:53-58` — `KEEP_VNDK` defaults to **false** when the release
  config sets `RELEASE_DEPRECATE_VNDK`, and true otherwise.
* `core/config.mk:1266-1273` — when `KEEP_VNDK` is not true, `BOARD_VNDK_VERSION`
  and `PLATFORM_VNDK_VERSION` are assigned empty. No warning, no error.

So `BOARD_VNDK_VERSION := current` in `BoardConfig.mk` was discarded before anything
read it, the framework manifest listed no versions at all, and the device
compatibility matrix was requiring something that no longer exists. Both are gone.
Nothing replaces them: if a future release keeps VNDK, `envsetup.mk:64` sets
`BOARD_VNDK_VERSION := current` itself when the board has not — the same value that
line used to state.

The device matrix now requires nothing, which is correct rather than lazy: nothing on
the vendor side of this board calls into a framework HAL, because every HAL here is
an AOSP one talking to a mainline driver.

Writing the gate for this reproduced the kernel-fragment trap exactly. A
`grep -c '<vendor-ndk>'` over the matrix counted the explanation in that file's own
comment and reported a requirement on a clean tree. The gate parses the XML instead,
since ElementTree does not see comments — and the test that caught it was the one
that checked the *passing* case, not the failing one.

## The one check that is disabled rather than satisfied

Everything else in this tree was made to pass. This one cannot be:

```
Runtime info and framework compatibility matrix are incompatible: No kernel
entry found for kernel version 6.12 at kernel FCM version 7. The following
kernel requirements are checked:
  Minimum LTS: 5.10.107 ... 5.15.41 ... 6.1.0 ... 6.6.0
```

Read what it lists. Those are minimums, and 6.12.111 is above every one of them. The
failure is not that the kernel is too old — it is that libvintf matches the LTS
*branch* exactly, the matrices in this release carry `<kernel>` rows for 5.10, 5.15,
6.1 and 6.6, and 6.12 LTS did not exist when Android 14 was cut. There is no row to
match and no mechanism for a device to add one.

So `PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false`, which is AOSP's own
remedy — option (4) in the warning it prints at `core/Makefile:5259`. The variable was
true only because `PRODUCT_SHIPPING_API_LEVEL` is 29, and 29 ≥ 29
(`core/product_config.mk:523-528`).

What is genuinely lost is worth naming rather than glossing: the same check also
verified the `CONFIG_*` symbols those rows require, and that half would have worked.
The probe does it instead — it collects every `<config>` requirement across all
`<kernel>` rows in every matrix and lists the ones this board's config does not name,
checking the merged `.config` when the kernel has been built and the fragment
otherwise. Reported rather than gated: many of those entries are conditional on a GKI
kernel or on another config, and deciding which apply to a non-GKI board is not a
judgement a script can make. The enforcement is gone; the information is not.

This is also the first failure in the run that was not the tree's fault. The previous
seven were all the same mistake — claiming something the platform does not agree with.
This one is a version table that ends before the kernel this board runs.

## The vendor_boot that had nothing to carry

`recovery.img` built, `system.img` started, and then:

```
panic: lstat out/target/product/edge/vendor_ramdisk: no such file or directory
    build/soong/cmd/fileslist/fileslist.go:130
```

`INTERNAL_VENDOR_RAMDISK_FILES` is whatever is installed under
`$(TARGET_VENDOR_RAMDISK_OUT)` (`core/Makefile:1559`). Nothing was, so the directory
was never created, and the rule that lists it walks it anyway. `mkbootfs` would have
failed next for the same reason.

Filling the directory would have been the wrong repair. Header v4 with a separate
`vendor_boot` is what Android 13+ expects of devices that ship a GKI kernel and load
vendor modules from the vendor ramdisk. This board is not one: the kernel is built
from source with every driver compiled in, `BOARD_USES_GENERIC_KERNEL_IMAGE` is
unset, there is no `vendor_dlkm`. The vendor ramdisk had nothing to hold.

What `vendor_boot` costs is not an empty directory. With `BUILDING_VENDOR_BOOT_IMAGE`
the kernel command line moves out of `boot.img` into `vendor_boot`'s `vendor_cmdline`
(`core/Makefile:1614`) and the dtb moves with it (`1600-1606`); without it both go
into `boot.img` (`1303-1311`). This board is booted by mainline U-Boot, not by a
vendor bootloader written against `vendor_boot`, so `console=ttyS2,1500000n8` and
`androidboot.hardware=edge1` were sitting in a field a bootloader that reads only
`boot.img` never looks at. A board that boots to nothing with no console is the
hardest failure to diagnose on a board whose only output is that console.

So: header v2, one `boot.img` with kernel + ramdisk + dtb, no `vendor_boot`
partition. v0/v1/v2 share the classic `andr_img_hdr` in U-Boot, its best-tested
path. If the board ever gets a GKI kernel and loadable modules, v4 is right again.

## Paths that were still the BSP's

Moving to a mainline kernel changed every sysfs and device path the board config
names, and a stale one does not fail a build — it fails silently on the device. Each
of these was checked against `rk3399-base.dtsi`, `rk3399-khadas-edge.dtsi` and
`rk3399-khadas-edge-v.dts` at v6.12.111. A platform device is named
`<address>.<node name>`, and the BSP renamed several of those nodes.

| Was | Is | What it broke |
|---|---|---|
| `fstab`: `/devices/platform/fe320000.dwmmc/mmc_host*` | `fe320000.mmc` | vold matches this against the block device's sysfs path. No SD card, ever. |
| `fstab`: `/devices/platform/usb*` | `/devices/platform/*.usb*` | Every USB controller is a `usb@<address>` node, so nothing sits at `platform/usb*`. No USB storage. |
| `fstab`: `fileencryption=...:v1` | `:v2` | v1 was pinned because 4.19 lacked the fscrypt v2 backports. 6.12 has had them since 5.4. |
| `fstab`: `/dev/block/by-name/baseparameter` | removed | A Rockchip partition read by their hwcomposer. `flash/partitions.tsv` does not create it. |
| `genfs_contexts`: `fe380000.dwmmc/mmc_host` | `fe320000.mmc/mmc_host` | `fe380000` is `usb@fe380000`, an EHCI controller. The label was on nothing. |
| `genfs_contexts`: `/devices/platform/dmc` | removed | `dmc: memory-controller` is `status = "disabled"` and no Khadas dts enables it. |
| `genfs_contexts`: `/class/backlight` | removed | No backlight device on an HDMI board. |
| `init.edge1.rc`: `write /sys/class/devfreq/dmc/governor dmc_ondemand` | removed | Device does not exist, and `dmc_ondemand` is a BSP governor upstream does not have. Two init errors per boot. |
| `init.edge1.rc`: a bare `oneshot`, `start brcm_patchram` | removed | Left over from a deleted service stanza; init read `oneshot` as a command inside `on boot`. |
| `init.edge1.usb.rc`: `/sys/class/android_usb/android0/...` | `sys.usb.controller=fe800000.usb` | `android_usb` is the pre-configfs gadget. The dts gives `usbdrd_dwc3_0` (`usb@fe800000`) `dr_mode = "otg"`, so that is the UDC. |
| fragment: `CONFIG_DWMAC_ROCKCHIP=y` alone | `+ CONFIG_STMMAC_PLATFORM=y` | `DWMAC_ROCKCHIP` is inside `if STMMAC_PLATFORM`, a tristate. While the parent was `m` the child could not be `y`, so `olddefconfig` demoted it — no Ethernet, on a board whose dts enables `&gmac`. |

## Five traps in the tooling itself

**The device tree cannot be a symlink.** It was one — one place to edit, under
version control — and that is why the first platform build could not start:

```
build/make/core/product_config.mk:226: error: Cannot locate config makefile
    for product "edge1_tv".
```

AOSP does not glob for `AndroidProducts.mk` at make time. It reads
`out/.module_paths/AndroidProducts.mk.list`, which Soong's finder writes by walking
the source tree, and that walk does not descend into symlinked directories. The same
applies to everything else Soong globs: no `Android.bp` under the device tree had
ever been parsed and `BOARD_VENDOR_SEPOLICY_DIRS` pointed into a directory Soong
could not see. `build/place-device.sh` now copies the tree in as a real directory
before every stage that reads it, and clears the finder cache when the content
changed. The manifest repo stays the single source of truth; the copy is a build
artefact.

**A comment in the kernel fragment can be a directive.** `merge_config.sh` picks the
symbols to merge with two `sed` patterns and then reads each value back with
`grep -w $CFG`, so a comment mentioning a symbol the fragment also sets makes that
`grep` return two lines and the override report print the comment as the value. The
merge itself is unaffected, but the one output that says whether a symbol took
becomes unreadable — and `# CONFIG_X is deliberately absent` is four words from
matching the second pattern, `# CONFIG_X is not set`, and turning the symbol off.
Comments name symbols without the `CONFIG_` prefix now, and `verify-tree.sh` check 7
enforces both halves.

**A completed stage is only as good as its inputs.** `swig` was added to the WSL
dependency list, pushed, and never installed. The next run printed
`skipping Provision (already complete; -Force to redo)`, built the platform for eight
hours, and then failed the U-Boot stage on

```
error: command 'swig' failed: No such file or directory
make[2]: *** [scripts/dtc/pylibfdt/Makefile:33: rebuild] Error 1
```

The state file records which stages finished. It said Provision had, which was true of
the Provision that ran — against a shorter package list. An input that changes has to
un-complete the stage that consumes it, and the orchestrator already did exactly that
for one input: the manifest overlay is hashed, and `Sync` and `Kernel` are un-completed
when it moves. The dependency list was not hashed because it was not a file; it was a
list inside `provision-wsl.sh`, and hashing that whole script would re-run Provision on
every unrelated edit.

So the list became `build/windows/apt-packages.txt`, and the invalidation became a
table of (file, state key, stages):

| Input | Un-completes |
|---|---|
| `manifests/khadas_edge_tv14.xml` | `Sync`, `Kernel`, `Uboot` |
| `build/windows/apt-packages.txt` | `Provision` |
| `device/khadas/edge/**` | `Build` |
| `device/khadas/edge/kernel/edge1_mainline.config` | `Kernel`, `Build` |
| `build/build-kernel.sh` | `Kernel` |
| `build/build-uboot.sh` | `Uboot` |
| `build/build.sh` | `Build` |

`Uboot` joined the manifest row when `build-uboot.sh` started editing the U-Boot checkout
that a sync resets. The kernel fragment got a row of its own later, found in the audit
rather than by a failure: it lives under `device/khadas/edge`, so its hash re-ran only
`Build` - which packs whatever `Image` the `Kernel` stage left behind. A fragment change
would have shipped the previous kernel with nothing in any log to say so.

The last three rows are the same lesson again, and the third time it cost a cycle:
**a stage's own script is an input to it.** `build-uboot.sh` was rewritten to try the
card, then the eMMC, then the NVMe; the next run printed `skipping Uboot (already
complete)` and built all three images around a bootloader that still only knew about the
card. Nothing about the artefact showed it — `u-boot-rockchip.bin` was present and the
right size. The report now reads the bootcmd out of the built `.config` and prints which
media it actually knows, for the same reason: what is on disk is the truth, not what the
script says.

The device-tree row is the same lesson applied to the expensive stage, and it is the one
that would have saved the `super.img` cycle: a `BoardConfig.mk` change that makes the build
emit a raw image does nothing while `Build` is still marked complete. Any edit under the
device tree now un-completes it, and re-running `Build` with `out/` intact is an
incremental rebuild.

Adding a package now re-runs Provision by itself, and apt on an already-provisioned
distro takes seconds. `build-uboot.sh` also checks its four host requirements up front
— `swig`, setuptools, pyelftools and `Python.h` — and names the package for each,
because the error the build gives names neither the package nor what wanted it. U-Boot
builds a SWIG Python extension (`scripts/dtc/pylibfdt`) before it can run binman, and
binman is what packs `u-boot-rockchip.bin`.

**A diagnostic must never abort on the thing it is diagnosing.** The report is one
file, and the build log section is the part that explains a failure. It stopped
mid-sentence on a run whose whole purpose was to explain a failure, on this line:

```sh
first_failed=$(grep -nE '^FAILED:' "$f" | head -1 | cut -d: -f1)
```

A log with no `FAILED:` line - a kernel that built fine, or a stage that died in a
shell script rather than in ninja - makes `grep` exit 1, `pipefail` makes the pipeline
exit 1, and under `errexit` an assignment from a failing command substitution ends the
function. The report ended after printing the first log's first heading, so the logs of
the stage that actually failed never reached it.

This was the fourth occurrence of that shape, and the first three were each fixed on
whichever line happened to trip, with a `|| true`. The module probe had already drawn
the right conclusion and enforced the property once for its whole body; the report now
does the same - `set +e +o pipefail` inside a subshell, so the rest of the script keeps
both. A diagnostic printing something odd is always better than a diagnostic stopping.

Adjacent, and the same kind of mistake in a different tool: `preflight.sh` asked for
250GiB of free disk on every run. That is right before a sync and impossible after one,
because the 120GiB checkout and 150GiB of output it is sizing for are exactly what is
no longer free. It stopped a run that had only to rebuild a few images. The requirement
is now tiered by what is already on the filesystem - 250GiB bare, 140GiB synced, 40GiB
with a built `out/` - and `PORTING.md` has the table.

**A Kconfig default is not a guarantee, and this is the third time.** The U-Boot build
stopped with

```
NOT SET: CONFIG_CONSOLE_MUX
```

on a symbol whose Kconfig entry is `default y if VIDEO || LCD` (`common/Kconfig:260-262`)
— and the fragment had just turned `CONFIG_VIDEO` on. A default only applies to a symbol
nothing has decided yet. The base defconfig names neither `VIDEO` nor `CONSOLE_MUX`, so
running it evaluated `CONSOLE_MUX` with `VIDEO=n` and wrote
`# CONFIG_CONSOLE_MUX is not set` into `.config`; `olddefconfig` then *kept* that decided
value when the fragment turned `VIDEO` on. Same shape as `DWMAC_ROCKCHIP` staying `m`
behind a tristate parent, and as `BOARD_VNDK_VERSION` being cleared in silence: the
config says one thing and the build does another.

The symbol is stated in the fragment now, along with
`CONFIG_VIDEO_ROCKCHIP_MAX_YRES=2160`, which was inherited from a default for the same
reason and could have gone the same way.

The second half of the fix is the one that matters more. The check that caught it named
`CONFIG_CONSOLE_MUX` in a list kept **beside** the fragment rather than derived from it,
so the two could disagree — and they did, in the direction of asserting something never
set. **The fragment is now the only list**: the check reads it and requires every line to
survive, comparing exact values rather than assuming `=y`, so `SPL_PAD_TO=0x7f8000` and
`MAX_YRES=2160` are held to their values and not merely to being present. Four cases
tested, including the one that happened.

## How this tree got here

Worth one paragraph, because it explains the workflow. The port was written in an
environment that could not build it: `android.googlesource.com` is refused by that
container's network policy and the disk is roughly a tenth of what a build needs. So
the device tree, the HAL migration, the kernel delta, the SELinux policy and the
build pipeline were written and statically verified there, and `build/verify-tree.sh`
exists because it was the only check available — it validates XML, every file
reference in `device.mk` and `BoardConfig.mk`, VINTF consistency, shell syntax and
the mandatory kernel symbols without an AOSP tree present. Its first run found 14
real errors. Compilation happens on the board owner's Windows host through
`build/windows/Start-EdgeBuild.ps1`, which is why the diagnostics in this repo are
shaped around producing one pasteable report per run rather than a live terminal.
`github.com/aosp-mirror` was checked as a way out and is a partial reference mirror,
not a buildable tree — every `prebuilts/*` repo is absent, so nothing can compile —
but reading `platform_build` and `platform_manifest` from it is where most of the
decision table above comes from.
