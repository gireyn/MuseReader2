import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/services/score_library_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'persists lightweight metadata and a cover beside an imported score',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'muse_reader_library_cache_test.',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/1700000000000_preflight.mscx');
      await source.writeAsString('<museScore/>', flush: true);
      final document = ScoreDocument(
        sourcePath: source.path,
        fileName: source.uri.pathSegments.last,
        format: ScoreFormat.mscx,
        title: 'Cached preflight',
        composer: 'MuseReader',
        division: 480,
        tempoMap: TempoMap(
          division: 480,
          points: const [TempoPoint(tick: 0, quarterNotesPerSecond: 2)],
        ),
        measures: const [],
        events: const [],
        pages: [
          ScorePage(
            index: 0,
            width: 100,
            height: 140,
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
      final cache = ScoreLibraryCache();

      final written = await cache.write(document);
      final restored = await cache.readOrPlaceholder(source.path);

      expect(written.coverBytes, isNotEmpty);
      expect(restored.title, 'Cached preflight');
      expect(restored.composer, 'MuseReader');
      expect(restored.pageCount, 1);
      expect(restored.durationUs, 2000000);
      expect(restored.coverBytes, isNotEmpty);
      expect(restored.document, isNull);

      await source.writeAsString('\n<!-- changed -->', mode: FileMode.append);
      final invalidated = await cache.readOrPlaceholder(source.path);

      expect(invalidated.title, 'preflight');
      expect(invalidated.pageCount, isNull);
      expect(invalidated.coverBytes, isNull);
    },
  );
}
