import 'dart:math' as math;
import 'dart:typed_data';

enum ScoreFormat { mscx, mscz }

enum GlyphKind {
  title,
  composer,
  measureNumber,
  staffLine,
  barline,
  clef,
  note,
  rest,
}

class ScoreRect {
  const ScoreRect(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;

  double get bottom => top + height;

  bool get isFinite =>
      left.isFinite && top.isFinite && width.isFinite && height.isFinite;
}

/// One page-local region whose engraved ink follows a playback event's color.
///
/// Native MuseScore events can span a chain of tied notes, including ties that
/// cross systems or pages. Keeping the page with each region lets the reader
/// recolor the complete chain while the single MIDI event remains active.
class ScorePlaybackHighlight {
  const ScorePlaybackHighlight({required this.pageIndex, required this.rect});

  final int pageIndex;
  final ScoreRect rect;
}

/// One interval of the playback cursor on an engraved page.
///
/// MuseScore positions its playback cursor by interpolating between the
/// visible chord/rest segments in a measure.  Keeping the interval in the
/// same page coordinate space as the rendered PNG lets Flutter draw the
/// cursor without attempting to lay the score out a second time.
class ScoreCursorSegment {
  const ScoreCursorSegment({
    required this.startTick,
    required this.endTick,
    required this.pageIndex,
    required this.rect,
    this.endX,
    this.startUs,
    this.endUs,
  });

  final int startTick;
  final int endTick;
  final int pageIndex;

  /// Cursor rectangle at [startTick].  Only the x coordinate changes while
  /// the cursor travels through this interval.
  final ScoreRect rect;

  /// x coordinate at [endTick].  Older/native payloads may omit it; in that
  /// case the cursor remains at [rect.left].
  final double? endX;

  /// Optional playback-time bounds. Native scores provide these from
  /// `RepeatList::utick2utime()` so repeated passages remain unambiguous even
  /// when their unrolled tick range overlaps the original score.
  final int? startUs;
  final int? endUs;

  bool get hasTimeRange =>
      startUs != null && endUs != null && endUs! > startUs!;

  bool get isUsable =>
      endTick > startTick &&
      pageIndex >= 0 &&
      rect.isFinite &&
      rect.width > 0 &&
      rect.height > 0 &&
      (endX == null || endX!.isFinite);

  double xAtTick(int tick) {
    final destination = endX ?? rect.left;
    if (endTick <= startTick) return rect.left;
    final amount = ((tick - startTick) / (endTick - startTick))
        .clamp(0.0, 1.0)
        .toDouble();
    return rect.left + (destination - rect.left) * amount;
  }

  ScoreRect rectAtTick(int tick) =>
      ScoreRect(xAtTick(tick), rect.top, rect.width, rect.height);

  ScoreRect rectAtTime(int microseconds) {
    if (!hasTimeRange) return rect;
    final amount = ((microseconds - startUs!) / (endUs! - startUs!))
        .clamp(0.0, 1.0)
        .toDouble();
    final destination = endX ?? rect.left;
    return ScoreRect(
      rect.left + (destination - rect.left) * amount,
      rect.top,
      rect.width,
      rect.height,
    );
  }
}

/// A cursor rectangle resolved for a particular playback position.
class ScoreCursorPosition {
  const ScoreCursorPosition({
    required this.pageIndex,
    required this.rect,
    required this.tick,
  });

  final int pageIndex;
  final ScoreRect rect;
  final int tick;
}

class ScoreGlyph {
  const ScoreGlyph({
    required this.kind,
    required this.rect,
    this.pitch,
    this.text,
    this.eventIndex,
    this.filled = true,
  });

  final GlyphKind kind;
  final ScoreRect rect;
  final int? pitch;
  final String? text;
  final int? eventIndex;
  final bool filled;
}

/// Geometry for an engraved note that can be selected in playback mode.
///
/// A visual note is kept separate from [PlaybackEvent] because MuseScore may
/// merge tied notes (or otherwise omit a standalone MIDI note-on) while the
/// engraved note remains a valid target for `ScoreView::elementNear`.
class ScoreNoteTarget {
  const ScoreNoteTarget({
    required this.rect,
    required this.sourceTick,
    this.clickStartUs,
  });

