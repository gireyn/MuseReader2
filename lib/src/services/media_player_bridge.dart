import 'dart:io';

import 'package:flutter/services.dart';

/// Result of preparing one audio file for playback.
class MediaLoadResult {
  const MediaLoadResult({
    required this.available,
    this.durationUs,
    this.title,
    this.artist,
    this.error,
  });

  final bool available;
  final int? durationUs;
  final String? title;
  final String? artist;
  final String? error;
}

/// Platform media player (Android `MediaPlayer`) used for audio files:
/// mp3/wav/ogg/flac/m4a/… — the same backend the companion mscz_an_Audio
/// player uses. Scores keep using the MuseScore/FluidSynth bridge.
class MediaPlayerBridge {
  MediaPlayerBridge._();

  static const _channel = MethodChannel('com.musereader/media');

  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// Prepare [path] for playback and report its duration and tags.
  static Future<MediaLoadResult> load(String path) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('load', {
        'path': path,
      });
      if (raw == null) {
        return const MediaLoadResult(available: false);
      }
      final available = raw['available'] == true;
      final durationMs = raw['durationMs'];
      return MediaLoadResult(
        available: available,
        durationUs: durationMs is num
            ? (durationMs.toDouble() * 1000).round()
            : null,
        title: raw['title'] as String?,
        artist: raw['artist'] as String?,
        error: raw['error'] as String?,
      );
    } on MissingPluginException {
      return const MediaLoadResult(available: false, error: '此平台没有音频播放支持。');
    } on PlatformException catch (error) {
      return MediaLoadResult(available: false, error: error.message);
    } on Object catch (error) {
      return MediaLoadResult(available: false, error: '$error');
    }
  }

  static Future<void> play() => _invoke('play');
  static Future<void> pause() => _invoke('pause');
  static Future<void> stop() => _invoke('stop');

  static Future<void> seek(int positionUs) async {
    final milliseconds = positionUs < 0 ? 0 : positionUs ~/ 1000;
    try {
      await _channel.invokeMethod<void>('seek', {'positionMs': milliseconds});
    } on MissingPluginException {
      // Audio is best effort on platforms without the media bridge.
    } on PlatformException {
      // Seeking beyond the end simply stops.
    }
  }

  /// Current presentation position, or null when no player is running.
  static Future<int?> positionUs() async {
    try {
      final milliseconds = await _channel.invokeMethod<num>('position');
      if (milliseconds == null) return null;
      return (milliseconds.toDouble() * 1000).round();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> isPlaying() async {
    try {
      return await _channel.invokeMethod<bool>('isPlaying') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Optional platform capability.
    } on PlatformException {
      // Optional platform capability.
    }
  }
}
