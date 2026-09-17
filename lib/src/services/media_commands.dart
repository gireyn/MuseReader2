import 'package:flutter/services.dart';

/// Commands sent from the Android side of the app.
///
/// Two kinds are used today:
///  * `pause` — the stop action of the playback foreground-service
///    notification, so the reader can pause instead of silently going on;
///  * `memoryPressure` — `Activity.onTrimMemory` levels; the library releases
///    decoded images and hydrated documents to avoid an out-of-memory kill;
///  * `mediaCompleted` — the platform media player reached the end of an
///    audio file, which advances the collection queue just like a score does;
///  * `scoreCompleted` — the FluidSynth renderer finished the score's audio
///    stream. This advances the queue even when the Dart timer that samples the
///    playback position is not being scheduled (screen off / app backgrounded).
class MediaCommands {
  MediaCommands._();

  static const _channel = MethodChannel('com.musereader/controls');

  /// Set by the reader page while it is displayed.
  static Future<void> Function()? onPauseRequested;

  /// Set by the library page (which stays alive for the whole session).
  static void Function(int level)? onMemoryPressure;

  /// Set by the audio playback controller while an audio item is loaded.
  static void Function()? onMediaCompleted;

  /// Set by the reader while a score plays: the embedded FluidSynth renderer
  /// reached the end of the score's audio stream.
  static void Function()? onScoreCompleted;

  /// Screen turned on again (used to preload the next piece after a suppressed
  /// advance). The reader also polls this in its watchdog as a fallback.
  static void Function()? onScreenOn;

  static void attach() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'pause':
          final handler = onPauseRequested;
          if (handler != null) await handler();
          break;
        case 'mediaCompleted':
          onMediaCompleted?.call();
          break;
        case 'scoreCompleted':
          onScoreCompleted?.call();
          break;
        case 'screenOn':
          onScreenOn?.call();
          break;
        case 'memoryPressure':
          final level = (call.arguments as num?)?.toInt() ?? 0;
          onMemoryPressure?.call(level);
          break;
      }
      return null;
    });
  }

  static void detach() {
    _channel.setMethodCallHandler(null);
  }
}
