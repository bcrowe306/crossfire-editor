#!/usr/bin/env bash
# Builds "Crossfire Editor.app": a macOS app bundle with everything the editor needs except Odin
# itself. Taskfile.macos.yml runs each step (`task macos:app` runs them in order); run one alone
# with: tools/macos/bundle.sh <step>
#
#   layout     the folders, Info.plist, the editor, OLS, the prebuilt player, the engine's sources,
#              the demo project
#   vulkan     the Vulkan loader and MoltenVK (dlopened by SDL, so dylibbundler can't see them),
#              and MoltenVK's driver manifest
#   dylibs     every non-system dylib the executables and those libraries link, copied into
#              Contents/Frameworks by dylibbundler, their paths rewritten to @rpath
#   sign       an ad-hoc signature (Apple Silicon refuses to run unsigned code, and rewriting
#              paths breaks signatures); a Developer ID signature comes later (gon)
#   check      what `task macos:verify` checks without running anything: no Mach-O file links
#              outside the bundle except the system, the manifest, the signature
#
#   Crossfire Editor.app/Contents/
#     Info.plist                               (CFBundleIconFile: Resources/Crossfire.icns)
#     MacOS/crossfire-editor                     the editor (SDL linked in statically)
#     MacOS/ols                                the Odin language server
#     MacOS/prebuilt/<target>/player           the player for projects without scripts
#     Frameworks/libvulkan.1.dylib             the Vulkan loader (Homebrew's vulkan-loader)
#     Frameworks/libMoltenVK.dylib             Vulkan on Metal (Homebrew's molten-vk)
#     Frameworks/...                           anything else the executables link
#     Resources/vulkan/icd.d/MoltenVK_icd.json MoltenVK's manifest, pointing at Frameworks/
#     Resources/engine/                        the engine's sources and its static libraries
#                                              (box2d/lib, sdl/lib): games compile against them
#     Resources/tools/build_web_mixer.sh       builds SDL3_mixer for web exports
#     Resources/plugin_api/                    the API editor plugins are built against
#     Resources/docs/manual/                   the user manual, for the docs window (offline)
#     Resources/demo_project/                  the demo project (its git-tracked files): copied to
#                                              ~/Documents/Crossfire Editor on first run
#
# Environment (Taskfile.macos.yml sets it): APP (the .app path), EDITOR_BIN, PLAYER_BIN, OLS_BIN,
# ENGINE_DIR, TARGET (macos_arm64...), VERSION, BUNDLE_ID, APP_NAME
set -euo pipefail
step=${1:?usage: bundle.sh layout|vulkan|dylibs|sign|check}
here=$(cd "$(dirname "$0")" && pwd)
: "${APP:?}" "${VERSION:=0.0.0}" "${BUNDLE_ID:=io.github.bcrowe306.crossfire-editor}" "${APP_NAME:=Crossfire Editor}"
contents="$APP/Contents"
executable=crossfire-editor

# The bundle's Mach-O files: the executables and the libraries in Frameworks
machos() {
	find "$contents/MacOS" "$contents/Frameworks" -type f 2>/dev/null | while read -r f; do
		file "$f" | grep -q "Mach-O" && echo "$f"
	done
}

