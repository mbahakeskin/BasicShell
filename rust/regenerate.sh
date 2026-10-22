#!/bin/bash
# Makes the bindings again with gir: after WebKit is updated (its .gir files,
# from a WebKit build's share/gir-1.0, go in rust/gir-files), or a Gir.toml
# changes. gir and gtk-rs's own .gir files are those of the gtk-rs release
# the crates use (0.22), put under build/.
#
#   rust/regenerate.sh [<WebKit install prefix, for its share/gir-1.0>]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
build="$here/../build"
mkdir -p "$build"
release=0.22

if [ -n "${1:-}" ]; then
  for gir in WPEPlatform WPEPlatformWayland WPEPlatformHeadless WPEWebKit WPEJavaScriptCore; do
    cp "$1/share/gir-1.0/$gir-2.0.gir" "$here/gir-files/"
  done
fi
[ -d "$build/gir-files" ] || git clone -q --depth 1 --branch "$release" https://github.com/gtk-rs/gir-files "$build/gir-files"
[ -x "$build/cargo-tools/bin/gir" ] || cargo install --quiet --locked --git https://github.com/gtk-rs/gir --branch "$release" --root "$build/cargo-tools" gir

for crate in sys/wpe-platform-sys sys/wpe-platform-wayland-sys sys/wpe-javascriptcore-sys sys/wpe-webkit-sys wpe-platform wpe-javascriptcore wpe-webkit; do
  (cd "$here/$crate" && "$build/cargo-tools/bin/gir" -o . 2>&1 | grep -v '^\[WARN' || true)
done
echo "Regenerated; check with: (cd rust && cargo test)"