  final ScoreRect rect;
  final int sourceTick;
  final int? clickStartUs;

  int resolvedClickStartUs(TempoMap tempoMap) {
    final unrolled = clickStartUs;
    if (unrolled != null && unrolled >= 0) return unrolled;
    return tempoMap.tickToUs(sourceTick);
  }
}

class ScorePage {
  const ScorePage({
    required this.index,
    required this.width,
    required this.height,
    required this.glyphs,
    this.imageBytes,
    this.pixelWidth,
    this.pixelHeight,
    this.noteTargets = const [],
  });

  final int index;
  final double width;
  final double height;
  final List<ScoreGlyph> glyphs;

  /// A page rendered by the MuseScore native backend, when available.
  /// The Dart painter is used only when this is null.
  final Uint8List? imageBytes;

  /// Native raster dimensions. Logical [width]/[height] remain the coordinate
  /// space shared with note highlight rectangles.
  final int? pixelWidth;
  final int? pixelHeight;

  /// Visual note geometry emitted by the native renderer.  Compatibility
  /// pages can leave this empty because their note glyphs/events already
  /// provide the same hit information.
  final List<ScoreNoteTarget> noteTargets;
}

class _PlaybackHit {
  const _PlaybackHit({
    this.event,
    required this.timeUs,
    required this.distance,
    required this.containsPoint,
    required this.order,
  });

  final PlaybackEvent? event;
  final int timeUs;
  final double distance;
  final bool containsPoint;
  final int order;
}

class ScoreMeasure {
  const ScoreMeasure({
    required this.number,
    required this.startTick,
    required this.endTick,
  });

  final int number;
  final int startTick;
  final int endTick;
}

class TempoPoint {
  const TempoPoint({required this.tick, required this.quarterNotesPerSecond});

  final int tick;
  final double quarterNotesPerSecond;
}

/// Piecewise-linear conversion between MuseScore ticks and playback time.
/// MuseScore stores tempo as quarter-notes per second (qps), while the UI
/// displays the equivalent BPM.
class TempoMap {
  TempoMap({required this.division, required Iterable<TempoPoint> points})
    : points = _normalize(points);

  final int division;
  final List<TempoPoint> points;

  static List<TempoPoint> _normalize(Iterable<TempoPoint> input) {
    final sorted =
        input.where((point) => point.quarterNotesPerSecond > 0).toList()
          ..sort((a, b) => a.tick.compareTo(b.tick));
    if (sorted.isEmpty || sorted.first.tick != 0) {
      sorted.insert(0, const TempoPoint(tick: 0, quarterNotesPerSecond: 2.0));
    }
    final result = <TempoPoint>[];
    for (final point in sorted) {
      if (result.isNotEmpty && result.last.tick == point.tick) {
        result[result.length - 1] = point;
      } else {
        result.add(point);
      }
    }
    return List.unmodifiable(result);
  }

  double bpmAt(int tick) => quarterNotesPerSecondAt(tick) * 60.0;

  double quarterNotesPerSecondAt(int tick) {
    var current = points.first.quarterNotesPerSecond;
    for (final point in points) {
      if (point.tick > tick) break;
      current = point.quarterNotesPerSecond;
    }
    return current;
  }

  int tickToUs(int tick, {double speed = 1.0}) {
    if (tick <= 0) return 0;
    final safeSpeed = speed <= 0 ? 1.0 : speed;
    var elapsed = 0.0;
    var segmentStart = 0;
    var qps = points.first.quarterNotesPerSecond;
    for (final point in points.skip(1)) {
      if (point.tick >= tick) break;
      elapsed += _ticksToUs(point.tick - segmentStart, qps);
      segmentStart = point.tick;
      qps = point.quarterNotesPerSecond;
    }
    elapsed += _ticksToUs(tick - segmentStart, qps);
    return (elapsed / safeSpeed).round();
  }

