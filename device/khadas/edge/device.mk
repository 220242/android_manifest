#
# Khadas Edge1 (RK3399) - Android TV 14 device configuration.
#
# Every HAL below is listed with the Android 10 HIDL interface it replaces.
# docs/HAL_MIGRATION.md carries the full matrix and the per-HAL rationale.
#

LOCAL_PATH := device/khadas/edge

# EDGE1_ENABLE_INCOMPLETE_HALS is gone, along with every package it gated. It
# selected the Rockchip Android 10 HALs - libGLES_mali, libgralloc_rk3399,
# audio.primary.rk3399, libcodec2_rk and the rest - which this port no longer
# forward-ports and whose source is no longer in the manifest. On a mainline
# kernel they could not work even if they built: the Mali blob talks to the BSP's
# midgard kmod, and this kernel has panfrost.


# ---------------------------------------------------------------------------
# The kernel image.
#
# AOSP 14 expects the kernel at $(PRODUCT_OUT)/kernel and provides no mechanism
# to put it there: TARGET_PREBUILT_KERNEL, which the Android 10 tree relied on,
# does not appear anywhere in build/make any more. core/Makefile:1018 defines
# INSTALLED_KERNEL_TARGET as that path and leaves producing it to the device -
# its own diagnostic says so, "installing the built kernel to
# $(PRODUCT_OUT)/kernel". Without this copy, boot.img fails at the end of a long
# build on a missing file with no rule to make it.
#
# The path is the out-of-tree build from build/build-kernel.sh, which runs before
# the platform build. The dependency is not expressed to ninja, which is the
# trade-off of building the kernel separately: rebuild the kernel, then rebuild.
PRODUCT_COPY_FILES += \
    kernel/mainline/out/arch/arm64/boot/Image:kernel


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
    $(LOCAL_PATH)/permissions/khadas_edge_excluded_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/khadas_edge_excluded_hardware.xml

# android.hardware.opengles.aep.xml was copied here, carried over from the BSP
# where the Mali blob supported the Android Extension Pack. AEP requires GLES 3.1
# plus a specific extension set, and panfrost on Midgard delivers 3.0 - declaring
# it would tell applications to ask for what is not there. Same reasoning as the
# audio policy declaring only the formats the HAL can actually produce.
#
# The deqp level file dragonboard also copies is left out for the same reason: it
# states which dEQP suite the driver passes, and nothing here has run one.

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
# ---------------------------------------------------------------------------
# Verified against the module list of a synced android-14.0.0_r75 tree
# (build/windows/provision-wsl.sh probe). AOSP 14 ships a complete graphics
# stack that needs no vendor code:
#
#   android.hardware.graphics.allocator-service.minigbm  AIDL allocator V2
#   mapper.minigbm                                       IMapper 5 (stable-c)
#   gralloc.minigbm                                      gralloc0 backend
#   hwcomposer.drm_minigbm                               drm_hwcomposer HWC2
#   android.hardware.graphics.composer@2.4-service       HIDL passthrough composer
#
# minigbm has a rockchip backend and drm_hwcomposer is a generic atomic-KMS
# composer, which the Rockchip DRM driver supports. Together they replace three
# things that were blocking this port: the hand-written allocator shim, the
# unported libgralloc_rk3399, and an unwritten composer3 service whose
# IComposerClient has 48 methods.
#
# Note drm_hwcomposer in AOSP 14 is HWC2 only - its tree contains hwc2_device/
# and no composer3 references at all - so the composer is declared as HIDL
# @2.4 rather than AIDL composer3. That is why vintf/manifest.xml declares
# composer@2.4.
#
# The tradeoff: minigbm's rockchip backend does not implement the RK3399's AFBC
# layouts, so composition moves more bytes than Rockchip's own gralloc did.
# ---------------------------------------------------------------------------

PRODUCT_PACKAGES += \
    android.hardware.graphics.allocator-service.minigbm \
    mapper.minigbm \
    gralloc.minigbm \
    android.hardware.graphics.composer@2.4-service \
    hwcomposer.drm_minigbm

