package icu.ringona.musereader

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Process
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.max

/** Streams the bundled MuseScore FluidSynth renderer into Android's audio sink. */
class FluidScoreSynth {
    companion object {
        private const val TAG = "MuseReaderFluid"
        private const val FRAMES_PER_BLOCK = 1024
        // FluidSynth can take longer than one mixer period on an emulator.
        // Queue a few blocks before starting AudioTrack so the first render
        // does not immediately underrun and get disabled by AudioFlinger.
        private const val PREBUFFER_BLOCKS = 3
    }

    private val lock = Any()
    private var track: AudioTrack? = null
    private var worker: Thread? = null
    private var generation = 0
    private var basePositionUs = 0L
    private var playbackSpeed = 1.0
    private var playbackSampleRate = 44_100
    private var writtenFrames = 0L
    private var lastPositionUs = 0L

    /** Starts native playback, returning false when the embedded renderer is unavailable. */
    fun start(rawEvents: List<Any?>, positionUs: Long, speed: Double): Boolean {
        stop()
        val eventsJson = encodeEvents(rawEvents)
        if (eventsJson == "[]") {
            Log.w(TAG, "Native playback skipped: empty event list")
            return false
        }
        if (!NativeMuseScoreEngine.audioIsAvailable()) {
            logNativeFailure("Native FluidSynth is unavailable")
            return false
        }
        if (!NativeMuseScoreEngine.audioStartJson(eventsJson, positionUs, speed)) {
            logNativeFailure("Native FluidSynth rejected the audio event stream")
            return false
        }

        val sampleRate = NativeMuseScoreEngine.audioSampleRate()
        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT,
        ).let { if (it > 0) it else sampleRate / 10 * 4 }
        val bufferBytes = max(minBuffer * 2, FRAMES_PER_BLOCK * 4)
        val audio = try {
            AudioTrack(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build(),
                bufferBytes,
                AudioTrack.MODE_STREAM,
                AudioManager.AUDIO_SESSION_ID_GENERATE,
            )
        } catch (error: Throwable) {
            NativeMuseScoreEngine.audioStop()
            Log.w(TAG, "Unable to create AudioTrack", error)
            return false
        }
        if (audio.state != AudioTrack.STATE_INITIALIZED) {
            audio.release()
            NativeMuseScoreEngine.audioStop()
            Log.w(TAG, "AudioTrack was not initialized")
            return false
        }

