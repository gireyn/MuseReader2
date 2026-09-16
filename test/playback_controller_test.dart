import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/playback/playback_controller.dart';

ScoreDocument _document() {
  final tempoMap = TempoMap(
    division: 480,
    points: const [TempoPoint(tick: 0, quarterNotesPerSecond: 2)],
  );
  return ScoreDocument(
    sourcePath: '/tmp/controller.mscx',
    fileName: 'controller.mscx',
    format: ScoreFormat.mscx,
    title: 'Controller fixture',
    composer: '',
    division: 480,
    tempoMap: tempoMap,
    measures: const [],
    events: const [],
    pages: const [ScorePage(index: 0, width: 820, height: 1160, glyphs: [])],
    endTick: 960,
    backend: 'test',
    durationUsOverride: 1000000,
    cursorSegments: const [
      ScoreCursorSegment(
        startTick: 0,
        endTick: 960,
        pageIndex: 0,
        rect: ScoreRect(100, 200, 30, 600),
        endX: 300,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('formats playback time with stable minute, second, and hour widths', () {
    expect(formatScoreDuration(0), '0:00');
    expect(formatScoreDuration(9 * 60 * 1000000 + 5 * 1000000), '9:05');
    expect(formatScoreDuration(10 * 60 * 1000000 + 5 * 1000000), '10:05');
    expect(
      formatScoreDuration(1 * 3600 * 1000000 + 2 * 60 * 1000000 + 5 * 1000000),
      '1:02:05',
    );
    expect(formatScoreDuration(-1), '0:00');
  });

  test('shows a cursor after a paused seek and clears it on restart', () async {
    final controller = PlaybackController(_document());
    addTearDown(controller.dispose);

    expect(controller.cursorVisible, isFalse);
    expect(controller.cursorPosition, isNull);

    await controller.seekToUs(250000);

    expect(controller.cursorVisible, isTrue);
    expect(controller.cursorPosition, isNotNull);
    expect(controller.cursorPosition!.rect.left, closeTo(150, 0.0001));

    await controller.restart();

    expect(controller.cursorVisible, isFalse);
    expect(controller.cursorPosition, isNull);
  });
}
