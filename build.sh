#!/usr/bin/env bash
# Builds FFmpeg for NTranscript under the LGPL: ffmpeg, ffprobe and the shared
# libraries they run on, for one target.
#
#   ./build.sh windows-x86_64   # on Linux, cross-compiled with mingw-w64
#   ./build.sh macos-arm64      # on an Apple Silicon Mac
#
# The result is dist/ffmpeg-<version>-ntr<revision>-<target>.zip: both
# programs with their libraries beside them, the licences, and a BUILDINFO.txt
# recording exactly what went in.
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

# Downloads a source tarball once, under the name given, and refuses it unless
# it is byte for byte the one pinned in versions.env. Prints the path.
fetch() {
  local url="$1" expected="$2" name="$3"
  local file="$SOURCES/$name"
  [ -f "$file" ] || curl -fsSL --retry 3 -o "$file" "$url"
  local actual
  actual="$(sha256 "$file")"
  if [ "$actual" != "$expected" ]; then
    echo "checksum mismatch for $name: expected $expected, got $actual" >&2
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
    VPX_TARGET=x86_64-win64-gcc
    VPX_EXTRA=(--as=nasm)
    FFMPEG_TARGET=(--enable-cross-compile --target-os=mingw32 --arch=x86_64 --cross-prefix="$HOST-" --pkg-config=pkg-config --enable-w32threads)
    # libgcc linked in, so the libraries need nothing beside them but Windows.
    FFMPEG_LDFLAGS="-static-libgcc"
    # H.264 and HEVC through Media Foundation, the encoders Windows carries
    # itself: on the graphics card where its driver offers one, in software
    # everywhere else. FFmpeg opens mfplat.dll when one of these encoders is
    # opened rather than linking it, so a Windows "N" edition without the
    # Media Feature Pack loses these encoders and nothing else -- check.sh
    # fails any build that links it after all. The encoder is written to
    # take frames from the graphics card as well, and does not build without
    # Direct3D 11, whose libraries FFmpeg opens the same way.
    PLATFORM_FLAGS=(--enable-mediafoundation --enable-d3d11va)
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
    VPX_TARGET=arm64-darwin23-gcc
    VPX_EXTRA=()
    # Libraries are named through @rpath, and the programs look for them in
    # their own folder -- so the archive works wherever it is unpacked.
    FFMPEG_TARGET=(--arch=arm64 --target-os=darwin --cc=clang --enable-pthreads --install-name-dir=@rpath)
    FFMPEG_LDFLAGS="-Wl,-rpath,@executable_path"
    # Apple's H.264 and HEVC encoders, in hardware on every Apple Silicon Mac.
    PLATFORM_FLAGS=(--enable-videotoolbox)
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

if [ "$TARGET" = windows-x86_64 ]; then
  # The MinGW-w64 runtime and winpthreads end up inside the files, and parts
  # of both ask for their notices to travel with the binaries. Those notices
  # are kept in licences/ per mingw-w64 version; a toolchain without a copy
  # stops the build here rather than ship notices that may not match it.
  winpthread="$(realpath "$("$HOST-gcc" -print-file-name=libwinpthread.a)")"
  mingw_package="$(dpkg-query -S "$winpthread" | cut -d: -f1)"
  MINGW_VERSION="$(dpkg-query -W -f='${Version}' "$mingw_package")"
  MINGW_VERSION="${MINGW_VERSION#*:}"
  MINGW_VERSION="${MINGW_VERSION%%[-+~]*}"
  MINGW_NOTICES="$ROOT/licences/mingw-w64-$MINGW_VERSION"
  if [ ! -f "$MINGW_NOTICES/COPYING.MinGW-w64-runtime.txt" ] || [ ! -f "$MINGW_NOTICES/COPYING.winpthreads.txt" ]; then
    echo "no notices kept for mingw-w64 $MINGW_VERSION: add them under $MINGW_NOTICES" >&2
    exit 1
  fi
fi

if [ "$TARGET" = windows-x86_64 ]; then
  echo "::group::zlib $ZLIB_VERSION"
  zlib_tarball="$(fetch "$ZLIB_URL" "$ZLIB_SHA256" "$ZLIB_FILE")"
  zlib_src="$(unpack "$zlib_tarball" zlib)"
  (
    cd "$zlib_src"
    # Built here rather than taken from the distribution: its mingw package
    # hands the linker an import library first, and shared FFmpeg libraries
    # then need a zlib1.dll that nothing ships. macOS has zlib itself.
    make -f win32/Makefile.gcc PREFIX="$HOST-" CFLAGS="$LIB_CFLAGS" -j"$JOBS" libz.a
    install -d "$PREFIX/include" "$PREFIX/lib"
    install -m 644 zlib.h zconf.h "$PREFIX/include/"
    install -m 644 libz.a "$PREFIX/lib/"
  )
  echo "::endgroup::"
fi

if [ "$TARGET" = windows-x86_64 ]; then
  # libvpx threads through winpthreads, and the toolchain offers the linker
  # winpthreads' import library before its static one -- avcodec then needs a
  # libwinpthread-1.dll that nothing ships. Copies of the static archives,
  # where the build looks first, are linked in instead.
  for archive in libwinpthread.a libpthread.a; do
    found="$("$HOST-gcc" -print-file-name="$archive")"
    if [ "$found" != "$archive" ] && [ -f "$found" ]; then
      install -m 644 "$found" "$PREFIX/lib/$archive"
    fi
  done
fi

echo "::group::LAME $LAME_VERSION"
lame_tarball="$(fetch "$LAME_URL" "$LAME_SHA256" "$LAME_FILE")"
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
opus_tarball="$(fetch "$OPUS_URL" "$OPUS_SHA256" "$OPUS_FILE")"
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

echo "::group::dav1d $DAV1D_VERSION"
dav1d_tarball="$(fetch "$DAV1D_URL" "$DAV1D_SHA256" "$DAV1D_FILE")"
dav1d_src="$(unpack "$dav1d_tarball" dav1d)"
dav1d_cross=()
if [ "$TARGET" = windows-x86_64 ]; then
  dav1d_cross=(--cross-file "$dav1d_src/package/crossfiles/x86_64-w64-mingw32.meson")
fi
rm -rf "$WORK/build/dav1d"
meson setup "$WORK/build/dav1d" "$dav1d_src" ${dav1d_cross[@]+"${dav1d_cross[@]}"} \
  --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
  -Denable_tools=false -Denable_tests=false
ninja -C "$WORK/build/dav1d" install
echo "::endgroup::"

echo "::group::libvpx $VPX_VERSION"
vpx_tarball="$(fetch "$VPX_URL" "$VPX_SHA256" "$VPX_FILE")"
vpx_src="$(unpack "$vpx_tarball" libvpx)"
rm -rf "$WORK/build/libvpx"
mkdir -p "$WORK/build/libvpx"
(
  cd "$WORK/build/libvpx"
  if [ "$TARGET" = windows-x86_64 ]; then
    export CROSS="$HOST-"
  fi
  "$vpx_src/configure" --target="$VPX_TARGET" --prefix="$PREFIX" \
    --enable-static --disable-shared --enable-pic \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --enable-vp9-highbitdepth ${VPX_EXTRA[@]+"${VPX_EXTRA[@]}"}
  make -j"$JOBS"
  make install
)
echo "::endgroup::"

FFMPEG_FLAGS=(
  --prefix="$WORK/ffmpeg-install"
  --extra-version="ntr$BUILD_REVISION"
  --pkg-config-flags=--static
  --extra-cflags="-I$PREFIX/include"
  --extra-ldflags="-L$PREFIX/lib $FFMPEG_LDFLAGS"
  # Shared, so ffmpeg and ffprobe share one copy of the codecs instead of
  # carrying one each.
  --enable-shared
  --disable-static
  --disable-autodetect
  --disable-everything
  --disable-network
  --disable-doc
  --disable-ffplay
  --disable-avdevice
  --disable-debug
  --enable-zlib
  --enable-libdav1d
  --enable-libmp3lame
  --enable-libopus
  --enable-libvpx
  # Everything FFmpeg itself provides. Components that need the GPL or a
  # library not built here drop out on their own, which keeps this LGPL.
  --enable-decoders
  --enable-encoders
  --enable-demuxers
  --enable-muxers
  --enable-parsers
  --enable-bsfs
  --enable-filters
  --enable-protocol=file,pipe
  "${FFMPEG_TARGET[@]}"
  ${PLATFORM_FLAGS[@]+"${PLATFORM_FLAGS[@]}"}
)

echo "::group::FFmpeg $FFMPEG_VERSION"
ffmpeg_tarball="$(fetch "$FFMPEG_URL" "$FFMPEG_SHA256" "$FFMPEG_FILE")"
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
INSTALL="$WORK/ffmpeg-install"
STAGE="$WORK/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

case "$TARGET" in
  windows-x86_64)
    for program in ffmpeg.exe ffprobe.exe; do
      [ -f "$INSTALL/bin/$program" ] || { echo "$program was not built" >&2; exit 1; }
    done
    cp "$INSTALL/bin/ffmpeg.exe" "$INSTALL/bin/ffprobe.exe" "$INSTALL"/bin/*.dll "$STAGE/"
    ;;
  macos-arm64)
    for program in ffmpeg ffprobe; do
      [ -f "$INSTALL/bin/$program" ] || { echo "$program was not built" >&2; exit 1; }
    done
    cp "$INSTALL/bin/ffmpeg" "$INSTALL/bin/ffprobe" "$STAGE/"
    # Exactly the libraries the programs ask for, under the names they ask
    # for them by, as real files rather than symlinks.
    for name in $(otool -L "$STAGE/ffmpeg" "$STAGE/ffprobe" | awk '$1 ~ /^@rpath\// { sub("@rpath/", "", $1); print $1 }' | sort -u); do
      cp -L "$INSTALL/lib/$name" "$STAGE/$name"
    done
    codesign --force --sign - "$STAGE/ffmpeg" "$STAGE/ffprobe" "$STAGE"/*.dylib
    ;;
esac

cp "$ffmpeg_src/COPYING.LGPLv2.1" "$STAGE/LICENSE-FFmpeg.txt"
cp "$lame_src/COPYING" "$STAGE/LICENSE-LAME.txt"
cp "$opus_src/COPYING" "$STAGE/LICENSE-Opus.txt"
cp "$dav1d_src/COPYING" "$STAGE/LICENSE-dav1d.txt"
cat "$vpx_src/LICENSE" "$vpx_src/PATENTS" > "$STAGE/LICENSE-libvpx.txt"
sources=(FFMPEG LAME OPUS DAV1D VPX)
if [ "$TARGET" = windows-x86_64 ]; then
  cp "$zlib_src/LICENSE" "$STAGE/LICENSE-zlib.txt"
  cp "$MINGW_NOTICES/COPYING.MinGW-w64-runtime.txt" "$STAGE/LICENSE-mingw-w64-runtime.txt"
  cp "$MINGW_NOTICES/COPYING.winpthreads.txt" "$STAGE/LICENSE-winpthreads.txt"
  sources+=(ZLIB)
  compiler="$("$HOST-gcc" --version)"
  toolchain="${compiler%%$'\n'*}, mingw-w64 $MINGW_VERSION"
else
  compiler="$(clang --version)"
  toolchain="${compiler%%$'\n'*}"
fi

{
  echo "FFmpeg $FFMPEG_VERSION-ntr$BUILD_REVISION for $TARGET"
  echo "Built by https://github.com/Nothing-Software/FFmpeg-Builds${GITHUB_SHA:+ at commit $GITHUB_SHA}"
  echo "Toolchain: $toolchain"
  echo
  echo "Sources:"
  for source in "${sources[@]}"; do
    url_var="${source}_URL"
    sha_var="${source}_SHA256"
    echo "  ${!url_var}"
    echo "    sha256 ${!sha_var}"
  done
  echo
  echo "FFmpeg configure flags:"
  printf '  %s\n' "${FFMPEG_FLAGS[@]}"
  echo
  echo "Licences: LGPL-2.1-or-later (FFmpeg, LAME), BSD (Opus, dav1d, libvpx)."
  echo "The exact sources are attached to the release this archive belongs to."
} > "$STAGE/BUILDINFO.txt"

ARCHIVE="$DIST/ffmpeg-$FFMPEG_VERSION-ntr$BUILD_REVISION-$TARGET.zip"
rm -f "$ARCHIVE"
(cd "$STAGE" && zip -9 -q -X "$ARCHIVE" ./*)
ls -l "$STAGE"
echo "$(basename "$ARCHIVE"): $(wc -c < "$ARCHIVE" | tr -d ' ') bytes"
echo "::endgroup::"