  int usToTick(int microseconds, {double speed = 1.0}) {
    if (microseconds <= 0) return 0;
    final safeSpeed = speed <= 0 ? 1.0 : speed;
    var remaining = microseconds * safeSpeed.toDouble();
    var tick = 0;
    var qps = points.first.quarterNotesPerSecond;
    for (final point in points.skip(1)) {
      final segmentUs = _ticksToUs(point.tick - tick, qps);
      if (remaining <= segmentUs) {
        return tick + _usToTicks(remaining, qps);
      }
      remaining -= segmentUs;
      tick = point.tick;
      qps = point.quarterNotesPerSecond;
    }
    return tick + _usToTicks(remaining, qps);
  }

  double _ticksToUs(int ticks, double qps) =>
      ticks * 1000000.0 / division / qps;

  int _usToTicks(double us, double qps) =>
      (us * division * qps / 1000000.0).round();
}

class PlaybackEvent {
  const PlaybackEvent({
    required this.startTick,
    required this.endTick,
    required this.pitch,
    this.tuning = 0.0,
    this.noteheadFilled = true,
    required this.velocity,
    required this.staff,
    required this.voice,
    required this.measure,
    this.channel = 0,
    this.program = 0,
    this.bank = 0,
    this.startUs,
    this.endUs,
    this.sourceTick,
    this.clickStartUs,
    this.pageIndex,
    this.glyphIndex,
    this.pageRect,
    this.highlights = const [],
    this.noteheadImageBytes,
    this.noteheadRect,
    this.cursorRect,
    this.cursorEndX,
  });

  final int startTick;
  final int endTick;
  final int pitch;

  /// Per-note pitch offset in cents, as stored by MuseScore's
  /// `Note::tuning` property.  A value of `100` raises the note by one
  /// semitone while leaving the integer MIDI key in [pitch] unchanged.
  ///
  /// MuseScore's bundled FluidSynth consumes this value as a per-voice
  /// midicent offset, which is what lets two notes sharing one MIDI key use
  /// different microtonal tunings at the same time.
  final double tuning;

  /// Whether MuseScore engraved this notehead as a filled shape. Playback
  /// marking changes the note colour only; hollow heads (whole, half, and
  /// breve notes) must remain hollow while they are sounding.
  final bool noteheadFilled;

  final int velocity;
  final int staff;
  final int voice;
  final int measure;
  final int channel;
  final int program;
  final int bank;
  final int? startUs;
  final int? endUs;

  /// Original engraved Chord/Rest tick for this visual note. Playback events
  /// can begin later when MuseScore applies grace notes, swing, or a user
  /// `<Events>` ornament; PLAY-mode clicks still seek the parent ChordRest's
  /// tick.
  final int? sourceTick;

  /// Unrolled playback time of [sourceTick], supplied by the native backend
  /// when repeats are expanded. Compatibility documents can omit it and
  /// derive the time from [sourceTick] and their local tempo map.
  final int? clickStartUs;
  final int? pageIndex;
  final int? glyphIndex;
  final ScoreRect? pageRect;

  /// Page-local notehead and tie regions that should be recolored together.
  /// Empty lists retain compatibility with payloads that only carry
  /// [pageIndex] and [pageRect].
  final List<ScorePlaybackHighlight> highlights;

  /// Legacy MuseScore-rendered notehead pixels for playback highlighting.
  ///
  /// Older readers used this transparent bitmap as a second layer over the
  /// page.  The current reader keeps the field for payload compatibility but
  /// recolours the existing page pixels inside the tight [pageRect] (falling
  /// back to [noteheadRect] when needed), which avoids a doubled antialiased
  /// edge.  Older documents may omit both fields and use the geometric overlay
  /// fallback.
  final Uint8List? noteheadImageBytes;
  final ScoreRect? noteheadRect;

  /// Optional native cursor geometry for scores with repeats.  The event
  /// stream is unrolled by MuseScore, while its note still points at the
  /// original engraved page; this anchor keeps the cursor on that page when
  /// the unrolled tick is outside the original score range.
  final ScoreRect? cursorRect;
  final double? cursorEndX;

  int resolvedStartUs(TempoMap tempoMap) =>
      startUs ?? tempoMap.tickToUs(startTick);

  int resolvedEndUs(TempoMap tempoMap) => endUs ?? tempoMap.tickToUs(endTick);

