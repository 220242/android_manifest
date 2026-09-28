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

# Dynamic partitions. This lives here rather than in BoardConfig.mk with the rest
# of the partition layout because it is a product variable: product config
# freezes those before BoardConfig.mk is read, and assigning it there failed with
# "cannot assign to readonly variable". board_config.mk reads it from product
# config to decide whether to build super_empty.img, and product_config.mk
# derives PRODUCT_BUILD_SUPER_PARTITION from it.
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# ART's userfaultfd GC, off. This is a kernel capability question, not a policy
# one: Android 14's default is PRODUCT_ENABLE_UFFD_GC := default, which makes
# post_process_props.py decide from the kernel version at build time, and the
# 4.19.111 kernel here has neither the userfaultfd feature set nor
# MREMAP_DONTUNMAP that the GC needs. Saying so explicitly also removes the
# build's dependency on reading the version back out of the kernel image, which
# is a separate mechanism that can fail on its own.
PRODUCT_ENABLE_UFFD_GC := false

# No VNDK settings here, and none in BoardConfig.mk either. VNDK is deprecated in
# this release: the build clears BOARD_VNDK_VERSION and PLATFORM_VNDK_VERSION
# outright when KEEP_VNDK is not true (core/config.mk:1266-1273), and the framework
# manifest provides no VNDK version for a device matrix to require. See
# vintf/compatibility_matrix.xml, which is where that cost a build.
#
# PRODUCT_TARGET_VNDK_VERSION was also set here once. It is not a variable AOSP 14
# reads anywhere and did nothing.

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
# Board hardware, for the record.
#
# The legacy tree set BOARD_HAS_GPS, BOARD_NFC_SUPPORT, the four
# BOARD_*_SENSOR_SUPPORT flags, BOARD_USB_HOST_SUPPORT, BOARD_HAS_HDMI_CEC,
# BOARD_HAS_ETHERNET, PRODUCT_HAS_CAMERA, PRODUCT_HAVE_OPTEE and
# BUILD_WITH_WIDEVINE here, and device/rockchip/common read them to decide what
# to install. Nothing in AOSP 14 reads any of them, and nothing in this tree does
# either, so setting them was decoration that read like configuration. What they
# encoded is now expressed where it takes effect:
#
#   no GPS, no NFC, no sensors  -> the HALs are simply absent from device.mk, and
#                                 the framework features are not declared in
#                                 permissions/. Declaring a sensor feature on a
#                                 TV SKU makes the framework wait on a HAL that
#                                 never publishes.
#   USB host, HDMI-CEC, Ethernet -> android.hardware.usb.host.xml,
#                                 the tv.hdmi.cec and tv.hdmi.connection
#                                 services, and the ethernet feature, all in
#                                 device.mk.
#   no OP-TEE                   -> Widevine stays L3: no TEE-backed L1 path, and
#                                 keymint is the software service.
#   no camera                   -> no camera HAL, no
#                                 android.hardware.camera*.xml.
# ---------------------------------------------------------------------------

$(call inherit-product, device/khadas/edge/device.mk)

# ---------------------------------------------------------------------------
# Build identity.
#
# PRODUCT_BUILD_PROP_OVERRIDES used to be set here with a hand-written
# PRIVATE_BUILD_DESC. AOSP 14 does not read that variable at all - the build
# description and fingerprint come from PRODUCT_NAME, PRODUCT_DEVICE, the
# release and the build id - so it was a no-op carrying a string that would have
# gone stale the moment the variant changed.
#
# ro.product.first_api_level is not set here either: core/main.mk already emits
# it from PRODUCT_SHIPPING_API_LEVEL. Setting both worked only while the two
# agreed, and post_process_props.py rejects duplicates that disagree - so
# raising the shipping level later would have failed the build.
# ---------------------------------------------------------------------------
PRODUCT_PROPERTY_OVERRIDES += \
    ro.oem.key1=edge1

# USB gadget. AOSP's init.usb.configfs.rc builds the whole gadget, but only when
# sys.usb.configfs is 1, and it binds it by writing ${sys.usb.controller} to UDC.
# Both are properties rather than init actions, because that file's own actions
# read them - setting them from an action races with the actions that consume it.
#
# fe800000.usb is the peripheral controller on this board, not a guess:
# rk3399-khadas-edge.dtsi sets dr_mode = "otg" on usbdrd_dwc3_0, which is
# usb@fe800000, and dr_mode = "host" on usbdrd_dwc3_1 at fe900000.
PRODUCT_PROPERTY_OVERRIDES += \
    sys.usb.configfs=1 \
    sys.usb.controller=fe800000.usb

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
