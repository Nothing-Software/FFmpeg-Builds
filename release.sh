#!/usr/bin/env bash
# Assembles a release in dist/: the archives the build jobs produced, the
# exact sources they were built from -- which the LGPL asks for, and which let
# anyone rebuild and compare -- and checksums for all of it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=versions.env
source "$ROOT/versions.env"
cd "$ROOT/dist"

for source in FFMPEG LAME OPUS DAV1D VPX ZLIB; do
  url_var="${source}_URL"
  sha_var="${source}_SHA256"
  file_var="${source}_FILE"
  curl -fsSL --retry 3 -o "${!file_var}" "${!url_var}"
  echo "${!sha_var}  ${!file_var}" | sha256sum -c -
done

sha256sum ./*.zip ./*.tar.* | sed 's# \./# #' > SHA256SUMS

cat > RELEASE_NOTES.md <<EOF
FFmpeg $FFMPEG_VERSION for NTranscript: \`ffmpeg\`, \`ffprobe\` and the shared libraries they use, for Windows x64 and for macOS on Apple Silicon.

- Every decoder FFmpeg has, plus dav1d for AV1.
- Every encoder FFmpeg has, plus MP3 (LAME), Opus, and VP8/VP9 (libvpx). On macOS also H.264 and HEVC through VideoToolbox.
- Every demuxer, muxer, parser, bitstream filter and filter, with scaling.
- Not included: anything under the GPL (so no x264 or x265), network protocols, capture devices.

Licensed LGPL-2.1-or-later (FFmpeg, LAME), with Opus, dav1d and libvpx under BSD licences. The source tarballs these archives were built from are attached, and \`BUILDINFO.txt\` inside each archive lists their checksums and FFmpeg's configure flags.
EOF

cat SHA256SUMS
