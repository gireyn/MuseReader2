#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${PROJECT_ROOT}/build"
MUSESCORE_SOURCE_DIR="${MUSESCORE_SOURCE_DIR:-${PROJECT_ROOT}/../MuseScore-3.6.2}"
TARGET="${1:-all}"

QT_VERSION="5.15.2"
QT_ANDROID_VERSION="5.15.2-0-202011130624"
QT_IOS_VERSION="5.15.2-0-202011130625"
ANDROID_NDK_VERSION="28.2.13676358"

DOWNLOAD_DIR="${BUILD_ROOT}/toolchains/downloads"
TOOLCHAIN_DIR="${BUILD_ROOT}/toolchains"
QT_ANDROID_ROOT="${TOOLCHAIN_DIR}/qt/android/${QT_VERSION}/android"
QT_IOS_ROOT="${TOOLCHAIN_DIR}/qt/ios/${QT_VERSION}/ios"
QTBASE_SOURCE_ROOT="${TOOLCHAIN_DIR}/src/qtbase-everywhere-src-${QT_VERSION}"
IOS_NATIVE_BUILD_DIR="${BUILD_ROOT}/native-ios-arm64"
RELEASE_DIR="${BUILD_ROOT}/releases"
SOUNDFONT_PATH="${PROJECT_ROOT}/assets/sound/MS Basic.sf3"
SOUNDFONT_SHA256="5ea2375e8bd7d8e71def1036978c1621e85b66934169b6a2744b27b9b3c2d99c"

ANDROID_QTBASE_ARCHIVE="${DOWNLOAD_DIR}/android-qtbase.7z"
ANDROID_QTSVG_ARCHIVE="${DOWNLOAD_DIR}/android-qtsvg.7z"
IOS_QTBASE_ARCHIVE="${DOWNLOAD_DIR}/ios-qtbase.7z"
IOS_QTSVG_ARCHIVE="${DOWNLOAD_DIR}/ios-qtsvg.7z"
QTBASE_SOURCE_ARCHIVE="${DOWNLOAD_DIR}/qtbase-everywhere-src-${QT_VERSION}.tar.xz"

ANDROID_QTBASE_URL="https://download.qt.io/online/qtsdkrepository/mac_x64/android/qt5_5152/qt.qt5.5152.android/${QT_ANDROID_VERSION}qtbase-MacOS-MacOS_10_13-Clang-Android-Android_ANY-Multi.7z"
ANDROID_QTSVG_URL="https://download.qt.io/online/qtsdkrepository/mac_x64/android/qt5_5152/qt.qt5.5152.android/${QT_ANDROID_VERSION}qtsvg-MacOS-MacOS_10_13-Clang-Android-Android_ANY-Multi.7z"
IOS_QTBASE_URL="https://download.qt.io/online/qtsdkrepository/mac_x64/ios/qt5_5152/qt.qt5.5152.ios/${QT_IOS_VERSION}qtbase-MacOS-MacOS_10_14-Clang-IOS-IOS_ANY-Multi.7z"
IOS_QTSVG_URL="https://download.qt.io/online/qtsdkrepository/mac_x64/ios/qt5_5152/qt.qt5.5152.ios/${QT_IOS_VERSION}qtsvg-MacOS-MacOS_10_14-Clang-IOS-IOS_ANY-Multi.7z"
QTBASE_SOURCE_URL="https://download.qt.io/archive/qt/5.15/${QT_VERSION}/submodules/qtbase-everywhere-src-${QT_VERSION}.tar.xz"

log() {
  printf '[MuseReader] %s\n' "$*"
}

