#!/bin/bash
# What WPE WebKit is built with, from Ubuntu 24.04's own packages (every
# version WebKit asks for is met by 24.04's: see the README).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  cmake ninja-build ccache clang lld gperf unifdef ruby python3 perl bison flex pkg-config xz-utils patch \
  gobject-introspection libgirepository1.0-dev \
  libglib2.0-dev libharfbuzz-dev libicu-dev libepoxy-dev libgcrypt20-dev libsoup-3.0-dev \
  libxkbcommon-dev libxml2-dev libxslt1-dev libsqlite3-dev libwebp-dev libpng-dev libjpeg-dev \
  zlib1g-dev libtasn1-6-dev libfreetype-dev libfontconfig-dev libwoff-dev libjxl-dev libavif-dev \
  liblcms2-dev libhyphen-dev libenchant-2-dev libdrm-dev libgbm-dev libegl-dev libgles-dev \
  libwayland-dev wayland-protocols libmanette-0.2-dev libatk1.0-dev libatk-bridge2.0-dev \
  libsystemd-dev libseccomp-dev bubblewrap xdg-dbus-proxy \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev \
  libsysprof-capture-4-dev flite1-dev
