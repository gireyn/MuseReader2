import 'dart:async';

import 'package:flutter/foundation.dart';

import '../model/score_document.dart';
import '../services/muse_score_bridge.dart';

class PlaybackController extends ChangeNotifier {
  PlaybackController(this.document);

  final ScoreDocument document;
  Timer? _timer;
  Stopwatch? _clock;
  int _basePositionUs = 0;
  int _positionUs = 0;
  double _speed = 1.0;
  bool _isPlaying = false;
  bool _cursorVisible = false;
  int? _audioPositionUs;
  bool _audioPositionQueryInFlight = false;
  int _playbackGeneration = 0;

  bool get isPlaying => _isPlaying;
  double get speed => _speed;
  bool get cursorVisible => _cursorVisible;

  int get positionUs {
    if (!_isPlaying || _clock == null) return _positionUs;
    final audioPosition = _audioPositionUs;
    if (audioPosition != null) {
      return audioPosition.clamp(0, durationUs).toInt();
    }
    final elapsed = _clock!.elapsedMicroseconds;
    return (_basePositionUs + elapsed * _speed)
        .round()
        .clamp(0, durationUs)
        .toInt();
  }

  int get positionTick => document.tempoMap.usToTick(positionUs, speed: 1.0);

  ScoreCursorPosition? get cursorPosition =>
      _cursorVisible ? document.cursorForTime(positionUs) : null;

  int get durationUs => document.durationUs;

  double get progress => durationUs == 0 ? 0 : positionUs / durationUs;

  int get currentPage =>
      cursorPosition?.pageIndex ?? document.pageForTime(positionUs);

  int? get currentMeasure {
    final currentUs = positionUs;
    for (final event in document.events) {
      if (currentUs < event.resolvedEndUs(document.tempoMap)) {
        return event.measure;
      }
    }
    if (document.events.isNotEmpty) return document.events.last.measure;

    final tick = positionTick;
    for (final measure in document.measures) {
      if (tick < measure.endTick) return measure.number;
    }
    return document.measures.isEmpty ? null : document.measures.last.number;
  }

  List<int> get activeEventIndexes {
    final indexes = <int>[];
    for (var index = 0; index < document.events.length; index++) {
      final event = document.events[index];
      final startUs = event.resolvedStartUs(document.tempoMap);
      final endUs = event.resolvedEndUs(document.tempoMap);
      if (startUs <= positionUs && positionUs < endUs) indexes.add(index);
    }
    return indexes;
  }

  Future<void> play() async {
    if (durationUs <= 0) return;
    if (positionUs >= durationUs) {
      _positionUs = 0;
    }
    final generation = ++_playbackGeneration;
    _basePositionUs = _positionUs;
    // Keep the fallback clock stopped until the platform has created and
    // primed its audio route. Starting it before the first PCM block is
    // presented makes the cursor run ahead by the output latency.
    _clock = null;
    _audioPositionUs = null;
    _isPlaying = true;
    _cursorVisible = true;
    _timer?.cancel();
    notifyListeners();
    await MuseScoreBridge.startAudio(
      document,
      positionUs: _basePositionUs,
      speed: _speed,
    );
    if (!_isPlaying || generation != _playbackGeneration) return;
    _clock = Stopwatch()..start();
    _startPositionTimer(generation);
    await _syncPosition(generation);
  }

  Future<void> pause() async {
    if (!_isPlaying) return;
    await _syncPosition();
    if (!_isPlaying) return;
    final current = positionUs;
    _playbackGeneration += 1;
    _positionUs = current;
    _isPlaying = false;
    _cursorVisible = false;
    _audioPositionUs = null;
    _clock?.stop();
    _timer?.cancel();
    _timer = null;
    await MuseScoreBridge.stopAudio();
    notifyListeners();
  }

  Future<void> toggle() => _isPlaying ? pause() : play();

  Future<void> restart() async {
    await pause();
    _positionUs = 0;
    _cursorVisible = false;
    notifyListeners();
  }

