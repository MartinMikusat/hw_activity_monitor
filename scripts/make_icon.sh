#!/bin/sh
# Renders assets/icon.svg into assets/AppIcon.icns. Quick Look renders the SVG
# (ImageMagick's own renderer drops strokes); its white backdrop is made
# transparent. PNGs are forced to 8 bits: 16-bit PNGs make macOS show the
# generic placeholder icon.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
qlmanage -t -s 1024 -o "$WORK" "$ROOT/assets/icon.svg" >/dev/null 2>&1
magick "$WORK/icon.svg.png" -fuzz 3% -fill none -draw "color 0,0 floodfill" -draw "color 1023,0 floodfill" -draw "color 0,1023 floodfill" -draw "color 1023,1023 floodfill" "$WORK/base.png"
for size in 16 32 128 256 512; do
  magick "$WORK/base.png" -resize "${size}x${size}" -depth 8 "PNG32:$SET/icon_${size}x${size}.png"
  magick "$WORK/base.png" -resize "$((size * 2))x$((size * 2))" -depth 8 "PNG32:$SET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$SET" -o "$ROOT/assets/AppIcon.icns"
rm -rf "$WORK"
