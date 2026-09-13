#!/usr/bin/env bash
# Assembles a release in dist/: the archives the build jobs produced, the
# exact sources they were built from -- which the LGPL asks for, and which
# let anyone rebuild and compare -- and checksums for all of it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=versions.env
source "$ROOT/versions.env"
cd "$ROOT/dist"

for source in "$FFMPEG_URL $FFMPEG_SHA256" "$LAME_URL $LAME_SHA256" "$OPUS_URL $OPUS_SHA256"; do
  read -r url sha <<< "$source"
  file="$(basename "$url")"
  curl -fsSL --retry 3 -o "$file" "$url"
  echo "$sha  $file" | sha256sum -c -
done

sha256sum ./*.zip ./*.tar.* | sed 's# \./# #' > SHA256SUMS

cat > RELEASE_NOTES.md <<EOF
Minimal FFmpeg $FFMPEG_VERSION for NTranscript's video downloads: \`ffmpeg\` and \`ffprobe\` for Windows x64 and for macOS on Apple Silicon.

- Remuxing: every demuxer, muxer, parser and bitstream filter.
- Audio: decoding, and encoding to AAC, MP3 (LAME), Opus and PCM.
- Not included: video encoders, scaling, hardware acceleration, network protocols, anything under the GPL.

Licensed LGPL-2.1-or-later (FFmpeg, LAME) and BSD-3-Clause (Opus). The source tarballs these archives were built from are attached, and \`BUILDINFO.txt\` inside each archive lists their checksums and FFmpeg's configure flags.
EOF

cat SHA256SUMS
