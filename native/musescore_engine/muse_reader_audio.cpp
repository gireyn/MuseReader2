#include "muse_reader_engine.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#if defined(MUSE_READER_WITH_FLUIDSYNTH)
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QJsonValue>
#include <QString>

#include "event.h"
#include "fluid/fluid.h"
#if defined(MUSE_READER_WITH_MUSESCORE)
#include "score.h"
#endif
#endif

#include "muse_reader_audio_internal.h"

namespace {

constexpr int kAudioSampleRate = 44100;
// MuseScore's playback channel is an unsigned byte.  A score may allocate
// more than the sixteen wire-MIDI channels when articulation channels and
// instrument changes are present.
constexpr int kMaxPlaybackChannel = 255;

#if defined(MUSE_READER_WITH_FLUIDSYNTH)

struct AudioAction {
  enum class Kind : unsigned char {
    controller = 0,
    pitch_bend = 1,
    aftertouch = 2,
    poly_after = 3,
    program_select = 4,
    note_off = 5,
    note_on = 6,
  };

  double time_us = 0.0;
  // Preserve the source event order for actions sharing a timestamp.  A
  // program change must stay adjacent to the note it configures; sorting all
  // program actions ahead of all note-ons would make simultaneous notes with
  // different instruments use whichever program happened to be last.
  std::uint64_t order = 0;
  Kind kind = Kind::note_on;
  int channel = 0;
  int pitch = 60;
  // Per-note cent offset carried by MuseScore's PlayEvent.  FluidSynth's
  // voice API expects this as a midicent adjustment rather than a channel
  // pitch bend, so simultaneous notes can have independent tunings.
  double tuning = 0.0;
  int velocity = 80;
  int program = 0;
  int bank = 0;
  // MIDI data bytes. For a controller these are controller/value; for a
  // pitch bend they are LSB/MSB; for aftertouch they carry pressure data.
  int data_a = 0;
  int data_b = 0;
};

struct ParsedNote {
  double start_us = 0.0;
  double end_us = 1.0;
  int channel = 0;
  int pitch = 60;
  double tuning = 0.0;
  int velocity = 80;
  int program = 0;
  int bank = 0;
};

std::mutex g_audio_mutex;
std::unique_ptr<FluidS::Fluid> g_fluid;
std::vector<AudioAction> g_actions;
std::vector<float> g_effect1;
std::vector<float> g_effect2;
size_t g_next_action = 0;
double g_audio_cursor_us = 0.0;
double g_audio_speed = 1.0;
double g_audio_tail_end_us = 0.0;
bool g_audio_active = false;
std::string g_audio_error;

void set_audio_error(const std::string& message) {
  g_audio_error = message;
}

qint64 json_integer(const QJsonObject& object, const char* key, qint64 fallback) {
  const QJsonValue value = object.value(QLatin1String(key));
  if (value.isDouble()) return qRound64(value.toDouble());
  if (value.isString()) return value.toString().toLongLong();
  return fallback;
}

int json_int(const QJsonObject& object, const char* key, int fallback) {
  const qint64 value = json_integer(object, key, fallback);
  return static_cast<int>(qBound<qint64>(INT_MIN, value, INT_MAX));
}

double json_double(const QJsonObject& object, const char* key,
                   double fallback) {
  const QJsonValue value = object.value(QLatin1String(key));
  double result = fallback;
  if (value.isDouble()) {
    result = value.toDouble();
  } else if (value.isString()) {
    bool ok = false;
    const double parsed = value.toString().toDouble(&ok);
    if (ok) result = parsed;
  }
  if (!std::isfinite(result)) return fallback;
  // Keep the same safety envelope as MuseScore's
  // normalizedPlayEventTuning() helper.
  return std::clamp(result, -1000000.0, 1000000.0);
}

bool ensure_fluid_locked() {
  if (g_fluid) return true;

  try {
    auto candidate = std::make_unique<FluidS::Fluid>();
    candidate->init(static_cast<float>(kAudioSampleRate));
    if (!candidate->addSoundFont(QStringLiteral(":/sound/MS Basic.sf3"))) {
      set_audio_error("Unable to load embedded MS Basic.sf3");
      return false;
    }
    g_fluid = std::move(candidate);
    // Most platform callbacks request 512 or 1024 frames. Reserve enough
    // space up front so the first render does not grow these scratch buffers.
    g_effect1.reserve(2048);
    g_effect2.reserve(2048);
    return true;
  } catch (const std::exception& error) {
    set_audio_error(std::string("Unable to initialize FluidSynth: ") +
                    error.what());
    g_fluid.reset();
    return false;
  } catch (...) {
    set_audio_error("Unable to initialize FluidSynth");
    g_fluid.reset();
    return false;
  }
}

void dispatch_controller(int channel, int controller, int value) {
  if (!g_fluid || controller < 0 ||
      (controller > 127 && controller != Ms::CTRL_PROGRAM)) {
    return;
  }
  const Ms::NPlayEvent event(
      Ms::ME_CONTROLLER, static_cast<uchar>(channel),
      static_cast<uchar>(controller), static_cast<uchar>(value));
  g_fluid->play(event);
}

void dispatch_action(const AudioAction& action) {
  if (!g_fluid) return;
  Ms::NPlayEvent event;
  switch (action.kind) {
    case AudioAction::Kind::controller:
      dispatch_controller(action.channel, action.data_a, action.data_b);
      return;
    case AudioAction::Kind::pitch_bend:
      event = Ms::NPlayEvent(Ms::ME_PITCHBEND,
                             static_cast<uchar>(action.channel),
                             static_cast<uchar>(action.data_a),
                             static_cast<uchar>(action.data_b));
      break;
    case AudioAction::Kind::aftertouch:
      event = Ms::NPlayEvent(Ms::ME_AFTERTOUCH,
                             static_cast<uchar>(action.channel),
                             static_cast<uchar>(action.data_a), 0);
      break;
    case AudioAction::Kind::poly_after:
      event = Ms::NPlayEvent(Ms::ME_POLYAFTER,
                             static_cast<uchar>(action.channel),
                             static_cast<uchar>(action.data_a),
                             static_cast<uchar>(action.data_b));
      break;
    case AudioAction::Kind::program_select:
      // Bank select is part of the MuseScore instrument state. Replaying it
      // immediately before the program change keeps channel 10 percussion
      // and higher-bank MuseScore variants intact after a seek.
      dispatch_controller(action.channel, Ms::CTRL_HBANK,
                          (action.bank >> 7) & 0x7f);
      dispatch_controller(action.channel, Ms::CTRL_LBANK, action.bank & 0x7f);
      dispatch_controller(action.channel, Ms::CTRL_PROGRAM, action.program);
      return;
    case AudioAction::Kind::note_off:
      event = Ms::NPlayEvent(Ms::ME_NOTEOFF,
                             static_cast<uchar>(action.channel),
                             static_cast<uchar>(action.pitch), 0);
      event.setTuning(static_cast<float>(action.tuning));
      break;
    case AudioAction::Kind::note_on:
      event = Ms::NPlayEvent(Ms::ME_NOTEON,
                             static_cast<uchar>(action.channel),
                             static_cast<uchar>(action.pitch),
                             static_cast<uchar>(action.velocity));
      event.setTuning(static_cast<float>(action.tuning));
      break;
  }
  g_fluid->play(event);
}

AudioAction make_action(double time_us, std::uint64_t order,
                        AudioAction::Kind kind, int channel) {
  AudioAction action;
  action.time_us = time_us;
  action.order = order;
  action.kind = kind;
  action.channel = channel;
  return action;
}

QString action_kind(const QJsonObject& object) {
  QString kind = object.value(QLatin1String("kind")).toString().toLower();
  if (kind.isEmpty()) {
    kind = object.value(QLatin1String("type")).toString().toLower();
  }
  return kind;
}

bool is_program_kind(const QString& kind) {
  return kind == QLatin1String("program") ||
         kind == QLatin1String("programchange") ||
         kind == QLatin1String("program_change") ||
         kind == QLatin1String("program-change") ||
         kind == QLatin1String("programselect") ||
         kind == QLatin1String("program_select") ||
         kind == QLatin1String("program-select");
}

bool is_control_kind(const QString& kind) {
  return kind == QLatin1String("controller") ||
         kind == QLatin1String("cc") || is_program_kind(kind) ||
         kind == QLatin1String("pitchbend") ||
         kind == QLatin1String("pitch_bend") ||
         kind == QLatin1String("pitch-bend") ||
         kind == QLatin1String("aftertouch") ||
         kind == QLatin1String("channelpressure") ||
         kind == QLatin1String("channel_pressure") ||
         kind == QLatin1String("channel-pressure") ||
         kind == QLatin1String("polyafter") ||
         kind == QLatin1String("poly_after") ||
         kind == QLatin1String("poly-after") ||
         kind == QLatin1String("polyphonicaftertouch") ||
         kind == QLatin1String("polyphonic_aftertouch") ||
         kind == QLatin1String("polyphonic-aftertouch");
}

bool is_expressive_bank(int bank) {
  // MuseScore's MS Basic mapping puts bank 0/8 expressive variants on 17/18
  // and puts the variants of banks 20..126 one bank higher. The modulo keeps
  // the same rule working for SoundFont bank groups above 128.
  const int relative_bank = bank % 129;
  return relative_bank == 17 || relative_bank == 18 ||
         (relative_bank >= 21 && relative_bank <= 127);
}

int action_state_key(const AudioAction& action) {
  switch (action.kind) {
    case AudioAction::Kind::controller:
      return action.data_a;
    case AudioAction::Kind::pitch_bend:
      return 256;
    case AudioAction::Kind::aftertouch:
      return 257;
    case AudioAction::Kind::poly_after:
      return 512 + action.data_a;
    case AudioAction::Kind::program_select:
      return 258;
    default:
      return -1;
  }
}

double action_time_us(const QJsonObject& object) {
  const qint64 value = object.contains(QLatin1String("timeUs"))
                           ? json_integer(object, "timeUs", 0)
                           : json_integer(object, "startUs", 0);
  return std::max(0.0, static_cast<double>(value));
}

bool parse_control_action(const QJsonObject& object, std::uint64_t order,
                          AudioAction* result) {
  if (!result) return false;
  const QString kind = action_kind(object);
  const bool control_object =
      is_control_kind(kind) ||
      (kind.isEmpty() &&
       (object.contains(QLatin1String("controller")) ||
        object.contains(QLatin1String("cc")) ||
        object.contains(QLatin1String("ctrl"))));
  if (!control_object) return false;

  const int channel =
      qBound(0, json_int(object, "channel", 0), kMaxPlaybackChannel);
  const double time_us = action_time_us(object);
  AudioAction action = make_action(time_us, order,
                                   AudioAction::Kind::controller, channel);

  if (kind == QLatin1String("pitchbend") ||
      kind == QLatin1String("pitch_bend") ||
      kind == QLatin1String("pitch-bend")) {
    int lsb = json_int(object, "lsb", json_int(object, "dataA", 0));
    int msb = json_int(object, "msb", json_int(object, "dataB", 64));
    if (object.contains(QLatin1String("value")) &&
        !object.contains(QLatin1String("lsb")) &&
        !object.contains(QLatin1String("msb")) &&
        !object.contains(QLatin1String("dataA")) &&
        !object.contains(QLatin1String("dataB"))) {
      const int bend = qBound(0, json_int(object, "value", 8192), 16383);
      lsb = bend & 0x7f;
      msb = (bend >> 7) & 0x7f;
    }
    action.kind = AudioAction::Kind::pitch_bend;
    action.data_a = qBound(0, lsb, 127);
    action.data_b = qBound(0, msb, 127);
    *result = action;
    return true;
  }

  if (kind == QLatin1String("aftertouch") ||
      kind == QLatin1String("channelpressure") ||
      kind == QLatin1String("channel_pressure") ||
      kind == QLatin1String("channel-pressure")) {
    action.kind = AudioAction::Kind::aftertouch;
    action.data_a = qBound(
        0, json_int(object, "value",
                    json_int(object, "pressure",
                             json_int(object, "dataA",
                                      json_int(object, "dataB", 0)))),
        127);
    *result = action;
    return true;
  }

  if (kind == QLatin1String("polyafter") ||
      kind == QLatin1String("poly_after") ||
      kind == QLatin1String("poly-after") ||
      kind == QLatin1String("polyphonicaftertouch") ||
      kind == QLatin1String("polyphonic_aftertouch") ||
      kind == QLatin1String("polyphonic-aftertouch")) {
    action.kind = AudioAction::Kind::poly_after;
    action.data_a = qBound(
        0, json_int(object, "pitch",
                    json_int(object, "note", json_int(object, "dataA", 60))),
        127);
    action.data_b = qBound(
        0, json_int(object, "value",
                    json_int(object, "pressure", json_int(object, "dataB", 0))),
        127);
    *result = action;
    return true;
  }

  if (is_program_kind(kind)) {
    // This form is accepted for callers that provide a standalone program
    // action. Native score payloads use regular controller actions so bank
    // select and program changes retain their original ordering.
    action.kind = AudioAction::Kind::program_select;
    action.program = qBound(
        0, json_int(object, "program", json_int(object, "value", 0)), 127);
    action.bank = qBound(0, json_int(object, "bank", 0), 16383);
    *result = action;
    return true;
  }

  int controller = json_int(
      object, "controller",
      json_int(object, "cc", json_int(object, "ctrl",
                                       json_int(object, "dataA", -1))));
  int value = json_int(
      object, "value",
      json_int(object, "program", json_int(object, "dataB", 0)));
  if (controller == Ms::CTRL_PRESS) {
    action.kind = AudioAction::Kind::aftertouch;
    action.data_a = qBound(
        0, json_int(object, "value", json_int(object, "pressure", value)),
        127);
  } else if (controller == Ms::CTRL_POLYAFTER) {
    action.kind = AudioAction::Kind::poly_after;
    if (object.contains(QLatin1String("pitch")) ||
        object.contains(QLatin1String("note"))) {
      action.data_a = qBound(0, json_int(object, "pitch",
                                          json_int(object, "note", 60)), 127);
      action.data_b = qBound(0, value, 127);
    } else {
      // MuseScore's MIDI reader stores an internal CTRL_POLYAFTER value as
      // (note << 8) | pressure, even though a wire MIDI message has two
      // separate data bytes.
      action.data_a = qBound(0, (value >> 8) & 0x7f, 127);
      action.data_b = qBound(0, value & 0x7f, 127);
    }
  } else {
    if (controller < 0 ||
        (controller > 127 && controller != Ms::CTRL_PROGRAM)) {
      return false;
    }
    if (controller == Ms::CTRL_PROGRAM &&
        object.contains(QLatin1String("bank"))) {
      action.kind = AudioAction::Kind::program_select;
      action.program = qBound(0, value, 127);
      action.bank = qBound(0, json_int(object, "bank", 0), 16383);
    } else {
      action.kind = AudioAction::Kind::controller;
      action.data_a = controller;
      action.data_b = qBound(0, value, 127);
    }
  }
  *result = action;
  return true;
}

bool parse_actions(const char* events_json, int64_t position_us) {
  g_actions.clear();
  g_next_action = 0;
  g_audio_cursor_us = std::max<double>(0.0, static_cast<double>(position_us));
  g_audio_tail_end_us = g_audio_cursor_us;

  if (!events_json || events_json[0] == '\0') {
    set_audio_error("The audio event list is empty");
    return false;
  }

  QJsonParseError parse_error;
  const QJsonDocument document = QJsonDocument::fromJson(
      QByteArray(events_json), &parse_error);
  if (!document.isArray()) {
    set_audio_error("The audio event list is not a JSON array: " +
                    parse_error.errorString().toStdString());
    return false;
  }

  const double position = g_audio_cursor_us;
  std::uint64_t source_order = 0;
  std::vector<AudioAction> control_actions;
  std::vector<ParsedNote> notes;
  std::map<int, double> first_program_time;
  std::map<int, std::vector<double>> cc2_times;

  for (const QJsonValue& value : document.array()) {
    if (!value.isObject()) continue;
    const QJsonObject object = value.toObject();
    const QString kind = action_kind(object);
    if (is_control_kind(kind) ||
        (kind.isEmpty() &&
         (object.contains(QLatin1String("controller")) ||
          object.contains(QLatin1String("cc")) ||
          object.contains(QLatin1String("ctrl"))))) {
      AudioAction action;
      if (parse_control_action(object, source_order, &action)) {
        control_actions.push_back(action);
        if ((action.kind == AudioAction::Kind::controller &&
             action.data_a == Ms::CTRL_PROGRAM) ||
            action.kind == AudioAction::Kind::program_select) {
          const auto existing = first_program_time.find(action.channel);
          if (existing == first_program_time.end() ||
              action.time_us < existing->second) {
            first_program_time[action.channel] = action.time_us;
          }
        }
        if (action.kind == AudioAction::Kind::controller &&
            action.data_a == Ms::CTRL_BREATH) {
          cc2_times[action.channel].push_back(action.time_us);
        }
      }
      ++source_order;
      continue;
    }

    // Unknown explicitly typed actions are ignored. Objects without a kind
    // retain the original note-event format for older bridge clients.
    if (!kind.isEmpty() && kind != QLatin1String("note")) {
      ++source_order;
      continue;
    }

    const qint64 start_value = json_integer(object, "startUs", 0);
    const qint64 default_end =
        start_value >= std::numeric_limits<qint64>::max() - 1
            ? std::numeric_limits<qint64>::max()
            : start_value + 1;
    const qint64 end_value = json_integer(object, "endUs", default_end);
    const double start_us = std::max(0.0, static_cast<double>(start_value));
    double end_us = static_cast<double>(end_value);
    if (!std::isfinite(end_us) || end_us <= start_us) {
      end_us = start_us + 1.0;
    }

    ParsedNote note;
    note.start_us = start_us;
    note.end_us = end_us;
    ++source_order;
    note.channel =
        qBound(0, json_int(object, "channel", 0), kMaxPlaybackChannel);
    note.pitch = qBound(0, json_int(object, "pitch", 60), 127);
    note.velocity = qBound(1, json_int(object, "velocity", 80), 127);
    note.program = qBound(0, json_int(object, "program", 0), 127);
    note.bank = qBound(0, json_int(object, "bank", 0), 16383);
    note.tuning = object.contains(QLatin1String("tuning"))
                      ? json_double(object, "tuning", 0.0)
                      : json_double(object, "cents", 0.0);
    notes.push_back(note);
  }

  std::stable_sort(control_actions.begin(), control_actions.end(),
                   [](const AudioAction& left, const AudioAction& right) {
                     if (left.time_us != right.time_us)
                       return left.time_us < right.time_us;
                     return left.order < right.order;
                   });
  for (auto& entry : cc2_times) {
    std::sort(entry.second.begin(), entry.second.end());
  }

  // Resetting FluidSynth on every start is intentional. Recreate the latest
  // state before the seek point, then let future events run at their original
  // score times. This mirrors Seq::initInstruments() plus the sequencer's
  // controller stream when playback starts from the middle of a score.
  std::map<std::pair<int, int>, AudioAction> latest_controls;
  for (const AudioAction& action : control_actions) {
    if (action.time_us < position) {
      const int key = action_state_key(action);
      if (key >= 0) latest_controls[{action.channel, key}] = action;
    }
  }
  std::vector<AudioAction> replay_controls;
  replay_controls.reserve(latest_controls.size());
  for (const auto& entry : latest_controls) replay_controls.push_back(entry.second);
  std::stable_sort(replay_controls.begin(), replay_controls.end(),
                   [](const AudioAction& left, const AudioAction& right) {
                     return left.order < right.order;
                   });

  std::vector<AudioAction> scheduled;
  scheduled.reserve(replay_controls.size() + control_actions.size() +
                    notes.size() * 3);
  auto schedule = [&scheduled](AudioAction action, double time_us) {
    action.time_us = time_us;
    action.order = scheduled.size();
    scheduled.push_back(action);
  };
  for (const AudioAction& action : replay_controls) schedule(action, position);
  for (const AudioAction& action : control_actions) {
    if (action.time_us >= position) schedule(action, action.time_us);
  }

  bool has_playable_note = false;
  for (const ParsedNote& note : notes) {
    if (note.end_us <= position) continue;
    has_playable_note = true;
    const double note_on_us = std::max(note.start_us, position);

    // Legacy payloads carry program/bank on each note. Keep that path for
    // compatibility, but prefer the exact controller stream whenever this
    // channel has an explicit program event.
    const auto program_time = first_program_time.find(note.channel);
    if (program_time == first_program_time.end() ||
        program_time->second > note_on_us) {
      AudioAction program = make_action(
          note_on_us, 0, AudioAction::Kind::program_select, note.channel);
      program.pitch = note.pitch;
      program.tuning = note.tuning;
      program.program = note.program;
      program.bank = note.bank;
      schedule(program, note_on_us);
    }

    // Older direct callers may still send only note maps. Expressive MS Basic
    // presets otherwise start with CC2=0 and are practically silent.
    bool has_cc2_state = false;
    const auto cc2_times_for_channel = cc2_times.find(note.channel);
    if (cc2_times_for_channel != cc2_times.end()) {
      const auto first_after_note = std::upper_bound(
          cc2_times_for_channel->second.begin(),
          cc2_times_for_channel->second.end(), note_on_us);
      has_cc2_state = first_after_note !=
                      cc2_times_for_channel->second.begin();
    }
    if (!has_cc2_state && is_expressive_bank(note.bank)) {
      AudioAction expression = make_action(
          note_on_us, 0, AudioAction::Kind::controller, note.channel);
      expression.data_a = Ms::CTRL_BREATH;
      expression.data_b = note.velocity;
      schedule(expression, note_on_us);
    }

    AudioAction note_on =
        make_action(note_on_us, 0, AudioAction::Kind::note_on, note.channel);
    note_on.pitch = note.pitch;
    note_on.tuning = note.tuning;
    note_on.velocity = note.velocity;
    note_on.program = note.program;
    note_on.bank = note.bank;
    schedule(note_on, note_on_us);

    AudioAction note_off =
        make_action(note.end_us, 0, AudioAction::Kind::note_off, note.channel);
    note_off.pitch = note.pitch;
    note_off.tuning = note.tuning;
    note_off.program = note.program;
    note_off.bank = note.bank;
    schedule(note_off, note.end_us);
    g_audio_tail_end_us = std::max(g_audio_tail_end_us, note.end_us);
  }

  if (!has_playable_note) {
    set_audio_error("The audio event list contains no playable notes");
    return false;
  }

  g_actions = std::move(scheduled);

  std::stable_sort(g_actions.begin(), g_actions.end(),
                   [](const AudioAction& left, const AudioAction& right) {
                     if (left.time_us != right.time_us)
                       return left.time_us < right.time_us;
                     return left.order < right.order;
                   });
  // Allow the SoundFont release envelope to ring out without holding the
  // platform audio stream open indefinitely.
  g_audio_tail_end_us += 750000.0 * g_audio_speed;
  return true;
}

#endif  // MUSE_READER_WITH_FLUIDSYNTH

}  // namespace

