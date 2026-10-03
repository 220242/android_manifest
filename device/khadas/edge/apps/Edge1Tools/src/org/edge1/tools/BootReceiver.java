package org.edge1.tools;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** After every boot: install whatever bundled app is still due, and the overlay if asked. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;
        PreinstallJob.schedule(context, false);
        if (Prefs.get(context).getBoolean(Prefs.HUD_AUTOSTART, false)) {
            HudService.start(context);
        }
    }
}
