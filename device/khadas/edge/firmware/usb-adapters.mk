# Khadas Edge1 - firmware for USB Wi-Fi and Bluetooth adapters.
#
# Included from device.mk. The drivers are built into the kernel (see the kernel
# config fragment, "USB Wi-Fi and Bluetooth adapters"), and a built-in USB driver
# probes an adapter that is plugged in at power-on within the first two seconds -
# before /vendor is mounted - so every file goes into the ramdisk's /lib/firmware
# as well as /vendor/firmware, like the AP6398S's. The files are linux-firmware's;
# usb/README.md says which commit and under which licences.
#
# Generated from the directory listing; regenerate rather than edit by hand:
#   build/dev/gen-usb-firmware-mk.sh
PRODUCT_COPY_FILES += \
    device/khadas/edge/firmware/usb/ath9k_htc/htc_7010-1.4.0.fw:$(TARGET_COPY_OUT_VENDOR)/firmware/ath9k_htc/htc_7010-1.4.0.fw \
    device/khadas/edge/firmware/usb/ath9k_htc/htc_9271-1.4.0.fw:$(TARGET_COPY_OUT_VENDOR)/firmware/ath9k_htc/htc_9271-1.4.0.fw \
    device/khadas/edge/firmware/usb/mediatek/BT_RAM_CODE_MT7961_1_2_hdr.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/mediatek/BT_RAM_CODE_MT7961_1_2_hdr.bin \
    device/khadas/edge/firmware/usb/mediatek/WIFI_MT7961_patch_mcu_1_2_hdr.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/mediatek/WIFI_MT7961_patch_mcu_1_2_hdr.bin \
    device/khadas/edge/firmware/usb/mediatek/WIFI_RAM_CODE_MT7961_1.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/mediatek/WIFI_RAM_CODE_MT7961_1.bin \
    device/khadas/edge/firmware/usb/mediatek/mt7601u.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/mediatek/mt7601u.bin \
    device/khadas/edge/firmware/usb/mediatek/mt7610u.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/mediatek/mt7610u.bin \
    device/khadas/edge/firmware/usb/mediatek/mt7662u.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/mediatek/mt7662u.bin \
    device/khadas/edge/firmware/usb/mediatek/mt7662u_rom_patch.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/mediatek/mt7662u_rom_patch.bin \
    device/khadas/edge/firmware/usb/rt2870.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rt2870.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8723b_fw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtl_bt/rtl8723b_fw.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8723d_fw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtl_bt/rtl8723d_fw.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8761b_config.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtl_bt/rtl8761b_config.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8761b_fw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtl_bt/rtl8761b_fw.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8761bu_config.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtl_bt/rtl8761bu_config.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8761bu_fw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtl_bt/rtl8761bu_fw.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8821c_config.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtl_bt/rtl8821c_config.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8821c_fw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtl_bt/rtl8821c_fw.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8822b_config.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtl_bt/rtl8822b_config.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8822b_fw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtl_bt/rtl8822b_fw.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8852bu_fw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtl_bt/rtl8852bu_fw.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8188eufw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtlwifi/rtl8188eufw.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8188fufw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtlwifi/rtl8188fufw.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8192cufw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtlwifi/rtl8192cufw.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8192cufw_A.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtlwifi/rtl8192cufw_A.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8192cufw_B.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtlwifi/rtl8192cufw_B.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8192cufw_TMSC.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtlwifi/rtl8192cufw_TMSC.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8192eu_nic.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtlwifi/rtl8192eu_nic.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8192fufw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtlwifi/rtl8192fufw.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8710bufw_SMIC.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtlwifi/rtl8710bufw_SMIC.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8710bufw_UMC.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtlwifi/rtl8710bufw_UMC.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8723bu_nic.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtlwifi/rtl8723bu_nic.bin \
    device/khadas/edge/firmware/usb/rtw88/rtw8723d_fw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtw88/rtw8723d_fw.bin \
    device/khadas/edge/firmware/usb/rtw88/rtw8821c_fw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtw88/rtw8821c_fw.bin \
    device/khadas/edge/firmware/usb/rtw88/rtw8822b_fw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtw88/rtw8822b_fw.bin \
    device/khadas/edge/firmware/usb/rtw88/rtw8822c_fw.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/rtw88/rtw8822c_fw.bin \
    device/khadas/edge/firmware/usb/ath9k_htc/htc_7010-1.4.0.fw:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/ath9k_htc/htc_7010-1.4.0.fw \
    device/khadas/edge/firmware/usb/ath9k_htc/htc_9271-1.4.0.fw:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/ath9k_htc/htc_9271-1.4.0.fw \
    device/khadas/edge/firmware/usb/mediatek/BT_RAM_CODE_MT7961_1_2_hdr.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/mediatek/BT_RAM_CODE_MT7961_1_2_hdr.bin \
    device/khadas/edge/firmware/usb/mediatek/WIFI_MT7961_patch_mcu_1_2_hdr.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/mediatek/WIFI_MT7961_patch_mcu_1_2_hdr.bin \
    device/khadas/edge/firmware/usb/mediatek/WIFI_RAM_CODE_MT7961_1.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/mediatek/WIFI_RAM_CODE_MT7961_1.bin \
    device/khadas/edge/firmware/usb/mediatek/mt7601u.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/mediatek/mt7601u.bin \
    device/khadas/edge/firmware/usb/mediatek/mt7610u.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/mediatek/mt7610u.bin \
    device/khadas/edge/firmware/usb/mediatek/mt7662u.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/mediatek/mt7662u.bin \
    device/khadas/edge/firmware/usb/mediatek/mt7662u_rom_patch.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/mediatek/mt7662u_rom_patch.bin \
    device/khadas/edge/firmware/usb/rt2870.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rt2870.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8723b_fw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtl_bt/rtl8723b_fw.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8723d_fw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtl_bt/rtl8723d_fw.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8761b_config.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtl_bt/rtl8761b_config.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8761b_fw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtl_bt/rtl8761b_fw.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8761bu_config.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtl_bt/rtl8761bu_config.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8761bu_fw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtl_bt/rtl8761bu_fw.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8821c_config.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtl_bt/rtl8821c_config.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8821c_fw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtl_bt/rtl8821c_fw.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8822b_config.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtl_bt/rtl8822b_config.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8822b_fw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtl_bt/rtl8822b_fw.bin \
    device/khadas/edge/firmware/usb/rtl_bt/rtl8852bu_fw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtl_bt/rtl8852bu_fw.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8188eufw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtlwifi/rtl8188eufw.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8188fufw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtlwifi/rtl8188fufw.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8192cufw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtlwifi/rtl8192cufw.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8192cufw_A.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtlwifi/rtl8192cufw_A.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8192cufw_B.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtlwifi/rtl8192cufw_B.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8192cufw_TMSC.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtlwifi/rtl8192cufw_TMSC.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8192eu_nic.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtlwifi/rtl8192eu_nic.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8192fufw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtlwifi/rtl8192fufw.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8710bufw_SMIC.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtlwifi/rtl8710bufw_SMIC.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8710bufw_UMC.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtlwifi/rtl8710bufw_UMC.bin \
    device/khadas/edge/firmware/usb/rtlwifi/rtl8723bu_nic.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtlwifi/rtl8723bu_nic.bin \
    device/khadas/edge/firmware/usb/rtw88/rtw8723d_fw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtw88/rtw8723d_fw.bin \
    device/khadas/edge/firmware/usb/rtw88/rtw8821c_fw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtw88/rtw8821c_fw.bin \
    device/khadas/edge/firmware/usb/rtw88/rtw8822b_fw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtw88/rtw8822b_fw.bin \
    device/khadas/edge/firmware/usb/rtw88/rtw8822c_fw.bin:$(TARGET_COPY_OUT_RAMDISK)/lib/firmware/rtw88/rtw8822c_fw.bin