        val localGeneration: Int
        synchronized(lock) {
            generation += 1
            localGeneration = generation
            track = audio
            basePositionUs = positionUs.coerceAtLeast(0L)
            playbackSpeed = if (speed.isFinite()) speed.coerceAtLeast(0.0) else 1.0
            playbackSampleRate = sampleRate.coerceAtLeast(1)
            writtenFrames = 0L
            lastPositionUs = basePositionUs
        }
        val thread = Thread {
            runAudio(audio, localGeneration)
        }.also {
            it.name = "MuseReaderFluidAudio"
        }
        synchronized(lock) {
            if (generation == localGeneration) worker = thread
        }
        thread.start()
        return true
    }

    /** Returns the position currently presented by AudioTrack, if running. */
    fun positionUs(): Long? {
        val snapshot = synchronized(lock) {
            val current = track ?: return@synchronized null
            TrackSnapshot(
                audio = current,
                basePositionUs = basePositionUs,
                speed = playbackSpeed,
                sampleRate = playbackSampleRate,
                writtenFrames = writtenFrames,
                lastPositionUs = lastPositionUs,
            )
        } ?: return null

        val position = AudioTrackClock.positionUs(
            audio = snapshot.audio,
            basePositionUs = snapshot.basePositionUs,
            speed = snapshot.speed,
            sampleRate = snapshot.sampleRate,
            writtenFrames = snapshot.writtenFrames,
            lastPositionUs = snapshot.lastPositionUs,
        )
        return synchronized(lock) {
            if (track !== snapshot.audio) return@synchronized null
            lastPositionUs = max(lastPositionUs, position)
            lastPositionUs
        }
    }

    fun stop() {
        val oldTrack: AudioTrack?
        val oldWorker: Thread?
        synchronized(lock) {
            generation += 1
            oldTrack = track
            oldWorker = worker
            track = null
            worker = null
            basePositionUs = 0L
            playbackSpeed = 1.0
            playbackSampleRate = 44_100
            writtenFrames = 0L
            lastPositionUs = 0L
        }
        NativeMuseScoreEngine.audioStop()
        try {
            oldTrack?.pause()
            oldTrack?.stop()
            oldTrack?.flush()
        } catch (_: IllegalStateException) {
        }
        oldWorker?.interrupt()
        if (oldWorker != null && oldWorker !== Thread.currentThread()) {
            try {
                oldWorker.join(250)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
    }

    private fun runAudio(audio: AudioTrack, localGeneration: Int) {
        val floatBuffer = FloatArray(FRAMES_PER_BLOCK * 2)
        val shortBuffer = ShortArray(FRAMES_PER_BLOCK * 2)
        try {
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            } catch (_: SecurityException) {
                // Some vendor builds do not allow changing the worker
                // priority. Playback remains functional without the hint.
            }

            // AudioTrack starts consuming as soon as play() is called. Fill a
            // bounded amount while it is still paused so a slow first native
            // render (especially on an AVD) cannot cause an initial underrun.
            val capacityFrames = try {
                audio.bufferSizeInFrames
            } catch (_: IllegalStateException) {
                FRAMES_PER_BLOCK * PREBUFFER_BLOCKS
            }
            val prebufferFrames = capacityFrames.coerceIn(
                FRAMES_PER_BLOCK,
                FRAMES_PER_BLOCK * PREBUFFER_BLOCKS,
            )
            var bufferedFrames = 0
            while (bufferedFrames < prebufferFrames && isCurrent(localGeneration)) {
                val frames = NativeMuseScoreEngine.audioRender(floatBuffer)
                if (frames <= 0) {
                    if (!NativeMuseScoreEngine.audioIsActive()) break
                    Thread.yield()
                    continue
                }
                val sampleCount = (frames * 2).coerceAtMost(floatBuffer.size)
                for (index in 0 until sampleCount) {
                    shortBuffer[index] = (floatBuffer[index] * Short.MAX_VALUE)
                        .toInt()
                        .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                        .toShort()
                }
                var offset = 0
                while (offset < sampleCount && isCurrent(localGeneration)) {
                    val written = audio.write(shortBuffer, offset, sampleCount - offset)
                    if (written <= 0) break
                    offset += written
                }
                if (offset <= 0) break
                val blockFrames = offset / 2
                recordWrittenFrames(audio, blockFrames)
                bufferedFrames += blockFrames
                if (offset < sampleCount) break
            }
            if (!isCurrent(localGeneration) || bufferedFrames <= 0) return
            audio.play()
            while (isCurrent(localGeneration)) {
                val frames = NativeMuseScoreEngine.audioRender(floatBuffer)
                if (frames <= 0) {
                    if (!NativeMuseScoreEngine.audioIsActive()) break
                    Thread.yield()
                    continue
                }
                val sampleCount = (frames * 2).coerceAtMost(floatBuffer.size)
                for (index in 0 until sampleCount) {
                    val sample = (floatBuffer[index] * Short.MAX_VALUE)
                        .toInt()
                        .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                    shortBuffer[index] = sample.toShort()
                }
                var offset = 0
                while (offset < sampleCount && isCurrent(localGeneration)) {
                    val written = audio.write(shortBuffer, offset, sampleCount - offset)
                    if (written <= 0) break
                    offset += written
                }
                if (offset > 0) recordWrittenFrames(audio, offset / 2)
                if (offset < sampleCount && isCurrent(localGeneration)) break
            }
            if (isCurrent(localGeneration)) waitForDrain(audio, localGeneration)
        } catch (error: Throwable) {
            if (isCurrent(localGeneration)) Log.w(TAG, "FluidSynth audio stream stopped", error)
        } finally {
            if (isCurrent(localGeneration)) {
                NativeMuseScoreEngine.audioStop()
            }
            try {
                audio.stop()
            } catch (_: IllegalStateException) {
            }
            audio.release()
            synchronized(lock) {
                if (track === audio) {
                    track = null
                    if (generation == localGeneration) worker = null
                }
            }
        }
    }

    private fun isCurrent(localGeneration: Int): Boolean = synchronized(lock) {
        generation == localGeneration && !Thread.currentThread().isInterrupted
    }

    private fun recordWrittenFrames(audio: AudioTrack, frames: Int) {
        if (frames <= 0) return
        synchronized(lock) {
            if (track === audio) writtenFrames += frames.toLong()
        }
    }

    private fun waitForDrain(audio: AudioTrack, localGeneration: Int) {
        val targetFrames = synchronized(lock) {
            if (track === audio) writtenFrames else 0L
        }
        if (targetFrames <= 0L) return
        val deadlineNanos = System.nanoTime() + 2_000_000_000L
        while (isCurrent(localGeneration) && System.nanoTime() < deadlineNanos) {
            val presentedFrames = try {
                audio.playbackHeadPosition.toLong() and 0xffffffffL
            } catch (_: IllegalStateException) {
                return
            }
            if (presentedFrames >= targetFrames) return
            Thread.sleep(5)
        }
    }

    private fun logNativeFailure(prefix: String) {
        val detail = NativeMuseScoreEngine.audioLastError()
        if (detail.isNullOrBlank()) {
            Log.w(TAG, prefix)
        } else {
            Log.w(TAG, "$prefix: $detail")
        }
    }

    private data class TrackSnapshot(
        val audio: AudioTrack,
        val basePositionUs: Long,
        val speed: Double,
        val sampleRate: Int,
        val writtenFrames: Long,
        val lastPositionUs: Long,
    )

    private fun encodeEvents(rawEvents: List<Any?>): String {
        val array = JSONArray()
        for (raw in rawEvents) {
            val map = raw as? Map<*, *> ?: continue
            val jsonObject = JSONObject()
            for ((key, value) in map) {
                if (key is String) jsonObject.put(key, jsonValue(value))
            }
            array.put(jsonObject)
        }
        return array.toString()
    }

    private fun jsonValue(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> JSONObject().apply {
            for ((key, child) in value) {
                if (key is String) put(key, jsonValue(child))
            }
        }
        is Iterable<*> -> JSONArray().apply {
            for (child in value) put(jsonValue(child))
        }
        is Array<*> -> JSONArray().apply {
            for (child in value) put(jsonValue(child))
        }
        is Number, is Boolean, is String, is JSONObject, is JSONArray -> value
        else -> value.toString()
    }
}
