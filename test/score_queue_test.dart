import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/playback/score_queue.dart';

void main() {
  group('ReaderQueue defaults', () {
    test('defaults to random (memory) for a multi-piece collection', () {
      final queue = ReaderQueue(ids: const ['a', 'b', 'c']);
      expect(queue.loop, PlayLoop.randomMemory);
      expect(queue.effectiveLoop, PlayLoop.randomMemory);
      expect(queue.currentId, 'a');
    });

    test('forces single loop for a one-piece collection', () {
      final queue = ReaderQueue(ids: const ['a']);
      expect(queue.loop, PlayLoop.single);
      expect(queue.effectiveLoop, PlayLoop.single);
      expect(queue.hasMultiple, isFalse);
    });

    test('empty collection keeps no current id', () {
      final queue = ReaderQueue(ids: const []);
      expect(queue.currentId, isNull);
      expect(queue.loop, PlayLoop.single);
    });
  });

  group('manual next', () {
    test('random mode picks uniformly outside the golden-ratio memory', () {
      final queue = ReaderQueue(ids: const ['a', 'b', 'c', 'd', 'e']);
      // Record four pieces: memory capacity floor(0.618*5) = 3.
      queue.recordCurrent(); // records 'a'
      for (var index = 1; index < 4; index++) {
        queue.setCurrentId(queue.ids[index]);
        queue.recordCurrent();
      }
      queue.setCurrentId('a'); // in memory again: move-to-front, still size 3
      for (var round = 0; round < 30; round++) {
        final index = queue.manualNextIndex();
        expect(index, isNotNull);
        final picked = queue.ids[index!];
        expect(queue.memory.snapshot(), isNot(contains(picked)));
        queue.setCurrentId(picked);
      }
    });

    test('sequential mode advances one step and wraps around the end', () {
      final queue = ReaderQueue(
        ids: const ['a', 'b', 'c'],
        loop: PlayLoop.sequential,
      )..setCurrentId('a');
      expect(queue.manualNextIndex(), 1);
      queue.setCurrentId('b');
      expect(queue.manualNextIndex(), 2);
      queue.setCurrentId('c');
      expect(queue.manualNextIndex(), 0);
    });

    test('single loop keeps the current piece', () {
      final queue = ReaderQueue(
        ids: const ['a', 'b', 'c'],
        loop: PlayLoop.single,
      )..setCurrentId('b');
      expect(queue.manualNextIndex(), 1);
    });

    test('none mode advances until the last piece then stops', () {
      final queue = ReaderQueue(ids: const ['a', 'b', 'c'], loop: PlayLoop.none)
        ..setCurrentId('a');
      expect(queue.manualNextIndex(), 1);
      queue.setCurrentId('c');
      expect(queue.manualNextIndex(), isNull);
    });

    test(
      'a one-piece collection answers with its own index whatever the loop',
      () {
        for (final loop in [
          PlayLoop.randomMemory,
          PlayLoop.sequential,
          PlayLoop.single,
        ]) {
          final queue = ReaderQueue(ids: const ['a'], loop: loop);
          expect(queue.effectiveLoop, PlayLoop.single);
          expect(queue.manualNextIndex(), 0);
        }
      },
    );
  });

  group('piece end', () {
    test('sequential end wraps around', () {
      final queue = ReaderQueue(
        ids: const ['a', 'b', 'c'],
        loop: PlayLoop.sequential,
      )..setCurrentId('c');
      expect(queue.endOfPieceIndex(), 0);
    });

    test('single end replays the same piece', () {
      final queue = ReaderQueue(ids: const ['a', 'b'], loop: PlayLoop.single)
        ..setCurrentId('b');
      expect(queue.endOfPieceIndex(), 1);
    });

    test('none end stops playback', () {
      final queue = ReaderQueue(ids: const ['a', 'b', 'c'], loop: PlayLoop.none)
        ..setCurrentId('b');
      expect(queue.endOfPieceIndex(), isNull);
    });

    test('random end never chooses a piece inside the memory', () {
      final queue = ReaderQueue(ids: const ['a', 'b', 'c', 'd', 'e']);
      queue.setCurrentId('a');
      queue.recordCurrent();
      queue.setCurrentId('b');
      queue.recordCurrent();
      queue.setCurrentId('c');
      queue.recordCurrent();
      // All of a/b/c fill the capacity 3 -> every next pick must be d or e.
      for (var round = 0; round < 20; round++) {
        final index = queue.endOfPieceIndex();
        expect(index, anyOf(3, 4));
      }
    });
  });

  group('previous piece', () {
    test('walks back through the memory history (most recent first)', () {
      final queue = ReaderQueue(ids: const ['a', 'b', 'c', 'd', 'e']);
      // Simulate: start a, then b, then c — memory snapshot [c, b, a].
      for (final id in ['a', 'b', 'c']) {
        queue.setCurrentId(id);
        queue.recordCurrent();
      }
      expect(queue.memoryPrevIndex(), 1); // 'b' before current 'c'
      queue.setCurrentId('b');
      expect(queue.memoryPrevIndex(), 0); // 'a' before current 'b'
      queue.setCurrentId('d'); // never played
      expect(queue.memoryPrevIndex(), 2); // most recent memory entry 'c'
      queue.setCurrentId('a');
      expect(queue.memoryPrevIndex(), isNull); // nothing older in memory
    });

    test('falls back to stepping back through the collection', () {
      final queue = ReaderQueue(ids: const ['a', 'b', 'c'])..setCurrentId('b');
      expect(queue.stepBackIndex(), 0);
      queue.setCurrentId('a');
      expect(queue.stepBackIndex(), isNull);
    });
  });

  group('collection replacement', () {
    test(
      'replaceWith clears the memory and keeps the requested id when present',
      () {
        final queue = ReaderQueue(ids: const ['a', 'b', 'c', 'd', 'e']);
        queue.setCurrentId('a');
        queue.recordCurrent();
        queue.setCurrentId('b');
        queue.recordCurrent();
        expect(queue.memory.memorySize, 2);

        queue.replaceWith(const ['x', 'y', 'b'], keepId: 'b');
        expect(queue.ids, const ['x', 'y', 'b']);
        expect(queue.currentId, 'b');
        expect(queue.memory.memorySize, 0);
        expect(queue.loop, PlayLoop.randomMemory);
      },
    );

    test(
      'replaceWith falls back to the first id and forces single for one piece',
      () {
        final queue = ReaderQueue(
          ids: const ['a', 'b'],
          loop: PlayLoop.sequential,
        );
        queue.replaceWith(const ['z']);
        expect(queue.currentId, 'z');
        expect(queue.loop, PlayLoop.single);
      },
    );
  });

  group('loop selection', () {
    test('setLoop persists a user selection and notifies listeners', () {
      final queue = ReaderQueue(ids: const ['a', 'b', 'c']);
      var notifications = 0;
      queue.addListener(() => notifications += 1);
      queue.setLoop(PlayLoop.sequential);
      expect(queue.loop, PlayLoop.sequential);
      expect(notifications, 1);
      queue.setLoop(PlayLoop.sequential);
      expect(notifications, 1); // no-op selection does not notify
    });

    test('a one-piece queue cannot leave single loop', () {
      final queue = ReaderQueue(ids: const ['a']);
      queue.setLoop(PlayLoop.sequential);
      expect(queue.loop, PlayLoop.single);
    });

    test('labels are Chinese and cover every mode', () {
      expect(PlayLoop.randomMemory.label, '随机（记忆）');
      expect(PlayLoop.sequential.label, '顺序播放');
      expect(PlayLoop.single.label, '单曲循环');
      expect(PlayLoop.none.label, '播完停止');
    });
  });
}
