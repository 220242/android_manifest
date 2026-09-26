#
# Khadas Edge1 (RK3399) - Android TV 14 device configuration.
#
# Every HAL below is listed with the Android 10 HIDL interface it replaces.
# docs/HAL_MIGRATION.md carries the full matrix and the per-HAL rationale.
#

LOCAL_PATH := device/khadas/edge

# ---------------------------------------------------------------------------
# EDGE1_ENABLE_INCOMPLETE_HALS
#
# Several Rockchip HALs are mid-forward-port: the AIDL shim exists in outline
# but does not build yet (see shims/README.md for the exact state of each).
# Pulling them into PRODUCT_PACKAGES unconditionally would stop every build at a
# gap that is already documented, which makes the rest of the tree untestable.
#
# Default false: build with AOSP's generic implementations where one exists, and
# simply omit the HAL where none does. Set to true to build the Rockchip shims
# once they are finished:
#
#   EDGE1_ENABLE_INCOMPLETE_HALS=true m
#
# docs/STATUS.md tracks which HALs still flip this.
# ---------------------------------------------------------------------------
EDGE1_ENABLE_INCOMPLETE_HALS ?= false


# ---------------------------------------------------------------------------
# Treble / VINTF.
# ---------------------------------------------------------------------------
PRODUCT_PACKAGES += \
    vndk_package

PRODUCT_ENFORCE_RRO_TARGETS := *

# ---------------------------------------------------------------------------
# Android TV: device type, leanback and TIF.
#
# atv_base.mk already declares android.hardware.type.television,
# android.software.leanback and the launcher. Added here are the features the
# legacy device/rockchip/common/tv/permissions/tv_core_hardware.xml declared
# that are board facts rather than TV facts.
#
# Note the legacy file declared android.software.leanback_only with
# android.software.leanback commented out. That pair is wrong on 14:
# leanback_only without leanback makes the framework treat the device as
# leanback-capable-but-not-leanback and LeanbackLauncher will not be resolved
# as HOME. atv_base.mk declares both correctly, so this tree does not override
# them.
# ---------------------------------------------------------------------------
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.hdmi.cec.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.hdmi.cec.xml \
    frameworks/native/data/etc/android.hardware.ethernet.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.ethernet.xml \
    frameworks/native/data/etc/android.hardware.usb.host.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.host.xml \
    frameworks/native/data/etc/android.hardware.wifi.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.xml \
    frameworks/native/data/etc/android.hardware.wifi.direct.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.direct.xml \
    frameworks/native/data/etc/android.hardware.bluetooth.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth.xml \
    frameworks/native/data/etc/android.hardware.bluetooth_le.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth_le.xml \
    frameworks/native/data/etc/android.hardware.opengles.aep.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.opengles.aep.xml \
    $(LOCAL_PATH)/permissions/khadas_edge_excluded_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/khadas_edge_excluded_hardware.xml

# TV apps. TvProvider/TvSettings come from atv_base.mk; LiveTv is the TIF
# reference tuner UI and is what makes android.software.live_tv meaningful.
# atv_base.mk already provides the leanback launcher, TvProvider and
# TvSettings. Only LiveTv is added: it is the TIF reference tuner UI, and it is
# what makes the android.software.live_tv feature declaration meaningful.
PRODUCT_PACKAGES += \
    LiveTv

# Leanback/TV device overlays (density, HDMI-driven screen config, no rotation).
DEVICE_PACKAGE_OVERLAYS += $(LOCAL_PATH)/overlay