case "$step" in
layout)
	: "${EDITOR_BIN:?}" "${PLAYER_BIN:?}" "${OLS_BIN:?}" "${ENGINE_DIR:?}" "${TARGET:?}"
	rm -rf "$APP"
	mkdir -p "$contents/MacOS/prebuilt/$TARGET" "$contents/Frameworks" "$contents/Resources"
	# CFBundleShortVersionString wants numbers: v0.1.0-dev.12 -> 0.1.0
	short=$(echo "$VERSION" | sed -E 's/^v//; s/[^0-9.].*$//')
	[[ -n "$short" ]] || short=0.0.0
	sed -e "s|@APP_NAME@|$APP_NAME|g" -e "s|@EXECUTABLE@|$executable|g" -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" \
		-e "s|@VERSION@|$VERSION|g" -e "s|@SHORT_VERSION@|$short|g" "$here/Info.plist.in" > "$contents/Info.plist"
	plutil -lint "$contents/Info.plist" > /dev/null
	printf 'APPL????' > "$contents/PkgInfo"
	# The app icon: Crossfire.icns from the 1024 px logo, every size macOS asks for (sips scales,
	# iconutil packs; Info.plist's CFBundleIconFile names it)
	iconset=$(mktemp -d)/Crossfire.iconset
	mkdir -p "$iconset"
	for size in 16 32 128 256 512; do
		sips -z $size $size "$here/../../assets/icons/crossfire.png" --out "$iconset/icon_${size}x${size}.png" > /dev/null
		double=$((size * 2))
		sips -z $double $double "$here/../../assets/icons/crossfire.png" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
	done
	iconutil -c icns "$iconset" -o "$contents/Resources/Crossfire.icns"
	rm -rf "$(dirname "$iconset")"
	cp "$EDITOR_BIN" "$contents/MacOS/$executable"
	cp "$OLS_BIN" "$contents/MacOS/ols"
	cp "$PLAYER_BIN" "$contents/MacOS/prebuilt/$TARGET/player"
	# The shader compilers (Toolchain_ShaderTools: shader_tools/ beside the executable; signed with the rest)
	for dir in "$ENGINE_DIR"/shader_tools/darwin_*/; do
		[[ -f "$dir/shadercross" ]] || continue
		mkdir -p "$contents/MacOS/shader_tools/$(basename "$dir")"
		cp "$dir/glslang" "$dir/shadercross" "$contents/MacOS/shader_tools/$(basename "$dir")/"
		if [[ -f "$dir/msdf-atlas-gen" ]]; then cp "$dir/msdf-atlas-gen" "$contents/MacOS/shader_tools/$(basename "$dir")/"; fi
	done
	# The engine's git-tracked sources (not the third_party submodules) and its built libraries
	mkdir -p "$contents/Resources/engine"
	(cd "$ENGINE_DIR" && git ls-files | grep -v '^third_party/' | tar -cf - -T - box2d/lib $(compgen -G "sdl/lib" || true)) |
		tar -xf - -C "$contents/Resources/engine"
	# The plugin API editor plugins are built against (Toolchain_PluginAPI: Resources/plugin_api)
	mkdir -p "$contents/Resources/plugin_api"
	cp "$here"/../../plugin_api/*.odin "$contents/Resources/plugin_api/"
	# The user manual the docs window shows offline (Docs_ManualDir: Resources/docs/manual; the
	# API reference is read from Resources/engine)
	mkdir -p "$contents/Resources/docs/manual"
	cp "$here"/../../docs/manual/*.md "$contents/Resources/docs/manual/"
	# The demo project, opened (from a copy the user can edit) when no project is given
	mkdir -p "$contents/Resources/demo_project"
	(cd "$here/../../examples/demo_project" && git ls-files . | tar -cf - -T -) | tar -xf - -C "$contents/Resources/demo_project"
	# Web exports build SDL3_mixer with it (Toolchain_WebMixerScript)
	mkdir -p "$contents/Resources/tools"
	cp "$here/../build_web_mixer.sh" "$contents/Resources/tools/"
	echo "Laid out $APP ($VERSION)"
	;;

vulkan)
	loader=$(brew --prefix vulkan-loader)/lib/libvulkan.1.dylib
	moltenvk=$(brew --prefix molten-vk)/lib/libMoltenVK.dylib
	for lib in "$loader" "$moltenvk"; do
		[[ -f "$lib" ]] || { echo "Missing $lib: brew install vulkan-loader molten-vk" >&2; exit 1; }
	done
	# -L: Homebrew's are symlinks to versioned files
	cp -L "$loader" "$contents/Frameworks/libvulkan.1.dylib"
	cp -L "$moltenvk" "$contents/Frameworks/libMoltenVK.dylib"
	chmod u+w "$contents/Frameworks/"*.dylib
	install_name_tool -id @rpath/libvulkan.1.dylib "$contents/Frameworks/libvulkan.1.dylib"
	install_name_tool -id @rpath/libMoltenVK.dylib "$contents/Frameworks/libMoltenVK.dylib"
	# The manifest's library path is relative to the manifest: Resources/vulkan/icd.d -> Frameworks
	mkdir -p "$contents/Resources/vulkan/icd.d"
	manifest=$(brew --prefix molten-vk)/etc/vulkan/icd.d/MoltenVK_icd.json
	python3 - "$manifest" "$contents/Resources/vulkan/icd.d/MoltenVK_icd.json" <<'PY'
import json, sys
source, target = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(source))
except OSError:
    data = {"file_format_version": "1.0.0", "ICD": {"api_version": "1.2.0", "is_portability_driver": True}}
data["ICD"]["library_path"] = "../../../Frameworks/libMoltenVK.dylib"
json.dump(data, open(target, "w"), indent=4)
PY
	echo "Bundled the Vulkan loader and MoltenVK"
	;;

dylibs)
	command -v dylibbundler > /dev/null || { echo "dylibbundler is needed: brew install dylibbundler" >&2; exit 1; }
	args=()
	while read -r f; do args+=(-x "$f"); done < <(machos)
	# -b bundle, -of overwrite files (not -od: it would empty Frameworks/, the Vulkan step's), -cd
	# create the folder, -ns: sign afterwards (the sign step);
	# @rpath so the editor (MacOS/) and the player (MacOS/prebuilt/<target>/) both find them
	dylibbundler -b -of -cd -ns -d "$contents/Frameworks/" -p "@rpath/" \
		-s "$(brew --prefix)/lib" "${args[@]}"
	add_rpath() { # <file> <rpath>
		otool -l "$1" | grep -q "path $2 " || install_name_tool -add_rpath "$2" "$1"
	}
	add_rpath "$contents/MacOS/$executable" "@executable_path/../Frameworks"
	add_rpath "$contents/MacOS/ols" "@executable_path/../Frameworks"
	for player in "$contents/MacOS/prebuilt/"*/player; do add_rpath "$player" "@executable_path/../../../Frameworks"; done
	for lib in "$contents/Frameworks/"*.dylib; do add_rpath "$lib" "@loader_path"; done
	echo "Bundled the libraries:"
	ls "$contents/Frameworks"
	;;

