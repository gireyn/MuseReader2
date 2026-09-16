# MuseScore native backend

This directory builds the required mobile C ABI around MuseScore 3.6.2. The
Android and iOS product artifacts compile `libmscore` from the attached source;
they do not use the former stub or a desktop MuseScore binary.

The adapter uses the same source of truth for engraving and playback:

1. `MasterScore::loadMsc()` reads MSCX and MSCZ.
2. The adapter overrides a score's persisted `line`/`system` layout mode with
   `LayoutMode::PAGE`, so every opened score is laid out as paper pages.
3. `MasterScore::doLayout()` computes native page geometry and is configured
   with MuseScore's
   `showMeasureNumber`/`measureNumberSystem` styles, then `Score::print()`
   paints each page (including generated line-start measure numbers) to PNG.
4. `Score::renderMidi(..., expandRepeats=true, ...)` creates the expanded event
   stream.
5. `Score::utick2utime()` converts expanded ticks through MuseScore's
   `TempoMap` and `RepeatList`.

The JSON response contains rendered pages, integer-microsecond event times,
per-note `Note::tuning` cent offsets, and `Note::pageBoundingRect()` coordinates
from the same laid-out `MasterScore`. Flutter uses each event's tight `rect`
metadata to recolour the existing raster pixels for a sounding note in place,
preserving filled, hollow, and custom notehead contours and their antialiasing
without drawing a second notehead over the page. A legacy transparent
`noteheadImage`/`noteheadRect` pair is still accepted/emitted for payload
compatibility with older readers, but the current UI does not place it as an
overlay.
Native playback events with a source note also carry its original `sourceTick`
and, when repeats are expanded, the corresponding first-occurrence
`clickStartUs`; this mirrors `ScoreView`'s PLAY-mode click on the parent
`ChordRest`, including delayed grace/ornament events. Pages additionally expose
`noteTargets` for visible engraved notes that MuseScore merged into another
MIDI event (such as tied continuations), so the playback click path still
covers the complete layout.
Flutter therefore does not reconstruct engraving geometry or playback timing.
A tuning value is carried alongside the integer MIDI pitch; this preserves
independently tuned unisons.

## Bundled playback

The mobile source build also vendors the MuseScore FluidSynth fork from
`audio/midi/fluid`. `MUSE_READER_WITH_FLUIDSYNTH` is enabled by default for the
product build. The CMake resource file embeds the MuseScore 3.6.2 default
`assets/sound/MS Basic.sf3` as `:/sound/MS Basic.sf3`; the soundfont is not
copied into the Flutter asset bundle a second time. SF3 Ogg
packets are decoded in memory by the bundled `stb_vorbis` implementation.

`muse_reader_audio.cpp` converts the native note and MIDI-control event JSON
(including each note's cent offset) into the same program, controller, and
note events used by MuseScore's sequencer, then exposes a small pull-render API in
`muse_reader_engine.h`. Android feeds that API to a stereo `AudioTrack`, while
iOS feeds it to an `AVAudioSourceNode`. Both platforms retain the existing
simple oscillator as a fallback for development builds whose native library
does not contain the optional audio symbols.

The selected soundfont is MuseScore's `MS Basic.sf3` (MuseScore_General_HQ
v0.2). Its license, readme and changelog are kept beside the binary in
`assets/sound/`; the inherited FluidR3Mono attribution is included there as
well.

## Source build

`MUSE_READER_BUILD_MUSESCORE_SOURCE=ON` adds the upstream `libmscore`, qzip and
FreeType targets directly. It also compiles the MIDI event implementation,
embeds the MuseScore fonts/styles/instrument resources, and selects the minimal
Qt platform plugin for headless page rendering.

Android's Gradle build enables this mode automatically and emits only
`arm64-v8a`. The JNI shared object contains the static MuseScore dependencies;
Qt 5.15.2 Core, Gui, Widgets, Xml and Svg plus `libc++_shared.so` are packaged as
APK shared libraries. The matching `jar/QtAndroid.jar` is packaged as well:
QtCore's `JNI_OnLoad` resolves `QtNative` even though the Flutter host does not
run Qt's `QtActivity` deployment path. The bundled qminimal plugin uses Qt's
Android font database to scan `/system/fonts`, so MuseScore text (including
Chinese) can fall back to the device's CJK faces while the embedded engraving
fonts remain registered as application fonts.

iOS builds a dynamic `MuseReaderEngine.framework` for `iphoneos/arm64`. Qt,
MuseScore, qzip, FreeType, qminimal, and reader resources are linked into that
framework, leaving only Apple system frameworks and libraries as dynamic
dependencies. Runner embeds and signs the framework when a signed app build is
performed.

Use the project wrapper to download the pinned Qt kits, build both platforms,
package the results, and audit their architectures:

```sh
./tool/build_mobile_arm64.sh all
```

The equivalent standalone iOS framework configuration is:

```sh
cmake -S native/musescore_engine -B build/native-ios-arm64 -G Xcode \
  -DMUSE_READER_BUILD_MUSESCORE_SOURCE=ON \
  -DMUSE_READER_BUILD_IOS_FRAMEWORK=ON \
  -DMUSESCORE_SOURCE_DIR=/Volumes/Files/Github/MuseScore-3.6.2 \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_PREFIX_PATH=/path/to/Qt/5.15.2/ios \
  -DQt5_DIR=/path/to/Qt/5.15.2/ios/lib/cmake/Qt5
cmake --build build/native-ios-arm64 \
  --config Release --target muse_reader_engine
```

The legacy `MUSESCORE_LIBRARIES` mode remains available for an externally built
complete dependency closure, but the mobile product path intentionally uses the
source build so that headers, compile definitions, resources, Qt configuration,
and archive architecture cannot drift apart.

MuseScore 3.6.2 is GPLv2. Distribution must include the corresponding license
and source-offer notices documented in `NOTICE-MUSESCORE.md`.
