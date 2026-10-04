package org.edge1.tools;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.hardware.display.DisplayManager;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Display;
import android.view.Gravity;
import android.view.WindowManager;
import android.widget.TextView;

import java.util.Locale;

/**
 * The performance overlay: a small text panel over everything, refreshed once a
 * second. It neither takes focus nor touches, so the remote keeps driving the app
 * underneath. Started at boot, it waits BOOT_DELAY_MS before it shows, and once it
 * has been up SETTLE_MS it clears BootReceiver's count of failed autostarts.
 */
public class HudService extends Service {
    private static final String CHANNEL = "hud";
    private static final String EXTRA_DELAY_MS = "delay_ms";
    static final long BOOT_DELAY_MS = 30 * 1000;
    static final long SETTLE_MS = 3 * 60 * 1000;
    private static volatile boolean running;

    private WindowManager wm;
    private TextView view;
    private Handler handler;
    private TaskFps fps;
    private final Sampler sampler = new Sampler();

    private boolean scheduled;

    private final Runnable show = this::show;
    private final Runnable settled = () ->
            Prefs.get(this).edit().remove(Prefs.HUD_BOOT_TRIES).apply();

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            fps.poll();
            view.setText(render());
            handler.postDelayed(this, 1000);
        }
    };

    static boolean isRunning() {
        return running;
    }

    static void start(Context context) {
        start(context, 0);
    }

    static void start(Context context, long delayMs) {
        context.startForegroundService(new Intent(context, HudService.class)
                .putExtra(EXTRA_DELAY_MS, delayMs));
    }

    static void stop(Context context) {
        context.stopService(new Intent(context, HudService.class));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL,
                getString(R.string.hud_channel), NotificationManager.IMPORTANCE_MIN));
        Notification n = new Notification.Builder(this, CHANNEL)
                .setContentTitle(getString(R.string.hud_notification))
                .setSmallIcon(R.drawable.icon)
                .setOngoing(true)
                .build();
        startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);

        wm = getSystemService(WindowManager.class);
        handler = new Handler(Looper.getMainLooper());
        fps = new TaskFps(this);

        view = new TextView(this);
        view.setTypeface(Typeface.MONOSPACE);
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        view.setTextColor(Color.WHITE);
        view.setBackgroundColor(0xB0000000);
        int pad = (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 6,
                getResources().getDisplayMetrics());
        view.setPadding(pad, pad / 2, pad, pad / 2);
        running = true;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (!scheduled) {
            scheduled = true;
            handler.postDelayed(show, intent == null ? 0 : intent.getLongExtra(EXTRA_DELAY_MS, 0));
        } else if (view.isAttachedToWindow()) {
            // A position change while running: move the panel.
            wm.updateViewLayout(view, layoutParams());
        }
        return START_STICKY;
    }

    private void show() {
        wm.addView(view, layoutParams());
        new Thread(sampler::probeStatic, "edge1-hud-probe").start();
        handler.post(tick);
        handler.postDelayed(settled, SETTLE_MS);
    }

    private WindowManager.LayoutParams layoutParams() {
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT);
        lp.setTitle("Edge1 performance overlay");
        // Trusted, so the window keeps alpha 1. An untrusted overlay that lets
        // touches through gets 0.8 from the window manager (b/218777508), and the
        // VOP's planes have no alpha property: drm_hwcomposer cannot put such a
        // layer on a plane, and card 28 composed the whole screen on the GPU -
        // full-screen video included - whenever this overlay was on.
        lp.setTrustedOverlay();
        switch (Prefs.get(this).getInt(Prefs.HUD_POSITION, Prefs.POS_TOP_RIGHT)) {
            case Prefs.POS_TOP_LEFT: lp.gravity = Gravity.TOP | Gravity.START; break;
            case Prefs.POS_BOTTOM_LEFT: lp.gravity = Gravity.BOTTOM | Gravity.START; break;
            case Prefs.POS_BOTTOM_RIGHT: lp.gravity = Gravity.BOTTOM | Gravity.END; break;
            default: lp.gravity = Gravity.TOP | Gravity.END; break;
        }
        lp.x = 16;
        lp.y = 16;
        return lp;
    }

    private String render() {
        StringBuilder sb = new StringBuilder();
        sb.append("FPS  ").append(fps.text());
        String top = fps.topPackage();
        if (!top.isEmpty()) sb.append("  ").append(top);
        sb.append('\n').append("CPU  ").append(sampler.cpuLoad());
        sb.append('\n').append("     ").append(sampler.cpuClocks());
        sb.append('\n').append("GPU  ").append(sampler.gpuClock())
                .append("  ").append(sampler.gpuRenderer());
        sb.append('\n').append("TEMP ").append(sampler.temperatures());
        sb.append('\n').append("RAM  ").append(sampler.memory());
        sb.append('\n').append("DISP ").append(displayMode());
        sb.append('\n').append("HW decode: ").append(sampler.hwDecoders());
        return sb.toString();
    }

    private String displayMode() {
        Display d = getSystemService(DisplayManager.class).getDisplay(Display.DEFAULT_DISPLAY);
        if (d == null) return "?";
        Display.Mode m = d.getMode();
        return String.format(Locale.ROOT, "%dx%d@%.0fHz",
                m.getPhysicalWidth(), m.getPhysicalHeight(), m.getRefreshRate());
    }

    @Override
    public void onDestroy() {
        running = false;
        // Stopped, not reset: the board was up, whatever the time.
        Prefs.get(this).edit().remove(Prefs.HUD_BOOT_TRIES).apply();
        if (handler != null) {
            handler.removeCallbacks(show);
            handler.removeCallbacks(tick);
            handler.removeCallbacks(settled);
        }
        if (fps != null) fps.stop();
        if (view != null) {
            try {
                wm.removeView(view);
            } catch (IllegalArgumentException ignored) {
                // Never attached.
            }
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
