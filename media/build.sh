#!/bin/bash
# Builds what BasicShell plays video and sound with, beside GStreamer: FFmpeg's
# decoders (H.264, HEVC, AAC, VP8, VP9, Opus, Vorbis, MP3 and the rest) and
# gst-libav, the GStreamer plugin that hands them to WebKit. Not AV1: gst-libav
# leaves out FFmpeg's AV1 decoder and every decoder that wraps another
# library (libdav1d among them), so AV1 is GStreamer's own (av1dec, libaom).
#
#   media/build.sh
#
# FFmpeg is built LGPL: no --enable-gpl, no --enable-nonfree (that would make
# it unredistributable), shared libraries, decoders, demuxers and parsers only;
# nothing that encodes, records or goes on the network. Installed into
# build/media/stage (the package step puts it beside WebKit and points the
# libraries at each other), packed as build/media-<ffmpeg>-<gst-libav>.tar.xz.
#
# BUILD_ROOT  where the sources, the builds and the package go (build/)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=VERSION
source "$here/VERSION"
root=${BUILD_ROOT:-$here/../build}
mkdir -p "$root/media"
root=$(cd "$root" && pwd)
work="$root/media"
stage="$work/stage"
jobs=$(nproc)

fetch() { # url sha256 file
  if ! echo "$2  $3" | sha256sum -c --quiet - 2>/dev/null; then
    curl -sSfL -o "$3" "$1"
    echo "$2  $3" | sha256sum -c -
  fi
}

ffmpeg="$work/ffmpeg-$FFMPEG_VERSION"
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256" "$ffmpeg.tar.xz"
rm -rf "$ffmpeg" "$stage"
tar -xf "$ffmpeg.tar.xz" -C "$work"
(
  cd "$ffmpeg"
  ./configure \
    --prefix="$stage" \
    --enable-shared \
    --disable-static \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --disable-autodetect \
    --disable-avdevice \
    --disable-postproc \
    --disable-network \
    --disable-encoders \
    --disable-muxers \
    --disable-devices \
    --disable-hwaccels \
    --disable-protocols \
    --disable-filters \
    --enable-filter=yadif \
    --enable-zlib
  # Refuse anything but LGPL, whatever the flags above come to.
  grep -q '^#define FFMPEG_LICENSE "LGPL' config.h
  make -j"$jobs" > /dev/null
  make install > /dev/null
)
echo "FFmpeg $FFMPEG_VERSION: $(grep '^#define FFMPEG_LICENSE' "$ffmpeg/config.h" | cut -d'"' -f2), $(grep -c '^#define CONFIG_.*_DECODER 1' "$ffmpeg/config_components.h") decoders"

libav="$work/gst-libav-$GST_LIBAV_VERSION"
fetch "https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-$GST_LIBAV_VERSION.tar.xz" "$GST_LIBAV_SHA256" "$libav.tar.xz"
rm -rf "$libav"
tar -xf "$libav.tar.xz" -C "$work"
PKG_CONFIG_PATH="$stage/lib/pkgconfig" \
  meson setup "$libav/build" "$libav" --prefix="$stage" --libdir=lib --buildtype=release \
    -Ddoc=disabled -Dtests=disabled > /dev/null
meson compile -C "$libav/build" > /dev/null
meson install -C "$libav/build" > /dev/null

rm -rf "$stage/include" "$stage/lib/pkgconfig" "$stage/share"
package="$root/media-$FFMPEG_VERSION-$GST_LIBAV_VERSION.tar.xz"
tar -C "$stage" -cJf "$package" .
find "$stage" -type f | sed "s#^$stage/##" | sort
du -sh "$stage" "$package"
