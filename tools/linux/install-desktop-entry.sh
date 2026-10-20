#!/usr/bin/env bash
# Adds Crossfire Editor to the desktop's application menu, with its icon: writes
# ~/.local/share/applications/io.github.bcrowe306.crossfire-editor.desktop (its Exec is the editor
# beside this script) and the icon into ~/.local/share/icons/hicolor/<size>/apps/. The file's
# name is the app ID the editor gives its window (branding.odin), so the desktop matches the
# running window to the entry and shows its icon. Run it again after moving the editor's folder;
# --remove takes the entry away.
#
# In a release archive this script is beside the editor (crossfire-editor-<version>-linux-x64/);
# in the repository it's tools/linux/ and the editor is build/release/crossfire-editor.
set -euo pipefail
id=io.github.bcrowe306.crossfire-editor
data=${XDG_DATA_HOME:-$HOME/.local/share}
here=$(cd "$(dirname "$0")" && pwd)

if [[ "${1:-}" == --remove ]]; then
	rm -f "$data/applications/$id.desktop"
	find "$data/icons/hicolor" -name "$id.png" -delete 2> /dev/null || true
	echo "Removed Crossfire Editor from the application menu"
	exit 0
fi

editor=$here/crossfire-editor
icons=$here/icons
if [[ ! -x "$editor" ]]; then
	editor=$(cd "$here/../.." && pwd)/build/release/crossfire-editor
	icons=$(cd "$here/../.." && pwd)/assets/icons
fi
[[ -x "$editor" ]] || { echo "No editor beside this script (or build/release/crossfire-editor)" >&2; exit 1; }

for size in 256 1024; do
	source=$icons/crossfire_256.png
	[[ $size == 1024 ]] && source=$icons/crossfire.png
	[[ -f "$source" ]] || continue
	mkdir -p "$data/icons/hicolor/${size}x${size}/apps"
	cp "$source" "$data/icons/hicolor/${size}x${size}/apps/$id.png"
done
mkdir -p "$data/applications"
cat > "$data/applications/$id.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Crossfire Editor
GenericName=Game Editor
Comment=Make 2D games with the Crossfire Engine
Exec="$editor" %f
Path=$(dirname "$editor")
Icon=$id
Terminal=false
Categories=Development;IDE;
StartupWMClass=$id
DESKTOP
command -v update-desktop-database > /dev/null && update-desktop-database "$data/applications" 2> /dev/null || true
command -v gtk-update-icon-cache > /dev/null && gtk-update-icon-cache -q "$data/icons/hicolor" 2> /dev/null || true
echo "Added Crossfire Editor to the application menu ($data/applications/$id.desktop)"
