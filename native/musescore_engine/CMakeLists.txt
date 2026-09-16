cmake_minimum_required(VERSION 3.18)

project(muse_reader_engine LANGUAGES C CXX)

option(
  MUSE_READER_WITH_MUSESCORE
  "Link the MuseScore 3.6.2 libmscore implementation"
  OFF
)
option(
  MUSE_READER_BUILD_MUSESCORE_SOURCE
  "Cross-compile the MuseScore reader core from MUSESCORE_SOURCE_DIR"
  OFF
)
option(
  MUSE_READER_BUILD_IOS_FRAMEWORK
  "Build the complete iOS reader runtime as an embeddable framework"
  OFF
)
option(
  MUSE_READER_WITH_FLUIDSYNTH
  "Build the MuseScore FluidSynth renderer and bundled SF3 soundfont"
  ON
)

if(MUSE_READER_BUILD_MUSESCORE_SOURCE)
  set(MUSE_READER_WITH_MUSESCORE ON)
endif()

if(NOT DEFINED MUSE_READER_ENGINE_TARGET)
  set(MUSE_READER_ENGINE_TARGET muse_reader_engine)
endif()

set(_muse_reader_library_type STATIC)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND MUSE_READER_BUILD_IOS_FRAMEWORK)
  set(_muse_reader_library_type SHARED)
endif()

add_library(
  ${MUSE_READER_ENGINE_TARGET}
  ${_muse_reader_library_type}
  muse_reader_engine.cpp
  muse_reader_audio.cpp
)
target_compile_features(${MUSE_READER_ENGINE_TARGET} PUBLIC cxx_std_17)
set_target_properties(
  ${MUSE_READER_ENGINE_TARGET}
  PROPERTIES POSITION_INDEPENDENT_CODE ON
)
target_include_directories(
  ${MUSE_READER_ENGINE_TARGET}
  PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}"
)

if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND MUSE_READER_BUILD_IOS_FRAMEWORK)
  set_target_properties(${MUSE_READER_ENGINE_TARGET} PROPERTIES
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    MACOSX_FRAMEWORK_BUNDLE_NAME "MuseReaderEngine"
    MACOSX_FRAMEWORK_BUNDLE_VERSION "1"
    MACOSX_FRAMEWORK_IDENTIFIER "com.musereader.engine"
    MACOSX_FRAMEWORK_SHORT_VERSION_STRING "1.0.0"
    OUTPUT_NAME MuseReaderEngine
    PUBLIC_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/muse_reader_engine.h"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
    XCODE_ATTRIBUTE_INSTALL_PATH "@rpath"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.musereader.engine"
  )
endif()

