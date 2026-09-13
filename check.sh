#!/usr/bin/env bash
# Checks a build before it can become a release: the programs link against
# nothing but the operating system and, where the build machine can run
# them, actually do the jobs they are for.
#
#   ./check.sh windows-x86_64   # imports only; the programs themselves are
#                               # exercised on Windows before a release
#   ./check.sh macos-arm64      # linkage, signature, and real conversions
set -euo pipefail

TARGET="${1:?usage: check.sh windows-x86_64|macos-arm64}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=versions.env
source "$ROOT/versions.env"

ARCHIVE="$ROOT/dist/ffmpeg-$FFMPEG_VERSION-ntr$BUILD_REVISION-$TARGET.zip"
CHECK="$ROOT/work/$TARGET/check"
rm -rf "$CHECK"
mkdir -p "$CHECK"
unzip -q "$ARCHIVE" -d "$CHECK"

case "$TARGET" in
  windows-x86_64)
    for program in ffmpeg.exe ffprobe.exe; do
      dlls="$(x86_64-w64-mingw32-objdump -p "$CHECK/$program" | awk '/DLL Name:/ { print tolower($3) }' | sort -u)"
      echo "$program imports: $(echo $dlls)"
      # Libraries every Windows install has. Anything else would have to be
      # shipped beside the program, and nothing is.
      unexpected="$(echo "$dlls" | grep -vE '^(kernel32|msvcrt|ucrtbase|user32|advapi32|bcrypt|ole32|shell32|psapi|shlwapi|ws2_32|api-ms-win-[a-z0-9-]+)\.dll$' || true)"
      if [ -n "$unexpected" ]; then
        echo "unexpected dependency in $program: $unexpected" >&2
        exit 1
      fi
    done
    ;;

  macos-arm64)
    for program in ffmpeg ffprobe; do
      echo "$program links:"
      otool -L "$CHECK/$program" | tail -n +2
      unexpected="$(otool -L "$CHECK/$program" | tail -n +2 | awk '{ print $1 }' | grep -vE '^(/usr/lib/|/System/Library/)' || true)"
      if [ -n "$unexpected" ]; then
        echo "unexpected dependency in $program: $unexpected" >&2
        exit 1
      fi
      codesign --verify --verbose "$CHECK/$program"
    done

    cd "$CHECK"
    ./ffmpeg -hide_banner -version | head -n 1
    # A second of silence as raw PCM: no input device or generator needed.
    head -c 88200 /dev/zero > silence.raw
    raw=(-hide_banner -loglevel error -f s16le -ar 44100 -ac 1 -i silence.raw)
    ./ffmpeg "${raw[@]}" -c:a libmp3lame silence.mp3
    ./ffmpeg "${raw[@]}" -c:a aac silence.m4a
    # libopus only takes 48 kHz, so this also proves resampling is inserted.
    ./ffmpeg "${raw[@]}" -c:a libopus silence.opus
    ./ffmpeg -hide_banner -loglevel error -i silence.m4a -c copy silence.mkv
    ./ffmpeg -hide_banner -loglevel error -i silence.opus -c:a pcm_s16le silence.wav
    for file in silence.mp3 silence.m4a silence.opus silence.mkv silence.wav; do
      printf '%-14s ' "$file"
      ./ffprobe -v error -show_entries stream=codec_name,sample_rate:format=format_name,duration \
        -of compact=p=0:nk=1 "$file" | tr '\n' ' '
      echo
    done
    ;;

  *)
    echo "unknown target: $TARGET" >&2
    exit 1
    ;;
esac

echo "$TARGET: checks passed"
