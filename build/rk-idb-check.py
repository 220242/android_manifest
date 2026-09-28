#!/usr/bin/env python3
"""Verify a Rockchip ID block - the thing the RK3399 BootROM looks for.

  usage: rk-idb-check.py <device-or-file> [sector]

  sector 0    the start of u-boot-rockchip.bin / u-boot-rockchip-spi.bin, and
              offset 0 of SPI NOR
  sector 64   where build-images.sh writes the bootloader on a card or eMMC

Why this script exists rather than a hexdump: the 512-byte block is RC4-encrypted
with a fixed key, so a CORRECT one looks like random data and an eyeball check is
worthless in both directions. U-Boot does it in tools/rkcommon.c:340 when writing
(unconditionally - the rk3399 entry at :150 disables RC4 for the SPL payload, not
for this header) and undoes it at :427 to verify, RC4 being symmetric. The key is
the one at tools/rkcommon.c:178-181.

Checking a card the board refused to boot from was the first use: it proved the
write was correct and moved the search to where the BootROM was looking instead.

Exit 0 if the block is valid, 1 if not, 2 if it could not be read.
"""
import sys
import struct

RK_MAGIC = 0x0ff0aa55
KEY = bytes([124, 78, 3, 4, 85, 5, 9, 7, 45, 44, 123, 56, 23, 13, 23, 17])


def rc4(buf, key):
    """Byte-for-byte what lib/rc4.c does: the key is repeated to 256 bytes for
    the KSA, then standard PRGA."""
    s = list(range(256))
    k = [key[i & 0x0f] for i in range(256)]
    j = 0
    for i in range(256):
        j = (j + s[i] + k[i]) % 256
        s[i], s[j] = s[j], s[i]
    out = bytearray(len(buf))
    i = j = 0
    for p in range(len(buf)):
        i = (i + 1) % 256
        j = (j + s[i]) % 256
        s[i], s[j] = s[j], s[i]
        out[p] = buf[p] ^ s[(s[i] + s[j]) % 256]
    return bytes(out)


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    dev = sys.argv[1]
    sector = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    try:
        with open(dev, 'rb') as f:
            f.seek(sector * 512)
            raw = f.read(512)
    except OSError as e:
        print(f"{dev}: {e}", file=sys.stderr)
        return 2
    if len(raw) != 512:
        print(f"{dev}: could not read 512 bytes at sector {sector}", file=sys.stderr)
        return 2

    if raw == b'\xff' * 512:
        print(f"{dev} sector {sector}: erased (all 0xff) - nothing here")
        return 1
    if raw == b'\x00' * 512:
        print(f"{dev} sector {sector}: all zero - nothing here")
        return 1

    dec = rc4(raw, KEY)
    # struct header0_info, tools/rkcommon.c: magic, reserved[4], disable_rc4,
    # init_offset, reserved1[492], init_size, init_boot_size, reserved2[2]
    magic, _, disable_rc4, init_offset = struct.unpack_from('<I4sIH', dec, 0)
    init_size, init_boot_size = struct.unpack_from('<HH', dec, 506)

    print(f"{dev} sector {sector}:")
    print(f"  raw first 8 bytes  {raw[:8].hex(' ')}"
          "   (RC4-scrambled; a valid block always looks random here)")
    if magic != RK_MAGIC:
        print(f"  decrypted magic    0x{magic:08x}  NOT a Rockchip ID block"
              f" (expected 0x{RK_MAGIC:08x})")
        return 1
    print(f"  decrypted magic    0x{magic:08x}  valid Rockchip ID block")
    print(f"  init_offset        {init_offset} blocks ({init_offset * 512} bytes)")
    print(f"  init_size          {init_size} blocks ({init_size * 512} bytes)")
    print(f"  init_boot_size     {init_boot_size} blocks ({init_boot_size * 512} bytes)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