  Future<void> seekToUs(int microseconds) async {
    final next = microseconds.clamp(0, durationUs).toInt();
    _positionUs = next;
    _audioPositionUs = null;
    _cursorVisible = true;
    if (_isPlaying) {
      final generation = ++_playbackGeneration;
      _basePositionUs = next;
      _clock?.stop();
      _clock = null;
      _timer?.cancel();
      _timer = null;
      await MuseScoreBridge.startAudio(
        document,
        positionUs: next,
        speed: _speed,
      );
      if (_isPlaying && generation == _playbackGeneration) {
        _clock = Stopwatch()..start();
        _startPositionTimer(generation);
        await _syncPosition(generation);
      }
    }
    notifyListeners();
  }

  Future<void> setSpeed(double value) async {
    final next = value.clamp(0.5, 2.0).toDouble();
    if ((next - _speed).abs() < 0.001) return;
    if (_isPlaying) await _syncPosition();
    _speed = next;
    if (_isPlaying) {
      final generation = ++_playbackGeneration;
      _basePositionUs = _positionUs;
      _audioPositionUs = null;
      _clock?.stop();
      _clock = null;
      _timer?.cancel();
      _timer = null;
      await MuseScoreBridge.startAudio(
        document,
        positionUs: _positionUs,
        speed: _speed,
      );
      if (_isPlaying && generation == _playbackGeneration) {
        _clock = Stopwatch()..start();
        _startPositionTimer(generation);
        await _syncPosition(generation);
      }
    }
    notifyListeners();
  }

  void _startPositionTimer(int generation) {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      unawaited(_syncPosition(generation));
    });
  }

  Future<void> _syncPosition([int? expectedGeneration]) async {
    if (!_isPlaying) return;
    final generation = expectedGeneration ?? _playbackGeneration;
    if (generation != _playbackGeneration || _audioPositionQueryInFlight) {
      return;
    }
    _audioPositionQueryInFlight = true;
    try {
      final reported = await MuseScoreBridge.audioPositionUs();
      if (!_isPlaying || generation != _playbackGeneration) return;

      // A missing track means the platform clock is unavailable (or has just
      // finished). Rebase the local fallback at the last reported position so
      // a temporary query gap cannot introduce a jump.
      if (reported == null && _audioPositionUs != null) {
        _positionUs = _audioPositionUs!.clamp(0, durationUs).toInt();
        _basePositionUs = _positionUs;
        _clock = Stopwatch()..start();
      }
      _audioPositionUs = reported?.clamp(0, durationUs).toInt();

      final next = positionUs;
      if (next >= durationUs) {
        _positionUs = durationUs;
        _isPlaying = false;
        _cursorVisible = false;
        _audioPositionUs = null;
        _clock?.stop();
        _timer?.cancel();
        _timer = null;
        _playbackGeneration += 1;
        unawaited(MuseScoreBridge.stopAudio());
      } else {
        _positionUs = next;
      }
      notifyListeners();
    } finally {
      _audioPositionQueryInFlight = false;
    }
  }

  @override
  void dispose() {
    _playbackGeneration += 1;
    _timer?.cancel();
    _clock?.stop();
    unawaited(MuseScoreBridge.stopAudio());
    super.dispose();
  }
}

String formatScoreDuration(int microseconds) {
  // Truncate sub-second values: the transport clock advances continuously,
  // while the reader intentionally presents a stable, whole-second label.
  final totalSeconds =
      (microseconds < 0 ? 0 : microseconds) ~/ Duration.microsecondsPerSecond;
  final seconds = totalSeconds % 60;
  final secondLabel = seconds.toString().padLeft(2, '0');
  if (totalSeconds >= Duration.secondsPerHour) {
    final hours = totalSeconds ~/ Duration.secondsPerHour;
    final minutes = (totalSeconds ~/ Duration.secondsPerMinute) % 60;
    return '$hours:${minutes.toString().padLeft(2, '0')}:$secondLabel';
  }
  final minutes = totalSeconds ~/ Duration.secondsPerMinute;
  return '$minutes:$secondLabel';
}
