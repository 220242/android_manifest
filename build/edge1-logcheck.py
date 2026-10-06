#!/usr/bin/env python3
"""Read a card's logs and say which of the open checks passed.

    usage: edge1-logcheck.py [--boot N] [--all] PATH

PATH is what the owner sends back from the card's EDGE1BOOT drive: the drive's
folder itself, the edge1-logs folder, one boot-NNNNN folder, or a .zip of any of
them. Python 3 and nothing else, so it runs on the build machine (Windows or WSL)
as well as here.

What it reads is what device/khadas/edge/bin/edge1-bootwatch.sh writes (and
edge1-install-boot.sh, for an installer card):

  edge1-logs/boots.txt              a line per boot: started, options; how it ended
  boot-NNNNN/alive.txt              the last moment the boot was seen
  boot-NNNNN/logcat.txt, dmesg.txt  the whole boot
  boot-NNNNN/{120s,completed,timeout}/   snapshots: surfaceflinger.txt, audio.txt,
                                    misc.txt, packages.txt ...
  boot-NNNNN/playing-N.txt          while a video played: decode rate, DRM state,
                                    SurfaceFlinger
  boot-NNNNN/pstore/                the boot's ramoops, if it ended in a reset
  edge1-install.log                 the installer card's log

and the checks are the ones docs/HANDOFF.md lists for the card under test: boots
and resets, the 1080p menus (ui=), the hardware RNG, HDMI audio, HDMI-CEC, video on a display
plane, the overlay's alpha, temperatures, crashes, Bluetooth's signature, the
installer. Each prints OK, FAIL, WARN (worth a look) or "--" (not in the logs: the
boot ended first, nothing played, an older card). The exit status is 1 if anything
FAILed.

The dumpsys parts (SurfaceFlinger's layer table, drm_hwcomposer's statistics,
dumpsys audio) follow the formats of AOSP 14 and drm_hwcomposer as seen on cards
26-28; a format that has moved shows as "--", never as OK.
"""
import argparse
import os
import re
import shutil
import sys
import tempfile
import zipfile

# The certificate Android prints as "signatures:[d77294ce]": AOSP's test key
# (build/make/target/product/security/testkey), which card 23 found on Bluetooth.
AOSP_TESTKEY = "d77294ce"
OVERLAY_TITLE = "Edge1 performance overlay"   # Edge1Tools HudService
SNAPSHOTS = ("completed", "timeout", "120s")  # most telling first

results = []


def report(status, name, detail=""):
    results.append(status)
    print(f"{status:<4} {name}" + (f": {detail}" if detail else ""))


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def lines(path):
    text = read(path)
    return text.splitlines() if text is not None else []


# --- finding the logs ---------------------------------------------------------

BOOT_RE = re.compile(r"boot-(\d{5})$")


def find_root(path):
    """(card root or None, edge1-logs dir or None, boot dir or None)."""
    path = os.path.normpath(path)
    if BOOT_RE.search(os.path.basename(path)):
        logs = os.path.dirname(path)
        return os.path.dirname(logs), logs, path
    for dirpath, dirnames, filenames in os.walk(path):
        if os.path.basename(dirpath) == "edge1-logs" or "boots.txt" in filenames \
                or any(BOOT_RE.match(d) for d in dirnames):
            return os.path.dirname(dirpath), dirpath, None
        if "edge1-install.log" in filenames or "edge1-boot.log" in filenames:
            if "edge1-logs" in dirnames:
                return dirpath, os.path.join(dirpath, "edge1-logs"), None
            return dirpath, None, None
    return None, None, None


def boot_dirs(logs):
    if not logs or not os.path.isdir(logs):
        return []
    return sorted(os.path.join(logs, d) for d in os.listdir(logs) if BOOT_RE.match(d))


def snapshot(boot, name):
    """The newest snapshot holding file `name`: completed, then timeout, then 120s."""
    for s in SNAPSHOTS:
        p = os.path.join(boot, s, name)
        if os.path.isfile(p):
            return p
    return None


# --- boots --------------------------------------------------------------------

UP_RE = re.compile(r"up (\d+)s, boot (?:completed at (\d+)s|not completed)")


