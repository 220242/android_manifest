package org.edge1.tools;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.os.PersistableBundle;

/**
 * Runs Preinstaller off the main thread, with JobScheduler's ten minutes to do it.
 * The run after a boot waits BOOT_DELAY_MS, so installs (and the compiling that
 * comes with each) do not pile onto the busiest minute of the boot; "install now"
 * runs at once.
 */
public class PreinstallJob extends JobService {
    private static final int JOB_ID = 1;
    private static final String FORCE = "force";
    static final long BOOT_DELAY_MS = 3 * 60 * 1000;

    static void schedule(Context context, boolean force) {
        PersistableBundle extras = new PersistableBundle();
        extras.putBoolean(FORCE, force);
        JobInfo.Builder job = new JobInfo.Builder(JOB_ID,
                new ComponentName(context, PreinstallJob.class)).setExtras(extras);
        if (force) {
            job.setOverrideDeadline(0);
        } else {
            job.setMinimumLatency(BOOT_DELAY_MS).setOverrideDeadline(BOOT_DELAY_MS);
        }
        context.getSystemService(JobScheduler.class).schedule(job.build());
    }

    @Override
    public boolean onStartJob(JobParameters params) {
        final boolean force = params.getExtras().getBoolean(FORCE, false);
        new Thread(() -> {
            Preinstaller.run(getApplicationContext(), force);
            jobFinished(params, false);
        }, "edge1-preinstall").start();
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        // Cut short (the ten minutes ran out): what is done stays done; run again.
        return true;
    }
}
