#!/bin/bash
# Puts WebKit, the media libraries and what they need from Ubuntu 24.04 into
# one folder, basicshell/, that runs wherever it is put on Ubuntu 24.04 or
# anything newer, and packs it as build/basicshell-linux.tar.xz.
#
#   package/assemble.sh <webkit tarball or folder> <media tarball or folder>
#
# What it takes from the system it runs on, which is to be Ubuntu 24.04 with
# install-runtime.sh's packages: GStreamer's plugins (the list below), its
# plugin scanner, glib-networking's modules, and every library any of those or
# WebKit links to, except the ones every desktop has and which keep working
# with newer versions of what loads them (system-libraries.txt). Each ELF file
# is then pointed at the folder's lib/ by a relative RPATH.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=${BUILD_ROOT:-$here/../build}
mkdir -p "$root"
root=$(cd "$root" && pwd)
out="$root/basicshell"
arch=x86_64-linux-gnu
system=/usr/lib/$arch

rm -rf "$out"
mkdir -p "$out"
unpack() { # tarball or folder
  if [ -d "$1" ]; then cp -a "$1"/. "$out"/; else tar -xf "$1" -C "$out"; fi
}
unpack "$1"
unpack "$2"
rm -rf "$out/include" "$out/lib/pkgconfig" "$out/share/gir-1.0" "$out/lib/$arch/girepository-1.0"
rmdir "$out/lib/$arch" 2>/dev/null || true

# GStreamer: what plays and demuxes the formats the web uses; decoding is
# FFmpeg's through gst-libav (from the media tarball), AV1's is libaom's, and
# hardware decoding goes through VA-API (va).
mkdir -p "$out/lib/gstreamer-1.0" "$out/libexec/gstreamer-1.0"
while read -r plugin; do
  [ -z "$plugin" ] || [ "${plugin#\#}" != "$plugin" ] && continue
  cp -L "$system/gstreamer-1.0/libgst$plugin.so" "$out/lib/gstreamer-1.0/"
done < "$here/gstreamer-plugins.txt"
cp -L "$system/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner" "$out/libexec/gstreamer-1.0/"

# TLS for libsoup. Not glib-networking's proxy modules: GNOME's ends the
# process where no GSettings schemas are installed, and BasicShell is to hand
# WebKit the proxy itself (webkit_network_session_set_proxy_settings).
mkdir -p "$out/lib/gio/modules"
cp -L "$system/gio/modules/libgiognutls.so" "$out/lib/gio/modules/"

mapfile -t keep < <(grep -v '^#' "$here/system-libraries.txt" | grep -v '^$')
from_system() { # soname
  local pattern
  for pattern in "${keep[@]}"; do
    # shellcheck disable=SC2053
    [[ $1 == $pattern ]] && return 0
  done
  return 1
}

elves() { find "$out" -type f \( -name '*.so*' -o -perm -u+x \) -exec sh -c 'head -c4 "$1" | grep -q ELF' _ {} \; -print; }

# Every library the folder's ELF files ask for by name (DT_NEEDED), and what
# those ask for, until nothing new comes in. A library taken from the system
# is not followed: what it needs is the system's business, and shipping that
# could put an older copy in front of what the system's library expects.
resolve() { # elf name -> path, as the loader would find it
  LD_LIBRARY_PATH="$out/lib" ldd "$1" 2>/dev/null | awk -v n="$2" '$1 == n && $2 == "=>" { print $3 }'
}
while :; do
  added=0
  while read -r elf; do
    while read -r name; do
      from_system "$name" && continue
      [ -e "$out/lib/$name" ] && continue
      path=$(resolve "$elf" "$name")
      [ -n "$path" ] && [ -f "$path" ] || continue
      cp -L "$path" "$out/lib/$name"
      added=1
    done < <(patchelf --print-needed "$elf" 2>/dev/null)
  done < <(elves)
  [ "$added" = 0 ] && break
done

# Relative RPATHs (DT_RPATH, which also holds for what each library loads).
while read -r elf; do
  dir=$(dirname "$elf")
  rel=$(realpath --relative-to="$dir" "$out/lib")
  if [ "$rel" = . ]; then rpath='$ORIGIN'; else rpath="\$ORIGIN/$rel"; fi
  patchelf --force-rpath --set-rpath "$rpath" "$elf"
done < <(elves)

# Until BasicShell itself is here, MiniBrowser shows what the folder can do.
mkdir -p "$out/bin"
cp "$here/minibrowser" "$out/bin/minibrowser"
cp "$here/environment.sh" "$out/lib/environment.sh"

# Anything still not found is a library missing from both lists.
missing=$(while read -r elf; do ldd "$elf" 2>/dev/null | { grep 'not found' || true; } | sed "s#^#$(basename "$elf"): #"; done < <(elves) | sort -u)
if [ -n "$missing" ]; then
  echo "Not found:" >&2
  echo "$missing" >&2
  exit 1
fi

echo "Bundled libraries: $(find "$out/lib" -maxdepth 1 -name '*.so*' | wc -l), GStreamer plugins: $(find "$out/lib/gstreamer-1.0" -name '*.so' | wc -l)"
find "$out/lib" -maxdepth 1 -name '*.so*' -printf '%f\n' | sort > "$root/bundled-libraries.txt"
package="$root/basicshell-linux.tar.xz"
tar -C "$root" -cJf "$package" basicshell
du -sh "$out" "$package"
