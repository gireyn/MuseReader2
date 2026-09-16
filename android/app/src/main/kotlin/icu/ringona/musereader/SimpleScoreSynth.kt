package icu.ringona.musereader

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Process
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/** Small audible fallback for the reader while the MuseScore synth is optional. */
class SimpleScoreSynth {
    private val sampleRate = 44100
    private val lock = Any()
    private var track: AudioTrack? = null
    private var worker: Thread? = null
    private var generation = 0
    private var basePositionUs = 0L
    private var playbackSpeed = 1.0
    private var writtenFrames = 0L
    private var lastPositionUs = 0L

    fun start(rawEvents: List<Any?>, positionUs: Long, speed: Double) {
        val events = rawEvents.mapNotNull { raw ->
            val map = raw as? Map<*, *> ?: return@mapNotNull null
            val start = (map["startUs"] as? Number)?.toDouble() ?: return@mapNotNull null
            val end = (map["endUs"] as? Number)?.toDouble() ?: return@mapNotNull null
            val pitch = ((map["pitch"] as? Number)?.toInt() ?: 60).coerceIn(0, 127)
            val tuningValue = (map["tuning"] as? Number)?.toDouble()
                ?: (map["cents"] as? Number)?.toDouble()
                ?: 0.0
            val tuning = if (tuningValue.isFinite()) {
                tuningValue.coerceIn(-1_000_000.0, 1_000_000.0)
            } else {
                0.0
            }
            val velocity = (map["velocity"] as? Number)?.toDouble() ?: 80.0
            ToneEvent(start, max(start + 1.0, end), pitch, tuning, velocity)
        }
        stop()
        if (events.isEmpty()) return

        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        ).coerceAtLeast(2048)
        val audio = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build(),
            AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build(),
            minBuffer * 2,
            AudioTrack.MODE_STREAM,
            AudioManager.AUDIO_SESSION_ID_GENERATE,
        )
        val localGeneration: Int
        synchronized(lock) {
            track = audio
            generation += 1
            localGeneration = generation
            basePositionUs = positionUs.coerceAtLeast(0L)
            playbackSpeed = if (speed.isFinite()) speed.coerceAtLeast(0.0) else 1.0
            writtenFrames = 0L
            lastPositionUs = basePositionUs
        }
        worker = Thread {
            val buffer = ShortArray(1024)
            var frame = 0L
            try {
                try {
                    Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
                } catch (_: SecurityException) {
                    // Keep playback working on vendor builds that reject the
                    // priority hint.
                }

                // Prime AudioTrack while paused.  Starting it before the
                // first oscillator block is ready causes an immediate
                // underrun on slower AVDs.
                val capacityFrames = try {
                    audio.bufferSizeInFrames
                } catch (_: IllegalStateException) {
                    buffer.size * 3
                }
                val prebufferFrames = capacityFrames.coerceIn(
                    buffer.size,
                    buffer.size * 3,
                )
                var bufferedFrames = 0
                while (bufferedFrames < prebufferFrames && isCurrent(localGeneration)) {
                    var hasSound = false
                    for (index in buffer.indices) {
                        val timeUs = positionUs +
                            (frame + index) * 1_000_000.0 / sampleRate * speed
                        val sample = sampleAt(events, timeUs)
                        buffer[index] = (sample * Short.MAX_VALUE).toInt()
                            .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                            .toShort()
                        if (sample != 0.0) hasSound = true
                    }
                    val written = audio.write(buffer, 0, buffer.size)
                    if (written <= 0) break
                    frame += written
                    recordWrittenFrames(audio, written)
                    bufferedFrames += written
                    if (written < buffer.size) break
                }
                if (!isCurrent(localGeneration) || bufferedFrames <= 0) return@Thread
                audio.play()
                while (isCurrent(localGeneration)) {
                    var hasSound = false
                    for (index in buffer.indices) {
                        val timeUs = positionUs +
                            (frame + index) * 1_000_000.0 / sampleRate * speed
                        val sample = sampleAt(events, timeUs)
                        buffer[index] = (sample * Short.MAX_VALUE).toInt()
                            .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                            .toShort()
                        if (sample != 0.0) hasSound = true
                    }
                    var offset = 0
                    while (offset < buffer.size && isCurrent(localGeneration)) {
                        val written = audio.write(buffer, offset, buffer.size - offset)
                        if (written <= 0) break
                        offset += written
                    }
                    frame += offset
                    recordWrittenFrames(audio, offset)
                    if (offset < buffer.size && isCurrent(localGeneration)) break
                    val lastEnd = events.maxOf { it.endUs }
                    if (positionUs +
                            frame * 1_000_000.0 / sampleRate * speed >= lastEnd &&
                        !hasSound
                    ) {
                        break
                    }
                }
                if (isCurrent(localGeneration)) waitForDrain(audio, localGeneration)
            } finally {
                try {
                    audio.stop()
                } catch (_: IllegalStateException) {
                }
                audio.release()
                synchronized(lock) {
                    if (track === audio) track = null
                }
            }
        }.also {
            it.name = "MuseReaderAudio"
            it.start()
        }
    }

    /** Returns the position currently presented by AudioTrack, if running. */
    fun positionUs(): Long? {
        val snapshot = synchronized(lock) {
            val current = track ?: return@synchronized null
            TrackSnapshot(
                audio = current,
                basePositionUs = basePositionUs,
                speed = playbackSpeed,
                writtenFrames = writtenFrames,
                lastPositionUs = lastPositionUs,
            )
        } ?: return null

        val position = AudioTrackClock.positionUs(
            audio = snapshot.audio,
            basePositionUs = snapshot.basePositionUs,
            speed = snapshot.speed,
            sampleRate = sampleRate,
            writtenFrames = snapshot.writtenFrames,
            lastPositionUs = snapshot.lastPositionUs,
        )
        return synchronized(lock) {
            if (track !== snapshot.audio) return@synchronized null
            lastPositionUs = maxOf(lastPositionUs, position)
            lastPositionUs
        }
    }

    fun stop() {
        synchronized(lock) {
            generation += 1
            try {
                track?.pause()
                track?.flush()
            } catch (_: IllegalStateException) {
            }
            track = null
            basePositionUs = 0L
            playbackSpeed = 1.0
            writtenFrames = 0L
            lastPositionUs = 0L
        }
        worker?.interrupt()
        worker = null
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

    private data class TrackSnapshot(
        val audio: AudioTrack,
        val basePositionUs: Long,
        val speed: Double,
        val writtenFrames: Long,
        val lastPositionUs: Long,
    )

    private fun sampleAt(events: List<ToneEvent>, timeUs: Double): Double {
        var sum = 0.0
        var active = 0
        for (event in events) {
            if (timeUs < event.startUs || timeUs >= event.endUs) continue
            active += 1
            val elapsed = timeUs - event.startUs
            val duration = event.endUs - event.startUs
            val attack = min(1.0, elapsed / 12_000.0)
            val release = min(1.0, (duration - elapsed) / 35_000.0)
            val envelope = min(attack, release)
            // MuseScore's Note::tuning is a cent offset from the integer MIDI
            // key.  Apply it per oscillator voice so the fallback remains
            // useful when the native FluidSynth library is unavailable.
            val frequency = 440.0 * 2.0.pow(
                ((event.pitch - 69) * 100.0 + event.tuning) / 1200.0,
            )
            if (!frequency.isFinite()) continue
            sum += sin(2.0 * PI * frequency * elapsed / 1_000_000.0) *
                envelope * event.velocity / 127.0
        }
        return if (active == 0) {
            0.0
        } else {
            (sum / sqrt(active.toDouble()) * 0.22).coerceIn(-0.95, 0.95)
        }
    }

    private data class ToneEvent(
        val startUs: Double,
        val endUs: Double,
        val pitch: Int,
        val tuning: Double,
        val velocity: Double,
    )
}
