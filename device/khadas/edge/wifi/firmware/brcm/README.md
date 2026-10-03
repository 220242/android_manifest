# Firmware for the AP6398S (BCM4359): Wi-Fi and Bluetooth

`brcmfmac4359-sdio.bin` is the BCM4359 SDIO firmware, `brcmfmac4359-sdio.txt` the
board NVRAM. Both come from this owner's OpenWrt build for the same board
(github.com/220242/khadas_edge-openwrt, `boards/khadas-edge-v/wifi`), where they
are known to associate and pass traffic on mainline brcmfmac. The NVRAM's own
header identifies it: `AP6398S_NVRAM_V2.0_20191009A`, `AP6359SA_V1.1NVRAM`.

`BCM4359C0.hcd` is the Bluetooth patchram, loaded by the kernel's `hci_bcm`/`btbcm`
over uart0 when hci0 is set up. It is Armbian's (github.com/armbian/firmware, commit
`2a9e1c19460401443267926181191d57e3ff175d`, `brcm/BCM4359C0.hcd`, sha256
`c4fed091688bcdd7a8bca2e8601f10eddddfca5d95a44f40a9fcc8a0868d7c8e`) - the file
Armbian ships for its AP6398S boards. It identifies itself as
`BCM4359C0 37.4MHz AMPAK AP6359S-0059`. btbcm names it from the controller's
subversion (0x6106 -> `BCM4359C0`) and tries `BCM4359C0.khadas,edge-v.hcd` first.

All three install twice: to `/vendor/firmware/brcm/`, which is what
`firmware_class.path` on the kernel command line points at, and to the ramdisk's
`/lib/firmware/brcm/`. The second copy is the one that is used. Both drivers are
built into the kernel and ask for their firmware within two seconds of power-on,
long before Android mounts /vendor; the firmware loader waits for the initramfs and
searches `/lib/firmware` after `firmware_class.path`. On card 16, with the /vendor
copy only, brcmfmac logged "Direct firmware load ... failed with error -2" at 1.4s
and gave up, and there was no wlan0.

The driver asks for `brcmfmac4359-sdio.<board-compatible>.txt` first and falls back
to the plain name, which is what is installed. The board compatible comes from the
root node of the dts, and for the dtb this port builds
(`rk3399-khadas-edge-v.dts`) it is `khadas,edge-v` — so the first name tried is
`brcmfmac4359-sdio.khadas,edge-v.txt`. Installing the board-specific name as well
would make the match explicit if a second Khadas carrier with different RF ever
needs its own.

This replaces the BSP's `fw_bcm4359c0_ag.bin` triple, which was bcmdhd's format
and is not interchangeable: bcmdhd took separate STA/AP/P2P firmware images
through module parameters, brcmfmac takes one image plus NVRAM through the kernel
firmware loader.
