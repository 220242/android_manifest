package org.edge1.tools;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Edge1 Tools' screen, in Material 3 (res/values/themes.xml): the performance mode,
 * the overlay, sound and display, the default launcher, the logs on the card, and
 * the apps on this image - each with a row of its own, installed only when pressed.
 */
public class MainActivity extends Activity {
    private static final String TAG = "Edge1Tools";

    /** Corner segments on screen, left to right, as Prefs positions. */
    private static final int[] CORNERS = {Prefs.POS_TOP_LEFT, Prefs.POS_TOP_RIGHT,
            Prefs.POS_BOTTOM_LEFT, Prefs.POS_BOTTOM_RIGHT};
    private static final int[] CORNER_NAMES = {R.string.pos_top_left, R.string.pos_top_right,
            R.string.pos_bottom_left, R.string.pos_bottom_right};

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Sampler sampler = new Sampler();

    private TextView status;
    private TextView perfNow;
    private TextView notice;
    private TextView appsNote;
    private final List<View> presetTiles = new ArrayList<>();
    private final List<View> cornerTiles = new ArrayList<>();
    private View rowHud;
    private View rowAutostart;
    private View rowSound;
    private View rowLauncher;
    private View cardLogs;
    private View rowLogs;
    private View rowLogsClear;
    private LinearLayout appList;

    private final List<Preinstaller.Offer> offers = new ArrayList<>();
    private final List<View> appRows = new ArrayList<>();
    private boolean offersLoaded;

