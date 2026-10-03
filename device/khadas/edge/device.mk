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
# atv_base.mk already declares android.hardware.type.television and
# android.software.leanback. Added here are the features the
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
    $(LOCAL_PATH)/permissions/khadas_edge_excluded_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/khadas_edge_excluded_hardware.xml

# Bluetooth features. Off for cards 15-16: with them declared and no working HAL,
# com.android.bluetooth aborted at once ("Can't start stack, last instance:
# starting HciHalHidl") and restarted every few seconds; without them
# BluetoothAdapter is null and TvSettings' "Add accessory" died on it
# (NullPointerException in BluetoothDevicePairer.start, card 16). Back now that
# the kernel brings up hci0 for the HAL - see the Bluetooth section below.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.bluetooth.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth.xml \
    frameworks/native/data/etc/android.hardware.bluetooth_le.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth_le.xml

# android.hardware.opengles.aep.xml was copied here, carried over from the BSP
# where the Mali blob supported the Android Extension Pack. AEP requires GLES 3.1
# plus a specific extension set, and panfrost on Midgard delivers 3.0 - declaring
# it would tell applications to ask for what is not there. Same reasoning as the
# audio policy declaring only the formats the HAL can actually produce.
#
# The deqp level file dragonboard also copies is left out for the same reason: it
# states which dEQP suite the driver passes, and nothing here has run one.

# TV apps. atv_base.mk brings TvProvider, TvSettings, TvSystemUI and the TV package
# installer, and no launcher: Google's TV launcher is part of GMS, not AOSP. Card 14
# booted to completion and stayed on TvSettings' FallbackHome - black - logging
# "User unlocked but no home; let's hope someone enables one soon?". Checked against
# what the board actually ran (every /system, /system_ext, /product app in card 14's
# logcat) and the synced tree's module list, these were missing and are needed on
# a TV box without GMS:
#
#   TvSampleLeanbackLauncher  AOSP's leanback launcher (device/google/atv): HOME
#   TvProvision               AOSP's stand-in for a setup wizard: marks the device
#                             provisioned and user setup complete on first boot,
#                             then disables itself. Without one nothing does
#                             ("There should probably be exactly one setup wizard;
#                             found 0"), and HOME, notifications and some settings
#                             behave as on a device still being set up
#   LeanbackIME               the TV on-screen keyboard. There was no IME at all,
#                             so no text field - a Wi-Fi password, a search - could
#                             be filled in with the remote
#   DocumentsUI               the system file picker and Files: installing an APK
#                             from a USB stick, and any app's "open file", go
#                             through it
#
# Each privileged one comes with its privapp-permission allowlist: a privileged app
# whose allowlist is missing stops system_server at boot when the allowlist is
# enforced. All of these modules are in the synced tree (Probe stage module list).
# Left out on purpose: phone apps (Dialer, Contacts, messaging), Launcher3, Gallery2,
# Music and Camera2 - nothing on a TV box uses them, and each costs space on /system.
#
# LiveTv is the TIF reference tuner UI, and it is what makes the
# android.software.live_tv feature declaration meaningful.
# F-Droid, the AOSP-world app store, preinstalled on /product. Not listed here:
# build/fetch-fdroid.sh downloads it (verifying F-Droid's signing certificate) into
# vendor/edge1/fdroid/ with a fdroid.mk that adds the package, and when that fails
# the image is built without it rather than not at all.
$(call inherit-product-if-exists, vendor/edge1/fdroid/fdroid.mk)

# Edge1 Tools (apps/Edge1Tools): the performance overlay (FPS of the app in front,
# per-core CPU load and clocks, GPU clock, temperatures, memory, display mode,
# hardware decoders) and the first-boot installer for the bundled apps.
# The bundled apps themselves - every APK in D:\android_khadas\apks, plus VLC,
# Material Files and Aurora Store from F-Droid - come from build/fetch-apps.sh,
# which writes vendor/edge1/apps/apps.mk (or nothing, if there is no app at all).
# Projectivy Launcher, if among them, becomes the default launcher. See
# build/apps/apps.tsv.
PRODUCT_PACKAGES += \
    Edge1Tools
$(call inherit-product-if-exists, vendor/edge1/apps/apps.mk)

