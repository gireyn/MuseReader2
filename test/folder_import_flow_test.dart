import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/main.dart';

/// The "打开目录" flow with a mocked files channel: the system grant is
/// answered by the mock, the in-app browser lists the folder, and confirming
/// replaces the whole library collection with the folder's direct scores
/// (the bundled demo disappears, matching "opening a folder replaces the
/// playlist" in the reference player).
void main() {
  testWidgets('folder import replaces the library collection without the demo', (
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
    final imported = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'pickScoreFile':
          return null;
        case 'listImportedScoreFiles':
          return const <String>[];
        case 'storedScoreFolderTree':
          return null;
        case 'pickScoreFolder':
          return 'content://tree/scores';
        case 'listScoreFolderContents':
          return <String, dynamic>{
            'folders': <Map<String, dynamic>>[],
            'scores': const ['alpha.mscx', 'beta.mscz'],
          };
        case 'importScoreFolder':
          imported.addAll(const [
            '/data/user/0/icu.ringona.musereader/files/muse_reader/imports/1750000000000_alpha.mscx',
            '/data/user/0/icu.ringona.musereader/files/muse_reader/imports/1749999999999_beta.mscz',
          ]);
          return List<String>.of(imported);
      }
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const MuseReaderApp());
    await tester.pumpAndSettle();

    // First run: only the bundled demo, with both import actions available.
    expect(find.text('reader-demo'), findsOneWidget);
    expect(find.text('导入谱面'), findsOneWidget);
    expect(find.text('打开目录'), findsOneWidget);

    // Open the in-app folder browser and confirm the root folder.
    await tester.tap(find.text('打开目录'));
    await tester.pumpAndSettle();
    expect(find.text('alpha.mscx'), findsOneWidget);
    expect(find.text('beta.mscz'), findsOneWidget);
    await tester.tap(find.text('确认目录'));
    await tester.pumpAndSettle();

    // The collection is replaced by the folder's scores; the demo is gone.
    expect(imported, hasLength(2));
    expect(find.text('reader-demo'), findsNothing);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('2 份谱面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('确认目录 is on screen before the first listing answers', (
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
    // Hold the first listing open so the browser is observed mid-load: the
    // confirm bar must already be there (disabled), not appear later.
    final listing = Completer<void>();
    var pickerOpened = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'pickScoreFile':
          return null;
        case 'listImportedScoreFiles':
          return const <String>[];
        case 'storedScoreFolderTree':
          return 'content://tree/scores';
        case 'pickScoreFolder':
          pickerOpened = true;
          return 'content://tree/scores';
        case 'listScoreFolderContents':
          await listing.future;
          return <String, dynamic>{
            'folders': <Map<String, dynamic>>[],
            'scores': const ['alpha.mscx'],
          };
      }
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const MuseReaderApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开目录'));
    // Explicit pumps only: the progress bars animate, so the tree never
    // settles while the listing is gated. They stay far inside the non-mobile
    // listing timeout (250 ms), which keeps the browser mid-load instead of
    // letting the gated call time out and end the load.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(pickerOpened, isFalse, reason: 'the stored grant needs no picker');
    expect(find.text('确认目录'), findsOneWidget);
    expect(_confirmButton(tester).enabled, isFalse);

    listing.complete();
    await tester.pumpAndSettle();

    expect(find.text('alpha.mscx'), findsOneWidget);
    expect(_confirmButton(tester).enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the first grant explains the hidden system button', (
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
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'pickScoreFile':
          return null;
        case 'listImportedScoreFiles':
          return const <String>[];
        case 'storedScoreFolderTree':
          return null;
        case 'pickScoreFolder':
          return null;
      }
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const MuseReaderApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开目录'));
    await tester.pumpAndSettle();

    // The browser closes and the library says how to un-stick the picker.
    expect(find.text('确认目录'), findsNothing);
    expect(find.textContaining('USE THIS FOLDER'), findsOneWidget);

    // Let the hint expire before the test ends.
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

/// The 确认目录 button, found through the text it carries so the icon factory
/// constructor (a FilledButton subclass) does not matter.
ButtonStyleButton _confirmButton(WidgetTester tester) => tester
    .widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('确认目录'),
        matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
      ),
    );
