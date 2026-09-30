# Khadas Edge1 - boot the Android boot image on the device this script was found on.
#
# This is a template. build/build-bootfs.sh fills in every @...@ from the boot.img
# it sits next to, runs mkimage over the result and puts boot.scr (and this text,
# as boot.cmd) on the small FAT partition that is partition 1 of every image.
#
# Why it exists
# -------------
# The RK3399 BootROM tries SPI NOR, then the eMMC, then the SD card, and runs the
# first bootloader it finds. With anything bootable on the eMMC - Armbian, the
# factory Android, Ubuntu - the card's own bootloader never runs at all. But a
# mainline or Armbian U-Boot on the eMMC then runs distro boot, and distro boot
# looks at the SD card FIRST (boot_targets "mmc1 mmc0 ..."), on partition 1, for
# extlinux/extlinux.conf or boot.scr. That is how an OpenWrt card on this board
# "won" over the eMMC: the eMMC's U-Boot ran the card's boot.scr.
#
# So a card carrying this script boots Android whether the U-Boot that finds it is
# ours (from the card, via TST mode or an empty eMMC; or from SPI NOR) or the one
# already on the eMMC. Only commands every U-Boot of the last several years has are
# used: part, mmc/nvme read, setexpr, booti. In particular it does not need
# CONFIG_ANDROID_BOOT_IMAGE, which the defconfig Armbian builds its U-Boot from lacks.
#
# What distro boot hands us
# -------------------------
# devtype, devnum and distro_bootpart. Defaults below cover running it by hand
# ("load mmc 1:1 ${scriptaddr} boot.scr; source ${scriptaddr}").

echo "Edge1: Android boot script on ${devtype} ${devnum}"

if test -z "${devtype}"; then setenv devtype mmc; fi
if test -z "${devnum}"; then setenv devnum 1; fi

# androidboot.boot_devices names the controller whose partitions become
# /dev/block/by-name/*. Without it first-stage init finds no super, metadata or
# misc and stops - see BoardConfig.mk. U-Boot numbers the controllers by
# rk3399-u-boot.dtsi's aliases, mmc0 = &sdhci (eMMC, fe330000) and mmc1 = &sdmmc
# (card, fe320000), and has done since those aliases were added in 2019. The NVMe
# hangs off the PCIe controller, which is the nearest platform device init sees.
setenv edge1_dev fe320000.mmc
if test "${devtype}" = "mmc"; then
	if test "${devnum}" = "0"; then setenv edge1_dev fe330000.mmc; fi
	mmc dev ${devnum}
fi
if test "${devtype}" = "nvme"; then
	setenv edge1_dev f8000000.pcie
	nvme scan
	nvme device ${devnum}
fi

# Load addresses. The kernel is put on a 2MiB boundary so booti never has to move
# it; the ramdisk is 128MiB above it, clear of the 50MB Image plus its BSS; the
# dtb sits below the kernel where U-Boot's own fdt_addr_r for rk3399 is. The
# header goes well above all three.
setenv edge1_kaddr 0x02200000
setenv edge1_raddr 0x0a200000
setenv edge1_faddr 0x01f00000
setenv edge1_haddr 0x10000000

setenv edge1_ok 0
if part start ${devtype} ${devnum} boot edge1_bs; then
	setenv edge1_ok 1
else
	echo "Edge1: no partition named boot on ${devtype} ${devnum}"
fi

# Read the header and check it is the boot.img this script was built for. The
# magic is "ANDR" as a little-endian word; the id word is the first 32 bits of
# the image's SHA1, which mkbootimg writes into the header. A mismatch means boot
# was rewritten without this partition - the offsets below would be wrong.
if test "${edge1_ok}" = "1"; then
	if test "${devtype}" = "nvme"; then
		nvme read ${edge1_haddr} ${edge1_bs} 4
	else
		mmc read ${edge1_haddr} ${edge1_bs} 4
	fi
	setexpr.l edge1_magic *${edge1_haddr}
	setexpr edge1_idaddr ${edge1_haddr} + 0x240
	setexpr.l edge1_id *${edge1_idaddr}
	if test "${edge1_magic}" != "52444e41"; then
		echo "Edge1: partition boot does not hold an Android boot image"
		setenv edge1_ok 0
	elif test "${edge1_id}" != "@ID0@"; then
		echo "Edge1: boot.img was changed after this script was generated"
		echo "       (id ${edge1_id}, expected @ID0@) - rebuild the image"
		setenv edge1_ok 0
	fi
fi

# Kernel, ramdisk and dtb, each straight out of the boot partition. Offsets and
# lengths are in 512-byte sectors from the start of the partition, taken from the
# header by build-bootfs.sh.
if test "${edge1_ok}" = "1"; then
	setexpr edge1_k ${edge1_bs} + @KERNEL_OFF@
	setexpr edge1_r ${edge1_bs} + @RAMDISK_OFF@
	setexpr edge1_d ${edge1_bs} + @DTB_OFF@
	if test "${devtype}" = "nvme"; then
		nvme read ${edge1_kaddr} ${edge1_k} @KERNEL_CNT@
		nvme read ${edge1_raddr} ${edge1_r} @RAMDISK_CNT@
		nvme read ${edge1_faddr} ${edge1_d} @DTB_CNT@
	else
		mmc read ${edge1_kaddr} ${edge1_k} @KERNEL_CNT@
		mmc read ${edge1_raddr} ${edge1_r} @RAMDISK_CNT@
		mmc read ${edge1_faddr} ${edge1_d} @DTB_CNT@
	fi
	setenv bootargs "androidboot.boot_devices=${edge1_dev} @CMDLINE@"
	echo "Edge1: booting Android from ${edge1_dev}"
	booti ${edge1_kaddr} ${edge1_raddr}:@RAMDISK_SIZE@ ${edge1_faddr}
	echo "Edge1: booti returned - the kernel did not start"
fi
