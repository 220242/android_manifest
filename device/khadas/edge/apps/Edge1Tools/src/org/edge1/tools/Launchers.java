package org.edge1.tools;

import android.app.role.RoleManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Process;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;

/**
 * The installed launchers, and which one is the default (the HOME role holder).
 *
 * The launcher picked with Edge1 Tools' "Default launcher" button (cycle) is also
 * kept in Edge1 Tools' own settings, and after each boot, if Android has another one
 * as HOME by then, it is made HOME again and gone home to: a launcher chosen on card
 * 30 did not survive a reboot. So the button is what decides; a launcher picked
 * anywhere else holds until the next boot. Picking the stock launcher with the
 * button keeps that one. A kept launcher that has since been removed is forgotten,
 * and Android's own pick - the stock one - stays.
 */
final class Launchers {
    static final String TAG = "Edge1Launcher";

    private Launchers() {}

    /** Packages with a HOME activity, FallbackHome (negative priority) left out. */
    static List<String> installed(Context context) {
        Intent home = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
        List<String> out = new ArrayList<>();
        for (ResolveInfo ri : context.getPackageManager().queryIntentActivities(home,
                PackageManager.MATCH_DEFAULT_ONLY)) {
            if (ri.priority < 0 || ri.activityInfo == null) continue;
            String pkg = ri.activityInfo.packageName;
            if (!out.contains(pkg)) out.add(pkg);
        }
        return out;
    }

    static String current(Context context) {
        RoleManager roles = context.getSystemService(RoleManager.class);
        List<String> holders = roles.getRoleHolders(RoleManager.ROLE_HOME);
        return holders.isEmpty() ? null : holders.get(0);
    }

    static CharSequence label(Context context, String pkg) {
        if (pkg == null) return "-";
        PackageManager pm = context.getPackageManager();
        try {
            return pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0));
        } catch (PackageManager.NameNotFoundException e) {
            return pkg;
        }
    }

    /** Make the next installed launcher after the current one the default. */
    static void cycle(Context context, Consumer<Boolean> done) {
        List<String> all = installed(context);
        if (all.isEmpty()) {
            done.accept(false);
            return;
        }
        int i = all.indexOf(current(context));
        String next = all.get((i + 1) % all.size());
        context.getSystemService(RoleManager.class).addRoleHolderAsUser(
                RoleManager.ROLE_HOME, next, 0, Process.myUserHandle(),
                context.getMainExecutor(), ok -> {
                    if (ok) remember(context, next);
                    done.accept(ok);
                });
    }

    /** Keep pkg as the owner's launcher. Committed: a reset seconds later must find it. */
    static void remember(Context context, String pkg) {
        Prefs.get(context).edit().putString(Prefs.LAUNCHER, pkg).commit();
    }

    /** After boot: make the kept launcher HOME again if something else is; then done. */
    static void restore(Context context, Runnable done) {
        String saved = Prefs.get(context).getString(Prefs.LAUNCHER, null);
        String now = current(context);
        Intent home = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
        ResolveInfo resolved = context.getPackageManager().resolveActivity(home,
                PackageManager.MATCH_DEFAULT_ONLY);
        Log.i(TAG, "boot: HOME role " + now + ", kept " + saved + ", HOME resolves to "
                + (resolved == null || resolved.activityInfo == null ? null
                        : resolved.activityInfo.packageName + "/" + resolved.activityInfo.name));
        if (saved == null || saved.equals(now)) {
            done.run();
            return;
        }
        if (!installed(context).contains(saved)) {
            Log.i(TAG, "boot: " + saved + " is no longer a launcher; forgetting it");
            Prefs.get(context).edit().remove(Prefs.LAUNCHER).commit();
            done.run();
            return;
        }
        context.getSystemService(RoleManager.class).addRoleHolderAsUser(
                RoleManager.ROLE_HOME, saved, 0, Process.myUserHandle(),
                context.getMainExecutor(), ok -> {
                    Log.i(TAG, "boot: HOME back to " + saved + (ok ? "" : " FAILED"));
                    // The stock launcher is on screen by now; go home to the kept one.
                    if (ok) {
                        context.startActivity(new Intent(home)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                    }
                    done.run();
                });
    }
}
