#!/bin/bash
# What package/assemble.sh takes from Ubuntu 24.04: GStreamer's plugins and
# glib-networking, with the libraries they bring.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends patchelf xz-utils \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-gl \
  glib-networking \
  libsoup-3.0-0 libicu74 libxslt1.1 libwebp7 libwebpdemux2 libavif16 libjxl0.7 liblcms2-2 libhyphen0 \
  libenchant-2-2 libmanette-0.2-0 libwoff1 libatk1.0-0t64 libatk-bridge2.0-0t64 libseccomp2 \
  libflite1 libepoxy0 libsqlite3-0 libjpeg-turbo8 bubblewrap xdg-dbus-proxy
