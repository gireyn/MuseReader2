import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../model/score_document.dart';
import '../model/score_library_entry.dart';

/// Persistent, lightweight library metadata and cover thumbnails.
///
/// The cache is deliberately stored beside the app-owned imported score. The
/// native file enumerators only return MSCX/MSCZ files, so these sidecars stay
/// private to the library implementation and need no database migration.
class ScoreLibraryCache {
  static const _schemaVersion = 1;
  static const _indexSuffix = '.musereader-library-v1.json';
  static const _coverSuffix = '.musereader-cover-v1.png';
  static const _coverWidth = 240;

  Future<ScoreLibraryEntry> readOrPlaceholder(String sourcePath) async {
    final placeholder = ScoreLibraryEntry.placeholder(sourcePath);
    try {
      final source = File(sourcePath);
      final sourceStat = await source.stat();
      if (sourceStat.type != FileSystemEntityType.file) return placeholder;

      final indexFile = File('$sourcePath$_indexSuffix');
      if (!await indexFile.exists()) return placeholder;
      final decoded = jsonDecode(await indexFile.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != _schemaVersion ||
          decoded['sourceLength'] != sourceStat.size ||
          decoded['sourceModifiedUs'] !=
              sourceStat.modified.microsecondsSinceEpoch) {
        return placeholder;
      }

      final title = decoded['title'];
      final composer = decoded['composer'];
      final pageCount = decoded['pageCount'];
      final durationUs = decoded['durationUs'];
      if (title is! String ||
          title.isEmpty ||
          composer is! String ||
          pageCount is! int ||
          pageCount <= 0 ||
          durationUs is! int ||
          durationUs < 0) {
        return placeholder;
      }

      Uint8List? coverBytes;
      final coverFile = File('$sourcePath$_coverSuffix');
      if (await coverFile.exists()) {
        final bytes = await coverFile.readAsBytes();
        if (bytes.isNotEmpty) coverBytes = bytes;
      }
      return ScoreLibraryEntry(
        sourcePath: sourcePath,
        fileName: placeholder.fileName,
        format: placeholder.format,
        title: title,
        composer: composer,
        pageCount: pageCount,
        durationUs: durationUs,
        coverBytes: coverBytes,
      );
    } on Object {
      return placeholder;
    }
  }

  Future<ScoreLibraryEntry> write(ScoreDocument document) async {
    if (!_isPersistentFile(document.sourcePath)) {
      return ScoreLibraryEntry.fromDocument(document);
    }

    Uint8List? coverBytes;
    final sourceCover = document.pages.isEmpty
        ? null
        : document.pages.first.imageBytes;
    if (sourceCover != null && sourceCover.isNotEmpty) {
      coverBytes = await _downsampleCover(sourceCover);
    }

    try {
      final sourceStat = await File(document.sourcePath).stat();
      if (sourceStat.type == FileSystemEntityType.file) {
        if (coverBytes != null) {
          await _atomicWriteBytes(
            File('${document.sourcePath}$_coverSuffix'),
            coverBytes,
          );
        }
        final index = <String, Object>{
          'version': _schemaVersion,
          'sourceLength': sourceStat.size,
          'sourceModifiedUs': sourceStat.modified.microsecondsSinceEpoch,
          'title': document.title,
          'composer': document.composer,
          'pageCount': document.pages.length,
          'durationUs': document.durationUs,
        };
        await _atomicWriteBytes(
          File('${document.sourcePath}$_indexSuffix'),
          utf8.encode(jsonEncode(index)),
        );
      }
    } on Object {
      // A cache failure must never prevent a score from opening.
    }
    return ScoreLibraryEntry.fromDocument(document, coverBytes: coverBytes);
  }

  bool _isPersistentFile(String path) =>
      !path.startsWith('assets/') && File(path).existsSync();

  Future<Uint8List?> _downsampleCover(Uint8List source) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(source, targetWidth: _coverWidth);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } on Object {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  Future<void> _atomicWriteBytes(File target, List<int> bytes) async {
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }
}
