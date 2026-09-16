import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/main.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/ui/app_theme.dart';
import 'package:muse_reader/src/ui/reader_page.dart';

void main() {
  test('theme text pairs meet WCAG AA contrast', () {
    for (final theme in [MuseReaderTheme.light, MuseReaderTheme.dark]) {
      final colors = theme.colorScheme;
      final pairs = <(Color, Color)>[
        (colors.onPrimary, colors.primary),
        (colors.onSecondary, colors.secondary),
        (colors.onSurface, colors.surface),
        (colors.onSurfaceVariant, colors.surface),
        (colors.onSurface, theme.scaffoldBackgroundColor),
        (colors.onError, colors.error),
        (colors.onErrorContainer, colors.errorContainer),
        (colors.onSecondaryContainer, colors.secondaryContainer),
      ];
      for (final (foreground, background) in pairs) {
        expect(
          _contrastRatio(foreground, background),
          greaterThanOrEqualTo(4.5),
          reason:
              '${foreground.toARGB32().toRadixString(16)} on '
              '${background.toARGB32().toRadixString(16)}',
        );
      }
    }
  });

  testWidgets('library adapts to a two-column tablet layout', (tester) async {
    await _configureView(tester, const Size(1024, 768));
    _mockImportedFiles(tester);

    await tester.pumpWidget(const MuseReaderApp());
    await tester.pumpAndSettle();

    expect(find.byType(SliverGrid), findsOneWidget);
    expect(find.text('1 份谱面'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('打开谱面 MuseReader Demo')),
      findsOneWidget,
    );

    final importButton = find.widgetWithText(FilledButton, '导入谱面');
    expect(tester.getSize(importButton).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('app follows the system dark appearance', (tester) async {
    await _configureView(tester, const Size(390, 844));
    _mockImportedFiles(tester);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const MuseReaderApp());
    await tester.pumpAndSettle();

    final context = tester.element(find.text('谱面库'));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader transport fits landscape at 200 percent text', (
    tester,
  ) async {
    await _configureView(tester, const Size(844, 390));

    await tester.pumpWidget(
      MaterialApp(
        theme: MuseReaderTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: ReaderPage(document: _readerDocument()),
      ),
    );
    await tester.pumpAndSettle();

    final playButton = find.byTooltip('播放');
    expect(playButton, findsOneWidget);
    final playSize = tester.getSize(playButton);
    expect(playSize.width, greaterThanOrEqualTo(48));
    expect(playSize.height, greaterThanOrEqualTo(48));
    expect(find.text('1/2'), findsOneWidget);

    final viewer = tester.widget<InteractiveViewer>(
      find.byKey(const ValueKey('multi-page-score-interactive-viewer')),
    );
    final transform = viewer.transformationController!;
    await tester.tap(find.byTooltip('下一页'));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    expect(transform.value.getTranslation().y, lessThan(0));
    expect(tester.takeException(), isNull);
  });
}

double _contrastRatio(Color first, Color second) {
  final lighter = math.max(
    _relativeLuminance(first),
    _relativeLuminance(second),
  );
  final darker = math.min(
    _relativeLuminance(first),
    _relativeLuminance(second),
  );
  return (lighter + 0.05) / (darker + 0.05);
}

double _relativeLuminance(Color color) {
  double linearize(double channel) => channel <= 0.04045
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * linearize(color.r) +
      0.7152 * linearize(color.g) +
      0.0722 * linearize(color.b);
}

Future<void> _configureView(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void _mockImportedFiles(WidgetTester tester) {
  const channel = MethodChannel('com.musereader/files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async => const []);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

ScoreDocument _readerDocument() {
  final tempoMap = TempoMap(
    division: 480,
    points: const [TempoPoint(tick: 0, quarterNotesPerSecond: 2)],
  );
  return ScoreDocument(
    sourcePath: '/tmp/ui-reader.mscx',
    fileName: 'ui-reader.mscx',
    format: ScoreFormat.mscx,
    title: 'Landscape reader fixture with a long title',
    composer: 'MuseReader',
    division: 480,
    tempoMap: tempoMap,
    measures: const [ScoreMeasure(number: 1, startTick: 0, endTick: 1920)],
    events: const [],
    pages: const [
      ScorePage(index: 0, width: 820, height: 1160, glyphs: []),
      ScorePage(index: 1, width: 820, height: 1160, glyphs: []),
    ],
    endTick: 1920,
    backend: 'test',
    durationUsOverride: 2000000,
  );
}
