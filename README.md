# FFmpeg-Builds

FFmpeg builds for [NTranscript](https://github.com/Nothing-Software/NTranscript-releases): `ffmpeg`, `ffprobe` and the shared libraries they use, for **Windows x64** and **macOS on Apple Silicon**, built by GitHub Actions from pinned, checksummed sources, under the **LGPL**.

NTranscript downloads a build on demand. It uses FFmpeg to get the sound out of any video or audio file it is asked to transcribe, to turn a video the app's own player cannot show into one it can, to join the streams of a downloaded video, and to convert between formats.

## What is in a build

- Every decoder FFmpeg has, plus [dav1d](https://code.videolan.org/videolan/dav1d) for AV1.
- Every encoder FFmpeg has, plus MP3 ([LAME](https://lame.sourceforge.io/)), [Opus](https://opus-codec.org/) and VP8/VP9 ([libvpx](https://chromium.googlesource.com/webm/libvpx)). On macOS, also H.264 and HEVC through VideoToolbox, in hardware.
- Every demuxer, muxer, parser, bitstream filter and filter, and scaling.
- The `file` and `pipe` protocols.

Not included: anything under the GPL — which rules out x264 and x265 — network protocols, and capture devices. On Windows, H.264 and HEVC encoding through Media Foundation is not in yet: linked the plain way, a missing `mfplat.dll` (Windows "N" editions) would stop every FFmpeg library from loading, so it waits until it can be added without that.

The programs share one copy of the libraries rather than carrying one each, which keeps a download around half the size.

## Licence

The archives are LGPL-2.1-or-later (FFmpeg, LAME), with Opus, dav1d and libvpx under BSD licences; each archive includes every licence. Every release carries the exact source tarballs its archives were built from, and every archive holds a `BUILDINFO.txt` with those sources' checksums and FFmpeg's full configure flags, so any build can be reproduced and compared. The scripts in this repository are under the same LGPL-2.1-or-later; see `LICENSE`.

## Building

```bash
./build.sh windows-x86_64   # on Linux, with mingw-w64, nasm, pkg-config, meson, ninja, zip
./build.sh macos-arm64      # on an Apple Silicon Mac, with the Xcode tools, pkgconf, meson and ninja
./check.sh <target>         # linkage and licence; on macOS also real encodes, decodes and a transcode
```

`versions.env` pins every source with its SHA-256, and a build refuses any download that does not match. FFmpeg's tarball was checked against its release signature (key `FCF986EA15E6E293A5644F10B4322F04D67658D8`) when it was pinned.

## Releasing

1. Change `versions.env`: a new source version, or `BUILD_REVISION` for a change to the build itself.
2. Push a tag `<ffmpeg version>-ntr<revision>`, for example `9.0.1-ntr1`.
3. The workflow builds and checks both targets and opens a **draft** release with the archives, the sources and `SHA256SUMS`.
4. Try the Windows archive on Windows and the VideoToolbox encoders on a real Mac, then publish the draft. A published release is immutable.
5. Update the checksums NTranscript pins for FFmpeg.
