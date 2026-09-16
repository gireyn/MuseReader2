import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/ui/reader_page.dart';

ScoreDocument _tapDocument() {
  final tempoMap = TempoMap(
    division: 480,
    points: const [TempoPoint(tick: 0, quarterNotesPerSecond: 2)],
  );
  return ScoreDocument(
    sourcePath: '/tmp/tap.mscx',
    fileName: 'tap.mscx',
    format: ScoreFormat.mscx,
    title: 'Tap fixture',
    composer: '',
    division: 480,
    tempoMap: tempoMap,
    measures: const [ScoreMeasure(number: 1, startTick: 0, endTick: 1920)],
    events: const [
      PlaybackEvent(
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
        pageRect: ScoreRect(100, 160, 24, 20),
      ),
      PlaybackEvent(
        startTick: 960,
        endTick: 1440,
        startUs: 1000000,
        endUs: 1500000,
        pitch: 64,
        velocity: 80,
        staff: 0,
        voice: 0,
        measure: 1,
        pageIndex: 0,
        pageRect: ScoreRect(500, 160, 24, 20),
      ),
    ],
    pages: [
      ScorePage(
        index: 0,
        width: 820,
        height: 1160,
        glyphs: const [],
        imageBytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      ),
    ],
    endTick: 1920,
    backend: 'test',
    durationUsOverride: 2000000,
  );
}

void main() {
  testWidgets('tapping a score note seeks while playback is active', (
    tester,
  ) async {
    const channel = MethodChannel('com.musereader/musescore_engine');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(home: ReaderPage(document: _tapDocument())),
    );
    await tester.pumpAndSettle();

    // The original ScoreView only seeks from ViewState::PLAY; ordinary
    // reading taps must not move the transport.
    final pageFinder = find.byKey(const ValueKey<String>('score-page-0'));
    final pageRect = tester.getRect(pageFinder);
    final target = Offset(
      pageRect.left + pageRect.width * 500 / 820 + 8,
      pageRect.top + pageRect.height * 160 / 1160 + 10,
    );
    await tester.tapAt(target);
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.textContaining('0:00/0:02'), findsOneWidget);

    await tester.tap(find.byTooltip('播放'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    // Playback follow-cursor may adjust the canvas transform, so resolve the
    // second tap against the page's current on-screen rectangle.
    final playingPageRect = tester.getRect(pageFinder);
    final playingTarget = Offset(
      playingPageRect.left + playingPageRect.width * 500 / 820 + 8,
      playingPageRect.top + playingPageRect.height * 160 / 1160 + 10,
    );
    await tester.tapAt(playingTarget);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('0:01/0:02'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
