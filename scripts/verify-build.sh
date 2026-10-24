#!/bin/sh
# verify-build.sh — acceptance checks for a built FFmpeg (run on the CI runner).
# Checks distribution integration, not upstream algorithms or output quality.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."
PREFIX="${PREFIX:-$ROOT/build/prefix}"
OUT="${OUT:-$ROOT/build/artifacts}"
BIN="$PREFIX/bin"
COMPONENTS="$HERE/data/expected-components.txt"
mkdir -p "$OUT"
# Filters execute in the fixture directory, so binary and log paths must be absolute.
BIN=$(cd "$BIN" && pwd)
OUT=$(cd "$OUT" && pwd)
T="$OUT/tests"; mkdir -p "$T"

fail=0

# Keep command output in the uploaded artifacts and show it on failure.
check() { # label command...
  label="$1"; shift
  if "$@" > "$OUT/$label.log" 2>&1; then
    echo "ok  $label"
    return 0
  else
    echo "ERROR: $label failed (log: $OUT/$label.log)"
    tail -n 80 "$OUT/$label.log"
    fail=1
    return 1
  fi
}

# diagnostics: third-party paths embedded in the pkg-config files
if [ -d "$PREFIX/lib/pkgconfig" ]; then
  echo "== pkg-config files referencing /opt/homebrew:"
  grep -lE '/opt/homebrew' "$PREFIX/lib/pkgconfig"/*.pc 2>/dev/null || echo "  (none)"
  echo "== pkg-config files requiring libpng:"
  grep -lE 'libpng' "$PREFIX/lib/pkgconfig"/*.pc 2>/dev/null || echo "  (none)"
fi

# --- binaries exist and are arm64 ---
for b in ffmpeg ffprobe ffplay; do
  [ -x "$BIN/$b" ] || { echo "ERROR: missing $b"; fail=1; continue; }
  if file "$BIN/$b" | grep -q arm64; then
    echo "ok  $b is arm64"
  else
    echo "ERROR: $b is not arm64"; fail=1
  fi
  check "$b.version" "$BIN/$b" -version || :
done

# --- otool: only Apple-provided dylibs ---
for b in ffmpeg ffprobe ffplay; do
  [ -x "$BIN/$b" ] || continue
  check "$b.otool" otool -L "$BIN/$b" || continue
  bad=$(tail -n +2 "$OUT/$b.otool.log" | awk '{print $1}' \
        | grep -vE '^(/usr/lib/|/System/Library/)' || true)
  if [ -n "$bad" ]; then
    echo "ERROR: $b depends on non-Apple libraries:"; echo "$bad"; fail=1
  else
    echo "ok  $b links only Apple libraries"
  fi
done

# --- buildconf and feature lists ---
check buildconf "$BIN/ffmpeg" -buildconf || :
cp "$OUT/buildconf.log" "$OUT/buildconf.txt"
for x in formats demuxers muxers codecs encoders decoders bsfs filters \
         protocols devices hwaccels pix_fmts sample_fmts layouts dispositions; do
  check "$x" "$BIN/ffmpeg" -"$x" || :
  cp "$OUT/$x.log" "$OUT/$x.txt"
done
echo "ok  saved buildconf and feature lists"

# --- the reduction is a closed set ---
# Every third-party component carries a lib* name, so the lists describe exactly
# which libraries ended up in the binary. Comparing both directions catches a
# silently re-enabled library as well as one that dropped out.
third_party() { # kind
  kind="$1"
  awk -v k="$kind" -F'|' '$1 == k && $0 !~ /^#/ { print $2 }' "$COMPONENTS" | sort > "$T/want.$kind"
  awk '$2 ~ /^lib/ { print $2 }' "$OUT/$kind.txt" | sort > "$T/have.$kind"
  if diff -u "$T/want.$kind" "$T/have.$kind" > "$OUT/$kind.third-party.log"; then
    echo "ok  $kind expose exactly the adopted libraries"
  else
    echo "ERROR: $kind differ from the adopted libraries:"; cat "$OUT/$kind.third-party.log"; fail=1
  fi
}
third_party encoders
third_party decoders

# Removed capabilities must stay removed, and fail as unknown rather than crash.
absent() { # kind name
  if awk -v n="$2" '$2 == n { found = 1 } END { exit !found }' "$OUT/$1.txt"; then
    echo "ERROR: $1 unexpectedly contains $2"; fail=1
  else
    echo "ok  $1 exclude $2"
  fi
}
absent encoders libaom-av1
absent encoders libwebp
absent filters drawtext
absent filters subtitles
absent demuxers dvdvideo

# --- encode -> decode smoke tests ---
smoke() { # name video-decoder-or-empty encoder-args...
  name="$1"; decoder="$2"; shift 2
  # Remove a previous run's file so it cannot satisfy the output check.
  rm -f "$T/$name"
  check "$name.encode" "$BIN/ffmpeg" -nostdin -y -loglevel error -xerror \
    "$@" "$T/$name" || return 0
  if [ ! -s "$T/$name" ]; then
    echo "ERROR: $name produced no file"; fail=1; return 0
  fi
  set --
  [ -z "$decoder" ] || set -- -c:v "$decoder"
  if check "$name.decode" "$BIN/ffmpeg" -nostdin -y -loglevel error -xerror \
     -abort_on empty_output "$@" -i "$T/$name" -f null -; then
    echo "ok  $name encode->decode"
  else
    echo "ERROR: $name encode->decode failed"; fail=1
  fi
}
smoke x264.mp4 "" -f lavfi -i testsrc=size=320x240:rate=30 -t 2 -c:v libx264 -pix_fmt yuv420p
smoke x265.mp4 "" -f lavfi -i testsrc=size=320x240:rate=30 -t 1 -c:v libx265 -pix_fmt yuv420p
smoke vp8.webm libvpx -f lavfi -i testsrc=size=320x240:rate=30 -t 1 -c:v libvpx -pix_fmt yuv420p
smoke vp9.webm libvpx-vp9 -f lavfi -i testsrc=size=320x240:rate=30 -t 1 \
  -c:v libvpx-vp9 -pix_fmt yuv420p -b:v 500k
smoke lame.mp3 "" -f lavfi -i sine=frequency=1000:sample_rate=44100 -t 2 -c:a libmp3lame
smoke aac.m4a "" -f lavfi -i sine=sample_rate=44100 -t 2 -c:a aac
smoke opus.ogg "" -f lavfi -i sine=sample_rate=48000 -t 2 -c:a libopus
# Exercise the adopted AV1 encoder and explicitly use the external decoder.
smoke av1-svt.ivf libdav1d -f lavfi -i testsrc2=size=320x240:rate=3 \
  -frames:v 3 -c:v libsvtav1 -preset 12 -threads 2
# Probe actual media, requiring a stream to be reported, without testing metadata
# precision or ffprobe's complete output schema.
probe() { # name expected-stream-type
  name="$1"; kind="$2"
  if check "$name.probe" "$BIN/ffprobe" -v error -show_entries stream=codec_type \
     -of csv=p=0 "$T/$name"; then
    if ! grep -qx "$kind" "$OUT/$name.probe.log"; then
      echo "ERROR: ffprobe reported no $kind stream for $name"; fail=1
    fi
  fi
}
probe x264.mp4 video
probe aac.m4a audio

# A produced file only proves that encode and decode did not fail. Assert the
# stream inside, so a truncated or mislabelled result cannot pass.
frames() { # name expected
  name="$1"; want="$2"
  check "$name.frames" "$BIN/ffprobe" -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames -of csv=p=0 "$T/$name" || return 0
  got=$(tr -d '[:space:]' < "$OUT/$name.frames.log")
  if [ "$got" = "$want" ]; then
    echo "ok  $name has $want frames"
  else
    echo "ERROR: $name has ${got:-no} frames, expected $want"; fail=1
  fi
}
pix_fmt() { # name expected
  name="$1"; want="$2"
  check "$name.pix_fmt" "$BIN/ffprobe" -v error -select_streams v:0 \
    -show_entries stream=pix_fmt -of csv=p=0 "$T/$name" || return 0
  got=$(tr -d '[:space:]' < "$OUT/$name.pix_fmt.log")
  if [ "$got" = "$want" ]; then
    echo "ok  $name is $want"
  else
    echo "ERROR: $name is ${got:-unknown}, expected $want"; fail=1
  fi
}
frames x264.mp4 60
frames x265.mp4 30
frames vp8.webm 30
frames vp9.webm 30
frames av1-svt.ivf 3
pix_fmt x265.mp4 yuv420p

# 10-bit output is an acceptance condition for the adopted encoders. Encoding
# succeeds even when the library is 8-bit only: FFmpeg then converts silently, so
# the pixel format of the result is what decides.
smoke x264-10bit.mp4 "" -f lavfi -i testsrc=size=320x240:rate=30 -t 1 \
  -c:v libx264 -pix_fmt yuv420p10le
smoke x265-10bit.mp4 "" -f lavfi -i testsrc=size=320x240:rate=30 -t 1 \
  -c:v libx265 -pix_fmt yuv420p10le
smoke vp9-10bit.webm libvpx-vp9 -f lavfi -i testsrc=size=320x240:rate=30 -t 1 \
  -c:v libvpx-vp9 -pix_fmt yuv420p10le -b:v 500k
smoke svt-10bit.ivf libdav1d -f lavfi -i testsrc2=size=320x240:rate=3 \
  -frames:v 2 -c:v libsvtav1 -preset 12 -pix_fmt yuv420p10le
pix_fmt x264-10bit.mp4 yuv420p10le
pix_fmt x265-10bit.mp4 yuv420p10le
pix_fmt vp9-10bit.webm yuv420p10le
pix_fmt svt-10bit.ivf yuv420p10le

# --- ffplay: start and play a short clip (headless) ---
if [ -x "$BIN/ffplay" ]; then
  if check ffplay.playback env SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
     "$BIN/ffplay" -hide_banner -autoexit -nodisp -loglevel error \
     -f lavfi -i "sine=frequency=1000:duration=1"; then
    echo "ok  ffplay start/playback"
  else
    echo "ERROR: ffplay start/playback failed"; fail=1
  fi
fi

# --- TLS trust store ---
# OpenSSL compiles in OPENSSLDIR and uses it for certificate verification. If it
# points into the build tree, https fails on every machine but the runner's.
store=$(strings "$BIN/ffmpeg" | grep -E '/ssl$' | sort -u | tr '\n' ' ')
case "$store" in
  */build/*|*/Users/*|*/home/*)
    echo "ERROR: TLS trust store points into the build tree: $store"; fail=1 ;;
  /etc/ssl*)
    echo "ok  TLS trust store: $store" ;;
  *)
    echo "ERROR: unexpected TLS trust store: ${store:-none}"; fail=1 ;;
esac

# --- checksums ---
( cd "$BIN" && shasum -a 256 ffmpeg ffprobe ffplay > "$OUT/SHA256SUMS" )

if [ "$fail" -ne 0 ]; then echo "RESULT: verify FAILED"; exit 1; fi
echo "RESULT: verify passed ($OUT)"
