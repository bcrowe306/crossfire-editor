#!/usr/bin/env bash
# Builds Crossfire Editor (optimized) and packs the built program for a release:
#   dist/crossfire-editor-<version>-<platform>.tar.gz (.zip on Windows), holding the editor's
#   executable with the SDL3 libraries it needs (Linux: lib/, found through rpath $ORIGIN/lib;
#   Windows: the DLLs next to it; macOS: Homebrew's, not bundled), a README.txt, and what building
#   games needs besides Odin and a linker (the editor's toolchain.odin):
#   - prebuilt/<target>/player: the engine's player for this platform (optimized), which plays and
#     exports projects without scripts with no compiler at all
#   - engine/: the engine's sources (its git-tracked files, without the third_party submodules)
#     with its built Box2D (box2d/lib) and static SDL (sdl/lib), for games with scripts
#   - examples/demo_project: the demo project (its git-tracked files), opened when no project is
#     given
#   Settings, icons and fonts are built in. The Windows executable has the Crossfire icon
#   (crossfire.rc); the Linux archive has icons/ and install-desktop-entry.sh (the application
#   menu entry, with the icon). macOS releases are the app bundle (Taskfile.macos.yml) instead.
#
# Usage: tools/ci/package_editor.sh <platform> <version>
# Run from the editor's folder, with the engine checked out next to it (../odin_sdl_engine) and
# set up (the engine's tools/ci/setup.sh, tools/build_box2d.sh).
set -euo pipefail

# Built with zig for an old glibc (tools/ci/zig_toolchain.sh sets GLIBC_MAX): no program may need
# a newer one
glibc_check() { # <program>...
	[[ -n "${GLIBC_MAX:-}" ]] || return 0
	for program in "$@"; do
		newest=$(objdump -T "$program" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1)
		if [[ -n "$newest" ]] && [[ "$(printf '%s\n%s\n' "$newest" "$GLIBC_MAX" | sort -V | tail -1)" != "$GLIBC_MAX" ]]; then
			echo "$program needs GLIBC $newest, newer than $GLIBC_MAX" >&2
			exit 1
		fi
		echo "$program: GLIBC $newest at most"
	done
}

platform=$1
version=$2
editor=$(cd "$(dirname "$0")/../.." && pwd)
engine=$(cd "$editor/../odin_sdl_engine" && pwd)
name="crossfire-editor-$version-$platform"
stage="$editor/dist/$name"
rm -rf "$stage"
mkdir -p "$stage"
cd "$editor"

flags=(-collection:gui=Skald "-collection:engine=$engine" -define:ENGINE_DIR=../odin_sdl_engine "-define:EDITOR_VERSION=$version" -o:speed)
# With the engine's static SDL built (its tools/build_sdl_static.sh), SDL is inside the editor
static=false
compgen -G "$engine/sdl/lib/*/libSDL3.a" > /dev/null && static=true
compgen -G "$engine/sdl/lib/*/sdl3_static.lib" > /dev/null && static=true
case "$(uname -s)" in
Linux)
	if $static; then
		odin build . "${flags[@]}" "-out:$stage/crossfire-editor"
	else
		odin build . "${flags[@]}" "-out:$stage/crossfire-editor" "-extra-linker-flags:-Wl,-rpath,\$ORIGIN/lib"
		mkdir -p "$stage/lib"
		ldd "$stage/crossfire-editor" | awk '/libSDL3/ { print $3 }' | while read -r lib; do cp -L "$lib" "$stage/lib/"; done
	fi
	;;
Darwin)
	# Homebrew's -L only without the static SDL: macOS's linker takes the first folder with a
	# library, so Homebrew's dylibs would win over the static ones (macOS releases use
	# Taskfile.macos.yml's bundle instead of this archive)
	if $static; then
		odin build . "${flags[@]}" "-out:$stage/crossfire-editor"
	else
		odin build . "${flags[@]}" "-out:$stage/crossfire-editor" ${ODIN_LINK_FLAGS:-}
	fi
	;;
*)
	odin build . "${flags[@]}" -resource:crossfire.rc "-out:$stage/crossfire-editor.exe"
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
	odin build "$engine/player" -o:speed "-out:$stage/prebuilt/$target/player" $($static || echo "${ODIN_LINK_FLAGS:-}")
	;;
esac

# Static: neither program may load an SDL library
if $static && command -v ldd > /dev/null; then
	for program in "$stage"/crossfire-editor* "$stage/prebuilt/$target"/player*; do
		if ldd "$program" | grep -i "sdl3"; then
			echo "$program still links SDL dynamically" >&2
			exit 1
		fi
	done
	echo "SDL is inside the editor and the prebuilt player"
fi
[[ "$(uname -s)" == Linux ]] && glibc_check "$stage/crossfire-editor" "$stage/prebuilt/$target/player"

# The engine's sources, with its built libraries
mkdir -p "$stage/engine"
(cd "$engine" && git ls-files | grep -v '^third_party/' | tar -cf - -T - box2d/lib $(compgen -G "sdl/lib" || true)) | tar -xf - -C "$stage/engine"

# The shader compilers (Toolchain_ShaderTools: shader_tools/<os>_<arch>/ beside the editor)
for dir in "$engine"/shader_tools/*_*/; do
	[[ "$(basename "$dir")" == build ]] && continue
	[[ -f "$dir/glslang" || -f "$dir/glslang.exe" ]] || continue
	mkdir -p "$stage/shader_tools/$(basename "$dir")"
	cp "$dir"/glslang* "$dir"/shadercross* "$stage/shader_tools/$(basename "$dir")/"
	# The font tool (MSDF atlases), when this build of the tools has it
	if compgen -G "$dir/msdf-atlas-gen*" > /dev/null; then cp "$dir"/msdf-atlas-gen* "$stage/shader_tools/$(basename "$dir")/"; fi
	[[ "$(uname -s)" == Linux ]] && glibc_check "$stage/shader_tools/$(basename "$dir")/glslang" "$stage/shader_tools/$(basename "$dir")/shadercross"
done
compgen -G "$stage/shader_tools/*/shadercross*" > /dev/null || echo "No shader tools (the engine's tools/build_shader_tools.sh): projects' own shaders won't compile in this package" >&2

# Web exports build SDL3_mixer with this script (Toolchain_WebMixerScript: tools/ beside the editor)
mkdir -p "$stage/tools"
cp tools/build_web_mixer.sh "$stage/tools/"

# The demo project, where the editor looks for it (Editor_DemoProject: beside the executable)
(cd "$editor" && git ls-files examples/demo_project | tar -cf - -T -) | tar -xf - -C "$stage"
test -f "$stage/examples/demo_project/project.xml"

# Linux: the icon and the application menu entry
if [[ "$(uname -s)" == Linux ]]; then
	mkdir -p "$stage/icons"
	cp assets/icons/crossfire.png assets/icons/crossfire_256.png "$stage/icons/"
	cp tools/linux/install-desktop-entry.sh "$stage/"
fi

cat > "$stage/README.txt" <<TXT
Crossfire Editor $version ($platform), a development build

    ./crossfire-editor [project folder]     (crossfire-editor.exe on Windows)

With no folder it opens the demo project in examples/demo_project, beside the editor: a small
space game, and a platformer level made in LDtk (the menu's "Forest (LDtk)").
Linux: ./install-desktop-entry.sh adds it to your application menu, with its icon.
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
