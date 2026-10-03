package org.edge1.tools;

import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;

/** The settings screen: overlay on/off, its corner, autostart, the default launcher, and the bundled apps. */
public class MainActivity extends Activity {
    private Button hud;
    private Button position;
    private Button autostart;
    private Button launcher;
    private TextView status;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        int pad = dp(32);
        LinearLayout list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText(R.string.app_name);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 28);
        list.addView(title);

        hud = button(list, v -> {
            if (HudService.isRunning()) HudService.stop(this); else HudService.start(this);
            // The service flips its flag as it starts and stops; read it back shortly.
            v.postDelayed(this::refresh, 300);
        });
        position = button(list, v -> {
            SharedPreferences p = Prefs.get(this);
            int next = (p.getInt(Prefs.HUD_POSITION, Prefs.POS_TOP_RIGHT) + 1) % 4;
            p.edit().putInt(Prefs.HUD_POSITION, next).apply();
            if (HudService.isRunning()) HudService.start(this);
            refresh();
        });
        autostart = button(list, v -> {
            SharedPreferences p = Prefs.get(this);
            p.edit().putBoolean(Prefs.HUD_AUTOSTART, !p.getBoolean(Prefs.HUD_AUTOSTART, false))
                    .remove(Prefs.HUD_BOOT_TRIES)
                    .remove(Prefs.HUD_AUTOSTART_TRIPPED)
                    .apply();
            refresh();
        });
        launcher = button(list, v -> Launchers.cycle(this, ok -> refresh()));
        Button install = button(list, v -> {
            PreinstallJob.schedule(this, true);
            status.setText(R.string.install_started);
            v.postDelayed(this::refresh, 15000);
        });
        install.setText(R.string.install_now);

        status = new TextView(this);
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        status.setPadding(0, dp(16), 0, 0);
        list.addView(status);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(list);
        setContentView(scroll);
        hud.requestFocus();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
    }

    private Button button(LinearLayout parent, View.OnClickListener onClick) {
        Button b = new Button(this);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        b.setAllCaps(false);
        b.setOnClickListener(onClick);
        parent.addView(b);
        return b;
    }

    private void refresh() {
        SharedPreferences p = Prefs.get(this);
        hud.setText(HudService.isRunning() ? R.string.hud_on : R.string.hud_off);
        int[] names = {R.string.pos_top_right, R.string.pos_top_left,
                R.string.pos_bottom_left, R.string.pos_bottom_right};
        int pos = p.getInt(Prefs.HUD_POSITION, Prefs.POS_TOP_RIGHT);
        position.setText(getString(R.string.hud_position, getString(names[pos & 3])));
        autostart.setText(p.getBoolean(Prefs.HUD_AUTOSTART, false)
                ? R.string.hud_autostart_on : R.string.hud_autostart_off);
        launcher.setText(getString(R.string.launcher,
                Launchers.label(this, Launchers.current(this))));

        StringBuilder sb = new StringBuilder();
        if (p.getBoolean(Prefs.HUD_AUTOSTART_TRIPPED, false)) {
            sb.append(getString(R.string.hud_autostart_tripped)).append("\n\n");
        }
        sb.append(getString(R.string.bundled_title)).append('\n');
        File[] apks = Preinstaller.bundled();
        if (apks.length == 0) sb.append(getString(R.string.bundled_none));
        for (File f : apks) {
            String s = p.getString(Prefs.STATUS_PREFIX + f.getName(), "…");
            sb.append("• ").append(f.getName().replace(".apk", "")).append(": ").append(s)
                    .append('\n');
        }
        status.setText(sb);
    }

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                getResources().getDisplayMetrics());
    }
}
