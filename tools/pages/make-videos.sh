#!/bin/bash
# The three short videos tools/pages/video.html plays, made with the
# system's ffmpeg (encoders included, unlike BasicShell's): H.264 with AAC,
# VP9 with Opus, and AV1.
set -euo pipefail
cd "$(dirname "$0")"
src=(-f lavfi -i testsrc2=size=640x360:rate=30)
ffmpeg -loglevel error -y "${src[@]}" -f lavfi -i sine=frequency=440 -t 6 -c:v libx264 -pix_fmt yuv420p -c:a aac h264.mp4
ffmpeg -loglevel error -y "${src[@]}" -f lavfi -i sine=frequency=660 -t 6 -c:v libvpx-vp9 -b:v 500k -c:a libopus vp9.webm
ffmpeg -loglevel error -y "${src[@]}" -t 6 -c:v libaom-av1 -cpu-used 8 -b:v 300k av1.mp4
