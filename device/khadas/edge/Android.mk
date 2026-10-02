# Khadas Edge1 - the one Make module this device tree defines.
#
# edge1_no_configstore keeps android.hardware.configstore@1.1-service out of the
# image. The build adds that service by itself: core/main.mk installs
# PRODUCT_PACKAGES_SHIPPING_API_LEVEL_29 on any product whose shipping level is 29
# or lower, and target/product/base_vendor.mk puts configstore in that list. Ours is
# 29 (edge1_tv.mk says why). But configstore is a deprecated HIDL HAL that neither
# VINTF manifest declares, so hwservicemanager refuses to register it:
#   F android.hardware.configstore@1.1-service: Could not register ISurfaceFlingerConfigs
# and it crash-looped until init flagged an "updatable" process crashing before
# boot completed (tenth card). Nothing needs it: SurfaceFlinger reads the same
# settings from ro.surface_flinger.* properties and falls back to defaults.
#
# A product list cannot take a module back out, and inheriting base_vendor.mk is
# not optional. An override can: product-installed-modules (core/main.mk) filters
# out every module named in an installed module's LOCAL_OVERRIDES_MODULES. ETC is
# one of the three classes base_rules.mk accepts that from, so the module is a text
# file saying what it is for.
LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := edge1_no_configstore
LOCAL_LICENSE_KINDS := SPDX-license-identifier-Apache-2.0
LOCAL_LICENSE_CONDITIONS := notice
LOCAL_MODULE_CLASS := ETC
LOCAL_VENDOR_MODULE := true
LOCAL_MODULE_RELATIVE_PATH := edge1
LOCAL_MODULE_STEM := no-configstore.txt
LOCAL_SRC_FILES := etc/no-configstore.txt
LOCAL_OVERRIDES_MODULES := android.hardware.configstore@1.1-service
include $(BUILD_PREBUILT)
