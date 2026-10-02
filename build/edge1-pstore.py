#!/usr/bin/env python3
"""Turn edge1-pstore.bin back into the previous boot's kernel and Android logs.

    usage: edge1-pstore.py edge1-pstore.bin

The file is the kernel's ramoops region, copied off the RAM by boot.scr after a warm
reset and before the next kernel could clear it (see device/khadas/edge/flash/boot.cmd
and the ramoops block in build/build-kernel.sh). It is the board's only kernel log
until a UART adapter is attached.

Layout, as fs/pstore/ram.c (v6.12) lays it out from the dtb's sizes: the dmesg zones
first (record-size each), then console, then pmsg. Every zone starts with
struct persistent_ram_buffer - u32 sig ("DBGC", 0x43474244), u32 start, u32 size -
and is a ring buffer: the oldest byte is at start once it has wrapped, so the text
is data[start:size] + data[0:start] (persistent_ram_save_old).

  console   everything printk said, init's own "init: ..." lines included
  dmesg     the log at the moment of a panic or oops, behind a "====sec.nsec-C" line
  pmsg      what liblog wrote on a debuggable build: logcat, as of the reset
"""
import struct
import sys

SIG = 0x43474244
HDR = 12
# Must match build/build-kernel.sh.
RECORD, CONSOLE, PMSG = 0x20000, 0x80000, 0x40000

PRIO = {2: "V", 3: "D", 4: "I", 5: "W", 6: "E", 7: "F"}
LOGID = {0: "main", 1: "radio", 3: "system", 4: "crash", 7: "kernel"}


def zones(total):
    dump = total - CONSOLE - PMSG
    n = dump // RECORD
    out = [(f"dmesg.{i}", i * RECORD, RECORD) for i in range(n)]
    off = n * RECORD
    out.append(("console", off, CONSOLE))
    out.append(("pmsg", off + CONSOLE, PMSG))
    return out


def old_contents(blob, off, size):
    sig, start, used = struct.unpack_from("<III", blob, off)
    cap = size - HDR
    if sig != SIG:
        return None, f"no ramoops header (sig {sig:#010x})"
    if used > cap or start > cap:
        return None, f"header out of range (start {start}, size {used}, capacity {cap})"
    data = blob[off + HDR:off + HDR + cap]
    return data[start:used] + data[0:start], None


def text(b):
    return b.decode("utf-8", errors="replace").rstrip("\0")


def pmsg_lines(b):
    i, out = 0, []
    while i + 18 <= len(b):
        if b[i] != ord("l"):
            i += 1
            continue
        (ln, _uid, pid) = struct.unpack_from("<HHH", b, i + 1)
        (lid, tid, sec, nsec) = struct.unpack_from("<BHII", b, i + 7)
        if ln < 18 or i + ln > len(b) or lid > 7:
            i += 1
            continue
        payload = b[i + 18:i + ln]
        i += ln
        if lid not in LOGID or len(payload) < 2:
            continue                        # events/stats/security are binary
        prio = PRIO.get(payload[0], "?")
        tag, _, msg = payload[1:].partition(b"\0")
        out.append(f"{sec}.{nsec // 1000000:03d} {pid:5d} {tid:5d} {prio} "
                   f"{text(tag)}: {text(msg).rstrip()}  [{LOGID[lid]}]")
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    blob = open(sys.argv[1], "rb").read()
    if len(blob) < CONSOLE + PMSG + RECORD:
        sys.exit(f"{sys.argv[1]}: {len(blob)} bytes, smaller than the layout")
    found = 0
    for name, off, size in zones(len(blob)):
        data, why = old_contents(blob, off, size)
        print(f"===== {name} (offset {off:#x}) " + "=" * 40)
        if data is None:
            print(f"  {why}")
            continue
        found += 1
        if not data.strip(b"\0"):
            print("  (empty)")
        elif name == "pmsg":
            lines = pmsg_lines(data)
            print("\n".join(lines) if lines else "  (no log records)")
        else:
            print(text(data))
    if not found:
        print("\nNo zone carries the ramoops signature: the region was not written by our"
              "\nkernel, or did not survive the reset (a power cut always loses it).")


if __name__ == "__main__":
    main()
