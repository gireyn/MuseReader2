package icu.ringona.musereader

import org.qtproject.qt5.android.QtNative

/** JNI boundary for the packaged MuseScore 3.6.2 reader core. */
object NativeMuseScoreEngine {
    private var loaded = false

    init {
        try {
            // Qt's JNI bootstrap uses this class loader for lookups made from
            // native worker threads. Normally QtActivityDelegate sets it
            // before loading Qt; MuseReader loads the engine directly, so set
            // the same value first.
            QtNative.setClassLoader(NativeMuseScoreEngine::class.java.classLoader)
            System.loadLibrary("muse_reader_engine")
            loaded = true
        } catch (_: LinkageError) {
            // A missing Qt jar or native dependency should remain a visible
            // fail-closed load failure instead of crashing Activity startup.
        }
    }

    fun isAvailable(): Boolean {
        if (!loaded) return false
        return try {
            isAvailableNative()
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    fun initialize(): Boolean {
        if (!loaded) return false
        return try {
            initializeNative()
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    fun open(path: String): String? {
        if (!loaded) return null
        return try {
            openJsonNative(path)
        } catch (_: UnsatisfiedLinkError) {
            null
        }
    }

    fun lastError(): String? {
        if (!loaded) return null
        return try {
            lastErrorNative()
        } catch (_: UnsatisfiedLinkError) {
            null
        }
    }

    fun audioIsAvailable(): Boolean {
        if (!loaded) return false
        return try {
            audioIsAvailableNative()
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    fun audioInitialize(): Boolean {
        if (!loaded) return false
        return try {
            audioInitializeNative()
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    fun audioStartJson(eventsJson: String, positionUs: Long, speed: Double): Boolean {
        if (!loaded) return false
        return try {
            audioStartNative(eventsJson, positionUs, speed)
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    fun audioRender(output: FloatArray): Int {
        if (!loaded || output.size < 2) return 0
        return try {
            audioRenderNative(output)
        } catch (_: UnsatisfiedLinkError) {
            0
        }
    }

    fun audioIsActive(): Boolean {
        if (!loaded) return false
        return try {
            audioIsActiveNative()
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    fun audioStop() {
        if (!loaded) return
        try {
            audioStopNative()
        } catch (_: UnsatisfiedLinkError) {
            // A non-native debug build may not export the optional audio ABI.
        }
    }

    fun audioSampleRate(): Int {
        if (!loaded) return 44_100
        return try {
            audioSampleRateNative().coerceAtLeast(8_000)
        } catch (_: UnsatisfiedLinkError) {
            44_100
        }
    }

    fun audioLastError(): String? {
        if (!loaded) return null
        return try {
            audioLastErrorNative()
        } catch (_: UnsatisfiedLinkError) {
            null
        }
    }

    @JvmStatic
    private external fun initializeNative(): Boolean

    @JvmStatic
    private external fun isAvailableNative(): Boolean

    @JvmStatic
    private external fun openJsonNative(path: String): String?

    @JvmStatic
    private external fun lastErrorNative(): String?

    @JvmStatic
    private external fun audioIsAvailableNative(): Boolean

    @JvmStatic
    private external fun audioInitializeNative(): Boolean

    @JvmStatic
    private external fun audioStartNative(
        eventsJson: String,
        positionUs: Long,
        speed: Double,
    ): Boolean

    @JvmStatic
    private external fun audioRenderNative(output: FloatArray): Int

    @JvmStatic
    private external fun audioIsActiveNative(): Boolean

    @JvmStatic
    private external fun audioStopNative()

    @JvmStatic
    private external fun audioSampleRateNative(): Int

    @JvmStatic
    private external fun audioLastErrorNative(): String?
}
