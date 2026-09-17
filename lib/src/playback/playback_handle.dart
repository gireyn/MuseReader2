import 'package:flutter/foundation.dart';

/// Transport-facing surface shared by the two playback backends:
/// engraving playback (MuseScore + FluidSynth) and audio files
/// (platform media player).
abstract class PlaybackHandle extends ChangeNotifier {
  bool get isPlaying;

  /// Presentation position in microseconds.
  int get positionUs;

  /// Total length in microseconds (0 when unknown).
  int get durationUs;

  double get progress;

  Future<void> play();
  Future<void> pause();
  Future<void> toggle();

  /// Stop and rewind to the start (stays paused, like the score transport).
  Future<void> restart();

  Future<void> seekToUs(int microseconds);
}
