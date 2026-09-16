import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/model/score_library_entry.dart';
import 'package:muse_reader/src/services/score_library_cache.dart';
import 'package:muse_reader/src/services/score_repository.dart';
import 'package:muse_reader/src/ui/library_page.dart';
import 'package:muse_reader/src/ui/reader_page.dart';

/// In-memory repository so widget tests never depend on real asynchronous file
/// I/O (which does not progress inside `testWidgets`).
class _FakeRepository implements ScoreRepository {
  _FakeRepository(this.documents);

  final Map<String, ScoreDocument> documents;

  @override
  Future<ScoreDocument> open(String path) async {
    final document = documents[path];
    if (document == null) throw StateError('unknown score: $path');
    return document;
  }

  @override
  Future<ScoreDocument> openAsset(String assetPath) async {
    final document = documents[assetPath];
    if (document == null) throw StateError('unknown asset: $assetPath');
    return document;
  }
}

class _FakeLibraryCache implements ScoreLibraryCache {
  @override
  Future<ScoreLibraryEntry> readOrPlaceholder(String sourcePath) async =>
      ScoreLibraryEntry.placeholder(sourcePath);

  @override
  Future<ScoreLibraryEntry> write(ScoreDocument document) async =>
      ScoreLibraryEntry.fromDocument(document);
}

ScoreDocument _doc(String path, String title) {
  return ScoreDocument(
    sourcePath: path,
    fileName: path.split('/').last,
    format: ScoreFormat.mscx,
    title: title,
    composer: 'fixture',
    division: 480,
    tempoMap: TempoMap(
      division: 480,
      points: [TempoPoint(tick: 0, quarterNotesPerSecond: 2)],
    ),
    measures: const [],
    events: const [],
    pages: const [ScorePage(index: 0, width: 820, height: 1160, glyphs: [])],
    endTick: 0,
    backend: 'test',
    durationUsOverride: 4000000,
  );
}

void main() {
  const filesChannel = MethodChannel('com.musereader/files');
  const pathA = '/library/alpha.mscx';
  const pathB = '/library/beta.mscx';

  void mockImports(List<String> paths) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(filesChannel, (call) async {
      switch (call.method) {
        case 'listImportedScoreFiles':
          return paths;
        case 'storedScoreFolderTree':
          return null;
      }
      throw MissingPluginException();
    });
  }

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(filesChannel, null);
  });

  Future<void> pumpLibrary(
    WidgetTester tester, {
    required List<String> importedPaths,
    required Map<String, ScoreDocument> documents,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    mockImports(importedPaths);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          repository: _FakeRepository(documents),
          libraryCache: _FakeLibraryCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Autoplay keeps a 16 ms position timer alive, so pump manually until the
  /// reader route appears instead of using pumpAndSettle.
  Future<void> pumpUntilReader(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      if (find.byType(ReaderPage).evaluate().isNotEmpty) return;
    }
  }

  bool readerShowsTitle(String title) => find
      .descendant(of: find.byType(AppBar), matching: find.text(title))
      .evaluate()
      .isNotEmpty;

  testWidgets('the bundled demo joins the playlist only when it is empty', (
    tester,
  ) async {
    await pumpLibrary(
      tester,
      importedPaths: const [pathA],
      documents: {pathA: _doc(pathA, 'alpha')},
    );

    expect(find.text('MuseReader Demo'), findsNothing);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('开始随机'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bundled demo is shown when nothing is imported', (
    tester,
  ) async {
    await pumpLibrary(tester, importedPaths: const [], documents: const {});

    expect(find.text('MuseReader Demo'), findsOneWidget);
    expect(find.text('开始随机'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('开始随机 opens a piece and plays in random (memory) mode', (
    tester,
  ) async {
    await pumpLibrary(
      tester,
      importedPaths: const [pathA, pathB],
      documents: {pathA: _doc(pathA, 'alpha'), pathB: _doc(pathB, 'beta')},
    );
    expect(find.text('开始随机'), findsOneWidget);

    await tester.tap(find.text('开始随机'));
    await pumpUntilReader(tester);

    expect(find.byType(ReaderPage), findsOneWidget);
    expect(find.byTooltip('下一首'), findsOneWidget);
    expect(find.text('随机（记忆）'), findsOneWidget);
    // autoplay really started
    expect(find.byTooltip('暂停'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('开始随机 skips the piece that was played just before', (
    tester,
  ) async {
    await pumpLibrary(
      tester,
      importedPaths: const [pathA, pathB],
      documents: {pathA: _doc(pathA, 'alpha'), pathB: _doc(pathB, 'beta')},
    );

    // First random start: records whichever piece starts playing.
    await tester.tap(find.text('开始随机'));
    await pumpUntilReader(tester);
    final playedAlpha = readerShowsTitle('alpha');
    expect(playedAlpha || readerShowsTitle('beta'), isTrue);

    // Back to the library stops playback and keeps the memory list.
    await tester.tap(find.byTooltip('返回谱面库'));
    await tester.pumpAndSettle();
    expect(find.text('开始随机'), findsOneWidget);

    // Second random start with two pieces: the memory holds the piece that
    // just played, so the other one must be chosen.
    await tester.tap(find.text('开始随机'));
    await pumpUntilReader(tester);
    expect(readerShowsTitle(playedAlpha ? 'beta' : 'alpha'), isTrue);
    expect(tester.takeException(), isNull);
  });
}
