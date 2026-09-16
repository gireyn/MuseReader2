package icu.ringona.musereader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log

/**
 * Media-playback foreground service used while a score is playing.
 *
 * Without it Android suspends a backgrounded app: the audio renderer, the
 * Flutter position timer and the automatic "next piece" advance all stop as
 * soon as the screen turns off. The service also holds a partial wake lock so
 * the CPU keeps feeding the audio sink, and offers a stop action in the
 * notification that pauses playback through Flutter.
 *
 * Piece transitions call stopAudio()/startAudio() back to back, so stopping is
 * delayed by a short grace period that a following start cancels; the service
 * therefore survives the automatic advance instead of flickering off.
 */
class PlaybackService : Service() {
    companion object {
        const val ACTION_START = "icu.ringona.musereader.action.PLAYBACK_START"
        const val ACTION_STOP = "icu.ringona.musereader.action.PLAYBACK_STOP"

        private const val TAG = "MuseReaderPlayback"
        private const val CHANNEL_ID = "muse_reader_playback"
        private const val NOTIFICATION_ID = 4101

        /** Grace period that keeps the service alive across a piece change. */
        private const val STOP_GRACE_MS = 3000L

        /** Set by MainActivity; asks Flutter to pause the current playback. */
        @Volatile
        var pauseRequest: (() -> Unit)? = null

        @Volatile
        private var instance: PlaybackService? = null

        /** Start (or keep) the foreground playback service. */
        fun start(context: Context) {
            val current = instance
            if (current != null) {
                current.cancelScheduledStop()
                return
            }
            val intent = Intent(context, PlaybackService::class.java).setAction(ACTION_START)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                Log.w(TAG, "Unable to start the playback service", error)
            }
        }

        /**
         * Ask the service to stop. The stop is delayed so the automatic
         * advance (stopAudio → startAudio) keeps the same foreground service
         * and wake lock.
         */
        fun stop(context: Context) {
            val current = instance
            if (current != null) {
                current.scheduleStop()
            } else {
                runCatching { context.stopService(Intent(context, PlaybackService::class.java)) }
            }
        }
    }

    private val stopHandler = Handler(Looper.getMainLooper())
    private val stopRunnable = Runnable { stopSelf() }
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            cancelScheduledStop()
            pauseRequest?.invoke()
            stopSelf()
            return START_NOT_STICKY
        }
        cancelScheduledStop()
        startForeground(NOTIFICATION_ID, buildNotification())
        acquireWakeLock()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        cancelScheduledStop()
        releaseWakeLock()
        if (instance === this) instance = null
        super.onDestroy()
    }

    private fun scheduleStop() {
        stopHandler.removeCallbacks(stopRunnable)
        stopHandler.postDelayed(stopRunnable, STOP_GRACE_MS)
    }

    private fun cancelScheduledStop() {
        stopHandler.removeCallbacks(stopRunnable)
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = manager
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MuseReader:playback")
                .apply { setReferenceCounted(false) }
                .also { it.acquire() }
        } catch (error: Exception) {
            Log.w(TAG, "Unable to acquire the playback wake lock", error)
        }
    }

    private fun releaseWakeLock() {
        val lock = wakeLock ?: return
        wakeLock = null
        try {
            if (lock.isHeld) lock.release()
        } catch (error: Exception) {
            Log.w(TAG, "Unable to release the playback wake lock", error)
        }
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "Playback",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        description = "MuseReader score playback"
                        setShowBadge(false)
                    },
                )
            }
        }
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
            },
            pendingIntentFlags(),
        )
        val stopPlayback = PendingIntent.getService(
            this,
            1,
            Intent(this, PlaybackService::class.java).setAction(ACTION_STOP),
            pendingIntentFlags(),
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("MuseReader")
            .setContentText("正在播放谱面")
            .setSmallIcon(R.drawable.muse_reader_notification)
            .setContentIntent(openApp)
            .setOngoing(true)
            .addAction(0, "停止", stopPlayback)
            .build()
    }

    private fun pendingIntentFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
}
