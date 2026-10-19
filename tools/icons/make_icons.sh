#!/usr/bin/env bash
# Makes the Crossfire icons from the artwork (assets/icons/source/crossfire_artwork.jpeg: the logo
# on a painted-in checkerboard, with AI-generator watermarks), with ImageMagick:
#
#   assets/icons/crossfire.png       1024 x 1024, transparent: the master (READMEs, the macOS icon)
#   assets/icons/crossfire_256.png   256 x 256: built into the editor as its window icon
#   assets/icons/crossfire.ico       16-256 px: the Windows executable's icon (crossfire.rc)
#
# The macOS .icns is made from crossfire.png when the app is bundled (tools/macos/bundle.sh, with
# sips and iconutil). How the background goes: every part of the logo is strongly colored (dark
# red to yellow), while the checkerboard and the watermarks are gray or white, so the alpha is
# the image's chroma (max - min channel; HSL saturation is unstable near white): over 20% is
# the logo (the background peaks under 9%, the logo bottoms out near 48%). Specks under 20000
# pixels are dropped (watermark text), holes in the logo kept, the edge shrunk 1.5 px (JPEG edge
# pixels carry the old background) and softened.
#
# Usage: tools/icons/make_icons.sh   (from the editor's folder; needs ImageMagick 7: magick)
set -euo pipefail
src=assets/icons/source/crossfire_artwork.jpeg
out=assets/icons
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

magick "$src" -colorspace HCL -channel G -separate +channel "$work/chroma.png"
magick "$work/chroma.png" -threshold 20% "$work/raw.png"
magick "$work/raw.png" -define connected-components:area-threshold=20000 \
	-define connected-components:mean-color=true -connected-components 8 "$work/shape.png"
magick "$work/shape.png" "$work/raw.png" -compose Multiply -composite \
	-morphology Erode Disk:1.5 -blur 0x1 "$work/mask.png"
magick "$src" "$work/mask.png" -alpha off -compose CopyOpacity -composite -trim +repage "$work/logo.png"
magick "$work/logo.png" -resize 920x920 -background none -gravity center -extent 1024x1024 -strip "$out/crossfire.png"
magick "$out/crossfire.png" -resize 256x256 -strip "$out/crossfire_256.png"
magick "$out/crossfire.png" -define icon:auto-resize=256,128,64,48,32,24,16 "$out/crossfire.ico"
echo "Made $out/crossfire.png, crossfire_256.png, crossfire.ico"
