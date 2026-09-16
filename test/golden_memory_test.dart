import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_reader/src/playback/golden_memory.dart';

/// Parity tests for the Dart port of the reference "mscz an Audio"
/// memory_random.py scheduler (pure logic, no UI).
void main() {
  group('GoldenMemory.capacity', () {
    test(
      'uses floor(0.6180339887498949 * T) with the total clamped to T-1',
      () {
        final memory = GoldenMemory()..setTotal(10);
        expect(memory.capacity(), 6); // floor(6.180339887)
        memory.setTotal(5);
        expect(memory.capacity(), 3); // floor(3.090169943)
        memory.setTotal(2);
        expect(memory.capacity(), 1); // floor(1.236067977) but capped at T-1
        memory.setTotal(1);
        expect(memory.capacity(), 0); // capped at T-1 = 0
        memory.setTotal(0);
        expect(memory.capacity(), 0);
      },
    );
  });

  group('GoldenMemory FIFO behaviour', () {
    test(
      'records most recently played first and forgets the earliest once full',
      () {
        final memory = GoldenMemory()..setTotal(5); // capacity 3
        for (final id in ['a', 'b', 'c', 'd']) {
          memory.record(id);
        }
        expect(memory.snapshot(), ['d', 'c', 'b']);
      },
    );

    test('re-recording moves an entry to the front without duplicating', () {
      final memory = GoldenMemory()..setTotal(5);
      for (final id in ['a', 'b', 'c', 'd']) {
        memory.record(id);
      }
      memory.record('b');
      expect(memory.snapshot(), ['b', 'd', 'c']);
      expect(memory.memorySize, 3);
    });

    test('keeps growing until the capacity while fewer pieces were played', () {
      final memory = GoldenMemory()..setTotal(10); // capacity 6
      memory.record('x');
      memory.record('y');
      expect(memory.snapshot(), ['y', 'x']);
      expect(memory.memorySize, 2);
    });
  });

  group('GoldenMemory refresh', () {
    test('drops removed ids, grows capacity and keeps remembered ids', () {
      final memory = GoldenMemory()..setTotal(2);
      memory.record('a');
      memory.record('b'); // memory: [b, a], capacity 1 -> trims 'a'
      memory.refresh(['a', 'b', 'c', 'd', 'e']); // capacity now 3
      expect(memory.memorySize, 1);
      expect(memory.snapshot(), ['b']);
      memory.record('c');
      memory.record('d');
      expect(memory.snapshot(), ['d', 'c', 'b']);
    });

    test('trims the extra earliest entries when the capacity shrinks', () {
      final memory = GoldenMemory()..setTotal(10);
      for (final id in ['a', 'b', 'c', 'd']) {
        memory.record(id);
      }
      expect(memory.snapshot(), ['d', 'c', 'b', 'a']);
      memory.refresh(['d', 'b', 'x', 'y', 'z']); // capacity 3
      expect(memory.snapshot(), ['d', 'b']);
    });

    test('clear removes everything', () {
      final memory = GoldenMemory()..setTotal(10);
      memory.record('a');
      memory.clear();
      expect(memory.snapshot(), isEmpty);
    });
  });

  group('GoldenMemory choosing', () {
    test('candidates exclude every remembered id', () {
      final memory = GoldenMemory()..setTotal(5);
      memory.record('a');
      memory.record('b');
      expect(memory.candidates(['a', 'b', 'c', 'd', 'e']).toSet(), {
        'c',
        'd',
        'e',
      });
    });

    test('chooseNext always picks outside the memory', () {
      final memory = GoldenMemory()..setTotal(5);
      final rng = Random(7);
      final ids = ['a', 'b', 'c', 'd', 'e'];
      for (var round = 0; round < 20; round++) {
        final pick = memory.chooseNext(ids, rng);
        expect(pick, isNotNull);
        expect(memory.snapshot(), isNot(contains(pick)));
        expect(ids, contains(pick));
        if (pick != null) memory.record(pick);
      }
    });

    test('previousOf returns the entry played just before the current one', () {
      final memory = GoldenMemory()..setTotal(5);
      for (final id in ['a', 'b', 'c']) {
        memory.record(id);
      }
      // snapshot: [c, b, a]
      expect(memory.previousOf('c'), 'b');
      expect(memory.previousOf('b'), 'a');
      expect(memory.previousOf('a'), isNull);
      expect(memory.previousOf('unknown'), isNull);
      expect(memory.mostRecent(), 'c');
    });
  });
}
