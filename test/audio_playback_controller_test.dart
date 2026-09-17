import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/playback/audio_playback_controller.dart';

/// Transport semantics of the audio backend (mirrors the score controller so
/// the queue, auto-advance and loop modes behave identically).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.musereader/media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  var playing = false;
  var positionMs = 0;
  final calls = <String>[];

  setUp(() {
    playing = false;
    positionMs = 0;
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'load':
          return <String, Object?>{'available': true, 'durationMs': 60000};
        case 'play':
          playing = true;
          return true;
        case 'pause':
        case 'stop':
          playing = false;
          return null;
        case 'seek':
          positionMs = (call.arguments['positionMs'] as num).toInt();
          return null;
        case 'position':
          return positionMs;
        case 'isPlaying':
          return playing;
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('load learns the duration and play/pause drive the transport', () async {
    final controller = AudioPlaybackController('/audio/a.mp3');
    await controller.play();

    expect(controller.durationUs, 60000000);
    expect(controller.isPlaying, isTrue);
    expect(calls, contains('load'));
    expect(calls, contains('play'));

    await controller.pause();
    expect(controller.isPlaying, isFalse);
    expect(calls, contains('pause'));
    controller.dispose();
  });

  test('a short file that stops near its end snaps to the duration', () async {
    final controller = AudioPlaybackController('/audio/a.mp3');
    await controller.play();

    // The platform reports the last position a little before the end and stops.
    positionMs = 59900;
    playing = false;
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(controller.isPlaying, isFalse);
    // Snapped to the end so the reader's end-of-piece detection can advance.
    expect(controller.positionUs, controller.durationUs);
    controller.dispose();
  });

  test('completion latches the stopped state at the duration', () async {
    final controller = AudioPlaybackController('/audio/a.mp3');
    await controller.play();
    controller.handleCompleted();

    expect(controller.isPlaying, isFalse);
    expect(controller.positionUs, controller.durationUs);
    controller.dispose();
  });

  test('an unsupported file surfaces the platform error', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'load') {
        return <String, Object?>{'available': false, 'error': '不支持该格式'};
      }
      return null;
    });
    final controller = AudioPlaybackController('/audio/a.opus');
    await controller.play();

    expect(controller.error, '不支持该格式');
    expect(controller.isPlaying, isFalse);
    controller.dispose();
  });
}
