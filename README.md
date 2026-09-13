# FFmpeg-Builds

Minimal FFmpeg builds for [NTranscript](https://github.com/Nothing-Software/NTranscript-releases): `ffmpeg` and `ffprobe` for **Windows x64** and **macOS on Apple Silicon**, built by GitHub Actions from pinned, checksummed sources.

NTranscript downloads a build on demand for its video downloads, where FFmpeg joins separately downloaded video and audio streams and converts audio. That is all a build here is for, so it carries only what that needs — a few megabytes, where general-purpose builds run to 150–260 MB.

## What is in a build

- Every demuxer, muxer, parser and bitstream filter. They are small, and they are what lets a stream from any site go into MP4, MKV or WebM without re-encoding.
- Decoders for the audio formats sites actually serve.
- Encoders for AAC (FFmpeg's own), MP3 (LAME), Opus (libopus) and PCM.
- The audio filters format conversion inserts on its own.
- The `file` and `pipe` protocols. Downloading is not FFmpeg's job here.

Not included: video encoders, scaling, hardware acceleration, network protocols, and anything under the GPL. When NTranscript needs to encode video, that will be a separate, fuller build in this repository, not this one grown.

## Licence

The archives are LGPL-2.1-or-later (FFmpeg, LAME), with Opus under BSD-3-Clause. Every release carries the exact source tarballs its archives were built from, and every archive holds a `BUILDINFO.txt` with those sources' checksums and FFmpeg's full configure flags, so any build can be reproduced and compared. The scripts in this repository are under the same LGPL-2.1-or-later; see `LICENSE`.

## Building

```bash
./build.sh windows-x86_64   # on Linux, with mingw-w64, libz-mingw-w64-dev, nasm, pkg-config, zip
./build.sh macos-arm64      # on an Apple Silicon Mac, with the Xcode tools and pkgconf
./check.sh <target>         # linkage; on macOS also real encodes and a remux
```

`versions.env` pins every source with its SHA-256, and a build refuses any download that does not match. FFmpeg's tarball was checked against its release signature (key `FCF986EA15E6E293A5644F10B4322F04D67658D8`) when it was pinned.

## Releasing

1. Change `versions.env`: a new source version, or `BUILD_REVISION` for a change to the build itself.
2. Push a tag `minimal-<ffmpeg version>-<revision>`, for example `minimal-9.0.1-1`.
3. The workflow builds and checks both targets and opens a **draft** release with the archives, the sources and `SHA256SUMS`.
4. Try the Windows archive on Windows, then publish the draft. A published release is immutable.
5. Update the checksums NTranscript pins for FFmpeg.
