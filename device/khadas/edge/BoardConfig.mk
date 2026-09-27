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
TARGET_KERNEL_DTS := rk3399-khadas-edge
TARGET_KERNEL_ARCH := arm64

# TARGET_PREBUILT_KERNEL is not set: the string "PREBUILT_KERNEL" appears nowhere
# in AOSP 14's build/make. core/Makefile:1018 defines INSTALLED_KERNEL_TARGET as
# $(PRODUCT_OUT)/kernel and leaves producing it to the device, so device.mk copies
# the Image there.
#
# The device tree blob goes into vendor_boot, which is where boot header v4 keeps
# it. BOARD_PREBUILT_DTBIMAGE_DIR is globbed for *.dtb at Kati parse time and
# everything found is concatenated into dtb.img - so it points at a directory
# build-kernel.sh stages with exactly one dtb, not at the kernel's dts output,
# which holds about ninety.
#
# BOARD_PREBUILT_DTBOIMAGE is gone with the BSP: it pointed at Rockchip's
# resource.img, an RSCE container holding the dtb and the boot logos that only
# Rockchip's own bootloader reads. Mainline U-Boot takes the dtb from
# vendor_boot like any other Android device.
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

# Boot image header v4 + a separate vendor_boot, which is what Android 13+
# expects. The vendor ramdisk carries the board's init stages; with a mainline
# kernel there are no vendor modules to load from it.
BOARD_BOOT_HEADER_VERSION := 4
BOARD_MKBOOTIMG_ARGS := --header_version $(BOARD_BOOT_HEADER_VERSION)

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
# driver at run time. That is the failure mode to avoid, because it looks like a
# working build.
#
# panfrost is the Midgard/Bifrost gallium driver and binds to
# drivers/gpu/drm/panfrost, which this kernel builds in. kmsro is what lets it
# render on a display controller that is not the GPU - the Rockchip VOP here -
# which is exactly the split this SoC has.
#
# No BOARD_MESA3D_VULKAN_DRIVERS: panvk on Midgard is not something to depend on,
# and nothing in this configuration asks for Vulkan.
BOARD_MESA3D_GALLIUM_DRIVERS := panfrost kmsro

# 4608 MiB super. Leaves room on a 16GB eMMC for userdata.
BOARD_SUPER_PARTITION_SIZE := 4831838208
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

BOARD_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 67108864
# No BOARD_DTBOIMG_PARTITION_SIZE and no dtbo partition: the dtb travels inside
# vendor_boot on this path, so there is no dtbo.img to give a partition to.
BOARD_FLASH_BLOCK_SIZE := 131072

BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_ODMIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
# BOARD_USE_SPARSE_SYSTEM_IMAGE was set here. It is a Rockchip variable, absent
# from AOSP 14; sparse images are controlled per filesystem type, and by
# TARGET_USERIMAGES_SPARSE_EXT_DISABLED if they ever need turning off.

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

# ---------------------------------------------------------------------------
# fstab / recovery.
# ---------------------------------------------------------------------------
TARGET_RECOVERY_FSTAB := device/khadas/edge/fstab.edge1
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
TARGET_RECOVERY_DEFAULT_ROTATION := ROTATION_NONE
TARGET_USERIMAGES_SPARSE_EXT_DISABLED := false

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
BOARD_VNDK_VERSION := current

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
BOARD_BLUETOOTH_BDROID_BUILDCFG_INCLUDE_DIR := device/khadas/edge/bluetooth

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
TARGET_RELEASETOOLS_EXTENSIONS := device/khadas/edge
