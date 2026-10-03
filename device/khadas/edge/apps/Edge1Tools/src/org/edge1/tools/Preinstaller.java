package org.edge1.tools;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Installs the APKs build/fetch-apps.sh put in /system_ext/etc/edge1-preinstall as
 * ordinary apps, through PackageInstaller - silently, since the platform signature
 * gives this app INSTALL_PACKAGES. Each file is installed once: an app the owner
 * later uninstalls stays uninstalled. Two files of one package (the apks folder's
 * and F-Droid's) install once, the folder's preferred. Runs are serialized: a press
 * of "install now" while the boot run is going waits for it.
 *
 * Nothing here changes the default launcher any more. Card 18 made Projectivy HOME
 * by itself and then reset in a loop, each time seconds after the boot completed,
 * as the launcher and the overlay started; whatever the trigger, something the
 * owner did not choose should not be what runs at every boot. MainActivity has a
 * button for it.
 */
final class Preinstaller {
    static final String TAG = "Edge1Preinstall";
    static final File DIR = new File("/system_ext/etc/edge1-preinstall");
    private static final String ACTION_RESULT = "org.edge1.tools.INSTALL_RESULT";
    private static final Object LOCK = new Object();

    private Preinstaller() {}

    static File[] bundled() {
        File[] apks = DIR.listFiles((d, n) -> n.endsWith(".apk"));
        if (apks == null) return new File[0];
        Arrays.sort(apks);
        return apks;
    }

    /** @param force install even the ones that were installed once and removed since */
    static void run(Context context, boolean force) {
        synchronized (LOCK) {
            runLocked(context, force);
        }
    }

    private static void runLocked(Context context, boolean force) {
        PackageManager pm = context.getPackageManager();
        SharedPreferences prefs = Prefs.get(context);
        // One file per package. The folder and F-Droid can both supply an app; the
        // folder's copy (not marked "fetched") wins, then the higher version.
        List<String> fetched = confAll("fetched");
        Map<String, File> chosen = new LinkedHashMap<>();
        Map<String, PackageInfo> infos = new HashMap<>();
        for (File apk : bundled()) {
            PackageInfo archive = pm.getPackageArchiveInfo(apk.getPath(), 0);
            if (archive == null) {
                status(prefs, apk.getName(), "unreadable APK");
                continue;
            }
            String pkg = archive.packageName;
            File prev = chosen.get(pkg);
            if (prev == null || preferred(apk, archive, prev, infos.get(pkg), fetched)) {
                if (prev != null) status(prefs, prev.getName(), "same app as " + apk.getName());
                chosen.put(pkg, apk);
                infos.put(pkg, archive);
            } else {
                status(prefs, apk.getName(), "same app as " + prev.getName());
            }
        }
        for (Map.Entry<String, File> e : chosen.entrySet()) {
            String pkg = e.getKey();
            File apk = e.getValue();
            String key = apk.getName();
            if (installedVersion(pm, pkg) >= infos.get(pkg).getLongVersionCode()) {
                prefs.edit().putString(Prefs.DONE_PREFIX + key, pkg).apply();
                status(prefs, key, "installed (" + pkg + ")");
                continue;
            }
            if (!force && prefs.contains(Prefs.DONE_PREFIX + key)) {
                status(prefs, key, "removed by the user; not reinstalled");
                continue;
            }
            String result = install(context, apk, pkg);
            if (result == null) {
                prefs.edit().putString(Prefs.DONE_PREFIX + key, pkg).apply();
                status(prefs, key, "installed (" + pkg + ")");
            } else {
                status(prefs, key, "failed: " + result);
            }
        }
    }

    /** Is a better than b, two files of the same package? */
    private static boolean preferred(File a, PackageInfo ai, File b, PackageInfo bi,
            List<String> fetched) {
        boolean aFetched = fetched.contains(a.getName());
        boolean bFetched = fetched.contains(b.getName());
        if (aFetched != bFetched) return !aFetched;
        return ai.getLongVersionCode() > bi.getLongVersionCode();
    }

    private static long installedVersion(PackageManager pm, String pkg) {
        try {
            return pm.getPackageInfo(pkg, 0).getLongVersionCode();
        } catch (PackageManager.NameNotFoundException e) {
            return -1;
        }
    }

    private static void status(SharedPreferences prefs, String key, String text) {
        Log.i(TAG, key + ": " + text);
        prefs.edit().putString(Prefs.STATUS_PREFIX + key, text).apply();
    }

    /** null on success, else the reason. */
    private static String install(Context context, File apk, String pkg) {
        PackageInstaller installer = context.getPackageManager().getPackageInstaller();
        PackageInstaller.SessionParams params =
                new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(pkg);
        params.setSize(apk.length());
        final String[] outcome = {"timed out"};
        final CountDownLatch done = new CountDownLatch(1);
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent intent) {
                int st = intent.getIntExtra(PackageInstaller.EXTRA_STATUS,
                        PackageInstaller.STATUS_FAILURE);
                if (st == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                    // Only if INSTALL_PACKAGES were missing; say so rather than wait.
                    outcome[0] = "needs confirmation (no INSTALL_PACKAGES?)";
                } else if (st == PackageInstaller.STATUS_SUCCESS) {
                    outcome[0] = null;
                } else {
                    outcome[0] = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);
                    if (outcome[0] == null) outcome[0] = "status " + st;
                }
                done.countDown();
            }
        };
        String action = ACTION_RESULT + "." + pkg;
        context.registerReceiver(receiver, new IntentFilter(action), Context.RECEIVER_NOT_EXPORTED);
        try {
            int id = installer.createSession(params);
            try (PackageInstaller.Session session = installer.openSession(id)) {
                try (InputStream in = new FileInputStream(apk);
                     OutputStream out = session.openWrite("base.apk", 0, apk.length())) {
                    byte[] buf = new byte[1 << 16];
                    for (int n; (n = in.read(buf)) > 0; ) out.write(buf, 0, n);
                    session.fsync(out);
                }
                Intent intent = new Intent(action).setPackage(context.getPackageName());
                PendingIntent pi = PendingIntent.getBroadcast(context, id, intent,
                        PendingIntent.FLAG_MUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
                session.commit(pi.getIntentSender());
            }
            done.await(5, TimeUnit.MINUTES);
            return outcome[0];
        } catch (IOException | RuntimeException e) {
            return e.toString();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return "interrupted";
        } finally {
            context.unregisterReceiver(receiver);
        }
    }

    /** Every "key=value" line of preinstall.conf with that key. */
    static List<String> confAll(String key) {
        List<String> out = new ArrayList<>();
        String text = Sampler.read(new File(DIR, "preinstall.conf").getPath());
        if (text == null) return out;
        for (String line : text.split("\n")) {
            line = line.trim();
            if (line.startsWith(key + "=")) out.add(line.substring(key.length() + 1).trim());
        }
        return out;
    }
}