# ---------------------------------------------------------------------------
# Graphics.
#
# A10: android.hardware.graphics.allocator@2.0 (gralloc0 passthrough)
#      android.hardware.graphics.mapper@{2.0,3.0}
#      android.hardware.graphics.composer@2.{1,2,3}
#      implementations: hardware/rockchip/libgralloc/midgard (Mali-T860,
#      Midgard) and hardware/rockchip/hwcomposer (drm_hwcomposer fork).
#
# A14: allocator -> AIDL android.hardware.graphics.allocator-V2
#      mapper    -> Gralloc4 (IMapper 4.0); IMapper 5.0 stable-c is the
#                   follow-up, tracked in docs/HAL_MIGRATION.md
#      composer  -> AIDL android.hardware.graphics.composer3-V3
# ---------------------------------------------------------------------------
# The allocator shim is implemented (shims/graphics/allocator).
PRODUCT_PACKAGES += \
    android.hardware.graphics.allocator-service.rk3399 \
    libgralloc_rk3399 \
    libGLES_mali

# The composer3 shim is not written yet. There is no usable AOSP fallback for a
# real display - drm_hwcomposer would have to be built against the Rockchip DRM
# driver - so without this the build produces an image that cannot composite.
# This is the single largest remaining gap; see docs/STATUS.md.
ifeq ($(EDGE1_ENABLE_INCOMPLETE_HALS),true)
PRODUCT_PACKAGES += android.hardware.graphics.composer3-service.rk3399
endif

# Mali-T860 userspace (proprietary, from vendor/rockchip).
# libRSDriverArm is deliberately absent: RenderScript was removed from the
# platform in Android 12, so the Android 10 tree's RS driver has no consumer.
PRODUCT_PACKAGES += \
    vulkan.rk3399

PRODUCT_PROPERTY_OVERRIDES += \
    ro.hardware.egl=mali \
    ro.hardware.vulkan=rk3399 \
    ro.hardware.gralloc=rk3399 \
    ro.hardware.hwcomposer=rk3399 \
    ro.surface_flinger.max_frame_buffer_acquired_buffers=3 \
    ro.surface_flinger.has_wide_color_display=false \
    ro.surface_flinger.has_HDR_display=true \
    debug.sf.disable_backpressure=1

# HDMI primary, DisplayPort-over-USB-C secondary. Carried over from the legacy
# product, which set these on the tablet SKU too.
PRODUCT_PROPERTY_OVERRIDES += \
    sys.hwc.device.primary=HDMI-A \
    sys.hwc.device.extend=DP

# ---------------------------------------------------------------------------
# Audio.
#
# A10: android.hardware.audio@5.0 + android.hardware.audio.effect@5.0,
#      wrapping the legacy audio_hw_device in hardware/rockchip/audio.
# A14: android.hardware.audio.core-V2 (AIDL). The AIDL audio HAL is the
#      default in 14; libaudiohal still has a HIDL@7.1 path but the Rockchip
#      HAL is at @5.0, so uprevving HIDL twice is more work than one AIDL shim.
#
# HDMI multichannel/passthrough matters far more on a TV box than on the
# tablet SKU this config came from, hence the explicit HDMI output profiles in
# audio/audio_policy_configuration.xml.
# ---------------------------------------------------------------------------
PRODUCT_PACKAGES += \
    audio.r_submix.default \
    audio.usb.default \
    libaudioroute \
    libtinyalsa \
    libtinycompress

# The audio.core shim opens the legacy device but has no stream I/O yet
# (shims/audio/RkAudioModule.cpp). Without it there is no HDMI audio.
ifeq ($(EDGE1_ENABLE_INCOMPLETE_HALS),true)
PRODUCT_PACKAGES += \
    android.hardware.audio.service.rk3399 \
    android.hardware.audio.effect-service.rk3399 \
    audio.primary.rk3399
else
# AOSP's AIDL effect service is generic and usable as-is; only the core module
# is board-specific.
PRODUCT_PACKAGES += \
    android.hardware.audio.effect-service.example
endif

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/audio/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    $(LOCAL_PATH)/audio/audio_policy_volumes.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_volumes.xml \
    $(LOCAL_PATH)/audio/mixer_paths.xml:$(TARGET_COPY_OUT_VENDOR)/etc/mixer_paths.xml \
    $(LOCAL_PATH)/audio/audio_effects.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_effects.xml