namespace MuseReaderAudio {

bool updateExpressive(Ms::MasterScore* score) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH) && defined(MUSE_READER_WITH_MUSESCORE)
  if (!score) return false;
  std::lock_guard<std::mutex> guard(g_audio_mutex);
  if (!ensure_fluid_locked()) return false;

  // MuseScore's desktop file loader performs this step after rebuilding the
  // MIDI mapping. It is what turns an ordinary violin/cello channel (bank 0)
  // into the matching MS Basic expressive variant (bank 17, 18, or +1).
  score->updateExpressive(g_fluid.get());
  return true;
#else
  (void)score;
  return false;
#endif
}

}  // namespace MuseReaderAudio

extern "C" MUSE_READER_EXPORT int muse_reader_audio_is_available(void) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  return 1;
#else
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT int muse_reader_audio_initialize(void) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  if (!muse_reader_initialize()) {
    std::lock_guard<std::mutex> guard(g_audio_mutex);
    const char* error = muse_reader_last_error();
    set_audio_error(error && error[0] ? error :
                    "MuseScore core initialization failed");
    return 0;
  }
  std::lock_guard<std::mutex> guard(g_audio_mutex);
  g_audio_error.clear();
  return ensure_fluid_locked() ? 1 : 0;
#else
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT int muse_reader_audio_start_json(
    const char* events_json,
    int64_t position_us,
    double speed) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  if (!muse_reader_audio_initialize()) return 0;
  std::lock_guard<std::mutex> guard(g_audio_mutex);
  g_audio_error.clear();
  g_audio_speed = std::isfinite(speed) ? std::clamp(speed, 0.1, 4.0) : 1.0;
  if (!parse_actions(events_json, position_us)) {
    g_audio_active = false;
    return 0;
  }
  if (!ensure_fluid_locked()) {
    g_audio_active = false;
    return 0;
  }
  g_fluid->system_reset();
  g_audio_active = true;
  return 1;
