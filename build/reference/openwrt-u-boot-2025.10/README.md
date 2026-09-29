# A U-Boot that is known to boot this board from an SD card

These two files are not built by this tree and are not shipped in any image. They
exist for one purpose: to answer, with a single card write, a question that three
cards could not.

## Where they come from

The board's owner built OpenWrt for this same Khadas Edge-V earlier, and that card
booted — it won over the Armbian on the eMMC every time. These are that build's
bootloader, taken from `boards/khadas-edge-v/u-boot/` of the OpenWrt tree:

| file | size | sha256 of the uncompressed file |
|---|---|---|
| `idbloader.img.gz` | 190464 uncompressed | `f3f9fc3be10127ccf66bd3aea0458cae3c8ded7b993d257671e9ff95b738e626` |
| `u-boot.itb.gz` | 1227776 uncompressed | `b8ab547be9fe21bc97e0b6cc8b33806b65d530c7ad7fc8c9955ce9fbfe36872c` |

It is U-Boot **2025.10**, `khadas-edge-v-rk3399_defconfig`, with one patch that adds
`CONFIG_VIDEO`, `CONFIG_DISPLAY`, `CONFIG_VIDEO_ROCKCHIP` and
`CONFIG_DISPLAY_ROCKCHIP_HDMI` — so it puts its banner on HDMI, which is what makes it
usable as a test on a board with no UART adapter.

## Why they answer the question

Our card does not boot. Two links can be at fault and they are indistinguishable from
the outside, because both end with Armbian booting off the eMMC:

1. the BootROM does not run the card's first stage at all, or
2. it does, and SPL then loads `u-boot.itb` from the eMMC instead of the card.

Writing a card with **this** bootloader and our Android partitions separates them
outright. It gets written to the same two sectors, by the same script:

- `U-Boot 2025.10` appears on HDMI → the BootROM does boot this card layout, and the
  fault is inside the U-Boot this tree builds.
- the screen stays blank and Armbian boots → the BootROM is not running the card at
  all, no change to our U-Boot can ever fix it, and the path forward is the SPI NOR
  (which is erased) or the eMMC.

It will not boot Android: its `bootcmd` is `bootflow scan -lb`, which knows nothing
about Android boot images. Reaching its prompt or its "no bootflow" message *is* the
result.

## How to use them

`build-images.sh` takes the pair through two variables and writes them at the same
sectors it writes `u-boot-rockchip.bin` to — 64 for the ID block, 16384 for the FIT,
which is where both Armbian and OpenWrt put them:

```sh
R=~/android_khadas/android_manifest/build/reference/openwrt-u-boot-2025.10
gunzip -kf "$R"/idbloader.img.gz "$R"/u-boot.itb.gz
EDGE1_UBOOT_IDB="$R/idbloader.img" \
EDGE1_UBOOT_ITB="$R/u-boot.itb" \
EDGE1_IMAGE_TAG=owboot \
  build/build-images.sh '' sdcard
```

The result is `edge1-sdcard-owboot.img`, identical to the normal card except for the
bootloader.

## Licence

U-Boot is GPL-2.0-or-later. These are unmodified build outputs of
[u-boot](https://source.denx.de/u-boot/u-boot) v2025.10 with the four-symbol HDMI
change described above; the matching source is upstream v2025.10 plus that change,
and the full `.config` the build used is recorded in the OpenWrt tree they came from.
