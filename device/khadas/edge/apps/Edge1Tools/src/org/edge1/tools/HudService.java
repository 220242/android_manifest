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
 * underneath.
 */
public class HudService extends Service {
    private static final String CHANNEL = "hud";
    private static volatile boolean running;

    private WindowManager wm;
    private TextView view;
    private Handler handler;
    private TaskFps fps;
    private final Sampler sampler = new Sampler();

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
        context.startForegroundService(new Intent(context, HudService.class));
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
        wm.addView(view, layoutParams());
        running = true;

        new Thread(sampler::probeStatic, "edge1-hud-probe").start();
        handler.post(tick);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // A position change while running: move the panel.
        if (view != null) wm.updateViewLayout(view, layoutParams());
        return START_STICKY;
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
        if (handler != null) handler.removeCallbacks(tick);
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