  int resolvedClickStartUs(TempoMap tempoMap) {
    final unrolled = clickStartUs;
    if (unrolled != null && unrolled >= 0) return unrolled;
    final source = sourceTick;
    return source == null || source < 0
        ? resolvedStartUs(tempoMap)
        : tempoMap.tickToUs(source);
  }

  PlaybackEvent copyWith({
    int? sourceTick,
    int? clickStartUs,
    int? pageIndex,
    int? glyphIndex,
    ScoreRect? pageRect,
    List<ScorePlaybackHighlight>? highlights,
    Uint8List? noteheadImageBytes,
    ScoreRect? noteheadRect,
    ScoreRect? cursorRect,
    double? cursorEndX,
    double? tuning,
    bool? noteheadFilled,
  }) => PlaybackEvent(
    startTick: startTick,
    endTick: endTick,
    pitch: pitch,
    tuning: tuning ?? this.tuning,
    noteheadFilled: noteheadFilled ?? this.noteheadFilled,
    velocity: velocity,
    staff: staff,
    voice: voice,
    measure: measure,
    channel: channel,
    program: program,
    bank: bank,
    startUs: startUs,
    endUs: endUs,
    sourceTick: sourceTick ?? this.sourceTick,
    clickStartUs: clickStartUs ?? this.clickStartUs,
    pageIndex: pageIndex ?? this.pageIndex,
    glyphIndex: glyphIndex ?? this.glyphIndex,
    pageRect: pageRect ?? this.pageRect,
    highlights: highlights ?? this.highlights,
    noteheadImageBytes: noteheadImageBytes ?? this.noteheadImageBytes,
    noteheadRect: noteheadRect ?? this.noteheadRect,
    cursorRect: cursorRect ?? this.cursorRect,
    cursorEndX: cursorEndX ?? this.cursorEndX,
  );

  Map<String, Object> toMap(TempoMap tempoMap) {
    final result = <String, Object>{
      'startTick': startTick,
      'endTick': endTick,
      'startUs': resolvedStartUs(tempoMap),
      'endUs': resolvedEndUs(tempoMap),
      'pitch': pitch,
      // Keep the field in every event, including ordinary 12-TET notes. An
      // explicit zero lets the native renderer distinguish a tuned voice from
      // a legacy event when matching note-offs.
      'tuning': tuning.isFinite ? tuning : 0.0,
      'noteheadFilled': noteheadFilled,
      'velocity': velocity,
      'staff': staff,
      'voice': voice,
      'measure': measure,
      'channel': channel,
      'program': program,
      'bank': bank,
      'page': pageIndex ?? 0,
    };
    if (sourceTick != null) result['sourceTick'] = sourceTick!;
    if (clickStartUs != null) result['clickStartUs'] = clickStartUs!;
    return result;
  }
}

class ScoreDocument {
  const ScoreDocument({
    required this.sourcePath,
    required this.fileName,
    required this.format,
    required this.title,
    required this.composer,
    required this.division,
    required this.tempoMap,
    required this.measures,
    required this.events,
    required this.pages,
    required this.endTick,
    required this.backend,
    this.durationUsOverride,
    this.symbolFont,
    this.renderDpi,
    this.cursorSegments = const [],
    this.audioEvents = const [],
  });

  final String sourcePath;
  final String fileName;
  final ScoreFormat format;
  final String title;
  final String composer;
  final int division;
  final TempoMap tempoMap;
  final List<ScoreMeasure> measures;
  final List<PlaybackEvent> events;
  final List<ScorePage> pages;
  final int endTick;
  final String backend;
  final int? durationUsOverride;
  final String? symbolFont;
  final int? renderDpi;
  final List<ScoreCursorSegment> cursorSegments;

  /// Non-note MIDI actions used by the native SoundFont renderer. These are
  /// kept separate from [events] because the latter drives page interaction
  /// and intentionally contains notes only.
  final List<Map<String, Object>> audioEvents;

  int get durationUs =>
      durationUsOverride ??
      events.fold<int>(
        tempoMap.tickToUs(endTick),
        (value, event) => math.max(value, event.resolvedEndUs(tempoMap)),
      );

  Duration get duration => Duration(microseconds: durationUs);

