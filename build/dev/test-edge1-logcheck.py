#!/usr/bin/env python3
"""Tests for build/edge1-logcheck.py, offline, in a second.

    usage: test-edge1-logcheck.py

Two things:
  1. the lines the checker looks for are still what the tree writes - the
     bootwatch's ui:/thermal/rng lines, Edge1 Tools' HdmiAudio tag and messages,
     the overlay's title, ffmpeg_codec2's perf: line. A renamed log line would
     otherwise turn a check into a silent "--".
  2. a synthetic card that passes everything comes out with no FAIL, one that
     breaks every check comes out with each FAIL, and a .zip of the card reads the
     same as the folder.
SHOW=1 prints both synthetic cards' reports. The dumpsys samples follow AOSP 14 /
drm_hwcomposer's formats; they are not copies of a real card's logs.
"""
import contextlib
import io
import os
import re
import shutil
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DEV = os.path.join(ROOT, "device", "khadas", "edge")
sys.path.insert(0, os.path.join(ROOT, "build"))
import importlib.util  # noqa: E402

spec = importlib.util.spec_from_file_location("logcheck", os.path.join(ROOT, "build", "edge1-logcheck.py"))
logcheck = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logcheck)

failures = []


def expect(cond, what):
    if not cond:
        failures.append(what)


def src(*parts):
    with open(os.path.join(DEV, *parts), encoding="utf-8") as f:
        return f.read()


# --- 1. the producers -----------------------------------------------------------

bootwatch = src("bin", "edge1-bootwatch.sh")
expect('log "ui: androidboot.edge1.ui=' in bootwatch and "menus drawn within" in bootwatch,
       "bootwatch no longer logs the 'ui: androidboot.edge1.ui=..., menus drawn within WxH' line")
expect('log "thermal$line"' in bootwatch, "bootwatch's thermal line moved")
expect('echo "rng_current: ' in bootwatch and 'echo "hw_random bytes:"' in bootwatch,
       "bootwatch's misc.txt has no rng_current / hw_random bytes")
expect('decoder interrupts $(( (b - a) / 2 ))/s' in bootwatch, "playing-N.txt's decode rate line moved")
expect('"$s/packages.txt"' in bootwatch and "signatures=" in bootwatch, "packages.txt moved")
for snap in ("120s", "completed", "timeout"):
    expect(f"snapshot {snap}" in bootwatch, f"bootwatch takes no '{snap}' snapshot")
hdmi = src("apps", "Edge1Tools", "src", "org", "edge1", "tools", "HdmiAudio.java")
expect('TAG = "Edge1HdmiAudio"' in hdmi, "HdmiAudio's log tag changed")
expect('"connecting" : "disconnecting") + " HDMI Out' in hdmi, "HdmiAudio's connect message changed")
expect('"HDMI Out " + (have ? "connected" : "not connected")' in hdmi, "HdmiAudio's as-wanted message changed")
hud = src("apps", "Edge1Tools", "src", "org", "edge1", "tools", "HudService.java")
expect(f'setTitle("{logcheck.OVERLAY_TITLE}")' in hud, "the overlay's window title changed")
perf_patch = [p for p in os.listdir(os.path.join(DEV, "patches", "external", "ffmpeg_codec2"))
              if "NV12-output" in p]
expect(bool(perf_patch) and
       '"perf: %dx%d %s, %.1f fps: decode %.1f, fetch %.1f, map %.1f, copy %.1f ms/frame'
       in src("patches", "external", "ffmpeg_codec2", perf_patch[0]),
       "ffmpeg_codec2's perf: line changed")
install = src("bin", "edge1-install-boot.sh")
expect('exited $rc"' in install and '"done; powering off"' in install and "; rebooting\"" in install,
       "edge1-install-boot.sh's ending lines changed")

# --- 2. synthetic cards --------------------------------------------------------


def lc(level, tag, msg, pid=1000):
    return f"10-06 06:12:01.123  {pid}  {pid + 5} {level} {tag:<8}: {msg}\n"


