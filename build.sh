#!/usr/bin/env bash
# Builds a minimal, LGPL-only FFmpeg -- ffmpeg and ffprobe -- for one target.
#
#   ./build.sh windows-x86_64   # on Linux, cross-compiled with mingw-w64
#   ./build.sh macos-arm64      # on an Apple Silicon Mac
#
# The result is dist/ffmpeg-<version>-ntr<revision>-<target>.zip: both
# programs, the licences, and a BUILDINFO.txt recording exactly what went in.
set -euo pipefail

TARGET="${1:?usage: build.sh windows-x86_64|macos-arm64}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=versions.env
source "$ROOT/versions.env"

WORK="$ROOT/work/$TARGET"
PREFIX="$WORK/prefix"
SOURCES="$ROOT/sources"
DIST="$ROOT/dist"
mkdir -p "$WORK" "$PREFIX" "$SOURCES" "$DIST"

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Downloads a source tarball once and refuses it unless it is byte for byte
# the one pinned in versions.env. Prints the path.
fetch() {
  local url="$1" expected="$2"
  local file="$SOURCES/$(basename "$url")"
  [ -f "$file" ] || curl -fsSL --retry 3 -o "$file" "$url"
  local actual
  actual="$(sha256 "$file")"
  if [ "$actual" != "$expected" ]; then
    echo "checksum mismatch for $(basename "$file"): expected $expected, got $actual" >&2
    rm -f "$file"
    exit 1
  fi
  echo "$file"
}

# Unpacks a tarball into a fresh directory under $WORK. Prints the path.
unpack() {
  local tarball="$1" name="$2"
  local dir="$WORK/src/$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xf "$tarball" -C "$dir" --strip-components=1
  echo "$dir"
}

case "$TARGET" in
  windows-x86_64)
    HOST=x86_64-w64-mingw32
    AUTOTOOLS_HOST=(--host="$HOST")
    LIB_CFLAGS="-O2"
    FFMPEG_TARGET=(--enable-cross-compile --target-os=mingw32 --arch=x86_64 --cross-prefix="$HOST-" --pkg-config=pkg-config --enable-w32threads)
    # Everything static, libgcc included, so the programs need nothing beside
    # them but Windows itself.
    FFMPEG_LDFLAGS="-static -static-libgcc"
    EXE=.exe
    ;;
  macos-arm64)
    if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
      echo "macos-arm64 has to be built on an Apple Silicon Mac" >&2
      exit 1
    fi
    AUTOTOOLS_HOST=()
    # LAME 3.100 predates the stricter defaults of current Apple clang.
    LIB_CFLAGS="-O2 -Wno-error=incompatible-function-pointer-types -Wno-error=implicit-function-declaration"
    # No newer than NTranscript's own minimum (14.2): a tool that needs a newer
    # macOS than the app it serves would fail on machines the app supports.
    export MACOSX_DEPLOYMENT_TARGET=14.0
    FFMPEG_TARGET=(--arch=arm64 --target-os=darwin --cc=clang --enable-pthreads)
    FFMPEG_LDFLAGS=""
    EXE=""
    ;;
  *)
    echo "unknown target: $TARGET" >&2
    exit 1
    ;;
esac

# Only the libraries built below are visible to pkg-config, never the build
# machine's own.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH

echo "::group::LAME $LAME_VERSION"
lame_tarball="$(fetch "$LAME_URL" "$LAME_SHA256")"
lame_src="$(unpack "$lame_tarball" lame)"
(
  cd "$lame_src"
  # 3.100 exports a symbol it no longer defines. Harmless for a static
  # library, fatal for some linkers.
  sed -i.orig '/lame_init_old/d' include/libmp3lame.sym
  ./configure ${AUTOTOOLS_HOST[@]+"${AUTOTOOLS_HOST[@]}"} --prefix="$PREFIX" \
    --enable-static --disable-shared --disable-frontend --disable-decoder \
    --disable-gtktest --disable-cpml CFLAGS="$LIB_CFLAGS"
  make -j"$JOBS"
  make install
)
echo "::endgroup::"

echo "::group::Opus $OPUS_VERSION"
opus_tarball="$(fetch "$OPUS_URL" "$OPUS_SHA256")"
opus_src="$(unpack "$opus_tarball" opus)"
(
  cd "$opus_src"
  # The stack protector and fortified builds pull in libssp, which a static
  # mingw link does not have. The neural-network features carry model weights
  # worth megabytes and matter for real-time calls, not for encoding a file.
  ./configure ${AUTOTOOLS_HOST[@]+"${AUTOTOOLS_HOST[@]}"} --prefix="$PREFIX" \
    --enable-static --disable-shared --disable-doc --disable-extra-programs \
    --disable-stack-protector --disable-hardening \
    --disable-deep-plc --disable-dred --disable-osce CFLAGS="$LIB_CFLAGS"
  make -j"$JOBS"
  make install
)
echo "::endgroup::"