die() {
  printf '[MuseReader] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

android_sdk_root() {
  local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"

  if [[ -z "${sdk_root}" && -f "${PROJECT_ROOT}/android/local.properties" ]]; then
    sdk_root="$(sed -n 's/^sdk\.dir=//p' "${PROJECT_ROOT}/android/local.properties" | tail -n 1)"
  fi
  [[ -d "${sdk_root}" ]] || die "Set ANDROID_SDK_ROOT to an installed Android SDK"
  printf '%s\n' "${sdk_root}"
}

android_build_tool() {
  local tool_name="$1"
  local sdk_root
  local candidate
  local selected=""

  sdk_root="$(android_sdk_root)"
  for candidate in "${sdk_root}"/build-tools/*/"${tool_name}"; do
    if [[ -x "${candidate}" ]]; then
      selected="${candidate}"
    fi
  done
  [[ -n "${selected}" ]] || die "Android build tool not found: ${tool_name}"
  printf '%s\n' "${selected}"
}

android_readelf() {
  local sdk_root
  local candidate

  sdk_root="$(android_sdk_root)"
  for candidate in \
    "${sdk_root}/ndk/${ANDROID_NDK_VERSION}"/toolchains/llvm/prebuilt/*/bin/llvm-readelf
  do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
  die "llvm-readelf not found in Android NDK ${ANDROID_NDK_VERSION}"
}

verify_checksum() {
  local algorithm="$1"
  local expected="$2"
  local path="$3"
  local actual

  actual="$(shasum -a "${algorithm}" "${path}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] ||
    die "Checksum mismatch for ${path}: expected ${expected}, got ${actual}"
}

download() {
  local url="$1"
  local destination="$2"
  local algorithm="$3"
  local checksum="$4"
  local partial="${destination}.part"

  if [[ -f "${destination}" ]]; then
    verify_checksum "${algorithm}" "${checksum}" "${destination}"
    return
  fi

  log "Downloading $(basename "${destination}")"
  curl --fail --location --retry 3 --continue-at - \
    --output "${partial}" "${url}"
  verify_checksum "${algorithm}" "${checksum}" "${partial}"
  mv "${partial}" "${destination}"
}

extract_if_missing() {
  local archive="$1"
  local destination="$2"
  local marker="$3"

  if [[ ! -e "${marker}" ]]; then
    log "Extracting $(basename "${archive}")"
    mkdir -p "${destination}"
    bsdtar -xf "${archive}" -C "${destination}"
  fi
  [[ -e "${marker}" ]] || die "Toolchain marker was not created: ${marker}"
}

prepare_android_toolchain() {
  mkdir -p "${DOWNLOAD_DIR}" "${TOOLCHAIN_DIR}/qt/android" "${TOOLCHAIN_DIR}/src"
  download "${ANDROID_QTBASE_URL}" "${ANDROID_QTBASE_ARCHIVE}" 1 \
    f950fb0350e7dd6a08ecbf974a3322baa1a5657a
  download "${ANDROID_QTSVG_URL}" "${ANDROID_QTSVG_ARCHIVE}" 1 \
    2c299d51036c2a4e34367d65b98d7a827157438e
  download "${QTBASE_SOURCE_URL}" "${QTBASE_SOURCE_ARCHIVE}" 256 \
    909fad2591ee367993a75d7e2ea50ad4db332f05e1c38dd7a5a274e156a4e0f8

  extract_if_missing "${ANDROID_QTBASE_ARCHIVE}" "${TOOLCHAIN_DIR}/qt/android" \
    "${QT_ANDROID_ROOT}/lib/cmake/Qt5/Qt5Config.cmake"
  extract_if_missing "${ANDROID_QTSVG_ARCHIVE}" "${TOOLCHAIN_DIR}/qt/android" \
    "${QT_ANDROID_ROOT}/lib/cmake/Qt5Svg/Qt5SvgConfig.cmake"
  extract_if_missing "${QTBASE_SOURCE_ARCHIVE}" "${TOOLCHAIN_DIR}/src" \
    "${QTBASE_SOURCE_ROOT}/src/plugins/platforms/minimal/main.cpp"

  # The Android Qt shared libraries call into QtNative from JNI_OnLoad. Keep
  # the matching runtime jar in the toolchain; Gradle packages it explicitly
  # because this Flutter host does not run androiddeployqt/QtActivity.
  [[ -f "${QT_ANDROID_ROOT}/jar/QtAndroid.jar" ]] ||
    die "Qt Android runtime jar not found: ${QT_ANDROID_ROOT}/jar/QtAndroid.jar"
}

