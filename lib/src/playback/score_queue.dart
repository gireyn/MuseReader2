import 'package:flutter/foundation.dart';

import 'golden_memory.dart';

/// Loop modes of the reader queue.  Behaviour mirrors the "mscz an Audio"
/// player: random uses the internal golden-ratio memory, sequential advances
/// through the collection, single repeats the piece, none stops after it.
/// The memory factor is deliberately not shown and not editable here.
enum PlayLoop {
  randomMemory,
  sequential,
  single,
  none;

  String get label => switch (this) {
    PlayLoop.randomMemory => '随机（记忆）',
    PlayLoop.sequential => '顺序播放',
    PlayLoop.single => '单曲循环',
    PlayLoop.none => '播完停止',
  };
}

/// Ordered collection queue for the reader's previous/next piece controls.
///
/// The queue owns the hidden golden-ratio memory scheduler and the current
/// loop mode; it survives reader navigation because the library page keeps
/// one instance per collection session.  Only the ids of the collection are
/// stored here; documents are loaded by the caller on demand.
class ReaderQueue extends ChangeNotifier {
  ReaderQueue({required List<String> ids, String? initialId, PlayLoop? loop})
    : ids = List<String>.of(ids),
      loop = ids.length > 1 ? (loop ?? PlayLoop.randomMemory) : PlayLoop.single,
      currentId = initialId ?? (ids.isEmpty ? null : ids.first) {
    memory.setTotal(this.ids.length);
  }

  List<String> ids;
  final GoldenMemory memory = GoldenMemory();
  PlayLoop loop;
  String? currentId;

  bool get hasMultiple => ids.length > 1;

  /// Effective mode: a single-piece collection can only repeat or stop.
  PlayLoop get effectiveLoop => switch (loop) {
    PlayLoop.randomMemory ||
    PlayLoop.sequential when !hasMultiple => PlayLoop.single,
    _ => loop,
  };

  int? get currentIndex {
    final id = currentId;
    if (id == null) return null;
    final index = ids.indexOf(id);
    return index < 0 ? null : index;
  }

  /// Replace the whole collection (folder import).  The memory is cleared,
  /// exactly like reopening a folder in "mscz an Audio".
  void replaceWith(List<String> newIds, {String? keepId}) {
    ids = List<String>.unmodifiable(newIds); // ignore: invalid_assignment
    memory.clear();
    memory.setTotal(ids.length);
    if (keepId != null && ids.contains(keepId)) {
      currentId = keepId;
    } else {
      currentId = ids.isEmpty ? null : ids.first;
    }
    if (!hasMultiple && loop != PlayLoop.single && loop != PlayLoop.none) {
      loop = PlayLoop.single;
    }
    notifyListeners();
  }

  void setLoop(PlayLoop value) {
    if (loop == value) return;
    loop = value;
    if (!hasMultiple && loop != PlayLoop.single && loop != PlayLoop.none) {
      loop = PlayLoop.single;
    }
    notifyListeners();
  }

  void setCurrentId(String? id) {
    if (currentId == id) return;
    currentId = id;
    notifyListeners();
  }

  /// Mark the current piece as started (called when playback begins).
  void recordCurrent() {
    final id = currentId;
    if (id != null && hasMultiple) memory.record(id);
  }

  /// Index of the piece to play for a MANUAL next press, or null to stop.
  int? manualNextIndex() {
    if (ids.isEmpty) return null;
    switch (effectiveLoop) {
      case PlayLoop.randomMemory:
        final pick = memory.chooseNext(ids);
        return pick == null ? null : ids.indexOf(pick);
      case PlayLoop.sequential:
        return (currentIndex ?? -1) < ids.length - 1
            ? ((currentIndex ?? -1) + 1) % ids.length
            : 0;
      case PlayLoop.single:
        return currentIndex ?? 0;
      case PlayLoop.none:
        final index = currentIndex;
        if (index == null) return 0;
        return index + 1 < ids.length ? index + 1 : null;
    }
  }

  /// Index of the piece to play when the current piece ENDS, or null to
  /// stop playback (none mode).
  int? endOfPieceIndex() {
    if (ids.isEmpty) return null;
    switch (effectiveLoop) {
      case PlayLoop.randomMemory:
        final pick = memory.chooseNext(ids);
        return pick == null ? null : ids.indexOf(pick);
      case PlayLoop.sequential:
        return ((currentIndex ?? -1) + 1) % ids.length;
      case PlayLoop.single:
        return currentIndex ?? 0;
      case PlayLoop.none:
        return null;
    }
  }

  /// The previous-piece target from the memory list (random-style history),
  /// or null when the memory cannot name one.  The caller falls back to
  /// restarting the piece or stepping back through the collection.
  int? memoryPrevIndex() {
    final current = currentId;
    if (current == null || ids.length < 2) return null;
    final snapshot = memory.snapshot();
    if (snapshot.isEmpty) return null;
    final currentPosition = snapshot.indexOf(current);
    String? target;
    if (currentPosition >= 0) {
      if (currentPosition + 1 < snapshot.length) {
        target = snapshot[currentPosition + 1];
      }
    } else {
      target = snapshot.first;
    }
    if (target == null || target == current || !ids.contains(target)) {
      return null;
    }
    return ids.indexOf(target);
  }

  /// Index of the previous collection entry (fallback step back).
  int? stepBackIndex() {
    if (ids.isEmpty) return null;
    final index = currentIndex;
    if (index == null || index <= 0) return null;
    return index - 1;
  }
}
