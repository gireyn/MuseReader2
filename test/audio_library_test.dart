import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/model/score_library_entry.dart';
import 'package:muse_reader/src/ui/reader_page.dart';

import 'support/library_fakes.dart';

/// Audio files are first-class collection items: they are recognized by the
/// import/listing filters, shown with their own badge, and played by the
/// platform media player with the standard transport.
void main() {
  const mp3 = '/library/song.mp3';
  const flac = '/library/tune.flac';
  const scorePath = '/library/alpha.mscx';

  tearDown(clearChannelMocks);

  test('recognizes the requested audio extensions', () {
    for (final path in const [
      'a.mp3',
      'a.wav',
      'a.ogg',
      'a.flac',
      'a.m4a',
      'a.opus',
      'a.aac',
      'a.wma',
      'a.aiff',
      'a.MP3',
      'a.FLAC',
    ]) {
      expect(isAudioPath(path), isTrue, reason: path);
      expect(isSupportedMediaPath(path), isTrue, reason: path);
      expect(scoreFormatForPath(path), ScoreFormat.audio, reason: path);
    }
    expect(isAudioPath('a.mscx'), isFalse);
    expect(isSupportedMediaPath('a.txt'), isFalse);
    expect(scoreFormatForPath('a.mscz'), ScoreFormat.mscz);
    expect(mediaFormatLabel(mp3), 'MP3');
  });

  testWidgets('an audio file is listed with its own badge and plays', (
    tester,
  ) async {
    final mediaCalls = <String>[];
    mockMediaChannel(durationMs: 90000, calls: mediaCalls);

    await pumpFakeLibrary(
      tester,
      imports: const [mp3],
      documents: const {},
      audioMetadata: {
        mp3: {
          'title': 'Song Title',
          'artist': 'Song Artist',
          'durationMs': 90000,
        },
      },
    );

    // 内部标题 off by default: file name, no author, own badge and duration.
    expect(find.text('song'), findsOneWidget);
    expect(find.text('Song Title'), findsNothing);
    expect(find.text('MP3'), findsOneWidget);
    expect(find.text('1:30'), findsOneWidget);

    await tester.tap(find.text('song'));
    await pumpUntilReader(tester);

    expect(find.text('音频文件（无谱面）'), findsOneWidget);
    expect(readerShowsTitle('song'), isTrue);
    // No page navigator for audio items.
    expect(find.byTooltip('上一页'), findsNothing);
    expect(find.byTooltip('下一页'), findsNothing);

    await tester.tap(find.byTooltip('播放'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(mediaCalls, contains('load'));
    expect(mediaCalls, contains('play'));
    expect(find.byTooltip('暂停'), findsOneWidget);

    await tester.tap(find.byTooltip('暂停'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('internal titles show audio tags and the artist', (tester) async {
    mockMediaChannel();

    await pumpFakeLibrary(
      tester,
      imports: const [flac],
      documents: const {},
      storedBooleanPreference: true,
      audioMetadata: {
        flac: {
          'title': 'Tagged Track',
          'artist': 'Tagged Artist',
          'durationMs': 60000,
        },
      },
    );

    expect(find.text('Tagged Track'), findsOneWidget);
    expect(find.text('Tagged Artist'), findsOneWidget);
    expect(find.text('FLAC'), findsOneWidget);

    await tester.tap(find.text('Tagged Track'));
    await pumpUntilReader(tester);
    expect(readerShowsTitle('Tagged Track'), isTrue);
    // The card behind the route still shows the author, so scope to the panel.
    expect(
      find.descendant(
        of: find.byType(ReaderPage),
        matching: find.text('Tagged Artist'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an undecodable audio file reports the failure in the panel', (
    tester,
  ) async {
    mockMediaChannel(available: false);

    await pumpFakeLibrary(tester, imports: const [mp3], documents: const {});
    await tester.tap(find.text('song'));
    await pumpUntilReader(tester);
    await tester.tap(find.byTooltip('播放'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }

    expect(find.text('不支持该格式'), findsOneWidget);
    expect(find.byTooltip('播放'), findsOneWidget); // still paused
    expect(tester.takeException(), isNull);
  });

  testWidgets('scores and audio mix in one collection queue', (tester) async {
    mockMediaChannel();

    await pumpFakeLibrary(
      tester,
      imports: const [scorePath, mp3],
      documents: {scorePath: fakeScoreDocument(scorePath, 'Alpha Title')},
    );

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('song'), findsOneWidget);
    expect(find.text('MSCX'), findsOneWidget);

    await tester.tap(find.text('song'));
    await pumpUntilReader(tester);
    expect(find.byTooltip('下一首'), findsOneWidget);
    expect(find.byTooltip('上一首'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