#else
  (void)events_json;
  (void)position_us;
  (void)speed;
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT size_t muse_reader_audio_render(
    float* stereo_interleaved,
    size_t frames) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  if (!stereo_interleaved || frames == 0 ||
      frames > std::numeric_limits<size_t>::max() / 2) {
    return 0;
  }
  std::fill(stereo_interleaved, stereo_interleaved + frames * 2, 0.0f);

  std::lock_guard<std::mutex> guard(g_audio_mutex);
  if (!g_audio_active || !g_fluid) return 0;

  size_t produced = 0;
  while (produced < frames) {
    while (g_next_action < g_actions.size() &&
           g_actions[g_next_action].time_us <= g_audio_cursor_us + 0.01) {
      dispatch_action(g_actions[g_next_action++]);
    }

    if (g_next_action >= g_actions.size() &&
        g_audio_cursor_us >= g_audio_tail_end_us) {
      g_audio_active = false;
      break;
    }

    size_t chunk = std::min<size_t>(frames - produced, 1024);
    if (g_next_action < g_actions.size()) {
      const double next_time = g_actions[g_next_action].time_us;
      if (next_time > g_audio_cursor_us) {
        const double frames_until =
            (next_time - g_audio_cursor_us) * kAudioSampleRate /
            (1000000.0 * g_audio_speed);
        if (frames_until < 1.0) {
          chunk = 1;
        } else {
          chunk = std::min<size_t>(chunk,
                                   static_cast<size_t>(frames_until));
        }
      }
    }
    if (chunk == 0) chunk = 1;

    g_effect1.resize(chunk * 2);
    g_effect2.resize(chunk * 2);
    std::fill(g_effect1.begin(), g_effect1.end(), 0.0f);
    std::fill(g_effect2.begin(), g_effect2.end(), 0.0f);
    g_fluid->process(static_cast<unsigned>(chunk),
                     stereo_interleaved + produced * 2, g_effect1.data(),
                     g_effect2.data());
    for (size_t index = 0; index < chunk * 2; ++index) {
      float& sample = stereo_interleaved[produced * 2 + index];
      sample = std::clamp(sample * 0.85f, -1.0f, 1.0f);
    }
    g_audio_cursor_us +=
        static_cast<double>(chunk) * 1000000.0 * g_audio_speed /
        kAudioSampleRate;
    produced += chunk;
  }
  return produced;
#else
  (void)stereo_interleaved;
  (void)frames;
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT int muse_reader_audio_is_active(void) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  std::lock_guard<std::mutex> guard(g_audio_mutex);
  return g_audio_active ? 1 : 0;
#else
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT void muse_reader_audio_stop(void) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  std::lock_guard<std::mutex> guard(g_audio_mutex);
  if (g_fluid) g_fluid->allSoundsOff(-1);
  g_actions.clear();
  g_next_action = 0;
  g_audio_cursor_us = 0.0;
  g_audio_tail_end_us = 0.0;
  g_audio_active = false;
#endif
}

extern "C" MUSE_READER_EXPORT int muse_reader_audio_sample_rate(void) {
  return kAudioSampleRate;
}

extern "C" MUSE_READER_EXPORT const char* muse_reader_audio_last_error(void) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  std::lock_guard<std::mutex> guard(g_audio_mutex);
  return g_audio_error.c_str();
#else
  return "Bundled FluidSynth is disabled";
#endif
}