PRODUCT_PACKAGES += \
    TvSampleLeanbackLauncher \
    privapp_whitelist_com.example.sampleleanbacklauncher \
    TvProvision \
    privapp_whitelist_com.android.tv.provision \
    LeanbackIME \
    DocumentsUI \
    privapp_whitelist_com.android.documentsui \
    LiveTv

# UI sound effects (D-pad ticks, keyboard clicks), which atv_base does not bring:
# card 16's AudioService logged "SoundPool could not load file" for all six. The
# TV set is the one Google's own TV products use.
$(call inherit-product-if-exists, frameworks/base/data/sounds/AudioTv.mk)

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
# from what seemed necessary. Two things came from it that were missing here:
#
#   PRODUCT_SOONG_NAMESPACES. external/mesa3d refuses to build without it -
#     "external/mesa3d must be in PRODUCT_SOONG_NAMESPACES" (its Android.mk:41) -
#     and that was the whole of the last build failure.
#   ro.opengles.version. The framework reports what this says, not what the driver
#     can do. 196608 is 3.0 (0x30000), which is what panfrost delivers on Midgard;
#     claiming 3.1 here would only make applications ask for what is not there.
#
# What was NOT copied from dragonboard, on purpose: libEGL_mesa,
# libGLESv1_CM_mesa, libGLESv2_mesa and libgallium_dri. dragonboard lists all
# four, but nothing in this tree defines them - two independent scans of the
# synced tree agree, one over every Android.bp/Android.mk in it and one over
# external/mesa3d alone, and the only EGL/GLES modules mesa3d defines are
# libGLES_mesa and libglapi. Those four names come from the newer meson-based
# Mesa packaging, which this snapshot does not use (dragonboard's default is
# BOARD_USE_CUSTOMIZED_MESA, a prebuilt).
#
# Naming them cost nothing and bought nothing, which is the problem:
# core/main.mk:1341 only checks that PRODUCT_PACKAGES exist when a product opts
# in with PRODUCT_ENFORCE_PACKAGES_EXIST, so a name that matches no module is
# dropped in silence. The list read like five libraries being installed when one
# was.
#
# One library is the supported form. frameworks/native's EGL loader takes
# libGLES_$(ro.hardware.egl).so as a single combined driver, and only falls back
# to the libEGL_/libGLESv1_CM_/libGLESv2_ triplet when that is absent.
#
# Vulkan is deliberately absent, which is where this diverges from dragonboard:
# panvk on Midgard is not something to depend on, and HWUI uses GLES unless told
# otherwise. So no vulkan.* package and no android.hardware.vulkan permission.
PRODUCT_SOONG_NAMESPACES += \
    external/mesa3d

PRODUCT_PACKAGES += \
    libGLES_mesa \
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

# has_HDR_display was true, carried over from the BSP's hwcomposer. Nothing in
# this display path passes HDR metadata to the TV (drm_hwcomposer reports no HDR
# capabilities), so claiming HDR only invites apps to pick HDR streams that would
# then be shown as SDR, washed out.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.surface_flinger.max_frame_buffer_acquired_buffers=3 \
    ro.surface_flinger.has_wide_color_display=false \
    ro.surface_flinger.has_HDR_display=false \
    debug.sf.disable_backpressure=1

# sys.hwc.device.primary=HDMI-A / sys.hwc.device.extend=DP were set here. Both
# are gone, for two independent reasons:
#
#   - Nothing reads them. They are Rockchip's own hwcomposer properties, read by
#     hardware/rockchip/hwcomposer, which left the tree with the rest of the BSP.
#     drm_hwcomposer takes no display hint - it enumerates DRM connectors and
#     uses the first connected one, which on this board is HDMI.
#   - "sys." is not a prefix a vendor partition may own. check_prop_prefix
#     rejected the property_contexts line that labelled it and stopped the build
#     at 71%, six hours in; VTS enforces the same rule on device.

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
# The two binaries alone did not give a running HAL on the ninth card: audioserver's
# "start vendor.audio-hal-aidl" found no such service and servicemanager found no
# android.hardware.audio.core.IModule/default in VINTF - the service's .rc and VINTF
# fragment ship in the vendor APEX com.android.hardware.audio, which is how Android
# 14 packages the default AIDL HAL. Added only if the tree has it, so a release that
# renamed it does not stop the build.
ifneq ($(wildcard hardware/interfaces/audio/aidl/default/apex/com.android.hardware.audio/Android.bp),)
PRODUCT_PACKAGES += com.android.hardware.audio
endif

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/audio/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    $(LOCAL_PATH)/audio/mixer_paths.xml:$(TARGET_COPY_OUT_VENDOR)/etc/mixer_paths.xml \
    $(LOCAL_PATH)/audio/audio_effects_config.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_effects_config.xml

