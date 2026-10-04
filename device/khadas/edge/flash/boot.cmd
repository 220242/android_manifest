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
# fatwrite, itest and booti - every one of them present in that config, and most of
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

# Logs off: "logs=0" in edge1-options.txt, the file on this FAT the owner edits on a
# PC (or Edge1 Tools does, through bin/edge1-ctl.sh). Then this script writes nothing
# to the card - neither edge1-pstore.bin nor edge1-boot.log. "env import -t" reads
# name=value lines and skips "#" comments, -r takes CRLF (Notepad), and naming
# "logs" imports that one variable and nothing else. The file goes to the log
# buffer's address, nowhere near the ramoops region saved next.
#
# "pd" the same way: the USB PD voltage the board asks its supply for (below).
setenv logs
setenv pd
setenv edge1_nolog
if load ${devtype} ${devnum}:${distro_bootpart} ${edge1_laddr} edge1-options.txt; then
	env import -t -r ${edge1_laddr} ${filesize} logs pd
fi
if test "${logs}" = "0"; then setenv edge1_nolog 1; fi

# The previous kernel's log. The kernel keeps a ramoops region (its address is in
# the dtb; build-bootfs.sh fills it in here) whose contents survive a warm reset - a
# panic reboots by itself on a userdebug build. Saved to edge1-pstore.bin before
# anything but the few bytes of edge1-options.txt touches RAM, and before a new
# kernel clears it. Every zone our kernel
# has initialised starts with the ramoops signature "DBGC"; edge1_prev says whether
# the console zone's is there, i.e. whether the file is worth decoding. (Not the
# region's first word: the DRAM init's capacity probe can overwrite a word at a
# round address on the way through the reset - see build-kernel.sh.)
setenv edge1_paddr @PSTORE_ADDR@
setenv edge1_psize @PSTORE_SIZE@
setenv edge1_pcons @PSTORE_CONSOLE@
setenv edge1_prev none
if test -n "${edge1_paddr}"; then
	if test -n "${edge1_pcons}"; then
		if itest.l *${edge1_pcons} == 0x43474244; then setenv edge1_prev found; fi
	fi
	if test -z "${edge1_nolog}"; then
		fatwrite ${devtype} ${devnum}:${distro_bootpart} ${edge1_paddr} edge1-pstore.bin ${edge1_psize}
	fi
fi

# A record of how far this got, written to edge1-boot.log on this same FAT - which
# a PC shows when the card is plugged in. Without a serial console this file is the
# only account of what happened on the U-Boot side. It is written once all three
# files are loaded, and again if booti comes back; a fatwrite that fails costs
# nothing but the record. boot_targets and fdtfile are the eMMC U-Boot's own, to
# show whose environment ran this. (Not "ver": 2022.07 sets it only with
# CONFIG_VERSION_VARIABLE, which that config does not have.) Sizes are hex, as
# "load" leaves them in filesize.
setenv edge1_stage started
setenv edge1_log 'if test -z "${edge1_nolog}"; then env export -t ${edge1_laddr} edge1_where edge1_dev edge1_prev edge1_stage edge1_ksize edge1_rsize edge1_dsize edge1_pd bootargs boot_targets fdtfile; fatwrite ${devtype} ${devnum}:${distro_bootpart} ${edge1_laddr} edge1-boot.log ${filesize}; fi'

if load ${devtype} ${devnum}:${distro_bootpart} ${edge1_kaddr} Image; then
	setenv edge1_ksize ${filesize}
	if load ${devtype} ${devnum}:${distro_bootpart} ${edge1_faddr} edge1.dtb; then
		setenv edge1_dsize ${filesize}
		# USB PD. Both USB-C ports power the board through a FUSB302 that asks the
		# supply for a voltage (kernel patch 0005): 5, 9 or 12V as built - the
		# highest the supply has. pd=0 disables both controllers (the supply's
		# 5V, as before card 25); pd=5, 9, 15 or 20 replaces the list with 5V up
		# to that voltage. Cells are PDO_FIXED(mV, 3000mA): 5V 0x0401912c (with
		# USB data), 9V 0x0002d12c, 12V 0x0003c12c, 15V 0x0004b12c, 20V 0x0006412c.
		setenv edge1_pd default
		if test -n "${pd}"; then
			fdt addr ${edge1_faddr}
			fdt resize
			if test "${pd}" = "0"; then
				fdt set /i2c@ff3e0000/usb-typec@22 status disabled
				fdt set /i2c@ff3d0000/usb-typec@22 status disabled
				setenv edge1_pd off
			elif test "${pd}" = "5"; then
				fdt set /i2c@ff3e0000/usb-typec@22/connector sink-pdos <0x0401912c>
				fdt set /i2c@ff3d0000/usb-typec@22/connector sink-pdos <0x0401912c>
				setenv edge1_pd 5V
			elif test "${pd}" = "9"; then
				fdt set /i2c@ff3e0000/usb-typec@22/connector sink-pdos <0x0401912c 0x0002d12c>
				fdt set /i2c@ff3d0000/usb-typec@22/connector sink-pdos <0x0401912c 0x0002d12c>
				setenv edge1_pd 9V
			elif test "${pd}" = "12"; then
				setenv edge1_pd 12V
			elif test "${pd}" = "15"; then
				fdt set /i2c@ff3e0000/usb-typec@22/connector sink-pdos <0x0401912c 0x0002d12c 0x0003c12c 0x0004b12c>
				fdt set /i2c@ff3d0000/usb-typec@22/connector sink-pdos <0x0401912c 0x0002d12c 0x0003c12c 0x0004b12c>
				setenv edge1_pd 15V
			elif test "${pd}" = "20"; then
				fdt set /i2c@ff3e0000/usb-typec@22/connector sink-pdos <0x0401912c 0x0002d12c 0x0003c12c 0x0004b12c 0x0006412c>
				fdt set /i2c@ff3d0000/usb-typec@22/connector sink-pdos <0x0401912c 0x0002d12c 0x0003c12c 0x0004b12c 0x0006412c>
				setenv edge1_pd 20V
			fi
		fi
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
