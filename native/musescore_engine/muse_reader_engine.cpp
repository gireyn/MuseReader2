#include "muse_reader_engine.h"
#include "muse_reader_audio_internal.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <mutex>
#include <string>

#if defined(MUSE_READER_WITH_MUSESCORE)
#if defined(MUSE_READER_BUILD_MUSESCORE_SOURCE)
#include "mobile_all.h"
#else
#include "all.h"
#endif
#include <QApplication>
#include <QCoreApplication>
#include <QBuffer>
#include <QByteArray>
#include <QFile>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPainter>
#include <QRectF>
#include <QString>
#include <QStringRef>

#include <algorithm>
#include <deque>
#include <map>
#include <memory>
#include <tuple>
#include <vector>

#include "chord.h"
#include "element.h"
#include "event.h"
#include "instrtemplate.h"
#include "instrument.h"
#include "measure.h"
#include "mscore.h"
#include "musescoreCore.h"
#include "note.h"
#include "page.h"
#include "repeatlist.h"
#include "segment.h"
#include "score.h"
#include "scoreOrder.h"
#include "staff.h"
#include "synthesizerstate.h"
#include "system.h"
#include "tempo.h"
#include "text.h"
#include "tie.h"
#include "preferences.h"

#ifndef MUSE_READER_RENDER_DPI
#define MUSE_READER_RENDER_DPI 180
#endif
#endif

#if defined(MUSE_READER_WITH_MUSESCORE) && \
    defined(MUSE_READER_BUILD_MUSESCORE_SOURCE)
static void initialize_muse_reader_resources() {
  Q_INIT_RESOURCE(muse_reader_resources);
}
#endif

#if defined(MUSE_READER_WITH_MUSESCORE) && \
    defined(MUSE_READER_BUILD_MUSESCORE_SOURCE) && defined(Q_OS_ANDROID)
extern "C" void muse_reader_qminimal_link_anchor();
#endif

namespace {
std::mutex g_engine_mutex;
std::string g_last_error;

const char* copy_string(const std::string& value) {
  auto* result = static_cast<char*>(std::malloc(value.size() + 1));
  if (!result) return nullptr;
  std::memcpy(result, value.data(), value.size());
  result[value.size()] = '\0';
  return result;
}

#if defined(MUSE_READER_WITH_MUSESCORE)
void set_error(const QString& error) {
  g_last_error = error.toUtf8().toStdString();
}

bool verify_render_resources() {
  static const char* const required_resources[] = {
      ":/fonts/smufl/glyphnames.json",
      ":/fonts/leland/metadata.json",
      ":/fonts/bravura/metadata.json",
      ":/fonts/mscore/metadata.json",
      ":/fonts/gootville/metadata.json",
      ":/fonts/musejazz/metadata.json",
      ":/fonts/petaluma/metadata.json",
      ":/fonts/leland/Leland.otf",
      ":/fonts/bravura/Bravura.otf",
      ":/fonts/mscore/mscore.ttf",
      ":/fonts/gootville/Gootville.otf",
      ":/fonts/musejazz/MuseJazz.otf",
      ":/fonts/petaluma/Petaluma.otf",
      ":/fonts/fonts_tablature.xml",
      ":/fonts/fonts_figuredbass.xml",
  };
  for (const char* path : required_resources) {
    if (!QFile::exists(QString::fromLatin1(path))) {
      set_error(QStringLiteral("Missing MuseScore rendering resource: %1")
                    .arg(QString::fromLatin1(path)));
      return false;
    }
  }
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  if (!QFile::exists(QStringLiteral(":/sound/MS Basic.sf3"))) {
    set_error(QStringLiteral(
        "Missing MuseScore playback resource: MS Basic.sf3"));
    return false;
  }
#endif
  return true;
}

bool register_text_fonts() {
  static const char* const font_resources[] = {
      ":/fonts/leland/LelandText.otf",
      ":/fonts/bravura/BravuraText.otf",
      ":/fonts/mscore/MScoreText.ttf",
      ":/fonts/gootville/GootvilleText.otf",
      ":/fonts/musejazz/MuseJazzText.otf",
      ":/fonts/petaluma/PetalumaText.otf",
      ":/fonts/petaluma/PetalumaScript.otf",
      ":/fonts/campania/Campania.otf",
      ":/fonts/edwin/Edwin-Roman.otf",
      ":/fonts/edwin/Edwin-Bold.otf",
      ":/fonts/edwin/Edwin-Italic.otf",
      ":/fonts/edwin/Edwin-BdIta.otf",
      ":/fonts/FreeSans.ttf",
      ":/fonts/FreeSerif.ttf",
      ":/fonts/FreeSerifBold.ttf",
      ":/fonts/FreeSerifItalic.ttf",
      ":/fonts/FreeSerifBoldItalic.ttf",
      ":/fonts/mscoreTab.ttf",
      ":/fonts/mscore-BC.ttf",
  };
  for (const char* path : font_resources) {
    const QString resource = QString::fromLatin1(path);
    if (!QFile::exists(resource)) {
      set_error(QStringLiteral("Missing MuseScore text font: %1").arg(resource));
      return false;
    }
    if (QFontDatabase::addApplicationFont(resource) < 0) {
      set_error(QStringLiteral("Unable to register MuseScore text font: %1")
                    .arg(resource));
      return false;
    }
  }
  return true;
}

bool initialize_musescore() {
  static bool initialized = false;
  static std::unique_ptr<Ms::MuseScoreCore> core;
  static std::unique_ptr<QApplication> qt_application;
  if (initialized) return true;
#if defined(MUSE_READER_WITH_MUSESCORE) && \
    defined(MUSE_READER_BUILD_MUSESCORE_SOURCE) && defined(Q_OS_ANDROID)
  // Keep the static qminimal plugin object reachable from the final JNI
  // shared object (see muse_reader_qminimal_import.cpp).
  muse_reader_qminimal_link_anchor();
#endif
#if defined(MUSE_READER_BUILD_MUSESCORE_SOURCE)
  initialize_muse_reader_resources();
#endif
  QCoreApplication* application = QCoreApplication::instance();
  if (!application) {
#if defined(Q_OS_ANDROID)
    qputenv("QT_QPA_PLATFORM",
            QByteArrayLiteral("minimal:enable_fonts:freetype"));
#else
    qputenv("QT_QPA_PLATFORM", QByteArrayLiteral("minimal:enable_fonts"));
#endif
    QCoreApplication::setAttribute(Qt::AA_Use96Dpi);
    static int argc = 1;
    static char application_name[] = "MuseReader";
    static char* argv[] = {application_name, nullptr};
    qt_application = std::make_unique<QApplication>(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("MuseReader"));
    QCoreApplication::setOrganizationName(QStringLiteral("MuseReader"));
    application = qt_application.get();
  }
  if (!qobject_cast<QGuiApplication*>(application)) {
    set_error(
        QStringLiteral("MuseScore rendering requires the Qt GUI runtime to "
                       "be initialized on the platform main thread"));
    return false;
  }
  if (!verify_render_resources() || !register_text_fonts()) return false;
  Ms::MScore::noGui = true;
  Ms::MScore::pdfPrinting = false;
  Ms::MScore::svgPrinting = false;
  Ms::MScore::init();
  Ms::preferences.init(true);
#if defined(MUSE_READER_BUILD_MUSESCORE_SOURCE)
  // The desktop bootstrap loads these catalogs before opening scores.  They
  // provide the instrument/drumset and score-order defaults used when older
  // files omit an explicit channel definition.
  if (!Ms::loadInstrumentTemplates(QStringLiteral(":/data/instruments.xml"))) {
    set_error(QStringLiteral("Missing MuseScore instrument catalog"));
    return false;
  }
  Ms::loadScoreOrders(QStringLiteral(":/data/orders.xml"));
#endif
  core = std::make_unique<Ms::MuseScoreCore>();
  initialized = true;
  return true;
}

struct RenderedPage {
  QString base64_png;
  int pixel_width = 0;
  int pixel_height = 0;
};

struct RenderedNotehead {
  QString base64_png;
  // Absolute page coordinates, including the small antialiasing margin used
  // by the transparent bitmap.  Callers translate this to page-local space.
  QRectF page_rect;
};

class RenderStateGuard {
 public:
  explicit RenderStateGuard(Ms::MasterScore* score)
      : score_(score),
        old_printing_(score->printing()),
        old_pdf_printing_(Ms::MScore::pdfPrinting),
        old_pixel_ratio_(Ms::MScore::pixelRatio) {}