prepare_ios_toolchain() {
  mkdir -p "${DOWNLOAD_DIR}" "${TOOLCHAIN_DIR}/qt/ios"
  download "${IOS_QTBASE_URL}" "${IOS_QTBASE_ARCHIVE}" 1 \
    47e3c0bf3622acb076fd53039d6d9dfe9bc525d1
  download "${IOS_QTSVG_URL}" "${IOS_QTSVG_ARCHIVE}" 1 \
    f71e99d0c75783af0c87e5b9a289eb6f6e04875a

  extract_if_missing "${IOS_QTBASE_ARCHIVE}" "${TOOLCHAIN_DIR}/qt/ios" \
    "${QT_IOS_ROOT}/lib/cmake/Qt5/Qt5Config.cmake"
  extract_if_missing "${IOS_QTSVG_ARCHIVE}" "${TOOLCHAIN_DIR}/qt/ios" \
    "${QT_IOS_ROOT}/lib/cmake/Qt5Svg/Qt5SvgConfig.cmake"
}

build_android() {
  prepare_android_toolchain
  log "Building Android release for arm64-v8a"
  (
    cd "${PROJECT_ROOT}"
    ORG_GRADLE_PROJECT_museScoreSourceDir="${MUSESCORE_SOURCE_DIR}" \
    ORG_GRADLE_PROJECT_museReaderQtDir="${QT_ANDROID_ROOT}" \
    ORG_GRADLE_PROJECT_museReaderQtBaseSourceDir="${QTBASE_SOURCE_ROOT}" \
      flutter build apk --release \
        --target-platform android-arm64 \
        --dart-define=MUSE_READER_REQUIRE_NATIVE=true
  )

  mkdir -p "${RELEASE_DIR}"
  cp "${BUILD_ROOT}/app/outputs/flutter-apk/app-release.apk" \
    "${RELEASE_DIR}/MuseReader-android-arm64-release.apk"
}

replace_ios_framework() {
  local source_framework="$1"
  local destination_dir="${PROJECT_ROOT}/ios/Frameworks"
  local destination_framework="${destination_dir}/MuseReaderEngine.framework"
  local staging_dir

  [[ -d "${source_framework}" ]] || die "iOS framework was not built: ${source_framework}"
  mkdir -p "${destination_dir}"
  staging_dir="$(mktemp -d "${destination_dir}/.muse-reader-framework.XXXXXX")"
  ditto "${source_framework}" "${staging_dir}/MuseReaderEngine.framework"
  rm -rf "${destination_framework}"
  mv "${staging_dir}/MuseReaderEngine.framework" "${destination_framework}"
  rmdir "${staging_dir}"
}

package_unsigned_ios_app() {
  local app_path="${BUILD_ROOT}/ios/iphoneos/Runner.app"
  local package_root="${BUILD_ROOT}/ios/unsigned-package"
  local ipa_path="${RELEASE_DIR}/MuseReader-ios-arm64-unsigned.ipa"

  [[ -d "${app_path}" ]] || die "iOS app was not built: ${app_path}"
  mkdir -p "${package_root}" "${RELEASE_DIR}"
  rm -rf "${package_root}/Payload"
  mkdir -p "${package_root}/Payload"
  ditto "${app_path}" "${package_root}/Payload/Runner.app"
  rm -f "${ipa_path}"
  (
    cd "${package_root}"
    zip -qry "${ipa_path}" Payload
  )
}

