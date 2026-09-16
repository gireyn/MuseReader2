import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/main.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/ui/reader_page.dart';

void main() {
  testWidgets('opens the bundled score without a compact-layout overflow', (
    tester,
  ) async {
    const filesChannel = MethodChannel('com.musereader/files');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(filesChannel, (call) async => const []);
    addTearDown(() => messenger.setMockMethodCallHandler(filesChannel, null));
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const MuseReaderApp());
    await tester.pumpAndSettle();

    expect(find.text('谱面库'), findsOneWidget);
    expect(find.text('MuseReader Demo'), findsOneWidget);

    await tester.tap(find.text('MuseReader Demo'));
    await tester.pumpAndSettle();

    // Composer text is part of the engraved page image, not the transport
    // metadata row; it should no longer appear as a bottom control label.
    expect(find.text('MuseReader sample'), findsNothing);
    expect(find.byTooltip('播放速度'), findsNothing);
    expect(find.textContaining('小节'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders a native page with a page-coordinate playback marker', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempoMap = TempoMap(
      division: 480,
      points: const [TempoPoint(tick: 0, quarterNotesPerSecond: 2)],
    );
    final document = ScoreDocument(
      sourcePath: '/tmp/native.mscx',
      fileName: 'native.mscx',
      format: ScoreFormat.mscx,
      title: 'Native fixture',
      composer: 'MuseReader',
      division: 480,
      tempoMap: tempoMap,
      measures: const [ScoreMeasure(number: 1, startTick: 0, endTick: 480)],
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
          pageRect: ScoreRect(180, 260, 18, 20),
          highlights: [
            ScorePlaybackHighlight(
              pageIndex: 0,
              rect: ScoreRect(180, 260, 18, 20),
            ),
            ScorePlaybackHighlight(
              pageIndex: 0,
              rect: ScoreRect(198, 250, 132, 8),
            ),
            ScorePlaybackHighlight(
              pageIndex: 0,
              rect: ScoreRect(330, 260, 18, 20),
            ),
          ],
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
      endTick: 480,
      backend: 'MuseScore native core',
      durationUsOverride: 500000,
    );

    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    await tester.pumpAndSettle();

    expect(find.text('Native fixture'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);

    await tester.tap(find.byTooltip('播放'));
    await tester.pump();

    final clipFinder = find.descendant(
      of: find.byKey(const ValueKey('score-page-0')),
      matching: find.byType(ClipPath),
    );
    expect(clipFinder, findsOneWidget);
    final clip = tester.widget<ClipPath>(clipFinder);
    final clipSize = tester.getSize(clipFinder);
    final highlightPath = clip.clipper!.getClip(clipSize);
    Offset pagePoint(double x, double y) =>
        Offset(x * clipSize.width / 820, y * clipSize.height / 1160);
    expect(highlightPath.contains(pagePoint(189, 270)), isTrue);
    expect(highlightPath.contains(pagePoint(264, 254)), isTrue);
    expect(highlightPath.contains(pagePoint(339, 270)), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens a multi-page canvas and responds to a pinch gesture', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempoMap = TempoMap(
      division: 480,
      points: const [TempoPoint(tick: 0, quarterNotesPerSecond: 2)],
    );
    final document = ScoreDocument(
      sourcePath: '/tmp/multi-page.mscx',
      fileName: 'multi-page.mscx',
      format: ScoreFormat.mscx,
      title: 'Multi-page fixture',
      composer: 'MuseReader',
      division: 480,
      tempoMap: tempoMap,
      measures: const [],
      events: const [],
      pages: [
        for (var index = 0; index < 3; index++)
          ScorePage(index: index, width: 820, height: 1160, glyphs: const []),
      ],
      endTick: 0,
      backend: 'test',
    );

    await tester.pumpWidget(MaterialApp(home: ReaderPage(document: document)));
    await tester.pumpAndSettle();

    expect(find.byType(PageView), findsNothing);
    expect(
      find.byKey(const ValueKey('multi-page-score-interactive-viewer')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('多页谱面视图，双指缩放'), findsOneWidget);
    expect(find.bySemanticsLabel('第 1 页'), findsOneWidget);
    expect(find.bySemanticsLabel('第 2 页'), findsOneWidget);
    expect(find.bySemanticsLabel('第 3 页'), findsOneWidget);

    final viewerFinder = find.byKey(
      const ValueKey('multi-page-score-interactive-viewer'),
    );
    final viewer = tester.widget<InteractiveViewer>(viewerFinder);
    final controller = viewer.transformationController!;
    expect(viewer.panEnabled, isTrue);
    expect(viewer.scaleEnabled, isTrue);
    expect(viewer.minScale, 0.8);
    expect(viewer.maxScale, 4.0);
    final center = tester.getCenter(viewerFinder);
    final first = await tester.createGesture();
    final second = await tester.createGesture();
    await first.down(center - const Offset(20, 0));
    await second.down(center + const Offset(20, 0));
    await tester.pump();
    await first.moveTo(center - const Offset(70, 0));
    await second.moveTo(center + const Offset(70, 0));
    await tester.pump();
    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1.0));
    await first.up();
    await second.up();

    await tester.tap(find.byTooltip('适应页面'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
  });
}