  /// Resolve the engraved cursor rectangle for a score tick.
  ScoreCursorPosition? cursorForTick(int tick) {
    final usableSegments = _usableCursorSegments();
    if (usableSegments.isEmpty) return null;
    ScoreCursorSegment? previous;
    for (final segment in usableSegments) {
      if (tick < segment.startTick) {
        final chosen = previous ?? segment;
        return ScoreCursorPosition(
          pageIndex: chosen.pageIndex,
          rect: chosen.rectAtTick(
            previous == null ? chosen.startTick : chosen.endTick,
          ),
          tick: tick,
        );
      }
      if (tick < segment.endTick) {
        return ScoreCursorPosition(
          pageIndex: segment.pageIndex,
          rect: segment.rectAtTick(tick),
          tick: tick,
        );
      }
      previous = segment;
    }
    final last = usableSegments.last;
    return ScoreCursorPosition(
      pageIndex: last.pageIndex,
      rect: last.rectAtTick(last.endTick),
      tick: tick,
    );
  }

  /// Resolve a cursor from playback time, including a note anchor when the
  /// time belongs to an unrolled repeat that has no original-score segment.
  ScoreCursorPosition? cursorForTime(int microseconds) {
    final tick = tempoMap.usToTick(microseconds);
    final usableSegments = _usableCursorSegments();
    if (usableSegments.isNotEmpty &&
        usableSegments.every((segment) => segment.hasTimeRange)) {
      final timedSegments = [...usableSegments]
        ..sort((a, b) {
          final startOrder = a.startUs!.compareTo(b.startUs!);
          if (startOrder != 0) return startOrder;
          final endOrder = a.endUs!.compareTo(b.endUs!);
          if (endOrder != 0) return endOrder;
          return a.pageIndex.compareTo(b.pageIndex);
        });
      ScoreCursorSegment? previous;
      for (final segment in timedSegments) {
        final start = segment.startUs!;
        final end = segment.endUs!;
        if (microseconds < start) {
          final chosen = previous ?? segment;
          return ScoreCursorPosition(
            pageIndex: chosen.pageIndex,
            rect: chosen.rectAtTime(
              previous == null ? chosen.startUs! : chosen.endUs!,
            ),
            tick: tick,
          );
        }
        if (microseconds < end) {
          return ScoreCursorPosition(
            pageIndex: segment.pageIndex,
            rect: segment.rectAtTime(microseconds),
            tick: tick,
          );
        }
        previous = segment;
      }
      final last = timedSegments.last;
      return ScoreCursorPosition(
        pageIndex: last.pageIndex,
        rect: last.rectAtTime(last.endUs!),
        tick: tick,
      );
    }

    // For the ordinary (non-repeat) timeline the native segment geometry is
    // the exact source-of-truth cursor path. Use it before note anchors so a
    // long note does not make the cursor move at the note duration rather than
    // at the engraved segment boundary.
    final maxSegmentTick = usableSegments.fold<int>(
      0,
      (value, segment) => math.max(value, segment.endTick),
    );
    if (usableSegments.isNotEmpty && tick <= maxSegmentTick) {
      final fromSegments = cursorForTick(tick);
      if (fromSegments != null) return fromSegments;
    }

    for (final event in events) {
      final start = event.resolvedStartUs(tempoMap);
      final end = event.resolvedEndUs(tempoMap);
      if (microseconds >= start && microseconds < end) {
        final anchor = event.cursorRect;
        if (anchor != null &&
            anchor.isFinite &&
            anchor.width > 0 &&
            anchor.height > 0) {
          final destination = event.cursorEndX;
          final safeDestination = destination != null && destination.isFinite
              ? destination
              : anchor.left;
          final amount =
              destination == null || !destination.isFinite || end <= start
              ? 0.0
              : ((microseconds - start) / (end - start))
                    .clamp(0.0, 1.0)
                    .toDouble();
          final eventTick = tempoMap.usToTick(microseconds);
          return ScoreCursorPosition(
            pageIndex: event.pageIndex ?? 0,
            rect: ScoreRect(
              anchor.left + (safeDestination - anchor.left) * amount,
              anchor.top,
              anchor.width,
              anchor.height,
            ),
            tick: eventTick,
          );
        }
      }
    }
    // A repeat can leave a short interval with no sounding note. Keep the
    // cursor on the last engraved event instead of jumping to the final
    // original-score segment while the unrolled tick is outside that range.
    PlaybackEvent? previous;
    for (final event in events) {
      if (event.cursorRect == null ||
          microseconds < event.resolvedStartUs(tempoMap)) {
        continue;
      }
      previous = event;
    }
    final previousRect = previous?.cursorRect;
    if (previous != null && previousRect != null && previousRect.isFinite) {
      return ScoreCursorPosition(
        pageIndex: previous.pageIndex ?? 0,
        rect: previousRect,
        tick: tick,
      );
    }

    // Compatibility documents created before cursor metadata used note
    // bounding boxes only.  Build a conservative system-height cursor so the
    // migrated indicator still appears for those documents.
    for (final event in events) {
      final start = event.resolvedStartUs(tempoMap);
      final end = event.resolvedEndUs(tempoMap);
      if (microseconds < start || microseconds >= end) continue;
      final note = event.pageRect;
      if (note == null || !note.isFinite) continue;
      final page = event.pageIndex ?? 0;
      final sameSystem = events
          .where(
            (other) =>
                (other.pageIndex ?? 0) == page &&
                other.measure == event.measure &&
                other.pageRect != null,
          )
          .map((other) => other.pageRect!)
          .toList(growable: false);
      var top = note.top;
      var bottom = note.bottom;
      for (final rect in sameSystem) {
        top = math.min(top, rect.top);
        bottom = math.max(bottom, rect.bottom);
      }
      const margin = 30.0;
      final height = math.max(1.0, bottom - top + margin * 2);
      final width = math.max(24.0, note.width + 18.0);
      return ScoreCursorPosition(
        pageIndex: page,
        rect: ScoreRect(note.left - 9.0, top - margin, width, height),
        tick: event.startTick,
      );
    }
    return null;
  }