PRODUCT_COPY_FILES += \
    frameworks/av/services/audiopolicy/config/r_submix_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/r_submix_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/usb_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/usb_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/default_volume_tables.xml:$(TARGET_COPY_OUT_VENDOR)/etc/default_volume_tables.xml \
    frameworks/av/services/audiopolicy/config/audio_policy_engine_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_engine_configuration.xml \
    frameworks/av/services/audiopolicy/config/bluetooth_audio_policy_configuration_7_0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth_audio_policy_configuration.xml

PRODUCT_PROPERTY_OVERRIDES += \
    ro.hardware.audio.primary=rk3399 \
    persist.sys.media.avsync=true \
    ro.audio.monitorRotation=false

# ---------------------------------------------------------------------------
# TV Input Framework and HDMI-CEC.
#
# A10: android.hardware.tv.input@1.0, android.hardware.tv.cec@1.0
#      (tv_input.default stub + hardware/rockchip/hdmicec)
# A14: android.hardware.tv.input-V1 (AIDL), and tv.cec@1.0 is split three ways
#      into android.hardware.tv.hdmi.cec-V1, .hdmi.connection-V1 and
#      .hdmi.earc-V1. cec and connection are both required for a TV device
#      that declares android.hardware.hdmi.cec; earc is not (no eARC on the
#      RK3399 HDMI 2.0 TX).
# ---------------------------------------------------------------------------
ifeq ($(EDGE1_ENABLE_INCOMPLETE_HALS),true)
PRODUCT_PACKAGES += \
    android.hardware.tv.input-service.rk3399 \
    android.hardware.tv.hdmi.cec-service.rk3399 \
    android.hardware.tv.hdmi.connection-service.rk3399
else
# AOSP's examples are functional stand-ins: tv.input publishes no streams (which
# is correct for the Edge1 - it has no tuner or HDMI-in), and the CEC example
# drives the standard Linux /dev/cec0 adapter, which is what the RK3399's
# dw-hdmi-cec exposes. HDMI-CEC may well work with these unchanged.
PRODUCT_PACKAGES += \
    android.hardware.tv.input-service.example \
    android.hardware.tv.hdmi.cec-service.example \
    android.hardware.tv.hdmi.connection-service.example
endif

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/tv_input.xml:$(TARGET_COPY_OUT_VENDOR)/etc/tv_input.xml

PRODUCT_PROPERTY_OVERRIDES += \
    ro.hdmi.device_type=4 \
    ro.hdmi.cec.source.send_standby_on_sleep=true \
    persist.sys.hdmi.keep_awake=false

# ---------------------------------------------------------------------------
# Wi-Fi.
#
# A10: android.hardware.wifi@1.3, wifi.supplicant@1.2, wifi.hostapd@1.1
# A14: android.hardware.wifi-V1 (AIDL), wifi.supplicant-V3 (AIDL),
#      wifi.hostapd-V1 (AIDL).
#
# All three AOSP defaults are driver-agnostic nl80211 implementations, so the
# BCM4359 needs no vendor Wi-Fi HAL - only the firmware paths in
# BoardConfig.mk and the bcmdhd module. This removes an entire Rockchip HIDL
# component that existed only to wrap nl80211.
# ---------------------------------------------------------------------------
PRODUCT_PACKAGES += \
    android.hardware.wifi-service \
    wpa_supplicant \
    wpa_supplicant.conf \
    hostapd \
    wificond \
    libwpa_client

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/wifi/wpa_supplicant_overlay.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/wpa_supplicant_overlay.conf \
    $(LOCAL_PATH)/wifi/p2p_supplicant_overlay.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/p2p_supplicant_overlay.conf

PRODUCT_PROPERTY_OVERRIDES += \
    wifi.interface=wlan0 \
    wifi.direct.interface=p2p-dev-wlan0 \
    ro.vendor.wifi.sap.interface=wlan1

