package org.edge1.tools;

import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES20;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.TreeSet;

/**
 * Reads what the overlay shows, straight from the kernel: per-core load from
 * /proc/stat, cluster clocks from cpufreq, the GPU clock from devfreq, every
 * thermal zone, and memory from /proc/meminfo. Anything unreadable shows as "?"
 * rather than failing the rest.
 */
final class Sampler {
    private long[] prevTotal = new long[0];
    private long[] prevIdle = new long[0];

    private String gpuRenderer;
    private String hwDecoders;

    /** One-time facts, worked out on a background thread: GL renderer, HW codecs. */
    synchronized void probeStatic() {
        if (gpuRenderer == null) gpuRenderer = glRenderer();
        if (hwDecoders == null) hwDecoders = hardwareVideoDecoders();
    }

    synchronized String gpuRenderer() {
        return gpuRenderer == null ? "…" : gpuRenderer;
    }

    synchronized String hwDecoders() {
        return hwDecoders == null ? "…" : hwDecoders;
    }

    static String read(String path) {
        try {
            return new String(Files.readAllBytes(new File(path).toPath()),
                    StandardCharsets.UTF_8).trim();
        } catch (IOException | SecurityException e) {
            return null;
        }
    }

    static long readLong(String path, long fallback) {
        String s = read(path);
        if (s == null) return fallback;
        try {
            return Long.parseLong(s.split("\\s+")[0]);
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    /** "all 23%" plus one figure per core, from the /proc/stat deltas since last call. */
    String cpuLoad() {
        try {
            return cpuLoadUnchecked();
        } catch (RuntimeException e) {
            return "load ?";
        }
    }

    private String cpuLoadUnchecked() {
        String stat = read("/proc/stat");
        if (stat == null) return "load ?";
        List<long[]> rows = new ArrayList<>();
        for (String line : stat.split("\n")) {
            if (!line.startsWith("cpu")) break;
            String[] f = line.trim().split("\\s+");
            long total = 0;
            for (int i = 1; i < f.length && i <= 8; i++) total += Long.parseLong(f[i]);
            long idle = Long.parseLong(f[4]) + (f.length > 5 ? Long.parseLong(f[5]) : 0);
            rows.add(new long[] {total, idle});
        }
        if (prevTotal.length != rows.size()) {
            prevTotal = new long[rows.size()];
            prevIdle = new long[rows.size()];
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < rows.size(); i++) {
            long dt = rows.get(i)[0] - prevTotal[i];
            long di = rows.get(i)[1] - prevIdle[i];
            prevTotal[i] = rows.get(i)[0];
            prevIdle[i] = rows.get(i)[1];
            int pct = dt > 0 ? (int) Math.max(0, Math.min(100, 100 * (dt - di) / dt)) : 0;
            if (i == 0) {
                sb.append(String.format(Locale.ROOT, "%3d%% |", pct));
            } else {
                sb.append(String.format(Locale.ROOT, " %3d", pct));
            }
        }
        return sb.toString();
    }

    /** One entry per cpufreq policy (cluster): "0-3 1416" in MHz. */
    String cpuClocks() {
        File[] policies = new File("/sys/devices/system/cpu/cpufreq").listFiles(
                (d, n) -> n.startsWith("policy"));
        if (policies == null || policies.length == 0) return "?";
        Arrays.sort(policies);
        StringBuilder sb = new StringBuilder();
        for (File p : policies) {
            String cpus = read(p + "/related_cpus");
            long khz = readLong(p + "/scaling_cur_freq", -1);
            if (sb.length() > 0) sb.append("  ");
            sb.append("cpu").append(cpus == null ? "?" : compactCpus(cpus)).append(' ')
                    .append(khz < 0 ? "?" : String.valueOf(khz / 1000)).append("MHz");
        }
        return sb.toString();
    }

    private static String compactCpus(String list) {
        String[] ids = list.trim().split("\\s+");
        return ids.length > 1 ? ids[0] + "-" + ids[ids.length - 1] : ids[0];
    }

    /** The GPU's devfreq clock (panfrost on this board), in MHz. */
    String gpuClock() {
        File[] devs = new File("/sys/class/devfreq").listFiles((d, n) -> n.contains("gpu"));
        if (devs == null || devs.length == 0) return "?";
        long hz = readLong(devs[0] + "/cur_freq", -1);
        return hz < 0 ? "?" : (hz / 1000000) + "MHz";
    }

    /** Every thermal zone: "cpu 52.1  gpu 49.8" (°C). */
    String temperatures() {
        File[] zones = new File("/sys/class/thermal").listFiles(
                (d, n) -> n.startsWith("thermal_zone"));
        if (zones == null || zones.length == 0) return "?";
        Arrays.sort(zones);
        StringBuilder sb = new StringBuilder();
        for (File z : zones) {
            String type = read(z + "/type");
            long milli = readLong(z + "/temp", Long.MIN_VALUE);
            if (milli == Long.MIN_VALUE) continue;
            if (type == null) type = z.getName();
            type = type.replace("-thermal", "").replace("_thermal", "");
            if (sb.length() > 0) sb.append("  ");
            sb.append(type).append(' ')
                    .append(String.format(Locale.ROOT, "%.1f°C", milli / 1000.0));
        }
        return sb.length() == 0 ? "?" : sb.toString();
    }

    /** "1.2 / 3.8 GB" in use. */
    String memory() {
        String info = read("/proc/meminfo");
        if (info == null) return "?";
        long total = -1, avail = -1;
        for (String line : info.split("\n")) {
            String[] f = line.split("\\s+");
            if (f.length < 2) continue;
            if (f[0].equals("MemTotal:")) total = Long.parseLong(f[1]);
            if (f[0].equals("MemAvailable:")) avail = Long.parseLong(f[1]);
        }
        if (total <= 0 || avail < 0) return "?";
        return String.format(Locale.ROOT, "%.1f / %.1f GB",
                (total - avail) / 1048576.0, total / 1048576.0);
    }

    /** Hardware-accelerated video decoders the media framework offers. */
    private static String hardwareVideoDecoders() {
        try {
            TreeSet<String> types = new TreeSet<>();
            for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS)
                    .getCodecInfos()) {
                if (info.isEncoder() || !info.isHardwareAccelerated()) continue;
                for (String t : info.getSupportedTypes()) {
                    if (t.startsWith("video/")) types.add(t.substring(6));
                }
            }
            return types.isEmpty() ? "none - software decoding" : String.join(" ", types);
        } catch (RuntimeException e) {
            return "?";
        }
    }