  List<ScoreCursorSegment> _usableCursorSegments() => cursorSegments
      .where((segment) => segment.isUsable)
      .toList(growable: false);

  /// Return the playable note nearest to a point on an engraved page.
  ///
  /// MuseScore's [ScoreView::elementNear] does not require a pointer to land
  /// exactly on a glyph: it first checks the element bounds and then searches
  /// a small selection-proximity rectangle around the pointer.  Keep the same
  /// forgiving behaviour for the read-only playback view.  Native documents
  /// carry [PlaybackEvent.pageRect] from `Note::pageBoundingRect()` (or the
  /// legacy notehead rectangle) and the unrolled parent-Chord time.  Their
  /// page-level [ScoreNoteTarget] list covers visible notes that were merged
  /// out of the MIDI stream; the glyph fallback keeps documents produced by
  /// older/native-less parsers clickable as well.
  /// [proximity] is in the same page units as the rectangles; the UI passes
  /// the six-pixel MuseScore default after converting it from screen units.
  PlaybackEvent? eventAtPagePosition(
    int pageIndex,
    double x,
    double y, {
    double proximity = 6.0,
  }) =>
      _playbackHitAtPagePosition(pageIndex, x, y, proximity: proximity)?.event;

  /// Resolve the score-time target used when a note is clicked in playback
  /// mode.  This includes visual note targets that do not have a standalone
  /// MIDI event (for example, the continuation of a tie).
  int? playbackTimeAtPagePosition(
    int pageIndex,
    double x,
    double y, {
    double proximity = 6.0,
  }) => _playbackHitAtPagePosition(
    pageIndex,
    x,
    y,
    proximity: proximity,
    includeVisualTargets: true,
  )?.timeUs;

