import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Title/composer read straight out of a MuseScore file without engraving it.
///
/// `MSCX` is plain XML and `MSCZ` is a zip containing one `MSCX`; MuseScore
/// stores the work title and composer in `<metaTag>` elements (and, for older
/// exports, in a title text frame). This is a cheap background read used to
/// give the library internal titles for scores that were never opened.
class ScoreMetadata {
  const ScoreMetadata({this.title, this.composer});

  final String? title;
  final String? composer;

  bool get isEmpty => (title ?? '').isEmpty && (composer ?? '').isEmpty;
}

class ScoreMetadataReader {
  /// Reads the metadata of [path]; never throws.
  Future<ScoreMetadata> read(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return const ScoreMetadata();
      final extension = path.toLowerCase();
      if (extension.endsWith('.mscz')) {
        return _fromMscz(await file.readAsBytes());
      }
      return _fromXml(await file.readAsString());
    } on Object {
      return const ScoreMetadata();
    }
  }

  ScoreMetadata _fromMscz(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes, verify: false);
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        final name = entry.name.toLowerCase();
        if (!name.endsWith('.mscx')) continue;
        final content = entry.content;
        final data = content is List<int>
            ? Uint8List.fromList(content)
            : Uint8List(0);
        if (data.isEmpty) continue;
        return _fromXml(utf8.decode(data, allowMalformed: true));
      }
    } on Object {
      // A damaged archive simply has no readable metadata.
    }
    return const ScoreMetadata();
  }

  ScoreMetadata _fromXml(String xml) {
    final title = _metaTag(xml, 'workTitle') ?? _textFrameTitle(xml);
    final composer = _metaTag(xml, 'composer') ?? _textFrameComposer(xml);
    return ScoreMetadata(title: _clean(title), composer: _clean(composer));
  }

  /// `<metaTag name="workTitle">Title</metaTag>`
  String? _metaTag(String xml, String name) {
    final match = RegExp(
      '<metaTag\\s+name="${RegExp.escape(name)}"\\s*>([^<]*)</metaTag>',
      caseSensitive: false,
    ).firstMatch(xml);
    return match?.group(1);
  }

  /// Older scores keep the title in the first text frame of the first staff.
  String? _textFrameTitle(String xml) {
    final match = RegExp(
      '<VBox>.*?<Text>.*?<text>([^<]*)</text>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(xml);
    return match?.group(1);
  }

  String? _textFrameComposer(String xml) {
    final match = RegExp(
      '<VBox>.*?<Text>.*?<text>[^<]*</text>.*?<text>([^<]*)</text>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(xml);
    return match?.group(1);
  }

  String? _clean(String? value) {
    if (value == null) return null;
    final trimmed = value
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
