import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../model/score_document.dart';

/// Contract between Flutter and the required mobile MuseScore C++ core.
///
/// Non-mobile tests may run without the platform channel, but Android and iOS
/// product builds fail closed when the native renderer is unavailable.
class MuseScoreBridge {
  MuseScoreBridge._();

  static const _channel = MethodChannel('com.musereader/musescore_engine');
  static const _documentCacheVersion = 1;
  static const _documentCacheSuffix = '.musereader-document-v1.json.gz';
  // MuseScore uses an unsigned-byte playback channel.  It may allocate more
  // than the sixteen wire-MIDI channels for articulation/instrument states.
  static const _maxPlaybackChannel = 255;

  static Future<ScoreDocument?> open(String path, {String? sourcePath}) async {
    final cachedPayload = await _readDocumentCache(path);
    if (cachedPayload != null) {
      try {
        return _documentFromMap(cachedPayload, sourcePath ?? path);
      } on Object {
        // A stale or partial cache falls through to the native renderer and is
        // replaced after a successful open.
      }
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('open', {'path': path});
      if (raw is! Map) return null;
      final available = raw['available'] == true;
      if (!available) return null;
      final payload = raw['document'];
      if (payload is! Map) {
        throw MuseScoreBridgeException(
          _asString(raw['error'], fallback: 'MuseScore 原生核心没有返回谱面文档。'),
        );
      }
      final document = _documentFromMap(payload, sourcePath ?? path);
      await _writeDocumentCache(path, payload);
      return document;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      throw MuseScoreBridgeException(error.message ?? 'MuseScore 原生通道调用失败。');
    }
  }

  static Future<Map<dynamic, dynamic>?> _readDocumentCache(String path) async {
    try {
      final sourceStat = await File(path).stat();
      if (sourceStat.type != FileSystemEntityType.file) return null;
      final cachePath = '$path$_documentCacheSuffix';
      if (!await File(cachePath).exists()) return null;
      final decoded = await Isolate.run<Object?>(() async {
        final compressed = await File(cachePath).readAsBytes();
        final jsonBytes = gzip.decode(compressed);
        return jsonDecode(utf8.decode(jsonBytes));
      });
      if (decoded is! Map ||
          decoded['version'] != _documentCacheVersion ||
          decoded['sourceLength'] != sourceStat.size ||
          decoded['sourceModifiedUs'] !=
              sourceStat.modified.microsecondsSinceEpoch) {
        return null;
      }
      final document = decoded['document'];
      return document is Map ? document : null;
    } on Object {
      return null;
    }
  }

  static Future<void> _writeDocumentCache(
    String path,
    Map<dynamic, dynamic> payload,
  ) async {
    try {
      final sourceStat = await File(path).stat();
      if (sourceStat.type != FileSystemEntityType.file) return;
      final cachePath = '$path$_documentCacheSuffix';
      final sourceLength = sourceStat.size;
      final sourceModifiedUs = sourceStat.modified.microsecondsSinceEpoch;
      await Isolate.run(() async {
        final wrapper = <String, Object>{
          'version': _documentCacheVersion,
          'sourceLength': sourceLength,
          'sourceModifiedUs': sourceModifiedUs,
          'document': payload,
        };
        final encoded = utf8.encode(
          jsonEncode(
            wrapper,
            toEncodable: (value) {
              if (value is Uint8List) return base64Encode(value);
              if (value is ByteData) {
                return base64Encode(
                  value.buffer.asUint8List(
                    value.offsetInBytes,
                    value.lengthInBytes,
                  ),
                );
              }
              throw JsonUnsupportedObjectError(value);
            },
          ),
        );
        final temporary = File('$cachePath.tmp');
        await temporary.writeAsBytes(gzip.encode(encoded), flush: true);
        final target = File(cachePath);
        if (await target.exists()) await target.delete();
        await temporary.rename(cachePath);
      });
    } on Object {
      // Rendering succeeded, so persistence is an optional optimization.
    }
  }

  static Future<void> startAudio(
    ScoreDocument document, {
    required int positionUs,
    required double speed,
  }) async {
    try {
      await _channel.invokeMethod<void>('startAudio', {
        'positionUs': positionUs,
        'speed': speed,
        'events': document.nativeAudioEvents,
      });
    } on MissingPluginException {
      // A compatibility build can still show deterministic progress.
    } on PlatformException {
      // Audio is best effort until the native MuseScore synth is linked.
    }
  }