sign)
	# Inside out: libraries, helper executables, then the bundle
	while read -r f; do codesign --force --sign - --timestamp=none "$f"; done < <(machos)
	codesign --force --sign - --timestamp=none "$APP"
	codesign --verify --deep --strict "$APP"
	echo "Signed $APP (ad hoc)"
	;;

check)
	problems=0
	while read -r f; do
		# Every linked library is the system's or the bundle's
		outside=$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/|@rpath/|@executable_path/|@loader_path/)' || true)
		if [[ -n "$outside" ]]; then
			echo "$f links outside the bundle: $outside" >&2
			problems=$((problems + 1))
		fi
	done < <(machos)
	# SDL is linked in statically (the engine's sdl/lib): no SDL library may be bundled or linked
	if compgen -G "$contents/Frameworks/libSDL3*" > /dev/null; then
		echo "SDL dylibs were bundled: the static SDL wasn't linked (is Homebrew's lib folder passed with -L?)" >&2
		problems=$((problems + 1))
	fi
	# A game exported with the prebuilt player carries no bundle with it: it may link nothing
	for player in "$contents/MacOS/prebuilt/"*/player; do
		if otool -L "$player" | tail -n +2 | grep -q "@rpath/"; then
			echo "$player links bundled libraries: exported games would miss them (build the static SDL)" >&2
			problems=$((problems + 1))
		fi
	done
	for f in "$contents/Info.plist" "$contents/Resources/Crossfire.icns" "$contents/MacOS/ols" "$contents/Frameworks/libvulkan.1.dylib" \
		"$contents/Frameworks/libMoltenVK.dylib" "$contents/Resources/vulkan/icd.d/MoltenVK_icd.json" \
		"$contents/Resources/engine/player/main.odin" "$contents/Resources/demo_project/project.xml"; do
		[[ -e "$f" ]] || { echo "Missing $f" >&2; problems=$((problems + 1)); }
	done
	compgen -G "$contents/Resources/engine/sdl/lib/*/libSDL3.a" > /dev/null || { echo "No static SDL in the engine's copy" >&2; problems=$((problems + 1)); }
	compgen -G "$contents/Resources/engine/box2d/lib/box2d_darwin_*.a" > /dev/null || { echo "No Box2D in the engine's copy" >&2; problems=$((problems + 1)); }
	codesign --verify --deep --strict "$APP" || problems=$((problems + 1))
	if [[ $problems -gt 0 ]]; then
		echo "$problems problem(s) in $APP" >&2
		exit 1
	fi
	echo "$APP is self-contained"
	;;

*)
	echo "Unknown step $step: layout, vulkan, dylibs, sign or check" >&2
	exit 1
	;;
esac
