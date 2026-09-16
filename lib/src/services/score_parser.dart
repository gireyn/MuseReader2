import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../model/score_document.dart';

class ScoreParseException implements Exception {
  const ScoreParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads the portable part of the MuseScore 3 XML format.
///
/// This parser is deliberately read-only. It gives the Flutter shell a useful
/// compatibility path, while the optional native backend uses MuseScore's
/// own MasterScore/layout/MIDI code for production-grade fidelity.
class ScoreParser {
  Future<ScoreDocument> parseFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return parseBytes(bytes, path);
  }

  ScoreDocument parseBytes(List<int> bytes, String sourcePath) {
    final extension = _extension(sourcePath);
    final format = extension == 'mscz' ? ScoreFormat.mscz : ScoreFormat.mscx;
    final xmlBytes = format == ScoreFormat.mscz
        ? _extractMscx(bytes)
        : Uint8List.fromList(bytes);

    final document = _parseXml(xmlBytes, sourcePath, format);
    return document;
  }

  Uint8List _extractMscx(List<int> bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      String? rootPath;
      final container = archive.findFile('META-INF/container.xml');
      if (container != null) {
        final containerXml = XmlDocument.parse(
          utf8.decode(_asBytes(container.content), allowMalformed: true),
        );
        for (final rootFile in containerXml.findAllElements('rootfile')) {
          final path = rootFile.getAttribute('full-path');
          if (path != null && path.isNotEmpty) {
            rootPath = path;
            break;
          }
        }
      }

      ArchiveFile? scoreFile;
      if (rootPath != null) {
        scoreFile = archive.findFile(rootPath);
        final normalizedRootPath = rootPath
            .replaceFirst(RegExp(r'^\./'), '')
            .replaceFirst(RegExp(r'^/'), '');
        scoreFile ??= archive.findFile(normalizedRootPath);
      }
      scoreFile ??= archive.files.cast<ArchiveFile?>().firstWhere(
        (file) => file!.name.toLowerCase().endsWith('.mscx'),
        orElse: () => null,
      );
      if (scoreFile == null) {
        throw const ScoreParseException('MSCZ 压缩包中没有找到 MSCX 谱面。');
      }
      return _asBytes(scoreFile.content);
    } on ScoreParseException {
      rethrow;
    } catch (error) {
      throw ScoreParseException('无法读取 MSCZ 文件：$error');
    }
  }

  ScoreDocument _parseXml(
    Uint8List bytes,
    String sourcePath,
    ScoreFormat format,
  ) {
    late XmlDocument xml;
    try {
      xml = XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
    } catch (error) {
      throw ScoreParseException('无法解析 MSCX XML：$error');
    }

    final root = xml.rootElement;
    final division = _firstInt(root, 'Division') ?? 480;
    final metadata = _readMetadata(root, sourcePath);
    final parsed = _readMusic(root, division);
    final tempoMap = TempoMap(
      division: division,
      points: _readTempoPoints(root, division),
    );
    final endTick = parsed.endTick > 0 ? parsed.endTick : division * 4;
    final pages = _buildPages(
      title: metadata.title,
      composer: metadata.composer,
      measures: parsed.measures,
      events: parsed.events,
      rests: parsed.rests,
      staffCount: parsed.staffCount,
    );
    final cursorSegments = _buildCursorSegments(
      measures: parsed.measures,
      staffCount: parsed.staffCount,
    );

    final eventPageAndGlyph = <int, ({int page, int glyph})>{};
    for (final page in pages) {
      for (var glyphIndex = 0; glyphIndex < page.glyphs.length; glyphIndex++) {
        final eventIndex = page.glyphs[glyphIndex].eventIndex;
        if (eventIndex != null) {
          eventPageAndGlyph[eventIndex] = (page: page.index, glyph: glyphIndex);
        }
      }
    }
    final events = parsed.events
        .asMap()
        .entries
        .map((entry) {
          final location = eventPageAndGlyph[entry.key];
          final pageRect = location == null
              ? null
              : pages[location.page].glyphs[location.glyph].rect;
          return entry.value.copyWith(
            pageIndex: location?.page,
            glyphIndex: location?.glyph,
            pageRect: pageRect,
          );
        })
        .toList(growable: false);

    return ScoreDocument(
      sourcePath: sourcePath,
      fileName: _fileName(sourcePath),
      format: format,
      title: metadata.title,
      composer: metadata.composer,
      division: division,
      tempoMap: tempoMap,
      measures: List.unmodifiable(parsed.measures),
      events: events,
      pages: pages,
      endTick: endTick,
      backend: 'Dart compatibility parser',
      cursorSegments: cursorSegments,
    );
  }

  _Metadata _readMetadata(XmlElement root, String sourcePath) {
    final values = <String, String>{};
    for (final element in root.findAllElements('metaTag')) {
      final name = element.getAttribute('name');
      if (name != null && name.isNotEmpty) {
        values[name.toLowerCase()] = element.innerText.trim();
      }
    }
    for (final key in const [
      'workTitle',
      'movementTitle',
      'title',
      'composer',
    ]) {
      final element = _firstDescendant(root, key);
      if (element != null && element.innerText.trim().isNotEmpty) {
        values[key.toLowerCase()] = element.innerText.trim();
      }
    }

    String? richText(String subtype) {
      for (final element in root.findAllElements('Text')) {
        final style =
            element.getAttribute('subtype') ??
            _directChildText(element, 'style');
        if (style?.toLowerCase() == subtype.toLowerCase()) {
          final paragraphs = element.findAllElements('p').toList();
          final text =
              (paragraphs.isNotEmpty ? paragraphs.first.innerText : null) ??
              _directChildText(element, 'text') ??
              element.innerText;
          final cleaned = _cleanText(text);
          if (cleaned.isNotEmpty) return cleaned;
        }
      }
      return null;
    }

    final title = _cleanText(
      _firstNonEmpty([
            values['worktitle'],
            values['movementtitle'],
            values['title'],
            richText('title'),
          ]) ??
          _fileName(
            sourcePath,
          ).replaceFirst(RegExp(r'\.(mscz|mscx)$', caseSensitive: false), ''),
    );
    final composer = _cleanText(
      _firstNonEmpty([
            values['composer'],
            richText('composer'),
            richText('arranger'),
          ]) ??
          '',
    );
    return _Metadata(title: title, composer: composer);
  }

  List<XmlElement> _scoreStaffElements(XmlElement root) {
    final scope = _scoreScope(root);
    var staves = scope
        .findElements('Staff')
        .where((staff) => staff.findElements('Measure').isNotEmpty)
        .toList();
    if (staves.isEmpty) {
      staves = scope
          .findAllElements('Staff')
          .where((staff) => staff.findElements('Measure').isNotEmpty)
          .toList();
    }
    return staves;
  }

  XmlElement _scoreScope(XmlElement root) {
    final scores = root.findElements('Score').toList();
    return scores.isEmpty ? root : scores.first;
  }

  /// Reads the initial playback state for each score staff.
  ///
  /// MuseScore keeps the rendered staves separate from their instrument
  /// definitions: a [Part] contains lightweight Staff entries and an
  /// Instrument/Channel tree, while the score-level Staff contains measures.
  /// Match by staff id first and retain part order as a fallback for older
  /// files that omit ids.
  List<_PlaybackProfile> _readPlaybackProfiles(
    XmlElement root,
    List<XmlElement> staffElements,
  ) {
    final byStaffId = <String, _PlaybackProfile>{};
    final ordered = <_PlaybackProfile>[];
    var nextChannel = 0;
    final scope = _scoreScope(root);

    for (final part in scope.findElements('Part')) {
      XmlElement? instrument;
      for (final child in part.children.whereType<XmlElement>()) {
        if (child.localName == 'Instrument') {
          instrument = child;
          break;
        }
      }
      final profile = _playbackProfile(instrument, nextChannel);
      nextChannel = math.min(256, nextChannel + 1);

      for (final partStaff in part.findElements('Staff')) {
        ordered.add(profile);
        final id = partStaff.getAttribute('id')?.trim();
        if (id != null && id.isNotEmpty) {
          byStaffId.putIfAbsent(id, () => profile);
        }
      }
    }

    return List<_PlaybackProfile>.generate(staffElements.length, (index) {
      final id = staffElements[index].getAttribute('id')?.trim();
      final byId = id == null || id.isEmpty ? null : byStaffId[id];
      if (byId != null) return byId;
      if (index < ordered.length) return ordered[index];
      return _playbackProfile(null, index);
    });
  }

  _PlaybackProfile _playbackProfile(XmlElement? instrument, int channel) {
    final channels = <XmlElement>[];
    if (instrument != null) {
      for (final child in instrument.children.whereType<XmlElement>()) {
        if (child.localName.toLowerCase() == 'channel') {
          channels.add(child);
        }
      }
    }

    XmlElement? selected;
    for (final candidate in channels) {
      final name = candidate.getAttribute('name')?.trim().toLowerCase();
      if (name == null ||
          name.isEmpty ||
          name == 'normal' ||
          name == 'default') {
        selected = candidate;
        break;
      }
    }
    selected ??= channels.isEmpty ? null : channels.first;

    final program =
        (_playbackValue(selected, 'program') ??
                _playbackValue(instrument, 'program') ??
                0)
            .clamp(0, 127)
            .toInt();
    var bank = (_playbackBank(selected) ?? _playbackBank(instrument) ?? 0)
        .clamp(0, 16383)
        .toInt();
    final drumset = _isTruthy(
      instrument == null ? null : _directChildText(instrument, 'useDrumset'),
    );
    if (drumset && bank == 0) bank = 128;

    return _PlaybackProfile(
      channel: channel.clamp(0, 255).toInt(),
      program: program,
      bank: bank,
    );
  }

  static int? _playbackValue(XmlElement? element, String name) {
    if (element == null) return null;
    final wanted = name.toLowerCase();
    for (final child in element.children.whereType<XmlElement>()) {
      if (child.localName.toLowerCase() != wanted) continue;
      final raw = child.getAttribute('value') ?? child.innerText.trim();
      final value = int.tryParse(raw);
      if (value != null) return value;
    }
    return null;
  }

  static int? _playbackBank(XmlElement? element) {
    if (element == null) return null;
    int? msb;
    int? lsb;
    int? explicit;
    for (final child in element.children.whereType<XmlElement>()) {
      final name = child.localName.toLowerCase();
      if (name == 'bank') {
        final raw = child.getAttribute('value') ?? child.innerText.trim();
        explicit = int.tryParse(raw);
        continue;
      }
      if (name != 'controller') continue;
      final controller = int.tryParse(child.getAttribute('ctrl') ?? '');
      final value = int.tryParse(
        child.getAttribute('value') ?? '',
      )?.clamp(0, 127).toInt();
      if (controller == 0) {
        msb = value;
      } else if (controller == 32) {
        lsb = value;
      }
    }
    if (explicit != null) return explicit;
    if (msb == null && lsb == null) return null;
    return ((msb ?? 0) << 7) | (lsb ?? 0);
  }

  static bool _isTruthy(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == '1' || normalized == 'true' || normalized == 'yes';
  }

  int _timeSignatureTicks(XmlElement measure, int division, int fallback) {
    for (final signature in measure.findAllElements('TimeSig')) {
      final numerator = _firstInt(signature, 'sigN');
      final denominator = _firstInt(signature, 'sigD');
      if (numerator != null && denominator != null && denominator > 0) {
        return (division * 4.0 * numerator / denominator).round();
      }
    }
    return fallback;
  }

  int? _declaredMeasureTicks(XmlElement measure, int division) =>
      _fractionTicks(
        measure.getAttribute('len') ?? _directChildText(measure, 'len'),
        division,
      );

  int _locationOffsetTicks(
    XmlElement location,
    int division,
    int measureTicks,
  ) {
    final measures = _directChildInt(location, 'measures') ?? 0;
    final fractions = _fractionTicks(
      _directChildText(location, 'fractions'),
      division,
    );
    return measures * measureTicks + (fractions ?? 0);
  }

  int _scoreTick(int value, int measureStart) =>
      value < measureStart ? measureStart + value : value;

  List<TempoPoint> _readTempoPoints(XmlElement root, int division) {
    final points = <TempoPoint>[];

    // Older files may carry a flat <tempolist> with absolute tick values.
    for (final element in root.findAllElements('tempo')) {
      if (element.parentElement?.localName == 'Tempo') continue;
      final tick =
          int.tryParse(element.getAttribute('tick') ?? '') ??
          _directChildInt(element, 'tick');
      final raw = double.tryParse(element.innerText.trim());
      if (tick == null || raw == null || raw <= 0) continue;
      points.add(
        TempoPoint(
          tick: tick,
          quarterNotesPerSecond: raw > 20 ? raw / 60.0 : raw,
        ),
      );
    }

    // MuseScore 3 stores Tempo elements in a voice event stream. Their tick is
    // implicit in the preceding Chord/Rest durations and location offsets.
    final staves = _scoreStaffElements(root);
    if (staves.isNotEmpty) {
      var staffCursor = 0;
      var nominalMeasureTicks = division * 4;
      for (final measure in staves.first.findElements('Measure')) {
        nominalMeasureTicks = _timeSignatureTicks(
          measure,
          division,
          nominalMeasureTicks,
        );
        final measureTicks =
            _declaredMeasureTicks(measure, division) ?? nominalMeasureTicks;
        final explicitStart = _elementIntAttributeOrChild(measure, 'tick');
        final measureStart = explicitStart ?? staffCursor;
        final voices = measure.findElements('voice').toList();
        final sequences = voices.isEmpty ? <XmlElement>[measure] : voices;
        for (final sequence in sequences) {
          var cursor = measureStart;
          for (final element in sequence.children.whereType<XmlElement>()) {
            if (element.localName == 'location') {
              cursor += _locationOffsetTicks(element, division, measureTicks);
              continue;
            }
            if (element.localName == 'tick') {
              final value = int.tryParse(element.innerText.trim());
              if (value != null) cursor = _scoreTick(value, measureStart);
              continue;
            }
            if (element.localName == 'Tempo') {
              final raw = double.tryParse(
                _directChildText(element, 'tempo') ?? '',
              );
              if (raw != null && raw > 0) {
                final explicitTick = _elementIntAttributeOrChild(
                  element,
                  'tick',
                );
                points.add(
                  TempoPoint(
                    tick: explicitTick == null
                        ? cursor
                        : _scoreTick(explicitTick, measureStart),
                    quarterNotesPerSecond: raw > 20 ? raw / 60.0 : raw,
                  ),
                );
              }
              continue;
            }
            if (element.localName == 'Chord' || element.localName == 'Rest') {
              final explicitTick = _elementIntAttributeOrChild(element, 'tick');
              final eventStart = explicitTick == null
                  ? cursor
                  : _scoreTick(explicitTick, measureStart);
              cursor =
                  eventStart +
                  _durationTicks(element, division, measureTicks: measureTicks);
            }
          }
        }
        staffCursor = math.max(staffCursor, measureStart + measureTicks);
      }
    }
    return points;
  }

  _ParsedMusic _readMusic(XmlElement root, int division) {
    final staffElements = _scoreStaffElements(root);
    final playbackProfiles = _readPlaybackProfiles(root, staffElements);

    final events = <PlaybackEvent>[];
    final rests = <_RestMark>[];
    final measureByNumber = <int, _MeasureAccumulator>{};
    var maxEnd = 0;

    for (var staffIndex = 0; staffIndex < staffElements.length; staffIndex++) {
      final staff = staffElements[staffIndex];
      final playback = playbackProfiles[staffIndex];
      final measures = staff.findElements('Measure').toList();
      var staffCursor = 0;
      var nominalMeasureTicks = division * 4;
      for (
        var measureIndex = 0;
        measureIndex < measures.length;
        measureIndex++
      ) {
        final measure = measures[measureIndex];
        final number =
            int.tryParse(measure.getAttribute('number') ?? '') ??
            measureIndex + 1;
        final explicitStart = _elementIntAttributeOrChild(measure, 'tick');
        final start = explicitStart ?? staffCursor;
        nominalMeasureTicks = _timeSignatureTicks(
          measure,
          division,
          nominalMeasureTicks,
        );
        final measureTicks =
            _declaredMeasureTicks(measure, division) ?? nominalMeasureTicks;
        var end = start + measureTicks;

        final voices = measure.findElements('voice').toList();
        final sequences = voices.isEmpty ? <XmlElement>[measure] : voices;
        for (
          var sequenceIndex = 0;
          sequenceIndex < sequences.length;
          sequenceIndex++
        ) {
          final sequence = sequences[sequenceIndex];
          final sequenceVoice = _voiceOf(sequence, fallback: sequenceIndex);
          var voiceCursor = start;
          for (final container in sequence.children.whereType<XmlElement>()) {
            if (container.localName == 'location') {
              voiceCursor += _locationOffsetTicks(
                container,
                division,
                measureTicks,
              );
              continue;
            }
            if (container.localName == 'tick') {
              final value = int.tryParse(container.innerText.trim());
              if (value != null) voiceCursor = _scoreTick(value, start);
              continue;
            }
            if (container.localName != 'Chord' &&
                container.localName != 'Rest') {
              continue;
            }

            final voice = _voiceOf(container, fallback: sequenceVoice);
            final explicitTick = _elementIntAttributeOrChild(container, 'tick');
            final eventStart = explicitTick == null
                ? voiceCursor
                : _scoreTick(explicitTick, start);
            final duration = _durationTicks(
              container,
              division,
              measureTicks: measureTicks,
            );
            final eventEnd = eventStart + duration;
            voiceCursor = eventEnd;
            end = math.max(end, eventEnd);

            if (container.localName == 'Rest') {
              rests.add(
                _RestMark(
                  startTick: eventStart,
                  endTick: eventEnd,
                  staff: staffIndex,
                  measure: number,
                ),
              );
              continue;
            }

            final notes = container.findAllElements('Note').toList();
            for (final note in notes) {
              final pitch = _firstInt(note, 'pitch');
              if (pitch == null) continue;
              final velocity =
                  _firstInt(note, 'velocity') ??
                  _firstInt(container, 'velocity') ??
                  80;
              final tuning = _firstDouble(note, 'tuning');
              final noteheadFilled = _noteheadFilled(container, note);

              // MuseScore stores optional user NoteEvent entries below
              // <Events>.  They are used by microtonal plugins (including
              // Xen Tuner) when an offset is large enough to move the note
              // to a neighbouring MIDI key.  Preserve those offsets in the
              // compatibility parser just as libmscore's renderMidi path
              // does; ordinary notes retain the single default event.
              final playEvents = _readNotePlayEvents(note);
              if (playEvents.isEmpty) {
                events.add(
                  PlaybackEvent(
                    startTick: eventStart,
                    endTick: eventEnd,
                    pitch: pitch,
                    tuning: tuning,
                    noteheadFilled: noteheadFilled,
                    velocity: velocity.clamp(1, 127),
                    staff: staffIndex,
                    voice: voice,
                    measure: number,
                    channel: playback.channel,
                    program: playback.program,
                    bank: playback.bank,
                    sourceTick: eventStart,
                  ),
                );
                continue;
              }

              for (final playEvent in playEvents) {
                final onOffset = (duration * playEvent.ontime / 1000.0).round();
                final length = (duration * playEvent.len / 1000.0).round();
                final startTick = eventStart + onOffset;
                final endTick = math.max(startTick + 1, startTick + length);
                final adjustedPitch = (pitch + playEvent.pitch).clamp(0, 127);
                events.add(
                  PlaybackEvent(
                    startTick: startTick,
                    endTick: endTick,
                    pitch: adjustedPitch,
                    tuning: tuning,
                    noteheadFilled: noteheadFilled,
                    velocity: velocity.clamp(1, 127),
                    staff: staffIndex,
                    voice: voice,
                    measure: number,
                    channel: playback.channel,
                    program: playback.program,
                    bank: playback.bank,
                    sourceTick: eventStart,
                  ),
                );
              }
            }
          }
        }

        final current = measureByNumber[number];
        if (current == null) {
          measureByNumber[number] = _MeasureAccumulator(start, end);
        } else {
          current.start = math.min(current.start, start);
          current.end = math.max(current.end, end);
        }
        staffCursor = math.max(staffCursor, end);
        maxEnd = math.max(maxEnd, end);
      }
    }

    final measures =
        measureByNumber.entries
            .map(
              (entry) => ScoreMeasure(
                number: entry.key,
                startTick: entry.value.start,
                endTick: entry.value.end,
              ),
            )
            .toList()
          ..sort((a, b) => a.number.compareTo(b.number));
    events.sort((a, b) {
      final tickOrder = a.startTick.compareTo(b.startTick);
      if (tickOrder != 0) return tickOrder;
      return a.pitch.compareTo(b.pitch);
    });
    rests.sort((a, b) => a.startTick.compareTo(b.startTick));
    return _ParsedMusic(
      events: events,
      rests: rests,
      measures: measures,
      endTick: maxEnd,
      staffCount: math.max(1, staffElements.length),
    );
  }

  int _voiceOf(XmlElement element, {int fallback = 0}) {
    final voice =
        int.tryParse(element.getAttribute('voice') ?? '') ??
        _directChildInt(element, 'voice');
    if (voice != null) return voice;
    final track =
        int.tryParse(element.getAttribute('track') ?? '') ??
        _directChildInt(element, 'track');
    return track == null ? fallback : track % 4;
  }

  int _durationTicks(XmlElement element, int division, {int? measureTicks}) {
    final rawDuration = _firstText(element, 'duration');
    final explicit = _fractionTicks(rawDuration, division);
    if (explicit != null && explicit > 0) return explicit;
    final type = (_firstText(element, 'durationType') ?? 'quarter').trim();
    const units = <String, double>{
      'longa': 16,
      'breve': 8,
      'whole': 4,
      'measure': 4,
      'half': 2,
      'quarter': 1,
      'eighth': 0.5,
      '16th': 0.25,
      '32nd': 0.125,
      '64th': 0.0625,
      '128th': 0.03125,
      '256th': 0.015625,
    };
    if (type == 'measure' && measureTicks != null) return measureTicks;
    var quarterNotes = units[type] ?? 1.0;
    final dots = _firstInt(element, 'dots') ?? 0;
    var addition = quarterNotes / 2.0;
    for (var i = 0; i < dots; i++) {
      quarterNotes += addition;
      addition /= 2.0;
    }
    final stretch = _firstText(element, 'timeStretch');
    if (stretch != null) {
      final parts = stretch.split('/');
      if (parts.length == 2) {
        final numerator = double.tryParse(parts[0]);
        final denominator = double.tryParse(parts[1]);
        if (numerator != null && denominator != null && denominator != 0) {
          quarterNotes *= numerator / denominator;
        }
      }
    }
    return math.max(1, (division * quarterNotes).round());
  }

  List<ScorePage> _buildPages({
    required String title,
    required String composer,
    required List<ScoreMeasure> measures,
    required List<PlaybackEvent> events,
    required List<_RestMark> rests,
    required int staffCount,
  }) {
    const pageWidth = 820.0;
    const pageHeight = 1160.0;
    const margin = 64.0;
    const measuresPerSystem = 4;
    const systemsPerPage = 4;
    const measuresPerPage = measuresPerSystem * systemsPerPage;
    final visibleMeasures = measures.isEmpty
        ? const [ScoreMeasure(number: 1, startTick: 0, endTick: 1920)]
        : measures;
    final pageCount = math.max(
      1,
      (visibleMeasures.length + measuresPerPage - 1) ~/ measuresPerPage,
    );
    final pages = <ScorePage>[];

    for (var pageIndex = 0; pageIndex < pageCount; pageIndex++) {
      final glyphs = <ScoreGlyph>[];
      final firstMeasure = pageIndex * measuresPerPage;
      final lastMeasure = math.min(
        visibleMeasures.length,
        firstMeasure + measuresPerPage,
      );
      if (pageIndex == 0) {
        glyphs.add(
          ScoreGlyph(
            kind: GlyphKind.title,
            rect: const ScoreRect(margin, 34, pageWidth - margin * 2, 28),
            text: title,
          ),
        );
        if (composer.isNotEmpty) {
          glyphs.add(
            ScoreGlyph(
              kind: GlyphKind.composer,
              rect: const ScoreRect(margin, 64, pageWidth - margin * 2, 18),
              text: composer,
            ),
          );
        }
      }

      for (
        var localIndex = firstMeasure;
        localIndex < lastMeasure;
        localIndex++
      ) {
        final measure = visibleMeasures[localIndex];
        final systemIndex = (localIndex - firstMeasure) ~/ measuresPerSystem;
        final slot = (localIndex - firstMeasure) % measuresPerSystem;
        final systemTop = 112.0 + systemIndex * 252.0;
        final measureLeft =
            margin + slot * ((pageWidth - margin * 2) / measuresPerSystem);
        final measureWidth = (pageWidth - margin * 2) / measuresPerSystem;
        if (slot == 0) {
          // MuseScore's Measure::layoutMeasureNumber() creates one generated
          // MeasureNumber at the first measure of each system.  Keep the
          // fallback canvas consistent with that line-oriented placement.
          glyphs.add(
            ScoreGlyph(
              kind: GlyphKind.measureNumber,
              rect: ScoreRect(measureLeft, systemTop - 25, 48, 18),
              text: '${measure.number}',
            ),
          );
        }
        final staffSpacing = 78.0;
        for (var staff = 0; staff < staffCount; staff++) {
          final staffTop = systemTop + staff * staffSpacing;
          for (var line = 0; line < 5; line++) {
            glyphs.add(
              ScoreGlyph(
                kind: GlyphKind.staffLine,
                rect: ScoreRect(
                  measureLeft,
                  staffTop + line * 10,
                  measureWidth,
                  1,
                ),
              ),
            );
          }
          if (slot == 0) {
            glyphs.add(
              ScoreGlyph(
                kind: GlyphKind.clef,
                rect: ScoreRect(measureLeft + 8, staffTop - 8, 24, 60),
                text: '𝄞',
              ),
            );
          }
          glyphs.add(
            ScoreGlyph(
              kind: GlyphKind.barline,
              rect: ScoreRect(measureLeft, staffTop - 2, 1.4, 44),
            ),
          );
          glyphs.add(
            ScoreGlyph(
              kind: GlyphKind.barline,
              rect: ScoreRect(
                measureLeft + measureWidth,
                staffTop - 2,
                slot == measuresPerSystem - 1 ? 2.2 : 1.4,
                44,
              ),
            ),
          );

          final staffEvents = <MapEntry<int, PlaybackEvent>>[];
          for (var eventIndex = 0; eventIndex < events.length; eventIndex++) {
            final event = events[eventIndex];
            if (event.measure == measure.number && event.staff == staff) {
              staffEvents.add(MapEntry(eventIndex, event));
            }
          }
          for (final entry in staffEvents) {
            final event = entry.value;
            final span = math.max(1, measure.endTick - measure.startTick);
            final normalized = ((event.startTick - measure.startTick) / span)
                .clamp(0.04, 0.94);
            final noteX = measureLeft + normalized * measureWidth;
            final noteY = staffTop + 40 - (event.pitch - 64) * 5.0;
            glyphs.add(
              ScoreGlyph(
                kind: GlyphKind.note,
                rect: ScoreRect(noteX, noteY, 13, 9),
                pitch: event.pitch,
                eventIndex: entry.key,
                filled: event.noteheadFilled,
              ),
            );
          }
          final staffRests = rests.where(
            (rest) => rest.measure == measure.number && rest.staff == staff,
          );
          if (staffEvents.isEmpty && staffRests.isNotEmpty) {
            glyphs.add(
              ScoreGlyph(
                kind: GlyphKind.rest,
                rect: ScoreRect(
                  measureLeft + measureWidth / 2 - 7,
                  staffTop + 16,
                  14,
                  15,
                ),
              ),
            );
          }
        }
      }
      pages.add(
        ScorePage(
          index: pageIndex,
          width: pageWidth,
          height: pageHeight,
          glyphs: List.unmodifiable(glyphs),
        ),
      );
    }
    return List.unmodifiable(pages);
  }

  /// Generate cursor geometry for the deterministic compatibility layout.
  ///
  /// The native backend supplies this geometry directly from MuseScore's
  /// [PositionCursor].  Keeping the same interval representation here makes
  /// non-mobile tests and desktop diagnostics behave the same way.
  List<ScoreCursorSegment> _buildCursorSegments({
    required List<ScoreMeasure> measures,
    required int staffCount,
  }) {
    const pageWidth = 820.0;
    const pageHeight = 1160.0;
    const margin = 64.0;
    const measuresPerSystem = 4;
    const systemsPerPage = 4;
    const measuresPerPage = measuresPerSystem * systemsPerPage;
    final visibleMeasures = measures.isEmpty
        ? const [ScoreMeasure(number: 1, startTick: 0, endTick: 1920)]
        : measures;
    final result = <ScoreCursorSegment>[];
    final measureWidth = (pageWidth - margin * 2) / measuresPerSystem;
    for (var index = 0; index < visibleMeasures.length; index++) {
      final measure = visibleMeasures[index];
      final pageIndex = index ~/ measuresPerPage;
      final localIndex = index % measuresPerPage;
      final systemIndex = localIndex ~/ measuresPerSystem;
      final slot = localIndex % measuresPerSystem;
      final systemTop = 112.0 + systemIndex * 252.0;
      final measureLeft = margin + slot * measureWidth;
      final span = math.max(1, measure.endTick - measure.startTick);
      // PositionCursor subtracts one spatium from the interpolated segment
      // x.  The synthetic layout uses a 10px equivalent for that margin.
      final startX = measureLeft - 10.0;
      final endX = measureLeft + measureWidth - 10.0;
      final top = math.max(0.0, systemTop - 30.0);
      final height = math.min(
        pageHeight - top,
        54.0 + math.max(1, staffCount) * 78.0,
      );
      result.add(
        ScoreCursorSegment(
          startTick: measure.startTick,
          endTick: measure.startTick + span,
          pageIndex: pageIndex,
          rect: ScoreRect(startX, top, 30.0, math.max(1.0, height)),
          endX: endX,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  /// Resolve the visual notehead style independently from playback duration.
  /// MuseScore allows a note to override the chord duration's head type, so
  /// prefer the note-level value when it is one of the standard head names.
  /// Unknown/missing values retain the historical filled-quarter fallback.
  bool _noteheadFilled(XmlElement chord, XmlElement note) {
    final explicit = _firstText(note, 'headType')?.trim().toLowerCase();
    final chordType = _firstText(chord, 'durationType')?.trim().toLowerCase();
    final type = switch (explicit) {
      // MuseScore 3.x writes an explicit Note::headType as the enum value
      // (-1=auto, 0=whole, 1=half, 2=quarter, 3=brevis), while
      // durationType is written as a name.  Normalize both forms before
      // deciding whether the overlay should use a fill or an outline.
      '-1' || 'auto' || 'head_auto' => chordType,
      '0' || 'whole' || 'head_whole' || 'measure' => 'whole',
      '1' || 'half' || 'head_half' => 'half',
      '2' || 'quarter' || 'head_quarter' => 'quarter',
      '3' || 'breve' || 'brevis' || 'head_brevis' => 'breve',
      'long' || 'longa' => 'long',
      _ => chordType,
    };
    switch (type) {
      case 'whole':
      case 'measure':
      case 'half':
      case 'breve':
      case 'long':
      case 'longa':
        return false;
      default:
        return true;
    }
  }

  static Uint8List _asBytes(dynamic content) {
    if (content is Uint8List) return content;
    if (content is List<int>) return Uint8List.fromList(content);
    if (content is Iterable) {
      return Uint8List.fromList(content.cast<int>().toList());
    }
    throw const ScoreParseException('压缩包条目不是有效的二进制数据。');
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }

  static String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }

  static String _cleanText(String value) {
    final withoutTags = value.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return withoutTags.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  static XmlElement? _firstDescendant(XmlNode node, String name) {
    for (final element in node.findAllElements(name)) {
      return element;
    }
    return null;
  }

  static String? _firstText(XmlNode node, String name) {
    final element = _firstDescendant(node, name);
    final text = element?.innerText.trim();
    return text == null || text.isEmpty ? null : text;
  }

  static int? _firstInt(XmlNode node, String name) =>
      int.tryParse(_firstText(node, name) ?? '');

  static double _firstDouble(XmlNode node, String name) {
    final value = double.tryParse(_firstText(node, name) ?? '');
    // Note::tuning is a qreal in MuseScore and is expressed in cents.  Do not
    // allow malformed/non-finite XML values to poison the audio timeline.
    return value != null && value.isFinite ? value : 0.0;
  }

  static List<_NotePlaybackEvent> _readNotePlayEvents(XmlElement note) {
    final events = <_NotePlaybackEvent>[];
    for (final event in note.findAllElements('Event')) {
      // Only Event elements nested in the note's Events container describe
      // note playback.  A defensive parent check avoids accidentally
      // consuming unrelated elements in malformed documents.
      if (event.parentElement?.localName != 'Events') continue;
      final pitch = _directChildInt(event, 'pitch') ?? 0;
      final ontime = _directChildInt(event, 'ontime') ?? 0;
      final len = _directChildInt(event, 'len') ?? 1000;
      events.add(_NotePlaybackEvent(pitch: pitch, ontime: ontime, len: len));
    }
    return events;
  }

  static String? _directChildText(XmlElement element, String name) {
    for (final child in element.findElements(name)) {
      final text = child.innerText.trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static int? _directChildInt(XmlElement element, String name) =>
      int.tryParse(_directChildText(element, name) ?? '');

  static int? _elementIntAttributeOrChild(XmlElement element, String name) =>
      int.tryParse(element.getAttribute(name) ?? '') ??
      _firstInt(element, name);

  static int? _fractionTicks(String? value, int division) {
    if (value == null) return null;
    final parts = value.split('/');
    if (parts.length != 2) return int.tryParse(value);
    final numerator = double.tryParse(parts[0]);
    final denominator = double.tryParse(parts[1]);
    if (numerator == null || denominator == null || denominator == 0) {
      return null;
    }
    return (division * 4.0 * numerator / denominator).round();
  }
}

class _Metadata {
  const _Metadata({required this.title, required this.composer});

  final String title;
  final String composer;
}

class _PlaybackProfile {
  const _PlaybackProfile({
    required this.channel,
    required this.program,
    required this.bank,
  });

  final int channel;
  final int program;
  final int bank;
}

class _MeasureAccumulator {
  _MeasureAccumulator(this.start, this.end);

  int start;
  int end;
}

class _RestMark {
  const _RestMark({
    required this.startTick,
    required this.endTick,
    required this.staff,
    required this.measure,
  });

  final int startTick;
  final int endTick;
  final int staff;
  final int measure;
}

class _NotePlaybackEvent {
  const _NotePlaybackEvent({
    required this.pitch,
    required this.ontime,
    required this.len,
  });

  final int pitch;
  final int ontime;
  final int len;
}

class _ParsedMusic {
  const _ParsedMusic({
    required this.events,
    required this.rests,
    required this.measures,
    required this.endTick,
    required this.staffCount,
  });

  final List<PlaybackEvent> events;
  final List<_RestMark> rests;
  final List<ScoreMeasure> measures;
  final int endTick;
  final int staffCount;
}
