#pragma once

// The implementation is C-compatible but is compiled as C++ in the engine
// target because the target supplies a Qt C++ forced include. Keep this tiny
// declaration separate so the SF3 loader does not include the 190 KB unit.
extern "C" int stb_vorbis_decode_memory(
    const unsigned char* memory,
    int length,
    int* channels,
    int* sample_rate,
    short** output);
