#!/usr/bin/env bash
# Checks a build before it can become a release: every program and library
# links against nothing but the operating system and each other, the build is
# LGPL, and -- where the build machine can run it -- it actually does the jobs
# it is for.
#
#   ./check.sh windows-x86_64   # linkage only; the programs are exercised on
#                               # Windows itself before a release
#   ./check.sh macos-arm64      # linkage, signatures, licence, real work
#
# Output is captured before it is searched rather than piped into `grep -q`:
# grep stops reading at its first match, the program writing to it is killed
# by the broken pipe, and under pipefail a match would read as a failure.
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

fail() {
  echo "$1" >&2
  exit 1
}

# Reports every file with a dependency outside the allowed set, then fails
# once -- so one run shows everything that needs fixing.
problems=""
note_problem() {
  problems="$problems  $1: $2"$'\n'
}

case "$TARGET" in
  windows-x86_64)
    own='(avcodec|avformat|avfilter|avutil|swresample|swscale)-[0-9]+\.dll'
    # Libraries every Windows install has. Anything else would have to ship
    # beside the programs, and nothing does.
    system='(kernel32|msvcrt|ucrtbase|user32|gdi32|advapi32|bcrypt|ole32|oleaut32|shell32|psapi|shlwapi|ws2_32|secur32|crypt32|api-ms-win-[a-z0-9-]+)\.dll'
    for file in "$CHECK"/*.exe "$CHECK"/*.dll; do
      imports="$(x86_64-w64-mingw32-objdump -p "$file")"
      dlls="$(awk '/DLL Name:/ { print tolower($3) }' <<< "$imports" | sort -u)"
      echo "$(basename "$file") imports: $(echo $dlls)"
      unexpected="$(grep -vE "^($own|$system)$" <<< "$dlls" || true)"
      [ -z "$unexpected" ] || note_problem "$(basename "$file")" "$(echo $unexpected)"
    done
    [ -z "$problems" ] || fail "dependencies that would have to ship beside the programs:"$'\n'"$problems"
    ;;

  macos-arm64)
    for file in "$CHECK"/ffmpeg "$CHECK"/ffprobe "$CHECK"/*.dylib; do
      links="$(otool -L "$file" | tail -n +2)"
      echo "$(basename "$file") links:"
      echo "$links"
      unexpected="$(awk '{ print $1 }' <<< "$links" \
        | grep -vE '^(/usr/lib/|/System/Library/|@rpath/lib(avcodec|avformat|avfilter|avutil|swresample|swscale)\.[0-9]+\.dylib$)' || true)"
      [ -z "$unexpected" ] || note_problem "$(basename "$file")" "$(echo $unexpected)"
      codesign --verify "$file" || note_problem "$(basename "$file")" "signature does not verify"
    done
    [ -z "$problems" ] || fail "linkage problems:"$'\n'"$problems"

    cd "$CHECK"
    version="$(./ffmpeg -hide_banner -version)"
    echo "${version%%$'\n'*}"
    # FFmpeg prints its licence through its log, on stderr.
    licence="$(./ffmpeg -hide_banner -L 2>&1)"
    grep -q 'GNU Lesser General Public License' <<< "$licence" || fail "the build is not LGPL"

    encoders="$(./ffmpeg -hide_banner -encoders 2>/dev/null)"
    for encoder in libvpx-vp9 libvpx aac libmp3lame libopus flac mpeg4 h264_videotoolbox hevc_videotoolbox; do
      grep -qw -- "$encoder" <<< "$encoders" || note_problem "encoder $encoder" "missing"
    done
    decoders="$(./ffmpeg -hide_banner -decoders 2>/dev/null)"
    for decoder in libdav1d h264 hevc vp9 mpeg4 wmv3 prores aac opus amrnb adpcm_ms wmav2; do
      grep -qw -- "$decoder" <<< "$decoders" || note_problem "decoder $decoder" "missing"
    done
    [ -z "$problems" ] || fail "components missing from the build:"$'\n'"$problems"

    # A second of silence as raw PCM: no input device or generator needed.
    head -c 88200 /dev/zero > silence.raw
    raw=(-hide_banner -loglevel error -y -f s16le -ar 44100 -ac 1 -i silence.raw)
    ./ffmpeg "${raw[@]}" -c:a libmp3lame silence.mp3
    ./ffmpeg "${raw[@]}" -c:a aac silence.m4a
    # libopus only takes 48 kHz, so this also proves resampling is inserted.
    ./ffmpeg "${raw[@]}" -c:a libopus silence.opus
    ./ffmpeg -hide_banner -loglevel error -y -i silence.m4a -c copy silence.mkv
    # What NTranscript does to every file it transcribes.
    ./ffmpeg -hide_banner -loglevel error -y -i silence.opus -vn -ac 1 -ar 16000 -c:a pcm_s16le silence-16k.wav

    # A second of grey frames, then an old codec turned into the format the
    # app previews in: decoding, scaling and VP9 encoding in one go.
    head -c $((320 * 240 * 3 / 2 * 30)) /dev/zero > grey.yuv
    ./ffmpeg -hide_banner -loglevel error -y -f rawvideo -pix_fmt yuv420p -s 320x240 -r 30 -i grey.yuv -c:v mpeg4 grey.avi
    ./ffmpeg -hide_banner -loglevel error -y -i grey.avi -vf scale=160:-2 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 grey.webm
    produced=""
    if ./ffmpeg -hide_banner -loglevel error -y -i grey.avi -c:v h264_videotoolbox -allow_sw 1 grey-videotoolbox.mp4; then
      produced=grey-videotoolbox.mp4
    else
      # CI Macs are virtual machines without Apple's media engine. Checked on
      # a real Mac before a release instead.
      echo "VideoToolbox could not encode on this runner"
    fi

    for file in silence.mp3 silence.m4a silence.opus silence.mkv silence-16k.wav grey.avi grey.webm $produced; do
      summary="$(./ffprobe -v error -show_entries stream=codec_name,sample_rate,width,height:format=format_name,duration \
        -of compact=p=0:nk=1 "$file")"
      printf '%-24s %s\n' "$file" "$(echo $summary)"
    done
    ;;

  *)
    fail "unknown target: $TARGET"
    ;;
esac

echo "$TARGET: checks passed"
