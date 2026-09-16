import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../model/score_document.dart';
import 'muse_score_bridge.dart';
import 'score_parser.dart';

class ScoreRepository {
  ScoreRepository({ScoreParser? parser}) : _parser = parser ?? ScoreParser();

  /// Mobile builds fail closed instead of silently using compatibility layout.
  static const _requireNativeBuild = bool.fromEnvironment(
    'MUSE_READER_REQUIRE_NATIVE',
    defaultValue: true,
  );
  static bool get requireNative =>
      _requireNativeBuild && (Platform.isAndroid || Platform.isIOS);

  final ScoreParser _parser;

  Future<ScoreDocument> open(String path) async {
    final nativeDocument = await MuseScoreBridge.open(path);
    if (nativeDocument != null) return nativeDocument;
    if (requireNative) {
      throw const ScoreParseException('此版本要求 MuseScore 原生核心，但当前平台没有加载该核心。');
    }
    return _parser.parseFile(path);
  }

  Future<ScoreDocument> openAsset(String assetPath) async {
    final bytes = await rootBundle.load(assetPath);
    final data = bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final nativePath = await _materializeAsset(assetPath, data);
        final nativeDocument = await MuseScoreBridge.open(
          nativePath,
          sourcePath: assetPath,
        );
        if (nativeDocument != null) return nativeDocument;
      } on FileSystemException catch (error) {
        if (requireNative) {
          throw ScoreParseException(
            '无法为 MuseScore 原生核心准备内置谱面：${error.message}',
          );
        }
      }
    }
    if (requireNative) {
      throw const ScoreParseException('此版本要求 MuseScore 原生核心，但当前平台没有加载该核心。');
    }
    return _parser.parseBytes(data, assetPath);
  }

  Future<String> _materializeAsset(String assetPath, Uint8List bytes) async {
    final fileName = assetPath
        .replaceAll('\\', '/')
        .split('/')
        .last
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final directory = Directory(
      '${Directory.systemTemp.path}/muse_reader/bundled_scores',
    );
    await directory.create(recursive: true);
    final file = File('${directory.path}/$fileName');
    if (await file.exists() && await file.length() == bytes.length) {
      final existing = await file.readAsBytes();
      if (listEquals(existing, bytes)) return file.path;
    }
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
