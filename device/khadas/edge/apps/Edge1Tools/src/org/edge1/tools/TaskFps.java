package org.edge1.tools;

import android.app.ActivityManager;
import android.content.Context;
import android.os.SystemClock;
import android.view.WindowManager;
import android.window.TaskFpsCallback;

import java.util.List;
import java.util.concurrent.Executor;

/**
 * The frame rate of whatever is in front: SurfaceFlinger counts the frames of the
 * focused task's layers (its SurfaceViews included, so a playing video counts) and
 * reports through WindowManager.registerTaskFpsCallback - the API behind Android's
 * own game FPS counter. Needs ACCESS_FPS_COUNTER, which the platform signature
 * grants. Polled once a second to follow the focus to a new task.
 */
final class TaskFps {
    private final WindowManager wm;
    private final ActivityManager am;
    private final Executor direct = Runnable::run;
    private int taskId = -1;
    private String topPackage = "";
    private String error;
    private volatile float fps = -1;
    private volatile long lastReport;

    private final TaskFpsCallback callback = new TaskFpsCallback() {
        @Override
        public void onFpsReported(float value) {
            fps = value;
            lastReport = SystemClock.uptimeMillis();
        }
    };

    TaskFps(Context context) {
        wm = context.getSystemService(WindowManager.class);
        am = context.getSystemService(ActivityManager.class);
    }

    /** Follow the focused task; call once a second. */
    void poll() {
        List<ActivityManager.RunningTaskInfo> tasks;
        try {
            tasks = am.getRunningTasks(1);
        } catch (RuntimeException e) {
            error = "tasks: " + e.getClass().getSimpleName();
            return;
        }
        if (tasks == null || tasks.isEmpty()) return;
        ActivityManager.RunningTaskInfo top = tasks.get(0);
        topPackage = top.topActivity != null ? top.topActivity.getPackageName() : "";
        if (top.taskId == taskId) return;
        stop();
        try {
            wm.registerTaskFpsCallback(top.taskId, direct, callback);
            taskId = top.taskId;
            error = null;
        } catch (RuntimeException e) {
            error = e.getClass().getSimpleName();
        }
    }

    void stop() {
        if (taskId >= 0) {
            try {
                wm.unregisterTaskFpsCallback(callback);
            } catch (RuntimeException ignored) {
                // The task is gone; so is the registration.
            }
        }
        taskId = -1;
        fps = -1;
    }

    /** "59.8" - or "0" once the app has stopped drawing for two seconds. */
    String text() {
        if (error != null) return "n/a (" + error + ")";
        if (fps < 0) return "…";
        if (SystemClock.uptimeMillis() - lastReport > 2000) return "0";
        return String.format(java.util.Locale.ROOT, "%.1f", fps);
    }

    String topPackage() {
        return topPackage;
    }
}
