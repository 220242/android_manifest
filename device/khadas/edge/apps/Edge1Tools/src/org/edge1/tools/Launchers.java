package org.edge1.tools;

import android.app.role.RoleManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Process;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;

/** The installed launchers, and which one is the default (the HOME role holder). */
final class Launchers {
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
                context.getMainExecutor(), done);
    }
}
