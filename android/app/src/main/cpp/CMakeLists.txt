cmake_minimum_required(VERSION 3.18)

project(muse_reader_android_engine LANGUAGES CXX)

set(MUSE_READER_ENGINE_DIR
    "${CMAKE_CURRENT_LIST_DIR}/../../../../../native/musescore_engine")

# Reuse the desktop/native adapter's dependency wiring. The JNI target below
# remains a thin shared-library shell around this static core.
set(MUSE_READER_ENGINE_TARGET muse_reader_engine_core CACHE STRING "" FORCE)
add_subdirectory(
  "${MUSE_READER_ENGINE_DIR}"
  "${CMAKE_CURRENT_BINARY_DIR}/muse_reader_engine_core"
)

add_library(
  muse_reader_engine
  SHARED
  muse_reader_engine_jni.cpp
)

target_compile_features(muse_reader_engine PRIVATE cxx_std_17)
target_link_libraries(muse_reader_engine PRIVATE muse_reader_engine_core)

# Gradle always enables the source-built MuseScore core for the arm64 product
# artifact. Keeping the JNI shell separate makes the Flutter channel stable.
