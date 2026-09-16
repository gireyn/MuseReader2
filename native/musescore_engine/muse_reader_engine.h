#pragma once

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define MUSE_READER_EXPORT __declspec(dllexport)
#elif defined(__GNUC__)
#define MUSE_READER_EXPORT __attribute__((visibility("default")))
#else
#define MUSE_READER_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Opens a score and returns a UTF-8 JSON document owned by the engine.
 * Playback events include their original source tick and page-local note
 * rectangles; pages also expose visual note targets that may not have a
 * standalone MIDI event (for example, tied continuations).
 * The caller must release it with muse_reader_free_json().
 */
MUSE_READER_EXPORT const char* muse_reader_open_json(const char* utf8_path);

/**
 * Initializes Qt, MuseScore and all embedded engraving/font resources.
 * Call this on the platform main thread before opening scores.
 */
MUSE_READER_EXPORT int muse_reader_initialize(void);

/** Returns non-zero only when the MuseScore core was compiled into the app. */
MUSE_READER_EXPORT int muse_reader_is_available(void);

MUSE_READER_EXPORT void muse_reader_free_json(const char* json);

MUSE_READER_EXPORT const char* muse_reader_last_error(void);

/** Returns non-zero when the bundled MuseScore FluidSynth renderer is linked. */
MUSE_READER_EXPORT int muse_reader_audio_is_available(void);

/** Initializes the bundled FluidSynth renderer and embedded soundfont. */
MUSE_READER_EXPORT int muse_reader_audio_initialize(void);

/**
 * Starts rendering a JSON array of playback events. The array may contain the
 * note maps returned in the document's `events` field plus typed MIDI control
 * maps from `audioEvents` (program/bank initialization, controllers, pitch
 * bends, and aftertouch).
 */
MUSE_READER_EXPORT int muse_reader_audio_start_json(
    const char* events_json,
    int64_t position_us,
    double speed);

/** Renders interleaved stereo float PCM and returns the number of frames. */
MUSE_READER_EXPORT size_t muse_reader_audio_render(
    float* stereo_interleaved,
    size_t frames);

/** Returns non-zero while a started stream still has audio or release tails. */
MUSE_READER_EXPORT int muse_reader_audio_is_active(void);

MUSE_READER_EXPORT void muse_reader_audio_stop(void);

/** The native renderer's fixed output sample rate. */
MUSE_READER_EXPORT int muse_reader_audio_sample_rate(void);

MUSE_READER_EXPORT const char* muse_reader_audio_last_error(void);

#ifdef __cplusplus
}
#endif