# The shared parts of the audio policy - the r_submix and usb modules, the volume
# tables - are inlined in audio/audio_policy_configuration.xml, which says why. They
# were installed here as modules (r_submix_audio_policy_configuration,
# usb_audio_policy_configuration, default_volume_tables,
# audio_policy_engine_configuration) and pulled in with xi:include; on the tenth card
# the AIDL HAL rejected the file and found no engine configuration in /vendor/etc
# either. The engine configuration is not needed: the HAL reports none, and
# audioserver then uses its built-in default strategies (EngineBase.cpp).

# bluetooth_audio_policy_configuration was copied here too, renamed on the way in -
# the AOSP file is bluetooth_audio_policy_configuration_7_0.xml and the copy landed
# it without the suffix, which is what our xi:include named. Installing the module
# instead would keep the _7_0 in the filename and the include would not resolve.
#
# It is dropped rather than renamed: Bluetooth does not come up on this board yet
# (see init.edge1.rc), so there is nothing for a Bluetooth audio policy to describe,
# and the include is gone from audio_policy_configuration.xml with it.

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
    ro.hdmi.cec.source.send_standby_on_sleep=to_tv \
    persist.sys.hdmi.keep_awake=false

# ---------------------------------------------------------------------------
# Wi-Fi.
#
# A10: android.hardware.wifi@1.3, wifi.supplicant@1.2, wifi.hostapd@1.1
# A14: wifi.supplicant-V3 (AIDL), wifi.hostapd-V2 (AIDL), and no IWifi.
#
# No vendor Wi-Fi HAL (android.hardware.wifi-service). It was installed until card
# 16, and with nothing beneath it - its legacy HAL, libwifi-hal, picks a vendor
# implementation by BOARD_WLAN_DEVICE, and every one of those speaks a vendor
# driver's private nl80211 commands, which brcmfmac does not have - it failed
# every start: "Can not initialize the vendor function pointer table", and the
# framework, seeing IWifi declared, refused to bring Wi-Fi up at all ("Failed to
# start vendor HAL"). With no IWifi declared the framework runs HAL-less
# (WifiNative "Vendor Hal not supported"): wificond scans, wpa_supplicant
# associates, the interface is wifi.interface. Lost: STA+AP concurrency, link
# layer stats, RTT - nothing a TV box uses. GloDroid ships mainline brcmfmac
# boards the same way.
#
# wpa_supplicant and hostapd exist only when BoardConfig.mk sets
# WPA_SUPPLICANT_VERSION (external/wpa_supplicant_8/Android.mk), and the module
# probe greps for LOCAL_MODULE names without evaluating that guard - so on card 16
# neither was on the image and the framework logged "No HIDL or AIDL service
# available for SupplicantStaIfaceHal". wpa_supplicant.conf is not a package
# here: the module of that name is defined by wpa_supplicant_conf.mk, which only
# vendor Wi-Fi HAL directories include. The template is ours, below.
#
# Firmware: brcmfmac is built in and probes at 1.4s, before /vendor is mounted,
# so the files are in the ramdisk's /lib/firmware as well - see the kernel config
# fragment. The /vendor copies serve any later reload.
# ---------------------------------------------------------------------------
PRODUCT_PACKAGES += \
    wpa_supplicant \
    hostapd \
    wificond

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/wifi/wpa_supplicant.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/wpa_supplicant.conf \
    $(LOCAL_PATH)/wifi/wpa_supplicant_overlay.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/wpa_supplicant_overlay.conf \
    $(LOCAL_PATH)/wifi/p2p_supplicant_overlay.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/p2p_supplicant_overlay.conf