def check_boots(logs, boots):
    print("== boots")
    text = read(os.path.join(logs, "boots.txt")) if logs else None
    if text is None:
        report("--", "boots.txt", "not in the logs")
        return
    ended = {}
    started = {}
    for line in text.splitlines():
        m = re.match(r"(boot-\d{5}): (.*)", line)
        if not m:
            continue
        if m.group(2).startswith("started"):
            started[m.group(1)] = m.group(2)
        else:
            ended[m.group(1)] = m.group(2)
    names = sorted(set(started) | set(ended) | {os.path.basename(b) for b in boots})
    resets = 0
    for name in names:
        end = ended.get(name)
        if end is None:     # the last boot: no later boot has written its ending
            end = (read(os.path.join(logs, name, "alive.txt")) or "no record").strip()
            end += " (last boot)"
        opts = re.search(r"options:(.*)", started.get(name, ""))
        print(f"     {name}: {end}" + (f"; options:{opts.group(1)}" if opts else ""))
        if "pstore saved" in end:
            resets += 1
    done = sum(1 for n in names if "completed at" in (ended.get(n) or
               read(os.path.join(logs, n, "alive.txt")) or ""))
    if not names:
        report("--", "boots", "boots.txt lists none")
    elif resets:
        report("FAIL", "boots", f"{len(names)} boot(s), {resets} ended in a reset (pstore saved)")
    elif done < len(names):
        report("WARN", "boots", f"{len(names)} boot(s), {len(names) - done} never completed")
    else:
        report("OK", "boots", f"{len(names)} boot(s), all completed, no reset")


# --- one boot -----------------------------------------------------------------

# logcat -v threadtime: "10-06 06:12:01.123  1234  1250 E Tag     : message"
LOGCAT_RE = re.compile(r"^\d\d-\d\d \d\d:\d\d:\d\d\.\d+\s+\d+\s+\d+ ([VDIWEF]) (.*?)\s*: (.*)$")


def logcat(boot):
    out = []
    for line in lines(os.path.join(boot, "logcat.txt")):
        m = LOGCAT_RE.match(line)
        if m:
            out.append(m.groups())    # (level, tag, message)
    return out


def check_ui(dmesg, boot):
    m = None
    for line in dmesg:
        m = re.search(r"ui: androidboot\.edge1\.ui=(\S*), menus drawn within (\d*)x(\d*)", line) or m
    if not m:
        report("--", "ui (menus)", "no 'ui:' line in dmesg (bootwatch older than card 29?)")
        return
    ui, w, h = m.group(1).rstrip(","), m.group(2), m.group(3)
    if ui == "native":
        ok = not w
        detail = f"ui=native, menus at the TV's mode ({w or 'no'} cap)"
    else:
        ok = (w, h) == ("1920", "1080")
        detail = f"ui={ui or '(unset)'}, menus drawn within {w or '?'}x{h or '?'}"
    report("OK" if ok else "FAIL", "ui (menus)", detail)


def check_rng(dmesg, lc, boot):
    bad = [l.strip() for l in dmesg
           if re.search(r"rockchip-rng|hwrng|hw_random", l, re.I)
           and re.search(r"fail|error|timeout|timed out|-\d{1,3}\b", l, re.I)]
    seeder = [f"{lvl} {tag}: {msg}" for lvl, tag, msg in lc
              if "prng_seeder" in tag + msg and lvl in "EF"]
    misc = read(snapshot(boot, "misc.txt") or "") or ""
    cur = re.search(r"rng_current: *(\S*)", misc)
    words = []
    m = re.search(r"hw_random bytes:\n((?:[0-7]{7}.*\n?)+)", misc)
    if m:
        for l in m.group(1).splitlines():
            words += l.split()[1:]
    details = []
    status = "OK"
    if cur:
        details.append(f"rng_current={cur.group(1) or '(none)'}")
        if cur.group(1) != "rockchip-rng":
            status = "FAIL"
    if m:
        if not words or len(set(words)) <= 1:
            status = "FAIL"
            details.append("/dev/hw_random gave " + (f"only {words[0]}" if words else "nothing"))
        else:
            details.append(f"/dev/hw_random varies ({len(set(words))} distinct words)")
    elif "hw_random bytes:" in misc:
        status = "FAIL"
        details.append("/dev/hw_random read nothing (a poll timeout: the TRNG's clocks or reset)")
    if bad:
        status = "FAIL"
        details.append(f"dmesg: {bad[0]}")
    if seeder:
        status = "FAIL"
        details.append(f"logcat: {seeder[0]}")
    if not cur and not m and not bad and not seeder:
        if not dmesg and not lc:
            report("--", "hardware RNG", "no dmesg or logcat")
            return
        report("WARN", "hardware RNG", "no errors, but no rng_current in misc.txt "
               "(snapshot older than this check) - only the absence of errors was checked")
        return
    report(status, "hardware RNG", "; ".join(details))


