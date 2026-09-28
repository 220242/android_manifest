#
# Khadas Edge1 (RK3399) - Android TV 14 board configuration.
#

# ---------------------------------------------------------------------------
# CPU / ABI.
#
# RK3399 is big.LITTLE: 2x Cortex-A72 @1.8GHz + 4x Cortex-A53 @1.4GHz.
# The 2nd (32-bit) ABI is retained because the Mali-T860 userspace blob and
# the Rockchip OMX IL components ship armeabi-v7a only.
# ---------------------------------------------------------------------------
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_VARIANT := cortex-a53

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := cortex-a53

# Removed vs. the Android 10 BoardConfig, all obsolete or rejected on 14:
#   BUILD_EMULATOR            - deleted from build/make in Android 11
#   TARGET_CPU_SMP            - unused since Android 5
#   TARGET_USES_64_BIT_BINDER - binder is unconditionally 64-bit since 8.0
#   TARGET_USES_64_BIT_BCMDHD - was a bcmdhd-specific hack, no longer read
#   OVERRIDE_RS_DRIVER / BOARD_OVERRIDE_RS_CPU_VARIANT_* - RenderScript was
#     removed from the platform in Android 12; nothing consumes these.

TARGET_BOARD_PLATFORM := rk3399
TARGET_BOARD_PLATFORM_GPU := mali-t860
TARGET_BOARD_PLATFORM_PRODUCT := atv

# These two exist so the build emits the properties rather than device.mk setting
# them by hand. core/main.mk:332-341 puts all of the following into
# ADDITIONAL_VENDOR_PROPERTIES:
#
#   ro.product.board   = $(TARGET_BOOTLOADER_BOARD_NAME)
#   ro.board.platform  = $(TARGET_BOARD_PLATFORM)
#   ro.hwui.use_vulkan = $(TARGET_USES_VULKAN)
#   ro.sf.lcd_density  = $(TARGET_SCREEN_DENSITY), if defined
#
# device.mk set ro.product.board and ro.board.platform directly, and
# TARGET_BOOTLOADER_BOARD_NAME was unset, so the build emitted an empty one beside
# ours and post_process_props.py stopped:
#
#   error: found duplicate sysprop assignments:
#   ro.product.board=
#   ro.product.board=rk3399
#
# ro.board.platform survived only because duplicates with identical values are
# allowed (tools/post_process_props.py:114) - it would have become an error the
# moment TARGET_BOARD_PLATFORM changed.
TARGET_BOOTLOADER_BOARD_NAME := rk3399
# 213 is the leanback density for 1080p, and it was ro.sf.lcd_density=213 in
# device.mk. Set here it goes through the same ADDITIONAL_VENDOR_PROPERTIES path,
# so there is one source for it.
TARGET_SCREEN_DENSITY := 213

# Four variables were set here and are gone: BOARD_USE_DRM, BOARD_OPENGL_AEP,
# ENABLE_CPUSETS and ENABLE_SCHEDBOOST. None of the four appears anywhere in
# AOSP 14's build/make, and nothing in this tree reads them either. They were
# read by device/rockchip/common and by system/core's rootdir in releases that
# still had them; on 14 cpusets and schedboost are unconditional, the AEP
# permission file is copied by device.mk outright, and DRM/KMS is not a board
# switch any more. Setting them changed nothing while reading like configuration.

# ---------------------------------------------------------------------------
# Kernel: mainline 6.12 LTS, built out of tree by build/build-kernel.sh and
# consumed here as a prebuilt, so a platform-only rebuild does not re-run it.
#
# Path is kernel/mainline: a project at path "kernel" would nest the upstream
# kernel/configs, kernel/tests and 26 kernel/prebuilts/* projects, and repo
# rejects overlapping paths. See manifests/khadas_edge_tv14.xml.
# ---------------------------------------------------------------------------
# Documentation, not wiring - AOSP 14 does not build kernels, and
# build/build-kernel.sh carries the same values. They are here because they are
# the facts anyone touching the kernel looks for first. Change them together.
TARGET_KERNEL_SOURCE := kernel/mainline
TARGET_KERNEL_CONFIG := defconfig + device/khadas/edge/kernel/edge1_mainline.config
TARGET_KERNEL_DTS := rk3399-khadas-edge-v
TARGET_KERNEL_ARCH := arm64