build_ios() {
  local jobs
  local framework_path

  prepare_ios_toolchain
  jobs="$(sysctl -n hw.ncpu)"
  log "Building MuseReaderEngine.framework for iphoneos/arm64"
  cmake -S "${PROJECT_ROOT}/native/musescore_engine" \
    -B "${IOS_NATIVE_BUILD_DIR}" \
    -G Xcode \
    -DMUSE_READER_BUILD_MUSESCORE_SOURCE=ON \
    -DMUSE_READER_BUILD_IOS_FRAMEWORK=ON \
    -DMUSE_READER_WITH_FLUIDSYNTH=ON \
    -DMUSE_READER_SOUNDFONT_PATH="${SOUNDFONT_PATH}" \
    -DMUSESCORE_SOURCE_DIR="${MUSESCORE_SOURCE_DIR}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=NEVER \
    -DCMAKE_PREFIX_PATH="${QT_IOS_ROOT}" \
    -DQt5_DIR="${QT_IOS_ROOT}/lib/cmake/Qt5" \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "${IOS_NATIVE_BUILD_DIR}" \
    --config Release --target muse_reader_engine --parallel "${jobs}"

  framework_path="${IOS_NATIVE_BUILD_DIR}/Release-iphoneos/MuseReaderEngine.framework"
  replace_ios_framework "${framework_path}"

  log "Building unsigned iOS release for iphoneos/arm64"
  (
    cd "${PROJECT_ROOT}"
    flutter build ios --release --no-codesign \
      --dart-define=MUSE_READER_REQUIRE_NATIVE=true
  )
  package_unsigned_ios_app
}