  _PlaybackHit? _playbackHitAtPagePosition(
    int pageIndex,
    double x,
    double y, {
    required double proximity,
    bool includeVisualTargets = false,
  }) {
    if (pageIndex < 0 ||
        !x.isFinite ||
        !y.isFinite ||
        !proximity.isFinite ||
        proximity < 0) {
      return null;
    }

    // The Flutter viewport passes the page's list position.  Event metadata
    // may carry a stable page index as well; the matching branch below accepts
    // either representation without changing the viewport's position
    // semantics.
    final pagePosition = _pagePositionForIndex(pageIndex);
    if (pagePosition < 0) return null;

    final candidates = <_PlaybackHit>[];
    final page = pages[pagePosition];
    for (var eventIndex = 0; eventIndex < events.length; eventIndex++) {
      final event = events[eventIndex];
      ScoreRect? rect;
      final eventPage = event.pageIndex ?? 0;
      final eventRect = _usableEventRect(event);
      if ((eventPage == pageIndex || eventPage == page.index) &&
          eventRect != null) {
        rect = eventRect;
      } else {
        // Compatibility/native payloads written before pageRect was added
        // can still identify an event through the page glyph's eventIndex.
        for (
          var glyphIndex = 0;
          glyphIndex < page.glyphs.length;
          glyphIndex++
        ) {
          final glyph = page.glyphs[glyphIndex];
          final matchesEvent = glyph.eventIndex == eventIndex;
          final eventPageMatches =
              event.pageIndex == null ||
              event.pageIndex == pageIndex ||
              event.pageIndex == page.index;
          final matchesStoredGlyph =
              eventPageMatches &&
              event.glyphIndex != null &&
              event.glyphIndex == glyphIndex;
          if (glyph.kind == GlyphKind.note &&
              (matchesEvent || matchesStoredGlyph) &&
              _isUsableHitRect(glyph.rect)) {
            rect = glyph.rect;
            break;
          }
        }
      }
      if (rect == null || !_isUsableHitRect(rect)) {
        continue;
      }
      final distance = _distanceToRect(rect, x, y);
      if (_intersectsProximityRect(rect, x, y, proximity)) {
        candidates.add(
          _PlaybackHit(
            event: event,
            timeUs: event.resolvedClickStartUs(tempoMap),
            distance: distance,
            containsPoint: _containsPoint(rect, x, y),
            order: eventIndex,
          ),
        );
      }
    }

    if (includeVisualTargets) {
      // Ties and other playback optimizations can leave a visible Note without
      // a separate MIDI event.  The native page still exports its engraved
      // rectangle and parent-Chord time, so include it in the same nearest-hit
      // ordering as ordinary events.
      for (
        var targetIndex = 0;
        targetIndex < page.noteTargets.length;
        targetIndex++
      ) {
        final target = page.noteTargets[targetIndex];
        if (target.sourceTick < 0 || !_isUsableHitRect(target.rect)) continue;
        final distance = _distanceToRect(target.rect, x, y);
        if (_intersectsProximityRect(target.rect, x, y, proximity)) {
          candidates.add(
            _PlaybackHit(
              timeUs: target.resolvedClickStartUs(tempoMap),
              distance: distance,
              containsPoint: _containsPoint(target.rect, x, y),
              order: events.length + targetIndex,
            ),
          );
        }
      }
    }
    if (candidates.isEmpty) return null;

    // A chord (and a repeated passage) can expose several events at the same
    // page position.  Direct containment wins first, then distance for
    // neighbouring notes; the parent-chord playback time is the stable
    // tie-breaker and mirrors
    // RepeatList::tick2utick(), which resolves a clicked source note to its
    // first unrolled occurrence.
    candidates.sort((left, right) {
      final containmentOrder = (right.containsPoint ? 1 : 0).compareTo(
        left.containsPoint ? 1 : 0,
      );
      if (containmentOrder != 0) return containmentOrder;
      final distanceOrder = left.distance.compareTo(right.distance);
      if (distanceOrder != 0) return distanceOrder;
      final timeOrder = left.timeUs.compareTo(right.timeUs);
      if (timeOrder != 0) return timeOrder;
      return left.order.compareTo(right.order);
    });
    return candidates.first;
  }

  int _pagePositionForIndex(int pageIndex) {
    if (pageIndex < 0) return -1;
    return pageIndex < pages.length ? pageIndex : -1;
  }

