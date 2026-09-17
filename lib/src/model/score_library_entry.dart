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

  /// True for an audio file played by the platform media player instead of an
  /// engraved MuseScore document.
  bool get isAudio => format == ScoreFormat.audio;

  /// Copy carrying metadata read from the file itself — audio tags or the
  /// MuseScore title/composer read without engraving the score.
  ScoreLibraryEntry withMetadata({
    String? title,
    String? composer,
    int? durationUs,
  }) {
    return ScoreLibraryEntry(
      sourcePath: sourcePath,
      fileName: fileName,
      format: format,
      title: title == null || title.isEmpty ? this.title : title,
      composer: composer == null || composer.isEmpty ? this.composer : composer,
      pageCount: pageCount,
      durationUs: durationUs ?? this.durationUs,
      coverBytes: coverBytes,
      document: document,
      assetPath: assetPath,
    );
  }
}

String scoreFileName(String path) => path.replaceAll('\\', '/').split('/').last;

/// Audio containers handed to the platform media player. Anything the device
/// cannot decode reports a load error instead of crashing.
const audioFileExtensions = <String>{
  'mp3',
  'wav',
  'wave',
  'ogg',
  'oga',
  'opus',
  'flac',
  'm4a',
  'aac',
  'mp4',
  'm4b',
  'wma',
  'aif',
  'aiff',
  'amr',
  '3gp',
};

String fileExtension(String path) {
  final normalized = path.toLowerCase();
  final slash = normalized.lastIndexOf('/');
  final dot = normalized.lastIndexOf('.');
  return dot > slash && dot >= 0 ? normalized.substring(dot + 1) : '';
}

bool isScorePath(String path) {
  final extension = fileExtension(path);
  return extension == 'mscx' || extension == 'mscz';
}

bool isAudioPath(String path) =>
    audioFileExtensions.contains(fileExtension(path));

/// Every file kind the library accepts (MuseScore scores and audio files).
bool isSupportedMediaPath(String path) =>
    isScorePath(path) || isAudioPath(path);

ScoreFormat scoreFormatForPath(String path) {
  final extension = fileExtension(path);
  if (extension == 'mscz') return ScoreFormat.mscz;
  if (extension == 'mscx') return ScoreFormat.mscx;
  return isAudioPath(path) ? ScoreFormat.audio : ScoreFormat.mscx;
}

/// Uppercase badge for a library card ("MSCZ", "MP3", …).
String mediaFormatLabel(String path) => fileExtension(path).toUpperCase();

String scoreDisplayName(String fileName) {
  final extensionIndex = fileName.lastIndexOf('.');
  final stem = extensionIndex > 0
      ? fileName.substring(0, extensionIndex)
      : fileName;
  final withoutImportPrefix = stem.replaceFirst(RegExp(r'^\d+(?:_\d+)?_'), '');
  return withoutImportPrefix.isEmpty ? stem : withoutImportPrefix;
}

/// Title for a library card or the reader header. With [useInternalTitles] the
/// file's own metadata is used; otherwise the file name (importer prefix and
/// extension stripped).
String libraryDisplayTitle(
  ScoreLibraryEntry entry, {
  required bool useInternalTitles,
}) {
  if (useInternalTitles && entry.title.isNotEmpty) return entry.title;
  return scoreDisplayName(entry.fileName);
}

/// Author line for a library card; empty when internal titles are off (the
/// author is hidden in that mode).
String libraryDisplayAuthor(
  ScoreLibraryEntry entry, {
  required bool useInternalTitles,
}) => useInternalTitles ? entry.composer : '';
