# Bundled FluidSynth fork

This directory contains the FluidSynth implementation shipped in the
MuseScore 3.6.2 source tree (`audio/midi/fluid`). It is compiled directly into
the MuseReader native engine for Android and iOS; no desktop FluidSynth
library or runtime sound-font search path is required.

The files retain their upstream copyright and GNU Library General Public
License notices. Keep those notices and the corresponding source available
when distributing a build. `fluid_headless.cpp` is the MuseReader adapter for
the GUI virtual method, and `sfont3.cpp` is the mobile SF3 sample-loader
adapter. The remaining implementation files are unchanged MuseScore sources.

The renderer loads MuseScore 3.6.2's default `assets/sound/MS Basic.sf3` from
the Qt resource path `:/sound/MS Basic.sf3`. It receives the expanded note events
from `muse_reader_engine.cpp`, renders stereo float PCM at 44.1 kHz, and
exposes that stream through the C ABI in `muse_reader_engine.h`.
