#pragma once

namespace Ms {
class MasterScore;
}

namespace MuseReaderAudio {

// Apply the same automatic expressive-patch selection that MuseScore runs
// after loading a score. The function is deliberately separate from the C
// playback ABI because score loading and audio rendering use different locks.
bool updateExpressive(Ms::MasterScore* score);

}  // namespace MuseReaderAudio
