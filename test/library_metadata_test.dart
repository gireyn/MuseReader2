import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/playback/playback_controller.dart';
import 'package:muse_reader/src/services/score_metadata_reader.dart';

import 'support/library_fakes.dart';

const _mscx = '''
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="3.6">
  <Division>480</Division>
  <metaTag name="workTitle">Morning Song</metaTag>
  <metaTag name="composer">A. Composer</metaTag>
  <Part><Staff /></Part>
  <Staff id="1"><Measure number="1">
    <Chord><durationType>quarter</durationType><Note><pitch>60</pitch></Note></Chord>
  </Measure></Staff>
</museScore>
''';

void main() {
  group('ScoreMetadataReader', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('muse_reader_meta');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('reads workTitle/composer from an MSCX file', () async {
      final path = '${directory.path}/song.mscx';
      await File(path).writeAsString(_mscx);

      final metadata = await ScoreMetadataReader().read(path);

      expect(metadata.title, 'Morning Song');
      expect(metadata.composer, 'A. Composer');
      expect(metadata.isEmpty, isFalse);
    });

    test('reads the same metadata from an MSCZ archive', () async {
      final archive = Archive()
        ..addFile(ArchiveFile('song.mscx', _mscx.length, utf8.encode(_mscx)));
      final path = '${directory.path}/song.mscz';
      await File(path).writeAsBytes(ZipEncoder().encode(archive)!);

      final metadata = await ScoreMetadataReader().read(path);

      expect(metadata.title, 'Morning Song');
      expect(metadata.composer, 'A. Composer');
    });

    test('a file without metadata yields an empty result', () async {
      final path = '${directory.path}/plain.mscx';
      await File(path).writeAsString('<museScore version="3.6"/>');

      expect((await ScoreMetadataReader().read(path)).isEmpty, isTrue);
      expect(
        (await ScoreMetadataReader().read('/missing/x.mscx')).isEmpty,
        isTrue,
      );
    });
  });

  group('score completion', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('com.musereader/musescore_engine');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('handleCompleted latches the stopped state at the duration', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      final document = fakeScoreDocument('/library/a.mscx', 'A');
      final controller = PlaybackController(document);
      await controller.play();
      expect(controller.isPlaying, isTrue);

      controller.handleCompleted();

      expect(controller.isPlaying, isFalse);
      expect(controller.positionUs, controller.durationUs);
      // Idempotent: a second report changes nothing.
      controller.handleCompleted();
      expect(controller.positionUs, controller.durationUs);
      controller.dispose();
    });
  });

  group('library background passes', () {
    tearDown(clearChannelMocks);

    testWidgets(
      'a cold cache is filled in the background: title, author and cover pass',
      (tester) async {
        const path = '/library/alpha.mscx';
        await pumpFakeLibrary(
          tester,
          imports: const [path],
          documents: {path: fakeScoreDocument(path, 'Alpha Title')},
          storedPreferences: const {'use_internal_titles': true},
          warmCache: false,
        );

        // The background pass renders the score once, keeps its metadata and
        // releases the document again.
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }

        expect(find.text('Alpha Title'), findsOneWidget);
        expect(find.text('Fixture Composer'), findsOneWidget);
        expect(find.text('alpha'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('audio cards show no thumbnail, score cards do', (
      tester,
    ) async {
      const scorePath = '/library/alpha.mscx';
      const mp3 = '/library/song.mp3';
      mockMediaChannel();

      await pumpFakeLibrary(
        tester,
        imports: const [scorePath, mp3],
        documents: {scorePath: fakeScoreDocument(scorePath, 'Alpha Title')},
      );

      // Exactly one preview frame: the score card. The audio card is text-only.
      expect(
        find.byKey(const ValueKey<String>('library-score-preview')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.audiotrack_rounded), findsOneWidget);
      expect(find.text('MP3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