# AP6398S firmware: Wi-Fi image + board NVRAM, and the Bluetooth patchram.
# Each into /vendor/firmware and the ramdisk; wifi/firmware/brcm/README.md has
# where they come from.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/wifi/firmware/brcm/brcmfmac4359-sdio.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/brcm/brcmfmac4359-sdio.bin \
    $(LOCAL_PATH)/wifi/firmware/brcm/brcmfmac4359-sdio.txt:$(TARGET_COPY_OUT_VENDOR)/firmware/brcm/brcmfmac4359-sdio.txt \
    $(LOCAL_PATH)/wifi/firmware/brcm/BCM4359C0.hcd:$(TARGET_COPY_OUT_VENDOR)/firmware/brcm/BCM4359C0.hcd \
    $(LOCAL_PATH)/wifi/firmware/brcm/brcmfmac4359-sdio.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/brcm/brcmfmac4359-sdio.bin \
    $(LOCAL_PATH)/wifi/firmware/brcm/brcmfmac4359-sdio.txt:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/brcm/brcmfmac4359-sdio.txt \
    $(LOCAL_PATH)/wifi/firmware/brcm/BCM4359C0.hcd:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/brcm/BCM4359C0.hcd

# USB Wi-Fi and Bluetooth adapters: firmware for the ones the kernel has drivers
# for (firmware/usb/README.md lists them), and the same ramdisk-and-vendor pair.
include $(LOCAL_PATH)/firmware/usb-adapters.mk

PRODUCT_PROPERTY_OVERRIDES += \
    wifi.interface=wlan0 \
    wifi.direct.interface=p2p-dev-wlan0 \
    ro.vendor.wifi.sap.interface=wlan1

# ---------------------------------------------------------------------------
# Bluetooth.
#
# A10: android.hardware.bluetooth@1.0 over a Broadcom H4 UART with libbt-vendor.
# A14: android.hardware.bluetooth-V1 (AIDL), AOSP's default service.
# ---------------------------------------------------------------------------
# The kernel does the Broadcom part: hci_bcm owns uart0 (a serdev child in the
# DTS), powers the BCM4359, loads brcm/BCM4359C0.hcd and registers hci0. The AOSP
# HAL tries an HCI user channel on hci0 before any tty (net_bluetooth_mgmt.cpp)
# and passes raw HCI to the stack from there - no libbt-vendor, no
# brcm_patchram_plus. Card 14's crash loop was this HAL waiting for an hci0 that
# never came.
#
# One trap in that HAL: before binding it soft-blocks the Bluetooth rfkill switch
# it finds in /dev/rfkill, and the kernel refuses to open a blocked hci0
# (hci_dev_open_sync: -ERFKILL) - so with /dev/rfkill readable the bind fails. The
# node is therefore left at its default root-only mode (ueventd.edge1.rc); the
# HAL logs "rfkill unavailable" and carries on.
#
# Not here yet: A2DP audio. The audio HAL's bluetooth module wants
# IBluetoothAudioProviderFactory, which nothing on this image provides (card 16:
# "Failed to create bluetooth audio provider factory"), so the A2DP source profile
# is off until it does; remotes, keyboards and gamepads (HID host) do not need it.
PRODUCT_PACKAGES += \
    android.hardware.bluetooth-service.default

PRODUCT_PROPERTY_OVERRIDES += \
    ro.vendor.bluetooth.device=bcm4359 \
    bluetooth.device.class_of_device?=38,4,36 \
    bluetooth.profile.a2dp.source.enabled?=false \
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
# Task profiles. PRODUCT_SHIPPING_API_LEVEL is 29, so libprocessgroup also loads
# /system/etc/task_profiles/task_profiles_29.json, which re-points eleven profiles
# (HighPerformance, MaxPerformance, ...) at the schedtune controller - an Android
# common kernel feature mainline never had. The ninth card logged "failed to open
# /dev/stune/top-app/cgroup.procs" for every process that asked for one. The vendor
# file is loaded last (TaskProfiles::TaskProfiles) and replaces profiles by name, so
# this one restores those eleven exactly as the base task_profiles.json of this
# release defines them: the cpu controller and uclamp attributes 6.12 does have.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/task_profiles.json:$(TARGET_COPY_OUT_VENDOR)/etc/task_profiles.json

# The same shipping level also installs android.hardware.configstore@1.1-service,
# which no VINTF manifest declares and which crash-looped on the tenth card.
# Android.mk in this directory has the module that overrides it away.
PRODUCT_PACKAGES += edge1_no_configstore