# TARGET_PREBUILT_KERNEL is not set: the string "PREBUILT_KERNEL" appears nowhere
# in AOSP 14's build/make. core/Makefile:1018 defines INSTALLED_KERNEL_TARGET as
# $(PRODUCT_OUT)/kernel and leaves producing it to the device, so device.mk copies
# the Image there.
#
# The device tree blob goes into boot.img. core/Makefile:1303-1311 adds
# "--dtb $(INSTALLED_DTBIMAGE_TARGET)" to the boot image only when
# BUILDING_VENDOR_BOOT_IMAGE is unset; when a vendor_boot is built the dtb goes
# there instead (core/Makefile:1600-1606). With header v2 there is no vendor_boot,
# so the dtb, the kernel and the ramdisk are all in one image.
#
# BOARD_PREBUILT_DTBIMAGE_DIR is globbed for *.dtb at Kati parse time and
# everything found is concatenated into dtb.img - so it points at a directory
# build-kernel.sh stages with exactly one dtb, not at the kernel's dts output,
# which holds about ninety.
#
# BOARD_PREBUILT_DTBOIMAGE is gone with the BSP: it pointed at Rockchip's
# resource.img, an RSCE container holding the dtb and the boot logos that only
# Rockchip's own bootloader reads.
BOARD_INCLUDE_DTB_IN_BOOTIMG := true
BOARD_PREBUILT_DTBIMAGE_DIR := kernel/mainline/out/android-dtb

# console=ttyS2,1500000n8 is the mainline name for the RK3399 debug UART; the BSP
# called it ttyFIQ0, which was Rockchip's FIQ-based serial driver and does not
# exist upstream. androidboot.hardware names the HAL suffix set this board uses -
# rk30board was the BSP's value and matched nothing in this tree.
BOARD_KERNEL_CMDLINE := \
    console=ttyS2,1500000n8 \
    androidboot.console=ttyS2 \
    androidboot.hardware=edge1 \
    firmware_class.path=/vendor/firmware \
    init=/init \
    rootwait ro

# veritymode is appended per-variant: enforcing on user, eio on userdebug so a
# bring-up image with a locally modified vendor partition still boots.
ifeq ($(TARGET_BUILD_VARIANT),user)
BOARD_KERNEL_CMDLINE += androidboot.veritymode=enforcing
else
BOARD_KERNEL_CMDLINE += androidboot.veritymode=eio
endif

BOARD_KERNEL_BASE := 0x00200000
BOARD_KERNEL_PAGESIZE := 2048

# Boot image header v2: one boot.img with the kernel, the ramdisk and the dtb, and
# no vendor_boot.
#
# This was 4, on the reasoning that v4 plus a separate vendor_boot is what Android
# 13+ expects. That is true of devices that ship a GKI kernel and load vendor
# modules from the vendor ramdisk. This board is not one: the kernel is built from
# source with every driver it needs compiled in, BOARD_USES_GENERIC_KERNEL_IMAGE is
# not set, and there is no vendor_dlkm. So the vendor ramdisk had nothing to hold,
# and the build said so - core/Makefile never creates the directory when no module
# installs into it, and fileslist walked it anyway:
#
#   panic: lstat out/target/product/edge/vendor_ramdisk: no such file or directory
#
# Filling it to satisfy the walk would have been the wrong repair, because what
# vendor_boot costs is not an empty directory. With BUILDING_VENDOR_BOOT_IMAGE the
# kernel command line moves out of boot.img into vendor_boot's vendor_cmdline
# (core/Makefile:1614), and the dtb moves with it. Both are then invisible to a
# bootloader that reads only boot.img - and this board is booted by mainline
# U-Boot, not by a vendor bootloader written against vendor_boot. A silent boot
# with no console and no ro.boot.hardware is the hardest failure to diagnose on a
# board whose only output is that console.
#
# Header v2 is also the best-tested path in U-Boot: v0/v1/v2 share the classic
# andr_img_hdr, and "abootimg get dtb" reads the v2 dtb field directly. If the
# board ever gets a GKI kernel and loadable modules, v4 is the right answer again.
BOARD_BOOT_HEADER_VERSION := 2
BOARD_MKBOOTIMG_ARGS := --header_version $(BOARD_BOOT_HEADER_VERSION)

