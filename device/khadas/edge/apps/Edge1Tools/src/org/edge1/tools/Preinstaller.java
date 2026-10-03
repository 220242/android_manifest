package org.edge1.tools;

import android.app.PendingIntent;
import android.app.role.RoleManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.os.Process;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Installs the APKs build/fetch-apps.sh put in /system_ext/etc/edge1-preinstall as
 * ordinary apps, through PackageInstaller - silently, since the platform signature
 * gives this app INSTALL_PACKAGES. Each file is installed once: an app the owner
 * later uninstalls stays uninstalled. preinstall.conf may name one of them as the
 * launcher; it becomes the HOME role holder once, after it is installed.
 */
final class Preinstaller {
    static final String TAG = "Edge1Preinstall";
    static final File DIR = new File("/system_ext/etc/edge1-preinstall");
    private static final String ACTION_RESULT = "org.edge1.tools.INSTALL_RESULT";

    private Preinstaller() {}

    static File[] bundled() {
        File[] apks = DIR.listFiles((d, n) -> n.endsWith(".apk"));
        if (apks == null) return new File[0];
        Arrays.sort(apks);
        return apks;
    }

    /** @param force install even the ones that were installed once and removed since */
    static void run(Context context, boolean force) {
        PackageManager pm = context.getPackageManager();
        SharedPreferences prefs = Prefs.get(context);
        for (File apk : bundled()) {
            String key = apk.getName();
            PackageInfo archive = pm.getPackageArchiveInfo(apk.getPath(), 0);
            if (archive == null) {
                status(prefs, key, "unreadable APK");
                continue;
            }
            String pkg = archive.packageName;
            if (installedVersion(pm, pkg) >= archive.getLongVersionCode()) {
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
        setHomeOnce(context, prefs, pm);
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

    /** Make preinstall.conf's launcher the default HOME app, once. */
    private static void setHomeOnce(Context context, SharedPreferences prefs, PackageManager pm) {
        if (prefs.getBoolean(Prefs.HOME_SET, false)) return;
        String file = conf("home");
        if (file == null) return;
        PackageInfo archive = pm.getPackageArchiveInfo(new File(DIR, file).getPath(), 0);
        if (archive == null || installedVersion(pm, archive.packageName) < 0) return;
        RoleManager roles = context.getSystemService(RoleManager.class);
        if (roles == null || !roles.isRoleAvailable(RoleManager.ROLE_HOME)) return;
        final boolean[] ok = {false};
        final CountDownLatch done = new CountDownLatch(1);
        try {
            roles.addRoleHolderAsUser(RoleManager.ROLE_HOME, archive.packageName, 0,
                    Process.myUserHandle(), context.getMainExecutor(), success -> {
                        ok[0] = success;
                        done.countDown();
                    });
            done.await(30, TimeUnit.SECONDS);
        } catch (RuntimeException e) {
            Log.w(TAG, "could not set the launcher", e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        Log.i(TAG, "default launcher " + archive.packageName + ": " + (ok[0] ? "set" : "not set"));
        if (ok[0]) prefs.edit().putBoolean(Prefs.HOME_SET, true).apply();
    }

    /** A "key=value" line of preinstall.conf. */
    static String conf(String key) {
        String text = Sampler.read(new File(DIR, "preinstall.conf").getPath());
        if (text == null) return null;
        for (String line : text.split("\n")) {
            line = line.trim();
            if (line.startsWith(key + "=")) return line.substring(key.length() + 1).trim();
        }
        return null;
    }
}
