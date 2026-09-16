# Third-party decoder

`stb_vorbis.c` is Sean Barrett's single-file Ogg Vorbis decoder (v1.22),
imported from the upstream stb repository. Its source contains the complete
MIT/public-domain dual-license text at the end of the file. MuseReader builds
it with `STB_VORBIS_NO_STDIO` and uses only the in-memory decode entry point to
read Ogg packets embedded in the SF3 soundfont.

`stb_vorbis_api.h` is the small C ABI declaration used by the C++ SF3 loader;
it does not modify the decoder implementation.