# --ramdisk_offset, and this one is a boot failure rather than a preference. It was
# found by reading U-Boot rather than by booting, so the arithmetic is written out.
#
# mkbootimg's defaults put the kernel at base + 0x00008000 and the ramdisk at
# base + 0x01000000. With BOARD_KERNEL_BASE = 0x00200000 that is:
#
#   kernel  0x00208000
#   ramdisk 0x01200000   = kernel + 16MiB
#
# The Image is 50MB. It therefore occupies 0x00208000 to about 0x03408000, and the
# ramdisk address is inside that range.
#
# U-Boot does not tolerate the overlap, and the order is what makes it fatal
# (boot/bootm.c:1045-1070): BOOTM_STATE_FINDOTHER runs first and, for a header v2
# image whose ramdisk_addr is neither 0 nor mkbootimg's 0x11000000 default, memcpy's
# the ramdisk to that address (boot/image-android.c:714-726). BOOTM_STATE_LOADOS
# then memmoves the 50MB kernel over it. BOOTM_STATE_RAMDISK relocates a ramdisk
# that has already been overwritten, and the kernel comes up with a corrupt
# initramfs - which presents as a panic with no obvious cause.
#
# 0x05000000 puts the ramdisk at 0x05200000, which is 79MiB above the kernel's
# 0x00208000 - so about 30MB of margin over today's Image, and room for it to reach
# 79MB before this returns. verify-tree.sh check 3c does the arithmetic on every
# run, against the real Image size when a built kernel is reachable and against a
# 64MiB floor when it is not. It rejected 0x04000000, which left 63.97MiB: correct
# for the Image as it stands and not worth the thin margin.
BOARD_MKBOOTIMG_ARGS += --ramdisk_offset 0x05000000

# BOARD_INCLUDE_RECOVERY_DTBO used to be set here, carried over from the Android
# 10 config where the boot header was v2. Boot header v3 and v4 have no
# recovery_dtbo field at all, so mkbootimg is handed a --recovery_dtbo it cannot
# place - it does nothing at best. Dropped.
#
# With a dedicated recovery partition and no A/B, recovery ships as a whole image
# rather than as a patch against boot, which is also what package-file flashes.
# Setting this is what tells the build to stop generating the patch resources.
BOARD_USES_FULL_RECOVERY_IMAGE := true

# ---------------------------------------------------------------------------
# Partitions.
#
# Dynamic partitions (super) are mandatory groundwork for 14: system,
# system_ext, product, vendor and odm are all resizable images inside super.
# The Android 10 config had fixed BOARD_SYSTEMIMAGE_PARTITION_SIZE = 1.5GiB,
# which is far below what an Android 14 system image needs.
# ---------------------------------------------------------------------------
# PRODUCT_USE_DYNAMIC_PARTITIONS is NOT set here, although every other line in
# this section is a board variable. It is a product variable, and Kati freezes
# the product variables when product config finishes - which is before this file
# is read:
#
#   device/khadas/edge/BoardConfig.mk:101: error: cannot assign to readonly
#       variable: PRODUCT_USE_DYNAMIC_PARTITIONS
#
# It is set in edge1_tv.mk instead. board_config.mk reads it from there to decide
# whether to build super_empty.img, so the ordering works out.
BOARD_USES_METADATA_PARTITION := true

# minigbm is the gralloc/hwcomposer backend, replacing the unported
# libgralloc_rk3399. A convention flag rather than something AOSP's build reads:
# the actual selection is the gralloc.minigbm / mapper.minigbm / hwcomposer.
# drm_minigbm packages in device.mk plus ro.hardware.* . It was in device.mk,
# which is a product makefile; BOARD_* belongs here.
BOARD_USES_MINIGBM := true

# Mesa: which gallium driver to build.
#
# external/mesa3d builds nothing by default - the drivers are selected per board,
# and with none selected libGLES_mesa still builds and ships and then finds no
# driver at run time. That is the failure mode worth spending a round to avoid,
# because it looks like a working build.
#
# BOARD_MESA3D_GALLIUM_DRIVERS was set here first, from Mesa's upstream Android
# documentation. The probe then found that the only place in the whole tree that
# mentions BOARD_MESA3D_* is device/linaro/dragonboard, which sets it alongside
# BOARD_MESA3D_USES_MESON_BUILD := true and drives meson from its own makefiles -
# so those names are dragonboard's interface to its own build, not Mesa's to the
# platform. external/mesa3d itself never reads them.
#
# BOARD_GPU_DRIVERS is the variable the Android.mk build in that snapshot reads
# (Android.common.mk: MESA_GPU_DRIVERS := $(strip $(BOARD_GPU_DRIVERS))), and this
# snapshot is Android.mk-based - libGLES_mesa is a LOCAL_MODULE in it. The probe
# now prints every driver-selection variable external/mesa3d actually reads, with
# the lines that read them, so the next report confirms or corrects this.
#
# panfrost is the Midgard gallium driver and binds to drivers/gpu/drm/panfrost,
# which this kernel builds in. kmsro is what lets it render on a display
# controller that is not the GPU - the Rockchip VOP here - which is exactly the
# split this SoC has.
#
# No Vulkan driver: panvk on Midgard is not something to depend on, and nothing in
# this configuration asks for Vulkan.
BOARD_GPU_DRIVERS := panfrost kmsro

