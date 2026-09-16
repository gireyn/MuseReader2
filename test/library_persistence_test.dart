import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/main.dart';
import 'package:muse_reader/src/services/file_picker_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const filesChannel = MethodChannel('com.musereader/files');
  const engineChannel = MethodChannel('com.musereader/musescore_engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(filesChannel, null);
    messenger.setMockMethodCallHandler(engineChannel, null);
  });

  testWidgets('restores persisted imports without opening them at startup', (
    tester,
  ) async {
    final directory = await tester.runAsync(() async {
      final temporary = await Directory.systemTemp.createTemp(
        'muse_reader_library_widget_test.',
      );
      await File(
        '${temporary.path}/persisted.mscx',
      ).writeAsString('<museScore/>', flush: true);
      return temporary;
    });
    addTearDown(() => directory!.delete(recursive: true));
    final sourcePath = '${directory!.path}/persisted.mscx';
    var listed = false;
    var openCalls = 0;
    messenger.setMockMethodCallHandler(filesChannel, (call) async {
      expect(call.method, 'listImportedScoreFiles');
      listed = true;
      return [sourcePath];
    });
    messenger.setMockMethodCallHandler(engineChannel, (call) async {
      expect(call.method, 'open');
      openCalls++;
      return {
        'available': true,
        'document': {
          'title': 'Persisted score',
          'composer': 'MuseReader',
          'division': 480,
          'pages': [
            {
              'index': 0,
              'width': 100.0,
              'height': 100.0,
              'image':
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            },
          ],
          'events': const [],
          'measures': const [],
          'endTick': 0,
        },
      };
    });

    await tester.pumpWidget(const MuseReaderApp());
    await tester.pumpAndSettle();

    expect(listed, isTrue);
    expect(openCalls, 0);
    expect(find.text('persisted'), findsOneWidget);

    final scoreCard = find.ancestor(
      of: find.text('persisted'),
      matching: find.byType(InkWell),
    );
    expect(scoreCard, findsOneWidget);
    final onOpen = tester.widget<InkWell>(scoreCard).onTap!;
    await tester.runAsync(() async {
      onOpen();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (openCalls == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(openCalls, 1);
    expect(find.text('Persisted score'), findsOneWidget);
  });

  test('filters non-score files returned by the platform', () async {
    messenger.setMockMethodCallHandler(filesChannel, (call) async {
      expect(call.method, 'listImportedScoreFiles');
      return [
        '/data/user/0/icu.ringona.musereader/files/score.MSCX',
        '/data/user/0/icu.ringona.musereader/files/notes.txt',
        42,
      ];
    });

    expect(await FilePickerService().listImportedScoreFiles(), [
      '/data/user/0/icu.ringona.musereader/files/score.MSCX',
    ]);
  });
}