# What sites serve, and what the few conversions NTranscript offers need.
AUDIO_DECODERS="aac,aac_latm,ac3,alac,dca,eac3,flac,mp1,mp2,mp3,mp3float,opus,pcm_alaw,pcm_f32le,pcm_mulaw,pcm_s16be,pcm_s16le,pcm_s24le,pcm_s32le,pcm_u8,truehd,vorbis,wmav1,wmav2"
ENCODERS="aac,libmp3lame,libopus,pcm_s16le"
# The ones format conversion inserts on its own, plus trimming.
FILTERS="abuffer,abuffersink,aformat,anull,aresample,asetnsamples,atrim,buffer,buffersink,format,null,trim"

FFMPEG_FLAGS=(
  --prefix="$WORK/ffmpeg-install"
  --extra-version="ntr$BUILD_REVISION"
  --pkg-config-flags=--static
  --extra-cflags="-I$PREFIX/include"
  --extra-ldflags="-L$PREFIX/lib $FFMPEG_LDFLAGS"
  --enable-static
  --disable-shared
  --disable-autodetect
  --disable-everything
  --disable-network
  --disable-doc
  --disable-ffplay
  --disable-avdevice
  --disable-swscale
  --disable-debug
  --enable-zlib
  --enable-libmp3lame
  --enable-libopus
  --enable-demuxers
  --enable-muxers
  --enable-parsers
  --enable-bsfs
  --enable-protocol=file,pipe
  --enable-decoder="$AUDIO_DECODERS"
  --enable-encoder="$ENCODERS"
  --enable-filter="$FILTERS"
  "${FFMPEG_TARGET[@]}"
)

echo "::group::FFmpeg $FFMPEG_VERSION"
ffmpeg_tarball="$(fetch "$FFMPEG_URL" "$FFMPEG_SHA256")"
ffmpeg_src="$(unpack "$ffmpeg_tarball" ffmpeg)"
(
  cd "$ffmpeg_src"
  if ! ./configure "${FFMPEG_FLAGS[@]}"; then
    tail -n 60 ffbuild/config.log
    exit 1
  fi
  make -j"$JOBS"
  make install
)
echo "::endgroup::"

echo "::group::Package"
BIN="$WORK/ffmpeg-install/bin"
for program in ffmpeg ffprobe; do
  if [ ! -f "$BIN/$program$EXE" ]; then
    echo "$program$EXE was not built" >&2
    exit 1
  fi
done

STAGE="$WORK/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$BIN/ffmpeg$EXE" "$BIN/ffprobe$EXE" "$STAGE/"
cp "$ffmpeg_src/COPYING.LGPLv2.1" "$STAGE/LICENSE-FFmpeg.txt"
cp "$lame_src/COPYING" "$STAGE/LICENSE-LAME.txt"
cp "$opus_src/COPYING" "$STAGE/LICENSE-Opus.txt"
if [ "$TARGET" = macos-arm64 ]; then
  codesign --force --sign - "$STAGE/ffmpeg" "$STAGE/ffprobe"
fi

{
  echo "FFmpeg $FFMPEG_VERSION-ntr$BUILD_REVISION for $TARGET"
  echo "Built by https://github.com/Nothing-Software/FFmpeg-Builds${GITHUB_SHA:+ at commit $GITHUB_SHA}"
  echo
  echo "Sources:"
  echo "  $FFMPEG_URL"
  echo "    sha256 $FFMPEG_SHA256"
  echo "  $LAME_URL"
  echo "    sha256 $LAME_SHA256"
  echo "  $OPUS_URL"
  echo "    sha256 $OPUS_SHA256"
  echo
  echo "FFmpeg configure flags:"
  printf '  %s\n' "${FFMPEG_FLAGS[@]}"
  echo
  echo "Licences: LGPL-2.1-or-later (FFmpeg, LAME), BSD-3-Clause (Opus)."
  echo "The exact sources are attached to the release this archive belongs to."
} > "$STAGE/BUILDINFO.txt"

ARCHIVE="$DIST/ffmpeg-$FFMPEG_VERSION-ntr$BUILD_REVISION-$TARGET.zip"
rm -f "$ARCHIVE"
(cd "$STAGE" && zip -9 -q -X "$ARCHIVE" ./*)
ls -l "$STAGE"
echo "$(basename "$ARCHIVE"): $(wc -c < "$ARCHIVE" | tr -d ' ') bytes"
echo "::endgroup::"
