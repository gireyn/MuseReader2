# MuseScore and Qt source notice

MuseReader's Android and iOS product builds link the MuseScore 3.6.2
`libmscore` engine supplied with the project materials. The mobile application
requires this native backend; it is not an optional compatibility component.
MuseScore 3.6.2 is distributed under the GNU General Public License, version 2.
The original source and its license files are kept in the supplied checkout:

`/Volumes/Files/Github/MuseScore-3.6.2/`

The application launcher/AppIcon artwork in `assets/branding/muse_reader_icon.svg`
is the MuseScore 3.6.2 round application mark copied from
`assets/musescore-icon-round.svg`; the generated Android and iOS PNGs are
derived from that source. MuseScore and its logo are trademarks of their
respective owners; this migration does not imply endorsement or affiliation.

The product packages also link Qt 5.15.2 Core, Gui, Widgets, Xml and Svg,
package the matching Qt Android JNI runtime (`QtAndroid.jar`), and compile
Qt's minimal platform plugin. Qt's open-source distribution includes
GPL/LGPL license choices and component-specific notices. MuseScore's qzip and
FreeType dependencies retain their own upstream notices in the supplied source
tree.

## Bundled playback sources

The mobile engine vendors the MuseScore 3.6.2 FluidSynth fork under
`native/musescore_engine/fluid/`. Its headers and source files retain the
original copyright and GNU Library General Public License notices. The
headless GUI shim and SF3 loader in that directory are MuseReader additions;
the corresponding source is included in this repository.

`assets/sound/MS Basic.sf3` is MuseScore 3.6.2's default MuseScore
General/HQ v0.2 soundfont. The matching `MS Basic_License.md`,
`MS Basic_Readme.md` and changelog are included next to the binary. The
soundfont is derived from FluidR3Mono, whose license and changelog are also
included there; preserve the listed author attributions in derivative
distributions.

`native/musescore_engine/third_party/stb_vorbis.c` is Sean Barrett's Ogg
Vorbis decoder and includes its complete MIT/public-domain dual-license text.
The project uses it only for in-memory SF3 decoding.

Before distributing an APK or IPA, include the applicable license texts,
copyright notices, corresponding source (including the mobile adapter and any
Qt modifications), and any written source offer or relinking materials required
by the selected licenses. The unsigned/debug-signed artifacts produced by this
repository are engineering deliverables, not evidence of legal or app-store
compliance.
