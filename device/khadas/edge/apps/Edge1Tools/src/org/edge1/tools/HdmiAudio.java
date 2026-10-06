package org.edge1.tools;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.media.AudioSystem;
import android.os.SystemProperties;
import android.util.Log;

/**
 * Connects the audio HAL's "HDMI Out" at boot, so that Android plays to an HDMI device
 * rather than to the built-in "Speaker" that stands for it.
 *
 * Both are the same ALSA PCM (audio/audio_policy_configuration.xml says why there are
 * two). The HAL may attach only built-in devices, so "HDMI Out" is an external one,
 * and on a phone or a TV box something connects an external device when it is plugged
 * in: WiredAccessoryManager, from an extcon or a switch device. This board's HDMI
 * driver (dw-hdmi) has neither, so nothing in Android would. Nothing has to watch the
 * plug either: the box has no other sound output and no picture without HDMI.
 *
 * As an HDMI device the output gets what a TV box's HDMI gets: ACTION_HDMI_AUDIO_PLUG
 * for players, TvSettings' surround settings, its own volume. persist.sys.edge1.hdmi_audio
 * = 0 (hdmi_audio=0 in edge1-options.txt) leaves it on "Speaker", as up to card 28,
 * and disconnects it if it is connected.
 *
 * LOCKED_BOOT_COMPLETED rather than BOOT_COMPLETED: sound should be on HDMI from the
 * first sound, not from when the user is unlocked. Both are handled; the second finds
 * the device connected and does nothing.
 */
public class HdmiAudio extends BroadcastReceiver {
    private static final String TAG = "Edge1HdmiAudio";
    static final String PROP = "persist.sys.edge1.hdmi_audio";
    /** The name the device gets in AudioDeviceInfo.getProductName(). */
    private static final String NAME = "HDMI";

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        if (!Intent.ACTION_LOCKED_BOOT_COMPLETED.equals(action)
                && !Intent.ACTION_BOOT_COMPLETED.equals(action)) return;
        apply(context);
    }

    static void apply(Context context) {
        AudioManager audio = context.getSystemService(AudioManager.class);
        boolean want = SystemProperties.getBoolean(PROP, true);
        boolean have = isConnected(audio);
        if (want == have) {
            Log.i(TAG, "HDMI Out " + (have ? "connected" : "not connected") + ", as wanted");
            return;
        }
        try {
            audio.setWiredDeviceConnectionState(AudioSystem.DEVICE_OUT_HDMI,
                    want ? AudioSystem.DEVICE_STATE_AVAILABLE
                         : AudioSystem.DEVICE_STATE_UNAVAILABLE,
                    "", NAME);
            Log.i(TAG, (want ? "connecting" : "disconnecting") + " HDMI Out (" + PROP + "="
                    + SystemProperties.get(PROP, "") + ")");
        } catch (RuntimeException e) {
            // The HAL refuses it without patches/hardware/interfaces/0001: sound stays on
            // "Speaker", which is the same output.
            Log.w(TAG, "HDMI Out", e);
        }
    }

    static boolean isConnected(AudioManager audio) {
        for (AudioDeviceInfo d : audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            if (d.getType() == AudioDeviceInfo.TYPE_HDMI) return true;
        }
        return false;
    }
}
