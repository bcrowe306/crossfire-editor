#!/usr/bin/env bash
# Makes assets/dmg/background.tiff, the disk image window's background (tools/macos/dmg_settings.py):
# 600 x 320 points, at 1x and 2x (Retina) in one TIFF; an arrow from the app's icon to
# Applications'. Needs ImageMagick 7 (magick). Rerun only to change it: the TIFF is committed.
set -euo pipefail
cd "$(dirname "$0")/../.."
font=${FONT:-../odin_sdl_engine/Open_Sans/static/OpenSans-Regular.ttf}
work=$(mktemp -d)
for s in 1 2; do
	magick -size $((600 * s))x$((320 * s)) gradient:'#20232c-#12141a' \
		-fill none -stroke '#5b8cff' -strokewidth $((3 * s)) -draw "line $((230 * s)),$((150 * s)) $((360 * s)),$((150 * s))" \
		-fill '#5b8cff' -stroke none -draw "polygon $((372 * s)),$((150 * s)) $((352 * s)),$((138 * s)) $((352 * s)),$((162 * s))" \
		-font "$font" -fill '#c9cfdc' -pointsize $((15 * s)) -gravity north -annotate +0+$((262 * s)) "Drag Crossfire Editor onto Applications to install it" \
		-units PixelsPerInch -density $((72 * s)) "PNG24:$work/$s.png"
done
mkdir -p assets/dmg
magick "$work/1.png" "$work/2.png" -compress zip assets/dmg/background.tiff
rm -rf "$work"
echo "Made assets/dmg/background.tiff"
