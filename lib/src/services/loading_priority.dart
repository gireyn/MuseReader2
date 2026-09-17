/// Ordering helper for the library's background loading.
///
/// The anchor is the *last* card the sliver builders materialised, i.e. the
/// bottom-most card of the current viewport (Flutter builds the children in
/// index order, so the last report is the lowest one on screen). Starting from
/// that anchor the order walks *backwards* to the top of the collection and
/// then continues forwards from below the anchor:
///
///   collection a…h, viewport on c,d,e (anchor e)
///     → e, d, c, b, a, f, g, h
///
/// Nothing needs to be measured: the build reports are enough, and the item
/// currently being loaded is never interrupted by the caller.
List<String> anchorFirstOrder({
  required String? anchorPath,
  required List<String> collectionOrder,
}) {
  final anchorIndex = anchorPath == null
      ? -1
      : collectionOrder.indexOf(anchorPath);
  if (anchorIndex < 0) return List<String>.of(collectionOrder);

  final ordered = <String>[collectionOrder[anchorIndex]];
  for (var index = anchorIndex - 1; index >= 0; index--) {
    ordered.add(collectionOrder[index]);
  }
  for (var index = anchorIndex + 1; index < collectionOrder.length; index++) {
    ordered.add(collectionOrder[index]);
  }
  return ordered;
}
