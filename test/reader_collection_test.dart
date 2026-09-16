import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/model/score_library_entry.dart';
import 'package:muse_reader/src/playback/score_queue.dart';
import 'package:muse_reader/src/services/file_picker_service.dart';
import 'package:muse_reader/src/ui/folder_picker_page.dart';
import 'package:muse_reader/src/ui/reader_page.dart';

ScoreDocument _doc(String path, String title, {int durationUs = 0}) {
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
    pages: const [],
    endTick: 0,
    backend: 'test',
    durationUsOverride: durationUs == 0 ? null : durationUs,
  );
}

ScoreLibraryEntry _entry(ScoreDocument document) =>
    ScoreLibraryEntry.fromDocument(document);

void main() {
  testWidgets(
    'collection reader shows previous/next/loop row above the transport',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final docA = _doc('/imports/a.mscx', 'Piece A');
      final docB = _doc('/imports/b.mscx', 'Piece B');
      // Sequential loop keeps the manual switches deterministic (the default
      // random-memory mode may legitimately pick the current piece again).
      final queue = ReaderQueue(
        ids: [docA.sourcePath, docB.sourcePath],
        loop: PlayLoop.sequential,
      );
      final loaded = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            document: docA,
            queue: queue,
            loadEntry: (id) async {
              loaded.add(id);
              return _entry(id == docB.sourcePath ? docB : docA);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(queue.currentId, docA.sourcePath);
      expect(find.byTooltip('上一首'), findsOneWidget);
      expect(find.byTooltip('下一首'), findsOneWidget);
      expect(find.text('顺序播放'), findsOneWidget);
      expect(find.byTooltip('循环模式'), findsOneWidget);

      // 下一首 switches documents in place and leaves playback paused.
      await tester.tap(find.byTooltip('下一首'));
      await tester.pumpAndSettle();
      expect(loaded, [docB.sourcePath]);
      expect(queue.currentId, docB.sourcePath);
      expect(find.text('Piece B'), findsOneWidget);
      expect(find.text('Piece A'), findsNothing);
      expect(tester.takeException(), isNull);

      // Back to the first piece, again through the loader.
      await tester.tap(find.byTooltip('下一首'));
      await tester.pumpAndSettle();
      expect(loaded, [docB.sourcePath, docA.sourcePath]);
      expect(queue.currentId, docA.sourcePath);
      expect(find.text('Piece A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loop menu applies the selected mode to the queue', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final docA = _doc('/imports/a.mscx', 'Piece A');
    final queue = ReaderQueue(
      ids: const ['/imports/a.mscx', '/imports/b.mscx'],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          document: docA,
          queue: queue,
          loadEntry: (id) async => _entry(_doc(id, 'Piece $id')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('随机（记忆）'), findsOneWidget);
    await tester.tap(find.text('随机（记忆）'));
    await tester.pumpAndSettle();
    // All four modes are offered for a multi-piece collection.
    expect(find.text('顺序播放'), findsOneWidget);
    expect(find.text('单曲循环'), findsOneWidget);
    expect(find.text('播完停止'), findsOneWidget);
    await tester.tap(find.text('顺序播放'));
    await tester.pumpAndSettle();
    expect(queue.loop, PlayLoop.sequential);
    expect(find.text('顺序播放'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('standalone reader (no queue) keeps the classic transport only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: ReaderPage(document: _doc('/tmp/one.mscx', 'Solo'))),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('上一首'), findsNothing);
    expect(find.byTooltip('循环模式'), findsNothing);
    expect(find.byType(Slider), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a failed neighbour load keeps the current piece and reports it',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final docA = _doc('/imports/a.mscx', 'Piece A');
      final queue = ReaderQueue(
        ids: const ['/imports/a.mscx', '/imports/b.mscx'],
        loop: PlayLoop.sequential,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            document: docA,
            queue: queue,
            loadEntry: (id) async => throw StateError('missing $id'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一首'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Piece A'), findsOneWidget);
      expect(find.text('打开谱面失败'), findsOneWidget);
      expect(queue.currentId, docA.sourcePath);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('transport play and autoplay both record into the queue memory', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final docA = _doc('/imports/a.mscx', 'Piece A', durationUs: 600000);
    final queue = ReaderQueue(
      ids: const ['/imports/a.mscx', '/imports/b.mscx'],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          document: docA,
          queue: queue,
          loadEntry: (id) async => _entry(_doc(id, 'Piece $id')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(queue.memory.snapshot(), isEmpty);

    // The transport play button must record the piece (this was the bug: only
    // queue-driven starts were recorded, so 随机（记忆） could replay the piece
    // that had just finished).
    await tester.tap(find.byTooltip('播放'));
    await tester.pump();
    expect(queue.memory.snapshot(), [docA.sourcePath]);

    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('autoplay entry records the piece as soon as it plays', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final docA = _doc('/imports/a.mscx', 'Piece A', durationUs: 600000);
    final queue = ReaderQueue(
      ids: const ['/imports/a.mscx', '/imports/b.mscx'],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          document: docA,
          queue: queue,
          autoplay: true,
          loadEntry: (id) async => _entry(_doc(id, 'Piece $id')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(queue.memory.snapshot(), [docA.sourcePath]);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder picker page lists, browses and imports a granted tree', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final channel = MethodChannel('com.musereader/files');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final importedPaths = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'storedScoreFolderTree':
          return 'content://tree/root';
        case 'listScoreFolderContents':
          final documentId = call.arguments['documentId'];
          if (documentId == '') {
            return <String, dynamic>{
              'folders': [
                <String, dynamic>{'documentId': 'sub1', 'name': 'Pieces'},
              ],
              'scores': ['opener.mscz'],
            };
          }
          return <String, dynamic>{
            'folders': <Map<String, dynamic>>[],
            'scores': ['one.mscx', 'two.mscx', 'three.mscz'],
          };
        case 'importScoreFolder':
          importedPaths.addAll(const [
            '/data/imports/1_one.mscx',
            '/data/imports/2_two.mscx',
          ]);
          return importedPaths;
      }
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    final result = navigatorKey.currentState!.push<List<String>>(
      MaterialPageRoute<List<String>>(
        builder: (_) => FolderPickerPage(picker: FilePickerService()),
      ),
    );
    await tester.pumpAndSettle();

    // Root of the granted tree: one folder chip, one direct score listed.
    expect(find.text('打开目录'), findsWidgets);
    expect(find.text('Pieces'), findsOneWidget);
    expect(find.text('opener.mscz'), findsOneWidget);
    expect(find.text('确认目录'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // Enter the subfolder and confirm it.
    await tester.tap(find.text('Pieces'));
    await tester.pumpAndSettle();
    expect(find.text('one.mscx'), findsOneWidget);
    expect(find.text('three.mscz'), findsOneWidget);
    expect(find.text('Pieces'), findsOneWidget); // breadcrumb

    await tester.tap(find.text('确认目录'));
    await tester.pumpAndSettle();
    expect(await result, hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