def check_audio(lc, boot):
    hdmi_log = [msg for lvl, tag, msg in lc if tag == "Edge1HdmiAudio"]
    ahal = [f"{tag}: {msg}" for lvl, tag, msg in lc if tag.startswith("AHAL_") and lvl in "EF"]
    path = snapshot(boot, "audio.txt")
    audio = read(path) if path else None
    details = []
    status = "OK"
    if hdmi_log:
        details.append(f"Edge1HdmiAudio: {hdmi_log[-1]}")
        # hdmi_audio=0 in edge1-options.txt: "disconnecting HDMI Out" or
        # "HDMI Out not connected, as wanted" - sound stays on Speaker by choice.
        if re.search(r"disconnecting|not connected", hdmi_log[-1]):
            report("OK", "HDMI audio", "; ".join(details) + " (hdmi_audio=0)")
            return
        if not re.search(r"connecting HDMI Out|HDMI Out connected", hdmi_log[-1]):
            status = "WARN"
    else:
        status = "WARN"
        details.append("no Edge1HdmiAudio line in logcat")
    if audio is not None:
        connected = re.search(r"type:0x400\b|\(hdmi\)", audio)
        if connected:
            details.append("dumpsys audio lists an HDMI device")
        else:
            status = "FAIL" if status == "OK" else status
            details.append("dumpsys audio lists no HDMI device")
        music = re.search(r"STREAM_MUSIC:.*?Devices: *([^\n]*)", audio, re.S)
        if music:
            details.append(f"media routed to: {music.group(1).strip()}")
        full = re.search(r"mFullVolumeDevices=([^\n]*)", audio)
        if full and re.search(r"0x400|hdmi", full.group(1), re.I):
            status = "WARN" if status == "OK" else status
            details.append("HDMI has full volume: CEC took the TV as the volume (the TV's remote sets it)")
    else:
        details.append("no audio.txt snapshot")
    if ahal:
        status = "FAIL"
        details.append(f"{len(ahal)} AHAL_ error(s), first: {ahal[0]}")
    report(status, "HDMI audio", "; ".join(details))


# drm_hwcomposer's HwcDisplay::Dump: "Statistics since system boot:" then
# " Total frames count: N", " Failed to test commit frames: N", ...,
# " Composition efficiency: R"; the same again "since last dumpsys request".
def hwc_stats(sf):
    out = []
    for m in re.finditer(r"Statistics since ([^\n:]*):\s*\n(.*?)(?=\n\s*\n|\Z)", sf, re.S):
        block = m.group(2)
        total = re.search(r"Total frames count: *(\d+)", block)
        failed = re.search(r"Failed to test commit frames: *(\d+)", block)
        eff = re.search(r"Composition efficiency: *([\d.]+)", block)
        if total and failed:
            out.append((m.group(1).strip(), int(total.group(1)), int(failed.group(1)),
                        eff.group(1) if eff else "?"))
    return out


# SurfaceFlinger's "HWC layers" table: the layer's name on a line of its own, then
#   "  rel      0 |       2038 |     DEVICE |          0 | ..."
def layer_types(sf):
    types = {}
    name = None
    for line in sf.splitlines():
        m = re.match(r"\s+(?:rel\s+)?-?\d+\s*\|\s*-?\d+\s*\|\s*([A-Z_]+)\s*\|", line)
        if m:
            if name is not None:
                types[name] = m.group(1)
            name = None
        elif line.startswith(" ") and not line.startswith("  ") and "|" not in line:
            name = line.strip()
    return types


