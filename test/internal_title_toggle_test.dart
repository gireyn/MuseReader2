import 'package:flutter_test/flutter_test.dart';

import 'support/library_fakes.dart';

/// 内部标题 toggle: off (the default) shows file names and hides the author;
/// on shows the files' own metadata titles/authors, and the choice persists.
void main() {
  const pathA = '/library/alpha.mscx';
  const pathB = '/library/beta.mscx';

  tearDown(clearChannelMocks);

  testWidgets(
    'default off: cards show file names, hide the author and the reader header follows',
    (tester) async {
      await pumpFakeLibrary(
        tester,
        imports: const [pathA],
        documents: {pathA: fakeScoreDocument(pathA, 'Alpha Title')},
      );

      expect(find.text('内部标题'), findsOneWidget);
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('Alpha Title'), findsNothing);
      expect(find.text('Fixture Composer'), findsNothing);

      await tester.tap(find.text('alpha'));
      await tester.pumpAndSettle();
      expect(readerShowsTitle('alpha'), isTrue);
      expect(readerShowsTitle('Alpha Title'), isFalse);
      await tester.tap(find.byTooltip('返回谱面库'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('turning it on shows internal titles and authors, and persists', (
    tester,
  ) async {
    String? writtenKey;
    bool? writtenValue;
    await pumpFakeLibrary(
      tester,
      imports: const [pathA, pathB],
      documents: {
        pathA: fakeScoreDocument(pathA, 'Alpha Title'),
        pathB: fakeScoreDocument(pathB, 'Beta Title'),
      },
      onPreferenceWritten: (key, value) {
        writtenKey = key;
        writtenValue = value;
      },
    );

    await tester.tap(find.text('内部标题'));
    await tester.pumpAndSettle();

    expect(writtenKey, 'use_internal_titles');
    expect(writtenValue, isTrue);
    expect(find.text('Alpha Title'), findsOneWidget);
    expect(find.text('Beta Title'), findsOneWidget);
    expect(find.text('Fixture Composer'), findsNWidgets(2));
    expect(find.text('alpha'), findsNothing);

    // The reader header follows as well.
    await tester.tap(find.text('Beta Title'));
    await tester.pumpAndSettle();
    expect(readerShowsTitle('Beta Title'), isTrue);
    await tester.tap(find.byTooltip('返回谱面库'));
    await tester.pumpAndSettle();

    // Off again: back to file names and no author.
    await tester.tap(find.text('内部标题'));
    await tester.pumpAndSettle();
    expect(writtenValue, isFalse);
    expect(find.text('Alpha Title'), findsNothing);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('Fixture Composer'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stored preference restores the internal-title mode', (
    tester,
  ) async {
    await pumpFakeLibrary(
      tester,
      imports: const [pathA],
      documents: {pathA: fakeScoreDocument(pathA, 'Alpha Title')},
      storedBooleanPreference: true,
    );

    expect(find.text('Alpha Title'), findsOneWidget);
    expect(find.text('Fixture Composer'), findsOneWidget);
    expect(find.text('alpha'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