    /** GL_RENDERER from a throwaway 1x1 pbuffer context. */
    private static String glRenderer() {
        EGLDisplay dpy = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        if (dpy == EGL14.EGL_NO_DISPLAY) return "?";
        int[] version = new int[2];
        if (!EGL14.eglInitialize(dpy, version, 0, version, 1)) return "?";
        EGLContext ctx = EGL14.EGL_NO_CONTEXT;
        EGLSurface surf = EGL14.EGL_NO_SURFACE;
        try {
            int[] attrs = {
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_NONE
            };
            EGLConfig[] configs = new EGLConfig[1];
            int[] count = new int[1];
            if (!EGL14.eglChooseConfig(dpy, attrs, 0, configs, 0, 1, count, 0) || count[0] < 1) {
                return "?";
            }
            ctx = EGL14.eglCreateContext(dpy, configs[0], EGL14.EGL_NO_CONTEXT,
                    new int[] {EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE}, 0);
            surf = EGL14.eglCreatePbufferSurface(dpy, configs[0],
                    new int[] {EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE}, 0);
            if (ctx == EGL14.EGL_NO_CONTEXT || surf == EGL14.EGL_NO_SURFACE
                    || !EGL14.eglMakeCurrent(dpy, surf, surf, ctx)) {
                return "?";
            }
            String renderer = GLES20.glGetString(GLES20.GL_RENDERER);
            String version2 = GLES20.glGetString(GLES20.GL_VERSION);
            return (renderer == null ? "?" : renderer)
                    + (version2 == null ? "" : ", " + version2.replace("OpenGL ES ", "GLES "));
        } finally {
            EGL14.eglMakeCurrent(dpy, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT);
            if (surf != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(dpy, surf);
            if (ctx != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(dpy, ctx);
            // No eglTerminate: the default display is shared with HWUI, which
            // draws this very overlay.
        }
    }
}
