import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/media_player_bridge.dart';
import 'playback_handle.dart';

/// Playback of a plain audio file (mp3/wav/ogg/flac/m4a/…) through the
/// platform media player.
///
/// The transport contract matches [PlaybackHandle], so the reader page and the
/// collection queue treat audio items exactly like engraved scores: play,
/// pause, restart, seek, auto-advance at the end, 上一首/下一首, loop modes and
/// the golden-ratio memory all behave the same.
class AudioPlaybackController extends ChangeNotifier implements PlaybackHandle {
  AudioPlaybackController(this.sourcePath, {int? durationUs})
    : _durationUs = durationUs ?? 0;

  final String sourcePath;

  Timer? _timer;
  int _durationUs;
  int _positionUs = 0;
  bool _isPlaying = false;
  bool _loaded = false;
  String? _error;

  /// Preparation problem (unsupported codec, missing file), shown in the
  /// audio panel instead of playing silently.
  String? get error => _error;

  bool get isLoaded => _loaded;

  @override
  bool get isPlaying => _isPlaying;

  @override
  int get positionUs => _positionUs;

  @override
  int get durationUs => _durationUs;

  @override
  double get progress {
    if (_durationUs <= 0) return 0;
    return (_positionUs / _durationUs).clamp(0.0, 1.0);
  }

  /// Prepare the file and learn its real duration (also fills in metadata for
  /// files that were listed without tags).
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final result = await MediaPlayerBridge.load(sourcePath);
    if (result.durationUs != null && result.durationUs! > 0) {
      _durationUs = result.durationUs!;
    }
    _error = result.available ? null : (result.error ?? '无法播放该音频文件。');
    notifyListeners();
  }

  @override
  Future<void> play() async {
    await ensureLoaded();
    if (_error != null) return;
    if (_durationUs > 0 && _positionUs >= _durationUs) {
      _positionUs = 0;
    }
    await MediaPlayerBridge.seek(_positionUs);
    await MediaPlayerBridge.play();
    _isPlaying = true;
    _startTimer();
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    if (!_isPlaying) return;
    _timer?.cancel();
    _timer = null;
    final position = await MediaPlayerBridge.positionUs();
    await MediaPlayerBridge.pause();
    if (position != null) {
      _positionUs = position.clamp(0, _durationUs > 0 ? _durationUs : position);
    }
    _isPlaying = false;
    notifyListeners();
  }

  @override
  Future<void> toggle() => _isPlaying ? pause() : play();

  @override
  Future<void> restart() async {
    _timer?.cancel();
    _timer = null;
    await MediaPlayerBridge.pause();
    _positionUs = 0;
    await MediaPlayerBridge.seek(0);
    _isPlaying = false;
    notifyListeners();
  }

  @override
  Future<void> seekToUs(int microseconds) async {
    final next = microseconds < 0
        ? 0
        : (_durationUs > 0 && microseconds > _durationUs
              ? _durationUs
              : microseconds);
    _positionUs = next;
    await MediaPlayerBridge.seek(next);
    if (_isPlaying) _startTimer();
    notifyListeners();
  }

  /// The platform player reached the end of the file. The reader infers the
  /// "piece ended" transition from playing → stopped at the duration, so the
  /// state is latched exactly like the score controller does.
  void handleCompleted() {
    _timer?.cancel();
    _timer = null;
    _isPlaying = false;
    if (_durationUs > 0) _positionUs = _durationUs;
    notifyListeners();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      unawaited(_syncPosition());
    });
  }

  Future<void> _syncPosition() async {
    if (!_isPlaying) return;
    final position = await MediaPlayerBridge.positionUs();
    final playing = await MediaPlayerBridge.isPlaying();
    if (!_isPlaying) return;
    if (position != null) {
      final limit = _durationUs > 0 ? _durationUs : position;
      _positionUs = position.clamp(0, limit);
    }
    if (!playing) {
      // The platform player stopped on its own (end of file or a system
      // interruption): latch the stopped state once. The reported position
      // can sit a hair below the duration, so snap to the end — the reader
      // infers "piece ended" from stopped-at-duration and advances the queue.
      _timer?.cancel();
      _timer = null;
      _isPlaying = false;
      if (_durationUs > 0 && _positionUs >= _durationUs - 500000) {
        _positionUs = _durationUs;
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    unawaited(MediaPlayerBridge.stop());
    super.dispose();
  }
}