SF_GOOD = """Display 0 (active) HWC layers:
---------------------------------------------------------------------------------------------
 Layer name
           Z |  Window Type |  Comp Type |  Transform |   Disp Frame (LTRB) |
---------------------------------------------------------------------------------------------
 SurfaceView[com.liskovsoft.smarttubetv/MainActivity](BLAST)#120
  rel     -2 |            1 |     DEVICE |          0 |    0    0 1920 1080 |
 Edge1 performance overlay#133
  rel      0 |         2038 |     DEVICE |          0 |    0    0  400  120 |
---------------------------------------------------------------------------------------------
+ Layer (Edge1 performance overlay#133) uid=1000
  color{< 0, 0, 0, 1 >} alpha=1
- Display on: HDMI-A-1
  Flattening state: Disabled
Statistics since system boot:
 Total frames count: 9000
 Failed to test commit frames: 12
 Failed to commit frames: 0
 Flattened frames: 0
 Pixel operations (free units) : [TOTAL: 100 / GPU: 1]
 Composition efficiency: 0.99

Statistics since last dumpsys request:
 Total frames count: 600
 Failed to test commit frames: 0
 Failed to commit frames: 0
 Flattened frames: 0
 Pixel operations (free units) : [TOTAL: 100 / GPU: 0]
 Composition efficiency: 1

"""
SF_BAD = SF_GOOD.replace("DEVICE |          0 |    0    0 1920", "CLIENT |          0 |    0    0 1920") \
    .replace("color{< 0, 0, 0, 1 >}", "color{< 0, 0, 0, 0.799805 >}") \
    .replace(" Total frames count: 600\n Failed to test commit frames: 0",
             " Total frames count: 600\n Failed to test commit frames: 360")
DRM_NV12 = """plane[31]: plane-0
\tcrtc=crtc-1
\tfb=56
\t\tformat=NV12 little-endian (0x3231564e)
\t\tsize=3840x2160
"""
DRM_RGB = DRM_NV12.replace("NV12 little-endian (0x3231564e)", "XR24 little-endian (0x34325258)")
AUDIO_GOOD = """Audio routes:
  mConnectedDevices:
  [DeviceInfo: type:0x400 (hdmi) name:HDMI Out addr: codec: 0]
- STREAM_MUSIC:
   Muted: false
   Devices: hdmi, speaker
"""
AUDIO_BAD = "Audio routes:\n- STREAM_MUSIC:\n   Devices: speaker\n"
PKG_GOOD = """== com.android.bluetooth
    signatures=PackageSignatures{1 version:3, signatures:[5f2bb0a1], past signatures:[]}
== com.android.networkstack
    signatures=PackageSignatures{2 version:3, signatures:[0b3c7e11], past signatures:[]}
"""
PKG_BAD = PKG_GOOD.replace("5f2bb0a1", logcheck.AOSP_TESTKEY)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def card(base, good):
    logs = os.path.join(base, "EDGE1BOOT", "edge1-logs")
    b1, b2 = os.path.join(logs, "boot-00041"), os.path.join(logs, "boot-00042")
    write(os.path.join(logs, "boots.txt"),
          "boot-00041: started, clock 2026-10-06 06:00:00, boot reason reboot, options: ui=1080\n"
          + ("boot-00041: up 400s, boot completed at 100s\n" if good else
             "boot-00041: up 250s, boot completed at 100s, pstore saved\n")
          + "boot-00042: started, clock 2026-10-06 06:10:00, boot reason reboot, options: ui=1080 hdmi_audio=1\n")
    write(os.path.join(b1, "alive.txt"), "up 400s, boot completed at 100s\n")
    write(os.path.join(b2, "alive.txt"), "up 700s, boot completed at 98s\n")
    dmesg = ("[   20.1] edge1-bootwatch: ui: androidboot.edge1.ui=1080, menus drawn within "
             + ("1920x1080" if good else "x") + " (empty: the TV's mode)\n"
             "[   30.0] edge1-bootwatch: thermal cpu=51C gpu=48C fan=1/4 policy0=1416MHz "
             "policy4=1800MHz gpu=200MHz vdd_cpu_b=1125mV vdd_gpu=975mV\n"
             + ("[   35.0] edge1-bootwatch: thermal cpu=88C gpu=80C policy4=1800MHz\n" if not good else "")
             + ("" if good else "[    2.5] rockchip-rng ff8b8000.crypto: probe failed: -110\n")
             + ("" if good else "[  300.0] Unable to handle kernel NULL pointer dereference at 0x0\n"))
    write(os.path.join(b2, "dmesg.txt"), dmesg)
    logcat = (lc("I", "Edge1HdmiAudio", "connecting HDMI Out (persist.sys.edge1.hdmi_audio=1)")
              + lc("I", "C2FFMPEGVideoDecodeComponent",
                   "perf: 3840x2160 vp9, 30.0 fps: decode 4.5, fetch 12.0, map 0.3, copy 9.1 ms/frame (max 13.0 ms)")
              + lc("I", "C2FFMPEGVideoDecodeComponent",
                   "perf: 3840x2160 vp9, 59.0 fps: decode 5.0, fetch 2.0, map 0.3, copy 8.0 ms/frame (max 12.0 ms)"))
    if not good:
        logcat += (lc("E", "AHAL_StreamPrimary", "transfer: error -5")
                   + lc("E", "prng_seeder", "Could not open /dev/hw_random")
                   + lc("F", "libc", "Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 900 (binder:900_2), "
                                     "pid 900 (audioserver)"))
    write(os.path.join(b2, "logcat.txt"), logcat)
    snap = os.path.join(b2, "completed")
    write(os.path.join(snap, "misc.txt"), "Permissive\n\nrng_current: "
          + ("rockchip-rng\nhw_random bytes:\n0000000 1a2b 3c4d 9f00 77e1 0c3d aa51 6b20 e3d4\n0000100\n" if good
             else "none\nhw_random bytes:\n0000000 0000 0000 0000 0000 0000 0000 0000 0000\n0000100\n"))
    write(os.path.join(snap, "audio.txt"), AUDIO_GOOD if good else AUDIO_BAD)
    write(os.path.join(snap, "packages.txt"), PKG_GOOD if good else PKG_BAD)
    write(os.path.join(snap, "surfaceflinger.txt"), SF_GOOD if good else SF_BAD)
    write(os.path.join(b2, "playing-1.txt"),
          "uptime 300s, decoder interrupts 30/s (one per frame)\n"
          + (DRM_NV12 if good else DRM_RGB) + (SF_GOOD if good else SF_BAD))
    write(os.path.join(base, "EDGE1BOOT", "edge1-install.log"),
          "2026-10-06 06:00:01 install to emmc requested\n"
          + ("2026-10-06 06:03:00 edge1-install-internal.sh emmc exited 0\n2026-10-06 06:03:01 done; powering off\n"
             if good else "2026-10-06 06:03:00 edge1-install-internal.sh emmc exited 3\n"))
    return os.path.join(base, "EDGE1BOOT")


