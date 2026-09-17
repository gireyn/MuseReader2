import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/model/score_library_entry.dart';
import 'package:muse_reader/src/services/score_library_cache.dart';
import 'package:muse_reader/src/services/score_repository.dart';
import 'package:muse_reader/src/ui/library_page.dart';
import 'package:muse_reader/src/ui/reader_page.dart';

/// Shared fakes for the library widget tests: they avoid real asynchronous
/// file I/O, which does not progress inside `testWidgets`.
class FakeLibraryRepository implements ScoreRepository {
  FakeLibraryRepository(this.documents);

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

/// Simulates a warm metadata sidecar cache: score documents listed in
/// [documents] are already hydrated (title/composer/page count known), audio
/// files stay placeholders and are filled in from the platform metadata call.
class FakeLibraryCache implements ScoreLibraryCache {
  FakeLibraryCache(this.documents);

  final Map<String, ScoreDocument> documents;

  @override
  Future<ScoreLibraryEntry> readOrPlaceholder(String sourcePath) async {
    final document = documents[sourcePath];
    if (document == null) return ScoreLibraryEntry.placeholder(sourcePath);
    return ScoreLibraryEntry.fromDocument(document);
  }

  @override
  Future<ScoreLibraryEntry> write(ScoreDocument document) async =>
      ScoreLibraryEntry.fromDocument(document);
}

ScoreDocument fakeScoreDocument(
  String path,
  String title, {
  String composer = 'Fixture Composer',
  int durationUs = 4000000,
}) {
  return ScoreDocument(
    sourcePath: path,
    fileName: path.split('/').last,
    format: ScoreFormat.mscx,
    title: title,
    composer: composer,
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
    durationUsOverride: durationUs,
  );
}

const filesChannel = MethodChannel('com.musereader/files');
const mediaChannel = MethodChannel('com.musereader/media');

/// Mocks the platform file channel: imports listing, the persisted display
/// preference and audio metadata.
void mockFilesChannel({
  List<String> imports = const [],
  bool storedBooleanPreference = false,
  Map<String, Map<String, Object?>> audioMetadata = const {},
  void Function(String key, bool value)? onPreferenceWritten,
}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(filesChannel, (call) async {
    switch (call.method) {
      case 'listImportedScoreFiles':
        return imports;
      case 'storedScoreFolderTree':
        return null;
      case 'getBooleanPreference':
        return storedBooleanPreference;
      case 'setBooleanPreference':
        onPreferenceWritten?.call(
          call.arguments['key'] as String,
          call.arguments['value'] as bool,
        );
        return null;
      case 'readAudioMetadata':
        final paths = (call.arguments['paths'] as List<dynamic>).cast<String>();
        return [
          for (final path in paths)
            if (audioMetadata[path] != null)
              <String, Object?>{'path': path, ...audioMetadata[path]!},
        ];
    }
    throw MissingPluginException();
  });
}

/// Mocks the platform media player; [calls] records the invoked methods.
void mockMediaChannel({
  int durationMs = 60000,
  bool available = true,
  List<String>? calls,
}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  // Mimics the platform player's state so the controller's position polling
  // sees a running player after play() and a stopped one after pause().
  var playing = false;
  messenger.setMockMethodCallHandler(mediaChannel, (call) async {
    calls?.add(call.method);
    switch (call.method) {
      case 'load':
        return available
            ? <String, Object?>{'available': true, 'durationMs': durationMs}
            : <String, Object?>{'available': false, 'error': '不支持该格式'};
      case 'play':
        playing = true;
        return true;
      case 'pause':
      case 'stop':
        playing = false;
        return null;
      case 'position':
        return 0;
      case 'isPlaying':
        return playing;
    }
    return null;
  });
}

void clearChannelMocks() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(filesChannel, null);
  messenger.setMockMethodCallHandler(mediaChannel, null);
}

/// Pumps a library page wired to the fakes.
Future<void> pumpFakeLibrary(
  WidgetTester tester, {
  required List<String> imports,
  required Map<String, ScoreDocument> documents,
  bool storedBooleanPreference = false,
  Map<String, Map<String, Object?>> audioMetadata = const {},
  void Function(String key, bool value)? onPreferenceWritten,
}) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  mockFilesChannel(
    imports: imports,
    storedBooleanPreference: storedBooleanPreference,
    audioMetadata: audioMetadata,
    onPreferenceWritten: onPreferenceWritten,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: LibraryPage(
        repository: FakeLibraryRepository(documents),
        libraryCache: FakeLibraryCache(documents),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Autoplay keeps a 16 ms position timer alive: pump manually until the reader
/// route appears instead of using pumpAndSettle.
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
