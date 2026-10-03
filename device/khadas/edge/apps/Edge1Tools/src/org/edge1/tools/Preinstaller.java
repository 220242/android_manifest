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
import android.graphics.drawable.Drawable;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * The APKs build/fetch-apps.sh put in /system_ext/etc/edge1-preinstall, offered one
 * by one: MainActivity shows a button per app, and nothing is installed unless the
 * owner presses it. (Up to card 19 all of them went in at first boot; the owner wants
 * to choose.) An install goes through PackageInstaller silently - the platform
 * signature gives this app INSTALL_PACKAGES - and the result is an ordinary app,
 * updatable from its store and removable from Settings.
 *
 * Two files of one package (the apks folder's and F-Droid's) make one offer, the
 * folder's preferred, then the higher version. Installs are serialized.
 */
final class Preinstaller {
    static final String TAG = "Edge1Preinstall";
    static final File DIR = new File("/system_ext/etc/edge1-preinstall");
    private static final String ACTION_RESULT = "org.edge1.tools.INSTALL_RESULT";
    private static final Object LOCK = new Object();

    static final String INSTALLING = "installing";

    /** One app on offer: the file chosen for a package, and what it is. */
    static final class Offer {
        final File apk;
        final String pkg;
        final CharSequence label;
        final Drawable icon;
        final String versionName;
        final long versionCode;

        Offer(File apk, String pkg, CharSequence label, Drawable icon, String versionName,
                long versionCode) {
            this.apk = apk;
            this.pkg = pkg;
            this.label = label;
            this.icon = icon;
            this.versionName = versionName == null ? "" : versionName;
            this.versionCode = versionCode;
        }
    }

    private Preinstaller() {}

    static File[] bundled() {
        File[] apks = DIR.listFiles((d, n) -> n.endsWith(".apk"));
        if (apks == null) return new File[0];
        Arrays.sort(apks);
        return apks;
    }

    /** Every app on offer, in file-name order. Reads each APK's manifest and icon: call off the UI thread. */
    static List<Offer> offers(Context context) {
        PackageManager pm = context.getPackageManager();
        List<String> fetched = confAll("fetched");
        Map<String, Offer> chosen = new LinkedHashMap<>();
        for (File apk : bundled()) {
            PackageInfo info = pm.getPackageArchiveInfo(apk.getPath(), 0);
            if (info == null || info.applicationInfo == null) {
                Log.w(TAG, apk.getName() + ": unreadable APK");
                continue;
            }
            info.applicationInfo.sourceDir = apk.getPath();
            info.applicationInfo.publicSourceDir = apk.getPath();
            Offer offer = new Offer(apk, info.packageName, info.applicationInfo.loadLabel(pm),
                    info.applicationInfo.loadIcon(pm), info.versionName, info.getLongVersionCode());
            Offer prev = chosen.get(offer.pkg);
            if (prev == null || preferred(offer, prev, fetched)) chosen.put(offer.pkg, offer);
        }
        return new ArrayList<>(chosen.values());
    }

    /** Is a better than b, two files of the same package? */
    private static boolean preferred(Offer a, Offer b, List<String> fetched) {
        boolean aFetched = fetched.contains(a.apk.getName());
        boolean bFetched = fetched.contains(b.apk.getName());
        if (aFetched != bFetched) return !aFetched;
        return a.versionCode > b.versionCode;
    }

    /** The installed version of pkg, or -1. */
    static long installedVersion(PackageManager pm, String pkg) {
        try {
            return pm.getPackageInfo(pkg, 0).getLongVersionCode();
        } catch (PackageManager.NameNotFoundException e) {
            return -1;
        }
    }

    /** INSTALLING, "failed: ...", or null: nothing to report for this file. */
    static String status(Context context, String fileName) {
        return Prefs.get(context).getString(Prefs.STATUS_PREFIX + fileName, null);
    }

    static void markQueued(Context context, String fileName) {
        Prefs.get(context).edit().putString(Prefs.STATUS_PREFIX + fileName, INSTALLING).apply();
    }

    /** Installs one bundled file; runs on PreinstallJob's thread. */
    static void install(Context context, String fileName) {
        synchronized (LOCK) {
            SharedPreferences prefs = Prefs.get(context);
            File apk = new File(DIR, fileName);
            PackageInfo info = apk.isFile()
                    ? context.getPackageManager().getPackageArchiveInfo(apk.getPath(), 0) : null;
            if (info == null) {
                setStatus(prefs, fileName, "failed: unreadable APK");
                return;
            }
            setStatus(prefs, fileName, INSTALLING);
            String result = install(context, apk, info.packageName);
            if (result == null) {
                Log.i(TAG, fileName + ": installed (" + info.packageName + ")");
                prefs.edit().remove(Prefs.STATUS_PREFIX + fileName).apply();
            } else {
                setStatus(prefs, fileName, "failed: " + result);
            }
        }
    }

    private static void setStatus(SharedPreferences prefs, String key, String text) {
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
