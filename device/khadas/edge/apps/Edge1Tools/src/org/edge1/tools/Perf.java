package org.edge1.tools;

import android.os.SystemClock;
import android.os.SystemProperties;

/**
 * The CPU and GPU clock modes - the six of EDGE1BOOT:edge1-options.txt, with the same
 * limits - and the requests to bin/edge1-ctl.sh, the root helper that sets them.
 *
 * This app runs as the system user, which may set sys.* and persist.sys.*
 * properties; init.edge1.ctl.rc starts the helper on them. A mode is also kept in
 * persist.sys.edge1.perf, which the helper sets again at boot where no card's
 * edge1-options.txt is in charge. What runs is read back from the kernel, so a mode
 * picked on a PC shows here as well.
 */
final class Perf {
    private static final String CPU = "/sys/devices/system/cpu/cpufreq";
    private static final String GPU = "/sys/class/devfreq/ff9a0000.gpu";

    static final class Preset {
        final int title;
        final int text;
        final int big;
        final int little;
        final int gpu;

        Preset(int title, int text, int big, int little, int gpu) {
            this.title = title;
            this.text = text;
            this.big = big;
            this.little = little;
            this.gpu = gpu;
        }

        boolean matches(int[] limits) {
            return limits[0] == big && limits[1] == little && limits[2] == gpu;
        }
    }

    /** In the order of edge1-options.txt (build/build-bootfs.sh). */
    static final Preset[] PRESETS = {
            new Preset(R.string.preset_power, R.string.preset_power_text, 1416, 1416, 600),
            new Preset(R.string.preset_full, R.string.preset_full_text, 1800, 1416, 800),
            new Preset(R.string.preset_video, R.string.preset_video_text, 1800, 1416, 600),
            new Preset(R.string.preset_games, R.string.preset_games_text, 1608, 1416, 800),
            new Preset(R.string.preset_quiet, R.string.preset_quiet_text, 1200, 1200, 400),
            new Preset(R.string.preset_minimal, R.string.preset_minimal_text, 816, 816, 297),
    };

    private Perf() {}

    /** The limits in force, MHz: {A72, A53, GPU}; -1 where unreadable. */
    static int[] limits() {
        return new int[] {
                mhz(CPU + "/policy4/scaling_max_freq", 1000),
                mhz(CPU + "/policy0/scaling_max_freq", 1000),
                mhz(GPU + "/max_freq", 1000000),
        };
    }

    /** The clocks right now, MHz: {A72, A53, GPU}; -1 where unreadable. */
    static int[] clocks() {
        return new int[] {
                mhz(CPU + "/policy4/scaling_cur_freq", 1000),
                mhz(CPU + "/policy0/scaling_cur_freq", 1000),
                mhz(GPU + "/cur_freq", 1000000),
        };
    }

    private static int mhz(String path, int per) {
        long v = Sampler.readLong(path, -1);
        return v < 0 ? -1 : (int) (v / per);
    }

    /** The index of the mode now in force, or -1 for other limits. */
    static int current(int[] limits) {
        for (int i = 0; i < PRESETS.length; i++) {
            if (PRESETS[i].matches(limits)) return i;
        }
        return -1;
    }

    static void apply(Preset p) {
        String v = p.big + ":" + p.little + ":" + p.gpu;
        SystemProperties.set("persist.sys.edge1.perf", v);
        request("perf:" + v);
    }

    /** One request to edge1-ctl: "perf:...", "logs-off", "logs-on", "logs-clear". */
    static void request(String what) {
        SystemProperties.set("sys.edge1.ctl", SystemClock.elapsedRealtime() + ":" + what);
    }

    /**
     * The card's "logs=" as edge1-bootwatch read it at boot ("1" or "0"), kept up to
     * date by this app's own changes; empty where no bootwatch found a card (a user
     * build, an eMMC install), and then there is nothing to switch.
     */
    static String cardLogs() {
        return SystemProperties.get("sys.edge1.logs", "");
    }

    static void setLogs(boolean on) {
        request(on ? "logs-on" : "logs-off");
        SystemProperties.set("sys.edge1.logs", on ? "1" : "0");
    }
}
