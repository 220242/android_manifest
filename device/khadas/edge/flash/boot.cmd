# Khadas Edge1 - boot the Android on the device this script was found on.
#
# A template: build/build-bootfs.sh fills in @CMDLINE@ from boot.img's header, runs
# mkimage over the result and puts boot.scr - next to Image, ramdisk.img and
# edge1.dtb, all taken from that same boot.img - on bootfs, the FAT that is
# partition 1 of every image.
#
# Why it exists
# -------------
# The RK3399 BootROM tries SPI NOR, then the eMMC, then the SD card, and runs the
# first bootloader it finds. With anything bootable on the eMMC the card's own
# U-Boot never runs. What does run is the eMMC's U-Boot, and its distro boot looks
# at the SD card first (boot_targets "mmc1 mmc0 ..."), on partition 1, for
# extlinux/extlinux.conf and then boot.scr. So a card carrying this script boots
# Android on a board as it is. docs/BOOT.md has the sources.
#
# What it may use
# ---------------
# Only what the OLDEST U-Boot that has to run it provides. On this board that is
# Armbian's 2022.07, built from khadas-edge-v-rk3399_defconfig - and that config has
# no setexpr, no read, no gpio, no nvme, no abootimg. The first version of this
# script used setexpr to check the boot.img header and to add sector offsets; on
# the board setexpr was an unknown command, the check failed, and the script
# declined to boot, every time. So now: echo, test, setenv, run, load, env export,
# fatwrite and booti - every one of them present in that config, and every one of
# them what Armbian's own boot script uses. build/check-uboot-script.py enforces
# the list at build time, and verify-tree.sh does the same.
#
# The kernel, ramdisk and dtb are files here, read with "load", rather than sectors
# read out of the boot partition: that needed arithmetic this U-Boot cannot do, and
# a filesystem read is what every distro boot script does. They are byte-for-byte
# copies of what boot.img carries, made in the same step.
#
# What distro boot hands us
# -------------------------
# devtype, devnum and distro_bootpart. The defaults cover running it by hand:
#   load mmc 1:1 ${scriptaddr} boot.scr; source ${scriptaddr}

echo "Edge1: Android boot script on ${devtype} ${devnum}:${distro_bootpart}"

if test -z "${devtype}"; then setenv devtype mmc; fi
if test -z "${devnum}"; then setenv devnum 1; fi
if test -z "${distro_bootpart}"; then setenv distro_bootpart 1; fi
# distro boot sets those three as hush variables ("devnum=1", the for loop's
# distro_bootpart), which "env export" cannot see - so the log gets its own copy.
setenv edge1_where "${devtype} ${devnum}:${distro_bootpart}"

# androidboot.boot_devices names the controller whose partitions become
# /dev/block/by-name/*; without it first-stage init finds no super, metadata or misc.
# U-Boot numbers controllers by rk3399-u-boot.dtsi's aliases - mmc0 = &sdhci (eMMC,
# fe330000), mmc1 = &sdmmc (card, fe320000) - and an NVMe hangs off the PCIe
# controller, its nearest platform device as init sees it.
setenv edge1_dev fe320000.mmc
if test "${devtype}" = "mmc"; then
	if test "${devnum}" = "0"; then setenv edge1_dev fe330000.mmc; fi
fi
if test "${devtype}" = "nvme"; then setenv edge1_dev f8000000.pcie; fi

# Load addresses (RK3399 DRAM starts at 0). The kernel on a 2MiB boundary so booti
# does not have to move it; the ramdisk 128MiB above it, clear of the 50MB Image
# and its BSS; the dtb below the kernel, where U-Boot's own fdt_addr_r is. The log
# buffer sits between the kernel's end and the ramdisk.
setenv edge1_kaddr 0x02200000
setenv edge1_raddr 0x0a200000
setenv edge1_faddr 0x01f00000
setenv edge1_laddr 0x09f00000

# A record of how far this got, written to edge1-boot.log on this same FAT - which
# a PC shows when the card is plugged in. Without a serial console this file is the
# only account of what happened on the U-Boot side. It is written once all three
# files are loaded, and again if booti comes back; a fatwrite that fails costs
# nothing but the record. boot_targets and fdtfile are the eMMC U-Boot's own, to
# show whose environment ran this. (Not "ver": 2022.07 sets it only with
# CONFIG_VERSION_VARIABLE, which that config does not have.) Sizes are hex, as
# "load" leaves them in filesize.
setenv edge1_stage started
setenv edge1_log 'env export -t ${edge1_laddr} edge1_where edge1_dev edge1_stage edge1_ksize edge1_rsize edge1_dsize bootargs boot_targets fdtfile; fatwrite ${devtype} ${devnum}:${distro_bootpart} ${edge1_laddr} edge1-boot.log ${filesize}'

if load ${devtype} ${devnum}:${distro_bootpart} ${edge1_kaddr} Image; then
	setenv edge1_ksize ${filesize}
	if load ${devtype} ${devnum}:${distro_bootpart} ${edge1_faddr} edge1.dtb; then
		setenv edge1_dsize ${filesize}
		if load ${devtype} ${devnum}:${distro_bootpart} ${edge1_raddr} ramdisk.img; then
			setenv edge1_rsize ${filesize}
			setenv bootargs "androidboot.boot_devices=${edge1_dev} @CMDLINE@"
			setenv edge1_stage booti
			run edge1_log
			echo "Edge1: booting Android from ${edge1_dev}"
			booti ${edge1_kaddr} ${edge1_raddr}:${edge1_rsize} ${edge1_faddr}
			setenv edge1_stage booti-returned
		else
			setenv edge1_stage no-ramdisk
		fi
	else
		setenv edge1_stage no-dtb
	fi
else
	setenv edge1_stage no-kernel
fi

run edge1_log
echo "Edge1: Android did not start (${edge1_stage}); distro boot carries on"
