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
# Kernel.
#
# 4.19.111 from the khadas-edge-Qt branch. Built out of tree by
# build/build-kernel.sh, which this tree consumes as a prebuilt so that a
# platform-only rebuild does not re-run the kernel build.
# ---------------------------------------------------------------------------
# kernel/khadas/edge, not "kernel": a project at path "kernel" would nest the
# upstream kernel/configs, kernel/tests and 26 kernel/prebuilts/* projects, and
# repo rejects overlapping paths. See manifests/khadas_edge_tv14.xml.
# These four are documentation, not wiring: AOSP 14 does not build kernels, and
# build/build-kernel.sh has the same values of its own. They are kept because
# they are the four facts anyone touching the kernel needs, in the file they
# would look in first. Change them here and in build-kernel.sh together.
TARGET_KERNEL_SOURCE := kernel/khadas/edge
TARGET_KERNEL_CONFIG := kedge_defconfig
TARGET_KERNEL_DTS := rk3399-khadas-edge-android
TARGET_KERNEL_ARCH := arm64
# TARGET_PREBUILT_KERNEL is not set here. The Android 10 tree used it, but the
# string "PREBUILT_KERNEL" does not appear anywhere in AOSP 14's build/make:
# core/Makefile:1018 sets INSTALLED_KERNEL_TARGET to $(PRODUCT_OUT)/kernel and
# expects the device to install the file itself. device.mk copies it there.
#
# resource.img is Rockchip's RSCE container holding the DTB and the boot logos,
# built by the kernel's own <dts>.img target. The legacy BSP pointed
# BOARD_PREBUILT_DTBOIMAGE at it, which is how it reaches the dtbo partition.
BOARD_PREBUILT_DTBOIMAGE := kernel/khadas/edge/resource.img

BOARD_KERNEL_CMDLINE := \
    console=ttyFIQ0 \
    androidboot.console=ttyFIQ0 \
    androidboot.hardware=rk30board \
    androidboot.baseband=N/A \
    firmware_class.path=/vendor/etc/firmware \
    init=/init \
    rootwait ro loop.max_part=7

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
# expects and what Rockchip's own post-11 BSPs ship. The vendor ramdisk carries
# the Rockchip-specific init stages and the bcmdhd/rtk firmware loader.
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
BOARD_DTBOIMG_PARTITION_SIZE := 8388608
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
# Connectivity: AP6398S = Broadcom BCM4359. Driver is the out-of-tree bcmdhd
# module built with the kernel.
# ---------------------------------------------------------------------------
BOARD_WLAN_DEVICE := bcmdhd
BOARD_WPA_SUPPLICANT_DRIVER := NL80211
WPA_SUPPLICANT_VERSION := VER_0_8_X
BOARD_WPA_SUPPLICANT_PRIVATE_LIB := lib_driver_cmd_bcmdhd
BOARD_HOSTAPD_DRIVER := NL80211
BOARD_HOSTAPD_PRIVATE_LIB := lib_driver_cmd_bcmdhd
WIFI_DRIVER_FW_PATH_PARAM := "/sys/module/bcmdhd/parameters/firmware_path"
# Firmware moved from /system/etc/firmware (Android 10) to /vendor/etc/firmware:
# Treble forbids vendor code reading firmware out of /system.
WIFI_DRIVER_FW_PATH_STA := "/vendor/etc/firmware/fw_bcm4359c0_ag.bin"
WIFI_DRIVER_FW_PATH_AP  := "/vendor/etc/firmware/fw_bcm4359c0_ag_apsta.bin"
WIFI_DRIVER_FW_PATH_P2P := "/vendor/etc/firmware/fw_bcm4359c0_ag_p2p.bin"

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
