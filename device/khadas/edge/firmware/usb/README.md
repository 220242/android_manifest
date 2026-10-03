# Firmware for USB Wi-Fi and Bluetooth adapters

From linux-firmware (gitlab.com/kernel-firmware/linux-firmware), commit
`d947e4e8e314e9254a1242dc1a5d9cede2cce33d`, at the same paths, so the kernel finds
them under `/lib/firmware` (ramdisk) and `/vendor/firmware`. Licences are in
`LICENSES/`, as linux-firmware's WHENCE assigns them: all redistributable,
ath9k_htc's free software.

| Files | Driver (built in) | Typical adapters |
|---|---|---|
| `rtw88/rtw8821c_fw.bin` | rtw88_8821cu | RTL8811CU/8821CU (AC600 dongles) |
| `rtw88/rtw8822b_fw.bin` | rtw88_8822bu | RTL8812BU/8822BU (AC1200) |
| `rtw88/rtw8822c_fw.bin` | rtw88_8822cu | RTL8822CU |
| `rtw88/rtw8723d_fw.bin` | rtw88_8723du | RTL8723DU |
| `rtlwifi/rtl8188eufw.bin`, `rtl8188fufw.bin`, `rtl8192cufw*.bin`, `rtl8192eu_nic.bin`, `rtl8192fufw.bin`, `rtl8723bu_nic.bin`, `rtl8710bufw_*.bin` | rtl8xxxu | the cheap 802.11n nano dongles (RTL8188EU/FU/CU, 8192CU/EU/FU, 8723BU, 8188GU) |
| `mediatek/mt7601u.bin` | mt7601u | MT7601U |
| `mediatek/mt7610u.bin` | mt76x0u | MT7610U (AC600) |
| `mediatek/mt7662u*.bin` | mt76x2u | MT7612U (AC1200, e.g. Alfa AWUS036ACM) |
| `mediatek/WIFI_*MT7961*.bin`, `BT_RAM_CODE_MT7961_1_2_hdr.bin` | mt7921u, btusb | MT7921AU (Wi-Fi 6 + Bluetooth) |
| `ath9k_htc/htc_9271-1.4.0.fw`, `htc_7010-1.4.0.fw` | ath9k_htc | AR9271 (TL-WN722N v1), AR7010 |
| `rt2870.bin` | rt2800usb | RT2870/RT3070/RT3572/RT5370/RT5372 |
| `rtl_bt/rtl8761b*`, `rtl8761bu*` | btusb (Realtek) | RTL8761B/BU Bluetooth 5 dongles (TP-Link UB500 and most "BT 5.0" sticks) |
| `rtl_bt/rtl8821c*`, `rtl8822b*`, `rtl8723b*`, `rtl8723d*`, `rtl8852bu*` | btusb (Realtek) | the Bluetooth half of Realtek combo adapters |

CSR8510 and Broadcom BCM20702 Bluetooth sticks need no firmware file.

Adapters needing drivers that 6.12 does not have are not covered: RTL8812AU/8821AU
(mainline from 6.14), RTL8852BU/8832BU Wi-Fi 6 (rtw89 USB, 6.17).

**Android uses one Wi-Fi interface and one Bluetooth controller.** The board's own
AP6398S comes up first as `wlan0` and `hci0`, so a USB adapter is `wlan1`/`hci1`
and idle unless told otherwise. For Wi-Fi:
`adb shell setprop persist.vendor.edge1.wifi.iface wlan1`, then reboot (empty it
to go back). The Bluetooth HAL always takes the first controller.

Regenerate `../usb-adapters.mk` after adding or removing a file here:
`build/dev/gen-usb-firmware-mk.sh`.