def check_video(lc, boot):
    playing = sorted(p for p in os.listdir(boot) if re.match(r"playing-\d+\.txt$", p))
    perf = [msg for lvl, tag, msg in lc if msg.startswith("perf: ")]
    if not playing and not perf:
        report("--", "video", "nothing played long enough for a playing-N.txt (10 frames/s for 10s)")
        return
    for p in playing:
        text = read(os.path.join(boot, p)) or ""
        rate = re.search(r"decoder interrupts (\d+)/s", text)
        nv12 = re.findall(r"format=NV12", text)
        stats = hwc_stats(text)
        types = layer_types(text)
        details = [f"{rate.group(1)} decoded frames/s" if rate else "no decode rate"]
        status = "OK"
        if nv12:
            details.append("NV12 on a display plane")
        elif "plane[" in text:
            status = "FAIL"
            details.append("no NV12 plane in the DRM state: the GPU composed the video")
        if types:
            client = sorted(n for n, t in types.items() if t == "CLIENT")
            details.append(f"{len(types)} layers, {len(client)} CLIENT" +
                           (f" ({', '.join(client[:3])})" if client else ""))
            if client:
                status = "FAIL"
        if stats:
            label, total, failed, eff = stats[-1]
            details.append(f"drm_hwcomposer since {label}: {failed}/{total} failed test commits, "
                           f"efficiency {eff}")
            if total and failed * 20 > total:     # above 5%
                status = "FAIL"
        report(status, f"video {p}", "; ".join(details))
    if perf:
        # "perf: 3840x2160 vp9, 30.0 fps: decode 4.1, fetch 12.0, map 0.3, copy 9.8 ms/frame (max 14.0 ms)"
        by_size = {}
        for msg in perf:
            m = re.match(r"perf: (\d+x\d+) (\S+), ([\d.]+) fps: decode ([\d.]+), fetch ([\d.]+), "
                         r"map ([\d.]+), copy ([\d.]+)", msg)
            if m:
                by_size.setdefault((m.group(1), m.group(2).rstrip(",")), []).append(
                    tuple(float(x) for x in m.group(3, 4, 7)))
        for (size, codec), v in sorted(by_size.items()):
            fps = sorted(x[0] for x in v)
            copy = sorted(x[2] for x in v)
            dec = sorted(x[1] for x in v)
            print(f"     perf {size} {codec}: {len(v)} lines, fps {fps[0]:.0f}-{fps[-1]:.0f} "
                  f"(median {fps[len(fps) // 2]:.0f}), decode median {dec[len(dec) // 2]:.1f} ms, "
                  f"copy median {copy[len(copy) // 2]:.1f} ms")


# The HDMI-CEC HAL (device/khadas/edge/hdmi), tag edge1-hdmi, from card 30 on.
def check_cec(lc):
    msgs = [(lvl, msg) for lvl, tag, msg in lc if tag == "edge1-hdmi"]
    if not msgs:
        report("--", "HDMI-CEC", "no edge1-hdmi lines (a card before 30, or the HAL never started)")
        return
    text = [m for _, m in msgs]
    if any(m.startswith("cec=0") for m in text):
        report("OK", "HDMI-CEC", "off by cec=0 in edge1-options.txt")
        return
    opened = [m for m in text if re.match(r"/dev/cec0: \S+ \(", m)]
    if not opened:
        errors = [m for lvl, m in msgs if lvl in "EF"]
        report("FAIL", "HDMI-CEC", "no adapter: " + ("; ".join(errors[:2]) or "no open line"))
        return
    pas = re.findall(r"physical address ([0-9a-f.]+)", " ".join(text))
    pa = pas[-1] if pas else "?"
    claimed = [m for m in text if m.startswith("logical address ")]
    details = [opened[0].split(": ", 1)[1].split(",")[0], f"physical address {pa}"]
    if claimed:
        details.append(claimed[-1])
    status = "OK"
    if pa in ("f.f.f.f", "?"):
        status = "WARN"
        details.append("no physical address: no TV, or its EDID has no CEC block")
    elif not claimed:
        status = "WARN"
        details.append("the framework claimed no logical address (HDMI control off in Settings?)")
    report(status, "HDMI-CEC", "; ".join(details))


