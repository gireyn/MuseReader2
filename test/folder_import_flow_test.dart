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
    expect(find.text('MuseReader Demo'), findsOneWidget);
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
    expect(find.text('MuseReader Demo'), findsNothing);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('2 份谱面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
