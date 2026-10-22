#!/bin/bash
# What media/build.sh builds FFmpeg and gst-libav with, from Ubuntu 24.04.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential nasm meson ninja-build pkg-config xz-utils zlib1g-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