if(MUSE_READER_WITH_MUSESCORE)
  if(NOT MUSESCORE_SOURCE_DIR)
    message(FATAL_ERROR "Set MUSESCORE_SOURCE_DIR to the MuseScore-3.6.2 checkout")
  endif()

  # Qt's 5.15 package files are shipped with absolute module paths.  When a
  # cross-compiling sysroot is active, newer CMake releases prepend that
  # sysroot to those already-absolute paths and report Qt5Core (and friends)
  # as missing.  The Qt kit is explicitly selected below, so package lookup
  # must stay outside the target sysroot; library lookup still follows the
  # normal platform toolchain rules.
  if(ANDROID OR CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE NEVER)
  endif()

  if(MUSE_READER_BUILD_MUSESCORE_SOURCE)
    find_package(Qt5 5.15 REQUIRED COMPONENTS Core Gui Widgets Xml Svg)
    find_package(ZLIB REQUIRED)
    set(QT_VERSION_MAJOR 5)
    set(MUSESCORE_BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}")
  else()
    if(NOT MUSESCORE_LIBRARIES)
      message(FATAL_ERROR "Set MUSESCORE_LIBRARIES to the built libmscore and its dependencies")
    endif()
    if(NOT MUSESCORE_BUILD_DIR)
      message(FATAL_ERROR "Set MUSESCORE_BUILD_DIR to the matching MuseScore build directory")
    endif()

    find_package(QT NAMES Qt5 Qt6 REQUIRED COMPONENTS Core Gui Xml Svg Widgets)
  endif()

  if(QT_VERSION_MAJOR EQUAL 5)
    if(NOT MUSE_READER_BUILD_MUSESCORE_SOURCE)
      find_package(Qt5 REQUIRED COMPONENTS
        Core Gui Network Test Qml Quick QuickControls2 QuickTemplates2
        QuickWidgets Xml XmlPatterns Svg Sql PrintSupport Concurrent OpenGL
        Help Widgets
      )
    endif()
  else()
    find_package(Qt6 REQUIRED COMPONENTS Core Gui Xml Svg Widgets)
  endif()
  if(QT_VERSION_MAJOR EQUAL 6)
    find_package(Qt6 REQUIRED COMPONENTS Core5Compat)
  endif()

  target_compile_definitions(${MUSE_READER_ENGINE_TARGET} PRIVATE MUSE_READER_WITH_MUSESCORE=1)
  target_compile_options(${MUSE_READER_ENGINE_TARGET} PRIVATE
    -Wno-inconsistent-missing-override
    -Wno-deprecated-register
  )
  target_include_directories(${MUSE_READER_ENGINE_TARGET} PRIVATE
    "${MUSESCORE_BUILD_DIR}"
    "${MUSESCORE_SOURCE_DIR}/libmscore"
    "${MUSESCORE_SOURCE_DIR}"
    "${MUSESCORE_SOURCE_DIR}/audio/midi"
    "${MUSESCORE_SOURCE_DIR}/audio"
    "${MUSESCORE_SOURCE_DIR}/mscore"
    "${MUSESCORE_SOURCE_DIR}/thirdparty"
    "${MUSESCORE_SOURCE_DIR}/thirdparty/freetype/include"
    "${MUSESCORE_SOURCE_DIR}/global"
  )

  if(MUSE_READER_BUILD_MUSESCORE_SOURCE)
    target_compile_definitions(
      ${MUSE_READER_ENGINE_TARGET}
      PRIVATE MUSE_READER_BUILD_MUSESCORE_SOURCE=1
    )
    if(MUSE_READER_WITH_FLUIDSYNTH)
      target_compile_definitions(
        ${MUSE_READER_ENGINE_TARGET}
        PRIVATE MUSE_READER_WITH_FLUIDSYNTH=1
      )
    endif()
    set(MUSESCORE_NAME_VERSION "MuseScore 3")
    set(MUSESCORE_VERSION_FULL "3.6.2")
    set(MUSESCORE_VERSION_LABEL "Release")
    set(Mscore_INSTALL_NAME "")
    set(CMAKE_BUILD_NUMBER "")
    set(CRASHREPORTER_EXECUTABLE "")
    set(CRASH_REPORT_URL "")
    set(TELEMETRY_TRACK_ID "")
    set(HAS_MIDI ON)
    set(USE_SSE OFF)
    set(SCRIPT_INTERFACE OFF)
    set(BUILD_TELEMETRY_MODULE OFF)
    set(ZERBERUS OFF)
    set(OSC OFF)
    set(MUSE_READER_SOUNDFONT_PATH
        "${CMAKE_CURRENT_LIST_DIR}/../../assets/sound/MS Basic.sf3"
        CACHE FILEPATH "MuseScore SF3 resource embedded in the engine")
    if(NOT EXISTS "${MUSE_READER_SOUNDFONT_PATH}")
      message(FATAL_ERROR
        "MuseScore soundfont not found: ${MUSE_READER_SOUNDFONT_PATH}")
    endif()
    if(MUSE_READER_WITH_FLUIDSYNTH)
      set(SOUNDFONT3 ON)
    else()
      set(SOUNDFONT3 OFF)
    endif()

    configure_file(
      "${MUSESCORE_SOURCE_DIR}/build/config.h.in"
      "${MUSESCORE_BUILD_DIR}/config.h"
    )
    configure_file(
      "${CMAKE_CURRENT_SOURCE_DIR}/muse_reader_resources.qrc.in"
      "${MUSESCORE_BUILD_DIR}/muse_reader_resources.qrc"
      @ONLY
    )
    qt5_add_resources(
      MUSE_READER_RESOURCE_SOURCES
      "${MUSESCORE_BUILD_DIR}/muse_reader_resources.qrc"
    )
    # The generated qrc source embeds the SoundFont as huge string literals
    # (hundreds of MB of source). Optimizing it at the global -O3 release
    # level exhausted the RAM of small build hosts; an unoptimized compile is
    # a fraction of the cost and the data arrays need no optimization.
    foreach(_qrc_source ${MUSE_READER_RESOURCE_SOURCES})
      set_source_files_properties(
        "${_qrc_source}"
        PROPERTIES COMPILE_OPTIONS "-O0;-g0"
      )
    endforeach()

    if(NOT TARGET mops1)
      add_custom_target(mops1)
    endif()
    if(NOT TARGET mops2)
      add_custom_target(mops2)
    endif()
    if(NOT COMMAND xcode_pch)
      function(xcode_pch)
      endfunction()
    endif()
    if(NOT COMMAND vstudio_pch)
      function(vstudio_pch)
      endfunction()
    endif()

    set(PCH "")
    set(PCH_INCLUDE "-include ${CMAKE_CURRENT_SOURCE_DIR}/mobile_all.h")
    set(_muse_reader_project_source_dir "${PROJECT_SOURCE_DIR}")
    set(_muse_reader_msvc "${MSVC}")
    set(PROJECT_SOURCE_DIR "${MUSESCORE_SOURCE_DIR}")

    # The upstream files copy their desktop all.h unless MSVC is set. The
    # reader supplies a smaller forced include with only the Qt modules used
    # by libmscore, so temporarily take the no-copy branch.
    set(MSVC TRUE)
    add_subdirectory(
      "${MUSESCORE_SOURCE_DIR}/libmscore"
      "${MUSESCORE_BUILD_DIR}/musescore/libmscore"
    )
    add_subdirectory(
      "${MUSESCORE_SOURCE_DIR}/thirdparty/qzip"
      "${MUSESCORE_BUILD_DIR}/musescore/qzip"
    )
    set(MSVC "${_muse_reader_msvc}")
    add_subdirectory(
      "${MUSESCORE_SOURCE_DIR}/thirdparty/freetype"
      "${MUSESCORE_BUILD_DIR}/musescore/freetype"
    )
    set(PROJECT_SOURCE_DIR "${_muse_reader_project_source_dir}")

    set_target_properties(
      libmscore qzip mscore_freetype
      PROPERTIES POSITION_INDEPENDENT_CODE ON
    )
    set_target_properties(libmscore PROPERTIES AUTOMOC ON)
    target_compile_features(libmscore PRIVATE cxx_std_11)
    target_compile_options(libmscore PRIVATE
      -Wno-inconsistent-missing-override
      -Wno-deprecated-register
    )
    target_include_directories(libmscore PRIVATE
      "${MUSESCORE_BUILD_DIR}"
      "${MUSESCORE_SOURCE_DIR}"
      "${MUSESCORE_SOURCE_DIR}/libmscore"
      "${MUSESCORE_SOURCE_DIR}/global"
      "${MUSESCORE_SOURCE_DIR}/audio"
      "${MUSESCORE_SOURCE_DIR}/audio/midi"
      "${MUSESCORE_SOURCE_DIR}/thirdparty"
      "${MUSESCORE_SOURCE_DIR}/thirdparty/freetype/include"
    )
    target_link_libraries(libmscore PUBLIC
      Qt5::Core Qt5::Gui Qt5::Widgets Qt5::Xml Qt5::Svg
    )
    target_include_directories(qzip PRIVATE
      "${MUSESCORE_BUILD_DIR}"
      "${MUSESCORE_SOURCE_DIR}"
    )
    target_link_libraries(qzip PUBLIC
      Qt5::Core Qt5::Gui Qt5::Widgets Qt5::Xml Qt5::Svg ZLIB::ZLIB
    )

    target_sources(${MUSE_READER_ENGINE_TARGET} PRIVATE
      "${MUSESCORE_SOURCE_DIR}/audio/midi/event.cpp"
      "${CMAKE_CURRENT_SOURCE_DIR}/muse_reader_musescore_support.cpp"
      ${MUSE_READER_RESOURCE_SOURCES}
    )
    if(MUSE_READER_WITH_FLUIDSYNTH)
      target_sources(${MUSE_READER_ENGINE_TARGET} PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/fluid/fluid.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/fluid/chan.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/fluid/conv.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/fluid/dsp.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/fluid/fluid_headless.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/fluid/gen.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/fluid/mod.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/fluid/sfont.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/fluid/sfont3.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/fluid/voice.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/third_party/stb_vorbis.c"
      )
      # The target supplies a forced C++ Qt include for MuseScore sources.
      # stb_vorbis is C-compatible, so compiling it as C++ keeps the same
      # include boundary while retaining its C ABI declarations.
      set_source_files_properties(
        "${CMAKE_CURRENT_SOURCE_DIR}/third_party/stb_vorbis.c"
        PROPERTIES LANGUAGE CXX COMPILE_DEFINITIONS STB_VORBIS_NO_STDIO=1
      )
      target_include_directories(${MUSE_READER_ENGINE_TARGET} PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/fluid"
      )
    endif()
    target_compile_options(${MUSE_READER_ENGINE_TARGET} PRIVATE
      "-include" "${CMAKE_CURRENT_SOURCE_DIR}/mobile_all.h"
    )
    target_link_libraries(${MUSE_READER_ENGINE_TARGET} PRIVATE
      libmscore
      qzip
      mscore_freetype
      ZLIB::ZLIB
      Qt5::Core
      Qt5::Gui
      Qt5::Widgets
      Qt5::Xml
      Qt5::Svg
    )

    if(ANDROID)
      if(NOT MUSE_READER_QTBASE_SOURCE_DIR)
        message(FATAL_ERROR "Set MUSE_READER_QTBASE_SOURCE_DIR for the Android minimal QPA plugin")
      endif()
      find_package(Qt5EventDispatcherSupport 5.15 REQUIRED CONFIG)
      find_package(Qt5FontDatabaseSupport 5.15 REQUIRED CONFIG)
      add_library(muse_reader_qminimal STATIC
        "${MUSE_READER_QTBASE_SOURCE_DIR}/src/plugins/platforms/minimal/main.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/muse_reader_qminimal_integration.cpp"
        "${MUSE_READER_QTBASE_SOURCE_DIR}/src/plugins/platforms/minimal/qminimalbackingstore.cpp"
        # The minimal plugin is used instead of Qt's Android QPA, but its
        # font database still needs to enumerate Android's /system/fonts so
        # CJK text can fall back to the device's Noto Sans CJK faces.
        "${MUSE_READER_QTBASE_SOURCE_DIR}/src/plugins/platforms/android/qandroidplatformfontdatabase.cpp"
      )
      set_target_properties(muse_reader_qminimal PROPERTIES
        AUTOMOC ON
        POSITION_INDEPENDENT_CODE ON
      )
      target_compile_definitions(muse_reader_qminimal PRIVATE QT_STATICPLUGIN)
      target_include_directories(muse_reader_qminimal PRIVATE
        "${MUSESCORE_SOURCE_DIR}/thirdparty/freetype/include"
        "${MUSE_READER_QTBASE_SOURCE_DIR}/src/plugins/platforms/minimal"
        "${MUSE_READER_QTBASE_SOURCE_DIR}/src/plugins/platforms/android"
      )
      target_link_libraries(muse_reader_qminimal PRIVATE
        Qt5::CorePrivate
        Qt5::GuiPrivate
        Qt5::EventDispatcherSupportPrivate
        Qt5::FontDatabaseSupportPrivate
      )
      target_sources(${MUSE_READER_ENGINE_TARGET} PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/muse_reader_qminimal_import.cpp"
      )
      target_link_libraries(${MUSE_READER_ENGINE_TARGET} PRIVATE muse_reader_qminimal)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS")
      if(NOT TARGET Qt5::QMinimalIntegrationPlugin)
        message(FATAL_ERROR "The Qt iOS kit does not provide QMinimalIntegrationPlugin")
      endif()
      qt5_import_plugins(
        ${MUSE_READER_ENGINE_TARGET}
        INCLUDE_BY_TYPE platforms Qt5::QMinimalIntegrationPlugin
        EXCLUDE_BY_TYPE imageformats
      )
      target_link_libraries(
        ${MUSE_READER_ENGINE_TARGET}
        PRIVATE Qt5::QMinimalIntegrationPlugin
      )
    endif()
  else()
    target_link_libraries(${MUSE_READER_ENGINE_TARGET} PRIVATE
      ${MUSESCORE_LIBRARIES}
      Qt${QT_VERSION_MAJOR}::Core
      Qt${QT_VERSION_MAJOR}::Gui
      Qt${QT_VERSION_MAJOR}::Xml
      Qt${QT_VERSION_MAJOR}::Svg
      Qt${QT_VERSION_MAJOR}::Widgets
    )
  endif()

  if(QT_VERSION_MAJOR EQUAL 5 AND NOT MUSE_READER_BUILD_MUSESCORE_SOURCE)
    target_link_libraries(${MUSE_READER_ENGINE_TARGET} PRIVATE
      Qt5::Network
      Qt5::Test
      Qt5::Qml
      Qt5::Quick
      Qt5::QuickControls2
      Qt5::QuickTemplates2
      Qt5::QuickWidgets
      Qt5::XmlPatterns
      Qt5::Sql
      Qt5::PrintSupport
      Qt5::Concurrent
      Qt5::OpenGL
      Qt5::Help
    )
  endif()
  if(QT_VERSION_MAJOR EQUAL 6)
    target_link_libraries(${MUSE_READER_ENGINE_TARGET} PRIVATE Qt6::Core5Compat)
  endif()
endif()