def run(path, *extra):
    logcheck.results.clear()
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = logcheck.main([*extra, path])
    return rc, out.getvalue()


def statuses(out):
    return {m.group(2): m.group(1) for m in re.finditer(r"^(OK|FAIL|WARN|--)\s+(.+?)(?::|$)", out, re.M)}


tmp = tempfile.mkdtemp(prefix="test-edge1-logcheck-")
if os.environ.get("SHOW"):
    print(run(card(os.path.join(tmp, "g"), True))[1]); print(run(card(os.path.join(tmp, "b"), False))[1])
try:
    rc, out = run(card(os.path.join(tmp, "good"), True))
    st = statuses(out)
    expect(rc == 0, f"a good card exits {rc}:\n{out}")
    for name in ("boots", "ui (menus)", "hardware RNG", "HDMI audio", "video playing-1.txt",
                 "overlay alpha", "thermal", "crashes", "signatures", "install"):
        expect(st.get(name) == "OK", f"good card: {name} is {st.get(name)}, want OK\n{out}")
    expect("perf 3840x2160 vp9: 2 lines, fps 30-59" in out, f"good card: perf summary missing\n{out}")

    bad = card(os.path.join(tmp, "bad"), False)
    rc, out = run(bad)
    st = statuses(out)
    expect(rc == 1, f"a bad card exits {rc}")
    for name in ("boots", "ui (menus)", "hardware RNG", "HDMI audio", "video playing-1.txt",
                 "overlay alpha", "crashes", "install"):
        expect(st.get(name) == "FAIL", f"bad card: {name} is {st.get(name)}, want FAIL\n{out}")
    for name in ("thermal", "signatures"):
        expect(st.get(name) == "WARN", f"bad card: {name} is {st.get(name)}, want WARN\n{out}")

    # hdmi_audio=0 is a choice, not a failure.
    lpath = os.path.join(bad, "edge1-logs", "boot-00042", "logcat.txt")
    write(lpath, lc("I", "Edge1HdmiAudio", "HDMI Out not connected, as wanted"))
    rc, out = run(bad)
    expect(statuses(out).get("HDMI audio") == "OK", f"hdmi_audio=0 should be OK\n{out}")

    # A zip of the EDGE1BOOT folder, as the owner sends it.
    z = os.path.join(tmp, "edge1-logs.zip")
    good = os.path.join(tmp, "good", "EDGE1BOOT")
    with zipfile.ZipFile(z, "w") as zf:
        for dirpath, _, files in os.walk(good):
            for f in files:
                p = os.path.join(dirpath, f)
                zf.write(p, os.path.relpath(p, os.path.dirname(good)))
    rc, out = run(z)
    expect(rc == 0 and statuses(out).get("video playing-1.txt") == "OK", f"zip: rc {rc}\n{out}")

    # A single boot folder, and --boot.
    rc, out = run(os.path.join(good, "edge1-logs", "boot-00042"))
    expect(rc == 0 and "boots" not in statuses(out), f"boot folder: rc {rc}\n{out}")
    rc, out = run(good, "--boot", "41")
    expect("== boot-00041" in out and statuses(out).get("ui (menus)") == "--", f"--boot 41\n{out}")
finally:
    shutil.rmtree(tmp, ignore_errors=True)

if failures:
    print("\n\n".join(f"FAIL {f}" for f in failures))
    sys.exit(1)
print("edge1-logcheck: producers match, synthetic cards read as expected")
