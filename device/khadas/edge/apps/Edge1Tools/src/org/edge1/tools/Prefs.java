package org.edge1.tools;

import android.content.Context;
import android.content.SharedPreferences;

/** The few settings Edge1 Tools keeps, in one place. */
final class Prefs {
    static final String HUD_AUTOSTART = "hud_autostart";
    static final String HUD_POSITION = "hud_position";
    /** Boots in a row that started the overlay and did not last SETTLE_MS after. */
    static final String HUD_BOOT_TRIES = "hud_boot_tries";
    /** Set when those tries turned autostart off; MainActivity says so. */
    static final String HUD_AUTOSTART_TRIPPED = "hud_autostart_tripped";
    static final String DONE_PREFIX = "done:";
    static final String STATUS_PREFIX = "status:";

    /** Overlay corners, in the order the position button cycles through them. */
    static final int POS_TOP_RIGHT = 0;
    static final int POS_TOP_LEFT = 1;
    static final int POS_BOTTOM_LEFT = 2;
    static final int POS_BOTTOM_RIGHT = 3;

    private Prefs() {}

    static SharedPreferences get(Context context) {
        return context.getSharedPreferences("edge1_tools", Context.MODE_PRIVATE);
    }
}