  ~RenderStateGuard() {
    score_->setPrinting(old_printing_);
    Ms::MScore::pdfPrinting = old_pdf_printing_;
    Ms::MScore::pixelRatio = old_pixel_ratio_;
  }

 private:
  Ms::MasterScore* score_;
  bool old_printing_;
  bool old_pdf_printing_;
  double old_pixel_ratio_;
};

bool is_title_frame_text(const Ms::Text* text) {
  if (!text || !text->visible() || !text->parent() ||
      !text->parent()->isVBox()) {
    return false;
  }

  switch (text->tid()) {
    case Ms::Tid::TITLE:
    case Ms::Tid::SUBTITLE:
    case Ms::Tid::COMPOSER:
    case Ms::Tid::POET:
    case Ms::Tid::TRANSLATOR:
    case Ms::Tid::INSTRUMENT_EXCERPT:
      return true;
    default:
      return false;
  }
}

QRectF visible_text_rect(const Ms::Text* text) {
  QRectF result;
  bool has_visible_text = false;
  for (int row = 0; row < text->rows(); ++row) {
    const Ms::TextBlock& block = text->textBlock(row);
    bool block_has_visible_text = false;
    for (const Ms::TextFragment& fragment : block.fragments()) {
      if (!fragment.text.trimmed().isEmpty()) {
        block_has_visible_text = true;
        break;
      }
    }
    if (!block_has_visible_text) continue;

    const QRectF block_rect =
        block.boundingRect().translated(0.0, block.y());
    result = has_visible_text ? result.united(block_rect) : block_rect;
    has_visible_text = true;
  }
  return has_visible_text ? result.translated(text->pagePos()) : QRectF();
}

bool visible_text_overlaps(const Ms::Text* first, const Ms::Text* second) {
  const QRectF overlap =
      visible_text_rect(first).intersected(visible_text_rect(second));
  constexpr qreal kMinimumOverlap = 0.25;
  return overlap.width() > kMinimumOverlap &&
         overlap.height() > kMinimumOverlap;
}

bool trim_trailing_line_breaks(Ms::Text* text) {
  QString contents = text->xmlText();
  const int original_size = contents.size();
  while (!contents.isEmpty() &&
         (contents.endsWith(QLatin1Char('\n')) ||
          contents.endsWith(QLatin1Char('\r')))) {
    contents.chop(1);
  }
  if (contents.size() == original_size) return false;
  text->setXmlText(contents);
  return true;
}

bool repair_title_frame_text_collisions(Ms::MasterScore* score) {
  std::map<const Ms::Element*, std::vector<Ms::Text*>> text_by_frame;
  for (Ms::Page* page : score->pages()) {
    for (Ms::Element* element : page->elements()) {
      if (!element->isText()) continue;
      auto* text = static_cast<Ms::Text*>(element);
      if (is_title_frame_text(text)) {
        text_by_frame[text->parent()].push_back(text);
      }
    }
  }

  bool repaired = false;
  for (const auto& entry : text_by_frame) {
    const std::vector<Ms::Text*>& texts = entry.second;
    std::vector<bool> collides(texts.size(), false);
    for (size_t first = 0; first < texts.size(); ++first) {
      for (size_t second = first + 1; second < texts.size(); ++second) {
        if (visible_text_overlaps(texts[first], texts[second])) {
          collides[first] = true;
          collides[second] = true;
        }
      }
    }

    // MuseScore 3.x includes trailing blank paragraphs in bottom-aligned text
    // geometry. Some imported scores then offset adjacent credit lines back on
    // top of one another. Remove only those invisible paragraphs, and only in
    // title-frame text whose visible glyphs are already colliding.
    for (size_t index = 0; index < texts.size(); ++index) {
      if (collides[index]) {
        repaired = trim_trailing_line_breaks(texts[index]) || repaired;
      }
    }
  }
  return repaired;
}

RenderedPage render_page(Ms::MasterScore* score, int page_index) {
  Ms::Page* page = score->pages().at(page_index);
  const QRectF box = page->abbox();
  constexpr double render_dpi = MUSE_READER_RENDER_DPI;
  const double magnification = render_dpi / Ms::DPI;
  const int width = qMax(1, qRound(box.width() * magnification));
  const int height = qMax(1, qRound(box.height() * magnification));
  QImage image(width, height, QImage::Format_ARGB32_Premultiplied);
  image.setDotsPerMeterX(qRound(render_dpi * 1000.0 / Ms::INCH));
  image.setDotsPerMeterY(qRound(render_dpi * 1000.0 / Ms::INCH));
  image.fill(Qt::white);

  RenderStateGuard state(score);
  score->setPrinting(true);
  Ms::MScore::pdfPrinting = false;
  Ms::MScore::pixelRatio = 1.0 / magnification;

  QPainter painter(&image);
  painter.setRenderHint(QPainter::Antialiasing, true);
  painter.setRenderHint(QPainter::TextAntialiasing, true);
  painter.setRenderHint(QPainter::SmoothPixmapTransform, true);
  painter.scale(magnification, magnification);
  painter.translate(-box.topLeft());

  // This mirrors MuseScore::savePng(): every visible element is painted in
  // z-order. Staff lines/stems/ledger lines remain QPainter geometry, while
  // clefs, key signatures, noteheads and other SMuFL symbols go through
  // ScoreFont and FreeType. Page::draw() is included and paints headers and
  // footers, so the result is the complete engraved page rather than a subset.
  QList<Ms::Element*> elements = page->elements();
  std::stable_sort(elements.begin(), elements.end(), Ms::elementLessThan);
  for (const Ms::Element* element : elements) {
    if (!element->visible()) continue;
    painter.save();
    painter.translate(element->pagePos());
    element->draw(&painter);
    painter.restore();
  }
  painter.end();

  QByteArray png;
  QBuffer buffer(&png);
  if (!buffer.open(QIODevice::WriteOnly) || !image.save(&buffer, "PNG")) {
    set_error(QStringLiteral("MuseScore failed to encode page %1 as PNG")
                  .arg(page_index + 1));
    return {};
  }
  return {QString::fromLatin1(png.toBase64()), width, height};
}

RenderedNotehead render_notehead(Ms::MasterScore* score,
                                 const Ms::Note* note) {
  if (!score || !note || !note->visible()) return {};

  const QRectF note_box = note->pageBoundingRect().normalized();
  if (note_box.isEmpty() || !qIsFinite(note_box.left()) ||
      !qIsFinite(note_box.top()) || !qIsFinite(note_box.width()) ||
      !qIsFinite(note_box.height())) {
    return {};
  }

  // Use the same magnification and painter setup as render_page().  The
  // extra score-space margin keeps glyph antialiasing from being clipped at
  // the bitmap edge while preserving the exact note bbox in page space.  The
  // bitmap is retained for clients of older bridge payloads; the current
  // Flutter reader uses the accompanying rectangle to recolour the original
  // page pixels in place instead of compositing this bitmap over the page.
  constexpr double render_dpi = MUSE_READER_RENDER_DPI;
  const double magnification = render_dpi / Ms::DPI;
  constexpr qreal padding = 1.0;
  const QRectF crop = note_box.adjusted(-padding, -padding, padding, padding);
  const int width = qMax(1, qRound(crop.width() * magnification));
  const int height = qMax(1, qRound(crop.height() * magnification));
  QImage image(width, height, QImage::Format_ARGB32_Premultiplied);
  image.fill(Qt::transparent);

  RenderStateGuard state(score);
  score->setPrinting(false);
  Ms::MScore::pdfPrinting = false;
  Ms::MScore::pixelRatio = 1.0 / magnification;

  const bool old_mark = note->mark();
  note->setMark(true);
  QPainter painter(&image);
  painter.setRenderHint(QPainter::Antialiasing, true);
  painter.setRenderHint(QPainter::TextAntialiasing, true);
  painter.setRenderHint(QPainter::SmoothPixmapTransform, true);
  painter.scale(magnification, magnification);
  painter.translate(-crop.topLeft());
  painter.save();
  painter.translate(note->pagePos());
  // Note::draw uses MuseScore's cached SMuFL symbol and its own fractional
  // bbox, so custom, diamond, percussion and hollow heads all share the
  // exact geometry used by the page rasterization.  Stems are separate
  // elements and are intentionally not included in this legacy payload.
  note->draw(&painter);
  painter.restore();
  painter.end();
  note->setMark(old_mark);

  QByteArray png;
  QBuffer buffer(&png);
  if (!buffer.open(QIODevice::WriteOnly) || !image.save(&buffer, "PNG")) {
    set_error(QStringLiteral("MuseScore failed to encode a playback notehead"));
    return {};
  }
  return {QString::fromLatin1(png.toBase64()), crop};
}

QJsonObject note_target_json(Ms::MasterScore* score,
                             const Ms::Note* note,
                             const QRectF& page_box) {
  QJsonObject result;
  if (!score || !note || !note->visible() || note->hidden() ||
      !note->selectable() ||
      !note->chord() || !note->chord()->measure()) {
    return result;
  }
  const QRectF rect = note->pageBoundingRect()
                          .translated(-page_box.topLeft())
                          .normalized();
  if (rect.isEmpty() || !qIsFinite(rect.left()) ||
      !qIsFinite(rect.top()) || !qIsFinite(rect.width()) ||
      !qIsFinite(rect.height()) || !qIsFinite(rect.right()) ||
      !qIsFinite(rect.bottom())) {
    return result;
  }
  const int source_tick = note->chord()->tick().ticks();
  const int click_utick = score->repeatList().tick2utick(source_tick);
  const qreal click_time = score->utick2utime(click_utick);
  if (!qIsFinite(click_time) || click_time < 0.0) return result;

  QJsonObject target_rect;
  target_rect.insert("x", rect.x());
  target_rect.insert("y", rect.y());
  target_rect.insert("width", rect.width());
  target_rect.insert("height", rect.height());
  result.insert("rect", target_rect);
  result.insert("sourceTick", source_tick);
  result.insert("clickStartUs", qRound64(click_time * 1000000.0));
  return result;
}

struct PendingNote {
  int tick;
  int channel;
  int program;
  int bank;
  int pitch;
  // MuseScore stores Note::tuning as a cent offset from the integer MIDI
  // pitch.  Keep it on the pending note so the JSON interval can be replayed
  // by the bundled FluidSynth voice without collapsing microtonal unisons.
  double tuning = 0.0;
  // Playback marking changes a Note's colour, not its engraved head shape.
  // Preserve this bit so Flutter can recolour hollow heads without filling
  // whole/half/breve noteheads on top of the rasterized page.
  bool notehead_filled = true;
  int velocity;
  int staff;
  int voice;
  int measure;
  int page;
  QRectF page_rect;
  QString notehead_image;
  QRectF notehead_rect;
  QRectF cursor_rect;
  qreal cursor_end_x = 0.0;
  bool has_cursor = false;
  // The visual note belongs to this original-score chord tick.  Its MIDI
  // event may start later (grace notes/user NoteEvents), while PLAY-mode
  // clicks seek the parent ChordRest tick.
  int source_tick = -1;
  qint64 click_start_us = -1;
  QJsonArray highlight_rects;
};

void append_highlight_rect(QJsonArray* highlights,
                           Ms::MasterScore* score,
                           Ms::Page* page,
                           const QRectF& page_rect) {
  if (!highlights || !score || !page) return;
  const int page_index = score->pageIdx(page);
  if (page_index < 0) return;
  const QRectF page_box = page->abbox();
  const QRectF relative = page_rect.translated(-page_box.topLeft()).normalized();
  const QRectF clipped = relative.intersected(
      QRectF(0.0, 0.0, page_box.width(), page_box.height()));
  if (clipped.isEmpty() || !qIsFinite(clipped.left()) ||
      !qIsFinite(clipped.top()) || !qIsFinite(clipped.width()) ||
      !qIsFinite(clipped.height())) {
    return;
  }

  QJsonObject rect;
  rect.insert("x", clipped.x());
  rect.insert("y", clipped.y());
  rect.insert("width", clipped.width());
  rect.insert("height", clipped.height());
  QJsonObject highlight;
  highlight.insert("page", page_index);
  highlight.insert("rect", rect);
  highlights->append(highlight);
}

QJsonArray tied_highlight_rects(Ms::MasterScore* score,
                                const Ms::Note* source_note) {
  QJsonArray highlights;
  if (!score || !source_note) return highlights;
  const std::vector<Ms::Note*> tied_notes = source_note->tiedNotes();
  if (tied_notes.size() < 2) return highlights;

  for (const Ms::Note* note : tied_notes) {
    if (!note || !note->visible() || note->hidden() || !note->chord() ||
        !note->chord()->measure() || !note->chord()->measure()->system()) {
      continue;
    }
    Ms::Page* page = note->chord()->measure()->system()->page();
    append_highlight_rect(&highlights, score, page,
                          note->pageBoundingRect());

    Ms::Tie* tie = note->tieFor();
    if (!tie) continue;
    const Ms::Note* end_note = tie->endNote();
    if (end_note && end_note->chord() &&
        end_note->chord()->crossMeasure() == Ms::CrossMeasure::SECOND) {
      continue;
    }
    for (const Ms::SpannerSegment* raw_segment : tie->spannerSegments()) {
      if (!raw_segment || !raw_segment->visible() || !raw_segment->system() ||
          !raw_segment->system()->page()) {
        continue;
      }
      const auto* segment = static_cast<const Ms::TieSegment*>(raw_segment);
      Ms::Page* segment_page = segment->system()->page();
      const Ms::Shape shape = segment->shape();
      if (shape.empty()) {
        append_highlight_rect(&highlights, score, segment_page,
                              segment->pageBoundingRect());
        continue;
      }
      const QPointF page_offset = segment->pagePos();
      for (const QRectF& shape_rect : shape) {
        append_highlight_rect(&highlights, score, segment_page,
                              shape_rect.translated(page_offset));
      }
    }
  }
  return highlights;
}

bool notehead_is_filled(const Ms::Note* note) {
  if (!note || !note->chord()) return true;

  // Tablature noteheads are fret strings rather than oval noteheads. They
  // should remain solid text even when the chord duration is a half note.
  if (note->staff() && note->staff()->isTabStaff(note->chord()->tick())) {
    return true;
  }

  auto head_type = note->headType();
  if (head_type == Ms::NoteHead::Type::HEAD_AUTO) {
    head_type = note->chord()->durationType().headType();
  }
  switch (head_type) {
    case Ms::NoteHead::Type::HEAD_WHOLE:
    case Ms::NoteHead::Type::HEAD_HALF:
    case Ms::NoteHead::Type::HEAD_BREVIS:
      return false;
    default:
      return true;
  }
}

// Geometry copied from ScoreView::moveCursor() in MuseScore 3.6.2.  The
// cursor is kept as a set of tick intervals because its x coordinate is
// linearly interpolated between visible chord/rest segments.
struct CursorGeometry {
  int start_tick = 0;
  int end_tick = 0;
  int page = 0;
  QRectF rect;
  qreal end_x = 0.0;
};

QJsonObject cursor_json(const Ms::MasterScore* score,
                        const CursorGeometry& cursor) {
  QJsonObject result;
  result.insert("startTick", cursor.start_tick);
  result.insert("endTick", cursor.end_tick);
  result.insert("page", cursor.page);
  QJsonObject rect;
  rect.insert("x", cursor.rect.x());
  rect.insert("y", cursor.rect.y());
  rect.insert("width", cursor.rect.width());
  rect.insert("height", cursor.rect.height());
  result.insert("rect", rect);
  result.insert("endX", cursor.end_x);
  if (score) {
    const qreal start_time = score->utick2utime(cursor.start_tick);
    const qreal end_time = score->utick2utime(cursor.end_tick);
    if (qIsFinite(start_time) && qIsFinite(end_time)) {
      result.insert("startUs", qRound64(start_time * 1000000.0));
      result.insert("endUs", qRound64(end_time * 1000000.0));
    }
  }
  return result;
}

std::vector<CursorGeometry> build_cursor_geometry(Ms::MasterScore* score) {
  std::vector<CursorGeometry> result;
  if (!score) return result;

  const qreal spatium = score->spatium();
  const qreal mag = spatium / Ms::SPATIUM20;
  const qreal cursor_width =
      spatium * 2.0 +
      score->scoreFont()->width(Ms::SymId::noteheadBlack, mag);

  for (Ms::Measure* measure = score->firstMeasure(); measure;
       measure = measure->nextMeasure()) {
    Ms::System* system = measure->system();
    Ms::Page* page = system ? system->page() : nullptr;
    if (!system || !page || system->staves()->isEmpty()) continue;

    const QRectF page_box = page->abbox();
    qreal y = system->staffYpage(0) + page->pos().y();
    qreal last_staff_bottom = 0.0;
    for (int staff = 0; staff < score->nstaves(); ++staff) {
      if (staff >= system->staves()->size()) break;
      Ms::SysStaff* sys_staff = system->staff(staff);
      if (!sys_staff || !sys_staff->show() || !score->staff(staff)->show())
        continue;
      // This is intentionally the same bottom-of-SysStaff calculation used
      // by PositionCursor::move(), including its system-relative coordinate.
      last_staff_bottom = sys_staff->bbox().bottom();
    }
    if (last_staff_bottom <= 0.0) {
      last_staff_bottom = system->bbox().bottom();
    }
    const qreal cursor_height = 6.0 * spatium + last_staff_bottom;
    y -= 3.0 * spatium;
    y -= page_box.top();

    const int page_index = qMax(0, score->pageIdx(page));
    Ms::Segment* segment = measure->first(Ms::SegmentType::ChordRest);
    while (segment) {
      const int start_tick = segment->tick().ticks();
      const qreal x1 = segment->pagePos().x() - page_box.left() - spatium;
      Ms::Segment* next = segment->next(Ms::SegmentType::ChordRest);
      while (next && !next->visible()) {
        next = next->next(Ms::SegmentType::ChordRest);
      }

      int end_tick = measure->endTick().ticks();
      qreal x2 = measure->pagePos().x() + measure->width() - page_box.left();
      if (next) {
        end_tick = next->tick().ticks();
        x2 = next->pagePos().x() - page_box.left();
      } else {
        // Measure::width() includes courtesy elements; ScoreView uses the
        // explicit end-barline segment whenever it is available.
        Ms::Segment* end_bar = measure->findSegment(
            Ms::SegmentType::EndBarLine,
            measure->tick() + measure->ticks());
        if (end_bar) x2 = end_bar->pagePos().x() - page_box.left();
      }
      if (end_tick > start_tick) {
        CursorGeometry cursor;
        cursor.start_tick = start_tick;
        cursor.end_tick = end_tick;
        cursor.page = page_index;
        cursor.rect = QRectF(x1, y, cursor_width, cursor_height);
        cursor.end_x = x2 - spatium;
        result.push_back(cursor);
      }
      segment = next;
    }
  }
  std::sort(result.begin(), result.end(), [](const CursorGeometry& left,
                                             const CursorGeometry& right) {
    if (left.start_tick != right.start_tick)
      return left.start_tick < right.start_tick;
    if (left.page != right.page) return left.page < right.page;
    return left.end_tick < right.end_tick;
  });
  return result;
}

const CursorGeometry* cursor_for_tick(
    const std::vector<CursorGeometry>& cursors,
    int tick,
    int page_hint = -1) {
  const CursorGeometry* fallback = nullptr;
  for (const CursorGeometry& cursor : cursors) {
    if (page_hint >= 0 && cursor.page != page_hint) continue;
    if (tick >= cursor.start_tick && tick < cursor.end_tick) return &cursor;
    if (tick < cursor.start_tick && !fallback) fallback = &cursor;
  }
  return fallback;
}

QRectF cursor_rect_at_tick(const CursorGeometry& cursor, int tick) {
  if (cursor.end_tick <= cursor.start_tick) return cursor.rect;
  const qreal amount = qBound(
      0.0,
      static_cast<qreal>(tick - cursor.start_tick) /
          static_cast<qreal>(cursor.end_tick - cursor.start_tick),
      1.0);
  QRectF rect = cursor.rect;
  rect.moveLeft(cursor.rect.left() +
                (cursor.end_x - cursor.rect.left()) * amount);
  return rect;
}

// RepeatList stores both the original-score start tick and the unrolled
// playback start tick.  Expand the laid-out cursor intervals into that same
// unrolled coordinate space so a repeated passage does not use the geometry
// of a later original measure with the same numeric tick.
std::vector<CursorGeometry> expand_cursor_geometry(
    Ms::MasterScore* score,
    const std::vector<CursorGeometry>& original) {
  if (!score || original.empty() || score->repeatList().isEmpty()) {
    return original;
  }

  std::vector<CursorGeometry> result;
  for (const Ms::RepeatSegment* repeat : score->repeatList()) {
    if (!repeat || repeat->len() <= 0) continue;
    const int source_start = repeat->tick;
    const int source_end = source_start + repeat->len();
    for (const CursorGeometry& cursor : original) {
      const int clipped_start = qMax(cursor.start_tick, source_start);
      const int clipped_end = qMin(cursor.end_tick, source_end);
      if (clipped_end <= clipped_start) continue;

      CursorGeometry expanded = cursor;
      expanded.start_tick = repeat->utick + (clipped_start - source_start);
      expanded.end_tick = repeat->utick + (clipped_end - source_start);
      expanded.rect = cursor_rect_at_tick(cursor, clipped_start);
      expanded.end_x = cursor_rect_at_tick(cursor, clipped_end).left();
      result.push_back(expanded);
    }
  }
  if (result.empty()) return original;
  std::sort(result.begin(), result.end(), [](const CursorGeometry& left,
                                             const CursorGeometry& right) {
    if (left.start_tick != right.start_tick)
      return left.start_tick < right.start_tick;
    if (left.page != right.page) return left.page < right.page;
    return left.end_tick < right.end_tick;
  });
  return result;
}

QJsonObject note_json(
    Ms::MasterScore* score,
    const PendingNote& note,
    int end_tick) {
  QJsonObject result;
  const qreal start_time = score->utick2utime(note.tick);
  const qreal end_time = score->utick2utime(end_tick);
  result.insert("startTick", note.tick);
  result.insert("endTick", end_tick);
  result.insert("startUs", qRound64(start_time * 1000000.0));
  result.insert("endUs", qRound64(end_time * 1000000.0));
  if (note.source_tick >= 0) result.insert("sourceTick", note.source_tick);
  if (note.click_start_us >= 0)
    result.insert("clickStartUs", note.click_start_us);
  if (!note.highlight_rects.isEmpty())
    result.insert("highlightRects", note.highlight_rects);
  result.insert("pitch", note.pitch);
  result.insert("tuning", Ms::normalizedPlayEventTuning(note.tuning));
  result.insert("noteheadFilled", note.notehead_filled);
  result.insert("velocity", note.velocity);
  result.insert("channel", note.channel);
  result.insert("program", note.program);
  result.insert("bank", note.bank);
  result.insert("staff", note.staff);
  result.insert("voice", note.voice);
  result.insert("measure", note.measure);
  result.insert("page", note.page);
  if (!note.page_rect.isEmpty()) {
    QJsonObject rect;
    rect.insert("x", note.page_rect.x());
    rect.insert("y", note.page_rect.y());
    rect.insert("width", note.page_rect.width());
    rect.insert("height", note.page_rect.height());
    result.insert("rect", rect);
  }
  if (!note.notehead_image.isEmpty() && !note.notehead_rect.isEmpty()) {
    QJsonObject rect;
    rect.insert("x", note.notehead_rect.x());
    rect.insert("y", note.notehead_rect.y());
    rect.insert("width", note.notehead_rect.width());
    rect.insert("height", note.notehead_rect.height());
    result.insert("noteheadImage", note.notehead_image);
    result.insert("noteheadRect", rect);
  }
  if (note.has_cursor && !note.cursor_rect.isEmpty()) {
    QJsonObject cursor;
    cursor.insert("x", note.cursor_rect.x());
    cursor.insert("y", note.cursor_rect.y());
    cursor.insert("width", note.cursor_rect.width());
    cursor.insert("height", note.cursor_rect.height());
    result.insert("cursor", cursor);
    result.insert("cursorEndX", note.cursor_end_x);
  }
  return result;
}

// Keep non-note MIDI actions in a separate stream so the Flutter document
// model can continue exposing the note-only event list used by the renderer.
// This mirrors the events sent by Seq::initInstruments() and
// Seq::playEvent(), including expressive CC2 dynamics and pitch bends.
bool append_audio_event(QJsonArray* events,
                        qint64 time_us,
                        const Ms::MidiCoreEvent& event) {
  if (!events) return false;

  QJsonObject result;
  result.insert("timeUs", qMax<qint64>(0, time_us));
  result.insert("channel",
                qBound(0, static_cast<int>(event.channel()), 255));

  switch (event.type()) {
    case Ms::ME_CONTROLLER: {
      const int controller = event.controller();
      if (controller == Ms::CTRL_PRESS) {
        result.insert("kind", QStringLiteral("aftertouch"));
        result.insert("value", qBound(0, event.dataB(), 127));
      } else if (controller == Ms::CTRL_POLYAFTER) {
        const int packed = event.dataB();
        result.insert("kind", QStringLiteral("polyAfter"));
        result.insert("pitch", qBound(0, (packed >> 8) & 0x7f, 127));
        result.insert("value", qBound(0, packed & 0x7f, 127));
      } else if (controller == Ms::CTRL_PROGRAM ||
                 (controller >= 0 && controller <= 127)) {
        result.insert("kind", QStringLiteral("controller"));
        result.insert("controller", controller);
        result.insert("value", qBound(0, event.dataB(), 127));
      } else {
        return false;
      }
      break;
    }
    case Ms::ME_PROGRAM:
      // Fluid's mobile adapter consumes program changes through the same
      // internal controller representation used by MuseScore's channels.
      result.insert("kind", QStringLiteral("controller"));
      result.insert("controller", Ms::CTRL_PROGRAM);
      result.insert("value", qBound(0, event.dataB(), 127));
      break;
    case Ms::ME_PITCHBEND:
      result.insert("kind", QStringLiteral("pitchBend"));
      result.insert("lsb", qBound(0, event.dataA(), 127));
      result.insert("msb", qBound(0, event.dataB(), 127));
      break;
    case Ms::ME_AFTERTOUCH:
      result.insert("kind", QStringLiteral("aftertouch"));
      result.insert("value", qBound(0, event.dataA(), 127));
      break;
    case Ms::ME_POLYAFTER:
      result.insert("kind", QStringLiteral("polyAfter"));
      result.insert("pitch", qBound(0, event.dataA(), 127));
      result.insert("value", qBound(0, event.dataB(), 127));
      break;
    default:
      return false;
  }

  events->append(result);
  return true;
}

QJsonObject open_with_musescore(const char* utf8_path) {
  if (!initialize_musescore()) return {};

  Ms::MasterScore score(Ms::MScore::baseStyle());
  const auto error = score.loadMsc(QString::fromUtf8(utf8_path), true);
  if (error != Ms::Score::FileError::FILE_NO_ERROR) {
    set_error(QStringLiteral("MuseScore failed to load the score (%1)")
                  .arg(static_cast<int>(error)));
    return {};
  }

  // Match the desktop readScore() bootstrap: expressive patch selection must
  // happen before renderMidi() and before Channel::initList() is serialized.
  // Without this step ordinary Violin/Violoncello channels stay on the plain
  // bank even though MS Basic provides a dedicated expressive sample set.
  score.rebuildMidiMapping();
  score.updateChannel();
  MuseReaderAudio::updateExpressive(&score);
  score.rebuildMidiMapping();

  // A score file may persist MuseScore's view mode as
  // <layoutMode>line</layoutMode> or <layoutMode>system</layoutMode>.  Those
  // modes deliberately collapse the page list into a panoramic/single-system
  // layout.  MuseReader always exposes the paper pages as a multi-page
  // document, so override the file preference before laying the score out.
  // This mirrors MuseScore's own `switchToPageMode()` path (see
  // Score::switchToPageMode in 3.6.2).
  score.setLayoutMode(Ms::LayoutMode::PAGE);

  // Match the reader's line-oriented navigation affordance while keeping the
  // actual MuseScore MeasureNumber layout/drawing path.  MuseScore's
  // Measure::layoutMeasureNumber() uses these style flags to place the first
  // measure number of every system (and the first measure of the score).
  score.setStyleValue(Ms::Sid::showMeasureNumber, true);
  score.setStyleValue(Ms::Sid::showMeasureNumberOne, true);
  score.setStyleValue(Ms::Sid::measureNumberSystem, true);
  score.setStyleValue(Ms::Sid::measureNumberAllStaves, false);
  // Layout is the source of truth for every page image. No Flutter-side
  // geometry is used when this backend is enabled.
  score.doLayout();
  if (repair_title_frame_text_collisions(&score)) {
    score.doLayout();
  }
  // Keep the original geometry for note anchors, then expand a second copy
  // onto the same unrolled tick axis used by renderMidi().
  // MasterScore exposes RepeatList through a const accessor; setting the
  // expansion mode lets that accessor lazily build the unrolled segments.
  score.setExpandRepeats(true);
  const std::vector<CursorGeometry> cursor_geometry =
      build_cursor_geometry(&score);
  const std::vector<CursorGeometry> playback_cursor_geometry =
      expand_cursor_geometry(&score, cursor_geometry);

  QJsonObject document;
  document.insert("title", score.metaTags().value("workTitle"));
  document.insert("composer", score.metaTags().value("composer"));
  document.insert("division", Ms::MScore::division);
  document.insert("renderer", QStringLiteral("MuseScore 3.6.2 engraving"));
  document.insert("renderDpi", MUSE_READER_RENDER_DPI);
  document.insert("symbolFont", score.styleSt(Ms::Sid::MusicalSymbolFont));

  QJsonArray tempos;
  if (score.tempomap() && !score.tempomap()->empty()) {
    for (const auto& entry : *score.tempomap()) {
      QJsonObject tempo;
      tempo.insert("tick", entry.first);
      tempo.insert("qps", entry.second.tempo);
      tempos.append(tempo);
    }
  } else {
    QJsonObject tempo;
    tempo.insert("tick", 0);
    tempo.insert("qps", 2.0);
    tempos.append(tempo);
  }
  document.insert("tempos", tempos);

  QJsonArray pages;
  for (int index = 0; index < score.pages().size(); ++index) {
    Ms::Page* page = score.pages().at(index);
    const QRectF box = page->abbox();
    const RenderedPage rendered = render_page(&score, index);
    if (rendered.base64_png.isEmpty()) return {};
    QJsonObject page_json;
    page_json.insert("index", index);
    page_json.insert("width", box.width());
    page_json.insert("height", box.height());
    page_json.insert("pixelWidth", rendered.pixel_width);
    page_json.insert("pixelHeight", rendered.pixel_height);
    page_json.insert("image", rendered.base64_png);
    QJsonArray note_targets;
    const QList<Ms::Element*> page_elements = page->elements();
    for (const Ms::Element* element : page_elements) {
      if (!element->isNote()) continue;
      const auto* note = static_cast<const Ms::Note*>(element);
      const QJsonObject target = note_target_json(&score, note, box);
      if (!target.isEmpty()) note_targets.append(target);
    }
    page_json.insert("noteTargets", note_targets);
    pages.append(page_json);
  }
  document.insert("pages", pages);

  QJsonArray measures;
  for (Ms::Measure* measure = score.firstMeasure(); measure;
       measure = measure->nextMeasure()) {
    QJsonObject measure_json;
    measure_json.insert("number", measure->no() + 1);
    measure_json.insert("startTick", measure->tick().ticks());
    measure_json.insert("endTick", measure->endTick().ticks());
    measures.append(measure_json);
  }
  document.insert("measures", measures);

  QJsonArray cursor_segments;
  for (const CursorGeometry& cursor : playback_cursor_geometry) {
    cursor_segments.append(cursor_json(&score, cursor));
  }
  document.insert("cursorSegments", cursor_segments);

  // renderMidi(..., expandRepeats=true, ...) is the canonical unrolled event
  // stream. Its map key is a playback tick; utick2utime applies tempo changes,
  // pauses and repeat offsets exactly as the MuseScore sequencer does.
  //
  // renderMidi intentionally emits only time-varying MIDI actions.  The
  // initial program/bank from each instrument lives in Channel::initList()
  // (and is normally sent by Seq::initInstruments()), so it is absent from
  // EventMap.  Seed the state from the rebuilt playback mapping before
  // consuming EventMap; otherwise every channel silently starts at GM piano.
  score.rebuildMidiMapping();
  Ms::EventMap midi_events;
  score.renderMidi(&midi_events, false, true, Ms::defaultState);
  const auto tick_to_time_us = [&score](int tick) -> qint64 {
    const qreal seconds = score.utick2utime(tick);
    if (!qIsFinite(seconds)) return 0;
    return qMax<qint64>(0, qRound64(seconds * 1000000.0));
  };
  // EventMap::fixupMIDI uses the same quantized tuning key when it keeps
  // overlapping voices apart.  Mirror that key here so note-offs for two
  // equal MIDI pitches with different cent offsets are paired correctly.
  using NoteKey = std::tuple<int, int, qint64>;
  std::map<NoteKey, std::deque<PendingNote>> active;
  // A note can occur more than once in the unrolled MIDI stream (repeats,
  // tied playback events).  Render its exact glyph once and reuse the PNG.
  std::map<const Ms::Note*, RenderedNotehead> notehead_cache;
  std::map<const Ms::Note*, QJsonArray> highlight_rect_cache;
  std::map<int, int> programs;
  std::map<int, int> banks;
  QJsonArray audio_events;
  for (const Ms::MidiMapping& mapping : score.midiMapping()) {
    const Ms::Channel* channel = mapping.articulation();
    if (!channel || channel->channel() < 0) continue;
    const int channel_number =
        qBound(0, channel->channel(), 255);
    programs[channel_number] =
        qBound(0, channel->program(), 127);
    banks[channel_number] =
        qBound(0, channel->bank(), 16383);
    // renderMidi() does not include Channel::initList().  The original
    // sequencer sends these events before the first note, so serialize them at
    // time zero to select every mapped instrument and its mixer state.
    for (const Ms::MidiCoreEvent& init_event : channel->initList()) {
      // Channel::updateInitList() intentionally leaves the core event's
      // channel at its default value; Seq::initInstruments() supplies the
      // articulation channel when it wraps the event as NPlayEvent.
      const Ms::NPlayEvent playback_event(
          init_event.type(), static_cast<uchar>(channel_number),
          static_cast<uchar>(init_event.dataA()),
          static_cast<uchar>(init_event.dataB()));
      append_audio_event(&audio_events, 0, playback_event);
    }
  }
  QJsonArray events;
  int end_tick = score.repeatList().ticks();
  if (end_tick <= 0 && score.lastMeasure()) {
    end_tick = score.lastMeasure()->endTick().ticks();
  }
  for (const auto& item : midi_events) {
    const int tick = item.first;
    const Ms::NPlayEvent& event = item.second;
    end_tick = qMax(end_tick, tick);
    append_audio_event(&audio_events, tick_to_time_us(tick), event);
    if (event.type() == Ms::ME_CONTROLLER) {
      const int channel = event.channel();
      const int value = qBound(0, event.value(), 127);
      if (event.controller() == Ms::CTRL_HBANK) {
        banks[channel] = (banks[channel] & 0x7f) | (value << 7);
        continue;
      }
      if (event.controller() == Ms::CTRL_LBANK) {
        banks[channel] = (banks[channel] & 0x3f80) | value;
        continue;
      }
      if (event.controller() == Ms::CTRL_PROGRAM) {
        programs[channel] = value;
        continue;
      }
    }
    // Imported MIDI streams can contain a native ME_PROGRAM event instead of
    // MuseScore's CTRL_PROGRAM controller representation.  Keep both forms
    // in the same per-channel state machine.
    if (event.type() == Ms::ME_PROGRAM) {
      programs[event.channel()] = qBound(0, event.dataB(), 127);
      continue;
    }
    const int pitch = event.pitch();
    const double tuning = event.hasTuning() ? event.tuning() : 0.0;
    const NoteKey key(event.channel(), pitch,
                      Ms::playEventTuningKey(tuning));
    if (event.type() == Ms::ME_NOTEON && event.velo() > 0) {
      int staff = event.getOriginatingStaff();
      int measure_number = 1;
      int voice = 0;
      int page = 0;
      QRectF page_rect;
      QString notehead_image;
      QRectF notehead_rect;
      QRectF cursor_rect;
      qreal cursor_end_x = 0.0;
      bool has_cursor = false;
      bool notehead_filled = true;
      int source_tick = -1;
      qint64 click_start_us = -1;
      QJsonArray highlight_rects;
      if (event.note() && event.note()->chord() && event.note()->chord()->measure()) {
        Ms::Measure* measure = event.note()->chord()->measure();
        source_tick = event.note()->chord()->tick().ticks();
        const int click_utick = score.repeatList().tick2utick(source_tick);
        const qreal click_time = score.utick2utime(click_utick);
        if (qIsFinite(click_time) && click_time >= 0.0)
          click_start_us = qRound64(click_time * 1000000.0);
        staff = qMax(0, event.note()->staffIdx());
        voice = event.note()->voice();
        measure_number = measure->no() + 1;
        notehead_filled = notehead_is_filled(event.note());
        if (measure->system() && measure->system()->page()) {
          Ms::Page* note_page = measure->system()->page();
          page = qMax(0, score.pageIdx(note_page));
          page_rect = event.note()
                          ->pageBoundingRect()
                          .translated(-note_page->abbox().topLeft())
                          .normalized();
          const Ms::Note* source_note = event.note();
          const Ms::Note* first_tied_note = source_note->firstTiedNote();
          auto cached_highlights = highlight_rect_cache.find(first_tied_note);
          if (cached_highlights == highlight_rect_cache.end()) {
            cached_highlights = highlight_rect_cache
                                    .emplace(first_tied_note,
                                             tied_highlight_rects(
                                                 &score, first_tied_note))
                                    .first;
          }
          highlight_rects = cached_highlights->second;
          auto cached_notehead = notehead_cache.find(source_note);
          if (cached_notehead == notehead_cache.end()) {
            cached_notehead =
                notehead_cache.emplace(source_note,
                                       render_notehead(&score, source_note))
                    .first;
          }
          if (!cached_notehead->second.base64_png.isEmpty() &&
              !cached_notehead->second.page_rect.isEmpty()) {
            notehead_image = cached_notehead->second.base64_png;
            notehead_rect = cached_notehead->second.page_rect
                                .translated(-note_page->abbox().topLeft())
                                .normalized();
          }
          if (event.note()->chord()->segment()) {
            const int original_tick =
                event.note()->chord()->segment()->tick().ticks();
            const CursorGeometry* geometry =
                cursor_for_tick(cursor_geometry, original_tick, page);
            if (geometry) {
              cursor_rect = cursor_rect_at_tick(*geometry, original_tick);
              cursor_end_x = geometry->end_x;
              has_cursor = true;
            }
          }
        }
      }
      active[key].push_back(
          {tick,
           static_cast<int>(event.channel()),
           programs[event.channel()],
           banks[event.channel()],
           pitch,
           Ms::normalizedPlayEventTuning(tuning),
           notehead_filled,
           event.velo(),
           staff,
           voice,
           measure_number,
           page,
           page_rect,
           notehead_image,
           notehead_rect,
           cursor_rect,
           cursor_end_x,
           has_cursor,
           source_tick,
           click_start_us,
           highlight_rects});
    } else if (event.type() == Ms::ME_NOTEOFF ||
               (event.type() == Ms::ME_NOTEON && event.velo() == 0)) {
      auto open = active.find(key);
      if (open == active.end() || open->second.empty()) continue;
      PendingNote note = open->second.front();
      open->second.pop_front();
      events.append(note_json(&score, note, qMax(tick, note.tick + 1)));
    }
  }
  for (const auto& entry : active) {
    for (const PendingNote& note : entry.second) {
      events.append(
          note_json(&score, note, note.tick + Ms::MScore::division));
      end_tick = qMax(end_tick, note.tick + Ms::MScore::division);
    }
  }
  document.insert("events", events);
  if (!audio_events.isEmpty()) document.insert("audioEvents", audio_events);
  document.insert("endTick", end_tick);
  document.insert("durationUs", qRound64(score.utick2utime(end_tick) * 1000000.0));
  return document;
}
#endif
}  // namespace

