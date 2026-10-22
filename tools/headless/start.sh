#!/bin/bash
# A screen nobody sees, to look at BasicShell where there is no display (a
# cloud session): sway on its headless backend with software rendering, grim
# for pictures of it, wtype to type, and vpointer, a pointer that stays (one
# made per command, as wlrctl does, has gone before a client has bound it).
#
#   eval "$(tools/headless/start.sh)"
#   pointer move 420 245; pointer click; typetext "Merhaba"; grim shot.png
#
# pointer takes move X Y, click/down/up [left|right|middle], scroll N, wait MS.
# typetext is wtype after a pause: wtype makes a new keyboard each time, and
# without the pause its first key comes before the client has its keymap.
#
# HEADLESS_DIR   its runtime folder (/tmp/basicshell-headless)
# HEADLESS_SIZE  the screen (1280x800)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
dir=${HEADLESS_DIR:-/tmp/basicshell-headless}
size=${HEADLESS_SIZE:-1280x800}
mkdir -p "$dir"
chmod 700 "$dir"

need=()
for tool in sway grim wtype wayland-scanner cc; do command -v "$tool" > /dev/null || need+=("$tool"); done
if [ ${#need[@]} -gt 0 ]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    sway grim wtype libwayland-dev gcc libc6-dev pkg-config fonts-noto-core > /dev/null >&2
fi

if [ ! -x "$dir/vpointer" ]; then
  wayland-scanner client-header "$here/wlr-virtual-pointer-unstable-v1.xml" "$dir/wlr-virtual-pointer-unstable-v1-client-protocol.h"
  wayland-scanner private-code "$here/wlr-virtual-pointer-unstable-v1.xml" "$dir/wlr-virtual-pointer-unstable-v1-protocol.c"
  # shellcheck disable=SC2046
  cc -O2 -I"$dir" -o "$dir/vpointer" "$here/vpointer.c" "$dir/wlr-virtual-pointer-unstable-v1-protocol.c" $(pkg-config --cflags --libs wayland-client)
fi

running() { XDG_RUNTIME_DIR=$dir WAYLAND_DISPLAY=wayland-1 SWAYSOCK=$(ls "$dir"/sway-ipc.*.sock 2>/dev/null | head -1) swaymsg -t get_version > /dev/null 2>&1; }
if ! running; then
  # A Unix socket's path has room for 107 bytes.
  [ ${#dir} -le 80 ] || { echo "HEADLESS_DIR is too long for a socket path: $dir" >&2; exit 1; }
  rm -f "$dir"/wayland-1 "$dir"/wayland-1.lock "$dir"/sway-ipc.*.sock "$dir/pointer"
  printf 'output HEADLESS-1 resolution %s\ndefault_border none\n' "$size" > "$dir/sway.conf"
  XDG_RUNTIME_DIR=$dir WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    setsid sway -c "$dir/sway.conf" > "$dir/sway.log" 2>&1 < /dev/null &
  for _ in $(seq 50); do running && break; sleep 0.1; done
  running || { echo "sway didn't start: see $dir/sway.log" >&2; exit 1; }
fi

pgrep -f "^$dir/vpointer" > /dev/null || rm -f "$dir/pointer"
if [ ! -p "$dir/pointer" ]; then
  mkfifo "$dir/pointer"
  setsid sleep infinity > "$dir/pointer" < /dev/null &
  XDG_RUNTIME_DIR=$dir WAYLAND_DISPLAY=wayland-1 \
    setsid "$dir/vpointer" "${size%x*}" "${size#*x}" < "$dir/pointer" > "$dir/vpointer.log" 2>&1 &
fi

cat <<OUT
export XDG_RUNTIME_DIR='$dir' WAYLAND_DISPLAY=wayland-1 LC_ALL=C.UTF-8
typetext() { wtype -s 150 "\$*"; }
pointer() { timeout 2 sh -c 'echo "\$1" > "\$2"' _ "\$*" '$dir/pointer' || echo "vpointer isn't reading: see $dir/vpointer.log" >&2; }
OUT