# ---------------------------------------------------------------------------
# Bluetooth.
#
# A10: android.hardware.bluetooth@1.0 over a Broadcom H4 UART with libbt-vendor.
# A14: android.hardware.bluetooth-V1 (AIDL). AOSP's
#      android.hardware.bluetooth-service.default speaks H4 directly, which the
#      BCM4359 supports once firmware patchram is loaded - handled by the
#      init.edge1.rc brcm_patchram_plus stage rather than by a HAL.
# ---------------------------------------------------------------------------
PRODUCT_PACKAGES += \
    android.hardware.bluetooth-service.default \
    brcm_patchram_plus \
    libbt-vendor

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/bluetooth/bt_vendor.conf:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth/bt_vendor.conf

PRODUCT_PROPERTY_OVERRIDES += \
    ro.vendor.bluetooth.device=bcm4359 \
    bluetooth.device.class_of_device?=38,4,36 \
    bluetooth.profile.a2dp.source.enabled?=true \
    bluetooth.profile.hfp.ag.enabled?=false \
    bluetooth.profile.hid.host.enabled?=true

# ---------------------------------------------------------------------------
# Media / codecs.
#
# Rockchip VPU: H.264/H.265/VP9 decode to 4K60, H.264 encode.
# A10 shipped OMX IL components; Codec2 is mandatory for new codecs on 14, so
# the OMX components are kept only as a fallback behind the Codec2 store.
# ---------------------------------------------------------------------------
PRODUCT_PACKAGES += \
    libvpu \
    librockchip_mpp

ifeq ($(EDGE1_ENABLE_INCOMPLETE_HALS),true)
PRODUCT_PACKAGES += \
    android.hardware.media.c2@1.2-service.rk3399 \
    libcodec2_rk
else
# Software Codec2 only. 4K HEVC/VP9 will not play at full rate without the MPP
# hardware decoder, but the device boots and plays SD/HD software-decoded video.
PRODUCT_PACKAGES += \
    android.hardware.media.c2@1.2-service.software
endif

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/media/media_profiles_edge1.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_profiles_V1_0.xml

PRODUCT_PROPERTY_OVERRIDES += \
    debug.stagefright.ccodec=4 \
    media.c2.dmabuf.padding=512

# The hardware codec list is installed only when the Rockchip Codec2 store is
# actually built. Copying it unconditionally would advertise c2.rk.* decoders
# with no component registered, and MediaCodec.configure() then throws instead of
# falling back to a software codec.
ifeq ($(EDGE1_ENABLE_INCOMPLETE_HALS),true)
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/media/media_codecs.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs.xml \
    $(LOCAL_PATH)/media/media_codecs_performance.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_performance.xml \
    $(LOCAL_PATH)/media/media_codecs_c2.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_c2.xml
PRODUCT_PROPERTY_OVERRIDES += ro.media.xml_variant.codecs=_c2
endif

# DRM: Widevine L3 only. L1 needs an OP-TEE trusted app, and
# PRODUCT_HAVE_OPTEE is false for this target.
PRODUCT_PACKAGES += \
    android.hardware.drm-service.clearkey \
    android.hardware.drm@4.0-service.widevine

# ---------------------------------------------------------------------------
# Remaining HALs, all HIDL -> AIDL.
#
#   health@2.0      -> android.hardware.health-V2 (AIDL)
#   light@2.0       -> android.hardware.light-V2 (AIDL)
#   power@1.0       -> android.hardware.power-V4 (AIDL)
#   thermal@1.0     -> android.hardware.thermal-V1 (AIDL)
#   memtrack@1.0    -> android.hardware.memtrack-V1 (AIDL)
#   usb@1.1         -> android.hardware.usb-V1 (AIDL)
#   boot@1.1        -> dropped: this is a non-A/B device. The Edge1 flashes a
#                      Rockchip update.img over the full partition set and
#                      keeps a discrete recovery partition, so there are no
#                      slots for a boot control HAL to select between.
#   keymaster@4.0   -> android.hardware.security.keymint-V3 (AIDL)
#   gatekeeper@1.0  -> android.hardware.gatekeeper-V1 (AIDL)
#   atrace@1.0      -> removed from the platform, no replacement needed
#   vibrator@1.0    -> dropped: no vibrator on this board
#   sensors@1.0     -> dropped: no sensors populated on the TV SKU
#   gnss@1.1        -> dropped: BOARD_HAS_GPS is false
#   nfc@1.2         -> dropped: BOARD_NFC_SUPPORT is false
# ---------------------------------------------------------------------------
PRODUCT_PACKAGES += \
    android.hardware.health-service.example \
    android.hardware.health-service.example_recovery \
    android.hardware.thermal-service.example \
    android.hardware.usb-service.example \
    android.hardware.dumpstate-service.example

