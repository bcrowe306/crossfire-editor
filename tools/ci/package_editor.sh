#!/usr/bin/env bash
# Builds the editor (optimized) and packs the built program for a release:
#   dist/odin_sdl_editor-<version>-<platform>.tar.gz (.zip on Windows), holding the editor's
#   executable with the SDL3 libraries it needs (Linux: lib/, found through rpath $ORIGIN/lib;
#   Windows: the DLLs next to it; macOS: Homebrew's, not bundled) and a README.txt. No sources:
#   settings, icons and fonts are built in.
#
# Usage: tools/ci/package_editor.sh <platform> <version>
# Run from the editor's folder, with the engine checked out next to it (../odin_sdl_engine) and
# set up (the engine's tools/ci/setup.sh, tools/build_box2d.sh).
set -euo pipefail
platform=$1
version=$2
editor=$(cd "$(dirname "$0")/../.." && pwd)
engine=$(cd "$editor/../odin_sdl_engine" && pwd)
name="odin_sdl_editor-$version-$platform"
stage="$editor/dist/$name"
rm -rf "$stage"
mkdir -p "$stage"
cd "$editor"

flags=(-collection:gui=Skald "-collection:engine=$engine" -define:ENGINE_DIR=../odin_sdl_engine -o:speed)
case "$(uname -s)" in
Linux)
	odin build . "${flags[@]}" "-out:$stage/odin_sdl_editor" "-extra-linker-flags:-Wl,-rpath,\$ORIGIN/lib"
	mkdir -p "$stage/lib"
	ldd "$stage/odin_sdl_editor" | awk '/libSDL3/ { print $3 }' | while read -r lib; do cp -L "$lib" "$stage/lib/"; done
	;;
Darwin)
	odin build . "${flags[@]}" "-out:$stage/odin_sdl_editor" ${ODIN_LINK_FLAGS:-}
	;;
*)
	odin build . "${flags[@]}" "-out:$stage/odin_sdl_editor.exe"
	root=$(odin root)
	for d in sdl3 sdl3/image sdl3/ttf sdl3/mixer; do cp "${root%/}/vendor/$d"/*.dll "$stage/"; done
	;;
esac

cat > "$stage/README.txt" <<TXT
odin_sdl_editor $version ($platform), a development build

    ./odin_sdl_editor [project folder]     (odin_sdl_editor.exe on Windows)

With no folder it opens examples/demo_project in the current folder, creating it if it's missing.
The editor needs a Vulkan driver (on macOS: brew install molten-vk vulkan-loader).

Play and Export compile your game, so they need:
- Odin dev-2026-10 on PATH (https://github.com/odin-lang/Odin/releases/tag/dev-2026-10)
- the engine's sources at ../odin_sdl_engine, relative to the folder you start the editor from:
      git clone --recursive https://github.com/bcrowe306/odin_sdl_engine
      odin_sdl_engine/tools/build_box2d.sh
TXT
if [[ "$(uname -s)" == Darwin ]]; then
	echo "macOS: also needs SDL3 from Homebrew: brew install sdl3 sdl3_image sdl3_ttf sdl3_mixer" >> "$stage/README.txt"
fi

cd "$editor/dist"
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) 7z a -tzip -bso0 "$name.zip" "$name" ;;
*) tar -czf "$name.tar.gz" "$name" ;;
esac
rm -rf "$stage"
ls -la "$editor/dist"
