#!/usr/bin/env bash
# Builds the editor (optimized) and packs a release:
#   dist/odin_sdl_editor-<version>-<platform>.tar.gz (.zip on Windows), holding
#     odin_sdl_editor/   the editor's files (examples, settings) and the built editor, with the SDL3
#                        libraries (Linux: lib/ through rpath; Windows: DLLs; macOS: Homebrew's)
#     odin_sdl_engine/   the engine (Play builds the game's player from it) with Box2D built
#     README.txt
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
mkdir -p "$stage/odin_sdl_editor" "$stage/odin_sdl_engine"
cd "$editor"

# The two repositories' files, without .git or submodules (Skald is compiled in)
git archive HEAD | tar -x -C "$stage/odin_sdl_editor"
git -C "$engine" archive HEAD | tar -x -C "$stage/odin_sdl_engine"
cp -a "$engine/box2d/lib" "$stage/odin_sdl_engine/box2d/"

flags=(-collection:gui=Skald "-collection:engine=$engine" -define:ENGINE_DIR=../odin_sdl_engine -o:speed)
case "$(uname -s)" in
Linux)
	odin build . "${flags[@]}" "-out:$stage/odin_sdl_editor/odin_sdl_editor" "-extra-linker-flags:-Wl,-rpath,\$ORIGIN/lib"
	mkdir -p "$stage/odin_sdl_editor/lib"
	ldd "$stage/odin_sdl_editor/odin_sdl_editor" | awk '/libSDL3/ { print $3 }' | while read -r lib; do cp -L "$lib" "$stage/odin_sdl_editor/lib/"; done
	;;
Darwin)
	odin build . "${flags[@]}" "-out:$stage/odin_sdl_editor/odin_sdl_editor" ${ODIN_LINK_FLAGS:-}
	;;
*)
	odin build . "${flags[@]}" "-out:$stage/odin_sdl_editor/odin_sdl_editor.exe"
	root=$(odin root)
	for d in sdl3 sdl3/image sdl3/ttf sdl3/mixer; do cp "${root%/}/vendor/$d"/*.dll "$stage/odin_sdl_editor/"; done
	;;
esac

cat > "$stage/README.txt" <<TXT
odin_sdl_editor $version ($platform), a development build

Run the editor from its folder (it finds the engine at ../odin_sdl_engine and opens the demo):

    cd odin_sdl_editor
    ./odin_sdl_editor            (odin_sdl_editor.exe on Windows)

Play and Export compile your game, so they need Odin dev-2026-10 on PATH
(https://github.com/odin-lang/Odin/releases/tag/dev-2026-10). The editor itself needs a Vulkan
driver (on macOS: brew install molten-vk vulkan-loader).
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