ifeq ($(EDGE1_ENABLE_INCOMPLETE_HALS),true)
PRODUCT_PACKAGES += \
    android.hardware.light-service.rk3399 \
    android.hardware.power-service.rk3399 \
    android.hardware.memtrack-service.rk3399
else
# AOSP examples. Consequence of each fallback, so the tradeoff is visible:
#   light    - the blue power LED and HDMI backlight node are not driven
#   power    - no RK3399 big.LITTLE/devfreq boost hints, so UI latency is worse
#   memtrack - Mali allocations are missing from dumpsys meminfo
PRODUCT_PACKAGES += \
    android.hardware.light-service.example \
    android.hardware.power-service.example \
    android.hardware.memtrack-service.example
endif

# KeyMint / Gatekeeper: software ("nonsecure") implementations.
#
# This is a deliberate, documented downgrade. The RK3399 has no provisioned
# TEE on the Edge1 and PRODUCT_HAVE_OPTEE is false, so there is no hardware
# keystore. Consequence: hardware key attestation is unavailable and the build
# cannot pass CTS/GTS attestation tests. See docs/HAL_MIGRATION.md.
PRODUCT_PACKAGES += \
    android.hardware.security.keymint-service.nonsecure \
    android.hardware.gatekeeper-service.nonsecure

PRODUCT_PROPERTY_OVERRIDES += \
    ro.hardware.power=rk3399 \
    ro.hardware.lights=rk3399 \
    ro.hardware.memtrack=rk3399

# ---------------------------------------------------------------------------
# init / fstab.
# ---------------------------------------------------------------------------
# These are plain files installed by PRODUCT_COPY_FILES below, not Soong
# modules - listing them in PRODUCT_PACKAGES would fail with
# "module 'fstab.edge1' not found".
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/init/init.edge1.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.edge1.rc \
    $(LOCAL_PATH)/init/init.edge1.usb.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.edge1.usb.rc \
    $(LOCAL_PATH)/init/ueventd.edge1.rc:$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc \
    $(LOCAL_PATH)/fstab.edge1:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.edge1 \
    $(LOCAL_PATH)/fstab.edge1:$(TARGET_COPY_OUT_RAMDISK)/fstab.edge1

# Input: the Edge1 has an IR receiver and a power/function key row.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/input/Vendor_0001_Product_0001.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/Vendor_0001_Product_0001.kl \
    $(LOCAL_PATH)/input/rk29-keypad.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/rk29-keypad.kl \
    $(LOCAL_PATH)/input/ff420030_pwm.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/ff420030_pwm.kl

# ---------------------------------------------------------------------------
# Ethernet. Android TV boxes are usually wired, and the framework needs the
# interface allowlisted or EthernetTracker ignores it.
# ---------------------------------------------------------------------------
PRODUCT_PROPERTY_OVERRIDES += \
    ro.vendor.net.ethernet.interface=eth0

# No package is needed: config_ethernet_iface_regex and
# config_ethernet_interfaces are set by the framework overlay in
# overlay/frameworks/base/core/res/, which DEVICE_PACKAGE_OVERLAYS applies.

# ---------------------------------------------------------------------------
# Rockchip update.img packaging inputs.
# ---------------------------------------------------------------------------
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/parameter.txt:parameter.txt \
    $(LOCAL_PATH)/package-file:package-file

PRODUCT_PROPERTY_OVERRIDES += \
    ro.product.board=rk3399 \
    ro.board.platform=rk3399 \
    ro.sf.lcd_density=213
