#!/usr/bin/env bash
# Makes the Linux AppImage from a release's files (what tools/ci/package_editor.sh stages:
# crossfire-editor, prebuilt/, engine/, examples/, tools/, icons/), with appimagetool (downloaded
# into build/tools the first time).
#
#   tools/linux/make_appimage.sh <release folder> <output .AppImage>
#
# The image is read-only: the editor sees $APPIMAGE and runs "installed" (bundle.odin): settings
# and build folders in its data folder, the demo copied to ~/Documents/Crossfire Editor.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
editor=$(cd "$here/../.." && pwd)
release=$(cd "${1:?usage: make_appimage.sh <release folder> <output .AppImage>}" && pwd)
output=${2:?usage: make_appimage.sh <release folder> <output .AppImage>}
id=io.github.bcrowe306.crossfire-editor

tool="$editor/build/tools/appimagetool-x86_64.AppImage"
if [[ ! -x "$tool" ]]; then
	mkdir -p "$(dirname "$tool")"
	curl -fL --silent --show-error -o "$tool" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
	chmod +x "$tool"
fi

appdir=$(mktemp -d)/Crossfire_Editor.AppDir
mkdir -p "$appdir"
cp -a "$release"/. "$appdir/"
cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
# The editor and everything it uses are beside this script
here=$(dirname "$(readlink -f "$0")")
exec "$here/crossfire-editor" "$@"
RUN
chmod +x "$appdir/AppRun"
cat > "$appdir/$id.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Crossfire Editor
GenericName=Game Editor
Comment=Make 2D games with the Crossfire Engine
Exec=crossfire-editor %f
Icon=$id
Terminal=false
Categories=Development;IDE;
StartupWMClass=$id
DESKTOP
cp "$editor/assets/icons/crossfire_256.png" "$appdir/$id.png"
# The AppImage has no use for the archive's own menu-entry script
rm -f "$appdir/install-desktop-entry.sh"

# appimagetool is an AppImage itself: extracted and run, so it needs no FUSE (CI has none)
ARCH=x86_64 "$tool" --appimage-extract-and-run --no-appstream "$appdir" "$output"
rm -rf "$(dirname "$appdir")"
echo "Made $output"
