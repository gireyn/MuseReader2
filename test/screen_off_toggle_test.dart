import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/model/score_library_entry.dart';
import 'package:muse_reader/src/playback/advance_policy.dart';
import 'package:muse_reader/src/playback/score_queue.dart';
import 'package:muse_reader/src/services/loading_priority.dart';
import 'package:muse_reader/src/ui/reader_page.dart';
import 'package:muse_reader/src/ui/toggle_button.dart';

import 'support/library_fakes.dart';

/// 熄屏不打断下一首: default on, remembered afterwards, and the rule it applies.
void main() {
  tearDown(clearChannelMocks);

  group('advance policy', () {
    test('screen off suppresses the advance only when the setting is off', () {
      expect(
        suppressAdvanceForScreenOff(
          advanceWhenScreenOff: true,
          screenOn: false,
        ),
        isFalse,
      );
      expect(
        suppressAdvanceForScreenOff(
          advanceWhenScreenOff: false,
          screenOn: false,
        ),
        isTrue,
      );
      // Screen on: the queue advances normally either way.
      expect(
        suppressAdvanceForScreenOff(
          advanceWhenScreenOff: false,
          screenOn: true,
        ),
        isFalse,
      );
    });
  });

  group('reader toggle', () {
    Future<void> pumpReader(
      WidgetTester tester, {
      List<String>? preferenceWrites,
      bool? storedValue,
    }) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(filesChannel, (call) async {
        switch (call.method) {
          case 'getBooleanPreference':
            return storedValue ?? true;
          case 'setBooleanPreference':
            preferenceWrites?.add(
              '${call.arguments['key']}=${call.arguments['value']}',
            );
            return null;
        }
        throw MissingPluginException();
      });

      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final path = '/library/alpha.mscx';
      final queue = ReaderQueue(ids: [path, '/library/beta.mscx']);
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            document: fakeScoreDocument(path, 'Alpha Title'),
            queue: queue,
            loadEntry: (id) async => ScoreLibraryEntry.placeholder(id),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    bool toggleValue(WidgetTester tester) =>
        tester.widget<MuseToggleButton>(find.byType(MuseToggleButton)).value;

    testWidgets('sits under the queue row and is on by default', (
      tester,
    ) async {
      await pumpReader(tester);

      expect(find.text('熄屏不打断下一首'), findsOneWidget);
      expect(toggleValue(tester), isTrue);
      // Below the 上一首/下一首/循环模式 row.
      final queueRow = tester.getTopLeft(find.text('随机（记忆）')).dy;
      final toggleRow = tester.getTopLeft(find.text('熄屏不打断下一首')).dy;
      expect(toggleRow, greaterThan(queueRow));
      expect(tester.takeException(), isNull);
    });

    testWidgets('turning it off is remembered', (tester) async {
      final writes = <String>[];
      await pumpReader(tester, preferenceWrites: writes);

      await tester.tap(find.text('熄屏不打断下一首'));
      await tester.pumpAndSettle();

      expect(toggleValue(tester), isFalse);
      expect(writes, contains('advance_when_screen_off=false'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a stored off value is restored', (tester) async {
      await pumpReader(tester, storedValue: false);

      expect(find.text('熄屏不打断下一首'), findsOneWidget);
      expect(toggleValue(tester), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('熄屏不打断下一首 behaviour', () {
    const pathA = '/library/one.mp3';
    const pathB = '/library/two.mp3';

    Future<void> pumpAudioReader(WidgetTester tester) async {
      mockMediaChannel(screenOn: false);
      await pumpFakeLibrary(
        tester,
        imports: const [pathA, pathB],
        documents: const {},
        warmCache: false,
      );
      await tester.tap(find.text('one'));
      await pumpUntilReader(tester);
      await tester.pumpAndSettle();
    }

    testWidgets('screen off + setting off: the finished piece is kept', (
      tester,
    ) async {
      await pumpAudioReader(tester);
      await tester.tap(find.text('熄屏不打断下一首'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('播放'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The platform reports the end of the audio file.
      await sendPlatformCall(
        tester,
        'com.musereader/controls',
        'mediaCompleted',
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      // Still on the finished piece: no automatic advance while the screen is off.
      expect(readerShowsTitle('one'), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('screen back on preloads the next piece, paused until ▶', (
      tester,
    ) async {
      await pumpAudioReader(tester);
      await tester.tap(find.text('熄屏不打断下一首'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('播放'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await sendPlatformCall(
        tester,
        'com.musereader/controls',
        'mediaCompleted',
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(readerShowsTitle('one'), isTrue);

      // The screen comes back on: the next piece is loaded, still paused.
      mockMediaChannel(screenOn: true);
      await sendPlatformCall(tester, 'com.musereader/controls', 'screenOn');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(readerShowsTitle('two'), isTrue);
      expect(find.byTooltip('播放'), findsOneWidget); // waiting for the click
      expect(find.byTooltip('暂停'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('setting on: the queue advances even with the screen off', (
      tester,
    ) async {
      await pumpAudioReader(tester);

      await tester.tap(find.byTooltip('播放'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await sendPlatformCall(
        tester,
        'com.musereader/controls',
        'mediaCompleted',
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(readerShowsTitle('two'), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('loading order', () {
    test(
      'starts at the bottom-most visible card, goes up, then continues down',
      () {
        const collection = ['/a', '/b', '/c', '/d', '/e', '/f', '/g', '/h'];
        // The last card the sliver built is the bottom-most one on screen.
        expect(
          anchorFirstOrder(anchorPath: '/e', collectionOrder: collection),
          ['/e', '/d', '/c', '/b', '/a', '/f', '/g', '/h'],
        );
        // Viewport at the very top: the anchor is the last visible card.
        expect(
          anchorFirstOrder(anchorPath: '/c', collectionOrder: collection),
          ['/c', '/b', '/a', '/d', '/e', '/f', '/g', '/h'],
        );
        // Viewport at the end: walks back through the whole collection.
        expect(
          anchorFirstOrder(anchorPath: '/h', collectionOrder: collection),
          ['/h', '/g', '/f', '/e', '/d', '/c', '/b', '/a'],
        );
        // No anchor yet (before the first layout): collection order.
        expect(
          anchorFirstOrder(anchorPath: null, collectionOrder: collection),
          collection,
        );
        // An anchor outside the collection is ignored.
        expect(
          anchorFirstOrder(anchorPath: '/zz', collectionOrder: collection),
          collection,
        );
      },
    );
  });

  group('开始随机 loading sign', () {
    testWidgets('shows 正在载入谱面… while the chosen score is prepared', (
      tester,
    ) async {
      const pathA = '/library/alpha.mscx';
      const pathB = '/library/beta.mscx';
      // Cold cache + a gate on the (fake) native render: the chosen score stays
      // pending until the test releases it.
      final gate = Completer<void>();
      await pumpFakeLibrary(
        tester,
        imports: const [pathA, pathB],
        documents: {
          pathA: fakeScoreDocument(pathA, 'Alpha Title'),
          pathB: fakeScoreDocument(pathB, 'Beta Title'),
        },
        warmCache: false,
        repositoryGate: gate.future,
      );

      expect(find.text('正在载入谱面…'), findsNothing);

      await tester.tap(find.text('开始随机'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // The same loading card the reader shows between pieces.
      expect(find.text('正在载入谱面…'), findsOneWidget);

      // Once the score is ready the sign goes away and the reader opens.
      gate.complete();
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.byType(ReaderPage).evaluate().isNotEmpty) break;
      }
      expect(find.byType(ReaderPage), findsOneWidget);
      expect(find.text('正在载入谱面…'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
