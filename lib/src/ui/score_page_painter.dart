import 'package:flutter/material.dart';

import '../model/score_document.dart';

/// MuseScore 3.6.2's first voice/playback selection colour.
const museScorePlaybackColor = Color(0xff0065bf);
const museScoreInkColor = Color(0xff20211f);
const museScorePaperColor = Color(0xfffdfbf7);

class ScorePagePainter extends CustomPainter {
  const ScorePagePainter({
    required this.page,
    required this.activeEventIndexes,
    required this.inkColor,
    required this.accentColor,
    this.playbackCursor,
  });

  final ScorePage page;
  final Set<int> activeEventIndexes;
  final Color inkColor;
  final Color accentColor;
  final ScoreRect? playbackCursor;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / page.width;
    final scaleY = size.height / page.height;
    canvas.save();
    canvas.scale(scaleX, scaleY);

    final paper = Paint()..color = museScorePaperColor;
    canvas.drawRect(Offset.zero & Size(page.width, page.height), paper);
    final border = Paint()
      ..color = const Color(0xffe4ded4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(
      Rect.fromLTWH(0.5, 0.5, page.width - 1, page.height - 1),
      border,
    );

    for (final glyph in page.glyphs) {
      final rect = Rect.fromLTWH(
        glyph.rect.left,
        glyph.rect.top,
        glyph.rect.width,
        glyph.rect.height,
      );
      switch (glyph.kind) {
        case GlyphKind.title:
          _drawText(canvas, glyph.text ?? '', rect, 24, inkColor, true);
        case GlyphKind.composer:
          _drawText(
            canvas,
            glyph.text ?? '',
            rect,
            12,
            inkColor.withValues(alpha: 0.66),
            false,
          );
        case GlyphKind.measureNumber:
          _drawText(
            canvas,
            glyph.text ?? '',
            rect,
            11,
            inkColor.withValues(alpha: 0.72),
            false,
          );
        case GlyphKind.staffLine:
          final linePaint = Paint()
            ..color = inkColor.withValues(alpha: 0.82)
            ..strokeWidth = rect.height;
          canvas.drawLine(
            rect.topLeft,
            Offset(rect.right, rect.top),
            linePaint,
          );
        case GlyphKind.barline:
          final barPaint = Paint()
            ..color = inkColor.withValues(alpha: 0.88)
            ..strokeWidth = rect.width;
          canvas.drawLine(
            Offset(rect.center.dx, rect.top),
            Offset(rect.center.dx, rect.bottom),
            barPaint,
          );
        case GlyphKind.clef:
          _drawText(canvas, glyph.text ?? 'G', rect, 42, inkColor, false);
        case GlyphKind.rest:
          final restPaint = Paint()..color = inkColor;
          canvas.drawRect(
            Rect.fromLTWH(rect.left, rect.top + 6, rect.width, 4),
            restPaint,
          );
          canvas.drawRect(
            Rect.fromLTWH(rect.left + 4, rect.top + 2, rect.width - 8, 4),
            restPaint,
          );
        case GlyphKind.note:
          _drawNote(
            canvas,
            rect,
            glyph,
            activeEventIndexes.contains(glyph.eventIndex),
          );
      }
    }
    _drawPlaybackCursor(canvas);
    canvas.restore();
  }

  void _drawPlaybackCursor(Canvas canvas) {
    final cursor = playbackCursor;
    if (cursor == null ||
        !cursor.isFinite ||
        cursor.width <= 0 ||
        cursor.height <= 0) {
      return;
    }
    final pageRect = Rect.fromLTWH(0, 0, page.width, page.height);
    final rect = Rect.fromLTWH(
      cursor.left,
      cursor.top,
      cursor.width,
      cursor.height,
    ).intersect(pageRect);
    if (rect.isEmpty) return;
    // PositionCursor::paint() in MuseScore fills the complete system cursor
    // with the selection colour at alpha 50 and does not draw an outline.
    final paint = Paint()
      ..color = accentColor.withValues(alpha: 50 / 255.0)
      ..style = PaintingStyle.fill;
    canvas.drawRect(rect, paint);
  }

  void _drawText(
    Canvas canvas,
    String text,
    Rect rect,
    double fontSize,
    Color color,
    bool bold,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          fontFamily: 'serif',
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: rect.width);
    painter.paint(canvas, Offset(rect.left, rect.top));
  }

  void _drawNote(Canvas canvas, Rect rect, ScoreGlyph glyph, bool active) {
    final noteColor = active ? accentColor : inkColor;
    final notePaint = Paint()
      ..color = noteColor
      ..style = glyph.filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = active ? 2.4 : 1.6;
    canvas.save();
    canvas.translate(rect.center.dx, rect.center.dy);
    canvas.rotate(-0.22);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: rect.width,
        height: rect.height,
      ),
      notePaint,
    );
    canvas.restore();

    // MuseScore's playback mark is attached to Note, while the separately
    // painted stem/beam keeps the normal ink colour.
    final stemPaint = Paint()
      ..color = inkColor
      ..strokeWidth = active ? 2.2 : 1.6;
    final stemX = glyph.pitch != null && glyph.pitch! >= 71
        ? rect.left + 1.5
        : rect.right - 1.5;
    final stemTop = glyph.pitch != null && glyph.pitch! >= 71
        ? rect.bottom - 1
        : rect.top - 30;
    final stemBottom = glyph.pitch != null && glyph.pitch! >= 71
        ? rect.top + 30
        : rect.top + 1;
    canvas.drawLine(
      Offset(stemX, stemTop),
      Offset(stemX, stemBottom),
      stemPaint,
    );
  }

  @override
  bool shouldRepaint(covariant ScorePagePainter oldDelegate) =>
      oldDelegate.page != page ||
      oldDelegate.activeEventIndexes != activeEventIndexes ||
      oldDelegate.inkColor != inkColor ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.playbackCursor != playbackCursor;
}
