package org.edge1.tools;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Bundle;
import android.provider.Settings;
import android.util.Log;
import android.util.TypedValue;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.List;

/**
 * Settings > Sound & display: the media volume, a test sound, and where the sound goes.
 *
 * TvSettings puts a "Sound" entry on its main screen when a system app handles
 * com.android.tv.settings.SOUND (MainFragment.updateSoundSettings), with this app's
 * sound_pref_title, sound_pref_summary and sound_icon. Device Preferences then hides
 * its own "Display & Sound" entry (DevicePrefFragment.updateSounds) - resolution, HDR,
 * system sounds, surround - so the last button here opens that screen.
 *
 * Why the box needs it: the HDMI output is the audio HAL's "Speaker"
 * (audio/audio_policy_configuration.xml says why), so Android's media volume scales
 * what goes out over HDMI, and an Xbox pad has no volume keys. Card 21 played at 2 of
 * 15, about -40 dB: the sound worked and could not be heard.
 */
public class SoundActivity extends Activity {
    private static final String TAG = "Edge1Sound";
    private static final int STREAM = AudioManager.STREAM_MUSIC;
    // AudioManager.VOLUME_CHANGED_ACTION, which is hidden.
    private static final String VOLUME_CHANGED = "android.media.VOLUME_CHANGED_ACTION";
    private static final AudioAttributes MEDIA = new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build();

    private AudioManager audio;
    private TextView level;
    private ProgressBar bar;
    private TextView output;
    private Button louder;
    private AudioTrack track;

    private final BroadcastReceiver changed = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            refresh();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        audio = getSystemService(AudioManager.class);
        int pad = dp(32);
        LinearLayout list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setPadding(pad, pad, pad, pad);

        TextView title = text(list, 28);
        title.setText(R.string.sound_title);
        title.setPadding(0, 0, 0, 0);

        level = text(list, 20);
        bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        bar.setFocusable(false);
        list.addView(bar, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(24)));

        // Two buttons rather than a seek bar: plain to see which one has the focus,
        // and left/right moves between them the way it does everywhere else.
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        list.addView(row);
        button(row, R.string.sound_quieter, v -> step(-1));
        louder = button(row, R.string.sound_louder, v -> step(+1));

        button(list, R.string.sound_test, v -> playTest());
        output = text(list, 18);
        text(list, 16).setText(R.string.sound_note);
        button(list, R.string.sound_display_settings, v -> openDisplaySound());

        ScrollView scroll = new ScrollView(this);
        scroll.addView(list);
        setContentView(scroll);
        louder.requestFocus();
    }

    @Override
    protected void onResume() {
        super.onResume();
        registerReceiver(changed, new IntentFilter(VOLUME_CHANGED), Context.RECEIVER_NOT_EXPORTED);
        refresh();
    }

    @Override
    protected void onPause() {
        unregisterReceiver(changed);
        stopTest();
        super.onPause();
    }

    private void step(int by) {
        int max = audio.getStreamMaxVolume(STREAM);
        int min = audio.getStreamMinVolume(STREAM);
        int now = audio.getStreamVolume(STREAM);
        int next = Math.max(min, Math.min(max, now + by));
        if (next != now) audio.setStreamVolume(STREAM, next, 0);
        refresh();
    }

    private void refresh() {
        int max = audio.getStreamMaxVolume(STREAM);
        int now = audio.getStreamVolume(STREAM);
        if (audio.isVolumeFixed()) {
            level.setText(R.string.sound_fixed);
        } else if (now == 0 || audio.isStreamMute(STREAM)) {
            level.setText(getString(R.string.sound_level_off, max));
        } else {
            level.setText(getString(R.string.sound_level, now, max));
        }
        bar.setMax(max);
        bar.setProgress(now);
        output.setText(getString(R.string.sound_output, outputName()));
    }

    /** Where media plays now, as the owner would call it. */
    private String outputName() {
        List<AudioDeviceInfo> devices;
        try {
            devices = audio.getAudioDevicesForAttributes(MEDIA);
        } catch (RuntimeException e) {
            Log.w(TAG, "getAudioDevicesForAttributes", e);
            return "?";
        }
        if (devices.isEmpty()) return getString(R.string.sound_output_none);
        StringBuilder sb = new StringBuilder();
        for (AudioDeviceInfo d : devices) {
            if (sb.length() > 0) sb.append(", ");
            switch (d.getType()) {
                // This board's HDMI output, as the audio HAL declares it.
                case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER:
                case AudioDeviceInfo.TYPE_HDMI:
                    sb.append(getString(R.string.sound_output_hdmi));
                    break;
                case AudioDeviceInfo.TYPE_BLUETOOTH_A2DP:
                case AudioDeviceInfo.TYPE_BLE_HEADSET:
                case AudioDeviceInfo.TYPE_BLE_SPEAKER:
                    sb.append("Bluetooth: ").append(d.getProductName());
                    break;
                case AudioDeviceInfo.TYPE_USB_DEVICE:
                case AudioDeviceInfo.TYPE_USB_HEADSET:
                    sb.append("USB: ").append(d.getProductName());
                    break;
                default:
                    sb.append(d.getProductName());
            }
        }
        return sb.toString();
    }

    /** A tone on the left, then a higher one on the right, at the media volume. */
    private void playTest() {
        stopTest();
        final int rate = 48000;
        short[] pcm = new short[2 * (rate * 6 / 10 + rate * 15 / 100 + rate * 6 / 10)];
        int at = tone(pcm, 0, 0, 440, rate * 6 / 10, rate);
        at += 2 * (rate * 15 / 100);
        tone(pcm, at, 1, 660, rate * 6 / 10, rate);
        try {
            track = new AudioTrack.Builder()
                    .setAudioAttributes(MEDIA)
                    .setAudioFormat(new AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(rate)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                            .build())
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .setBufferSizeInBytes(pcm.length * 2)
                    .build();
            track.write(pcm, 0, pcm.length);
            track.play();
        } catch (RuntimeException e) {
            Log.w(TAG, "test tone", e);
            stopTest();
        }
    }

    /**
     * Writes a sine of freq Hz, frames long, into one channel of interleaved stereo pcm
     * from sample index from on: half of full scale, with 20ms fades so it does not
     * click. Returns the index just past it.
     */
    private static int tone(short[] pcm, int from, int channel, int freq, int frames, int rate) {
        int fade = rate / 50;
        for (int i = 0; i < frames; i++) {
            double env = Math.min(1.0, Math.min(i, frames - 1 - i) / (double) fade);
            double s = 0.5 * env * Math.sin(2 * Math.PI * freq * i / rate);
            pcm[from + 2 * i + channel] = (short) (s * Short.MAX_VALUE);
        }
        return from + 2 * frames;
    }

    private void stopTest() {
        if (track == null) return;
        try {
            track.stop();
        } catch (IllegalStateException ignored) {
            // Never started.
        }
        track.release();
        track = null;
    }

    private void openDisplaySound() {
        Intent intent = new Intent(Settings.ACTION_SOUND_SETTINGS).setClassName(
                "com.android.tv.settings",
                "com.android.tv.settings.device.displaysound.DisplaySoundActivity");
        try {
            startActivity(intent);
        } catch (ActivityNotFoundException e) {
            Log.w(TAG, "no TvSettings display & sound screen", e);
        }
    }

    private Button button(LinearLayout parent, int text, View.OnClickListener onClick) {
        Button b = new Button(this);
        b.setText(text);
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

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                getResources().getDisplayMetrics());
    }
}
