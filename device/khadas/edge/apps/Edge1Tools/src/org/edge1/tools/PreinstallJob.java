package org.edge1.tools;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.os.PersistableBundle;

/**
 * Installs one bundled app, the one the owner chose in MainActivity, off the main
 * thread and outside the activity: leaving the screen does not cut an install of a
 * 180MB APK short. One job per file, so several can be queued; Preinstaller runs
 * them one at a time.
 */
public class PreinstallJob extends JobService {
    private static final String APK = "apk";

    static void schedule(Context context, String fileName) {
        PersistableBundle extras = new PersistableBundle();
        extras.putString(APK, fileName);
        Preinstaller.markQueued(context, fileName);
        JobInfo job = new JobInfo.Builder(jobId(fileName),
                new ComponentName(context, PreinstallJob.class))
                .setExtras(extras)
                .setOverrideDeadline(0)
                .build();
        context.getSystemService(JobScheduler.class).schedule(job);
    }

    /** Is an install of this file queued or running? */
    static boolean queued(Context context, String fileName) {
        return context.getSystemService(JobScheduler.class).getPendingJob(jobId(fileName)) != null;
    }

    private static int jobId(String fileName) {
        return 1000 + (fileName.hashCode() & 0xffff);
    }

    @Override
    public boolean onStartJob(JobParameters params) {
        final String fileName = params.getExtras().getString(APK);
        if (fileName == null) return false;
        new Thread(() -> {
            Preinstaller.install(getApplicationContext(), fileName);
            jobFinished(params, false);
        }, "edge1-install").start();
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        // Cut short (the job's time ran out): let JobScheduler run it again.
        return true;
    }
}
