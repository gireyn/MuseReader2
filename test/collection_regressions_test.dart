import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/model/score_document.dart';
import 'package:muse_reader/src/model/score_library_entry.dart';
import 'package:muse_reader/src/playback/score_queue.dart';
import 'package:muse_reader/src/services/file_picker_service.dart';
import 'package:muse_reader/src/ui/folder_picker_page.dart';
import 'package:muse_reader/src/ui/reader_page.dart';

ScoreDocument _document(String id) => ScoreDocument(
  sourcePath: id,
  fileName: id,
  format: ScoreFormat.mscx,
  title: id,
  composer: '',
  division: 480,
  tempoMap: TempoMap(
    division: 480,
    points: const [TempoPoint(tick: 0, quarterNotesPerSecond: 2)],
  ),
  measures: const [],
  events: const [],
  pages: const [],
  endTick: 960,
  durationUsOverride: 1000000,
  backend: 'test',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const files = MethodChannel('com.musereader/files');
  const engine = MethodChannel('com.musereader/musescore_engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // 确认目录 is a FilledButton.icon, which builds a FilledButton subclass, so
  // find.byType(FilledButton) cannot see it: match the button by its type
  // hierarchy instead. The assertions stay exactly as they were.
  FilledButton confirmButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.ancestor(
      of: find.text('确认目录'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    ),
  );

  tearDown(() {
    messenger.setMockMethodCallHandler(files, null);
    messenger.setMockMethodCallHandler(engine, null);
  });

  testWidgets('transport play records history and random next avoids it', (
    tester,
  ) async {
    final queue = ReaderQueue(ids: const ['a.mscx', 'b.mscx']);
    addTearDown(queue.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          document: _document('a.mscx'),
          queue: queue,
          loadEntry: (id) async =>
              ScoreLibraryEntry.fromDocument(_document(id)),
        ),
      ),
    );
    await tester.tap(find.byTooltip('播放'));
    await tester.pump();
    expect(queue.memory.snapshot(), ['a.mscx']);

    await tester.tap(find.byTooltip('下一首'));
    await tester.pump();
    await tester.pump();
    expect(queue.currentId, 'b.mscx');
    expect(queue.memory.snapshot(), ['b.mscx']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a slow folder import waits for the native result', (
    tester,
  ) async {
    final completion = Completer<List<String>>();
    messenger.setMockMethodCallHandler(files, (_) => completion.future);
    List<String>? imported;
    final operation = FilePickerService()
        .importScoreFolder('content://tree/scores', '')
        .then((value) => imported = value);
    await tester.pump(const Duration(seconds: 30));
    expect(imported, isNull);
    completion.complete(['/imports/score.mscx']);
    await tester.pump();
    await operation;
    expect(imported, ['/imports/score.mscx']);
  });

  test(
    'a missing import result cannot be mistaken for an empty folder',
    () async {
      messenger.setMockMethodCallHandler(files, (_) async => null);
      await expectLater(
        FilePickerService().importScoreFolder('content://tree/scores', ''),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  testWidgets('an unreadable directory cannot be confirmed for import', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(files, (call) async {
      if (call.method == 'storedScoreFolderTree') {
        return 'content://tree/scores';
      }
      throw PlatformException(code: 'folder_list_failed');
    });
    await tester.pumpWidget(
      MaterialApp(home: FolderPickerPage(picker: FilePickerService())),
    );
    await tester.pumpAndSettle();
    expect(find.text('无法读取所选目录，可能需要重新授权。'), findsOneWidget);
    final confirm = confirmButton(tester);
    expect(confirm.onPressed, isNull);
  });

  testWidgets('system back waits for folder import to complete', (
    tester,
  ) async {
    final completion = Completer<List<String>>();
    messenger.setMockMethodCallHandler(files, (call) async {
      switch (call.method) {
        case 'storedScoreFolderTree':
          return 'content://tree/scores';
        case 'listScoreFolderContents':
          return {
            'folders': <Object>[],
            'scores': ['score.mscx'],
          };
        case 'importScoreFolder':
          return completion.future;
      }
      return null;
    });
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Scaffold()),
    );
    final result = navigator.currentState!.push<List<String>>(
      MaterialPageRoute(
        builder: (_) => FolderPickerPage(picker: FilePickerService()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认目录'));
    await tester.pump();
    await navigator.currentState!.maybePop();
    await tester.pump();
    expect(find.text('正在导入'), findsOneWidget);
    completion.complete(['/imports/score.mscx']);
    await tester.pumpAndSettle();
    expect(await result, ['/imports/score.mscx']);
  });
}
