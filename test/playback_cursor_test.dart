import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/model/score_document.dart';

ScoreDocument _document({
  List<PlaybackEvent> events = const [],
  List<ScoreCursorSegment> cursorSegments = const [],
  int endTick = 960,
}) {
  final tempoMap = TempoMap(
    division: 480,
    points: const [TempoPoint(tick: 0, quarterNotesPerSecond: 2)],
  );
  return ScoreDocument(
    sourcePath: '/tmp/cursor.mscx',
    fileName: 'cursor.mscx',
    format: ScoreFormat.mscx,
    title: 'Cursor fixture',
    composer: '',
    division: 480,
    tempoMap: tempoMap,
    measures: const [],
    events: events,
    pages: const [
      ScorePage(index: 0, width: 820, height: 1160, glyphs: []),
      ScorePage(index: 1, width: 820, height: 1160, glyphs: []),
    ],
    endTick: endTick,
    backend: 'test',
    cursorSegments: cursorSegments,
  );
}

void main() {
  test('interpolates the MuseScore cursor inside an engraved interval', () {
    final document = _document(
      cursorSegments: const [
        ScoreCursorSegment(
          startTick: 0,
          endTick: 480,
          pageIndex: 0,
          rect: ScoreRect(100, 200, 30, 600),
          endX: 300,
        ),
        ScoreCursorSegment(
          startTick: 480,
          endTick: 960,
          pageIndex: 1,
          rect: ScoreRect(40, 120, 30, 600),
          endX: 220,
        ),
      ],
    );

    final halfway = document.cursorForTime(250000);
    expect(halfway, isNotNull);
    expect(halfway!.pageIndex, 0);
    expect(halfway.tick, 240);
    expect(halfway.rect.left, closeTo(200, 0.0001));
    expect(halfway.rect.top, 200);
    expect(halfway.rect.width, 30);
    expect(halfway.rect.height, 600);

    final nextPage = document.cursorForTime(500000);
    expect(nextPage, isNotNull);
    expect(nextPage!.pageIndex, 1);
    expect(nextPage.tick, 480);
    expect(nextPage.rect.left, 40);
  });

  test('uses an event cursor anchor for an unrolled repeat', () {
    const event = PlaybackEvent(
      startTick: 1440,
      endTick: 1920,
      startUs: 1500000,
      endUs: 2000000,
      pitch: 60,
      velocity: 80,
      staff: 0,
      voice: 0,
      measure: 1,
      pageIndex: 0,
      cursorRect: ScoreRect(120, 240, 30, 600),
      cursorEndX: 240,
    );
    final document = _document(
      events: const [event],
      cursorSegments: const [
        ScoreCursorSegment(
          startTick: 0,
          endTick: 960,
          pageIndex: 0,
          rect: ScoreRect(20, 240, 30, 600),
          endX: 100,
        ),
      ],
      endTick: 1920,
    );

    final cursor = document.cursorForTime(1750000);
    expect(cursor, isNotNull);
    expect(cursor!.pageIndex, 0);
    expect(cursor.tick, 1680);
    expect(cursor.rect.left, closeTo(180, 0.0001));
    expect(cursor.rect.top, 240);
  });

  test('keeps the previous engraved anchor through a silent repeat gap', () {
    const event = PlaybackEvent(
      startTick: 0,
      endTick: 480,
      startUs: 0,
      endUs: 500000,
      pitch: 60,
      velocity: 80,
      staff: 0,
      voice: 0,
      measure: 1,
      pageIndex: 0,
      cursorRect: ScoreRect(120, 240, 30, 600),
    );
    final document = _document(
      events: const [event],
      cursorSegments: const [
        ScoreCursorSegment(
          startTick: 0,
          endTick: 960,
          pageIndex: 0,
          rect: ScoreRect(20, 240, 30, 600),
          endX: 100,
        ),
      ],
      endTick: 1680,
    );

    final cursor = document.cursorForTime(1250000);
    expect(cursor, isNotNull);
    expect(cursor!.pageIndex, 0);
    expect(cursor.rect.left, 120);
  });

  test('prefers native playback times when repeated ticks overlap', () {
    final document = _document(
      cursorSegments: const [
        ScoreCursorSegment(
          startTick: 0,
          endTick: 480,
          pageIndex: 0,
          rect: ScoreRect(20, 200, 30, 600),
          endX: 100,
          startUs: 0,
          endUs: 500000,
        ),
        ScoreCursorSegment(
          // The repeated passage maps back to the same original tick range.
          startTick: 0,
          endTick: 480,
          pageIndex: 1,
          rect: ScoreRect(300, 120, 30, 600),
          endX: 380,
          startUs: 500000,
          endUs: 1000000,
        ),
      ],
    );

    final cursor = document.cursorForTime(750000);
    expect(cursor, isNotNull);
    expect(cursor!.pageIndex, 1);
    expect(cursor.tick, 720);
    expect(cursor.rect.left, closeTo(340, 0.0001));
  });

  test(
    'skips malformed cursor geometry and keeps the compatibility fallback',
    () {
      const malformed = ScoreCursorSegment(
        startTick: 0,
        endTick: 480,
        pageIndex: 0,
        rect: ScoreRect(double.nan, 100, 30, 600),
        endX: 180,
      );
      final event = PlaybackEvent(
        startTick: 0,
        endTick: 480,
        startUs: 0,
        endUs: 500000,
        pitch: 60,
        velocity: 80,
        staff: 0,
        voice: 0,
        measure: 1,
        pageIndex: 0,
        pageRect: const ScoreRect(100, 300, 18, 14),
      );
      final document = _document(
        events: [event],
        cursorSegments: const [malformed],
      );

      final cursor = document.cursorForTime(250000);
      expect(cursor, isNotNull);
      expect(cursor!.pageIndex, 0);
      expect(cursor.rect.left, closeTo(91, 0.0001));
      expect(cursor.rect.top, closeTo(270, 0.0001));
    },
  );

  test('resolves a nearby score note to its earliest playback occurrence', () {
    const first = PlaybackEvent(
      startTick: 0,
      endTick: 480,
      startUs: 0,
      endUs: 500000,
      pitch: 60,
      velocity: 80,
      staff: 0,
      voice: 0,
      measure: 1,
      pageIndex: 0,
      pageRect: ScoreRect(100, 300, 20, 16),
    );
    const repeat = PlaybackEvent(
      startTick: 960,
      endTick: 1440,
      startUs: 1000000,
      endUs: 1500000,
      pitch: 60,
      velocity: 80,
      staff: 0,
      voice: 0,
      measure: 1,
      pageIndex: 0,
      pageRect: ScoreRect(100, 300, 20, 16),
    );
    final document = _document(events: const [repeat, first]);

    final hit = document.eventAtPagePosition(0, 110, 308);
    expect(hit, same(first));
    expect(document.playbackTimeAtPagePosition(0, 110, 308), 0);
    expect(document.eventAtPagePosition(0, 300, 500), isNull);
  });

  test('uses a note glyph as a hit target for legacy event metadata', () {
    const event = PlaybackEvent(
      startTick: 480,
      endTick: 960,
      pitch: 64,
      velocity: 80,
      staff: 0,
      voice: 0,
      measure: 1,
    );
    final document = ScoreDocument(
      sourcePath: '/tmp/legacy.mscx',
      fileName: 'legacy.mscx',
      format: ScoreFormat.mscx,
      title: 'Legacy',
      composer: '',
      division: 480,
      tempoMap: TempoMap(
        division: 480,
        points: const [TempoPoint(tick: 0, quarterNotesPerSecond: 2)],
      ),
      measures: const [],
      events: const [event],
      pages: const [
        ScorePage(
          index: 0,
          width: 820,
          height: 1160,
          glyphs: [
            ScoreGlyph(
              kind: GlyphKind.note,
              rect: ScoreRect(200, 240, 13, 9),
              eventIndex: 0,
            ),
          ],
        ),
      ],
      endTick: 960,
      backend: 'test',
    );

    expect(document.eventAtPagePosition(0, 206, 244), same(event));
    expect(document.playbackTimeAtPagePosition(0, 206, 244), 500000);
  });

  test('treats an omitted page index as the first page', () {
    const event = PlaybackEvent(
      startTick: 0,
      endTick: 480,
      pitch: 60,
      velocity: 80,
      staff: 0,
      voice: 0,
      measure: 1,
      pageRect: ScoreRect(40, 80, 12, 10),
    );
    final document = _document(events: const [event]);

    expect(document.eventAtPagePosition(0, 46, 85), same(event));
  });

  test('seeks to the parent chord when a playback event starts late', () {
    const event = PlaybackEvent(
      startTick: 120,
      endTick: 360,
      sourceTick: 0,
      startUs: 125000,
      endUs: 375000,
      pitch: 61,
      velocity: 80,
      staff: 0,
      voice: 0,
      measure: 1,
      pageIndex: 0,
      pageRect: ScoreRect(320, 240, 14, 10),
    );
    final document = _document(events: const [event]);

    expect(document.playbackTimeAtPagePosition(0, 326, 245), 0);
  });

  test('uses a visual note target when MIDI merged the note away', () {
    const target = ScoreNoteTarget(
      rect: ScoreRect(420, 300, 18, 14),
      sourceTick: 960,
      clickStartUs: 1000000,
    );
    final document = ScoreDocument(
      sourcePath: '/tmp/tied.mscx',
      fileName: 'tied.mscx',
      format: ScoreFormat.mscx,
      title: 'Tied',
      composer: '',
      division: 480,
      tempoMap: TempoMap(
        division: 480,
        points: const [TempoPoint(tick: 0, quarterNotesPerSecond: 2)],
      ),
      measures: const [],
      events: const [],
      pages: const [
        ScorePage(
          index: 0,
          width: 820,
          height: 1160,
          glyphs: [],
          noteTargets: [target],
        ),
      ],
      endTick: 1440,
      backend: 'test',
    );

    expect(document.eventAtPagePosition(0, 428, 307), isNull);
    expect(document.playbackTimeAtPagePosition(0, 428, 307), 1000000);
  });
}
