#!/bin/bash
# Backlight.png (1024 x 1024, the whole icon with its margin and shadow) -> Backlight.icns
set -euo pipefail
cd "$(dirname "$0")"
SET="$(mktemp -d)/Backlight.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size Backlight.png --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Backlight.png --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Backlight.icns
echo "wrote icon/Backlight.icns"