extern "C" MUSE_READER_EXPORT const char* muse_reader_open_json(
    const char* utf8_path) {
  std::lock_guard<std::mutex> guard(g_engine_mutex);
  g_last_error.clear();
  if (!utf8_path || utf8_path[0] == '\0') {
    g_last_error = "The score path is empty";
    return nullptr;
  }

#if defined(MUSE_READER_WITH_MUSESCORE)
  try {
    const QJsonObject document = open_with_musescore(utf8_path);
    if (document.isEmpty()) return nullptr;
    const QByteArray json =
        QJsonDocument(document).toJson(QJsonDocument::Compact);
    return copy_string(json.toStdString());
  } catch (const std::exception& error) {
    g_last_error = std::string("MuseScore rendering failed: ") + error.what();
    return nullptr;
  } catch (...) {
    g_last_error = "MuseScore rendering failed with an unknown native error";
    return nullptr;
  }
#else
  (void)utf8_path;
  g_last_error =
      "MuseScore native core is disabled; configure MUSE_READER_WITH_MUSESCORE";
  return nullptr;
#endif
}

extern "C" MUSE_READER_EXPORT int muse_reader_initialize(void) {
  std::lock_guard<std::mutex> guard(g_engine_mutex);
  g_last_error.clear();
#if defined(MUSE_READER_WITH_MUSESCORE)
  return initialize_musescore() ? 1 : 0;
#else
  g_last_error =
      "MuseScore native core is disabled; configure MUSE_READER_WITH_MUSESCORE";
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT int muse_reader_is_available(void) {
#if defined(MUSE_READER_WITH_MUSESCORE)
  return 1;
#else
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT void muse_reader_free_json(const char* json) {
  std::free(const_cast<char*>(json));
}

extern "C" MUSE_READER_EXPORT const char* muse_reader_last_error(void) {
  std::lock_guard<std::mutex> guard(g_engine_mutex);
  return g_last_error.c_str();
}
