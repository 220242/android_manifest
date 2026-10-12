package org.edge1.tools;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ActivityNotFoundException;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.hardware.input.InputManager;
import android.util.Log;
import android.view.InputDevice;

/**
 * A remote with nothing to pair it from: the owner's TV has no HDMI-CEC, so its
 * remote never reaches Android, and a fresh card has no Bluetooth remote bonded.
 * Like a Fire TV stick, then: some time after each boot, if no external input
 * device is connected - no remote, keyboard or gamepad - TvSettings' "Add
 * accessory" screen opens by itself. It searches, and with one input device in
 * pairing mode in range it pairs it after a few seconds' countdown, no key needed.
 *
 * The wait gives a bonded remote the time to come back (they connect on the first
 * key press). Once per boot: back out of the screen and it stays closed until the
 * next one. Logs under Edge1Pair (build/edge1-logcheck.py).
 */
public class RemotePairing extends JobService {
    static final String TAG = "Edge1Pair";
    private static final int JOB_ID = 2000;
    private static final long WAIT_MS = 45_000;

    static void schedule(Context context) {
        JobInfo job = new JobInfo.Builder(JOB_ID, new ComponentName(context, RemotePairing.class))
                .setMinimumLatency(WAIT_MS)
                .setOverrideDeadline(WAIT_MS + 15_000)
                .build();
        context.getSystemService(JobScheduler.class).schedule(job);
    }

    @Override
    public boolean onStartJob(JobParameters params) {
        String input = externalInput(this);
        if (input != null) {
            Log.i(TAG, "input device connected (" + input + "), no pairing screen");
            return false;
        }
        Log.i(TAG, "no remote, keyboard or gamepad connected: opening the pairing screen");
        open(this);
        return false;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        return false;
    }

    /** The name of an external, non-virtual device a person can steer with, or null. */
    static String externalInput(Context context) {
        InputManager im = context.getSystemService(InputManager.class);
        for (int id : im.getInputDeviceIds()) {
            InputDevice d = im.getInputDevice(id);
            if (d == null || d.isVirtual() || !d.isExternal()) continue;
            boolean steers = d.supportsSource(InputDevice.SOURCE_DPAD)
                    || d.supportsSource(InputDevice.SOURCE_GAMEPAD)
                    || d.getKeyboardType() == InputDevice.KEYBOARD_TYPE_ALPHABETIC;
            if (steers) return d.getName();
        }
        return null;
    }

    /**
     * TvSettings' AddAccessoryActivity. Not exported, which the system user may
     * start all the same; "no_input_mode" is what TvSettings' setup passes when
     * there is no input yet. The action is that screen's public way in, should the
     * class ever move.
     */
    static void open(Context context) {
        Intent i = new Intent()
                .setClassName("com.android.tv.settings",
                        "com.android.tv.settings.accessories.AddAccessoryActivity")
                .putExtra("no_input_mode", true)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            context.startActivity(i);
        } catch (ActivityNotFoundException | SecurityException e) {
            Log.w(TAG, "AddAccessoryActivity: " + e + "; trying CONNECT_INPUT");
            try {
                context.startActivity(new Intent("com.google.android.intent.action.CONNECT_INPUT")
                        .putExtra("no_input_mode", true)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            } catch (ActivityNotFoundException | SecurityException e2) {
                Log.e(TAG, "no pairing screen to open: " + e2);
            }
        }
    }
}
