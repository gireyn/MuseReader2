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
  FakeLibraryRepository(
    this.documents, {
    this.delay = Duration.zero,
    this.gate,
  });

  final Map<String, ScoreDocument> documents;

  /// Simulated native render latency, used to observe loading indicators.
  final Duration delay;

  /// Optional gate: opening waits for it, so a test can hold a load open.
  final Future<void>? gate;

  @override
  Future<ScoreDocument> open(String path) async {
    if (gate != null) await gate;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
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
  FakeLibraryCache(this.documents, {this.warm = true});

  final Map<String, ScoreDocument> documents;

  /// When false the cache behaves like a cold one: every entry starts as a
  /// placeholder and metadata/cover generation must fill it in.
  final bool warm;

  @override
  Future<ScoreLibraryEntry> readOrPlaceholder(String sourcePath) async {
    final document = documents[sourcePath];
    if (!warm || document == null) {
      return ScoreLibraryEntry.placeholder(sourcePath);
    }
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
  Map<String, bool> storedPreferences = const {},
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
        // Only explicitly stored keys answer; others return null so the app
        // applies its own default (内部标题 off, 熄屏不打断下一首 on).
        return storedPreferences[call.arguments['key'] as String];
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
  bool screenOn = true,
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
      case 'isInteractive':
        return screenOn;
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
  Map<String, bool> storedPreferences = const {},
  Map<String, Map<String, Object?>> audioMetadata = const {},
  void Function(String key, bool value)? onPreferenceWritten,
  bool warmCache = true,
  Duration repositoryDelay = Duration.zero,
  Future<void>? repositoryGate,
}) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  mockFilesChannel(
    imports: imports,
    storedPreferences: storedPreferences,
    audioMetadata: audioMetadata,
    onPreferenceWritten: onPreferenceWritten,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: LibraryPage(
        repository: FakeLibraryRepository(
          documents,
          delay: repositoryDelay,
          gate: repositoryGate,
        ),
        libraryCache: FakeLibraryCache(documents, warm: warmCache),
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

/// Sends a platform -> Dart method call on [channel] (for example the screen-on
/// broadcast or a media-completion callback).
Future<void> sendPlatformCall(
  WidgetTester tester,
  String channel,
  String method,
) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (_) {},
      );
}

bool readerShowsTitle(String title) => find
    .descendant(of: find.byType(AppBar), matching: find.text(title))
    .evaluate()
    .isNotEmpty;
