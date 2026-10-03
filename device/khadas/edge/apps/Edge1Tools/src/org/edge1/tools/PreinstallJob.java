package org.edge1.tools;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.os.PersistableBundle;

/** Runs Preinstaller off the main thread, with JobScheduler's ten minutes to do it. */
public class PreinstallJob extends JobService {
    private static final int JOB_ID = 1;
    private static final String FORCE = "force";

    static void schedule(Context context, boolean force) {
        PersistableBundle extras = new PersistableBundle();
        extras.putBoolean(FORCE, force);
        JobInfo job = new JobInfo.Builder(JOB_ID, new ComponentName(context, PreinstallJob.class))
                .setExtras(extras)
                .setOverrideDeadline(0)
                .build();
        context.getSystemService(JobScheduler.class).schedule(job);
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