  static double _distanceToRect(ScoreRect rect, double x, double y) {
    final dx = x < rect.left
        ? rect.left - x
        : x > rect.right
        ? x - rect.right
        : 0.0;
    final dy = y < rect.top
        ? rect.top - y
        : y > rect.bottom
        ? y - rect.bottom
        : 0.0;
    // Keep this distance only for stable nearest-note ordering.  Acceptance
    // itself uses the asymmetric BSP rectangle in [_intersectsProximityRect].
    return math.max(dx, dy);
  }

  static bool _containsPoint(ScoreRect rect, double x, double y) =>
      x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;

  static bool _intersectsProximityRect(
    ScoreRect rect,
    double x,
    double y,
    double proximity,
  ) {
    final half = proximity * 0.5;
    final left = x - half;
    final top = y - half;
    final right = x + proximity;
    final bottom = y + proximity;
    // This is the same 3w-by-3w rectangle built by MuseScore's
    // elementsNear(), where w = selectionProximity / 2 / zoom.
    return rect.right >= left &&
        rect.left <= right &&
        rect.bottom >= top &&
        rect.top <= bottom;
  }

  static ScoreRect? _usableEventRect(PlaybackEvent event) {
    final pageRect = event.pageRect;
    if (pageRect != null && _isUsableHitRect(pageRect)) {
      return pageRect;
    }
    final legacyRect = event.noteheadRect;
    if (legacyRect != null && _isUsableHitRect(legacyRect)) {
      return legacyRect;
    }
    return null;
  }

  static bool _isUsableHitRect(ScoreRect rect) =>
      rect.isFinite &&
      rect.width > 0 &&
      rect.height > 0 &&
      rect.right.isFinite &&
      rect.bottom.isFinite;

  int pageForTick(int tick) {
    if (pages.isEmpty) return 0;
    for (final event in events) {
      if (tick < event.startTick) return event.pageIndex ?? 0;
      if (tick < event.endTick) return event.pageIndex ?? 0;
    }
    return pages.length - 1;
  }

  int pageForTime(int microseconds) {
    if (pages.isEmpty) return 0;
    for (final event in events) {
      final startUs = event.resolvedStartUs(tempoMap);
      final endUs = event.resolvedEndUs(tempoMap);
      if (microseconds < startUs) return event.pageIndex ?? 0;
      if (microseconds < endUs) {
        return event.pageIndex ?? 0;
      }
    }
    return pages.length - 1;
  }

  List<Map<String, Object>> get nativeEvents =>
      events.map((event) => event.toMap(tempoMap)).toList(growable: false);

  /// Return the complete event stream expected by the native audio backend.
  ///
  /// Older documents have no controller stream, so they retain the exact
  /// note-only payload that previous platform binaries consumed. Native
  /// controller actions are sorted against note starts so initialization and
  /// expressive controls are applied before a note at the same timestamp.
  List<Map<String, Object>> get nativeAudioEvents {
    final notes = nativeEvents;
    if (audioEvents.isEmpty) return notes;

    final combined = <Map<String, Object>>[...audioEvents, ...notes];
    final indexed = combined.asMap().entries.toList(growable: false);
    indexed.sort((left, right) {
      final leftTime = _nativeAudioEventTime(left.value);
      final rightTime = _nativeAudioEventTime(right.value);
      final timeOrder = leftTime.compareTo(rightTime);
      if (timeOrder != 0) return timeOrder;
      final leftControl = _isNativeAudioControl(left.value);
      final rightControl = _isNativeAudioControl(right.value);
      if (leftControl != rightControl) return leftControl ? -1 : 1;
      return left.key.compareTo(right.key);
    });
    return List.unmodifiable(indexed.map((entry) => entry.value));
  }

  static int _nativeAudioEventTime(Map<String, Object> event) {
    final raw = event['timeUs'] ?? event['startUs'];
    if (raw is num && raw.isFinite) {
      final value = raw.round();
      return value < 0 ? 0 : value;
    }
    if (raw is String) {
      final parsed = int.tryParse(raw);
      if (parsed != null) return parsed < 0 ? 0 : parsed;
    }
    return 0;
  }

  static bool _isNativeAudioControl(Map<String, Object> event) =>
      event['kind'] != null ||
      event['type'] != null ||
      event.containsKey('controller') ||
      event.containsKey('cc') ||
      event.containsKey('ctrl');
}