# GLES: Mesa's panfrost driver, and it is not optional.
#
# AOSP 14 has no software GLES driver that a real device can load. The old
# libGLES_android was removed years ago, and swiftshader is packaged for the
# emulator's host side only - the tree defines no libEGL_swiftshader. So without
# a driver here SurfaceFlinger does not start, and "boot on software rendering
# first, sort out the GPU later" is not an option that exists.
#
# What does exist is external/mesa3d, which is the whole reason this port moved to
# a mainline kernel: panfrost binds to drivers/gpu/drm/panfrost and gives the
# Mali-T860 GLES with no proprietary blob. Android's EGL loader looks for
# libGLES_$(ro.hardware.egl).so, which Mesa installs as libGLES_mesa.
#
# Which driver Mesa builds is BOARD_GPU_DRIVERS in BoardConfig.mk - confirmed as
# the variable external/mesa3d reads, not guessed: its Android.mk has
#   MESA_BUILD_GALLIUM := $(strip $(foreach d, $(BOARD_GPU_DRIVERS), ...))
#
# The rest of this block is copied from device/linaro/dragonboard's Mesa
# integration, the one working example of this in the tree, rather than assembled
# from what seemed necessary. Three things came from it that were missing here:
#
#   PRODUCT_SOONG_NAMESPACES. external/mesa3d refuses to build without it -
#     "external/mesa3d must be in PRODUCT_SOONG_NAMESPACES" (its Android.mk:41) -
#     and that was the whole of the last build failure.
#   The other five packages. libGLES_mesa alone is not the driver: the EGL loader
#     also resolves libEGL_mesa and the two libGLESv*_mesa entry points, and the
#     gallium driver itself lives in libgallium_dri with libglapi under it.
#   ro.opengles.version. The framework reports what this says, not what the driver
#     can do. 196608 is 3.0 (0x30000), which is what panfrost delivers on Midgard;
#     claiming 3.1 here would only make applications ask for what is not there.
#
# Vulkan is deliberately absent, which is where this diverges from dragonboard:
# panvk on Midgard is not something to depend on, and HWUI uses GLES unless told
# otherwise. So no vulkan.* package and no android.hardware.vulkan permission.
PRODUCT_SOONG_NAMESPACES += \
    external/mesa3d

PRODUCT_PACKAGES += \
    libGLES_mesa \
    libEGL_mesa \
    libGLESv1_CM_mesa \
    libGLESv2_mesa \
    libgallium_dri \
    libglapi

PRODUCT_PROPERTY_OVERRIDES += \
    ro.hardware.egl=mesa \
    ro.opengles.version=196608 \
    ro.hardware.gralloc=minigbm \
    ro.hardware.hwcomposer=drm_minigbm


# BOARD_USES_MINIGBM was set here, in a product makefile. It is a board variable
# and now lives in BoardConfig.mk: product config runs first, so the value did
# survive, but a BOARD_* variable assigned from the product side is the kind of
# ordering dependency that breaks quietly when the build system moves.

PRODUCT_PROPERTY_OVERRIDES += \
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

# There is no Rockchip audio shim any more. It wrapped the Android 10
# audio_hw_device, which left the tree with hardware/rockchip, and on a mainline
# kernel the path is ALSA through the HDMI codec anyway.
# AOSP's reference audio HAL. hardware/interfaces/audio/aidl/default is a full
# AIDL implementation with ALSA support, and this board's audio is tinyalsa over
# the HDMI i2s and S/PDIF cards, so it is a far better starting point than
# wrapping the Android 10 audio_hw_device. Real module names, from the probe:
# .service-aidl.example, not -service.example.
PRODUCT_PACKAGES += \
    android.hardware.audio.service-aidl.example \
    android.hardware.audio.effect.service-aidl.example

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
# AOSP's examples are functional stand-ins: tv.input publishes no streams (which
# is correct for the Edge1 - it has no tuner or HDMI-in), and the CEC example
# drives the standard Linux /dev/cec0 adapter, which is what the RK3399's
# dw-hdmi-cec exposes. HDMI-CEC may well work with these unchanged.
PRODUCT_PACKAGES += \
    android.hardware.tv.input-service.example \
    android.hardware.tv.hdmi.cec-service \
    android.hardware.tv.hdmi.connection-service

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
# BCM4359 needs no vendor Wi-Fi HAL - which is just as well, because the vendor
# one that exists is written for bcmdhd's private nl80211 commands and this kernel
# runs brcmfmac.
#
# brcmfmac loads one firmware image plus the board NVRAM through the kernel
# firmware loader, unlike bcmdhd which took separate STA/AP/P2P images through
# module parameters. Both files come from this owner's OpenWrt build for the same
# board - see wifi/firmware/brcm/README.md.
#
# What is not settled: android.hardware.wifi-service needs a legacy HAL
# underneath for link statistics, RTT and roaming control, and brcmfmac provides
# none of those vendor commands. Basic STA association is expected to work;
# anything that asks the HAL for vendor features will not. The module probe dumps
# what the tree offers here.
# ---------------------------------------------------------------------------
PRODUCT_PACKAGES += \
    android.hardware.wifi-service \
    wpa_supplicant \
    wpa_supplicant.conf \
    hostapd \
    wificond

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/wifi/wpa_supplicant_overlay.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/wpa_supplicant_overlay.conf \
    $(LOCAL_PATH)/wifi/p2p_supplicant_overlay.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/p2p_supplicant_overlay.conf \
    $(LOCAL_PATH)/wifi/firmware/brcm/brcmfmac4359-sdio.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/brcm/brcmfmac4359-sdio.bin \
    $(LOCAL_PATH)/wifi/firmware/brcm/brcmfmac4359-sdio.txt:$(TARGET_COPY_OUT_VENDOR)/firmware/brcm/brcmfmac4359-sdio.txt

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
# brcm_patchram_plus is a Broadcom tool from the Rockchip vendor tree, not AOSP,
# The BCM4359 still needs its firmware patch loaded over uart0 before an HCI device
# exists, and that question is open: the kernel's hci_bcm driver would do it and
# then own the port, while this HAL expects to open the tty itself. See
# init.edge1.rc. The service is installed either way - it costs nothing and is what
# a solution would plug into.
PRODUCT_PACKAGES += \
    android.hardware.bluetooth-service.default

