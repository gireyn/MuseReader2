import 'dart:typed_data';

import 'score_document.dart';

/// Lightweight data used by the library before a score is opened.
///
/// A full [ScoreDocument] can contain every rendered page plus thousands of
/// playback events. Keeping that payload optional prevents app startup from
/// reopening and laying out every imported score just to build the library.
class ScoreLibraryEntry {
  const ScoreLibraryEntry({
    required this.sourcePath,
    required this.fileName,
    required this.format,
    required this.title,
    required this.composer,
    this.pageCount,
    this.durationUs,
    this.coverBytes,
    this.document,
    this.assetPath,
  });

  factory ScoreLibraryEntry.placeholder(String sourcePath) {
    final fileName = scoreFileName(sourcePath);
    return ScoreLibraryEntry(
      sourcePath: sourcePath,
      fileName: fileName,
      format: scoreFormatForPath(sourcePath),
      title: scoreDisplayName(fileName),
      composer: '',
    );
  }

  factory ScoreLibraryEntry.fromDocument(
    ScoreDocument document, {
    Uint8List? coverBytes,
    String? assetPath,
  }) {
    return ScoreLibraryEntry(
      sourcePath: document.sourcePath,
      fileName: document.fileName,
      format: document.format,
      title: document.title,
      composer: document.composer,
      pageCount: document.pages.length,
      durationUs: document.durationUs,
      coverBytes:
          coverBytes ??
          (document.pages.isEmpty ? null : document.pages.first.imageBytes),
      document: document,
      assetPath: assetPath,
    );
  }

  factory ScoreLibraryEntry.bundledDemo() {
    const assetPath = 'assets/demo/reader-demo.mscx';
    return const ScoreLibraryEntry(
      sourcePath: assetPath,
      fileName: 'reader-demo.mscx',
      format: ScoreFormat.mscx,
      title: 'MuseReader Demo',
      composer: 'MuseReader sample',
      pageCount: 1,
      durationUs: 16000000,
      assetPath: assetPath,
    );
  }

  final String sourcePath;
  final String fileName;
  final ScoreFormat format;
  final String title;
  final String composer;
  final int? pageCount;
  final int? durationUs;
  final Uint8List? coverBytes;
  final ScoreDocument? document;
  final String? assetPath;

  bool get isBundled => assetPath != null;
}

String scoreFileName(String path) => path.replaceAll('\\', '/').split('/').last;

ScoreFormat scoreFormatForPath(String path) =>
    path.toLowerCase().endsWith('.mscz') ? ScoreFormat.mscz : ScoreFormat.mscx;

String scoreDisplayName(String fileName) {
  final extensionIndex = fileName.lastIndexOf('.');
  final stem = extensionIndex > 0
      ? fileName.substring(0, extensionIndex)
      : fileName;
  final withoutImportPrefix = stem.replaceFirst(RegExp(r'^\d+(?:_\d+)?_'), '');
  return withoutImportPrefix.isEmpty ? stem : withoutImportPrefix;
}