  static Future<void> stopAudio() async {
    try {
      await _channel.invokeMethod<void>('stopAudio');
    } on MissingPluginException {
      // Optional platform capability.
    } on PlatformException {
      // Optional platform capability.
    }
  }

  /// Returns the mobile audio sink's current presentation position.
  ///
  /// Audio output is allowed to have a device/AVD buffer, so a wall-clock
  /// estimate on the Flutter side can run ahead of what is audible. Platforms
  /// Android uses AudioTrack timestamps and iOS accounts for AVAudioEngine's
  /// presentation latency. Platforms without this optional method return
  /// `null`, preserving the local-clock fallback used by tests and desktop.
  static Future<int?> audioPositionUs() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('audioPositionUs');
      return _asIntOrNull(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static ScoreDocument _documentFromMap(
    Map<dynamic, dynamic> map,
    String path,
  ) {
    final division = _asInt(map['division'], fallback: 480);
    if (division <= 0) {
      throw const MuseScoreBridgeException('MuseScore 返回了无效的 tick division。');
    }
    final title = _asString(map['title'], fallback: _fileName(path));
    final composer = _asString(map['composer']);
    final tempoPoints = <TempoPoint>[];
    final rawTempos = map['tempos'];
    if (rawTempos is Iterable) {
      for (final raw in rawTempos) {
        if (raw is Map) {
          tempoPoints.add(
            TempoPoint(
              tick: _asInt(raw['tick']),
              quarterNotesPerSecond: _asDouble(
                raw['qps'],
                fallback: _asDouble(raw['bpm'], fallback: 120.0) / 60.0,
              ),
            ),
          );
        }
      }
    }
    final tempoMap = TempoMap(division: division, points: tempoPoints);

    final measures = <ScoreMeasure>[];
    final rawMeasures = map['measures'];
    if (rawMeasures is Iterable) {
      for (final raw in rawMeasures) {
        if (raw is Map) {
          measures.add(
            ScoreMeasure(
              number: _asInt(raw['number'], fallback: measures.length + 1),
              startTick: _asInt(raw['startTick']),
              endTick: _asInt(raw['endTick'], fallback: division * 4),
            ),
          );
        }
      }
    }

    final events = <PlaybackEvent>[];
    final rawEvents = map['events'];
    if (rawEvents is Iterable) {
      for (final raw in rawEvents) {
        if (raw is Map) {
          events.add(
            PlaybackEvent(
              startTick: _asInt(raw['startTick']),
              endTick: _asInt(raw['endTick']),
              startUs: _asIntOrNull(raw['startUs']),
              endUs: _asIntOrNull(raw['endUs']),
              sourceTick: _asIntOrNull(raw['sourceTick']),
              clickStartUs: _asIntOrNull(raw['clickStartUs']),
              pitch: _asInt(raw['pitch'], fallback: 60),
              tuning: _asTuning(raw),
              noteheadFilled: _asBool(
                raw['noteheadFilled'] ?? raw['noteHeadFilled'] ?? raw['filled'],
                fallback: true,
              ),
              velocity: _asInt(
                raw['velocity'],
                fallback: 80,
              ).clamp(1, 127).toInt(),
              staff: _asInt(raw['staff']),
              voice: _asInt(raw['voice']),
              measure: _asInt(raw['measure'], fallback: 1),
              channel: _asInt(
                raw['channel'],
              ).clamp(0, _maxPlaybackChannel).toInt(),
              program: _asInt(raw['program']).clamp(0, 127).toInt(),
              bank: _asInt(raw['bank']).clamp(0, 16383).toInt(),
              pageIndex: _asIntOrNull(raw['page']),
              pageRect: _scoreRectOrNull(raw['rect']),
              highlights: _scorePlaybackHighlights(
                raw['highlightRects'] ?? raw['highlights'],
              ),
              noteheadImageBytes: _bytesOrNull(
                raw['noteheadImage'] ?? raw['noteHeadImage'],
              ),
              noteheadRect: _scoreRectOrNull(
                raw['noteheadRect'] ?? raw['noteHeadRect'],
              ),
              cursorRect: _scoreRectOrNull(raw['cursor']),
              cursorEndX: _asDoubleOrNull(raw['cursorEndX']),
            ),
          );
        }
      }
    }
    events.sort((a, b) {
      final timeOrder = a
          .resolvedStartUs(tempoMap)
          .compareTo(b.resolvedStartUs(tempoMap));
      if (timeOrder != 0) return timeOrder;
      final tickOrder = a.startTick.compareTo(b.startTick);
      if (tickOrder != 0) return tickOrder;
      return a.pitch.compareTo(b.pitch);
    });

    final audioEvents = <Map<String, Object>>[];
    final rawAudioEvents = map['audioEvents'];
    if (rawAudioEvents is Iterable) {
      for (final raw in rawAudioEvents) {
        if (raw is! Map) continue;
        final normalized = <String, Object>{};
        for (final entry in raw.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key is String && value != null) {
            normalized[key] = value;
          }
        }
        if (normalized.isNotEmpty) {
          audioEvents.add(Map.unmodifiable(normalized));
        }
      }
    }

    final pages = <ScorePage>[];
    final rawPages = map['pages'];
    if (rawPages is Iterable) {
      for (var index = 0; index < rawPages.length; index++) {
        final raw = rawPages.elementAt(index);
        if (raw is! Map) continue;
        final width = _asDouble(raw['width']);
        final height = _asDouble(raw['height']);
        final imageBytes = _bytesOrNull(raw['image']);
        if (width <= 0 || height <= 0) {
          throw MuseScoreBridgeException('MuseScore 第 ${index + 1} 页尺寸无效。');
        }
        if (imageBytes == null || imageBytes.isEmpty) {
          throw MuseScoreBridgeException('MuseScore 第 ${index + 1} 页缺少完整渲染图像。');
        }
        final noteTargets = <ScoreNoteTarget>[];
        final rawNoteTargets = raw['noteTargets'] ?? raw['notes'];
        if (rawNoteTargets is Iterable) {
          for (final rawTarget in rawNoteTargets) {
            if (rawTarget is Map) {
              final target = _scoreNoteTargetFromMap(rawTarget);
              if (target != null) noteTargets.add(target);
            }
          }
        }
        pages.add(
          ScorePage(
            index: _asInt(raw['index'], fallback: index),
            width: width,
            height: height,
            glyphs: const [],
            imageBytes: imageBytes,
            pixelWidth: _asPositiveIntOrNull(raw['pixelWidth']),
            pixelHeight: _asPositiveIntOrNull(raw['pixelHeight']),
            noteTargets: List.unmodifiable(noteTargets),
          ),
        );
      }
    }
    if (pages.isEmpty) {
      throw const MuseScoreBridgeException('MuseScore 原生核心没有返回任何已渲染页面。');
    }
    final cursorSegments = <ScoreCursorSegment>[];
    final rawCursorSegments = map['cursorSegments'];
    if (rawCursorSegments is Iterable) {
      for (final raw in rawCursorSegments) {
        if (raw is! Map) continue;
        final segment = _cursorSegmentFromMap(raw);
        if (segment != null &&
            segment.pageIndex >= 0 &&
            segment.pageIndex < pages.length) {
          cursorSegments.add(segment);
        }
      }
    }
    cursorSegments.sort((a, b) {
      final tickOrder = a.startTick.compareTo(b.startTick);
      if (tickOrder != 0) return tickOrder;
      final pageOrder = a.pageIndex.compareTo(b.pageIndex);
      if (pageOrder != 0) return pageOrder;
      return a.endTick.compareTo(b.endTick);
    });
    final endTick = _asInt(
      map['endTick'],
      fallback: events.fold<int>(
        0,
        (value, event) => value > event.endTick ? value : event.endTick,
      ),
    );
    final durationUs = _asIntOrNull(map['durationUs']);
    final renderer = _asString(
      map['renderer'],
      fallback: 'MuseScore native core',
    );
    final symbolFont = _asString(map['symbolFont']);
    return ScoreDocument(
      sourcePath: path,
      fileName: _fileName(path),
      format: _extension(path) == 'mscz' ? ScoreFormat.mscz : ScoreFormat.mscx,
      title: title,
      composer: composer,
      division: division,
      tempoMap: tempoMap,
      measures: List.unmodifiable(measures),
      events: List.unmodifiable(events),
      pages: List.unmodifiable(pages),
      endTick: endTick,
      backend: renderer,
      durationUsOverride: durationUs,
      symbolFont: symbolFont.isEmpty ? null : symbolFont,
      renderDpi: _asPositiveIntOrNull(map['renderDpi']),
      cursorSegments: List.unmodifiable(cursorSegments),
      audioEvents: List.unmodifiable(audioEvents),
    );
  }