# ---------------------------------------------------------------------------
# Shared memory: memfd, not ashmem.
#
# ashmem is an Android common kernel driver; mainline removed it from staging in
# 5.18, and 6.12 has no /dev/ashmem. libcutils' ashmem_create_region uses memfd
# instead, but only when sys.use_memfd is true (libcutils/ashmem-dev.cpp,
# __has_memfd_support; it defaults to false in this release). Without it every
# region failed, and the first casualty was the display: the composer's command
# queue is an FMQ in such a region, so SurfaceFlinger logged
#   E ashmem: Unable to open ashmem device /dev/ashmem<boot id> ... and /dev/ashmem
#   E HwcComposer: failed to prepare a new message queue
#   E HWComposer: presentAndGetReleaseFences: present failed for display 0: NoResources
# for every frame (tenth card). memfd needs only MEMFD_CREATE and F_SEAL_FUTURE_WRITE,
# both in 6.12.
#
# A product property, not PRODUCT_PROPERTY_OVERRIDES: that goes to /vendor/build.prop,
# and init loads vendor property files with vendor_init's permissions, which do not
# cover system properties like this one. /product/etc/build.prop loads as init.
#
# The property alone was not enough: rootdir/init.rc sets sys.use_memfd false again
# in post-fs-data, and the tenth card read false. init/init.edge1.memfd.rc sets it
# back right after, from /product so that init runs it without vendor_init's limits.
PRODUCT_PRODUCT_PROPERTIES += sys.use_memfd=true
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/init/init.edge1.memfd.rc:$(TARGET_COPY_OUT_PRODUCT)/etc/init/init.edge1.memfd.rc

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

# ro.product.board, ro.board.platform and ro.sf.lcd_density were set here. All
# three are emitted by core/main.mk from board variables, so they are set as those
# variables in BoardConfig.mk instead - see the note there for what the duplicate
# cost.
#
# Worth knowing when reading the rest of this file: on a device with a vendor
# partition, PRODUCT_PROPERTY_OVERRIDES goes to /vendor/build.prop, not
# /system/build.prop. core/sysprop.mk:368-380 lists it among the vendor
# build.prop's inputs when property_overrides_split_enabled is set, and drops it
# from the system one. Properties are global at run time, so this does not change
# who can read them - but it does mean every line in this file is a vendor
# property, which is why the duplicate above was found in vendor/build.prop.

# ---------------------------------------------------------------------------
# Installing onto the internal storage, from the card.
#
# The card is the install: it boots on its own with the eMMC untouched, and pulling
# it out puts the board back. Once it boots reliably, the same system belongs on the
# eMMC or the M.2 SSD - and the only thing that can write those is something already
# running on the board, because neither is removable.
#
# So the installer travels inside the image it installs. It copies the running
# card partition by partition and sizes the target to the real device, which is the
# one thing the fixed edge1-emmc.img and edge1-nvme.img cannot do: userdata gets the
# whole SSD rather than the 14GiB the image was built for.
#
# The layout is installed beside it rather than written into it, so that
# flash/partitions.tsv stays the single source of truth for the GPT. The image
# builder, the generated eMMC flash script and this installer all read that one file.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/bin/edge1-install-internal.sh:$(TARGET_COPY_OUT_VENDOR)/bin/edge1-install-internal.sh \
    $(LOCAL_PATH)/bin/edge1-bootwatch.sh:$(TARGET_COPY_OUT_VENDOR)/bin/edge1-bootwatch.sh \
    $(LOCAL_PATH)/flash/partitions.tsv:$(TARGET_COPY_OUT_VENDOR)/etc/edge1-partitions.tsv

# sgdisk writes the GPT on the target. It is not assumed to be present: it comes
# from external/gptfdisk, which AOSP builds as a device binary because vold uses it
# to partition adoptable storage - but "vold uses it" is not the same as "it is in
# this product", and a missing module is dropped from PRODUCT_PACKAGES in silence
# unless PRODUCT_ENFORCE_PACKAGES_EXIST is set. The module probe resolves every name
# in this file against the synced tree in about a minute, so if this one is wrong
# the next report says so rather than the installer failing on the board.
PRODUCT_PACKAGES += \
    sgdisk
