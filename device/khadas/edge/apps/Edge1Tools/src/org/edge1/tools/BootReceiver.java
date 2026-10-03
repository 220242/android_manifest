package org.edge1.tools;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.util.Log;

/**
 * After every boot: install whatever bundled app is still due, a few minutes on,
 * and the overlay if asked - unless the overlay is what the board keeps resetting
 * after. Card 18 reset about ten seconds after each boot completed, once the
 * overlay was set to start with it; so each autostart counts a try, the overlay
 * clears the count once it has run SETTLE_MS, and two tries that never got there
 * turn autostart off. Committed, not applied: a reset seconds later must find it
 * on disk.
 */
public class BootReceiver extends BroadcastReceiver {
    static final String TAG = "Edge1Boot";
    private static final int MAX_TRIES = 2;

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;
        PreinstallJob.schedule(context, false);

        SharedPreferences p = Prefs.get(context);
        if (!p.getBoolean(Prefs.HUD_AUTOSTART, false)) return;
        int tries = p.getInt(Prefs.HUD_BOOT_TRIES, 0);
        if (tries >= MAX_TRIES) {
            Log.w(TAG, "overlay autostart off: the last " + tries
                    + " boots that started it ended within "
                    + HudService.SETTLE_MS / 1000 + "s");
            p.edit().putBoolean(Prefs.HUD_AUTOSTART, false)
                    .putBoolean(Prefs.HUD_AUTOSTART_TRIPPED, true)
                    .remove(Prefs.HUD_BOOT_TRIES)
                    .commit();
            return;
        }
        p.edit().putInt(Prefs.HUD_BOOT_TRIES, tries + 1).commit();
        HudService.start(context, HudService.BOOT_DELAY_MS);
    }
}