  static Uint8List? _bytesOrNull(dynamic value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is Iterable) {
      return Uint8List.fromList(value.cast<int>().toList());
    }
    if (value is String) {
      try {
        return base64Decode(value);
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  static ScoreRect? _scoreRectOrNull(dynamic value) {
    if (value is! Map) return null;
    final left = _asDoubleOrNull(value['x']);
    final top = _asDoubleOrNull(value['y']);
    final width = _asDoubleOrNull(value['width']);
    final height = _asDoubleOrNull(value['height']);
    if (left == null ||
        top == null ||
        width == null ||
        height == null ||
        width <= 0 ||
        height <= 0) {
      return null;
    }
    return ScoreRect(left, top, width, height);
  }

  static ScoreNoteTarget? _scoreNoteTargetFromMap(Map<dynamic, dynamic> raw) {
    final rect = _scoreRectOrNull(raw['rect'] ?? raw['noteRect']);
    final sourceTick = _asIntOrNull(raw['sourceTick'] ?? raw['tick']);
    if (rect == null || sourceTick == null || sourceTick < 0) return null;
    return ScoreNoteTarget(
      rect: rect,
      sourceTick: sourceTick,
      clickStartUs: _asIntOrNull(raw['clickStartUs']),
    );
  }

  static List<ScorePlaybackHighlight> _scorePlaybackHighlights(dynamic value) {
    if (value is! Iterable) return const [];
    final highlights = <ScorePlaybackHighlight>[];
    for (final raw in value) {
      if (raw is! Map) continue;
      final pageIndex = _asIntOrNull(raw['page'] ?? raw['pageIndex']);
      final rect = _scoreRectOrNull(raw['rect'] ?? raw);
      if (pageIndex == null || pageIndex < 0 || rect == null) continue;
      highlights.add(ScorePlaybackHighlight(pageIndex: pageIndex, rect: rect));
    }
    return List.unmodifiable(highlights);
  }

  static ScoreCursorSegment? _cursorSegmentFromMap(Map<dynamic, dynamic> raw) {
    final rect =
        _scoreRectOrNull(raw['rect']) ?? _scoreRectOrNull(raw['cursor']);
    if (rect == null) return null;
    final startTick = _asInt(raw['startTick']);
    final endTick = _asInt(raw['endTick'], fallback: startTick);
    final pageIndex = _asInt(raw['page'], fallback: _asInt(raw['pageIndex']));
    final endX = _asDoubleOrNull(raw['endX'] ?? raw['cursorEndX']);
    final startUs = _asIntOrNull(raw['startUs']);
    final endUs = _asIntOrNull(raw['endUs']);
    final hasValidTimeRange =
        startUs != null && endUs != null && endUs > startUs;
    if (endTick <= startTick || (endX != null && !endX.isFinite)) return null;
    return ScoreCursorSegment(
      startTick: startTick,
      endTick: endTick,
      pageIndex: pageIndex,
      rect: rect,
      endX: endX,
      startUs: hasValidTimeRange ? startUs : null,
      endUs: hasValidTimeRange ? endUs : null,
    );
  }

  static int _asInt(dynamic value, {int fallback = 0}) {
    return _asIntOrNull(value) ?? fallback;
  }

  static bool _asBool(dynamic value, {bool fallback = false}) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is num) return value != 0;
    switch ('$value'.trim().toLowerCase()) {
      case 'true':
      case 'yes':
      case 'on':
      case '1':
        return true;
      case 'false':
      case 'no':
      case 'off':
      case '0':
        return false;
      default:
        return fallback;
    }
  }

