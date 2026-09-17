import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/model/score_library_entry.dart';
import 'package:muse_reader/src/services/score_library_cache.dart';
import 'package:muse_reader/src/services/score_repository.dart';
import 'package:muse_reader/src/ui/library_page.dart';

import 'support/library_fakes.dart';

class _RecordingRepository implements ScoreRepository {
  _RecordingRepository(this.documents, this.opened);

  final Map<String, ScoreDocument> documents;
  final List<String> opened;

  @override
  Future<ScoreDocument> open(String path) async {
    opened.add(path);
    return documents[path]!;
  }

  @override
  Future<ScoreDocument> openAsset(String assetPath) async =>
      documents[assetPath]!;
}

class _ColdCache implements ScoreLibraryCache {
  @override
  Future<ScoreLibraryEntry> readOrPlaceholder(String sourcePath) async =>
      ScoreLibraryEntry.placeholder(sourcePath);

  @override
  Future<ScoreLibraryEntry> write(ScoreDocument document) async =>
      ScoreLibraryEntry.fromDocument(document);
}

/// The background pass must start with the cards that are actually on screen
/// (top-most first) and, when the user scrolls while it is busy, re-anchor to
/// the new viewport after finishing the score it is rendering.
void main() {
  const count = 30;
  late List<String> paths;
  late List<String> opened;
  late Map<String, ScoreDocument> documents;

  setUp(() {
    paths = [for (var i = 0; i < count; i++) '/library/score$i.mscx'];
    opened = <String>[];
    documents = {
      for (var i = 0; i < count; i++)
        paths[i]: fakeScoreDocument(paths[i], 'Title $i'),
    };
  });

  tearDown(clearChannelMocks);

  testWidgets('starts from the bottom-most card on screen', (tester) async {
    mockFilesChannel(imports: paths);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          repository: _RecordingRepository(documents, opened),
          libraryCache: _ColdCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Cards the user can see right now.
    final visible = <(double, int)>[];
    for (var i = 0; i < count; i++) {
      final finder = find.text('score$i');
      if (finder.evaluate().isEmpty) continue;
      visible.add((tester.getRect(finder).top, i));
    }
    visible.sort((a, b) => a.$1.compareTo(b.$1));
    expect(visible, isNotEmpty);
    final topMost = visible.first.$2;
    final bottomMost = visible.last.$2;

    // The very first score loaded is the bottom-most visible one (the anchor),
    // not the first entry of the collection.
    final firstIndex = paths.indexOf(opened.first);
    expect(firstIndex, greaterThanOrEqualTo(topMost));
    expect(
      firstIndex,
      lessThanOrEqualTo(bottomMost + 1),
      reason: 'opened=$opened',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('walks upwards from the anchor, then continues below it', (
    tester,
  ) async {
    mockFilesChannel(imports: paths);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          repository: _RecordingRepository(documents, opened),
          libraryCache: _ColdCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));

    // Scroll far enough that the first entries leave the viewport.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await tester.pumpAndSettle();

    final visible = <(double, int)>[];
    for (var i = 0; i < count; i++) {
      final finder = find.text('score$i');
      if (finder.evaluate().isEmpty) continue;
      visible.add((tester.getRect(finder).top, i));
    }
    visible.sort((a, b) => a.$1.compareTo(b.$1));
    expect(visible, isNotEmpty);
    final topMost = visible.first.$2;
    final bottomMost = visible.last.$2;

    opened.clear();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(opened, isNotEmpty);

    // 1) the anchor: the bottom-most card of the viewport (or the next built
    //    card, which the cache extent adds right below it);
    final anchor = paths.indexOf(opened.first);
    expect(anchor, greaterThanOrEqualTo(topMost), reason: 'opened=$opened');
    expect(anchor, lessThanOrEqualTo(bottomMost + 1), reason: 'opened=$opened');

    // 2) then the walk goes upwards: each following score is the previous one
    //    minus one (the sequence reaches the top of the collection and only
    //    then continues below the anchor).
    for (var i = 1; i < opened.length; i++) {
      expect(
        paths.indexOf(opened[i]),
        anchor - i,
        reason: 'opened=$opened anchor=$anchor',
      );
    }
    expect(tester.takeException(), isNull);
  });
}