# 4608 MiB super. Leaves room on a 16GB eMMC for userdata.
BOARD_SUPER_PARTITION_SIZE := 4831838208

# super.img is built by the default target because of this line, and without it the
# build succeeds without producing one. core/Makefile:7307-7315 makes super.img a
# dependency of droidcore-unbundled only when this is true; otherwise it is built
# only by an explicit "m superimage" or for a dist build. What droid does build
# unconditionally is super_empty.img, which carries the partition metadata and no
# contents - fastboot writes it and then flashes the logical partitions
# individually.
#
# That is the normal path for a device flashed with fastboot, and it is not this
# one. flash-emmc.sh dds super.img into the super partition, so the board needs the
# full image - which is exactly the case the flag exists for ("devices that use
# super image directly", same comment). The first build to get all the way through
# ended with "expected .../super.img was not produced" for this reason, after
# reporting success: m had done everything it was asked to.
BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT := true
BOARD_SUPER_PARTITION_GROUPS := rockchip_dynamic_partitions
BOARD_ROCKCHIP_DYNAMIC_PARTITIONS_SIZE := 4827643904
BOARD_ROCKCHIP_DYNAMIC_PARTITIONS_PARTITION_LIST := \
    system \
    system_ext \
    product \
    vendor \
    odm

TARGET_COPY_OUT_VENDOR := vendor
TARGET_COPY_OUT_PRODUCT := product
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
TARGET_COPY_OUT_ODM := odm

# 96MiB each, not 64. The kernel Image is 50MB on its own - uncompressed, with
# every driver built in - and boot.img now carries the ramdisk and the dtb beside
# it, where the dtb used to be in vendor_boot. recovery.img carries the same kernel
# plus the recovery ramdisk, which is the larger of the two. 64MiB left single-digit
# megabytes of headroom on both, and exceeding the partition size is a build error
# at the very end of a run.
BOARD_BOOTIMAGE_PARTITION_SIZE := 100663296
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 100663296
# No BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE: header v2 builds no vendor_boot.
# No BOARD_DTBOIMG_PARTITION_SIZE and no dtbo partition: the dtb travels inside
# boot.img, so there is no dtbo.img to give a partition to.
BOARD_FLASH_BLOCK_SIZE := 131072

BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_ODMIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true

# Raw images, not Android-sparse ones. This is what makes super.img writable with
# dd, and it is the last thing that stood between a successful build and a card
# that boots.
#
# The build was producing a sparse super.img - visible in the log as
#
#   lpmake --metadata-size 65536 --super-name super ... --sparse
#          --output out/target/product/edge/super.img
#
# and that --sparse comes from tools/releasetools/build_super_image.py:136-137:
#
#   if info_dict.get("build_non_sparse_super_partition") != "true":
#     cmd.append("--sparse")
#
# An Android sparse image is a container - a 28-byte header and then chunks that
# each say where in the output they belong - so it is not the partition's contents
# and cannot be written into a partition. dd would have copied the container
# verbatim; the board would have found no ext4 superblock and no super metadata,
# and first-stage init would have failed to mount /system with nothing in the log
# to say why. Both writers here would have done it: build-sdimage.sh dds into the
# disk image, and the generated flash-emmc.sh dds into the eMMC partition.
#
# core/Makefile:6145-6148 is the only thing that sets build_non_sparse_super_partition,
# and it takes it from whichever of the two per-filesystem switches is set. So the
# switch for the filesystem the logical partitions use is the one that turns super
# raw. It also turns system/vendor/product/system_ext/odm raw on the way in, which
# is not a side effect worth avoiding: they are lpmake's inputs and they end up
# inside super either way. The cost is apparent size in out/, and since mke2fs
# leaves the unused blocks unwritten the files stay sparse on the host filesystem.
#
# This was TARGET_USERIMAGES_SPARSE_EXT_DISABLED := false, in the fstab section,
# carried over from the Android 10 config. That is the default, so it read as a
# decision while changing nothing.
#
# Not an unusual configuration: target/board/BoardConfigGsiCommon.mk:19 sets the
# same line, so it is the path AOSP's own GSI builds take.
TARGET_USERIMAGES_SPARSE_EXT_DISABLED := true
# The f2fs switch is deliberately not set. Nothing here builds an f2fs image -
# userdata is the only f2fs filesystem and init formats it on first boot - so this
# would be a line with no effect. It matters only that one of the two is set:
# core/Makefile treats either as "super must be raw".