    /** The clocks and temperatures in the header, and the mode in force, every 2s. */
    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            refreshStatus();
            refreshPerf();
            handler.postDelayed(this, 2000);
        }
    };

    /** Refreshes the app rows every 2s while an install is running. */
    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            if (refreshApps()) handler.postDelayed(this, 2000);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        status = findViewById(R.id.status);
        perfNow = findViewById(R.id.perf_now);
        notice = findViewById(R.id.notice);
        appsNote = findViewById(R.id.apps_note);
        appList = findViewById(R.id.app_list);

        buildPresets();
        buildCorners();

        rowHud = Ui.row(findViewById(R.id.row_hud), getString(R.string.hud_show),
                getString(R.string.hud_show_text), 0, v -> {
                    if (HudService.isRunning()) HudService.stop(this); else HudService.start(this);
                    // The service flips its flag as it starts and stops; read it back shortly.
                    v.postDelayed(this::refresh, 300);
                });
        rowAutostart = Ui.row(findViewById(R.id.row_autostart), getString(R.string.hud_autostart),
                getString(R.string.hud_autostart_text), 0, v -> {
                    SharedPreferences p = Prefs.get(this);
                    p.edit().putBoolean(Prefs.HUD_AUTOSTART, !p.getBoolean(Prefs.HUD_AUTOSTART, false))
                            .remove(Prefs.HUD_BOOT_TRIES)
                            .remove(Prefs.HUD_AUTOSTART_TRIPPED)
                            .apply();
                    refresh();
                });

        rowSound = Ui.row(findViewById(R.id.row_sound), getString(R.string.sound_row), null,
                R.drawable.ic_volume, v -> startActivity(new Intent(this, SoundActivity.class)));
        Ui.row(findViewById(R.id.row_display), getString(R.string.display_row),
                getString(R.string.display_row_text), R.drawable.ic_tv,
                v -> SoundActivity.openDisplaySound(this));
        rowLauncher = Ui.row(findViewById(R.id.row_launcher), null,
                getString(R.string.launcher_text), R.drawable.ic_home,
                v -> Launchers.cycle(this, ok -> refresh()));

        cardLogs = findViewById(R.id.card_logs);
        rowLogs = Ui.row(findViewById(R.id.row_logs), getString(R.string.logs_switch), null, 0,
                v -> {
                    Perf.setLogs(!"1".equals(Perf.cardLogs()));
                    refresh();
                });
        rowLogsClear = Ui.row(findViewById(R.id.row_logs_clear), getString(R.string.logs_clear),
                getString(R.string.logs_clear_text), 0, v -> clearLogs());

        // Reading ten APK manifests (one of them 180MB) is not for the UI thread.
        new Thread(() -> {
            List<Preinstaller.Offer> found = Preinstaller.offers(getApplicationContext());
            runOnUiThread(() -> showOffers(found));
        }, "edge1-offers").start();
        new Thread(sampler::probeStatic, "edge1-probe").start();

        int current = Perf.current(Perf.limits());
        presetTiles.get(Math.max(current, 0)).requestFocus();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
        handler.post(tick);
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(tick);
        handler.removeCallbacks(poll);
        super.onPause();
    }

    /** The six modes, three to a row. */
    private void buildPresets() {
        LinearLayout rows = findViewById(R.id.preset_rows);
        LayoutInflater inflater = getLayoutInflater();
        int gap = getResources().getDimensionPixelSize(R.dimen.tile_gap);
        LinearLayout line = null;
        for (int i = 0; i < Perf.PRESETS.length; i++) {
            if (i % 3 == 0) {
                line = new LinearLayout(this);
                line.setOrientation(LinearLayout.HORIZONTAL);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                lp.topMargin = gap;
                rows.addView(line, lp);
            }
            Perf.Preset p = Perf.PRESETS[i];
            View tile = inflater.inflate(R.layout.item_preset, line, false);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.MATCH_PARENT, 1);
            if (i % 3 != 0) lp.setMarginStart(gap);
            Ui.text(tile, R.id.title, getString(p.title));
            Ui.text(tile, R.id.values, getString(R.string.perf_values, p.big, p.little, p.gpu));
            Ui.text(tile, R.id.summary, getString(p.text));
            tile.setOnClickListener(v -> {
                try {
                    Perf.apply(p);
                } catch (RuntimeException e) {
                    Log.w(TAG, "mode", e);
                    Toast.makeText(this, getString(R.string.perf_failed, e.getMessage()),
                            Toast.LENGTH_LONG).show();
                }
                // edge1-ctl takes a moment; the tick reads back what runs.
                handler.postDelayed(this::refreshPerf, 400);
                handler.postDelayed(this::refreshPerf, 1500);
            });
            Ui.zoomOnFocus(tile);
            line.addView(tile, lp);
            presetTiles.add(tile);
        }
    }

    /** The overlay's corner as a segmented control. */
    private void buildCorners() {
        LinearLayout group = findViewById(R.id.corner_group);
        LayoutInflater inflater = getLayoutInflater();
        int gap = getResources().getDimensionPixelSize(R.dimen.tile_gap);
        for (int i = 0; i < CORNERS.length; i++) {
            final int pos = CORNERS[i];
            TextView seg = (TextView) inflater.inflate(R.layout.item_segment, group, false);
            seg.setText(CORNER_NAMES[i]);
            LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams) seg.getLayoutParams();
            if (i > 0) lp.setMarginStart(gap);
            seg.setOnClickListener(v -> {
                Prefs.get(this).edit().putInt(Prefs.HUD_POSITION, pos).apply();
                if (HudService.isRunning()) HudService.start(this);
                refresh();
            });
            Ui.zoomOnFocus(seg);
            group.addView(seg, lp);
            cornerTiles.add(seg);
        }
    }

    private void refresh() {
        SharedPreferences p = Prefs.get(this);
        Ui.checked(rowHud, HudService.isRunning());
        int pos = p.getInt(Prefs.HUD_POSITION, Prefs.POS_TOP_RIGHT);
        for (int i = 0; i < CORNERS.length; i++) cornerTiles.get(i).setActivated(CORNERS[i] == pos);
        Ui.checked(rowAutostart, p.getBoolean(Prefs.HUD_AUTOSTART, false));
        boolean tripped = p.getBoolean(Prefs.HUD_AUTOSTART_TRIPPED, false);
        notice.setVisibility(tripped ? View.VISIBLE : View.GONE);
        if (tripped) notice.setText(R.string.hud_autostart_tripped);

        AudioManager audio = getSystemService(AudioManager.class);
        Ui.text(rowSound, R.id.summary, getString(R.string.sound_row_text,
                audio.getStreamVolume(AudioManager.STREAM_MUSIC),
                audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)));
        Ui.text(rowLauncher, R.id.title, Launchers.label(this, Launchers.current(this)));

        // Logs: only where a bootwatch found the card (debuggable builds booted from it).
        String logs = Build.IS_DEBUGGABLE ? Perf.cardLogs() : "";
        cardLogs.setVisibility(logs.isEmpty() ? View.GONE : View.VISIBLE);
        boolean logsOn = !"0".equals(logs);
        Ui.checked(rowLogs, logsOn);
        Ui.text(rowLogs, R.id.summary, getString(logsOn ? R.string.logs_on_text : R.string.logs_off_text));
        Ui.text(rowLogsClear, R.id.summary,
                getString(logsOn ? R.string.logs_clear_first : R.string.logs_clear_text));

        refreshPerf();
        if (refreshApps()) {
            handler.removeCallbacks(poll);
            handler.postDelayed(poll, 2000);
        }
    }

    private void refreshStatus() {
        int[] c = Perf.clocks();
        status.setText(getString(R.string.status, mhz(c[0]), mhz(c[1]), mhz(c[2]),
                sampler.temperatures()));
    }

    private static String mhz(int v) {
        return v < 0 ? "?" : String.format(Locale.ROOT, "%d", v);
    }

    /** Marks the mode in force - read from the kernel, so a PC's edit shows too. */
    private void refreshPerf() {
        int[] l = Perf.limits();
        int current = Perf.current(l);
        for (int i = 0; i < presetTiles.size(); i++) {
            View tile = presetTiles.get(i);
            tile.setActivated(i == current);
            ImageView check = tile.findViewById(R.id.check);
            check.setVisibility(i == current ? View.VISIBLE : View.INVISIBLE);
        }
        perfNow.setText(getString(current >= 0 ? R.string.perf_now : R.string.perf_now_own,
                l[0], l[1], l[2]));
    }

    private void clearLogs() {
        if (!"0".equals(Perf.cardLogs())) {
            Toast.makeText(this, R.string.logs_clear_first, Toast.LENGTH_SHORT).show();
            return;
        }
        new AlertDialog.Builder(this)
                .setTitle(R.string.logs_clear_title)
                .setMessage(R.string.logs_clear_confirm)
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(R.string.delete, (d, w) -> {
                    Perf.request("logs-clear");
                    Toast.makeText(this, R.string.logs_cleared, Toast.LENGTH_SHORT).show();
                })
                .show();
    }

    private void showOffers(List<Preinstaller.Offer> found) {
        if (isDestroyed()) return;
        offers.clear();
        offers.addAll(found);
        appRows.clear();
        appList.removeAllViews();
        LayoutInflater inflater = getLayoutInflater();
        for (Preinstaller.Offer offer : offers) {
            View row = inflater.inflate(R.layout.item_app, appList, false);
            Ui.text(row, R.id.title, offer.label);
            ImageView icon = row.findViewById(R.id.icon);
            if (offer.icon != null) icon.setImageDrawable(offer.icon);
            row.setOnClickListener(v -> {
                PreinstallJob.schedule(this, offer.apk.getName());
                refreshApps();
                handler.removeCallbacks(poll);
                handler.postDelayed(poll, 2000);
            });
            Ui.zoomOnFocus(row);
            appList.addView(row);
            appRows.add(row);
        }
        offersLoaded = true;
        refresh();
    }

    /** Sets every app row from what is installed now; true while one installs. */
    private boolean refreshApps() {
        if (!offersLoaded) {
            return false;
        }
        if (offers.isEmpty()) {
            appsNote.setText(R.string.bundled_none);
            return false;
        }
        appsNote.setText(R.string.bundled_note);
        boolean busy = false;
        for (int i = 0; i < offers.size(); i++) {
            Preinstaller.Offer o = offers.get(i);
            View row = appRows.get(i);
            String name = o.apk.getName();
            String st = Preinstaller.status(this, name);
            long have = Preinstaller.installedVersion(getPackageManager(), o.pkg);
            String size = String.format(Locale.ROOT, "%.0f MB", o.apk.length() / 1048576.0);
            CharSequence summary = getString(R.string.app_summary, o.versionName, size);
            if (Preinstaller.INSTALLING.equals(st) && PreinstallJob.queued(this, name)) {
                Ui.action(row, getString(R.string.action_installing));
                row.setEnabled(false);
                busy = true;
            } else if (st != null && st.startsWith("failed")) {
                summary = getString(R.string.app_failed_text, st.substring(st.indexOf(':') + 1).trim());
                Ui.action(row, getString(R.string.action_retry));
                row.setEnabled(true);
            } else if (have >= o.versionCode) {
                Ui.action(row, getString(R.string.action_installed));
                row.setEnabled(false);
            } else if (have >= 0) {
                Ui.action(row, getString(R.string.action_update));
                row.setEnabled(true);
            } else {
                Ui.action(row, getString(R.string.action_install));
                row.setEnabled(true);
            }
            Ui.text(row, R.id.summary, summary);
        }
        return busy;
    }
}
