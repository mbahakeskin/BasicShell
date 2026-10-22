#!/bin/bash
# Builds WPE WebKit for BasicShell: the release in VERSION, checked against its
# SHA-256, with the patches in patches/, installed into a folder that can be
# moved anywhere and packed as build/wpewebkit-<version>.tar.xz.
#
#   webkit/build.sh
#
# BUILD_ROOT     where the source, the build and the package go (build/)
# BUILD_MINUTES  stop compiling after this long and say "out-of-time", so a
#                run in Actions keeps its compiler cache and goes on in the
#                next one (none: no limit)
# ATTEMPT        which try this is, for the progress line (1)
#
# How far it is: build/progress.txt, once a minute (see ci/progress.sh).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=VERSION
source "$here/VERSION"
root=${BUILD_ROOT:-$here/../build}
mkdir -p "$root"
root=$(cd "$root" && pwd)
export BUILD_ROOT=$root
attempt=${ATTEMPT:-1}
result() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "result=$1" >> "$GITHUB_OUTPUT"; return 0; }

# The installed WebKit names this folder in its libraries; a moved one finds
# its way from where it was loaded (patches/0001).
prefix=/opt/basicshell-webkit

tarball="$root/wpewebkit-$WPE_VERSION.tar.xz"
if ! echo "$WPE_SHA256  $tarball" | sha256sum -c --quiet - 2>/dev/null; then
  curl -sSfL -o "$tarball" "https://wpewebkit.org/releases/wpewebkit-$WPE_VERSION.tar.xz"
  echo "$WPE_SHA256  $tarball" | sha256sum -c -
fi

source="$root/wpewebkit-$WPE_VERSION"
rm -rf "$source"
tar -xf "$tarball" -C "$root"
for patch in "$here"/patches/*.patch; do
  patch -d "$source" -p1 --quiet < "$patch"
done

build="$root/webkit-build"
# $ORIGIN is for the linker, not the shell.
# shellcheck disable=SC2016
cmake -S "$source" -B "$build" -G Ninja \
  -DPORT=WPE \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$prefix" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_LIBEXECDIR=libexec \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld \
  -DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld \
  '-DCMAKE_INSTALL_RPATH=$ORIGIN:$ORIGIN/../lib:$ORIGIN/../../lib' \
  -DENABLE_WPE_LEGACY_API=OFF \
  -DENABLE_WPE_PLATFORM_DRM=OFF \
  -DENABLE_DOCUMENTATION=OFF \
  -DENABLE_INTROSPECTION=ON \
  -DENABLE_WEBDRIVER=OFF \
  -DENABLE_MINIBROWSER=ON \
  -DUSE_LIBBACKTRACE=OFF

log="$root/ninja.log"
: > "$log"
"$here/ci/progress.sh" "$log" "$attempt" &
reporter=$!
trap 'kill $reporter 2>/dev/null || true' EXIT

limit=()
[ -n "${BUILD_MINUTES:-}" ] && limit=(timeout --signal=INT "${BUILD_MINUTES}m")
set +e
NINJA_STATUS="[%f/%t %p] " ${limit[@]+"${limit[@]}"} ninja -C "$build" 2>&1 | tee -a "$log"
status=${PIPESTATUS[0]}
set -e
kill $reporter 2>/dev/null || true
ccache --show-stats --verbose | grep -E "Hits|Misses|Cache size" || true

if [ "$status" = 124 ]; then
  "$here/ci/progress.sh" --final pending "Out of time at $(grep -o '\[[0-9]*/[0-9]* *[0-9]*%\]' "$log" | tail -1); going on in try $((attempt + 1))"
  result out-of-time
  exit 0
elif [ "$status" != 0 ]; then
  "$here/ci/progress.sh" --final failure "Failed (try $attempt): see the run's log"
  result failed
  exit 1
fi

stage="$root/stage"
rm -rf "$stage"
DESTDIR="$stage" ninja -C "$build" install > /dev/null
package="$root/wpewebkit-$WPE_VERSION-basicshell.tar.xz"
tar -C "$stage$prefix" -cJf "$package" .
du -sh "$stage$prefix" "$package"
"$here/ci/progress.sh" --final success "Built: $(du -h "$package" | cut -f1) package, try $attempt"
result built
