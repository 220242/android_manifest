#
# Khadas Edge1 (Rockchip RK3399) - Android TV 14 product configuration.
#
# Board:   Khadas Edge1 (VIM-family "Edge", RK3399)
# SoC:     Rockchip RK3399 - 2x Cortex-A72 + 4x Cortex-A53, Mali-T860MP4
# Display: HDMI 2.0 (4K@60) primary, DisplayPort over USB-C secondary
# Net:     AP6398S (Broadcom BCM4359) WiFi 5 + BT 5.0, Gigabit Ethernet
# Kernel:  4.19.111, kedge_defconfig, rk3399-khadas-edge-android.dts
#

# ---------------------------------------------------------------------------
# Android TV base.
#
# device/google/atv supplies the leanback system configuration: TvProvider,
# TvSettings, LeanbackLauncher, the television device-type feature set,
# tv-specific SystemUI and the TIF (TV Input Framework) plumbing.
#
# The legacy tree instead used device/rockchip/common/tv/tv_base.mk. That file
# is unusable on 14: it still lists libstagefright_soft_* codecs, PicoTts,
# Browser, DefaultContainerService and local_time.default, none of which exist
# after Android 9. Nothing from it is inherited here; the TV-specific pieces it
# provided are re-expressed below against 14 APIs.
# ---------------------------------------------------------------------------
ATV_BASE := device/google/atv/products/atv_base.mk
ifeq ($(wildcard $(ATV_BASE)),)
  $(error device/google/atv is not synced. Android TV requires it. \
          Run 'repo sync device/google/atv' or confirm the local manifest in \
          manifests/khadas_edge_tv14.xml was applied.)
endif
$(call inherit-product, $(ATV_BASE))

# 64-bit primary with 32-bit support retained. The RK3399 has a large amount
# of armeabi-v7a-only prebuilt vendor code (Mali userspace, OMX IL), so this
# board cannot go 64-bit-only.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)

PRODUCT_NAME    := edge1_tv
PRODUCT_DEVICE  := edge
PRODUCT_MODEL   := Khadas Edge1
PRODUCT_BRAND   := Khadas
PRODUCT_MANUFACTURER := Khadas
PRODUCT_CHARACTERISTICS := tv,nosdcard

# ---------------------------------------------------------------------------
# Shipping API level.
#
# Deliberately 29 (Android 10), NOT 34.
#
# PRODUCT_SHIPPING_API_LEVEL selects which Treble/VTS rule set applies. Setting
# 34 would declare Edge1 an Android 14 *launch* device and pull in launch-only
# requirements it cannot satisfy: kernel >= 5.15 (this board has 4.19.111),
# 64-bit-only userspace, and the 14 GKI ABI. Declaring 29 keeps the correct
# *upgrade* device rules, under which a 4.19 kernel and 32-bit vendor code are
# both legal.
# ---------------------------------------------------------------------------
PRODUCT_SHIPPING_API_LEVEL := 29

# VNDK. Vendor code is built against the current VNDK snapshot rather than a
# frozen Android 10 one, because the Rockchip HALs are being forward-ported
# rather than kept binary-stable.
PRODUCT_TARGET_VNDK_VERSION := current

# ---------------------------------------------------------------------------
# Display / density.
#
# The legacy product declared "normal large mdpi tvdpi hdpi xhdpi" with a
# preferred density of hdpi, which is a tablet profile. Android TV renders a
# 1080p leanback UI at tvdpi (213dpi); 4K output is handled by surface scaling,
# not by a 2160p-native density.
# ---------------------------------------------------------------------------
PRODUCT_AAPT_CONFIG := normal large tvdpi hdpi xhdpi
PRODUCT_AAPT_PREF_CONFIG := tvdpi

# ---------------------------------------------------------------------------
# Board hardware feature flags consumed by device.mk.
# Sensor support is dropped relative to the tablet config: the Edge1 has no
# accelerometer/compass/gyro populated, and declaring them on a TV SKU makes
# the framework wait on sensor HALs that will never publish.
# ---------------------------------------------------------------------------
BOARD_HAS_GPS                  := false
BOARD_NFC_SUPPORT              := false
BOARD_GRAVITY_SENSOR_SUPPORT   := false
BOARD_COMPASS_SENSOR_SUPPORT   := false
BOARD_GYROSCOPE_SENSOR_SUPPORT := false
BOARD_LIGHT_SENSOR_SUPPORT     := false
BOARD_USB_HOST_SUPPORT         := true
BOARD_HAS_HDMI_CEC             := true
BOARD_HAS_ETHERNET             := true
PRODUCT_HAS_CAMERA             := false

# Widevine L3 (the L1 TEE path needs OP-TEE, which is off for this target).
BUILD_WITH_WIDEVINE := true
PRODUCT_HAVE_OPTEE  := false

$(call inherit-product, device/khadas/edge/device.mk)

# ---------------------------------------------------------------------------
# Build fingerprint / identity.
# ---------------------------------------------------------------------------
PRODUCT_BUILD_PROP_OVERRIDES += \
    PRODUCT_NAME=edge1_tv \
    PRIVATE_BUILD_DESC="edge1_tv-userdebug 14 UP1A 1 release-keys"

PRODUCT_PROPERTY_OVERRIDES += \
    ro.oem.key1=edge1 \
    ro.product.first_api_level=29

# adb over TCP is convenient on a headless-ish TV box during bring-up and is
# gated to non-user builds.
ifneq ($(TARGET_BUILD_VARIANT),user)
PRODUCT_PROPERTY_OVERRIDES += \
    service.adb.tcp.port=5555 \
    ro.adb.secure=0
PRODUCT_PROPERTY_OVERRIDES += persist.sys.usb.config=mtp,adb
else
PRODUCT_PROPERTY_OVERRIDES += \
    ro.adb.secure=1 \
    persist.sys.usb.config=mtp
endif