# Userdata is formatted on first boot by init, not sized here.
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs

# ---------------------------------------------------------------------------
# Verified boot.
# ---------------------------------------------------------------------------
BOARD_AVB_ENABLE := true
BOARD_AVB_ROLLBACK_INDEX := 0
# Hash the boot images rather than chain them to a separate vbmeta partition:
# the Edge1's u-boot reads a single vbmeta.
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 2

# The main vbmeta key is left unset on purpose: core/Makefile:4415 then picks
# external/avb/test/data/testkey_rsa4096.pem with SHA256_RSA4096, which is what a
# userdebug bring-up image should be signed with. A real key belongs here only
# once there is something to protect.
#
# Recovery is different, and the build says so:
#
#   build/make/core/Makefile:4460: error: BOARD_AVB_RECOVERY_KEY_PATH must be
#       defined for if non-A/B is supported.
#
# On a non-A/B device the standalone recovery image cannot be chained into
# vbmeta.img - there is no second slot to fall back to, so recovery has to verify
# on its own and therefore carries its own signature. TARGET_OTA_ALLOW_NON_AB is
# derived, not set here: board_config.mk turns it on whenever AB_OTA_UPDATER is
# not true, and marks it read-only.
#
# Same test key as the implicit default above, deliberately: two different test
# keys would suggest a key hierarchy that does not exist.
BOARD_AVB_RECOVERY_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem
BOARD_AVB_RECOVERY_ALGORITHM := SHA256_RSA4096
BOARD_AVB_RECOVERY_ROLLBACK_INDEX := 0
# Location 0 belongs to vbmeta itself; a self-signed partition needs its own.
BOARD_AVB_RECOVERY_ROLLBACK_INDEX_LOCATION := 1

# ---------------------------------------------------------------------------
# fstab / recovery.
# ---------------------------------------------------------------------------
TARGET_RECOVERY_FSTAB := device/khadas/edge/fstab.edge1
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
TARGET_RECOVERY_DEFAULT_ROTATION := ROTATION_NONE

# ---------------------------------------------------------------------------
# SELinux.
#
# Android 14 splits policy by partition; vendor HAL domains belong in the
# vendor policy dir. The Android 10 tree kept everything in one flat
# device/rockchip/common/sepolicy directory, which will not compile against a
# 14 tree.
# ---------------------------------------------------------------------------
BOARD_VENDOR_SEPOLICY_DIRS += device/khadas/edge/sepolicy/vendor

# BOARD_SEPOLICY_VERS := 29.0 was set here, to pin vendor policy to the shipping
# API level the way the Android 10 tree did. On 14 the build owns that variable:
#
#   core/config.mk:876  PLATFORM_SEPOLICY_VERSION := $(BOARD_API_LEVEL)
#   core/config.mk:877  BOARD_SEPOLICY_VERS := $(PLATFORM_SEPOLICY_VERSION)
#   core/config.mk:878  .KATI_READONLY := PLATFORM_SEPOLICY_VERSION BOARD_SEPOLICY_VERS
#
# and BOARD_API_LEVEL itself comes from the release config, not from the board
# (board_config.mk errors outright if a board sets it). Those lines run after
# BoardConfig.mk, so the assignment here was not an error - it was silently
# overwritten, which is worse. In this release the value lands on 202404, which is
# why system/sepolicy/prebuilts/api holds 202404 alongside 29.0 through 34.0:
# vendor policy builds against the platform version and the compatibility mapping
# files cover the older ones.

# ---------------------------------------------------------------------------
# VINTF.
# ---------------------------------------------------------------------------
DEVICE_MANIFEST_FILE := device/khadas/edge/vintf/manifest.xml
DEVICE_MATRIX_FILE := device/khadas/edge/vintf/compatibility_matrix.xml