  static int? _asIntOrNull(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.isFinite ? value.round() : null;
    return int.tryParse('$value');
  }

  static int? _asPositiveIntOrNull(dynamic value) {
    final result = _asIntOrNull(value);
    return result != null && result > 0 ? result : null;
  }

  static double _asDouble(dynamic value, {double fallback = 0}) {
    return _asDoubleOrNull(value) ?? fallback;
  }

  static double? _asDoubleOrNull(dynamic value) {
    if (value == null) return null;
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  static double _asTuning(Map<dynamic, dynamic> raw) {
    // `tuning` is MuseScore's public Note property (in cents).  Accept the
    // `cents` spelling as a compatibility alias for exported/plugin event
    // streams, but always expose one normalized value to the audio backends.
    final value = raw.containsKey('tuning') ? raw['tuning'] : raw['cents'];
    final parsed = _asDoubleOrNull(value);
    if (parsed == null || !parsed.isFinite) return 0.0;
    return parsed.clamp(-1000000.0, 1000000.0).toDouble();
  }

  static String _asString(dynamic value, {String fallback = ''}) {
    final result = '$value'.trim();
    return value == null || result.isEmpty ? fallback : result;
  }

  static String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }
}

class MuseScoreBridgeException implements Exception {
  const MuseScoreBridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}
