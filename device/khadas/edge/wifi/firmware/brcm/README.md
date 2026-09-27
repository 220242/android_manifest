# brcmfmac firmware for the AP6398S

`brcmfmac4359-sdio.bin` is the BCM4359 SDIO firmware, `brcmfmac4359-sdio.txt` the
board NVRAM. Both come from this owner's OpenWrt build for the same board
(github.com/220242/khadas_edge-openwrt, `boards/khadas-edge-v/wifi`), where they
are known to associate and pass traffic on mainline brcmfmac. The NVRAM's own
header identifies it: `AP6398S_NVRAM_V2.0_20191009A`, `AP6359SA_V1.1NVRAM`.

They install to `/vendor/firmware/brcm/`, which is both what
`firmware_class.path` on the kernel command line points at and one of ueventd's
default firmware directories.

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