# bluetooth/bt_vendor.conf was copied here. It configured libbt-vendor - the
# Broadcom vendor library of the HIDL era - with the UART, baud rates and the
# BCM4359C0.hcd patchram path. Nothing in this build reads it, so the file and the
# whole bluetooth/ directory are gone: installing a config nothing reads is worse
# than having none, because it suggests Bluetooth is configured.

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
# Rockchip MPP userspace: Android 10 revisions, not yet building against the 14
# VNDK, so gated with the rest.

# No vendor Codec2 service. The probe shows AOSP 14 has no
# c2@1.2-service.software - the software codecs live in the framework's own
# Codec2 store (libcodec2_soft_*), which needs no vendor HAL. 4K HEVC/VP9 will
# not play at full rate without the MPP hardware decoder, but SD/HD software
# decode works.

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/media/media_profiles_edge1.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_profiles_V1_0.xml

PRODUCT_PROPERTY_OVERRIDES += \
    debug.stagefright.ccodec=4 \
    media.c2.dmabuf.padding=512

# The hardware codec list is installed only when the Rockchip Codec2 store is
# actually built. Copying it unconditionally would advertise c2.rk.* decoders
# with no component registered, and MediaCodec.configure() then throws instead of
# falling back to a software codec.

# DRM: Widevine L3 only. L1 needs an OP-TEE trusted app, and this board has no
# provisioned TEE.
# clearkey only. Widevine is not in AOSP - drm@4.0-service.widevine comes from
# vendor/widevine, which this overlay does not sync. Add that project and this
# package together if Widevine L3 is wanted.
PRODUCT_PACKAGES += \
    android.hardware.drm-service.clearkey

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

# AOSP examples. Consequence of each fallback, so the tradeoff is visible:
#   light    - absent entirely, see above
#   power    - no RK3399 big.LITTLE/devfreq boost hints, so UI latency is worse
#   memtrack - Mali allocations are missing from dumpsys meminfo
# No light HAL: the only AOSP variant is .cuttlefish, which drives a virtio
# device. The Edge1's single power LED is not worth a HAL, and the framework
# copes with its absence.
PRODUCT_PACKAGES += \
    android.hardware.power-service.example \
    android.hardware.memtrack-service.example

# KeyMint / Gatekeeper: software ("nonsecure") implementations.
#
# This is a deliberate, documented downgrade. The RK3399 has no provisioned
# TEE on the Edge1 and no OP-TEE, so there is no hardware keystore. Consequence: hardware key attestation is unavailable and the build
# cannot pass CTS/GTS attestation tests. See docs/HAL_MIGRATION.md.
# keymint-service is AOSP's software KeyMint. There is no '.nonsecure' variant -
# the probe shows only the plain service plus .rust/.trusty/.strongbox/.remote.
PRODUCT_PACKAGES += \
    android.hardware.security.keymint-service

# No Gatekeeper HAL. AOSP 14 ships only .trusty and .remote variants, both of
# which need a TEE this board does not have. Without it, keyguard falls back to
# the framework's own credential checking: PIN and pattern still work, but
# without hardware-enforced throttling.

# ro.hardware.power / .lights / .memtrack were set here, naming the Rockchip HIDL
# passthrough libraries. The AIDL services are found on their binder service
# name, not through a property, and the libraries are gone - so pointing these at
# rk3399 would only send the framework looking for files that do not exist. The
# whole assignment went with them.


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

# parameter.txt and package-file were copied into $(PRODUCT_OUT) here, as inputs
# to Rockchip's update.img packer. Both are gone: the layout is now an ordinary
# GPT in flash/partitions.tsv, which build/build.sh turns into a flash script, and
# nothing needs to be staged into the product output for it.

PRODUCT_PROPERTY_OVERRIDES += \
    ro.product.board=rk3399 \
    ro.board.platform=rk3399 \
    ro.sf.lcd_density=213
