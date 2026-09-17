package icu.ringona.musereader

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.net.Uri
import android.util.Log
import java.io.File

/**
 * Thin wrapper around Android's [MediaPlayer] for audio files
 * (mp3/wav/ogg/flac/m4a/aac/…), the same backend the companion
 * mscz_an_Audio player uses.
 *
 * MediaPlayer delivers its callbacks on the thread that created it, so this
 * class must be used from the main thread (the method-channel thread); only
 * [readMetadata] is safe to call from a worker.
 */
class MediaAudioPlayer(private val context: Context) {
    companion object {
        private const val TAG = "MuseReaderMedia"

        /** Embedded tag title/artist and duration of one audio file. */
        fun readMetadata(path: String): Map<String, Any?> {
            var retriever: MediaMetadataRetriever? = null
            return try {
                retriever = MediaMetadataRetriever()
                retriever.setDataSource(path)
                mapOf(
                    "path" to path,
                    "title" to retriever.extractMetadata(
                        MediaMetadataRetriever.METADATA_KEY_TITLE,
                    ),
                    "artist" to retriever.extractMetadata(
                        MediaMetadataRetriever.METADATA_KEY_ARTIST,
                    ),
                    "durationMs" to retriever.extractMetadata(
                        MediaMetadataRetriever.METADATA_KEY_DURATION,
                    )?.toLongOrNull(),
                )
            } catch (error: Exception) {
                Log.w(TAG, "Unable to read metadata of $path", error)
                mapOf("path" to path)
            } finally {
                runCatching { retriever?.release() }
            }
        }
    }

    private var player: MediaPlayer? = null
    private var prepared = false

    /** Invoked when the current file plays to its end. */
    var onCompleted: (() -> Unit)? = null

    /** Prepares [path]; reports `available`, `durationMs`, `title`, `artist`. */
    fun load(path: String, onResult: (Map<String, Any?>) -> Unit) {
        var replied = false
        fun reply(payload: Map<String, Any?>) {
            if (replied) return
            replied = true
            onResult(payload)
        }
        release()
        val file = File(path)
        if (!file.isFile) {
            reply(mapOf("available" to false, "error" to "音频文件不存在"))
            return
        }
        val metadata = readMetadata(path)
        try {
            val mediaPlayer = MediaPlayer()
            player = mediaPlayer
            mediaPlayer.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            mediaPlayer.setDataSource(context, Uri.fromFile(file))
            mediaPlayer.setOnPreparedListener { preparedPlayer ->
                prepared = true
                reply(
                    mapOf(
                        "available" to true,
                        "durationMs" to preparedPlayer.duration,
                        "title" to metadata["title"],
                        "artist" to metadata["artist"],
                    ),
                )
            }
            mediaPlayer.setOnCompletionListener {
                prepared = true
                onCompleted?.invoke()
            }
            mediaPlayer.setOnErrorListener { _, what, extra ->
                Log.w(TAG, "MediaPlayer error what=$what extra=$extra")
                prepared = false
                reply(
                    mapOf(
                        "available" to false,
                        "error" to "无法解码该音频文件（$what/$extra）",
                    ),
                )
                true
            }
            mediaPlayer.prepareAsync()
        } catch (error: Exception) {
            release()
            reply(
                mapOf(
                    "available" to false,
                    "error" to (error.message ?: "无法打开音频文件"),
                ),
            )
        }
    }

    fun play(): Boolean {
        val mediaPlayer = player ?: return false
        if (!prepared) return false
        return try {
            mediaPlayer.start()
            true
        } catch (error: IllegalStateException) {
            Log.w(TAG, "Unable to start audio playback", error)
            false
        }
    }

    fun pause() {
        val mediaPlayer = player ?: return
        if (!prepared) return
        try {
            if (mediaPlayer.isPlaying) mediaPlayer.pause()
        } catch (error: IllegalStateException) {
            Log.w(TAG, "Unable to pause audio playback", error)
        }
    }

    fun seekTo(positionMs: Int) {
        val mediaPlayer = player ?: return
        if (!prepared) return
        try {
            mediaPlayer.seekTo(positionMs.coerceAtLeast(0))
        } catch (error: IllegalStateException) {
            Log.w(TAG, "Unable to seek audio playback", error)
        }
    }

    fun positionMs(): Int? = try {
        if (prepared) player?.currentPosition else null
    } catch (error: IllegalStateException) {
        null
    }

    fun isPlaying(): Boolean = try {
        prepared && player?.isPlaying == true
    } catch (error: IllegalStateException) {
        false
    }

    /** Releases the platform player; a later load() creates a new one. */
    fun stop() = release()

    private fun release() {
        val mediaPlayer = player
        player = null
        prepared = false
        if (mediaPlayer != null) {
            runCatching { mediaPlayer.reset() }
            runCatching { mediaPlayer.release() }
        }
    }
}