def check_overlay(boot):
    texts = [read(os.path.join(boot, p)) or "" for p in sorted(os.listdir(boot))
             if re.match(r"playing-\d+\.txt$", p)]
    sf = snapshot(boot, "surfaceflinger.txt")
    if sf:
        texts.append(read(sf) or "")
    alphas = []
    for text in texts:
        ls = text.splitlines()
        for i, line in enumerate(ls):
            if OVERLAY_TITLE in line:
                for near in ls[i:i + 15]:
                    m = re.search(r"color\{<\s*([^>]*)>\}", near)
                    if m:
                        alphas.append(m.group(1).split(",")[-1].strip())
                        break
    if not alphas:
        report("--", "overlay alpha", "the performance overlay was not on screen in any dump")
        return
    bad = [a for a in alphas if a not in ("1", "1.0", "1.000000")]
    report("FAIL" if bad else "OK", "overlay alpha",
           f"alpha {', '.join(sorted(set(alphas)))}" +
           (" - an untrusted overlay's cap: drm_hwcomposer has no plane for it" if bad else ""))


def check_thermal(dmesg):
    hot, rails, n = {}, {}, 0
    for line in dmesg:
        if "edge1-bootwatch: thermal" not in line:
            continue
        n += 1
        for k, v in re.findall(r"(\S+)=(-?\d+)C\b", line):
            hot[k] = max(hot.get(k, -999), int(v))
        for k, v in re.findall(r"(vdd_\w+)=(\d+)mV", line):
            lo, hi = rails.get(k, (10 ** 6, 0))
            rails[k] = (min(lo, int(v)), max(hi, int(v)))
    if not n:
        report("--", "thermal", "no thermal lines in dmesg")
        return
    peak = max(hot.values()) if hot else None
    detail = f"{n} lines; peak " + ", ".join(f"{k} {v}C" for k, v in sorted(hot.items()))
    if rails:
        detail += "; rails " + ", ".join(f"{k} {lo}-{hi}mV" for k, (lo, hi) in sorted(rails.items()))
    report("WARN" if peak is not None and peak >= 85 else "OK", "thermal", detail)


def check_crashes(lc, dmesg):
    crashed = {}
    for lvl, tag, msg in lc:
        m = (re.search(r"Fatal signal \d+ \(\w+\).*?pid \d+ \(([^)]*)\)", msg) if tag == "libc" else None) \
            or (re.search(r"Process: ([\w.:]+)", msg) if tag == "AndroidRuntime" else None)
        if m:
            crashed[m.group(1)] = crashed.get(m.group(1), 0) + 1
        if "WATCHDOG KILLING SYSTEM PROCESS" in msg:
            crashed["system_server (watchdog)"] = crashed.get("system_server (watchdog)", 0) + 1
    oops = [l.strip() for l in dmesg if re.search(r"Unable to handle kernel|Internal error: Oops|"
                                                   r"kernel BUG at|Kernel panic", l)]
    denials = sum(1 for l in dmesg if "avc:  denied" in l or "avc: denied" in l)
    if not lc and not dmesg:
        report("--", "crashes", "no logcat or dmesg")
        return
    detail = ", ".join(f"{p} x{n}" for p, n in sorted(crashed.items(), key=lambda x: -x[1])[:6]) \
        or "no native or Java crash"
    if oops:
        detail += f"; kernel: {oops[0]}"
    detail += f"; {denials} SELinux denial(s) in dmesg"
    report("FAIL" if oops or "system_server (watchdog)" in crashed else
           "WARN" if crashed else "OK", "crashes", detail)


