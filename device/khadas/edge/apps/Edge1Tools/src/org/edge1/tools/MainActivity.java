package org.edge1.tools;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * The settings screen: overlay on/off, its corner, autostart, the default launcher,
 * the sound screen (also in Settings), and the apps on this image - each with a button
 * of its own, installed only when pressed.
 */
public class MainActivity extends Activity {
    private Button hud;
    private Button position;
    private Button autostart;
    private Button launcher;
    private TextView notice;
    private TextView appsTitle;
    private LinearLayout appList;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final List<Preinstaller.Offer> offers = new ArrayList<>();
    private final List<Button> appButtons = new ArrayList<>();
    private boolean offersLoaded;

    /** Refreshes the app buttons every 2s while an install is running. */
    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            if (refreshApps()) handler.postDelayed(this, 2000);
        }
    };

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
        button(list, v -> startActivity(new Intent(this, SoundActivity.class)))
                .setText(R.string.sound_open);

        notice = text(list, 16);
        appsTitle = text(list, 20);
        appsTitle.setText(R.string.bundled_title);
        appList = new LinearLayout(this);
        appList.setOrientation(LinearLayout.VERTICAL);
        list.addView(appList);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(list);
        setContentView(scroll);
        hud.requestFocus();

        // Reading ten APK manifests (one of them 180MB) is not for the UI thread.
        new Thread(() -> {
            List<Preinstaller.Offer> found = Preinstaller.offers(getApplicationContext());
            runOnUiThread(() -> showOffers(found));
        }, "edge1-offers").start();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(poll);
        super.onPause();
    }

    private Button button(LinearLayout parent, View.OnClickListener onClick) {
        Button b = new Button(this);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        b.setAllCaps(false);
        b.setOnClickListener(onClick);
        parent.addView(b);
        return b;
    }

    private TextView text(LinearLayout parent, int sp) {
        TextView t = new TextView(this);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setPadding(0, dp(16), 0, 0);
        parent.addView(t);
        return t;
    }

    private void showOffers(List<Preinstaller.Offer> found) {
        if (isDestroyed()) return;
        offers.clear();
        offers.addAll(found);
        appButtons.clear();
        appList.removeAllViews();
        for (Preinstaller.Offer offer : offers) {
            appButtons.add(button(appList, v -> {
                PreinstallJob.schedule(this, offer.apk.getName());
                refreshApps();
                handler.removeCallbacks(poll);
                handler.postDelayed(poll, 2000);
            }));
        }
        offersLoaded = true;
        refresh();
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
        boolean tripped = p.getBoolean(Prefs.HUD_AUTOSTART_TRIPPED, false);
        notice.setVisibility(tripped ? View.VISIBLE : View.GONE);
        if (tripped) notice.setText(R.string.hud_autostart_tripped);
        if (refreshApps()) {
            handler.removeCallbacks(poll);
            handler.postDelayed(poll, 2000);
        }
    }

    /** Sets every app button's text from what is installed now; true while one installs. */
    private boolean refreshApps() {
        if (!offersLoaded) {
            return false;
        }
        if (offers.isEmpty()) {
            appsTitle.setText(R.string.bundled_none);
            return false;
        }
        boolean busy = false;
        for (int i = 0; i < offers.size(); i++) {
            Preinstaller.Offer o = offers.get(i);
            Button b = appButtons.get(i);
            String name = o.apk.getName();
            String st = Preinstaller.status(this, name);
            long have = Preinstaller.installedVersion(getPackageManager(), o.pkg);
            if (Preinstaller.INSTALLING.equals(st) && PreinstallJob.queued(this, name)) {
                b.setText(getString(R.string.app_installing, o.label));
                b.setEnabled(false);
                busy = true;
            } else if (st != null && st.startsWith("failed")) {
                b.setText(getString(R.string.app_failed, o.label, st.substring(st.indexOf(':') + 1).trim()));
                b.setEnabled(true);
            } else if (have >= o.versionCode) {
                b.setText(getString(R.string.app_installed, o.label, o.versionName));
                b.setEnabled(false);
            } else if (have >= 0) {
                b.setText(getString(R.string.app_update, o.label, o.versionName));
                b.setEnabled(true);
            } else {
                b.setText(getString(R.string.app_install, o.label, o.versionName,
                        String.format(Locale.ROOT, "%.0f MB", o.apk.length() / 1048576.0)));
                b.setEnabled(true);
            }
        }
        return busy;
    }

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                getResources().getDisplayMetrics());
    }
}