# No BOARD_VNDK_VERSION. It was "current" here and the build threw it away:
# core/config.mk:1266-1273 clears both BOARD_VNDK_VERSION and PLATFORM_VNDK_VERSION
# whenever KEEP_VNDK is not true, and core/envsetup.mk:53-58 makes KEEP_VNDK false
# whenever the release config sets RELEASE_DEPRECATE_VNDK - which this release does.
# Neither step warns. The framework manifest therefore provides no VNDK version at
# all, which is what check_vintf reported when the device matrix still asked for 34;
# see vintf/compatibility_matrix.xml.
#
# Nothing replaces it. If a future release keeps VNDK, envsetup.mk:64 sets
# BOARD_VNDK_VERSION := current itself when the board has not - the same value this
# line used to state.

# ---------------------------------------------------------------------------
# Connectivity: AP6398S = Broadcom BCM4359, on SDIO.
#
# On mainline this is brcmfmac, built into the kernel, and the DTS already carries
# the wifi@1 node with its power sequence and host-wake interrupt. That changes
# what belongs here:
#
#   - No BOARD_WLAN_DEVICE. It selects a vendor wifi_hal under
#     hardware/broadcom/wlan written for bcmdhd's private nl80211 commands, which
#     brcmfmac does not implement. Which HAL to use instead is an open question -
#     the module probe now dumps what the tree offers - so it is left unset rather
#     than set to something that cannot work.
#   - No WIFI_DRIVER_FW_PATH_*. Those write firmware paths into bcmdhd's module
#     parameters. brcmfmac asks the kernel firmware loader for
#     brcm/brcmfmac4359-sdio.bin and its board nvram, which device.mk installs
#     into /vendor/firmware/brcm.
#
# The firmware and the board's NVRAM come from this owner's OpenWrt build for the
# same board, where they are known to associate.
BOARD_WPA_SUPPLICANT_DRIVER := NL80211
BOARD_HOSTAPD_DRIVER := NL80211

BOARD_HAVE_BLUETOOTH := true
# BOARD_HAVE_BLUETOOTH_BCM was set here. system/bt read it until Android 11; the
# Bluetooth stack is an APEX module on 14 and nothing reads it. The Broadcom
# specifics that matter now are the firmware patchram stage in init.edge1.rc and
# bluetooth/bt_vendor.conf.
# BOARD_BLUETOOTH_BDROID_BUILDCFG_INCLUDE_DIR pointed at device/khadas/edge/bluetooth,
# and that directory had no bdroid_buildcfg.h in it. soong_config.mk:147 passes this
# to Soong as BtConfigIncludeDir and the Bluetooth stack includes the header from
# there, so this was a compile error waiting further down the build - AOSP's own
# example, build/make/target/board/mainline_arm64/bluetooth/, exists to show what
# belongs in such a directory.
#
# Left unset, exactly as BoardConfigGsiCommon.mk does, because there is nothing
# board-specific to put in it: the files that were there (bt_vendor.conf,
# vnd_edge1.txt) configured libbt-vendor, Broadcom's HIDL-era vendor library, which
# this tree does not build. See init.edge1.rc for where Bluetooth stands.

# ---------------------------------------------------------------------------
# Misc.
# ---------------------------------------------------------------------------
TARGET_NO_BOOTLOADER := true
TARGET_NO_KERNEL := false
TARGET_NO_RECOVERY := false
BOARD_CHARGER_ENABLE_SUSPEND := true
# TARGET_BASE_PARAMETER_IMAGE is deliberately unset.
#
# The Android 10 config pointed it at
# device/rockchip/common/baseparameter/baseparameter_fb720.img, a prebuilt that
# pins the display timing. On an HDMI-only device the bootloader and the DRM
# driver derive timings from the sink's EDID instead, which is more correct
# across the range of TVs an Edge1 gets plugged into. package-file has a
# commented-out entry to reinstate it if a board ever needs a fixed mode.

# Keep the Rockchip release tooling reachable for update.img packaging.
# Set because the default is $(TARGET_DEVICE_DIR)/../common - device/khadas/common,
# which does not exist. releasetools.py itself is optional (core/Makefile:6035 takes
# it through $(wildcard)), so this only needs to name a real directory.
TARGET_RELEASETOOLS_EXTENSIONS := device/khadas/edge
