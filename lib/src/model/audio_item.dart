import 'score_library_entry.dart';

/// One audio file in the reader queue: no engraving, played by the platform
/// media player. Titles follow the 内部标题 display rule: embedded tags when
/// enabled, the file name (import prefix and extension stripped) otherwise.
class AudioItem {
  const AudioItem({
    required this.sourcePath,
    required this.fileName,
    this.title = '',
    this.artist = '',
    this.durationUs,
  });

  factory AudioItem.fromEntry(ScoreLibraryEntry entry) {
    final tagTitle = entry.title == scoreDisplayName(entry.fileName)
        ? ''
        : entry.title;
    return AudioItem(
      sourcePath: entry.sourcePath,
      fileName: entry.fileName,
      title: tagTitle,
      artist: entry.composer,
      durationUs: entry.durationUs,
    );
  }

  final String sourcePath;
  final String fileName;

  /// Embedded tag title ('' when the file has none).
  final String title;

  /// Embedded tag artist ('' when the file has none).
  final String artist;

  final int? durationUs;

  String displayTitle({required bool useInternalTitles}) {
    if (useInternalTitles && title.isNotEmpty) return title;
    return scoreDisplayName(fileName);
  }

  String displayAuthor({required bool useInternalTitles}) =>
      useInternalTitles ? artist : '';
}
