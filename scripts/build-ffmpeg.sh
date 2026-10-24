#!/bin/sh
# build-ffmpeg.sh — configure and build FFmpeg (static) against build/prefix.
#
# Run after the adopted libraries are installed into build/prefix.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."
DL="${DL:-$ROOT/build/downloads}"
SRC="${SRC:-$ROOT/build/src}"
PREFIX="${PREFIX:-$ROOT/build/prefix}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
# search only the prefix (no Homebrew/system .pc files)
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

# --- extract pinned FFmpeg source ---
# download and verify the tarball on demand (verify-pins.py pre-fetches it when
# pin verification is enabled, but it must not be a prerequisite)
PINS="$ROOT/deps.txt"
. "$HERE/lib.sh"
if [ ! -d "$SRC/ffmpeg" ]; then
  fetch ffmpeg
fi

builddir="$SRC/ffmpeg"

# --- configure ---
# NOTE: --disable-vulkan because Vulkan on macOS needs MoltenVK (a third-party
# dylib), which the Apple-only runtime rule forbids.
# NOTE: the extra libs below are private dependencies that some static
# libraries' pkg-config files omit (C++ runtime, OpenSSL, zlib, Accelerate), so
# they are supplied explicitly.
extra_libs="-lpthread -lm -lc++ -lssl -lcrypto -lz -framework Accelerate"
set -- \
  --prefix="$PREFIX" \
  --pkg-config-flags=--static \
  --extra-cflags="-I$PREFIX/include" \
  --extra-ldflags="-L$PREFIX/lib" \
  --extra-libs="$extra_libs" \
  --enable-gpl --enable-version3 \
  --enable-static --disable-shared --disable-debug \
  --enable-libxml2 --enable-zlib --enable-bzlib --enable-iconv --enable-openssl \
  --enable-libdav1d --enable-libsvtav1 --enable-libvpx \
  --enable-libx264 --enable-libx265 \
  --enable-libopus --enable-libmp3lame \
  --enable-videotoolbox --enable-audiotoolbox --enable-avfoundation \
  --enable-coreimage --enable-opencl --enable-metal \
  --disable-vulkan \
  --disable-xlib --disable-libxcb

LOGS="$ROOT/build/logs"; mkdir -p "$LOGS"

# Reuse an existing configuration when the tree (possibly restored from the CI
# cache) was configured with identical arguments, so make runs incrementally.
stamp="$builddir/ffbuild/.configure-stamp"
if [ -f "$stamp" ] && [ -f "$builddir/ffbuild/config.mak" ] \
   && [ "$(cat "$stamp")" = "$(printf '%s\n' "$@")" ]; then
  echo "== reuse existing FFmpeg configuration (full)"
else
  if ! ( set -e; cd "$builddir" && ./configure "$@" ) > "$LOGS/ffmpeg-configure-full.log" 2>&1; then
    echo "FAILED: ffmpeg configure (full) (log: build/logs/ffmpeg-configure-full.log; see also $builddir/ffbuild/config.log)"
    tail -n 40 "$LOGS/ffmpeg-configure-full.log" 2>/dev/null || true
    exit 1
  fi
  printf '%s\n' "$@" > "$stamp"
fi

# --- build ---
# make does not track external libraries as prerequisites, so force a relink
# against the (possibly rebuilt) prefix libraries
rm -f "$builddir/ffmpeg" "$builddir/ffprobe" "$builddir/ffplay" \
      "$builddir/ffmpeg_g" "$builddir/ffprobe_g" "$builddir/ffplay_g"
if ! ( set -e; cd "$builddir" && make -j"$JOBS" && make install ) > "$LOGS/ffmpeg-build-full.log" 2>&1; then
  echo "FAILED: ffmpeg build (full) (log: build/logs/ffmpeg-build-full.log)"
  tail -n 40 "$LOGS/ffmpeg-build-full.log" 2>/dev/null || true
  exit 1
fi

echo "== ffmpeg build done: $builddir/ffmpeg"
