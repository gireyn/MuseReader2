import 'dart:math';

/// Golden-ratio memory scheduler, ported from the "mscz an Audio" player
/// (memory_random.py / MemoryRandom.java) so the MuseReader loop modes behave
/// identically:
///
///  * In random mode the player remembers the last
///    `floor(0.6180339887498949 * T)` pieces played, where T is the size of
///    the current collection.
///  * The next piece is picked uniformly at random among the pieces that are
///    NOT in that memory list.
///  * While fewer than the capacity have been played, that smaller number is
///    remembered; once full, the earliest entries are forgotten (FIFO).
///  * When the collection is replaced (folder import / reopen) the memory is
///    cleared and grows from empty.
///
/// The ratio is intentionally internal only: MuseReader never displays the
/// value and does not allow editing it.
class GoldenMemory {
  static const double goldenRatio = 0.6180339887498949;

  /// Memory holds distinct collection ids, most recently played first.
  final List<String> _memory = <String>[];
  int _total = 0;

  int get total => _total;

  int get memorySize => _memory.length;

  /// Current memory size M = floor(goldenRatio * total), clamped to total-1.
  int capacity([int? total]) {
    final t = total ?? _total;
    if (t <= 0) return 0;
    var m = (goldenRatio * t).floor();
    if (m > t - 1) m = t - 1;
    if (m < 0) m = 0;
    return m;
  }

  void setTotal(int total) => _total = total;

  /// Refresh against the current collection: drop ids that no longer exist,
  /// recompute the capacity and trim the earliest entries.
  void refresh(Iterable<String> validIds) {
    final ids = validIds.toSet();
    _total = ids.length;
    _memory.removeWhere((id) => !ids.contains(id));
    final m = capacity();
    if (_memory.length > m) _memory.removeRange(m, _memory.length);
  }

  /// Mark a piece as started: move it to the front and trim to capacity.
  void record(String id) {
    _memory.remove(id);
    _memory.insert(0, id);
    final m = capacity();
    if (_memory.length > m) _memory.removeRange(m, _memory.length);
  }

  /// Ids that may be played next (everything not currently remembered).
  List<String> candidates(Iterable<String> allIds) {
    final remembered = _memory.toSet();
    return [
      for (final id in allIds)
        if (!remembered.contains(id)) id,
    ];
  }

  /// Refresh, then pick one random id outside the memory list.
  String? chooseNext(List<String> allIds, [Random? random]) {
    final rng = random ?? Random();
    refresh(allIds);
    if (allIds.isEmpty) return null;
    final cand = candidates(allIds);
    // Unreachable while capacity <= total - 1, but stay safe.
    return (cand.isEmpty ? allIds : cand)[rng.nextInt(
      cand.isEmpty ? allIds.length : cand.length,
    )];
  }

  /// The entry played just before [currentId] (the next-older memory entry),
  /// used by the "previous piece" button in random mode.
  String? previousOf(String currentId) {
    final index = _memory.indexOf(currentId);
    if (index >= 0 && index + 1 < _memory.length) return _memory[index + 1];
    return null;
  }

  String? mostRecent() => _memory.isEmpty ? null : _memory.first;

  void clear() => _memory.clear();

  List<String> snapshot() => List<String>.unmodifiable(_memory);
}