def check_signing(boot):
    path = snapshot(boot, "packages.txt")
    if not path:
        report("--", "signatures", "no packages.txt snapshot")
        return
    sigs = {}
    pkg = None
    for line in lines(path):
        m = re.match(r"== (\S+)", line)
        if m:
            pkg = m.group(1)
        m = re.search(r"signatures:\[([0-9a-f, ]*)\]", line)
        if m and pkg and pkg not in sigs:
            sigs[pkg] = m.group(1).replace(" ", "")
    if not sigs:
        report("--", "signatures", "packages.txt has no signatures")
        return
    test = sorted(p for p, s in sigs.items() if AOSP_TESTKEY in s.split(","))
    detail = ", ".join(f"{p} {s}" for p, s in sorted(sigs.items()))
    # Matters for an enforcing build (mac_permissions seinfo), not a permissive one.
    report("WARN" if test else "OK", "signatures",
           (f"AOSP test key on {', '.join(test)}; " if test else "") + detail)


def check_install(root):
    text = read(os.path.join(root, "edge1-install.log")) if root else None
    if text is None:
        return
    print("== installer")
    last = [l for l in text.splitlines() if l.strip()]
    exited = re.findall(r"exited (\d+)", text)
    if exited and exited[-1] != "0":
        report("FAIL", "install", f"the installer exited {exited[-1]}; last: {last[-1]}")
    elif last and re.search(r"done; powering off|rebooting$", last[-1]):
        report("OK", "install", last[-1])
    else:
        report("WARN", "install", f"no ending in the log (power cut?); last: {last[-1] if last else '(empty)'}")


def check_boot(boot):
    name = os.path.basename(boot)
    alive = (read(os.path.join(boot, "alive.txt")) or "no alive.txt").strip()
    snaps = [s for s in SNAPSHOTS if os.path.isdir(os.path.join(boot, s))]
    print(f"== {name}: {alive}; snapshots: {', '.join(snaps) or 'none'}"
          + ("; pstore saved (ended in a reset)" if os.path.isdir(os.path.join(boot, "pstore")) else ""))
    dmesg = lines(os.path.join(boot, "dmesg.txt"))
    lc = logcat(boot)
    check_ui(dmesg, boot)
    check_rng(dmesg, lc, boot)
    check_audio(lc, boot)
    check_cec(lc)
    check_video(lc, boot)
    check_overlay(boot)
    check_thermal(dmesg)
    check_crashes(lc, dmesg)
    check_signing(boot)


def pick_boot(boots):
    """The newest boot with a completed snapshot, else the newest."""
    for b in reversed(boots):
        if os.path.isdir(os.path.join(b, "completed")):
            return b
    return boots[-1] if boots else None


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("path", help="EDGE1BOOT folder, edge1-logs, a boot-NNNNN folder, or a .zip")
    ap.add_argument("--boot", type=int, help="check boot-N (default: the newest that completed)")
    ap.add_argument("--all", action="store_true", help="check every boot on the card")
    args = ap.parse_args(argv)

    tmp = None
    path = args.path
    try:
        if zipfile.is_zipfile(path):
            tmp = tempfile.mkdtemp(prefix="edge1-logcheck-")
            with zipfile.ZipFile(path) as z:
                for member in z.namelist():
                    dest = os.path.realpath(os.path.join(tmp, member))
                    if not dest.startswith(os.path.realpath(tmp) + os.sep):
                        sys.exit(f"{path}: {member} points outside the archive")
                z.extractall(tmp)
            path = tmp
        if not os.path.exists(path):
            sys.exit(f"{path}: no such file or folder")
        root, logs, only = find_root(path)
        if not (root or logs or only):
            sys.exit(f"{args.path}: no edge1-logs, boot-NNNNN or edge1-install.log in it")
        boots = boot_dirs(logs) if not only else [only]
        if args.boot is not None:
            want = f"boot-{args.boot:05d}"
            boots_sel = [b for b in boots if os.path.basename(b) == want]
            if not boots_sel:
                sys.exit(f"{want} is not on the card: {', '.join(map(os.path.basename, boots)) or 'no boots'}")
        elif args.all:
            boots_sel = boots
        else:
            boots_sel = [pick_boot(boots)] if boots else []
        if logs and not only:
            check_boots(logs, boots)
        for b in boots_sel:
            check_boot(b)
        check_install(root)
        if not boots_sel and not results:
            sys.exit("nothing to check: no boot folders")
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    fails = results.count("FAIL")
    print(f"== {results.count('OK')} ok, {fails} fail, {results.count('WARN')} warn, "
          f"{results.count('--')} not in the logs")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