verify_android() {
  local apk="${RELEASE_DIR}/MuseReader-android-arm64-release.apk"
  local abis
  local audit_dir
  local dependency
  local library
  local package_entries
  local readelf

  [[ -f "${apk}" ]] || die "Android APK not found: ${apk}"
  package_entries="$(unzip -Z1 "${apk}")"
  abis="$(printf '%s\n' "${package_entries}" | sed -n 's#^lib/\([^/]*\)/.*#\1#p' | sort -u)"
  [[ "${abis}" == "arm64-v8a" ]] || die "Unexpected Android ABIs: ${abis}"
  for library in \
    libmuse_reader_engine.so libc++_shared.so \
    libQt5Core_arm64-v8a.so libQt5Gui_arm64-v8a.so \
    libQt5Widgets_arm64-v8a.so libQt5Xml_arm64-v8a.so \
    libQt5Svg_arm64-v8a.so
  do
    grep -qx "lib/arm64-v8a/${library}" <<<"${package_entries}" ||
      die "Android package is missing lib/arm64-v8a/${library}"
  done

  readelf="$(android_readelf)"
  audit_dir="$(mktemp -d "${TMPDIR:-/tmp}/muse-reader-elf.XXXXXX")"
  unzip -qq "${apk}" 'lib/arm64-v8a/*' -d "${audit_dir}"
  for library in "${audit_dir}"/lib/arm64-v8a/*.so; do
    while IFS= read -r dependency; do
      case "${dependency}" in
        libandroid.so|libc.so|libdl.so|libEGL.so|libGLESv2.so|libjnigraphics.so|liblog.so|libm.so|libmediandk.so|libnativewindow.so|libOpenSLES.so|libvulkan.so|libz.so)
          ;;
        *)
          grep -qx "lib/arm64-v8a/${dependency}" <<<"${package_entries}" ||
            die "Unresolved Android dependency: $(basename "${library}") -> ${dependency}"
          ;;
      esac
    done < <("${readelf}" -d "${library}" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
  done
  rm -rf "${audit_dir}"

  "$(android_build_tool zipalign)" -c -P 16 -v 4 "${apk}" >/dev/null
  "$(android_build_tool apksigner)" verify "${apk}"
  log "Verified Android package: arm64-v8a, ELF closure, 16 KB alignment, and signature"
}

verify_ios() {
  local ipa="${RELEASE_DIR}/MuseReader-ios-arm64-unsigned.ipa"
  local audit_dir
  local app
  local framework
  local binary
  local architectures
  local dependency
  local symbols

  [[ -f "${ipa}" ]] || die "iOS IPA not found: ${ipa}"
  audit_dir="$(mktemp -d "${TMPDIR:-/tmp}/muse-reader-ipa.XXXXXX")"
  unzip -qq "${ipa}" -d "${audit_dir}"
  app="${audit_dir}/Payload/Runner.app"
  framework="${app}/Frameworks/MuseReaderEngine.framework/MuseReaderEngine"
  [[ -d "${app}" ]] || die "IPA does not contain Payload/Runner.app"
  for binary in \
    "${app}/Runner" \
    "${app}/Frameworks/App.framework/App" \
    "${app}/Frameworks/Flutter.framework/Flutter" \
    "${framework}"
  do
    [[ -f "${binary}" ]] || die "iOS package is missing ${binary}"
    architectures="$(lipo -archs "${binary}")"
    [[ "${architectures}" == "arm64" ]] ||
      die "Unexpected architecture in ${binary}: ${architectures}"
    while IFS= read -r dependency; do
      case "${dependency}" in
        /System/Library/*|/usr/lib/*)
          ;;
        @rpath/*)
          [[ -f "${app}/Frameworks/${dependency#@rpath/}" ]] ||
            die "Unresolved iOS dependency: $(basename "${binary}") -> ${dependency}"
          ;;
        *)
          die "Unexpected iOS dependency: $(basename "${binary}") -> ${dependency}"
          ;;
      esac
    done < <(otool -L "${binary}" | tail -n +2 | awk '{print $1}')
  done
  symbols="$(nm -gU "${framework}")"
  grep -q '_muse_reader_open_json' <<<"${symbols}" ||
    die "MuseReaderEngine does not export muse_reader_open_json"
  grep -q '_muse_reader_free_json' <<<"${symbols}" ||
    die "MuseReaderEngine does not export muse_reader_free_json"
  for symbol in \
    muse_reader_audio_is_available \
    muse_reader_audio_initialize \
    muse_reader_audio_start_json \
    muse_reader_audio_render \
    muse_reader_audio_is_active \
    muse_reader_audio_stop \
    muse_reader_audio_sample_rate \
    muse_reader_audio_last_error
  do
    grep -q "_${symbol}" <<<"${symbols}" ||
      die "MuseReaderEngine does not export ${symbol}"
  done
  rm -rf "${audit_dir}"
  log "Verified iOS package: iphoneos/arm64 and complete Mach-O dependency closure"
}

verify_artifacts() {
  verify_android
  verify_ios
  shasum -a 256 \
    "${RELEASE_DIR}/MuseReader-android-arm64-release.apk" \
    "${RELEASE_DIR}/MuseReader-ios-arm64-unsigned.ipa"
}

case "${TARGET}" in
  all|android|ios)
    require_command curl
    require_command bsdtar
    require_command shasum
    require_command flutter
    require_command unzip
    [[ -f "${MUSESCORE_SOURCE_DIR}/libmscore/CMakeLists.txt" ]] ||
      die "MuseScore 3.6.2 source not found at ${MUSESCORE_SOURCE_DIR}"
    [[ -f "${SOUNDFONT_PATH}" ]] ||
      die "MuseScore soundfont not found at ${SOUNDFONT_PATH}"
    verify_checksum 256 "${SOUNDFONT_SHA256}" "${SOUNDFONT_PATH}"
    (
      cd "${PROJECT_ROOT}"
      flutter pub get
    )
    ;;
  verify)
    ;;
  *)
    die "Usage: $0 [all|android|ios|verify]"
    ;;
esac

case "${TARGET}" in
  all)
    require_command cmake
    require_command ditto
    require_command zip
    require_command lipo
    require_command nm
    require_command otool
    build_android
    build_ios
    verify_artifacts
    ;;
  android)
    build_android
    verify_android
    ;;
  ios)
    require_command cmake
    require_command ditto
    require_command zip
    require_command lipo
    require_command nm
    require_command otool
    build_ios
    verify_ios
    ;;
  verify)
    require_command unzip
    require_command lipo
    require_command nm
    require_command otool
    verify_artifacts
    ;;
esac

log "Done. Release artifacts are in ${RELEASE_DIR}"
