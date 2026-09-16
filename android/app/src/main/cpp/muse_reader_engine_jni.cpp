#include <jni.h>

#include <algorithm>
#include <climits>
#include <cstddef>

#include "muse_reader_engine.h"

extern "C" JNIEXPORT jboolean JNICALL
Java_icu_ringona_musereader_NativeMuseScoreEngine_initializeNative(
    JNIEnv* /* env */,
    jclass /* clazz */) {
  return muse_reader_initialize() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_icu_ringona_musereader_NativeMuseScoreEngine_isAvailableNative(
    JNIEnv* /* env */,
    jclass /* clazz */) {
  return muse_reader_is_available() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_icu_ringona_musereader_NativeMuseScoreEngine_openJsonNative(
    JNIEnv* env,
    jclass /* clazz */,
    jstring path) {
  if (path == nullptr) return nullptr;

  const char* utf8_path = env->GetStringUTFChars(path, nullptr);
  if (utf8_path == nullptr) return nullptr;
  const char* json = muse_reader_open_json(utf8_path);
  env->ReleaseStringUTFChars(path, utf8_path);

  if (json == nullptr) return nullptr;
  jstring result = env->NewStringUTF(json);
  muse_reader_free_json(json);
  return result;
}

extern "C" JNIEXPORT jstring JNICALL
Java_icu_ringona_musereader_NativeMuseScoreEngine_lastErrorNative(
    JNIEnv* env,
    jclass /* clazz */) {
  const char* error = muse_reader_last_error();
  if (error == nullptr || error[0] == '\0') return nullptr;
  return env->NewStringUTF(error);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_icu_ringona_musereader_NativeMuseScoreEngine_audioIsAvailableNative(
    JNIEnv* /* env */,
    jclass /* clazz */) {
  return muse_reader_audio_is_available() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_icu_ringona_musereader_NativeMuseScoreEngine_audioInitializeNative(
    JNIEnv* /* env */,
    jclass /* clazz */) {
  return muse_reader_audio_initialize() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_icu_ringona_musereader_NativeMuseScoreEngine_audioStartNative(
    JNIEnv* env,
    jclass /* clazz */,
    jstring events_json,
    jlong position_us,
    jdouble speed) {
  if (events_json == nullptr) return JNI_FALSE;
  const char* utf8_json = env->GetStringUTFChars(events_json, nullptr);
  if (utf8_json == nullptr) return JNI_FALSE;
  const int result = muse_reader_audio_start_json(
      utf8_json, static_cast<int64_t>(position_us), static_cast<double>(speed));
  env->ReleaseStringUTFChars(events_json, utf8_json);
  return result ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_icu_ringona_musereader_NativeMuseScoreEngine_audioRenderNative(
    JNIEnv* env,
    jclass /* clazz */,
    jfloatArray output) {
  if (output == nullptr) return 0;
  const jsize sample_count = env->GetArrayLength(output);
  if (sample_count < 2) return 0;
  jboolean copied = JNI_FALSE;
  jfloat* samples = env->GetFloatArrayElements(output, &copied);
  if (samples == nullptr) return 0;
  const size_t frames = static_cast<size_t>(sample_count / 2);
  const size_t rendered = muse_reader_audio_render(samples, frames);
  env->ReleaseFloatArrayElements(output, samples, 0);
  return static_cast<jint>(std::min<size_t>(rendered, static_cast<size_t>(INT_MAX)));
}

extern "C" JNIEXPORT jboolean JNICALL
Java_icu_ringona_musereader_NativeMuseScoreEngine_audioIsActiveNative(
    JNIEnv* /* env */,
    jclass /* clazz */) {
  return muse_reader_audio_is_active() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_icu_ringona_musereader_NativeMuseScoreEngine_audioStopNative(
    JNIEnv* /* env */,
    jclass /* clazz */) {
  muse_reader_audio_stop();
}

extern "C" JNIEXPORT jint JNICALL
Java_icu_ringona_musereader_NativeMuseScoreEngine_audioSampleRateNative(
    JNIEnv* /* env */,
    jclass /* clazz */) {
  return muse_reader_audio_sample_rate();
}

extern "C" JNIEXPORT jstring JNICALL
Java_icu_ringona_musereader_NativeMuseScoreEngine_audioLastErrorNative(
    JNIEnv* env,
    jclass /* clazz */) {
  const char* error = muse_reader_audio_last_error();
  if (error == nullptr || error[0] == '\0') return nullptr;
  return env->NewStringUTF(error);
}
