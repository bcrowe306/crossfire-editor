#!/usr/bin/env bash
# Builds the editor (optimized) and packs the built program for a release:
#   dist/odin_sdl_editor-<version>-<platform>.tar.gz (.zip on Windows), holding the editor's
#   executable with the SDL3 libraries it needs (Linux: lib/, found through rpath $ORIGIN/lib;
#   Windows: the DLLs next to it; macOS: Homebrew's, not bundled), a README.txt, and what building
#   games needs besides Odin and a linker (the editor's toolchain.odin):
#   - prebuilt/<target>/player: the engine's player for this platform (optimized), which plays and
#     exports projects without scripts with no compiler at all
#   - engine/: the engine's sources (its git-tracked files, without the third_party submodules)
#     with its built Box2D (box2d/lib) and static SDL (sdl/lib), for games with scripts
#   Settings, icons and fonts are built in.
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
# With the engine's static SDL built (its tools/build_sdl_static.sh), SDL is inside the editor
static=false
compgen -G "$engine/sdl/lib/*/libSDL3.a" > /dev/null && static=true
compgen -G "$engine/sdl/lib/*/sdl3_static.lib" > /dev/null && static=true
case "$(uname -s)" in
Linux)
	if $static; then
		odin build . "${flags[@]}" "-out:$stage/odin_sdl_editor"
	else
		odin build . "${flags[@]}" "-out:$stage/odin_sdl_editor" "-extra-linker-flags:-Wl,-rpath,\$ORIGIN/lib"
		mkdir -p "$stage/lib"
		ldd "$stage/odin_sdl_editor" | awk '/libSDL3/ { print $3 }' | while read -r lib; do cp -L "$lib" "$stage/lib/"; done
	fi
	;;
Darwin)
	odin build . "${flags[@]}" "-out:$stage/odin_sdl_editor" ${ODIN_LINK_FLAGS:-}
	;;
*)
	odin build . "${flags[@]}" "-out:$stage/odin_sdl_editor.exe"
	root=$(odin root)
	if ! $static; then
		for d in sdl3 sdl3/image sdl3/ttf sdl3/mixer; do cp "${root%/}/vendor/$d"/*.dll "$stage/"; done
	fi
	;;
esac

# The prebuilt player, in the folder Toolchain_PrebuiltPlayer looks in (linux-x64 -> linux_x64)
target=${platform//-/_}
mkdir -p "$stage/prebuilt/$target"
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
	odin build "$engine/player" -o:speed "-out:$stage/prebuilt/$target/player.exe"
	# Windows finds DLLs next to the program
	if ! $static; then
		for d in sdl3 sdl3/image sdl3/ttf sdl3/mixer; do cp "${root%/}/vendor/$d"/*.dll "$stage/prebuilt/$target/"; done
	fi
	;;
Linux)
	if $static; then
		odin build "$engine/player" -o:speed "-out:$stage/prebuilt/$target/player"
	else
		odin build "$engine/player" -o:speed "-out:$stage/prebuilt/$target/player" "-extra-linker-flags:-Wl,-rpath,\$ORIGIN/../../lib"
	fi
	;;
*)
	odin build "$engine/player" -o:speed "-out:$stage/prebuilt/$target/player" ${ODIN_LINK_FLAGS:-}
	;;
esac

# Static: neither program may load an SDL library
if $static && command -v ldd > /dev/null; then
	for program in "$stage"/odin_sdl_editor* "$stage/prebuilt/$target"/player*; do
		if ldd "$program" | grep -i "sdl3"; then
			echo "$program still links SDL dynamically" >&2
			exit 1
		fi
	done
	echo "SDL is inside the editor and the prebuilt player"
fi

# The engine's sources, with its built libraries
mkdir -p "$stage/engine"
(cd "$engine" && git ls-files | grep -v '^third_party/' | tar -cf - -T - box2d/lib $(compgen -G "sdl/lib" || true)) | tar -xf - -C "$stage/engine"

cat > "$stage/README.txt" <<TXT
odin_sdl_editor $version ($platform), a development build

    ./odin_sdl_editor [project folder]     (odin_sdl_editor.exe on Windows)

With no folder it opens examples/demo_project in the current folder, creating it if it's missing.
The editor needs a Vulkan driver (on macOS: brew install molten-vk vulkan-loader).

Projects without scripts play and export with the prebuilt player (prebuilt/): nothing to install.
Projects with scripts are compiled, with the engine's sources in engine/, so they need:
- Odin dev-2026-10: Settings > Toolchain > Install Odin downloads it (or put it on PATH)
- a linker: clang on Linux (your package manager), Xcode's command line tools on macOS
  (xcode-select --install), Visual Studio Build Tools on Windows ("Desktop development with C++")
Settings > Toolchain shows what's found.
TXT
if [[ "$(uname -s)" == Darwin ]] && ! $static; then
	echo "macOS: also needs SDL3 from Homebrew: brew install sdl3 sdl3_image sdl3_ttf sdl3_mixer" >> "$stage/README.txt"
fi

cd "$editor/dist"
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) 7z a -tzip -bso0 "$name.zip" "$name" ;;
*) tar -czf "$name.tar.gz" "$name" ;;
esac
rm -rf "$stage"
ls -la "$editor/dist"
