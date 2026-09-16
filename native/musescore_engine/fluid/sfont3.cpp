/*
 * SF3 sample decoder for the vendored MuseScore FluidSynth fork.
 *
 * MuseScore's desktop build uses libsndfile for this small adapter. Mobile
 * builds keep the same SF3 format but decode each embedded Ogg stream with
 * stb_vorbis, avoiding a platform-specific libsndfile/ Vorbis dependency.
 */

#include "sfont.h"

#include <climits>
#include <cstdlib>
#include <cstring>

#include "../third_party/stb_vorbis_api.h"

namespace FluidS {

bool Sample::decompressOggVorbis(char* source, int size) {
  if (!source || size <= 0) {
    setValid(false);
    return false;
  }

  int channels = 0;
  int decoded_sample_rate = 0;
  short* decoded = nullptr;
  const int sample_count = stb_vorbis_decode_memory(
      reinterpret_cast<const unsigned char*>(source), size, &channels,
      &decoded_sample_rate, &decoded);
  if (sample_count <= 0 || channels <= 0 || !decoded ||
      static_cast<size_t>(sample_count) >
          static_cast<size_t>(UINT_MAX) ||
      static_cast<size_t>(channels) >
          static_cast<size_t>(UINT_MAX) / static_cast<size_t>(sample_count)) {
    std::free(decoded);
    setValid(false);
    qWarning("Fluid: unable to decode an SF3 Ogg sample");
    return false;
  }

  // stb_vorbis_decode_memory returns frames per channel and writes an
  // interleaved buffer containing frames * channels samples.
  const unsigned int frames = static_cast<unsigned int>(sample_count);
  const size_t total_samples = static_cast<size_t>(sample_count) *
                               static_cast<size_t>(channels);
  data = new short[total_samples];
  std::memcpy(data, decoded,
              total_samples * sizeof(short));
  std::free(decoded);

  // The SF3 header carries the original sample rate. Use the decoder's value
  // only for malformed fonts that omit it.
  if (samplerate == 0 && decoded_sample_rate > 0)
    samplerate = static_cast<unsigned int>(decoded_sample_rate);

  start = 0;
  end = frames - 1;
  if (loopend > end || loopstart >= loopend || loopstart <= start) {
    // Keep a small guard band around a generated loop, matching MuseScore's
    // original libsndfile adapter.
    if ((end - start) >= 20) {
      loopstart = start + 8;
      loopend = end - 8;
    } else {
      loopstart = start + 1;
      loopend = end > start + 1 ? end - 1 : end;
    }
  }
  if ((end - start) < 8) {
    qWarning("Fluid: decoded SF3 sample is too short");
    setValid(false);
  }
  return valid();
}

}  // namespace FluidS
